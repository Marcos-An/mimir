import Foundation
import Testing
@testable import MimirCore

@Test("Default settings expose a Hermes handoff shortcut alongside Prompt / Rewrite")
func defaultSettingsExposeHermesHandoffShortcut() {
    let settings = AppSettings.default

    #expect(settings.hermesActivationTrigger == .defaultHermesHandoff)
    #expect(settings.hermesActivationTrigger != settings.promptRewriteActivationTrigger)
    #expect(settings.hermesActivationTrigger != settings.activationTrigger)
}

@Test("Default Hermes binding represents Right ⌥ + Left ⇧")
func defaultHermesBindingRepresentsRightOptionLeftShift() {
    let binding = KeyBinding.defaultHermesHandoff

    #expect(binding.keyCode == 0)
    #expect(binding.isModifierCombo)

    let optionBit: UInt = 1 << 19
    let shiftBit: UInt = 1 << 17
    #expect(binding.modifiers & optionBit != 0)
    #expect(binding.modifiers & shiftBit != 0)

    // Side-specific bits in NSEvent.modifierFlags raw value.
    let rightOption: UInt = 0x40
    let leftShift: UInt = 0x02
    #expect(binding.deviceMask == rightOption | leftShift)
    #expect(binding.keyCaps == ["Right ⌥", "Left ⇧"])
}

@Test("Modifier-combo binding without device mask still matches device-independent flags")
func modifierComboWithoutDeviceMaskMatchesDeviceIndependentFlags() {
    let binding = KeyBinding(
        keyCode: 0,
        modifiers: (1 << 19) | (1 << 17),
        label: "⌥⇧"
    )

    let rawWithLeftOptionRightShift: UInt = ((1 << 19) | (1 << 17)) | 0x20 | 0x04
    #expect(binding.matchesModifierFlags(rawFlags: rawWithLeftOptionRightShift))
}

@Test("Side-specific binding rejects mismatched physical sides")
func sideSpecificBindingRejectsMismatchedSides() {
    let binding = KeyBinding.defaultHermesHandoff

    // Right Option + Right Shift fails the deviceMask requirement (Left Shift bit absent).
    let rawWrongShift: UInt = ((1 << 19) | (1 << 17)) | 0x40 | 0x04
    #expect(binding.matchesModifierFlags(rawFlags: rawWrongShift) == false)

    // Right Option + Left Shift passes both device-independent and device masks.
    let rawCorrect: UInt = ((1 << 19) | (1 << 17)) | 0x40 | 0x02
    #expect(binding.matchesModifierFlags(rawFlags: rawCorrect))
}

@Test("Hermes dictation mode hands off without forcing prompt-rewrite intent")
func hermesDictationModeHandsOffWithoutPromptIntent() {
    #expect(DictationMode.hermes.displayName == "Hermes handoff")
    #expect(DictationMode.hermes.defaultPolishIntent == .defaults)
    #expect(DictationMode.hermes.accentName != "blue")
}

@Test("Default AppSettings encoding includes both prompt-rewrite and hermes activation keys")
func defaultAppSettingsEncodingIncludesHermesAndPromptRewriteKeys() throws {
    let data = try JSONEncoder().encode(AppSettings.default)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json.keys.contains("promptRewriteActivationTrigger"))
    #expect(json.keys.contains("hermesActivationTrigger"))
}

