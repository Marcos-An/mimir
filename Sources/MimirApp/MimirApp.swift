import AppKit
import AVFoundation
import MimirCore
import Speech
import SwiftUI

@main
struct MimirApp: App {
    @NSApplicationDelegateAdaptor(MimirAppDelegate.self) private var delegate
    @State private var store: SettingsStore
    @State private var model: MimirAppModel
    private let recorder: MacAudioRecorder
    private let hotkey: GlobalHotkeyMonitor
    private let island: RecordingIslandController
    private let menuBar: MenuBarController
    private let writingCheck: WritingCheckController
    @State private var levelMonitor: AudioLevelMonitor
    @State private var downloadMonitor: ModelDownloadMonitor

    init() {
        // Higiene de TMPDIR: WAVs de sessões anteriores que não foram limpos pelo
        // controller (crash, force-quit) ficariam acumulando indefinidamente —
        // áudio bruto da fala é dado sensível, não pode persistir além do uso.
        Task.detached(priority: .background) {
            MacAudioRecorder.purgeOrphanedTemporaryRecordings()
        }

        let store = SettingsStore()
        let levelMonitor = AudioLevelMonitor()
        let downloadMonitor = ModelDownloadMonitor()
        let recorder = MacAudioRecorder(
            inputDeviceUID: store.settings.inputDeviceUID,
            levelMonitor: levelMonitor
        )
        let factory: MimirAppModel.SessionFactory = { settings in
            MimirApp.buildSession(
                settings: settings,
                recorder: recorder,
                downloadMonitor: downloadMonitor
            )
        }
        let model = MimirAppModel(store: store, makeSession: factory)

        let hotkey = GlobalHotkeyMonitor(
            dictationTrigger: store.settings.activationTrigger,
            promptRewriteTrigger: store.settings.promptRewriteActivationTrigger,
            mode: store.settings.activationMode,
            model: model
        )
        let island = RecordingIslandController(
            model: model,
            levelMonitor: levelMonitor,
            downloadMonitor: downloadMonitor
        )
        let menuBar = MenuBarController(
            store: store,
            model: model,
            levelMonitor: levelMonitor,
            downloadMonitor: downloadMonitor
        )
        self.recorder = recorder
        self.hotkey = hotkey
        self.island = island
        self.menuBar = menuBar
        self.writingCheck = WritingCheckController(store: store, model: model)
        _store = State(initialValue: store)
        _model = State(initialValue: model)
        _levelMonitor = State(initialValue: levelMonitor)
        _downloadMonitor = State(initialValue: downloadMonitor)

        Task {
            await model.preloadSession()
        }
    }

