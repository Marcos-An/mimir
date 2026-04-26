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
    #expect(settings.whisperKitModel == .largeV3TurboQuantized)
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
    #expect(DashboardSection.settingsItems.map(\.title) == ["General", "Audio", "Pipeline", "Permissions", "About"])
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
    let recorder = RecorderSpy(finished: FinishedCapture(fileURL: audioURL, span: nil))
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
    #expect(snapshot.lastTranscript == "oi mundo")
    #expect(snapshot.lastTranscription?.text == "oi mundo")
    #expect(snapshot.lastTranscription?.language == "pt")
    #expect(snapshot.lastTranscription?.metrics == metrics)
    #expect(await recorder.finishCallCount == 1)
    #expect(await transcriber.receivedAudioFileURL == audioURL)
    #expect(await inserter.insertedTexts == ["oi mundo"])
}

@Test("Chunked sessions reuse incremental commits instead of re-transcribing full file")
func chunkedSessionReusesIncrementalCommits() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-final", byteCount: 2048)
    let span = ChunkSpan(startSequence: 0, endSequence: 1)
    let batch = IncrementalChunkBatch(
        chunks: makeChunks(startSequence: 0, count: 2, payloadPerChunk: 1000),
        span: span,
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
    )
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: span),
        incrementalBatches: [batch]
    )
    let speech = SpeechSpy(results: [SpeechTranscription(text: "oi", language: "pt")])
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        incrementalPollingIntervalNanoseconds: 10_000_000,
        safetyChunksAtTail: 0,
        minimumDeltaSeconds: 0.01
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 40_000_000)

    #expect(await recorder.incrementalBatchCallCount > 0)

    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastTranscript == "oi")
    #expect(await inserter.insertedTexts == ["oi"])
    // Todos os chunks foram commitados no incremental — release usa o committed
    // direto, sem chamar o speech provider com o finalURL.
    let receivedURLs = await speech.receivedAudioFileURLs
    #expect(receivedURLs.contains(finalURL) == false)
    #expect(snapshot.lastSessionMetrics?.streamingUsed == true)
}

@Test("Default incremental window commits after about five safe seconds")
func defaultIncrementalWindowCommitsAfterFiveSafeSeconds() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-default-window", byteCount: 2048)
    let span = ChunkSpan(startSequence: 0, endSequence: 17)
    let batch = IncrementalChunkBatch(
        chunks: makeChunks(startSequence: 0, count: 18, payloadPerChunk: 16_000),
        span: span,
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
    )
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: span),
        incrementalBatches: [batch]
    )
    let speech = SpeechSpy(results: [
        SpeechTranscription(text: "primeiro bloco", language: "pt"),
        SpeechTranscription(text: "cauda", language: "pt")
    ])
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        incrementalPollingIntervalNanoseconds: 10_000_000
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 40_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "primeiro bloco cauda")
    #expect(snapshot.lastSessionMetrics?.streamingUsed == true)
    #expect(snapshot.lastSessionMetrics?.streamingCommitCount == 1)
}

@Test("Release waits for an in-flight incremental commit instead of cancelling into no-commit fallback")
func releaseWaitsForInFlightIncrementalCommit() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-inflight-final", byteCount: 2048)
    let span = ChunkSpan(startSequence: 0, endSequence: 1)
    let batch = IncrementalChunkBatch(
        chunks: makeChunks(startSequence: 0, count: 2, payloadPerChunk: 1000),
        span: span,
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
    )
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: span),
        incrementalBatches: [batch]
    )
    let speech = SpeechSpy(
        results: [SpeechTranscription(text: "commit em andamento", language: "pt")],
        delayNanoseconds: 120_000_000
    )
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        incrementalPollingIntervalNanoseconds: 10_000_000,
        safetyChunksAtTail: 0,
        minimumDeltaSeconds: 0.01
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 40_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "commit em andamento")
    #expect(snapshot.lastSessionMetrics?.streamingUsed == true)
    #expect(snapshot.lastSessionMetrics?.streamingCommitCount == 1)
    #expect(snapshot.lastSessionMetrics?.fallbackReason == nil)
    let receivedURLs = await speech.receivedAudioFileURLs
    #expect(receivedURLs.contains(finalURL) == false)
}

