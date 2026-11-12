import Foundation
import Testing
@testable import MimirCore

@Test("Default settings use a runnable local stack")
func defaultSettingsUseRunnableLocalDefaults() {
    let settings = AppSettings.default

    #expect(settings.activationMode == .tapToToggle)
    #expect(settings.activationTrigger == .defaultRightCommand)
    #expect(settings.activationTrigger.keyCode == 54)
    #expect(settings.activationTrigger.isModifierOnly)
    #expect(settings.transcriptionProvider == .whisperKit)
    #expect(settings.transcriptionStrategy == .chunked)
    #expect(settings.whisperKitModel == .whisperTurbo)
    #expect(settings.postProcessingProvider == .mlx)
    #expect(settings.postProcessingStyle == .cleanDictation)
    #expect(settings.promptRewriteActivationTrigger == .defaultRightOptionSpace)
    #expect(settings.insertionStrategy == .clipboardPaste)
    #expect(settings.shouldAutoPaste)
    #expect(settings.preferredLanguage == nil)
}

@Test("Dictation modes expose Clean Dictation and blue Prompt Rewrite behavior")
func dictationModesExposeCleanAndPromptRewriteBehavior() {
    #expect(DictationMode.dictation.displayName == "Clean Dictation")
    #expect(DictationMode.dictation.defaultPolishIntent == .defaults)
    #expect(DictationMode.promptRewrite.displayName == "Prompt / Rewrite")
    #expect(DictationMode.promptRewrite.defaultPolishIntent == .promptEngineer)
    #expect(DictationMode.promptRewrite.accentName == "blue")
}

@Test("Display title reflects current app state")
func displayTitleReflectsCurrentState() {
    #expect(AppPhase.idle.displayTitle == "Ready")
    #expect(AppPhase.recording.displayTitle == "Recording…")
    #expect(AppPhase.transcribing.displayTitle == "Transcribing…")
    #expect(AppPhase.postProcessing.displayTitle == "Polishing…")
    #expect(AppPhase.inserting.displayTitle == "Pasting…")
    #expect(AppPhase.error(message: "Microphone permission denied").displayTitle == "Error")
}

@Test("Dashboard shell exposes MIMIR navigation and feature-focused copy")
func dashboardShellExposesMimirNavigationAndCopy() {
    #expect(DashboardSection.primaryItems.map(\.title) == ["Overview", "Session", "History"])
    #expect(DashboardSection.utilityItems.map(\.title) == ["Permissions", "Settings"])
    #expect(DashboardSection.settingsItems.map(\.title) == ["General", "Audio", "Dictation", "Permissions", "About"])
    #expect(DashboardMetric.defaultMetrics.map(\.title) == ["Active shortcut", "Transcription", "Insertion", "Language"])
    #expect(DashboardChrome.appName == "MIMIR")
    #expect(DashboardChrome.sidebarCardTitle == "Own theme, local flow")
    #expect(DashboardChrome.sidebarCardBody == "Native macOS transcription with an expressive look, built for speed and on-device privacy.")
    #expect(DashboardChrome.primaryActionTitle == "Start transcribing")
    #expect(DashboardPromo.defaultCards.map(\.action) == ["Open shortcuts", "Review permissions"])
}

@Test("Press and release runs a full hold-to-talk dictation cycle")
func holdToTalkCycleTransitionsThroughRecordingAndBackToIdle() async throws {
    let audioURL = URL(fileURLWithPath: "/tmp/mimir-test.wav")
    let recorder = RecorderSpy(finished: FinishedCapture(fileURL: audioURL))
    let metrics = TranscriptionMetrics(audioLoading: 0.12, fullPipeline: 1.4, realTimeFactor: 0.35, firstTokenLatency: 0.28)
    let transcriber = SpeechSpy(result: SpeechTranscription(text: "oi mundo", language: "pt", metrics: metrics))
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(speechToText: transcriber, postProcessor: nil, textInserter: inserter)
    let session = DictationSessionController(settings: .default, recorder: recorder, pipeline: pipeline)

    #expect(await session.snapshot.phase == .idle)

    try await session.handleActivationPressed()
    #expect(await session.snapshot.phase == .recording)
    #expect(await recorder.beginCallCount == 1)

    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastTranscript == "Oi mundo.")
    #expect(snapshot.lastTranscription?.text == "oi mundo")
    #expect(snapshot.lastTranscription?.language == "pt")
    #expect(snapshot.lastTranscription?.metrics == metrics)
    #expect(await recorder.finishCallCount == 1)
    #expect(await transcriber.receivedAudioFileURL == audioURL)
    #expect(await inserter.insertedTexts == ["Oi mundo."])
}

