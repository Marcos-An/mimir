import Foundation
import Testing
@testable import MimirCore

// Falha e "nenhuma fala detectada" precisam de sinal visível: antes, a ilha
// simplesmente desaparecia e o usuário não sabia se o texto tinha colado.

@MainActor
@Test("Session failure surfaces an error notice and acknowledges the error back to idle")
func sessionFailureSurfacesErrorNoticeAndAcknowledges() async throws {
    let session = NoticeSessionSpy()
    let model = MimirAppModel(session: session)
    await session.waitForSubscriber()

    await session.push(DictationSnapshot(phase: .error(message: "Microphone busy")))
    try await waitUntil { model.sessionNotice != nil }

    #expect(model.sessionNotice == .error(message: "Microphone busy"))
    // A fase volta pra idle: o ícone do menu bar não pode ficar preso em erro.
    try await waitUntil { await session.acknowledgeCount == 1 }
    #expect(await session.acknowledgeCount == 1)
}

@MainActor
@Test("No-speech completion surfaces a dedicated notice")
func noSpeechCompletionSurfacesNotice() async throws {
    let session = NoticeSessionSpy()
    let model = MimirAppModel(session: session)
    await session.waitForSubscriber()

    await session.push(DictationSnapshot(phase: .idle, lastCompletion: .noSpeech))
    try await waitUntil { model.sessionNotice != nil }

    #expect(model.sessionNotice == .noSpeech)
}

@MainActor
@Test("Successful completion does not surface any notice")
func successfulCompletionSurfacesNoNotice() async throws {
    let session = NoticeSessionSpy()
    let model = MimirAppModel(session: session)
    await session.waitForSubscriber()

    await session.push(DictationSnapshot(phase: .idle, lastTranscript: "texto", lastCompletion: .inserted))
    try? await Task.sleep(nanoseconds: 80_000_000)

    #expect(model.sessionNotice == nil)
}

@MainActor
@Test("A new recording clears a pending notice")
func newRecordingClearsPendingNotice() async throws {
    let session = NoticeSessionSpy()
    let model = MimirAppModel(session: session)
    await session.waitForSubscriber()

    await session.push(DictationSnapshot(phase: .idle, lastCompletion: .noSpeech))
    try await waitUntil { model.sessionNotice != nil }

    await session.push(DictationSnapshot(phase: .recording))
    try await waitUntil { model.sessionNotice == nil }

    #expect(model.sessionNotice == nil)
}

@Test("Controller reports no-speech completion when the transcript is empty")
func controllerReportsNoSpeechCompletion() async throws {
    let recorder = NoticeRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-notice-empty.wav"))
    )
    let speech = NoticeSpeechSpy(error: MimirError.emptyTranscript)
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: NoticeInserterSpy())
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    #expect(await session.snapshot.lastCompletion == .noSpeech)
}

@Test("Controller reports inserted completion on success and clears it on the next recording")
func controllerReportsInsertedCompletionAndClearsOnNextRecording() async throws {
    let recorder = NoticeRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-notice-ok.wav"))
    )
    let speech = NoticeSpeechSpy(result: SpeechTranscription(text: "tudo certo", language: "pt"))
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: NoticeInserterSpy())
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()
    #expect(await session.snapshot.lastCompletion == .inserted)

    try await session.handleActivationPressed()
    #expect(await session.snapshot.lastCompletion == nil)
}

@Test("Acknowledging an error moves the controller out of the error phase")
func acknowledgingErrorMovesControllerOutOfErrorPhase() async throws {
    let recorder = NoticeRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-notice-fail.wav")),
        finishError: MimirError.notImplemented("Recorder failed")
    )
    let speech = NoticeSpeechSpy(result: SpeechTranscription(text: "ignored"))
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: NoticeInserterSpy())
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()
    #expect(await session.snapshot.phase == .error(message: "Recorder failed"))

    await session.acknowledgeError()
    #expect(await session.snapshot.phase == .idle)
}

// MARK: - Helpers

@MainActor
private func waitUntil(
    timeoutNanoseconds: UInt64 = 2_000_000_000,
    _ condition: @MainActor () async -> Bool
) async throws {
    var waited: UInt64 = 0
    let step: UInt64 = 20_000_000
    while waited < timeoutNanoseconds {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: step)
        waited += step
    }
    #expect(Bool(false), "Condition never became true within the timeout")
}

private actor NoticeSessionSpy: DictationControlling {
    private var continuation: AsyncStream<DictationSnapshot>.Continuation?
    private var current = DictationSnapshot()
    var acknowledgeCount = 0

    var snapshot: DictationSnapshot { current }

    func handleActivationPressed() async throws {}
    func handleActivationReleased() async throws {}
    func handleActivationCancelled() async throws {}

    func snapshotUpdates() -> AsyncStream<DictationSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.yield(current)
        }
    }

    func acknowledgeError() async {
        acknowledgeCount += 1
        current.phase = .idle
    }

    /// O model assina o stream numa Task, então a assinatura pode não estar
    /// pronta no instante seguinte ao init — esperar evita empurrar no vazio.
    func waitForSubscriber(timeoutNanoseconds: UInt64 = 2_000_000_000) async {
        var waited: UInt64 = 0
        let step: UInt64 = 10_000_000
        while continuation == nil, waited < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
    }

    func push(_ snapshot: DictationSnapshot) {
        current = snapshot
        continuation?.yield(snapshot)
    }
}

private actor NoticeRecorderSpy: AudioRecording {
    let finished: FinishedCapture
    let finishError: Error?
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(finished: FinishedCapture, finishError: Error? = nil) {
        self.finished = finished
        self.finishError = finishError
    }

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
        if let finishError { throw finishError }
        return finished
    }
}

private actor NoticeSpeechSpy: SpeechToTextProviding {
    private let result: SpeechTranscription?
    private let error: Error?

    init(result: SpeechTranscription) {
        self.result = result
        self.error = nil
    }

    init(error: Error) {
        self.result = nil
        self.error = error
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        if let error { throw error }
        return result ?? SpeechTranscription(text: "")
    }
}

private actor NoticeInserterSpy: TextInserting {
    var insertedTexts: [String] = []
    func insert(_ text: String) async throws { insertedTexts.append(text) }
}
