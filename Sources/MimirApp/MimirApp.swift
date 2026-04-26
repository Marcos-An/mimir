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
    private let hermesIsland: HermesIslandController
    private let menuBar: MenuBarController
    @State private var levelMonitor: AudioLevelMonitor
    @State private var downloadMonitor: ModelDownloadMonitor

    init() {
        let store = SettingsStore()
        let levelMonitor = AudioLevelMonitor()
        let downloadMonitor = ModelDownloadMonitor()
        let recorder = MacAudioRecorder(
            inputDeviceUID: store.settings.inputDeviceUID,
            levelMonitor: levelMonitor
        )
        let hermesIsland = HermesIslandController()
        hermesIsland.start()
        let handoff: HermesHandoffInserter.Handoff = { [weak hermesIsland] text in
            await hermesIsland?.receiveExternalInput(text)
        }
        let hermesInserter = HermesHandoffInserter(handoff: handoff)
        let factory: MimirAppModel.SessionFactory = { settings in
            MimirApp.buildSession(
                settings: settings,
                recorder: recorder,
                downloadMonitor: downloadMonitor,
                hermesInserter: hermesInserter
            )
        }
        let model = MimirAppModel(store: store, makeSession: factory)
        let hotkey = GlobalHotkeyMonitor(
            dictationTrigger: store.settings.activationTrigger,
            promptRewriteTrigger: store.settings.promptRewriteActivationTrigger,
            hermesTrigger: store.settings.hermesActivationTrigger,
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
        self.hermesIsland = hermesIsland
        self.menuBar = menuBar
        _store = State(initialValue: store)
        _model = State(initialValue: model)
        _levelMonitor = State(initialValue: levelMonitor)
        _downloadMonitor = State(initialValue: downloadMonitor)

        let preloadProcessor = MLXPostProcessor(downloadMonitor: downloadMonitor)
        Task {
            await preloadProcessor.preload()
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
                    if oldValue.hermesActivationTrigger != newValue.hermesActivationTrigger {
                        hotkey.updateHermesTrigger(newValue.hermesActivationTrigger)
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
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 960, height: 640)
        .defaultLaunchBehavior(.suppressed)
    }

    private func needsSessionRebuild(old: AppSettings, new: AppSettings) -> Bool {
        old.transcriptionProvider != new.transcriptionProvider
            || old.transcriptionStrategy != new.transcriptionStrategy
            || old.whisperKitModel != new.whisperKitModel
            || old.postProcessingProvider != new.postProcessingProvider
            || old.postProcessingStyle != new.postProcessingStyle
            || old.insertionStrategy != new.insertionStrategy
            || old.shouldAutoPaste != new.shouldAutoPaste
            || old.preferredLanguage != new.preferredLanguage
            || old.activationMode != new.activationMode
    }

    @MainActor
    private static func buildSession(
        settings: AppSettings,
        recorder: any AudioRecording,
        downloadMonitor: ModelDownloadMonitor,
        hermesInserter: any TextInserting
    ) -> any DictationControlling {
        let speechToText: any SpeechToTextProviding = switch settings.transcriptionProvider {
        case .appleSpeech:
            AppleSpeechProvider()
        case .whisperKit:
            WhisperKitProvider(model: settings.whisperKitModel, strategy: settings.transcriptionStrategy)
        case .mlxWhisper, .whisperCPP, .fasterWhisper:
            AppleSpeechProvider()
        }

        let postProcessor: (any TextPostProcessing)? = switch settings.postProcessingProvider {
        case .disabled:
            nil
        case .mlx:
            MLXPostProcessor(style: settings.postProcessingStyle, downloadMonitor: downloadMonitor)
        }

        let pipeline = LocalPipeline(
            speechToText: speechToText,
            postProcessor: postProcessor,
            textInserter: ClipboardPasteInserter(autoPaste: settings.shouldAutoPaste)
        )

        return DictationSessionController(
            settings: settings,
            recorder: recorder,
            pipeline: pipeline,
            hermesInserter: hermesInserter
        )
    }
}


struct SettingsOverlay: View {
    @Bindable var store: SettingsStore
    @Binding var selectedItemID: String
    @Binding var isPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Settings")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.bottom, 8)

                ForEach(DashboardSection.settingsItems) { item in
                    SettingsSidebarRow(item: item, selectedItemID: $selectedItemID)
                }

                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(width: 280)
            .background(MimirTheme.surface)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTitle)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(MimirTheme.ink)
                        Text(selectedSubtitle)
                            .font(.system(size: 14))
                            .foregroundStyle(MimirTheme.secondaryInk)
                    }
                    Spacer()
                    Button("Restore defaults") {
                        store.reset()
                    }
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(MimirTheme.ink)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(MimirTheme.softFill))
                    }
                    .buttonStyle(.plain)
                }
                .padding(28)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        switch selectedItemID {
                        case "audio":
                            audioSection
                        case "pipeline":
                            pipelineSection
                        case "permissions":
                            permissionsSection
                        case "about":
                            aboutSection
                        default:
                            generalSection
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
            .background(MimirTheme.surfaceRaised)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(MimirTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.14), radius: 24, y: 14)
    }

    var generalSection: some View {
        SettingsSectionCard(title: "General", description: "") {
            VStack(alignment: .leading, spacing: 18) {
                KeyBindingRecorderRow(title: "Transcription shortcut", binding: $store.settings.activationTrigger)

                KeyBindingRecorderRow(title: "Prompt / Rewrite shortcut", binding: $store.settings.promptRewriteActivationTrigger)
                Text("Records in the blue Prompt / Rewrite mode and turns your dictation into a clearer prompt or rewritten text.")
                    .helperTextStyle()

                KeyBindingRecorderRow(title: "Send to Hermes shortcut", binding: $store.settings.hermesActivationTrigger)
                Text("Sends the cleaned dictation to the Hermes island instead of pasting into the active app.")
                    .helperTextStyle()

                MimirDropdown(
                    title: "Activation mode",
                    selection: $store.settings.activationMode,
                    options: ActivationMode.allCases.map { ($0, $0.displayName) }
                )
                Text(activationSubtitle(mode: store.settings.activationMode, binding: store.settings.activationTrigger))
                    .rowSubtitleStyle()

                MimirDropdown(
                    title: "Preferred language",
                    selection: Binding(
                        get: { store.settings.preferredLanguage },
                        set: { store.settings.preferredLanguage = $0 }
                    ),
                    options: LanguageOption.supported.map { ($0.code, $0.displayName) }
                )
            }
        }
    }

    var audioSection: some View {
        SettingsSectionCard(title: "Audio", description: "") {
            VStack(alignment: .leading, spacing: 14) {
                MicrophonePickerRow(store: store)
                Text("On Automatic, Mimir uses the system default microphone.")
                    .helperTextStyle()
            }
        }
    }

    var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionCard(title: "Transcription", description: "") {
                VStack(alignment: .leading, spacing: 14) {
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
                        title: "Whisper model",
                        selection: $store.settings.whisperKitModel,
                        options: WhisperKitModel.allCases.map { ($0, $0.displayName) }
                    )
                    Text("Chunked responds better on long dictation; batch processes the whole file.")
                        .helperTextStyle()
                }
            }

            SettingsSectionCard(title: "Formatting", description: "") {
                VStack(alignment: .leading, spacing: 14) {
                    MimirDropdown(
                        title: "Post-processing",
                        selection: $store.settings.postProcessingProvider,
                        options: PostProcessingProvider.allCases.map { ($0, $0.displayName) }
                    )
                    MimirDropdown(
                        title: "Style",
                        selection: $store.settings.postProcessingStyle,
                        options: PostProcessingStyle.allCases.map { ($0, $0.displayName) }
                    )
                    Text("Structured preserves language and content; only creates lists when the speech sounds like an enumeration.")
                        .helperTextStyle()
                }
            }

            SettingsSectionCard(title: "Insertion", description: "") {
                VStack(alignment: .leading, spacing: 14) {
                    MimirDropdown(
                        title: "Strategy",
                        selection: $store.settings.insertionStrategy,
                        options: InsertionStrategy.allCases.map { ($0, $0.displayName) }
                    )
                    Toggle("Paste automatically", isOn: $store.settings.shouldAutoPaste)
                        .font(.system(size: 14, weight: .medium))
                }
            }
        }
    }

    var permissionsSection: some View {
        PermissionsSettingsCard()
    }

    var aboutSection: some View {
        SettingsSectionCard(title: "About", description: "") {
            VStack(alignment: .leading, spacing: 10) {
                AboutRow(title: "Mimir", detail: "Local dictation — nothing uploaded to the cloud.")
            }
        }
    }

    private var selectedTitle: String {
        DashboardSection.settingsItems.first(where: { $0.id == selectedItemID })?.title ?? "Settings"
    }

    private var selectedSubtitle: String {
        switch selectedItemID {
        case "audio": return "Audio input and capture device."
        case "pipeline": return "Transcription, post-processing, and insertion."
        case "permissions": return "Permissions needed for the global shortcut to work well."
        case "about": return "Summary of the current visual direction."
        default: return "Shortcut, language, and the app's main behavior."
        }
    }
}