    var body: some Scene {
        Window("Mimir", id: "dashboard") {
            DashboardWindowView(store: store, model: model)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    // Window loaded via openWindow; make sure it's key.
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: store.settings) { oldValue, newValue in
                    if oldValue.activationTrigger != newValue.activationTrigger {
                        hotkey.updateDictationTrigger(newValue.activationTrigger)
                    }
                    if oldValue.promptRewriteActivationTrigger != newValue.promptRewriteActivationTrigger {
                        hotkey.updatePromptRewriteTrigger(newValue.promptRewriteActivationTrigger)
                    }
                    if oldValue.activationMode != newValue.activationMode {
                        hotkey.updateMode(newValue.activationMode)
                    }
                    if oldValue.inputDeviceUID != newValue.inputDeviceUID {
                        let uid = newValue.inputDeviceUID
                        Task { await recorder.setInputDeviceUID(uid) }
                    }
                    if needsSessionRebuild(old: oldValue, new: newValue) {
                        model.rebuildSession()
                        Task { await model.preloadSession() }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to Mimir", id: "welcome") {
            WelcomeView(store: store, model: model, downloadMonitor: downloadMonitor)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(WelcomeView.hasCompleted ? .suppressed : .presented)
    }

    private func needsSessionRebuild(old: AppSettings, new: AppSettings) -> Bool {
        old.transcriptionProvider != new.transcriptionProvider
            || old.transcriptionStrategy != new.transcriptionStrategy
            || old.whisperKitModel != new.whisperKitModel
            || old.postProcessingProvider != new.postProcessingProvider
            || old.promptPostProcessingProvider != new.promptPostProcessingProvider
            || old.postProcessingStyle != new.postProcessingStyle
            || old.customVocabulary != new.customVocabulary
            || old.insertionStrategy != new.insertionStrategy
            || old.shouldAutoPaste != new.shouldAutoPaste
            || old.keepsRecentRecordings != new.keepsRecentRecordings
            || old.preferredLanguage != new.preferredLanguage
            || old.activationMode != new.activationMode
    }

    @MainActor
    private static func buildSession(
        settings: AppSettings,
        recorder: any AudioRecording,
        downloadMonitor: ModelDownloadMonitor
    ) -> any DictationControlling {
        let speechToText: any SpeechToTextProviding = switch settings.transcriptionProvider {
        case .appleSpeech:
            AppleSpeechProvider()
        case .whisperKit:
            WhisperKitProvider(
                model: settings.whisperKitModel,
                strategy: settings.transcriptionStrategy,
                vocabulary: settings.customVocabulary,
                downloadMonitor: downloadMonitor
            )
        case .mlxWhisper, .whisperCPP, .fasterWhisper:
            AppleSpeechProvider()
        }

        func makePostProcessor(_ provider: PostProcessingProvider) -> (any TextPostProcessing)? {
            switch provider {
            case .disabled:
                nil
            case .anthropic:
                AnthropicPostProcessor(style: settings.postProcessingStyle, customVocabulary: settings.customVocabulary)
            case .mlx:
                // Both modes on local AI share one loaded model (SharedModelLoader).
                MLXPostProcessor(style: settings.postProcessingStyle, customVocabulary: settings.customVocabulary, downloadMonitor: downloadMonitor)
            }
        }

        let pipeline = LocalPipeline(
            speechToText: speechToText,
            postProcessor: makePostProcessor(settings.postProcessingProvider),
            promptPostProcessor: makePostProcessor(settings.promptPostProcessingProvider),
            textInserter: ClipboardPasteInserter(autoPaste: settings.shouldAutoPaste)
        )

        return DictationSessionController(
            settings: settings,
            recorder: recorder,
            pipeline: pipeline
        )
    }
}


/// Settings content, one page per section. Rows run edge to edge with hairline
/// dividers; the sheet chrome (sidebar, title, close) lives in `SettingsSheetView`.
@MainActor
struct SettingsSections {
    @Bindable var store: SettingsStore

    var generalSection: some View {
        VStack(spacing: 0) {
            KeyBindingRecorderRow(
                title: "Dictate",
                binding: $store.settings.activationTrigger,
                otherBinding: store.settings.promptRewriteActivationTrigger,
                otherName: "Prompt"
            )
            KeyBindingRecorderRow(
                title: "Prompt",
                subtitle: "Speak and get a clean prompt back.",
                binding: $store.settings.promptRewriteActivationTrigger,
                otherBinding: store.settings.activationTrigger,
                otherName: "Dictate"
            )
            SettingsRow(title: "Activation") {
                SegmentedPicker(
                    selection: $store.settings.activationMode,
                    options: [(.tapToToggle, "Tap"), (.holdToTalk, "Hold")]
                )
            }
            AppearanceRow()
            MimirDropdown(
                title: "Spoken language",
                selection: Binding(
                    get: { store.settings.preferredLanguage },
                    set: { store.settings.preferredLanguage = $0 }
                ),
                options: LanguageOption.supported.map { ($0.code, $0.displayName) }
            )
        }
    }

    var audioSection: some View {
        VStack(spacing: 0) {
            MicrophonePickerRow(store: store)
        }
    }

    var pipelineSection: some View {
        VStack(spacing: 0) {
            SettingsGroupLabel("Transcription")
            MimirDropdown(
                title: "Provider",
                selection: $store.settings.transcriptionProvider,
                options: TranscriptionProvider.allCases.map { ($0, $0.displayName + ($0.isAvailable ? "" : " (coming soon)")) }
            )
            MimirDropdown(
                title: "Strategy",
                selection: $store.settings.transcriptionStrategy,
                options: TranscriptionStrategy.allCases.map { ($0, $0.displayName) }
            )
            MimirDropdown(
                title: "Model",
                selection: $store.settings.whisperKitModel,
                options: WhisperKitModel.allCases.map { ($0, $0.displayName) }
            )

            SettingsGroupLabel("Cleanup")
            MimirDropdown(
                title: "Dictation",
                selection: $store.settings.postProcessingProvider,
                options: PostProcessingProvider.allCases.map { ($0, $0.displayName) }
            )
            MimirDropdown(
                title: "Prompt",
                selection: $store.settings.promptPostProcessingProvider,
                options: PostProcessingProvider.allCases.map { ($0, $0.displayName) }
            )
            if store.settings.postProcessingProvider != .disabled {
                MimirDropdown(
                    title: "Dictation style",
                    selection: $store.settings.postProcessingStyle,
                    options: PostProcessingStyle.allCases.map { ($0, $0.displayName) }
                )
            }
            if let cloudNote {
                SettingsRow(title: "Leaves your Mac", subtitle: cloudNote) { EmptyView() }
            }
            if store.settings.postProcessingProvider.isCloud || store.settings.promptPostProcessingProvider.isCloud {
                AnthropicAPIKeyRow()
            }
            CustomVocabularyRow(text: $store.settings.customVocabulary)

            SettingsGroupLabel("Insertion")
            SettingsRow(title: "Paste automatically") {
                Toggle("Paste automatically", isOn: $store.settings.shouldAutoPaste)
                    .toggleStyle(SettingsSwitchStyle())
            }
            SettingsRow(
                title: "Keep recent recordings",
                subtitle: "Last \(RecordingArchive.maxRecordings), for diagnosing transcription errors."
            ) {
                Toggle("Keep recent recordings", isOn: $store.settings.keepsRecentRecordings)
                    .toggleStyle(SettingsSwitchStyle())
            }
        }
    }

    /// Says plainly when transcribed text is sent to Anthropic. Audio never is.
    private var cloudNote: String? {
        let dictation = store.settings.postProcessingProvider.isCloud
        let prompt = store.settings.promptPostProcessingProvider.isCloud
        switch (dictation, prompt) {
        case (true, true): return "The text of every dictation and prompt is sent to Anthropic. Audio stays here."
        case (true, false): return "The text of every dictation is sent to Anthropic. Audio stays here."
        case (false, true): return "The text of every prompt is sent to Anthropic. Audio stays here."
        case (false, false): return nil
        }
    }

    var writingSection: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "Check my writing",
                subtitle: "Underlines mistakes while you type. Hover an underline to see the fix and why."
            ) {
                Toggle("Check my writing", isOn: $store.settings.writingCheckEnabled)
                    .toggleStyle(SettingsSwitchStyle())
            }
            if store.settings.writingCheckEnabled {
                SettingsRow(
                    title: "Leaves your Mac",
                    subtitle: "What you type in the checked apps is sent to Anthropic (Claude). Password fields never are."
                ) { EmptyView() }
                AnthropicAPIKeyRow()
                if ClaudeCreditsState.shared.isOutOfCredits {
                    SettingsRow(
                        title: "Out of credits",
                        subtitle: ClaudeCreditsState.message,
                        subtitleColor: .red
                    ) {
                        Button("Add credits") { NSWorkspace.shared.open(ClaudeCreditsState.billingURL) }
                            .buttonStyle(SecondaryCapsuleButtonStyle())
                            .pointerStyle(.link)
                    }
                }
                SettingsRow(
                    title: "Checks today",
                    subtitle: WritingCheckStatus.shared.keyRejected
                        ? "Claude rejected the API key. Save a new key to resume."
                        : "Stops for the day at the limit, so a bug can't run up costs.",
                    subtitleColor: WritingCheckStatus.shared.keyRejected ? .red : MimirTheme.tertiaryInk
                ) {
                    Text("\(WritingCheckStatus.shared.requestsToday) of \(WritingCheckStatus.shared.dailyCap.formatted())")
                        .font(.system(size: 14).monospacedDigit())
                        .foregroundStyle(MimirTheme.secondaryInk)
                }
            }
            SettingsGroupLabel("Apps")
            SettingsRow(
                title: "Check in",
                subtitle: store.settings.writingAppScope == .allApps
                    ? "Every app except terminals, code editors and password managers."
                    : "Only the apps listed below."
            ) {
                SegmentedPicker(
                    selection: $store.settings.writingAppScope,
                    options: [(.allApps, "All apps"), (.listedApps, "Only these")]
                )
            }
            if store.settings.writingAppScope == .allApps {
                writingAppList(
                    $store.settings.writingSkippedBundleIDs,
                    addTitle: "Skip an app",
                    addSubtitle: "Apps you never want checked.",
                    alsoExcluding: WritingAppPolicy.alwaysSkipped
                )
            } else {
                writingAppList(
                    $store.settings.writingAllowedBundleIDs,
                    addTitle: "Add an app",
                    addSubtitle: "Only apps you list here are checked.",
                    alsoExcluding: WritingAppPolicy.alwaysSkipped
                )
            }
        }
    }

    @ViewBuilder
    private func writingAppList(_ bundleIDs: Binding<[String]>, addTitle: String, addSubtitle: String, alsoExcluding: Set<String>) -> some View {
        ForEach(bundleIDs.wrappedValue, id: \.self) { bundleID in
            SettingsRow(title: WritingAppName.name(for: bundleID)) {
                Button("Remove") {
                    bundleIDs.wrappedValue.removeAll { $0 == bundleID }
                }
                .buttonStyle(SecondaryCapsuleButtonStyle())
                .pointerStyle(.link)
            }
        }
        SettingsRow(title: addTitle, subtitle: addSubtitle) {
            Menu("Running apps") {
                ForEach(WritingAppName.runningCandidates(excluding: bundleIDs.wrappedValue + Array(alsoExcluding)), id: \.bundleID) { app in
                    Button(app.name) { bundleIDs.wrappedValue.append(app.bundleID) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    var permissionsSection: some View {
        PermissionsSettingsCard()
    }

    var aboutSection: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "Mimir",
                subtitle: "Local dictation. Audio never leaves this Mac; optional cloud polishing sends only the transcribed text."
            ) { EmptyView() }
        }
    }
}

// MARK: - Settings building blocks

/// One settings row: title (and optional subtitle) on the left, control on the
/// right, hairline below. Rows span the full width of the content pane.
private struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var subtitleColor: Color = MimirTheme.tertiaryInk
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(MimirTheme.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(subtitleColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { MimirTheme.hairline.frame(height: 1) }
    }
}

private struct SettingsGroupLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MimirTheme.tertiaryInk)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { MimirTheme.hairline.frame(height: 1) }
    }
}

