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
    #expect(settings.postProcessingStyle == .structured)
    #expect(settings.insertionStrategy == .clipboardPaste)
    #expect(settings.shouldAutoPaste)
    #expect(settings.preferredLanguage == nil)
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
    #expect(DashboardSection.primaryItems.map(\.title) == ["Painel", "Sessão", "Histórico"])
    #expect(DashboardSection.utilityItems.map(\.title) == ["Permissões", "Configurações"])
    #expect(DashboardSection.settingsItems.map(\.title) == ["Geral", "Áudio", "Pipeline", "Permissões", "Sobre"])
    #expect(DashboardMetric.defaultMetrics.map(\.title) == ["Atalho ativo", "Transcrição", "Inserção", "Idioma"])
    #expect(DashboardChrome.appName == "MIMIR")
    #expect(DashboardChrome.sidebarCardTitle == "Tema próprio, fluxo local")
    #expect(DashboardChrome.sidebarCardBody == "Transcrição nativa para macOS com visual expressivo, foco em velocidade e privacidade no dispositivo.")
    #expect(DashboardChrome.primaryActionTitle == "Começar a transcrever")
    #expect(DashboardPromo.defaultCards.map(\.action) == ["Abrir atalhos", "Revisar permissões"])
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

@Test("Chunked sessions warm up with incremental commits and finalize from full file")
func chunkedSessionWarmsUpAndFinalizesFromFullFile() async throws {
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

    // Durante a gravação, o loop incremental deve ter polled ao menos uma vez.
    #expect(await recorder.incrementalBatchCallCount > 0)

    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    // Texto final vem de uma transcrição do arquivo completo (finished.fileURL).
    #expect(snapshot.lastTranscript == "oi")
    #expect(await inserter.insertedTexts == ["oi"])
    // O arquivo final gravado é sempre visto pelo speech provider no release.
    let receivedURLs = await speech.receivedAudioFileURLs
    #expect(receivedURLs.contains(finalURL))
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
    #expect(batch.concurrentWorkerCount == 4)
    #expect(batch.prefersWordTimestamps == false)
}

@Test("Structured MLX prompt preserves language and only formats faithful dictation")
func structuredMLXPromptPreservesLanguageAndFormattingRules() {
    let prompt = MLXPostProcessor.systemPrompt(for: .structured)

    #expect(prompt.localizedCaseInsensitiveContains("idioma"))
    #expect(prompt.localizedCaseInsensitiveContains("não traduza"))
    #expect(prompt.localizedCaseInsensitiveContains("preserve"))
    #expect(prompt.localizedCaseInsensitiveContains("pontuação"))
    #expect(prompt.localizedCaseInsensitiveContains("parágrafo"))
    #expect(prompt.localizedCaseInsensitiveContains("listas"))
}

@Test("Cleanup MLX prompt stays conservative and avoids structural rewrites")
func cleanupMLXPromptStaysConservative() {
    let prompt = MLXPostProcessor.systemPrompt(for: .cleanup)

    #expect(prompt.localizedCaseInsensitiveContains("ortografia"))
    #expect(prompt.localizedCaseInsensitiveContains("não invente"))
    #expect(prompt.localizedCaseInsensitiveContains("não reorganize") || prompt.localizedCaseInsensitiveContains("mínima intervenção") || prompt.localizedCaseInsensitiveContains("Corrija apenas"))
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
    var receivedAudioFileURL: URL?
    var receivedAudioFileURLs: [URL] = []
    var receivedLanguageHint: String?

    init(result: SpeechTranscription) {
        self.remainingResults = [result]
    }

    init(results: [SpeechTranscription]) {
        self.remainingResults = results
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        receivedAudioFileURL = audioFileURL
        receivedAudioFileURLs.append(audioFileURL)
        receivedLanguageHint = languageHint
        if remainingResults.count > 1 {
            return remainingResults.removeFirst()
        }
        return remainingResults.first ?? SpeechTranscription(text: "")
    }
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