private struct SettingsSidebarRow: View {
    let item: DashboardItem
    @Binding var selectedItemID: String

    private var isSelected: Bool { selectedItemID == item.id }

    var body: some View {
        Button {
            selectedItemID = item.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .sectionTitleStyle()
            if !description.isEmpty {
                Text(description)
                    .sectionLeadStyle()
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MimirTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(MimirTheme.hairline, lineWidth: 1)
        )
    }
}

private struct MimirDropdown<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    @State private var hovering = false

    private var currentLabel: String {
        options.first(where: { $0.0 == selection })?.1 ?? ""
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .rowTitleStyle()
            Spacer(minLength: 12)
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Button(option.1) { selection = option.0 }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(currentLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MimirTheme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MimirTheme.secondaryInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 320, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(hovering ? MimirTheme.softFillStrong : MimirTheme.surfaceSunken)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(MimirTheme.hairline, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hovering = $0 }
        }
    }
}

private struct HelperText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MimirTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PermissionsSettingsCard: View {
    @State private var snapshot = PermissionSnapshot.current()
    @State private var feedback: String?

    var body: some View {
        SettingsSectionCard(title: "Permissions", description: "Request or review the permissions MIMIR uses to capture and insert text.") {
            VStack(alignment: .leading, spacing: 14) {
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

                InteractivePermissionRow(title: "Input monitoring", description: "Required to listen for the global shortcut outside the app.", state: snapshot.inputMonitoring, buttonTitle: "Request") {
                    let granted = PermissionCoordinator.ensureInputMonitoring()
                    feedback = granted ? "Input monitoring granted." : "macOS hasn't granted input monitoring yet."
                    snapshot = PermissionSnapshot.current()
                }

                if let feedback {
                    Text(feedback)
                        .font(.system(size: 13))
                        .foregroundStyle(MimirTheme.secondaryInk)
                }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MimirTheme.ink)
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(MimirTheme.secondaryInk)
                }
                Spacer()
                Text(state.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(state.color)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(state.color.opacity(0.10)))
                Button(buttonTitle, action: action)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
            }
            Divider()
        }
    }
}