private struct SegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.0 == selection
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? MimirTheme.ink : MimirTheme.secondaryInk)
                        .padding(.horizontal, 14)
                        .frame(height: 28)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(MimirTheme.surfaceRaised)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MimirTheme.softFill))
    }
}

/// Neutral switch: dark gray when on, light gray when off. Cobalt stays
/// reserved for the user's own actions.
private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? MimirTheme.switchOn : MimirTheme.switchOff)
                    .frame(width: 44, height: 26)
                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                    .frame(width: 22, height: 22)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// Gray pill that opens a menu of options.
private struct DropdownMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    @State private var hovering = false

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? ""
    }

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option.1) { selection = option.0 }
            }
        } label: {
            HStack(spacing: 12) {
                Text(currentLabel)
                    .font(.system(size: 14))
                    .foregroundStyle(MimirTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MimirTheme.secondaryInk)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(hovering ? MimirTheme.softFillStrong : MimirTheme.softFill)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .menuIndicator(.hidden)
        .frame(maxWidth: 300, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
    }
}

/// Field to paste or replace the Anthropic API key. The key goes to a private
/// file (see `AnthropicAPIKey`, never UserDefaults); the row only shows whether
/// a key exists, never its value.
private struct AnthropicAPIKeyRow: View {
    @State private var draft: String = ""
    @State private var hasStoredKey: Bool = AnthropicAPIKey.hasStoredKey()
    @State private var feedback: String?
    @State private var editing = false

    var body: some View {
        SettingsRow(
            title: "Anthropic API key",
            subtitle: feedback ?? "Only text is sent. Audio stays on this Mac."
        ) {
            if editing {
                HStack(spacing: 8) {
                    SecureField(hasStoredKey ? "Paste a new key" : "sk-ant-...", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .pointerStyle(.link)
                        .disabled(trimmedDraft.isEmpty)
                    if hasStoredKey {
                        Button("Remove") {
                            AnthropicAPIKey.delete()
                            WritingCheckStatus.shared.keyChanged()
                            hasStoredKey = false
                            feedback = "Key removed."
                            editing = false
                        }
                        .buttonStyle(SecondaryCapsuleButtonStyle())
                        .pointerStyle(.link)
                    }
                    Button {
                        draft = ""
                        editing = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MimirTheme.tertiaryInk)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                    .accessibilityLabel("Cancel")
                }
            } else {
                Button {
                    feedback = nil
                    editing = true
                } label: {
                    HStack(spacing: 10) {
                        Text(hasStoredKey ? "Saved" : "Not set")
                            .font(.system(size: 14))
                            .foregroundStyle(hasStoredKey ? MimirTheme.ink : MimirTheme.tertiaryInk)
                        Image(systemName: "pencil")
                            .font(.system(size: 12))
                            .foregroundStyle(MimirTheme.secondaryInk)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel(hasStoredKey ? "Replace API key" : "Add API key")
            }
        }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        if AnthropicAPIKey.write(trimmedDraft) {
            WritingCheckStatus.shared.keyChanged()
            draft = ""
            hasStoredKey = true
            feedback = "Key saved."
            editing = false
        } else {
            feedback = "Could not save the key."
        }
    }
}

/// Glossary of names Whisper should spell the user's way. Collapsed it shows
/// the term count; editing opens the plain one-term-per-line text.
private struct CustomVocabularyRow: View {
    @Binding var text: String
    @State private var editing = false
    /// Edits stay local until Done: every change to settings rebuilds the
    /// dictation session, which must not happen on each keystroke.
    @State private var draft = ""

    private var termCount: Int {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    private var summary: String {
        switch termCount {
        case 0: return "None"
        case 1: return "1 term"
        default: return "\(termCount) terms"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow(
                title: "Custom vocabulary",
                subtitle: editing ? "One term per line: people, projects, product names." : nil
            ) {
                Button {
                    if editing {
                        commitDraft()
                    } else {
                        draft = text
                    }
                    editing.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Text(editing ? "Done" : summary)
                            .font(.system(size: 14))
                            .foregroundStyle(MimirTheme.ink)
                        if !editing {
                            Image(systemName: "pencil")
                                .font(.system(size: 12))
                                .foregroundStyle(MimirTheme.secondaryInk)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .accessibilityLabel(editing ? "Done editing vocabulary" : "Edit custom vocabulary")
            }
            if editing {
                TextEditor(text: $draft)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(MimirTheme.ink)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 120)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MimirTheme.softFill))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) { MimirTheme.hairline.frame(height: 1) }
            }
        }
        .onDisappear {
            if editing { commitDraft() }
        }
    }

    private func commitDraft() {
        if draft != text { text = draft }
    }
}

private struct MimirDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var subtitle: String? = nil

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            DropdownMenu(selection: $selection, options: options)
        }
    }
}