@Test("Release falls back to full-file transcription when no commits happened")
func releaseFallsBackWhenNoIncrementalCommits() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-full", byteCount: 1024)
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: nil)
    )
    let speech = SpeechSpy(result: SpeechTranscription(text: "texto completo", language: "pt"))
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter)
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "texto completo")
    let receivedURLs = await speech.receivedAudioFileURLs
    #expect(receivedURLs == [finalURL])
    #expect(snapshot.lastSessionMetrics?.streamingUsed == false)
    #expect(snapshot.lastSessionMetrics?.fallbackReason == "no-commit")
}

@Test("Incremental empty transcript counts as empty result instead of error")
func incrementalEmptyTranscriptCountsAsEmptyResultInsteadOfError() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-incremental-empty", byteCount: 1024)
    let span = ChunkSpan(startSequence: 0, endSequence: 1)
    let batch = IncrementalChunkBatch(
        chunks: makeChunks(startSequence: 0, count: 2, payloadPerChunk: 1000),
        span: span,
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
    )
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: span),
        incrementalBatches: [batch]
    )
    let speech = SpeechSpy(
        results: [SpeechTranscription(text: "texto final", language: "pt")],
        errors: [MimirError.emptyTranscript]
    )
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        incrementalPollingIntervalNanoseconds: 10_000_000,
        safetyChunksAtTail: 0,
        minimumDeltaSeconds: 0.01
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 40_000_000)
    try await session.handleActivationReleased()

    let metrics = try #require(await session.snapshot.lastSessionMetrics)
    #expect(metrics.streamingUsed == false)
    #expect(metrics.incrementalAttemptCount == 1)
    #expect(metrics.incrementalEmptyResultCount == 1)
    #expect(metrics.incrementalErrorCount == 0)
    #expect(metrics.lastIncrementalError == nil)
    #expect(await inserter.insertedTexts == ["texto final"])
}

@Test("Empty Whisper transcript behaves like cancellation and does not insert or post-process")
func emptyWhisperTranscriptCancelsWithoutError() async throws {
    let finalURL = try makeTempAudioFile(named: "mimir-empty", byteCount: 256)
    let recorder = RecorderSpy(finished: FinishedCapture(fileURL: finalURL, span: nil))
    let speech = SpeechSpy(error: MimirError.emptyTranscript)
    let postProcessor = PostProcessorSpy(result: "should not run")
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: postProcessor, textInserter: inserter)
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastTranscript == nil)
    #expect(snapshot.lastTranscription == nil)
    #expect(snapshot.lastSessionMetrics == nil)
    #expect(snapshot.activeMode == nil)
    #expect(await postProcessor.receivedTranscripts.isEmpty)
    #expect(await inserter.insertedTexts.isEmpty)
}

@Test("Incremental pipeline materializes in-memory chunk captures without reusing recorder WAV snapshots")
func incrementalPipelineMaterializesInMemoryChunkCaptures() async throws {
    let span = ChunkSpan(startSequence: 0, endSequence: 1)
    let capture = makeIncrementalCapture(spanCount: 2, payloadPerChunk: 1600)
    let artifact = IncrementalCaptureArtifact(audioCapture: capture, span: span)
    let speech = SpeechSpy(result: SpeechTranscription(text: "chunk text", language: "pt"))
    let pipeline = LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: InserterSpy())

    let transcription = try await pipeline.transcribeIncrementalArtifact(artifact, languageHint: "pt-BR")

    #expect(transcription.text == "chunk text")
    let url = try #require(await speech.receivedAudioFileURL)
    #expect(url.lastPathComponent.hasPrefix("mimir-incremental-") == true)
    #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

