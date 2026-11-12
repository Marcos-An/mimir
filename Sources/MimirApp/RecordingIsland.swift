import AppKit
import Observation
import SwiftUI
import MimirCore

/// Drives the island's appear and disappear animation. The panel stays in
/// place; the pill inside it scales and fades.
@MainActor
@Observable
final class IslandPresentation {
    var isVisible = false
}

@MainActor
final class RecordingIslandController {
    private var panel: NSPanel?
    private let model: MimirAppModel
    private let levelMonitor: AudioLevelMonitor
    private let downloadMonitor: ModelDownloadMonitor
    private let presentation = IslandPresentation()
    private var pendingOrderOut: DispatchWorkItem?

    init(
        model: MimirAppModel,
        levelMonitor: AudioLevelMonitor,
        downloadMonitor: ModelDownloadMonitor
    ) {
        self.model = model
        self.levelMonitor = levelMonitor
        self.downloadMonitor = downloadMonitor
        observeState()
    }

    private func observeState() {
        withObservationTracking {
            _ = model.phase
            _ = model.isFlashingMetrics
            _ = model.sessionNotice
            _ = downloadMonitor.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observeState()
            }
        }
    }

    private func syncVisibility() {
        if downloadMonitor.isActive {
            hide()
            return
        }
        switch model.phase {
        case .recording, .transcribing, .postProcessing, .inserting:
            show()
        default:
            // Um aviso pendente (falha ou "sem fala") mantém a ilha visível:
            // antes ela desaparecia e o usuário não sabia o que aconteceu.
            if model.isFlashingMetrics || model.sessionNotice != nil {
                show()
            } else {
                hide()
            }
        }
    }

    func show() {
        pendingOrderOut?.cancel()
        pendingOrderOut = nil

        if panel == nil {
            let hosting = NSHostingController(
                rootView: RecordingIslandView(
                    model: model,
                    levelMonitor: levelMonitor,
                    presentation: presentation
                )
            )
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: RecordingIslandMetrics.panel),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentViewController = hosting
            panel.setContentSize(RecordingIslandMetrics.panel)
            self.panel = panel
        }
        guard let panel else { return }

        // Reposiciona só quando estava escondido: durante a sessão o usuário
        // pode ter arrastado a ilha e recentrar a cada update desfaria o arrasto.
        if !panel.isVisible {
            presentation.isVisible = false
            positionAtBottomCenter(panel)
            panel.orderFrontRegardless()
            // Next runloop, so the pill animates in from its hidden state.
            DispatchQueue.main.async { [presentation] in
                presentation.isVisible = true
            }
        } else {
            presentation.isVisible = true
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        presentation.isVisible = false
        pendingOrderOut?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.presentation.isVisible else { return }
            self.panel?.orderOut(nil)
        }
        pendingOrderOut = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // The pill is centered in the panel; this keeps its bottom edge ~24 pt
        // above the Dock, where the old island sat.
        let y = visible.minY + 24 - (size.height - RecordingIslandMetrics.pillHeight) / 2
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// The panel is a fixed, transparent stage; the pill sizes itself to its
/// content inside it, so width changes (hover, states) can animate.
enum RecordingIslandMetrics {
    static let panel = NSSize(width: 440, height: 76)
    static let pillHeight: CGFloat = 36
    static let noticeMaxWidth: CGFloat = 320
}

private enum IslandStyle {
    static let background = Color(hex: 0x141416)
    static let lilac = Color(hex: 0xB9A7FF)
    static let recordingRed = Color(hex: 0xFF453A)
    static let resize = Animation.spring(response: 0.28, dampingFraction: 0.95)
    static let appear = Animation.spring(response: 0.3, dampingFraction: 0.92)
}

private struct RecordingIslandView: View {
    @Bindable var model: MimirAppModel
    var levelMonitor: AudioLevelMonitor
    var presentation: IslandPresentation

    @State private var hovering = false
    @State private var recordingStart = Date()

    private var isRecording: Bool { model.phase == .recording }
    private var isPrompt: Bool { model.activeMode == .promptRewrite }
    private var isShowingMetrics: Bool {
        model.phase == .idle && model.isFlashingMetrics && model.lastSessionMetrics != nil
    }
    private var showsButtons: Bool { isRecording && hovering }

    /// Changes whenever the pill's content changes shape, to animate its width.
    private var layoutKey: String {
        "\(model.phase)-\(isPrompt)-\(showsButtons)-\(model.sessionNotice != nil)-\(isShowingMetrics)"
    }

    private var statusLabel: String {
        switch model.phase {
        case .transcribing: "Transcribing"
        case .postProcessing: "Polishing"
        case .inserting: "Pasting"
        default: ""
        }
    }