private struct PermissionsSettingsCard: View {
    @Environment(\.openWindow) private var openWindow
    @State private var snapshot = PermissionSnapshot.current()
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            InteractivePermissionRow(title: "Microphone", description: "Required to record audio.", state: snapshot.microphone, buttonTitle: "Request") {
                Task {
                    do {
                        try await PermissionCoordinator.ensureMicrophoneAccess()
                        feedback = "Microphone permission updated."
                    } catch {
                        feedback = error.localizedDescription
                    }
                    snapshot = PermissionSnapshot.current()
                }
            }

            InteractivePermissionRow(title: "Speech recognition", description: "Required to use Apple Speech on-device.", state: snapshot.speech, buttonTitle: "Request") {
                Task {
                    do {
                        try await PermissionCoordinator.ensureSpeechAccess()
                        feedback = "Speech permission updated."
                    } catch {
                        feedback = error.localizedDescription
                    }
                    snapshot = PermissionSnapshot.current()
                }
            }

            InteractivePermissionRow(title: "Accessibility", description: "Required to paste into the focused app.", state: snapshot.accessibility, buttonTitle: "Open prompt") {
                do {
                    _ = try PermissionCoordinator.ensureAccessibilityAccess(prompt: true)
                    feedback = "Accessibility request sent to the system."
                } catch {
                    feedback = error.localizedDescription
                }
                snapshot = PermissionSnapshot.current()
            }