private struct AboutRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MimirTheme.ink)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(MimirTheme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct KeyBindingRecorderRow: View {
    let title: String
    @Binding var binding: KeyBinding

    @State private var isRecording = false
    @State private var captured: KeyBinding?
    @State private var liveModifiers: UInt = 0
    @State private var waitingForRelease = false
    @State private var monitor: Any?
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .rowTitleStyle()
                    if !isRecording {
                        Text(recorderSubtitle(binding: binding))
                            .rowSubtitleStyle()
                    } else {
                        Text("Press the new combination…")
                            .rowSubtitleStyle()
                    }
                }

                Spacer(minLength: 12)

                if isRecording {
                    recordingArea
                } else {
                    idleKeycaps
                }
            }
            if isRecording, let hint = remapHint {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(MimirTheme.accentPurple.opacity(0.7))
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(MimirTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 2)
            }
        }
        .onDisappear { stopRecording() }
    }

    /// Detecta se a captura atual parece vir de uma tecla remapeada por
    /// Karabiner/similar (3+ modificadores simultâneos sem tecla principal).
    private var remapHint: String? {
        guard let captured else { return nil }
        let mods = captured.modifiers
        let count = popCount(mods)
        if captured.keyCode == 0 && count >= 3 {
            return "Looks like your key is remapped (Karabiner/Hyper). Mimir only receives the modifiers — it can't see which physical key was pressed. Saving still works, or pick another key."
        }
        return nil
    }

    private var idleKeycaps: some View {
        Button {
            startRecording()
        } label: {
            HStack(spacing: 6) {
                keycapRow(for: binding.keyCaps)
                Image(systemName: "pencil")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .opacity(hovering ? 0.9 : 0.4)
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(hovering ? MimirTheme.softFill.opacity(0.5) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(hovering ? MimirTheme.accentPurple.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to record a new shortcut")
    }

    private var recordingArea: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                let displayCaps = captured?.keyCaps ?? []
                if waitingForRelease {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(MimirTheme.accentPurple)
                    Text("Release the keys first…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MimirTheme.ink.opacity(0.75))
                        .fixedSize()
                } else if !displayCaps.isEmpty {
                    keycapRow(for: displayCaps)
                } else {
                    Circle()
                        .fill(MimirTheme.accentPurple)
                        .frame(width: 8, height: 8)
                        .scaleEffect(pulse ? 1.35 : 0.85)
                        .opacity(pulse ? 0.55 : 1)
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true), value: pulse)
                    Text("Press the shortcut…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MimirTheme.ink.opacity(0.75))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MimirTheme.softFill.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(MimirTheme.accentPurple.opacity(0.45), lineWidth: 1)
            )

            if captured != nil {
                Button {
                    if let c = captured { binding = c }
                    stopRecording()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(MimirTheme.accentPurple))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Save shortcut")
            }

            Button { stopRecording() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(MimirTheme.secondaryInk)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(MimirTheme.softFill))
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .onAppear { pulse = true }
    }


    private func keycapRow(for caps: [String]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { idx, cap in
                keycap(cap)
                if idx < caps.count - 1 {
                    Text("+")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(MimirTheme.secondaryInk.opacity(0.5))
                        .padding(.horizontal, 1)
                }
            }
        }
    }

    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(MimirTheme.ink)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MimirTheme.softFillStrong)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(MimirTheme.hairline, lineWidth: 1)
            )
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
        NotificationCenter.default.post(name: .keyBindingRecordingStarted, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            Task { @MainActor in
                self.handleRecordingEvent(event)
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        captured = nil
        liveModifiers = 0
        waitingForRelease = false
        NotificationCenter.default.post(name: .keyBindingRecordingStopped, object: nil)
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

            // Enquanto tudo estiver solto, não há nada pra capturar — mas mantemos o
            // último captured pra o usuário poder clicar Salvar depois.
            if now == 0 { return }

            // Nova sessão: começou a pressionar do zero → limpa estado anterior.
            if prev == 0 {
                captured = nil
            }

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
            if event.keyCode == 53 { return }
            guard !KeyBinding.modifierKeyCodes.contains(event.keyCode) else { return }
            let flagsMasked = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue & Self.standardModifiersMask
            let label = Self.combinationLabel(keyCode: event.keyCode, modifiers: NSEvent.ModifierFlags(rawValue: flagsMasked), event: event)
            captured = KeyBinding(keyCode: event.keyCode, modifiers: flagsMasked, label: label)
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

private struct KeyBindingActionStyle: ButtonStyle {
    var accent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(accent ? Color.white : MimirTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Group {
                    if accent {
                        Capsule().fill(MimirTheme.brandGradient)
                            .opacity(configuration.isPressed ? 0.85 : 1)
                    } else {
                        Capsule().fill(MimirTheme.softFill)
                            .opacity(configuration.isPressed ? 0.85 : 1)
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(accent ? Color.clear : MimirTheme.hairline, lineWidth: 1)
            )
    }
}

private struct MicrophonePickerRow: View {
    @Bindable var store: SettingsStore
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        HStack(spacing: 14) {
            MimirDropdown(
                title: "Microphone",
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
            }
            .buttonStyle(SecondaryCapsuleButtonStyle())
        }
        .onAppear {
            devices = AudioInputDevice.allInputs()
        }
    }

    private var microphoneOptions: [(String?, String)] {
        let systemDefault = AudioInputDevice.systemDefaultInput()
        let autoLabel = systemDefault.map { "Automatic (system) — \($0.name)" } ?? "Automatic (system)"
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

private struct SecondaryCapsuleButtonStyle: ButtonStyle {
    var background: Color = MimirTheme.softFill
    var foreground: Color = MimirTheme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(Capsule().fill(background.opacity(configuration.isPressed ? 0.90 : 1)))
            .overlay(Capsule().stroke(MimirTheme.hairline, lineWidth: 1))
    }
}

private struct PermissionSnapshot {
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

private enum PermissionState {
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

enum MimirTheme {
    // Dark surfaces (base única)
    static let surface = Color(hex: 0x0E0E0F)
    static let surfaceRaised = Color(hex: 0x171718)
    static let surfaceSunken = Color(hex: 0x0A0A0B)

    // Typography
    static let ink = Color.white.opacity(0.92)
    static let secondaryInk = Color.white.opacity(0.58)
    static let tertiaryInk = Color.white.opacity(0.38)

    // Fills and hairlines
    static let softFill = Color.white.opacity(0.06)
    static let softFillStrong = Color.white.opacity(0.12)
    static let hairline = Color.white.opacity(0.08)

    // Brand
    static let brandBlue = Color(hex: 0x3559D4)
    static let accentCyan = Color(hex: 0x00C0E8)
    static let accentPurple = Color(hex: 0x6155F5)

    // Status (recalibrados para contraste em dark)
    static let green = Color(hex: 0x4CC274)
    static let orange = Color(hex: 0xE09A4A)
    static let red = Color(hex: 0xE35A4F)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [accentCyan, accentPurple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var brandGradientSoft: LinearGradient {
        LinearGradient(
            colors: [accentCyan.opacity(0.18), accentPurple.opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