    var body: some View {
        content
            .padding(.horizontal, showsButtons ? 5 : 14)
            .frame(height: RecordingIslandMetrics.pillHeight)
            .background(Capsule(style: .continuous).fill(IslandStyle.background))
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(isPrompt && isRecording ? IslandStyle.lilac.opacity(0.35) : Color.white.opacity(0.09), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .contentShape(Capsule())
            .onHover { inside in
                withAnimation(IslandStyle.resize) { hovering = inside }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Cancel dictation") {
                if isRecording { Task { try? await model.cancelDictation() } }
            }
            .accessibilityAction(named: "Finish and paste") {
                if isRecording { Task { try? await model.stopDictation() } }
            }
            .animation(IslandStyle.resize, value: layoutKey)
            .scaleEffect(presentation.isVisible ? 1 : 0.92)
            .opacity(presentation.isVisible ? 1 : 0)
            .offset(y: presentation.isVisible ? 0 : 6)
            .animation(IslandStyle.appear, value: presentation.isVisible)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: isRecording, initial: true) { _, recording in
                if recording { recordingStart = .now }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isRecording {
            // The buttons stay in the layout and grow from zero width: the
            // ✕ slides out from behind the dot to the left, the ✓ from behind
            // the timer to the right, mirrored.
            HStack(spacing: 0) {
                IslandButton(kind: .cancel, isPrompt: isPrompt) {
                    Task { try? await model.cancelDictation() }
                }
                .modifier(HoverReveal(shown: showsButtons, edge: .leading))

                HStack(spacing: 10) {
                    if isPrompt {
                        PromptBadge()
                    } else {
                        RecordingDot()
                    }
                    AudioWaveView(
                        levels: levelMonitor.levels,
                        tint: isPrompt ? IslandStyle.lilac : .white.opacity(0.92)
                    )
                    ElapsedTimer(since: recordingStart)
                }
                .padding(.horizontal, showsButtons ? 10 : 0)
                .zIndex(1)

                IslandButton(kind: .finish, isPrompt: isPrompt) {
                    Task { try? await model.stopDictation() }
                }
                .modifier(HoverReveal(shown: showsButtons, edge: .trailing))
            }
            .transition(.opacity)
        } else if let notice = model.sessionNotice {
            SessionNoticeView(notice: notice)
                .transition(.opacity)
        } else if isShowingMetrics, let metrics = model.lastSessionMetrics {
            MetricsFlashView(metrics: metrics)
                .transition(.opacity)
        } else {
            ProcessingProgressView(
                phase: model.phase,
                label: statusLabel,
                accent: isPrompt ? IslandStyle.lilac : .white
            )
            .transition(.opacity)
        }
    }
}

private struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(IslandStyle.recordingRed)
            .frame(width: 8, height: 8)
            .phaseAnimator([1.0, 0.35]) { dot, value in
                dot.opacity(value)
            } animation: { _ in
                .easeInOut(duration: 0.8)
            }
            .accessibilityLabel("Recording")
    }
}

private struct PromptBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkle")
                .font(.system(size: 11, weight: .semibold))
            Text("Prompt")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(IslandStyle.lilac)
        .fixedSize()
    }
}

private struct ElapsedTimer: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let total = max(0, Int(context.date.timeIntervalSince(since)))
            Text(String(format: "%d:%02d", total / 60, total % 60))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize()
        }
    }
}

private struct IslandButton: View {
    enum Kind { case cancel, finish }

    let kind: Kind
    let isPrompt: Bool
    let action: () -> Void

    @State private var hovering = false

    private var label: String {
        kind == .cancel ? "Cancel dictation" : "Finish and paste"
    }

    private var fill: Color {
        switch kind {
        case .cancel: Color.white.opacity(hovering ? 0.22 : 0.13)
        case .finish: (isPrompt ? IslandStyle.lilac : Color.white).opacity(hovering ? 1 : 0.9)
        }
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: kind == .cancel ? "xmark" : "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(kind == .cancel ? Color.white : IslandStyle.background)
                )
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(kind == .cancel ? "Cancel (Esc)" : "Finish and paste")
    }
}

private struct ProcessingProgressView: View {
    let phase: AppPhase
    let label: String
    let accent: Color