@Test("Assembler keeps the latest transcription per span and exposes exact matches")
func assemblerKeepsLatestPerSpanAndExposesExactMatches() {
    var assembler = IncrementalTranscriptAssembler()
    let firstSpan = ChunkSpan(startSequence: 0, endSequence: 1)
    let secondSpan = ChunkSpan(startSequence: 0, endSequence: 3)

    assembler.apply(span: firstSpan, transcription: SpeechTranscription(text: "primeiro"))
    assembler.apply(span: secondSpan, transcription: SpeechTranscription(text: "segundo"))
    assembler.apply(span: firstSpan, transcription: SpeechTranscription(text: "primeiro revisado"))

    #expect(assembler.transcription(exactlyMatching: firstSpan)?.text == "primeiro revisado")
    #expect(assembler.transcription(exactlyMatching: secondSpan)?.text == "segundo")
    #expect(assembler.bestCurrentTranscription()?.text == "segundo")
    #expect(assembler.transcription(exactlyMatching: ChunkSpan(startSequence: 0, endSequence: 7)) == nil)
}

@Test("Batch sessions skip hidden incremental polling")
func batchSessionSkipsHiddenIncrementalPolling() async throws {
    var settings = AppSettings.default
    settings.transcriptionStrategy = .batch

    let finalURL = try makeTempAudioFile(named: "mimir-batch", byteCount: 1024)
    let batch = IncrementalChunkBatch(
        chunks: makeChunks(startSequence: 0, count: 1, payloadPerChunk: 512),
        span: ChunkSpan(startSequence: 0, endSequence: 0),
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1)
    )
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: finalURL, span: ChunkSpan(startSequence: 0, endSequence: 0)),
        incrementalBatches: [batch]
    )
    let speech = SpeechSpy(result: SpeechTranscription(text: "texto final"))
    let inserter = InserterSpy()
    let session = DictationSessionController(
        settings: settings,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        incrementalPollingIntervalNanoseconds: 10_000_000
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 40_000_000)

    #expect(await recorder.incrementalBatchCallCount == 0)
    #expect(await session.snapshot.lastTranscript == nil)

    try await session.handleActivationReleased()
    #expect(await speech.receivedAudioFileURLs == [finalURL])
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

@Test("Clean Dictation MLX prompt is moderately conservative and removes pause artifacts")
func cleanDictationMLXPromptIsModeratelyConservative() {
    let prompt = MLXPostProcessor.systemPrompt(for: .cleanDictation)

    #expect(prompt.localizedCaseInsensitiveContains("editor"))
    #expect(prompt.localizedCaseInsensitiveContains("same language"))
    #expect(prompt.localizedCaseInsensitiveContains("do not translate"))
    #expect(prompt.localizedCaseInsensitiveContains("preserve"))
    #expect(prompt.localizedCaseInsensitiveContains("punctuation"))
    #expect(prompt.localizedCaseInsensitiveContains("ellipses") || prompt.localizedCaseInsensitiveContains("reticências"))
    #expect(prompt.localizedCaseInsensitiveContains("ultraconservative") == false)
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
    #expect(await inserter.insertedTexts == ["Prompt limpo"])
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

    #expect(result.outputText == "itens de projeto")
    #expect(result.transcription.text == "itens de projeto")
    #expect(result.transcription.language == "pt")
    #expect(result.transcription.metrics == metrics)
    #expect(await speech.receivedLanguageHint == "pt-BR")
    #expect(await inserter.insertedTexts == ["itens de projeto"])
}