@Test("WhisperKit provider configuration follows settings-driven chunking defaults")
func whisperKitProviderConfigurationFollowsSettings() {
    let chunked = WhisperKitProvider.configuration(
        model: .base,
        strategy: .chunked,
        languageHint: "pt-BR"
    )

    #expect(chunked.modelName == "openai_whisper-base")
    #expect(chunked.language == "pt")
    #expect(chunked.detectLanguage == false)
    #expect(chunked.chunkingMode == .vad)
    #expect(chunked.concurrentWorkerCount == 8)
    #expect(chunked.prefersWordTimestamps)

    let batch = WhisperKitProvider.configuration(
        model: .small,
        strategy: .batch,
        languageHint: nil
    )

    #expect(batch.modelName == "openai_whisper-small")
    #expect(batch.language == nil)
    #expect(batch.detectLanguage)
    #expect(batch.chunkingMode == .none)
    #expect(batch.concurrentWorkerCount == 8)
    #expect(batch.prefersWordTimestamps == false)
}

@Test("Clean Dictation MLX prompt is transcript-faithful and removes pause artifacts")
func cleanDictationMLXPromptIsTranscriptFaithful() {
    let prompt = MLXPostProcessor.systemPrompt(for: .cleanDictation)

    #expect(prompt.localizedCaseInsensitiveContains("editor"))
    #expect(prompt.localizedCaseInsensitiveContains("same language"))
    #expect(prompt.localizedCaseInsensitiveContains("do not translate"))
    #expect(prompt.localizedCaseInsensitiveContains("preserve"))
    #expect(prompt.localizedCaseInsensitiveContains("punctuation"))
    #expect(prompt.localizedCaseInsensitiveContains("ellipses") || prompt.localizedCaseInsensitiveContains("reticências"))
    #expect(prompt.localizedCaseInsensitiveContains("staging"))
    #expect(prompt.localizedCaseInsensitiveContains("branch"))
    #expect(prompt.localizedCaseInsensitiveContains("fetch"))
    #expect(prompt.localizedCaseInsensitiveContains("Do not normalize unfamiliar technical terms"))
    #expect(prompt.localizedCaseInsensitiveContains("preserve the original order"))
    #expect(prompt.localizedCaseInsensitiveContains("rambling"))
    #expect(prompt.localizedCaseInsensitiveContains("lightly reorganize") == false)
    #expect(prompt.localizedCaseInsensitiveContains("ultraconservative") == false)
}

@Test("Default Clean Dictation rejects aggressive post-processing compression")
func defaultCleanDictationRejectsAggressivePostProcessingCompression() async throws {
    let transcript = "Eu entendo. Gostei da ideia. Mas por que a gente não pode usar Open Web UI para acelerar nosso processo? Não conseguimos ter um Open Web UI aqui. Nosso objetivo inicial era iniciar e alterar esse Open Web UI. Você pode pesquisar para ver se isso é plausível ou fazer nosso processo de outra forma."
    let compressed = "Gostei da ideia. Pesquise se usar Open Web UI é plausível."
    let postProcessor = PostProcessorSpy(result: compressed)
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: transcript, language: "pt")),
        postProcessor: postProcessor,
        textInserter: inserter
    )

    let result = try await pipeline.process(
        transcription: SpeechTranscription(text: transcript, language: "pt"),
        defaultIntent: .defaults
    )

    #expect(result.outputText == transcript)
    #expect(result.postProcessingInputCharacterCount == transcript.count)
    #expect(result.postProcessingOutputCharacterCount == transcript.count)
    #expect(await inserter.insertedTexts == [transcript])
}

@Test("Prompt Rewrite mode forces prompt-engineering intent without a spoken prefix")
func promptRewriteModeForcesPromptEngineeringIntent() async throws {
    let postProcessor = PostProcessorSpy(result: "Prompt limpo")
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: "me ajuda a revisar esse PR", language: "pt")),
        postProcessor: postProcessor,
        textInserter: inserter
    )

    let result = try await pipeline.process(
        transcription: SpeechTranscription(text: "me ajuda a revisar esse PR", language: "pt"),
        defaultIntent: .promptEngineer
    )

    #expect(result.activeIntent == .promptEngineer)
    #expect(await postProcessor.receivedIntents == [.promptEngineer])
    #expect(await postProcessor.receivedTranscripts == ["me ajuda a revisar esse PR"])
    // Ponto final vem da limpeza determinística, que agora roda também no
    // modo prompt (antes só no ditado padrão).
    #expect(await inserter.insertedTexts == ["Prompt limpo."])
}