            InteractivePermissionRow(title: "Input monitoring", description: "Required to listen for the shortcut in other apps.", state: snapshot.inputMonitoring, buttonTitle: "Request") {
                let granted = PermissionCoordinator.ensureInputMonitoring()
                feedback = granted ? "Input monitoring granted." : "macOS hasn't granted input monitoring yet."
                snapshot = PermissionSnapshot.current()
            }

            SettingsRow(title: "Setup guide", subtitle: "Walk through permissions and the shortcut again.") {
                Button("Open") { openWindow(id: "welcome") }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .pointerStyle(.link)
            }

            if let feedback {
                Text(feedback)
                    .font(.system(size: 12))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
            }
        }
        .task {
            snapshot = PermissionSnapshot.current()
        }
    }
}

private struct InteractivePermissionRow: View {
    let title: String
    let description: String
    let state: PermissionState
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: description) {
            HStack(spacing: 14) {
                Text(state.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(state.color)
                Button(buttonTitle, action: action)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .pointerStyle(.link)
            }
        }
    }
}

/// Records a global shortcut in place. Click the keys to start; the keys show
/// up live while held; releasing them (or completing a key combination) saves
/// immediately. Esc or a click on the field cancels. A shortcut already taken by
/// the other action is refused with an inline message and recording continues.
private struct KeyBindingRecorderRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var binding: KeyBinding
    var otherBinding: KeyBinding? = nil
    var otherName: String = ""

    @State private var isRecording = false
    @State private var captured: KeyBinding?
    @State private var liveModifiers: UInt = 0
    @State private var waitingForRelease = false
    @State private var monitor: Any?
    @State private var pulse = false
    @State private var justSaved = false
    @State private var conflict: String?
    @State private var recorderID = UUID()

    var body: some View {
        SettingsRow(
            title: title,
            subtitle: rowSubtitle,
            subtitleColor: conflict == nil ? MimirTheme.tertiaryInk : MimirTheme.red
        ) {
            if isRecording {
                recordingField
            } else {
                idleKeys
            }
        }
        .onDisappear { stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: .keyBindingRecordingStarted)) { note in
            // Only one row records at a time. The other row keeps hotkeys
            // paused, so this one stops without announcing it.
            guard isRecording, (note.object as? UUID) != recorderID else { return }
            stopRecording(notify: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // Keys pressed in another app never reach the local monitor; leaving
            // the recorder open would keep global hotkeys paused.
            if isRecording { stopRecording() }
        }
    }

    private var rowSubtitle: String? {
        if let conflict { return conflict }
        if isRecording { return "Press the new keys. Esc cancels." }
        return subtitle
    }

    private var idleKeys: some View {
        Button {
            startRecording()
        } label: {
            HStack(spacing: 8) {
                if justSaved {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MimirTheme.green)
                        .transition(.opacity)
                }
                KeycapRow(caps: binding.keyCaps)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Click to record a new shortcut")
        .accessibilityLabel("\(title) shortcut, \(binding.keyCaps.joined(separator: " ")). Click to change.")
    }

    private var recordingField: some View {
        Button {
            stopRecording()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(MimirIdentity.brandBlue)
                    .frame(width: 7, height: 7)
                    .opacity(pulse ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
                if waitingForRelease {
                    Text("Release the keys first…")
                        .font(.system(size: 13))
                        .foregroundStyle(MimirTheme.tertiaryInk)
                } else if let caps = captured?.keyCaps, !caps.isEmpty {
                    KeycapRow(caps: caps)
                } else {
                    Text("Press new shortcut")
                        .font(.system(size: 13))
                        .foregroundStyle(MimirTheme.tertiaryInk)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: 230, height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MimirTheme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(conflict == nil ? MimirTheme.fieldBorder : MimirTheme.red, lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help("Click or press Esc to cancel")
        .accessibilityLabel("Recording \(title) shortcut. Press Esc to cancel.")
        .onAppear { pulse = true }
    }

    private func commit(_ candidate: KeyBinding) {
        if let otherBinding, Self.isSameShortcut(candidate, otherBinding) {
            conflict = "\(candidate.keyCaps.joined(separator: " + ")) is already used by \(otherName). Try another."
            captured = nil
            return
        }
        binding = candidate
        stopRecording()
        withAnimation(.easeOut(duration: 0.15)) { justSaved = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) { justSaved = false }
        }
    }

    static func isSameShortcut(_ lhs: KeyBinding, _ rhs: KeyBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers && lhs.deviceMask == rhs.deviceMask
    }

    private func startRecording() {
        captured = nil
        // Se o usuário chegar aqui com modificadores já segurados (ex.: Karabiner mapeando
        // uma tecla para "Hyper"), ignoramos esse estado inicial. A captura só começa
        // depois que tudo for solto.
        let initial = NSEvent.modifierFlags.rawValue & Self.standardModifiersMask
        liveModifiers = initial
        waitingForRelease = initial != 0
        isRecording = true
        NotificationCenter.default.post(name: .keyBindingRecordingStarted, object: recorderID)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // Preserve the exact AppKit event order for fast modifier + key chords.
            MainActor.assumeIsolated {
                self.handleRecordingEvent(event)
            }
            return nil
        }
    }

    private func stopRecording(notify: Bool = true) {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        captured = nil
        liveModifiers = 0
        waitingForRelease = false
        conflict = nil
        pulse = false
        if notify {
            NotificationCenter.default.post(name: .keyBindingRecordingStopped, object: nil)
        }
    }

    // Bits dos 5 modificadores que nos interessam. Exclui capsLock, numericPad, help e outros.
    private static let standardModifiersMask: UInt =
        (1 << 17) | // shift
        (1 << 18) | // control
        (1 << 19) | // option
        (1 << 20) | // command
        (1 << 23)   // function

    private func handleRecordingEvent(_ event: NSEvent) {
        if event.type == .flagsChanged {
            let prev = liveModifiers
            let raw = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let now = raw & Self.standardModifiersMask

            liveModifiers = now

            // Se iniciamos com modificadores já segurados, esperamos que sejam soltos
            // antes de aceitar qualquer captura. Caso contrário, um "Hyper" mapeado
            // contaminaria a captura com bits indesejados.
            if waitingForRelease {
                if now == 0 { waitingForRelease = false }
                return
            }

            // Tudo solto: o que foi segurado vira o atalho.
            if now == 0 {
                if let captured { commit(captured) }
                return
            }

            // Nova sessão: começou a pressionar do zero → limpa estado anterior.
            if prev == 0 {
                captured = nil
            }

            // Soltando parte do acorde: mantém o acorde completo já capturado.
            if popCount(now) < popCount(prev) { return }

            if popCount(now) == 1,
               KeyBinding.modifierKeyCodes.contains(event.keyCode),
               Self.isModifierPressed(event: event, keyCode: event.keyCode) {
                captured = KeyBinding(
                    keyCode: event.keyCode,
                    modifiers: 0,
                    label: Self.modifierOnlyLabel(for: event.keyCode)
                )
            } else {
                let rawFlags = event.modifierFlags.rawValue
                let deviceMask = Self.deviceSpecificModifierMask(from: rawFlags)
                captured = KeyBinding(
                    keyCode: 0,
                    modifiers: now,
                    label: deviceMask == nil
                        ? Self.modifiersOnlyLabel(from: now)
                        : Self.deviceSpecificModifiersLabel(from: deviceMask!),
                    deviceMask: deviceMask
                )
            }
            return
        }

        if event.type == .keyDown {
            if waitingForRelease { return }
            if event.keyCode == 53 {
                stopRecording()
                return
            }
            guard !KeyBinding.modifierKeyCodes.contains(event.keyCode) else { return }
            let flagsMasked = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue & Self.standardModifiersMask
            let label = Self.combinationLabel(keyCode: event.keyCode, modifiers: NSEvent.ModifierFlags(rawValue: flagsMasked), event: event)
            commit(.recordedCombination(keyCode: event.keyCode, modifiers: flagsMasked, label: label))
            return
        }
    }

    private func popCount(_ value: UInt) -> Int {
        var v = value
        var count = 0
        while v != 0 {
            count += Int(v & 1)
            v >>= 1
        }
        return count
    }

    private static func isModifierPressed(event: NSEvent, keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55: return event.modifierFlags.contains(.command)
        case 58, 61: return event.modifierFlags.contains(.option)
        case 59, 62: return event.modifierFlags.contains(.control)
        case 56, 60: return event.modifierFlags.contains(.shift)
        case 63: return event.modifierFlags.contains(.function)
        default: return false
        }
    }

    private static func modifiersOnlyLabel(from modifiers: UInt) -> String {
        var parts: [String] = []
        if modifiers & (1 << 18) != 0 { parts.append("⌃") }
        if modifiers & (1 << 19) != 0 { parts.append("⌥") }
        if modifiers & (1 << 17) != 0 { parts.append("⇧") }
        if modifiers & (1 << 20) != 0 { parts.append("⌘") }
        if modifiers & (1 << 23) != 0 { parts.append("fn") }
        return parts.joined()
    }

    private static func deviceSpecificModifierMask(from rawFlags: UInt) -> UInt? {
        // Device-specific bits from NSEvent's raw modifier flags. These let us
        // preserve side-specific modifier chords such as Right ⌥ + Left ⇧.
        let known: UInt = 0x00000001 | // left control
            0x00002000 | // right control
            0x00000020 | // left option
            0x00000040 | // right option
            0x00000002 | // left shift
            0x00000004 | // right shift
            0x00000008 | // left command
            0x00000010   // right command
        let mask = rawFlags & known
        return mask == 0 ? nil : mask
    }

    private static func deviceSpecificModifiersLabel(from deviceMask: UInt) -> String {
        var parts: [String] = []
        if deviceMask & 0x00000001 != 0 { parts.append("Left ⌃") }
        if deviceMask & 0x00002000 != 0 { parts.append("Right ⌃") }
        if deviceMask & 0x00000020 != 0 { parts.append("Left ⌥") }
        if deviceMask & 0x00000040 != 0 { parts.append("Right ⌥") }
        if deviceMask & 0x00000002 != 0 { parts.append("Left ⇧") }
        if deviceMask & 0x00000004 != 0 { parts.append("Right ⇧") }
        if deviceMask & 0x00000008 != 0 { parts.append("Left ⌘") }
        if deviceMask & 0x00000010 != 0 { parts.append("Right ⌘") }
        return parts.joined(separator: " + ")
    }

    private static func modifierOnlyLabel(for keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right ⌘"
        case 55: return "Left ⌘"
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "fn"
        default: return "Key \(keyCode)"
        }
    }

    private static func combinationLabel(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.function) { parts.append("fn") }
        parts.append(keyName(keyCode: keyCode, event: event))
        return parts.joined()
    }

    private static func keyName(keyCode: UInt16, event: NSEvent) -> String {
        if let named = specialKeyName(keyCode: keyCode) {
            return named
        }
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
            return chars.uppercased()
        }
        return "Key \(keyCode)"
    }

    private static func specialKeyName(keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "⎋"
        case 76: return "⌤"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default: return nil
        }
    }
}


