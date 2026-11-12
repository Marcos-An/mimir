import Foundation
import Testing
@testable import MimirCore

// O pós-processador MLX é o componente mais pesado (~1,7 GB residentes).
// Carregá-lo no launch do app deixa essa memória presa desde o login, mesmo
// que o usuário não dite nada por horas. A transcrição é o que precisa estar
// pronta na hora; o polish só é usado depois da fala terminar, então pode ser
// aquecido quando a gravação começa — o tempo de fala esconde o load.

@Test("App launch preload warms only the transcription provider")
func launchPreloadWarmsOnlyTranscriptionProvider() async throws {
    let speech = WarmableSpeechSpy()
    let post = WarmablePostProcessorSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: PreloadRecorderSpy(),
        pipeline: LocalPipeline(speechToText: speech, postProcessor: post, textInserter: PreloadInserterSpy())
    )

    await session.preload()

    #expect(await speech.preloadCount == 1)
    #expect(await post.preloadCount == 0)
}

@Test("Starting a recording warms the post-processor in the background")
func startingRecordingWarmsPostProcessor() async throws {
    let speech = WarmableSpeechSpy()
    let post = WarmablePostProcessorSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: PreloadRecorderSpy(),
        pipeline: LocalPipeline(speechToText: speech, postProcessor: post, textInserter: PreloadInserterSpy())
    )

    try await session.handleActivationPressed()

    // O aquecimento é disparado sem bloquear o início da gravação.
    var waited = 0
    while await post.preloadCount == 0, waited < 100 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 1
    }
    #expect(await post.preloadCount == 1)
    #expect(await session.snapshot.phase == .recording)
}

@Test("Each recording re-warms the post-processor")
func repeatedRecordingsRewarmPostProcessor() async throws {
    // O preload do provider é idempotente/barato (load cacheado no MLX; no
    // cloud revive a conexão TLS — pool ocioso por horas custava ~13s no
    // polish), então CADA gravação re-aquece.
    let speech = WarmableSpeechSpy()
    let post = WarmablePostProcessorSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: PreloadRecorderSpy(),
        pipeline: LocalPipeline(speechToText: speech, postProcessor: post, textInserter: PreloadInserterSpy())
    )

    try await session.handleActivationPressed()
    var waited = 0
    while await post.preloadCount == 0, waited < 100 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 1
    }
    try await session.handleActivationCancelled()
    try await session.handleActivationPressed()
    waited = 0
    while await post.preloadCount < 2, waited < 100 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        waited += 1
    }

    #expect(await post.preloadCount == 2)
}

@Test("Pipeline exposes separate warmup for transcription and post-processing")
func pipelineExposesSeparateWarmups() async throws {
    let speech = WarmableSpeechSpy()
    let post = WarmablePostProcessorSpy()
    let pipeline = LocalPipeline(speechToText: speech, postProcessor: post, textInserter: PreloadInserterSpy())

    await pipeline.preloadTranscription()
    #expect(await speech.preloadCount == 1)
    #expect(await post.preloadCount == 0)

    await pipeline.preloadPostProcessing()
    #expect(await speech.preloadCount == 1)
    #expect(await post.preloadCount == 1)
}

// MARK: - Spies

private actor WarmableSpeechSpy: WarmableSpeechToTextProviding {
    var preloadCount = 0

    func preload() async {
        preloadCount += 1
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        SpeechTranscription(text: "texto")
    }
}

private actor WarmablePostProcessorSpy: WarmableTextPostProcessing {
    var preloadCount = 0

    func preload() async {
        preloadCount += 1
    }

    func polish(_ transcript: String) async throws -> String { transcript }

    func polish(_ transcript: String, intent: PolishIntent) async throws -> String { transcript }

    func polish(
        _ transcript: String,
        intent: PolishIntent,
        onChunk: @Sendable (String) async -> Void
    ) async throws -> String {
        await onChunk(transcript)
        return transcript
    }
}

private actor PreloadRecorderSpy: AudioRecording {
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    func beginCapture() async throws -> AudioCaptureSession {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        self.continuation = continuation
        return AudioCaptureSession(
            format: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
            chunks: stream
        )
    }

    func finishCapture() async throws -> FinishedCapture {
        continuation?.finish()
        continuation = nil
        return FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-preload-test.wav"))
    }
}

private actor PreloadInserterSpy: TextInserting {
    func insert(_ text: String) async throws {}
}