@Test("Prompt Rewrite mode also gets the deterministic cleanup")
func promptRewriteModeGetsDeterministicCleanup() async throws {
    let transcript = "me manda o link do PR. Obrigado."
    let postProcessor = PostProcessorSpy(result: "Me manda o link do PR. Obrigado.")
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: transcript, language: "pt")),
        postProcessor: postProcessor,
        textInserter: inserter
    )

    let result = try await pipeline.process(
        transcription: SpeechTranscription(text: transcript, language: "pt"),
        defaultIntent: .promptEngineer
    )

    #expect(result.outputText == "Me manda o link do PR.")
    #expect(await inserter.insertedTexts == ["Me manda o link do PR."])
}

@Test("Prompt Rewrite MLX prompt keeps the user's voice instead of restructuring the dictation")
func promptRewriteMLXPromptKeepsUserVoice() {
    let prompt = MLXPostProcessor.systemPrompt(for: .promptEngineer, fallbackStyle: .cleanDictation)

    #expect(prompt.localizedCaseInsensitiveContains("hallucinates short closings"))
    #expect(prompt.localizedCaseInsensitiveContains("always needs real editing"))
    #expect(prompt.localizedCaseInsensitiveContains("numbered task list"))
    #expect(prompt.localizedCaseInsensitiveContains("structured prompt") == false)
}

@Test("Prompt Rewrite MLX prompt preserves the dictation language instead of forcing English")
func promptRewriteMLXPromptPreservesDictationLanguage() {
    let prompt = MLXPostProcessor.systemPrompt(for: .promptEngineer, fallbackStyle: .cleanDictation)

    #expect(prompt.localizedCaseInsensitiveContains("same as the dictation input"))
    #expect(prompt.localizedCaseInsensitiveContains("do not translate"))
    #expect(prompt.localizedCaseInsensitiveContains("always write the final prompt in English") == false)
}

@Test("Cleanup MLX prompt stays conservative and avoids structural rewrites")
func cleanupMLXPromptStaysConservative() {
    let prompt = MLXPostProcessor.systemPrompt(for: .cleanup)

    #expect(prompt.localizedCaseInsensitiveContains("spelling"))
    #expect(prompt.localizedCaseInsensitiveContains("do not invent"))
    #expect(prompt.localizedCaseInsensitiveContains("do not reorganize") || prompt.localizedCaseInsensitiveContains("minimum intervention") || prompt.localizedCaseInsensitiveContains("fix only"))
}

@Test("Local pipeline preserves structured transcription metrics through insertion")
func localPipelinePreservesStructuredTranscriptionResults() async throws {
    let audioURL = URL(fileURLWithPath: "/tmp/mimir-structured.wav")
    let metrics = TranscriptionMetrics(audioLoading: 0.21, fullPipeline: 1.8, realTimeFactor: 0.52, firstTokenLatency: 0.33)
    let speech = SpeechSpy(result: SpeechTranscription(text: "itens de projeto", language: "pt", metrics: metrics))
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter)

    let result = try await pipeline.process(audioFileURL: audioURL, languageHint: "pt-BR")

    #expect(result.outputText == "Itens de projeto.")
    #expect(result.postProcessingInputCharacterCount == nil)
    #expect(result.postProcessingSystemBefore == nil)
    #expect(result.transcription.text == "itens de projeto")
    #expect(result.transcription.language == "pt")
    #expect(result.transcription.metrics == metrics)
    #expect(await speech.receivedLanguageHint == "pt-BR")
    #expect(await inserter.insertedTexts == ["Itens de projeto."])
}

@Test("Local pipeline records post-processing input size and system load snapshots")
func localPipelineRecordsPostProcessingDiagnostics() async throws {
    let postProcessor = PostProcessorSpy(result: "Texto limpo")
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: "texto cru", language: "pt")),
        postProcessor: postProcessor,
        textInserter: inserter
    )

    let result = try await pipeline.process(
        transcription: SpeechTranscription(text: "texto cru", language: "pt"),
        defaultIntent: .defaults
    )

    #expect(result.outputText == "Texto limpo.")
    #expect(result.postProcessingInputCharacterCount == "texto cru".count)
    #expect(result.postProcessingOutputCharacterCount == "Texto limpo.".count)
    #expect(result.postProcessingSystemBefore?.processorCount ?? 0 > 0)
    #expect(result.postProcessingSystemBefore?.physicalMemoryBytes ?? 0 > 0)
    #expect(result.postProcessingSystemBefore?.loadAverage1m != nil)
    #expect(result.postProcessingSystemAfter?.processorCount ?? 0 > 0)
}

