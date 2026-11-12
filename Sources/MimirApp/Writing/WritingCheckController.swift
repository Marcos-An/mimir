import AppKit
import MimirCore
import Observation
import os.log
import SwiftUI

/// What Settings shows about the writing check (counter, key problems).
@MainActor
@Observable
final class WritingCheckStatus {
    static let shared = WritingCheckStatus()

    private static let budgetKey = "com.mimir.writing.budget.v1"

    private(set) var budget: WritingRequestBudget

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.budgetKey),
           let saved = try? JSONDecoder().decode(WritingRequestBudget.self, from: data) {
            budget = saved
        } else {
            budget = WritingRequestBudget()
        }
    }

    var requestsToday: Int { budget.sent(on: Date()) }
    var dailyCap: Int { budget.dailyCap }
    var keyRejected: Bool { budget.keyRejected }

    func update(_ change: (inout WritingRequestBudget) -> Void) {
        change(&budget)
        if let data = try? JSONEncoder().encode(budget) {
            UserDefaults.standard.set(data, forKey: Self.budgetKey)
        }
    }

    /// Settings saved or removed the Anthropic key.
    func keyChanged() {
        // Reload now: a running check only loads the key when it starts.
        Task.detached { AnthropicKeyStore.shared.reload() }
        update { $0.keyChanged() }
    }
}

/// Underlines writing mistakes in allowed apps while the user types, using
/// Claude. Off unless enabled in Settings; when off, nothing observes or reads
/// other apps. Overlay mechanics adapted from Trecho's SpellOverlayController.
@MainActor
final class WritingCheckController {
    private let store: SettingsStore
    private let model: MimirAppModel
    private let status = WritingCheckStatus.shared
    private let checker: WritingChecker

    private var isActive = false
    private var policy = WritingAppPolicy(scope: .listedApps, listed: [], skipped: [])
    private var scheduler = WritingCheckScheduler()

    private var field: FocusedField?
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var observedBundleID: String?
    private var workspaceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?

    private var idleWork: DispatchWorkItem?
    private var requestInFlight = false
    /// Scroll and layout changes are coalesced: one re-placement per 100 ms.
    private var layoutWork: DispatchWorkItem?
    /// Word positions for the current text and layout (cleared on any change),
    /// so selection-only notifications don't ask the app again.
    private var rectCache: [NSRange: [CGRect]] = [:]
    private var rectCacheText: String?
    private var applyFailedUntil: Date = .distantPast
    /// Mimir's own dictation paste: changes in this window are never sent.
    private var quietUntil: Date = .distantPast

    /// No reads while Mimir records, transcribes or pastes, and for 2 s after.
    /// Accessibility calls run on the main thread; during a recording they
    /// can delay the Esc tap enough for macOS to disable it.
    private var isQuiet: Bool {
        switch model.phase {
        case .recording, .transcribing, .postProcessing, .inserting: return true
        default: return Date() < quietUntil
        }
    }
    /// After a dictation, the field's text is marked as checked on the first
    /// read once the quiet window ends (nothing is read during it).
    private var pendingSeed = false
    private var quietEndWork: DispatchWorkItem?

    private struct Rendered {
        let anchored: AnchoredFinding
        /// AppKit coordinates.
        let rects: [CGRect]
    }
    private var rendered: [Rendered] = []
    /// Every finding placed in the current text, drawn or not (Slack doesn't
    /// always report word positions; the dot lists them anyway).
    private var anchoredFindings: [AnchoredFinding] = []
    private var indicator: WritingIndicatorState = .hidden
    private var indicatorPanel: NSPanel?
    private var listShownFromIndicator = false
    private var cleanUntil: Date = .distantPast
    private let logger = Logger(subsystem: "dev.mimir.app", category: "WritingCheck")
    private var markerPanels: [NSPanel] = []
    private var popupPanel: NSPanel?
    private var activeFinding: AnchoredFinding?
    private var pointerInPopup = false
    private var hideWork: DispatchWorkItem?