@Test("Press surfaces recorder failures as an error state")
func pressTransitionsToErrorWhenRecorderFails() async {
    let recorder = RecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-test.wav"), span: nil),
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
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-test.wav"), span: nil),
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
    var incrementalBatches: [IncrementalChunkBatch]
    let beginError: Error?
    let finishError: Error?
    var beginCallCount = 0
    var finishCallCount = 0
    var incrementalBatchCallCount = 0

    init(
        finished: FinishedCapture,
        incrementalBatches: [IncrementalChunkBatch] = [],
        beginError: Error? = nil,
        finishError: Error? = nil
    ) {
        self.finished = finished
        self.incrementalBatches = incrementalBatches
        self.beginError = beginError
        self.finishError = finishError
    }

    func beginCapture() async throws {
        beginCallCount += 1
        if let beginError {
            throw beginError
        }
    }

    func finishCapture() async throws -> FinishedCapture {
        finishCallCount += 1
        if let finishError {
            throw finishError
        }
        return finished
    }

    func nextIncrementalChunkBatch() async throws -> IncrementalChunkBatch? {
        incrementalBatchCallCount += 1
        guard !incrementalBatches.isEmpty else { return nil }
        return incrementalBatches.removeFirst()
    }
}

private actor SpeechSpy: SpeechToTextProviding {
    var remainingResults: [SpeechTranscription]
    var remainingErrors: [Error]
    let delayNanoseconds: UInt64
    var receivedAudioFileURL: URL?
    var receivedAudioFileURLs: [URL] = []
    var receivedLanguageHint: String?

    init(result: SpeechTranscription, delayNanoseconds: UInt64 = 0) {
        self.remainingResults = [result]
        self.remainingErrors = []
        self.delayNanoseconds = delayNanoseconds
    }

    init(results: [SpeechTranscription], delayNanoseconds: UInt64 = 0) {
        self.remainingResults = results
        self.remainingErrors = []
        self.delayNanoseconds = delayNanoseconds
    }

    init(results: [SpeechTranscription], errors: [Error], delayNanoseconds: UInt64 = 0) {
        self.remainingResults = results
        self.remainingErrors = errors
        self.delayNanoseconds = delayNanoseconds
    }

    init(error: Error, delayNanoseconds: UInt64 = 0) {
        self.remainingResults = []
        self.remainingErrors = [error]
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        receivedAudioFileURL = audioFileURL
        receivedAudioFileURLs.append(audioFileURL)
        receivedLanguageHint = languageHint
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
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
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
@Test("SettingsStore preserves structured when migration marker is already set")
func settingsStorePreservesStructuredWhenMigrationMarkerSet() throws {
    let suiteName = "com.mimir.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let migrationKey = "com.mimir.migrations.cleanDictationDefault.v1"
    let defaultsKey = "com.mimir.tests.settings"
    defaults.set(true, forKey: migrationKey)

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

    #expect(store.settings.postProcessingStyle == .structured)
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
    private var snapshotIndex = 0
    var pressCount = 0
    var releaseCount = 0

    init(snapshots: [DictationSnapshot], pressError: Error? = nil, releaseError: Error? = nil) {
        self.snapshots = snapshots
        self.pressError = pressError
        self.releaseError = releaseError
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
        snapshotIndex = min(snapshotIndex + 1, snapshots.count - 1)
        if let releaseError {
            throw releaseError
        }
    }

    func handleActivationCancelled() async throws {
        snapshotIndex = min(snapshotIndex + 1, snapshots.count - 1)
    }
}

private func makeTempAudioFile(named prefix: String, byteCount: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).wav")
    try Data(repeating: 0x1, count: byteCount).write(to: url)
    return url
}

private func makeChunks(startSequence: Int, count: Int, payloadPerChunk: Int) -> [AudioChunk] {
    (0..<count).map { offset in
        AudioChunk(
            id: ChunkID(sequence: startSequence + offset),
            data: Data(repeating: UInt8(0x11 + offset), count: payloadPerChunk),
            frameCount: payloadPerChunk / 2
        )
    }
}

private func makeIncrementalCapture(spanCount: Int, payloadPerChunk: Int) -> IncrementalAudioCapture {
    IncrementalAudioCapture(
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1, bitsPerSample: 16),
        chunks: makeChunks(startSequence: 0, count: spanCount, payloadPerChunk: payloadPerChunk)
    )
}