@Test("Press surfaces recorder failures as an error state")
func pressTransitionsToErrorWhenRecorderFails() async {
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-test.wav")),
        beginError: MimirError.microphonePermissionDenied
    )
    let pipeline = LocalPipeline(speechToText: SpeechSpy(result: SpeechTranscription(text: "ignored")), postProcessor: nil, textInserter: InserterSpy())
    let session = DictationSessionController(settings: .default, recorder: recorder, pipeline: pipeline)

    await #expect(throws: MimirError.microphonePermissionDenied) {
        try await session.handleActivationPressed()
    }

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .error(message: MimirError.microphonePermissionDenied.localizedDescription))
    #expect(snapshot.lastTranscript == nil)
}

@Test("Release surfaces recorder failures as an error state")
func releaseTransitionsToErrorWhenRecorderFails() async throws {
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-test.wav")),
        finishError: MimirError.notImplemented("Recorder failed")
    )
    let pipeline = LocalPipeline(speechToText: SpeechSpy(result: SpeechTranscription(text: "ignored")), postProcessor: nil, textInserter: InserterSpy())
    let session = DictationSessionController(settings: .default, recorder: recorder, pipeline: pipeline)

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .error(message: "Recorder failed"))
    #expect(snapshot.lastTranscript == nil)
}

private actor RecorderSpy: AudioRecording {
    let finished: FinishedCapture
    let scriptedChunks: [AudioChunk]
    let beginError: Error?
    let finishError: Error?
    var beginCallCount = 0
    var finishCallCount = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(
        finished: FinishedCapture,
        scriptedChunks: [AudioChunk] = [],
        beginError: Error? = nil,
        finishError: Error? = nil
    ) {
        self.finished = finished
        self.scriptedChunks = scriptedChunks
        self.beginError = beginError
        self.finishError = finishError
    }

    func beginCapture() async throws -> AudioCaptureSession {
        beginCallCount += 1
        if let beginError {
            throw beginError
        }
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        self.continuation = continuation
        for chunk in scriptedChunks {
            continuation.yield(chunk)
        }
        return AudioCaptureSession(
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            chunks: stream
        )
    }

    func finishCapture() async throws -> FinishedCapture {
        finishCallCount += 1
        continuation?.finish()
        continuation = nil
        if let finishError {
            throw finishError
        }
        return finished
    }
}

private enum SpeechSpyOutcome {
    case success(SpeechTranscription)
    case failure(Error)
}