    init(store: SettingsStore, model: MimirAppModel) {
        self.store = store
        self.model = model
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        self.checker = WritingChecker(client: AnthropicClient(session: URLSession(configuration: configuration)))
        // Like MenuBarController: no AppKit setup (event monitors, panels)
        // inside App.init — on macOS 26 it breaks clicks on the status item.
        DispatchQueue.main.async { [weak self] in
            self?.observeSettings()
            self?.observePhase()
        }
    }

    // MARK: Settings and lifecycle

    private func observeSettings() {
        withObservationTracking {
            _ = store.settings.writingCheckEnabled
            _ = store.settings.writingAllowedBundleIDs
            _ = store.settings.writingAppScope
            _ = store.settings.writingSkippedBundleIDs
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.applySettings()
                self?.observeSettings()
            }
        }
        applySettings()
    }

    private func applySettings() {
        let settings = store.settings
        policy = settings.writingAppPolicy
        if let observedBundleID, !policy.allows(observedBundleID) {
            detachObserver()
            clearField()
        }
        let enabled = settings.writingCheckEnabled
        let current = policy
        FocusedTextReader.disableElectronAccessibility(keeping: { enabled && current.allows($0) })
        if settings.writingCheckEnabled { start() } else { stop() }
        if isActive { refresh() }
    }

    private func observePhase() {
        withObservationTracking {
            _ = model.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                switch self.model.phase {
                case .recording, .transcribing, .postProcessing, .inserting:
                    self.beginQuietWindow()
                default:
                    break
                }
                self.observePhase()
            }
        }
    }

    /// While Mimir records and pastes, don't touch the target app at all:
    /// Accessibility reads slow apps like Slack down, and a slow app handled
    /// the paste late enough to read the restored (old) clipboard.
    private func beginQuietWindow() {
        quietUntil = Date().addingTimeInterval(2)
        pendingSeed = true
        idleWork?.cancel()
        quietEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        quietEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.05, execute: work)
    }

    private func start() {
        guard !isActive else { return }
        isActive = true
        // Read the key off the main thread (the Keychain may prompt).
        Task.detached {
            AnthropicKeyStore.shared.load()
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutChanged() }
        }
        refresh()
    }

    private func stop() {
        guard isActive else { return }
        isActive = false
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        detachObserver()
        clearField()
        pendingSeed = false
        markerPanels.forEach { $0.orderOut(nil) }
        markerPanels.removeAll()
        indicatorPanel?.orderOut(nil)
        indicatorPanel = nil
        popupPanel?.orderOut(nil)
        popupPanel = nil
    }

    // MARK: Reading

    /// Re-reads the focused field and decides what to check.
    func refresh() {
        guard isActive, !isQuiet else { return }
        guard let current = FocusedTextReader.focusedField(policy: policy) else {
            if field != nil {
                logger.notice("No readable field (frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?", privacy: .public))")
            }
            // A dictation into an app that isn't checked: nothing to seed.
            pendingSeed = false
            clearField()
            return
        }
        if field == nil {
            logger.notice("Field found in \(current.bundleID, privacy: .public), \(current.text.count) chars")
        }
        let previous = field
        let isNewField = previous.map { !$0.isSameField(as: current) } ?? true
        if isNewField {
            closePopup()
            attachObserver(to: current)
        }
        field = current
        // Only what the user types from now on is sent: text already in a
        // field they just focused (an old note, a draft) never leaves the Mac.
        // A field the app re-created mid-typing keeps going (same app, text
        // continues the previous one).
        let continues = previous.map { $0.pid == current.pid && !$0.text.isEmpty && current.text.hasPrefix($0.text) } ?? false
        let seedExisting = isNewField && !continues

        if pendingSeed || seedExisting {
            pendingSeed = false
            scheduler.seedAsChecked(current.text)
            render()
            return
        }
        switch scheduler.textChanged(current.text) {
        case .checkNow(let sentences):
            idleWork?.cancel()
            send(sentences, from: current)
        case .checkWhenIdle:
            scheduleIdleCheck()
        case .nothing:
            idleWork?.cancel()
        }
        render()
    }

    private func scheduleIdleCheck() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isActive,
                      let current = FocusedTextReader.focusedField(policy: self.policy),
                      !self.isQuiet else { return }
                self.field = current
                let sentences = self.scheduler.idleFired(current.text)
                // Dropped (busy, no key, budget): let a later idle try it again.
                if !sentences.isEmpty, !self.send(sentences, from: current) {
                    self.scheduler.requestFailed(for: sentences)
                }
            }
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + WritingCheckScheduler.idleDelay, execute: work)
    }

    private func clearField() {
        idleWork?.cancel()
        layoutWork?.cancel()
        layoutWork = nil
        rectCache = [:]
        rectCacheText = nil
        field = nil
        rendered = []
        anchoredFindings = []
        renderMarkers([])
        setIndicator(.hidden)
        closePopup()
    }

    // MARK: Requests

    /// Returns false when the request was not sent.
    @discardableResult
    private func send(_ sentences: [String], from field: FocusedField) -> Bool {
        // Busy: the refresh after the answer picks up what changed meanwhile.
        guard !requestInFlight else { return false }
        let now = Date()
        guard status.budget.canSend(now: now) else {
            logger.notice("Budget blocks the request (cap or backoff)")
            return false
        }
        guard let apiKey = AnthropicKeyStore.shared.cachedKey else {
            logger.notice("No Anthropic key loaded; skipping")
            return false
        }
        let vocabulary = WritingChecker.vocabularyTerms(from: store.settings.customVocabulary)
        logger.notice("Checking \(sentences.count) sentence(s)")
        setIndicator(.checking)
        let context = Self.context(before: sentences.first ?? "", in: field.text)
        scheduler.markInFlight(sentences)
        status.update { $0.recordSent(now: now) }
        requestInFlight = true
        let checker = self.checker
        Task { [weak self] in
            let started = ContinuousClock.now
            let result: Result<[WritingFinding], Error>
            do {
                result = .success(try await checker.check(sentences: sentences, context: context, vocabulary: vocabulary, apiKey: apiKey))
            } catch {
                result = .failure(error)
            }
            let elapsed = started.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            guard let self else { return }
            self.requestInFlight = false
            switch result {
            case .success(let findings):
                self.logger.notice("Claude returned \(findings.count) finding(s) in \(milliseconds) ms")
                self.scheduler.record(findings, for: sentences)
                if findings.isEmpty { self.cleanUntil = Date().addingTimeInterval(1.5) }
                self.status.update { $0.record(.success, now: Date()) }
            case .failure(let error):
                self.logger.error("Check failed after \(milliseconds) ms: \(String(describing: error), privacy: .public)")
                self.scheduler.requestFailed(for: sentences)
                let outcome: WritingRequestBudget.Outcome
                if case AnthropicClient.Failure.http(let code, _) = error { outcome = .httpStatus(code) } else { outcome = .otherFailure }
                self.status.update { $0.record(outcome, now: Date()) }
            }
            self.refresh()
        }
        return true
    }

    /// Up to 300 characters before the checked text, to resolve references.
    static func context(before sentence: String, in text: String) -> String {
        let ns = text as NSString
        let range = ns.range(of: sentence, options: [.literal, .backwards])
        guard range.location != NSNotFound, range.location > 0 else { return "" }
        let start = max(0, range.location - 300)
        return ns.substring(with: NSRange(location: start, length: range.location - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Accessibility notifications

    private func attachObserver(to field: FocusedField) {
        detachObserver()
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let controller = Unmanaged<WritingCheckController>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXLayoutChangedNotification as String {
                    controller.layoutChanged()
                } else {
                    controller.refresh()
                }
            }
        }
        guard AXObserverCreate(field.pid, callback, &created) == .success, let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXLayoutChangedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(created, field.element, name as CFString, context)
        }
        let app = AXUIElementCreateApplication(field.pid)
        AXObserverAddNotification(created, app, kAXFocusedUIElementChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        observedPID = field.pid
        observedBundleID = field.bundleID
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        observedPID = nil
        observedBundleID = nil
    }

    /// Scroll or layout moved the words: re-place the underlines at most once
    /// per 100 ms, and only when there is something drawn. Scrolling fires
    /// ~60 events a second; each placement asks the app for word positions.
    private func layoutChanged() {
        guard isActive, !isQuiet, field != nil else { return }
        closePopup()
        guard !anchoredFindings.isEmpty else { return }
        rectCache = [:]
        guard layoutWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutWork = nil
                guard self.isActive, !self.isQuiet else { return }
                self.rectCache = [:]
                self.render()
            }
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func cachedRects(for range: NSRange, in field: FocusedField) -> [CGRect] {
        if rectCacheText != field.text {
            rectCache = [:]
            rectCacheText = field.text
        }
        if let cached = rectCache[range] { return cached }
        let rects = FocusedTextReader.rects(for: range, in: field)
        rectCache[range] = rects
        return rects
    }

    // MARK: Drawing

    private func render() {
        guard let field else {
            rendered = []
            renderMarkers([])
            return
        }
        let maxY = primaryScreenMaxY()
        anchoredFindings = scheduler.findings(in: field.text)
        rendered = anchoredFindings.compactMap { anchored in
            let rects = cachedRects(for: anchored.range, in: field).map {
                CGRect(x: $0.minX, y: maxY - $0.minY - $0.height, width: $0.width, height: $0.height)
            }
            return rects.isEmpty ? nil : Rendered(anchored: anchored, rects: rects)
        }
        renderMarkers(rendered.flatMap { item in item.rects.map { ($0, item.anchored.finding.kind) } })
        if anchoredFindings.count != rendered.count {
            logger.notice("\(self.anchoredFindings.count - self.rendered.count) finding(s) without a word position; shown in the dot")
        }
        if Date() < applyFailedUntil {
            setIndicator(.applyFailed)
        } else if requestInFlight {
            setIndicator(.checking)
        } else if !anchoredFindings.isEmpty {
            setIndicator(.issues(anchoredFindings.count))
        } else if Date() < cleanUntil {
            setIndicator(.clean)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.indicator == .clean, Date() >= self.cleanUntil else { return }
                    self.setIndicator(.hidden)
                }
            }
        } else {
            setIndicator(.hidden)
        }
        if listShownFromIndicator {
            if anchoredFindings.isEmpty { closePopup() }
        } else if let activeFinding, !rendered.contains(where: { $0.anchored == activeFinding }) {
            closePopup()
        }
    }

    private func renderMarkers(_ markers: [(CGRect, WritingIssueKind)]) {
        for (index, marker) in markers.enumerated() {
            if index == markerPanels.count {
                let panel = Self.overlayPanel(hasShadow: false)
                panel.ignoresMouseEvents = true
                markerPanels.append(panel)
            }
            let panel = markerPanels[index]
            panel.contentView = NSHostingView(rootView: WritingMarker(kind: marker.1))
            let frame = CGRect(x: marker.0.minX, y: marker.0.minY - 3, width: marker.0.width, height: 3)
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        for panel in markerPanels.dropFirst(markers.count) { panel.orderOut(nil) }
    }

    // MARK: Popup (hover)

    // MARK: Status dot

    private func setIndicator(_ state: WritingIndicatorState) {
        indicator = state
        guard state != .hidden, let field, field.axFrame.width >= 24, field.axFrame.height >= 16 else {
            indicatorPanel?.orderOut(nil)
            return
        }
        let panel = indicatorPanel ?? Self.overlayPanel(hasShadow: false)
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: WritingIndicatorView(state: state))
        // Bottom-right corner, inside the field (AX → AppKit coordinates).
        let frame = CGRect(
            x: field.axFrame.maxX - 26,
            y: primaryScreenMaxY() - field.axFrame.maxY + 6,
            width: 20, height: 20
        )
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        indicatorPanel = panel
    }

    private func mouseMoved(to point: CGPoint) {
        if let dot = indicatorPanel, dot.isVisible, case .issues = indicator,
           dot.frame.insetBy(dx: -4, dy: -4).contains(point) {
            cancelHide()
            if !listShownFromIndicator || popupPanel?.isVisible != true { showList(near: dot.frame) }
            return
        }
        for item in rendered {
            if item.rects.contains(where: { $0.insetBy(dx: -2, dy: -5).contains(point) }) {
                cancelHide()
                if activeFinding != item.anchored || popupPanel?.isVisible != true {
                    activeFinding = item.anchored
                    showPopup(near: item.rects[0])
                }
                return
            }
        }
        scheduleHide()
    }

    /// All fixes of the field, from the status dot.
    private func showList(near anchor: CGRect) {
        guard !anchoredFindings.isEmpty else { return }
        listShownFromIndicator = true
        activeFinding = nil
        let view = WritingFindingsList(
            findings: anchoredFindings.map(\.finding),
            onApply: { [weak self] finding in self?.apply(finding) },
            onIgnore: { [weak self] finding in self?.ignore(finding) },
            onHover: { [weak self] hovering in
                guard let self else { return }
                self.pointerInPopup = hovering
                if hovering { self.cancelHide() } else { self.scheduleHide() }
            }
        )
        present(view, near: anchor)
    }

    private func showPopup(near anchor: CGRect) {
        guard let activeFinding else { return }
        listShownFromIndicator = false
        let view = WritingPopup(
            finding: activeFinding.finding,
            onApply: { [weak self] in self?.apply(activeFinding.finding) },
            onIgnore: { [weak self] in self?.ignore(activeFinding.finding) },
            onHover: { [weak self] hovering in
                guard let self else { return }
                self.pointerInPopup = hovering
                if hovering { self.cancelHide() } else { self.scheduleHide() }
            }
        )
        present(view, near: anchor)
    }

    private func present<V: View>(_ view: V, near anchor: CGRect) {
        let hosting = FirstClickHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: WritingPopup.width, height: max(hosting.fittingSize.height, 1))
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = popupPanel ?? Self.popupPanelWindow()
        panel.contentView = hosting
        panel.setFrame(Self.popupFrame(anchor: anchor, size: size), display: true)
        panel.orderFrontRegardless()
        popupPanel = panel
    }

    private static func popupFrame(anchor: CGRect, size: NSSize) -> NSRect {
        // Above the word (AppKit y grows upward); below only near the top.
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + 6
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            if y + size.height > visible.maxY - 8 { y = anchor.minY - size.height - 6 }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func apply(_ finding: WritingFinding) {
        guard let field,
              let source = FocusedTextReader.currentText(of: field),
              let applied = WritingAnchoring.applying(finding, to: source)
        else {
            closePopup()
            return
        }
        // The edit is the user's choice: don't send the fixed sentence back.
        let fixedSentence = (finding.sentence as NSString).replacingOccurrences(of: finding.original, with: finding.replacement)
        scheduler.seedAsChecked(fixedSentence)
        let replaced = FocusedTextReader.replace(range: applied.range, with: finding.replacement, in: field, source: source, expected: applied.text)
        closePopup()
        if !replaced {
            // The app refused the edit or typed it differently: say so on the
            // dot for 2 s instead of failing silently.
            logger.notice("Apply did not produce the expected text")
            applyFailedUntil = Date().addingTimeInterval(2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.05) { [weak self] in
                MainActor.assumeIsolated { self?.render() }
            }
        }
        refresh()
    }

    private func ignore(_ finding: WritingFinding) {
        scheduler.ignore(finding)
        closePopup()
        render()
    }

    private func scheduleHide() {
        guard popupPanel?.isVisible == true, hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hideWork = nil
                if !self.pointerInPopup { self.closePopup() }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func cancelHide() {
        hideWork?.cancel()
        hideWork = nil
    }

    private func closePopup() {
        cancelHide()
        popupPanel?.orderOut(nil)
        activeFinding = nil
        listShownFromIndicator = false
        pointerInPopup = false
    }

    /// The popup accepts the first click: it may become key (without
    /// activating Mimir, so the app being typed in stays in front).
    private static func popupPanelWindow() -> NSPanel {
        let panel = ClickablePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private static func overlayPanel(hasShadow: Bool) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = hasShadow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    private func primaryScreenMaxY() -> CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY ?? NSScreen.main?.frame.maxY ?? 0
    }
}

private final class ClickablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Without this the first click on an inactive panel only activates it.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum WritingIndicatorState: Equatable {
    case hidden
    case checking
    case issues(Int)
    case clean
    case applyFailed
}

private struct WritingIndicatorView: View {
    let state: WritingIndicatorState
    @State private var pulse = false

    var body: some View {
        ZStack {
            switch state {
            case .checking:
                Circle()
                    .stroke(WritingPalette.lilac, lineWidth: 2)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulse ? 1 : 0.7)
                    .opacity(pulse ? 0.5 : 1)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
                    }
            case .issues(let count):
                Circle().fill(WritingPalette.error)
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
            case .clean:
                Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.4))
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            case .applyFailed:
                Circle().fill(Color.orange)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .help("Could not apply the fix. Edit it by hand.")
            case .hidden:
                EmptyView()
            }
        }
        .frame(width: 18, height: 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Every fix of the field, listed from the status dot.
struct WritingFindingsList: View {
    let findings: [WritingFinding]
    var onApply: (WritingFinding) -> Void
    var onIgnore: (WritingFinding) -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
                if index > 0 { Divider().overlay(Color.white.opacity(0.08)) }
                WritingFindingContent(finding: finding, onApply: { onApply(finding) }, onIgnore: { onIgnore(finding) })
                    .padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .frame(width: WritingPopup.width, alignment: .leading)
        .background(WritingPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .onHover(perform: onHover)
    }
}

private struct WritingMarker: View {
    let kind: WritingIssueKind

    var body: some View {
        Capsule()
            .fill(kind == .phrasing ? WritingPalette.phrasing : WritingPalette.error)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum WritingPalette {
    static let background = Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x16 / 255)
    static let lilac = Color(red: 0xB9 / 255, green: 0xA7 / 255, blue: 0xFF / 255)
    static let error = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let phrasing = Color(red: 0xB9 / 255, green: 0xA7 / 255, blue: 0xFF / 255)
    static let secondaryInk = Color.white.opacity(0.62)
}

struct WritingPopup: View {
    static let width: CGFloat = 300

    let finding: WritingFinding
    var onApply: () -> Void
    var onIgnore: () -> Void
    var onHover: (Bool) -> Void

    var body: some View {
        WritingFindingContent(finding: finding, onApply: onApply, onIgnore: onIgnore)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
        .background(WritingPalette.background)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .onHover(perform: onHover)
    }
}

private struct WritingFindingContent: View {
    let finding: WritingFinding
    var onApply: () -> Void
    var onIgnore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(finding.kind.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(finding.kind == .phrasing ? WritingPalette.lilac : WritingPalette.error)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(finding.original)
                    .strikethrough()
                    .foregroundStyle(WritingPalette.secondaryInk)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(WritingPalette.secondaryInk)
                Text(finding.replacement)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
            }
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
            if !finding.why.isEmpty {
                Text(finding.why)
                    .font(.system(size: 12))
                    .foregroundStyle(WritingPalette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Apply", action: onApply)
                    .buttonStyle(WritingPopupButtonStyle(primary: true))
                Button("Ignore", action: onIgnore)
                    .buttonStyle(WritingPopupButtonStyle(primary: false))
            }
            .padding(.top, 2)
        }
    }
}

private struct WritingPopupButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(primary ? WritingPalette.lilac : Color.white.opacity(0.10))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Display names for allowlisted apps and the running apps that can be added.
@MainActor
enum WritingAppName {
    struct Candidate {
        let bundleID: String
        let name: String
    }

    static func name(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func runningCandidates(excluding: [String]) -> [Candidate] {
        let excluded = Set(excluding).union([Bundle.main.bundleIdentifier ?? ""])
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> Candidate? in
                guard let id = app.bundleIdentifier, !excluded.contains(id), seen.insert(id).inserted else { return nil }
                return Candidate(bundleID: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