    @State private var phaseStart: Date = .now
    @State private var trackedPhase: AppPhase = .idle
    @State private var lastProgress: Double = 0

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: label)
                .fixedSize()

            TimelineView(.animation(minimumInterval: 0.05, paused: false)) { context in
                let value = progress(at: context.date)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(2, 64 * CGFloat(value)))
                }
                .frame(width: 64, height: 3)
            }
            .frame(width: 64, height: 3)
        }
        .onAppear {
            trackedPhase = phase
            phaseStart = .now
            lastProgress = segmentBase(for: phase)
        }
        .onChange(of: phase) { _, newPhase in
            trackedPhase = newPhase
            phaseStart = .now
            // Ao trocar de fase, a barra nunca volta: começa do maior entre onde estava e o início do novo segmento.
            lastProgress = max(lastProgress, segmentBase(for: newPhase))
        }
    }

    // Uma barra única que cobre as três etapas em sequência:
    //   transcribing:    0% → 45%
    //   postProcessing:  45% → 92%
    //   inserting:       92% → 100%
    private func progress(at date: Date) -> Double {
        let (base, span, tau) = segment(for: trackedPhase)
        let elapsed = date.timeIntervalSince(phaseStart)
        guard tau > 0 else { return min(base + span, 0.99) }
        let raw = base + span * (1 - exp(-elapsed / tau))
        // Nunca anda pra trás; trava em 0.99 enquanto a fase final não terminar.
        return min(max(raw, lastProgress), 0.99)
    }

    private func segment(for phase: AppPhase) -> (base: Double, span: Double, tau: Double) {
        switch phase {
        case .transcribing: return (0.0, 0.45, 2.5)
        case .postProcessing: return (0.45, 0.47, 3.5)
        case .inserting: return (0.92, 0.08, 0.3)
        default: return (0.0, 1.0, 1.0)
        }
    }

    private func segmentBase(for phase: AppPhase) -> Double {
        segment(for: phase).base
    }
}

/// History of speech levels, newest on the right. Levels come from
/// `SpeechLevelMeter`, already in a perceptual scale, so bars map linearly.
private struct AudioWaveView: View {
    let levels: [Float]
    var tint: Color = .white

    /// Newest level in the middle, older ones spreading out to both sides and
    /// tapering toward the edges, so the wave reads as one voice shape rather
    /// than a row of unrelated bars.
    private static let sideCount = 6

    private var bars: [CGFloat] {
        let recent = Array(levels.suffix(Self.sideCount + 1).reversed())   // newest first
        return (-Self.sideCount...Self.sideCount).map { position in
            let distance = abs(position)
            let level = distance < recent.count ? CGFloat(max(0, min(1, recent[distance]))) : 0
            let taper = 1 - CGFloat(distance) / CGFloat(Self.sideCount + 2)
            return level * taper
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: barHeight(for: value))
            }
        }
        .frame(height: 18)
        // Glide between audio buffers (~85 ms) and ignore the hover spring,
        // which made the bars flicker while the pill resized.
        .transaction { $0.animation = .linear(duration: 0.1) }
        .accessibilityHidden(true)
    }

    private func barHeight(for value: CGFloat) -> CGFloat {
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 18
        return minHeight + value * (maxHeight - minHeight)
    }
}

/// Falha ou "sem fala": a ilha fica visível alguns segundos com o motivo em vez
/// de desaparecer em silêncio.
private struct SessionNoticeView: View {
    let notice: SessionNotice

    private var isError: Bool {
        if case .error = notice { return true }
        return false
    }

    private var symbolName: String {
        switch notice {
        case .error: "exclamationmark.triangle.fill"
        case .noSpeech: "mic.slash.fill"
        case .audioTooQuiet: "mic.badge.xmark"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isError ? Color.orange : Color.white.opacity(0.7))
            Text(notice.displayText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: RecordingIslandMetrics.noticeMaxWidth)
        .help(notice.displayText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.displayText)
    }
}

private struct MetricsFlashView: View {
    let metrics: SessionMetrics

    var body: some View {
        HStack(spacing: 10) {
            if let audio = metrics.audioSeconds {
                metricItem(symbol: "mic", label: "Recorded", value: DurationFormat.short(audio))
            }
            metricItem(symbol: "text.alignleft", label: "Transcribed in", value: DurationFormat.short(metrics.transcriptionSeconds))
            if let post = metrics.postProcessingSeconds {
                metricItem(symbol: "sparkle", label: "Polished in", value: DurationFormat.short(post))
            }
            if !metrics.streamingUsed {
                let note = "Transcribed the whole file on stop"
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                    .help(note)
                    .accessibilityLabel(note)
            }
        }
    }

    @ViewBuilder
    private func metricItem(symbol: String, label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
        .help("\(label) \(value)")
    }
}

/// Hidden: zero width, tucked inward behind the neighbouring content.
/// Shown: full width at the pill's edge. Animating between the two makes the
/// button travel outward from the middle on both sides.
private struct HoverReveal: ViewModifier {
    let shown: Bool
    let edge: HorizontalEdge

    func body(content: Content) -> some View {
        let inward: CGFloat = edge == .leading ? 12 : -12
        content
            // On the way out the button fades quickly, so it is gone before
            // the pill finishes shrinking; on the way in it fades in a touch
            // after the pill starts opening.
            .opacity(shown ? 1 : 0)
            .animation(
                shown ? .easeOut(duration: 0.2).delay(0.04) : .easeIn(duration: 0.09),
                value: shown
            )
            .scaleEffect(shown ? 1 : 0.85)
            .offset(x: shown ? 0 : inward)
            .frame(width: shown ? 26 : 0, alignment: edge == .leading ? .trailing : .leading)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}

enum DurationFormat {
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 {
            let minutes = total / 60
            let secs = total % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m\(secs)s"
        }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(total)s"
    }
}

private extension Color {
    init(hex: UInt64, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