private actor SpeechSpy: SpeechToTextProviding {
    var remainingResults: [SpeechTranscription]
    var remainingErrors: [Error]
    var remainingOutcomes: [SpeechSpyOutcome]
    let delayNanoseconds: UInt64
    var receivedAudioFileURL: URL?
    var receivedAudioFileURLs: [URL] = []
    var receivedLanguageHint: String?

    init(result: SpeechTranscription, delayNanoseconds: UInt64 = 0) {
        self.remainingResults = [result]
        self.remainingErrors = []
        self.remainingOutcomes = []
        self.delayNanoseconds = delayNanoseconds
    }

    init(results: [SpeechTranscription], delayNanoseconds: UInt64 = 0) {
        self.remainingResults = results
        self.remainingErrors = []
        self.remainingOutcomes = []
        self.delayNanoseconds = delayNanoseconds
    }

    init(results: [SpeechTranscription], errors: [Error], delayNanoseconds: UInt64 = 0) {
        self.remainingResults = results
        self.remainingErrors = errors
        self.remainingOutcomes = []
        self.delayNanoseconds = delayNanoseconds
    }

    init(outcomes: [SpeechSpyOutcome], delayNanoseconds: UInt64 = 0) {
        self.remainingResults = []
        self.remainingErrors = []
        self.remainingOutcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    init(error: Error, delayNanoseconds: UInt64 = 0) {
        self.remainingResults = []
        self.remainingErrors = [error]
        self.remainingOutcomes = []
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        receivedAudioFileURL = audioFileURL
        receivedAudioFileURLs.append(audioFileURL)
        receivedLanguageHint = languageHint
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !remainingOutcomes.isEmpty {
            switch remainingOutcomes.removeFirst() {
            case .success(let transcription):
                return transcription
            case .failure(let error):
                throw error
            }
        }
        if !remainingErrors.isEmpty {
            throw remainingErrors.removeFirst()
        }
        if remainingResults.count > 1 {
            return remainingResults.removeFirst()
        }
        return remainingResults.first ?? SpeechTranscription(text: "")
    }
}

@MainActor
@Test("SettingsStore migrates legacy structured default to Clean Dictation and persists marker")
func settingsStoreMigratesLegacyStructuredDefaultToCleanDictation() throws {
    let suiteName = "com.mimir.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { removeTestDefaults(defaults, suiteName: suiteName) }
    let migrationKey = "com.mimir.migrations.cleanDictationDefault.v1"
    let defaultsKey = "com.mimir.tests.settings"

    let legacyJSON = """
    {
      "activationMode": "tapToToggle",
      "activationTrigger": {"keyCode": 54, "modifiers": 0, "label": "Right ⌘"},
      "promptRewriteActivationTrigger": {"keyCode": 49, "modifiers": 524288, "label": "⌥ Space"},
      "transcriptionProvider": "whisperKit",
      "transcriptionStrategy": "chunked",
      "whisperKitModel": "largeV3TurboQuantized",
      "postProcessingProvider": "mlx",
      "postProcessingStyle": "structured",
      "insertionStrategy": "clipboardPaste",
      "shouldAutoPaste": true
    }
    """
    defaults.set(Data(legacyJSON.utf8), forKey: defaultsKey)
    #expect(defaults.bool(forKey: migrationKey) == false)

    let store = SettingsStore(defaults: defaults, defaultsKey: defaultsKey)

    #expect(store.settings.postProcessingStyle == .cleanDictation)
    #expect(defaults.bool(forKey: migrationKey))

    let persistedData = try #require(defaults.data(forKey: defaultsKey))
    let persisted = try JSONDecoder().decode(AppSettings.self, from: persistedData)
    #expect(persisted.postProcessingStyle == .cleanDictation)
}

@MainActor
@Test("SettingsStore runs current Clean Dictation migration even when legacy marker was already set")
func settingsStoreRunsCurrentCleanDictationMigrationEvenWhenLegacyMarkerSet() throws {
    let suiteName = "com.mimir.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { removeTestDefaults(defaults, suiteName: suiteName) }
    let legacyMigrationKey = "com.mimir.migrations.cleanDictationDefault.v1"
    let currentMigrationKey = "com.mimir.migrations.cleanDictationDefault.v2"
    let defaultsKey = "com.mimir.tests.settings"
    defaults.set(true, forKey: legacyMigrationKey)

    let json = """
    {
      "activationMode": "tapToToggle",
      "activationTrigger": {"keyCode": 54, "modifiers": 0, "label": "Right ⌘"},
      "promptRewriteActivationTrigger": {"keyCode": 49, "modifiers": 524288, "label": "⌥ Space"},
      "transcriptionProvider": "whisperKit",
      "transcriptionStrategy": "chunked",
      "whisperKitModel": "largeV3TurboQuantized",
      "postProcessingProvider": "mlx",
      "postProcessingStyle": "structured",
      "insertionStrategy": "clipboardPaste",
      "shouldAutoPaste": true
    }
    """
    defaults.set(Data(json.utf8), forKey: defaultsKey)

    let store = SettingsStore(defaults: defaults, defaultsKey: defaultsKey)

    #expect(store.settings.postProcessingStyle == .cleanDictation)
    #expect(defaults.bool(forKey: currentMigrationKey))
}

@Test("Default AppSettings encoding uses promptRewriteActivationTrigger")
func defaultAppSettingsEncodingUsesPromptRewriteKey() throws {
    let data = try JSONEncoder().encode(AppSettings.default)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(json.keys.contains("promptRewriteActivationTrigger"))
}

@Test("Decoding a legacy hermesActivationTrigger payload populates promptRewriteActivationTrigger")
func decodingLegacyHermesActivationTriggerPopulatesPromptRewrite() throws {
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
    #expect(settings.promptRewriteActivationTrigger.modifiers == 1 << 20)
    #expect(settings.promptRewriteActivationTrigger.label == "⌘ Return")
}

@MainActor
@Test("App model preloads the current session and rebuilt sessions")
func appModelPreloadsCurrentAndRebuiltSessions() async {
    let first = SessionSpy(snapshots: [DictationSnapshot()])
    let second = SessionSpy(snapshots: [DictationSnapshot()])
    var sessions = [first, second]
    let suiteName = "com.mimir.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defer { removeTestDefaults(defaults, suiteName: suiteName) }
    let model = MimirAppModel(store: SettingsStore(defaults: defaults)) { _ in
        sessions.removeFirst()
    }

    await model.preloadSession()
    #expect(await first.preloadCount == 1)
    #expect(await second.preloadCount == 0)

    model.rebuildSession()
    await model.preloadSession()
    #expect(await first.preloadCount == 1)
    #expect(await second.preloadCount == 1)
}

@MainActor
@Test("App model reflects session errors after failed start")
func appModelRefreshesErrorStateWhenStartFails() async {
    let session = SessionSpy(
        snapshots: [
            DictationSnapshot(phase: .idle, lastTranscript: nil),
            DictationSnapshot(phase: .error(message: "Mic missing"), lastTranscript: nil)
        ],
        pressError: MimirError.notImplemented("Mic missing")
    )
    let model = MimirAppModel(session: session)

    await #expect(throws: MimirError.notImplemented("Mic missing")) {
        try await model.startDictation()
    }

    #expect(model.phase == .error(message: "Mic missing"))
    #expect(model.lastTranscript == nil)
}