/// Shortcut keys as small gray caps joined by "+". A side-specific modifier
/// such as "Right ⌥" is one key, so it stays one cap.
struct KeycapRow: View {
    let caps: [String]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(caps.enumerated()), id: \.offset) { index, cap in
                Text(cap)
                    .font(.system(size: 13))
                    .foregroundStyle(MimirTheme.ink)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .frame(minWidth: 28, minHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MimirTheme.softFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.line(0.08), lineWidth: 1)
                    )
                if index < caps.count - 1 {
                    Text("+")
                        .font(.system(size: 12))
                        .foregroundStyle(MimirTheme.tertiaryInk)
                }
            }
        }
    }
}

private struct MicrophonePickerRow: View {
    @Bindable var store: SettingsStore
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        SettingsRow(title: "Microphone", subtitle: "Automatic uses the system default.") {
            HStack(spacing: 8) {
                DropdownMenu(
                    selection: Binding(
                        get: { store.settings.inputDeviceUID },
                        set: { store.settings.inputDeviceUID = $0 }
                    ),
                    options: microphoneOptions
                )
                Button {
                    devices = AudioInputDevice.allInputs()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MimirTheme.secondaryInk)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(MimirTheme.softFill))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help("Refresh microphones")
                .accessibilityLabel("Refresh microphones")
            }
        }
        .onAppear {
            devices = AudioInputDevice.allInputs()
        }
    }

    private var microphoneOptions: [(String?, String)] {
        let systemDefault = AudioInputDevice.systemDefaultInput()
        let autoLabel = systemDefault.map { "Automatic (\($0.name))" } ?? "Automatic (system)"
        var items: [(String?, String)] = [(nil, autoLabel)]
        for device in devices {
            items.append((device.uid, device.name))
        }
        if let uid = store.settings.inputDeviceUID,
           !devices.contains(where: { $0.uid == uid }) {
            items.append((uid, "Unavailable device (\(uid))"))
        }
        return items
    }
}