@Test("Modern decoding keeps hermes and prompt-rewrite triggers separate")
func modernDecodingKeepsHermesAndPromptRewriteSeparate() throws {
    let json = """
    {
      "activationMode": "tapToToggle",
      "activationTrigger": {"keyCode": 54, "modifiers": 0, "label": "Right ⌘"},
      "promptRewriteActivationTrigger": {"keyCode": 49, "modifiers": 524288, "label": "⌥ Space"},
      "hermesActivationTrigger": {"keyCode": 36, "modifiers": 1048576, "label": "⌘ Return"},
      "transcriptionProvider": "whisperKit",
      "postProcessingProvider": "mlx",
      "insertionStrategy": "clipboardPaste",
      "shouldAutoPaste": true
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

    #expect(settings.promptRewriteActivationTrigger.keyCode == 49)
    #expect(settings.hermesActivationTrigger.keyCode == 36)
    #expect(settings.hermesActivationTrigger.modifiers == 1 << 20)
}

@Test("Legacy hermes payload (no prompt-rewrite key) still migrates to prompt-rewrite while new hermes uses default")
func legacyHermesPayloadMigratesToPromptRewriteAndNewHermesGetsDefault() throws {
    let legacyJSON = """
    {
      "activationMode": "tapToToggle",
      "activationTrigger": {"keyCode": 54, "modifiers": 0, "label": "Right ⌘"},
      "hermesActivationTrigger": {"keyCode": 36, "modifiers": 1048576, "label": "⌘ Return"},
      "transcriptionProvider": "whisperKit",
      "postProcessingProvider": "mlx",
      "insertionStrategy": "clipboardPaste",
      "shouldAutoPaste": true
    }
    """

    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacyJSON.utf8))

    #expect(settings.promptRewriteActivationTrigger.keyCode == 36)
    #expect(settings.hermesActivationTrigger == .defaultHermesHandoff)
}

@Test("Hermes mode routes the final text through the hermes inserter instead of the default paste inserter")
func hermesModeRoutesThroughHermesInserter() async throws {
    var settings = AppSettings.default
    settings.transcriptionStrategy = .batch
    let audioURL = URL(fileURLWithPath: "/tmp/mimir-hermes-routing.wav")
    let recorder = HermesRoutingRecorderSpy(finished: FinishedCapture(fileURL: audioURL, span: nil))
    let speech = HermesRoutingSpeechSpy(result: SpeechTranscription(text: "olá hermes", language: "pt"))
    let primaryInserter = HermesRoutingInserterSpy()
    let hermesInserter = HermesRoutingInserterSpy()
    let pipeline = LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: primaryInserter)
    let session = DictationSessionController(
        settings: settings,
        recorder: recorder,
        pipeline: pipeline,
        hermesInserter: hermesInserter
    )

    try await session.handleActivationPressed(mode: .hermes)
    try await session.handleActivationReleased()

    #expect(await primaryInserter.insertedTexts.isEmpty)
    #expect(await hermesInserter.insertedTexts == ["olá hermes"])

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "olá hermes")
    #expect(snapshot.activeMode == nil)
}

@Test("Prompt / Rewrite mode keeps using the primary paste inserter (not Hermes)")
func promptRewriteModeKeepsUsingPrimaryInserter() async throws {
    var settings = AppSettings.default
    settings.transcriptionStrategy = .batch
    let audioURL = URL(fileURLWithPath: "/tmp/mimir-promptrewrite-routing.wav")
    let recorder = HermesRoutingRecorderSpy(finished: FinishedCapture(fileURL: audioURL, span: nil))
    let speech = HermesRoutingSpeechSpy(result: SpeechTranscription(text: "review this PR", language: "en"))
    let primaryInserter = HermesRoutingInserterSpy()
    let hermesInserter = HermesRoutingInserterSpy()
    let postProcessor = HermesRoutingPostProcessorSpy(result: "review this PR (refined)")
    let pipeline = LocalPipeline(speechToText: speech, postProcessor: postProcessor, textInserter: primaryInserter)
    let session = DictationSessionController(
        settings: settings,
        recorder: recorder,
        pipeline: pipeline,
        hermesInserter: hermesInserter
    )

    try await session.handleActivationPressed(mode: .promptRewrite)
    try await session.handleActivationReleased()

    #expect(await primaryInserter.insertedTexts == ["review this PR (refined)"])
    #expect(await hermesInserter.insertedTexts.isEmpty)
    #expect(await postProcessor.receivedIntents == [.promptEngineer])
}

private actor HermesRoutingRecorderSpy: AudioRecording {
    let finished: FinishedCapture
    init(finished: FinishedCapture) { self.finished = finished }
    func beginCapture() async throws {}
    func finishCapture() async throws -> FinishedCapture { finished }
    func nextIncrementalChunkBatch() async throws -> IncrementalChunkBatch? { nil }
}

private actor HermesRoutingSpeechSpy: SpeechToTextProviding {
    let result: SpeechTranscription
    init(result: SpeechTranscription) { self.result = result }
    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription { result }
}

private actor HermesRoutingInserterSpy: TextInserting {
    var insertedTexts: [String] = []
    func insert(_ text: String) async throws { insertedTexts.append(text) }
}

private actor HermesRoutingPostProcessorSpy: TextPostProcessing {
    let result: String
    var receivedIntents: [PolishIntent] = []
    init(result: String) { self.result = result }
    func polish(_ transcript: String) async throws -> String {
        try await polish(transcript, intent: .defaults)
    }
    func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        receivedIntents.append(intent)
        return result
    }
    func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        let output = try await polish(transcript, intent: intent)
        await onChunk(output)
        return output
    }
}