@MainActor
@Test("App model records only press-to-release duration, not post-release processing time")
func appModelRecordsRecordingDurationBeforeReleaseProcessing() async throws {
    let session = SessionSpy(
        snapshots: [
            DictationSnapshot(phase: .idle, lastTranscript: nil),
            DictationSnapshot(phase: .recording, lastTranscript: nil),
            DictationSnapshot(
                phase: .idle,
                lastTranscript: "texto final",
                lastSessionMetrics: SessionMetrics(audioSeconds: nil, transcriptionSeconds: 0.35, streamingUsed: false)
            )
        ],
        releaseDelayNanoseconds: 350_000_000
    )
    let model = MimirAppModel(session: session)

    try await model.startDictation()
    try? await Task.sleep(nanoseconds: 40_000_000)
    try await model.stopDictation()

    let entry = try #require(model.history.entries.first)
    let duration = try #require(entry.durationSeconds)
    let metricAudioSeconds = try #require(entry.sessionMetrics?.audioSeconds)
    #expect(duration < 0.20)
    #expect(metricAudioSeconds < 0.20)
}

@MainActor
@Test("App model reflects recording and completed transcript states")
func appModelPublishesSessionSnapshotChanges() async throws {
    let transcription = SpeechTranscription(
        text: "texto final",
        language: "pt",
        metrics: TranscriptionMetrics(audioLoading: 0.15, fullPipeline: 1.1, realTimeFactor: 0.44, firstTokenLatency: 0.22)
    )
    let session = SessionSpy(
        snapshots: [
            DictationSnapshot(phase: .idle, lastTranscript: nil),
            DictationSnapshot(phase: .recording, lastTranscript: nil),
            DictationSnapshot(phase: .idle, lastTranscript: "texto final", lastTranscription: transcription)
        ]
    )
    let model = MimirAppModel(session: session)

    #expect(model.phase == .idle)
    #expect(model.lastTranscript == nil)

    try await model.startDictation()
    #expect(model.phase == .recording)

    try await model.stopDictation()
    #expect(model.phase == .idle)
    #expect(model.lastTranscript == "texto final")
    #expect(model.lastTranscription == transcription)
    #expect(await session.pressCount == 1)
    #expect(await session.releaseCount == 1)
}

@MainActor
@Test("App model stores raw transcription separately from final polished text")
func appModelStoresRawTranscriptionInHistory() async throws {
    let rawTranscription = SpeechTranscription(text: "texto bruto com pausa e repetição", language: "pt")
    let session = SessionSpy(
        snapshots: [
            DictationSnapshot(phase: .idle, lastTranscript: nil),
            DictationSnapshot(phase: .recording, lastTranscript: nil),
            DictationSnapshot(phase: .idle, lastTranscript: "Texto final polido.", lastTranscription: rawTranscription)
        ]
    )
    let model = MimirAppModel(session: session)

    try await model.startDictation()
    try await model.stopDictation()

    let entry = try #require(model.history.entries.first)
    #expect(entry.text == "Texto final polido.")
    #expect(entry.rawText == "texto bruto com pausa e repetição")
}

private actor InserterSpy: TextInserting {
    var insertedTexts: [String] = []

    func insert(_ text: String) async throws {
        insertedTexts.append(text)
    }
}