struct SecondaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(MimirTheme.ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? MimirTheme.softFillStrong : MimirTheme.softFill)
            )
    }
}

struct PermissionSnapshot {
    let microphone: PermissionState
    let speech: PermissionState
    let accessibility: PermissionState
    let inputMonitoring: PermissionState

    static func current() -> PermissionSnapshot {
        PermissionSnapshot(
            microphone: PermissionState.microphone,
            speech: PermissionState.speech,
            accessibility: PermissionCoordinator.isAccessibilityGranted ? .granted : .missing,
            inputMonitoring: PermissionCoordinator.isInputMonitoringGranted ? .granted : .missing
        )
    }
}

enum PermissionState {
    case granted
    case missing
    case pending

    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .pending
        default: return .missing
        }
    }

    static var speech: PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .notDetermined: return .pending
        default: return .missing
        }
    }

    var label: String {
        switch self {
        case .granted: return "OK"
        case .missing: return "Missing"
        case .pending: return "Pending"
        }
    }

    var color: Color {
        switch self {
        case .granted: return MimirTheme.green
        case .missing: return MimirTheme.red
        case .pending: return MimirTheme.orange
        }
    }
}

/// Settings palette: neutral light grays with near-black ink, chosen for
/// legibility. The history window uses `MimirIdentity` instead.
enum MimirTheme {
    static let surface = Color.adaptive(0xFFFFFF, 0x232326)
    static let surfaceRaised = Color.adaptive(0xFFFFFF, 0x3A3A3E)
    static let surfaceSunken = Color.adaptive(0xF2F2F4, 0x2B2B2E)
    static let sidebar = Color.adaptive(0xFAFAFB, 0x1C1C1F)

