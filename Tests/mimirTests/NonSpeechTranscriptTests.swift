import Foundation
import Testing
@testable import MimirCore

// Whisper devolve símbolos de som ("♫", "♪", "[Music]") quando classifica o
// áudio como não-fala. Colar isso no app do usuário é pior que não colar nada:
// não dá pra distinguir de uma falha, e sobrescreve o clipboard com lixo.

@Test("Music symbols alone are treated as no speech")
func musicSymbolsAloneAreNoSpeech() {
    for text in ["♫", "♪", "♫♫", "🎵", "🎶", " ♫ ", "♪ ♪ ♪"] {
        #expect(WhisperKitProvider.isNonSpeechArtifact(text), "esperava não-fala para \(text)")
    }
}

@Test("Punctuation-only output is treated as no speech")
func punctuationOnlyIsNoSpeech() {
    for text in [".", "...", "-", "—", "!?", "…", "·"] {
        #expect(WhisperKitProvider.isNonSpeechArtifact(text), "esperava não-fala para \(text)")
    }
}

@Test("Real speech is never treated as a non-speech artifact")
func realSpeechIsNeverNonSpeech() {
    for text in [
        "Oi, tudo bem?",
        "Sobe a migration antes do deploy.",
        "a",
        "1",
        "Vou ouvir ♫ música depois",
        "OK"
    ] {
        #expect(WhisperKitProvider.isNonSpeechArtifact(text) == false, "esperava fala para \(text)")
    }
}

@Test("Empty and whitespace are treated as no speech")
func emptyIsNoSpeech() {
    #expect(WhisperKitProvider.isNonSpeechArtifact(""))
    #expect(WhisperKitProvider.isNonSpeechArtifact("   \n "))
}

@Test("Cleaning strips bare music symbols so they never reach the user")
func cleaningStripsBareMusicSymbols() {
    #expect(WhisperKitProvider.cleanedTranscriptForTesting("♫") == "")
    #expect(WhisperKitProvider.cleanedTranscriptForTesting("[Music]") == "")
}

@Test("A session whose transcript is only a music symbol reports no speech and pastes nothing")
func musicSymbolSessionReportsNoSpeechAndPastesNothing() async throws {
    let recorder = ArtifactRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-artifact.wav"))
    )
    let speech = ArtifactSpeechSpy(result: SpeechTranscription(text: "♫", language: "pt"))
    let inserter = ArtifactInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter)
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastCompletion == .noSpeech)
    #expect(snapshot.lastTranscript == nil)
    #expect(await inserter.insertedTexts.isEmpty)
}

// MARK: - Spies

private actor ArtifactRecorderSpy: AudioRecording {
    let finished: FinishedCapture
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(finished: FinishedCapture) { self.finished = finished }

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
        return finished
    }
}

private actor ArtifactSpeechSpy: SpeechToTextProviding {
    let result: SpeechTranscription
    init(result: SpeechTranscription) { self.result = result }
    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        result
    }
}

private actor ArtifactInserterSpy: TextInserting {
    var insertedTexts: [String] = []
    func insert(_ text: String) async throws { insertedTexts.append(text) }
}