private actor PostProcessorSpy: TextPostProcessing {
    let result: String
    var receivedTranscripts: [String] = []
    var receivedIntents: [PolishIntent] = []

    init(result: String) {
        self.result = result
    }

    func polish(_ transcript: String) async throws -> String {
        try await polish(transcript, intent: .defaults)
    }

    func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        receivedTranscripts.append(transcript)
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

private actor SessionSpy: DictationControlling {
    private let snapshots: [DictationSnapshot]
    private let pressError: Error?
    private let releaseError: Error?
    private let releaseDelayNanoseconds: UInt64
    private var snapshotIndex = 0
    var pressCount = 0
    var releaseCount = 0
    var preloadCount = 0

    init(
        snapshots: [DictationSnapshot],
        pressError: Error? = nil,
        releaseError: Error? = nil,
        releaseDelayNanoseconds: UInt64 = 0
    ) {
        self.snapshots = snapshots
        self.pressError = pressError
        self.releaseError = releaseError
        self.releaseDelayNanoseconds = releaseDelayNanoseconds
    }

    var snapshot: DictationSnapshot {
        snapshots[min(snapshotIndex, snapshots.count - 1)]
    }

    func handleActivationPressed() async throws {
        pressCount += 1
        snapshotIndex = min(snapshotIndex + 1, snapshots.count - 1)
        if let pressError {
            throw pressError
        }
    }

    func handleActivationReleased() async throws {
        releaseCount += 1
        if releaseDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: releaseDelayNanoseconds)
        }
        snapshotIndex = min(snapshotIndex + 1, snapshots.count - 1)
        if let releaseError {
            throw releaseError
        }
    }

    func handleActivationCancelled() async throws {
        snapshotIndex = min(snapshotIndex + 1, snapshots.count - 1)
    }

    func preload() async {
        preloadCount += 1
    }
}


@Test("WhisperKit configuration prewarms and loads models eagerly")
func whisperKitConfigurationPrewarmsAndLoadsEagerly() {
    let config = WhisperKitProvider.makeConfiguration(modelName: "openai_whisper-large-v3_turbo_954MB")
    // prewarm força a especialização ANE do Core ML (sem ela o decode roda em
    // fallback ~5× mais lento); load garante tokenizer pronto no preload.
    #expect(config.prewarm == true)
    #expect(config.load == true)
    #expect(config.model == "openai_whisper-large-v3_turbo_954MB")
}

/// Deletes a test's UserDefaults suite, including the empty plist cfprefsd
/// would otherwise leave in ~/Library/Preferences after every run.
func removeTestDefaults(_ defaults: UserDefaults, suiteName: String) {
    defaults.removePersistentDomain(forName: suiteName)
    let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: file)
}

// MARK: - Speech level meter

private func meterLevels(noiseDB: Float, speechDB: Float, seconds: Int = 6) -> (silence: [Float], speech: [Float]) {
    var meter = SpeechLevelMeter()
    var silence: [Float] = []
    var speech: [Float] = []
    let rate = 23
    for t in 0..<(seconds * rate) {
        let second = Float(t) / Float(rate)
        let noise = noiseDB + 3 * sin(Float(t) * 2.3)
        // Speech: ~5 syllables a second, with a short pause every 1.5 s.
        let syllable = sin(Float.pi * (second * 5).truncatingRemainder(dividingBy: 1))
        let inPause = second.truncatingRemainder(dividingBy: 1.5) > 1.3
        let isSpeech = second >= 2
        let db = isSpeech && !inPause
            ? speechDB + 3 * sin(Float(t) * 1.7) - (1 - syllable) * 14
            : noise
        let level = meter.level(forRMS: pow(10, db / 20))
        if second > 0.5 && !isSpeech { silence.append(level) }
        if second > 3 { speech.append(level) }
    }
    return (silence, speech)
}

private func mean(_ values: [Float]) -> Float {
    values.reduce(0, +) / Float(values.count)
}

private func spread(_ values: [Float]) -> Float {
    let m = mean(values)
    return sqrt(values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Float(values.count))
}

@Test("Speech level meter: normal voice sits mid-bar and moves, room noise stays flat")
func speechLevelMeterNormalVoice() {
    let result = meterLevels(noiseDB: -55, speechDB: -28)
    #expect(result.silence.max()! < 0.15)
    #expect((0.2...0.5).contains(mean(result.speech)))
    #expect(spread(result.speech) > 0.05)
    // Ordinary speech must not pin the bars at the top.
    #expect(result.speech.filter { $0 > 0.9 }.count * 10 < result.speech.count)
}

@Test("Speech level meter adapts to a quiet mic and a noisy room")
func speechLevelMeterAdapts() {
    let quiet = meterLevels(noiseDB: -62, speechDB: -40)
    #expect(mean(quiet.speech) > 0.12)

    let noisy = meterLevels(noiseDB: -42, speechDB: -26)
    #expect(mean(noisy.silence) < 0.15)
    #expect(mean(noisy.speech) > 0.05)

    let loud = meterLevels(noiseDB: -55, speechDB: -18)
    #expect(loud.speech.filter { $0 > 0.9 }.count * 10 < loud.speech.count)
}

// MARK: - Separate dictation and prompt cleanup