    // Typography
    static let ink = Color.adaptive(0x1D1D1F, 0xF2F2F4)
    static let secondaryInk = Color.adaptive(0x55555C, 0xB4B4BB)
    static let tertiaryInk = Color.adaptive(0x6E6E73, 0x8E8E93)

    // Fills and hairlines
    static let softFill = Color.adaptive(0xF2F2F4, 0x2B2B2E)
    static let softFillStrong = Color.adaptive(0xE8E8EC, 0x36363A)
    static let hairline = Color.line(0.07)
    static let fieldBorder = Color.adaptive(0xC7C7CC, 0x48484A)
    static let switchOn = Color.adaptive(0x4A4A4E, 0x8E8E93)
    static let switchOff = Color.adaptive(0xE5E5EA, 0x39393D)

    // Status, tuned for contrast on white (light) and on #232326 (dark)
    static let green = Color.adaptive(0x1F8A4C, 0x30D158)
    static let orange = Color.adaptive(0xB86E00, 0xFF9F0A)
    static let red = Color.adaptive(0xC9302C, 0xFF6961)
}

/// System / Light / Dark, applied the moment it changes.
private struct AppearanceRow: View {
    @AppStorage(MimirAppearance.key) private var raw = MimirAppearance.system.rawValue

    var body: some View {
        SettingsRow(title: "Appearance") {
            SegmentedPicker(
                selection: Binding(
                    get: { MimirAppearance(rawValue: raw) ?? .system },
                    set: { raw = $0.rawValue; $0.apply() }
                ),
                options: MimirAppearance.allCases.map { ($0, $0.title) }
            )
        }
    }
}