@Test("Dictation and prompt use their own post-processors")
func dictationAndPromptUseSeparateProcessors() async throws {
    let dictation = PostProcessorSpy(result: "Texto do ditado")
    let prompt = PostProcessorSpy(result: "Prompt reescrito")
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: "ignored")),
        postProcessor: dictation,
        promptPostProcessor: prompt,
        textInserter: InserterSpy()
    )

    _ = try await pipeline.process(transcription: SpeechTranscription(text: "um ditado qualquer"), defaultIntent: .defaults)
    _ = try await pipeline.process(transcription: SpeechTranscription(text: "um prompt qualquer"), defaultIntent: .promptEngineer)

    #expect(await dictation.receivedTranscripts == ["um ditado qualquer"])
    #expect(await prompt.receivedTranscripts == ["um prompt qualquer"])
}

@Test("Dictation with cleanup off never calls the prompt model")
func dictationOffSkipsAI() async throws {
    let prompt = PostProcessorSpy(result: "Prompt reescrito")
    let inserter = InserterSpy()
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: "ignored")),
        postProcessor: nil,
        promptPostProcessor: prompt,
        textInserter: inserter
    )

    let result = try await pipeline.process(transcription: SpeechTranscription(text: "só um ditado"), defaultIntent: .defaults)

    #expect(result.outputText == "Só um ditado.")
    #expect(await prompt.receivedTranscripts.isEmpty)
}

@Test("A model note about the text is never pasted")
func modelCommentaryIsRejected() async throws {
    let note = "(Removed as a standalone closing artifact with no addressee or context.)"
    let pipeline = LocalPipeline(
        speechToText: SpeechSpy(result: SpeechTranscription(text: "ignored")),
        postProcessor: PostProcessorSpy(result: note),
        textInserter: InserterSpy()
    )

    let result = try await pipeline.process(transcription: SpeechTranscription(text: "Tchau."), defaultIntent: .defaults)

    #expect(result.outputText == "Tchau.")
    #expect(LocalPipeline.isModelCommentary("Gostei do header.", original: "gostei do header") == false)
}

@Test("Farewells invented in the middle of a dictation are dropped")
func midTextFarewellsAreDropped() {
    let raw = "Esse header não gostei. Tchau. A parte dos requests ficou boa. Obrigado. Mostra só cinco."
    #expect(DictationTextCleaner.stripMidTextFarewells(raw) == "Esse header não gostei. A parte dos requests ficou boa. Mostra só cinco.")
    // A real sign-off at the end is the trailing rule's job; a lone thanks stays.
    #expect(DictationTextCleaner.stripMidTextFarewells("Obrigado.") == "Obrigado.")
    #expect(DictationTextCleaner.stripMidTextFarewells("Valeu pela ajuda. Tchau.") == "Valeu pela ajuda. Tchau.")
}

@Test("Settings saved before the split keep one provider for both modes")
func settingsBeforeSplitKeepProviderForPrompt() throws {
    let json = """
    {
      "activationMode": "tapToToggle",
      "activationTrigger": {"keyCode": 54, "modifiers": 0, "label": "Right ⌘"},
      "transcriptionProvider": "whisperKit",
      "postProcessingProvider": "anthropic",
      "insertionStrategy": "clipboardPaste",
      "shouldAutoPaste": true
    }
    """
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    #expect(settings.postProcessingProvider == .anthropic)
    #expect(settings.promptPostProcessingProvider == .anthropic)
    #expect(AppSettings.default.promptPostProcessingProvider == .mlx)
}

@MainActor
@Test("Cleanup set to Off stays off after the one-time migration")
func cleanupOffSticks() throws {
    let suiteName = "com.mimir.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { removeTestDefaults(defaults, suiteName: suiteName) }
    let key = "com.mimir.tests.settings"

    let first = SettingsStore(defaults: defaults, defaultsKey: key)
    first.settings.postProcessingProvider = .disabled

    let reopened = SettingsStore(defaults: defaults, defaultsKey: key)
    #expect(reopened.settings.postProcessingProvider == .disabled)
}

@Test("Hesitation sounds and stuttered words are cleaned without touching intended repeats")
func hesitationsAndStuttersAreCleaned() {
    #expect(DictationTextCleaner.clean("Ahn, eu acho que os os testes passaram") == "Eu acho que os testes passaram.")
    #expect(DictationTextCleaner.clean("Isso com com hum o cache") == "Isso com o cache.")
    // Kept: comma between, "o que que", "ah" as interjection, "humano".
    #expect(DictationTextCleaner.clean("Não, não. O que que é isso") == "Não, não. O que que é isso.")
    #expect(DictationTextCleaner.clean("Ah, entendi o lado humano") == "Ah, entendi o lado humano.")
}
