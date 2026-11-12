import Foundation
import Testing
@testable import MimirCore

// Cobertura do fluxo de transcrição redesenhado:
// - ditado curto → arquivo completo em janela única ("no-segments")
// - ditado longo → segmentos cortados em silêncio + cauda com contexto
// - falha/vazio suspeito no caminho segmentado → segmento volta pra fila; só
//   quando nada foi commitado (ou o teto de re-enfileiramentos estoura) o stop
//   recorre ao arquivo completo
// - teardown solta o microfone

private let testSegmenterConfig = SilenceSegmenter.Config(
    targetSeconds: 2,
    searchWindowSeconds: 1.5,
    minTrailingSeconds: 0.25,
    hardCapSeconds: 4,
    silenceRMSFloor: 0.015,
    silenceRelativeFactor: 0.35
)

/// Chunks de 0.5s (8000 frames @16kHz) com RMS controlado.
private func flowChunks(rmsValues: [Float]) -> [AudioChunk] {
    rmsValues.enumerated().map { offset, rms in
        AudioChunk(
            id: ChunkID(sequence: offset),
            data: Data(count: 16_000),
            frameCount: 8_000,
            rms: rms
        )
    }
}

/// Fala contínua com um vale de silêncio no índice 4: corta o segmento em
/// chunks 0...4 e deixa o chunk 5 como cauda.
private let speechWithValley: [Float] = [0.2, 0.2, 0.2, 0.2, 0.001, 0.2]

@Test("Long dictation cuts a segment at silence and carries context into the tail")
func segmentedFlowCutsAtSilenceAndCarriesContext() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-segmented.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "primeiro trecho ditado", language: "pt")),
        .success(SpeechTranscription(text: "e o final", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastTranscript == "Primeiro trecho ditado e o final.")
    #expect(await inserter.insertedTexts == ["Primeiro trecho ditado e o final."])
    // Nenhuma transcrição de arquivo completo — só os dois trechos in-memory.
    #expect(await speech.receivedFileURLs.isEmpty)
    let contexts = await speech.receivedContexts
    try #require(contexts.count == 2)
    #expect(contexts[0] == nil)
    // A cauda recebe o texto do segmento anterior como contexto do decoder.
    #expect(contexts[1] == "primeiro trecho ditado")
    let metrics = try #require(snapshot.lastSessionMetrics)
    #expect(metrics.streamingUsed == true)
    #expect(metrics.streamingCommitCount == 1)
    #expect(metrics.fallbackReason == nil)
}

@Test("Tail with no speech accepts the committed text without full-file recovery")
func tailEmptyTranscriptAcceptsCommittedText() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-empty-tail.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "só o segmento", language: "pt")),
        .failure(MimirError.emptyTranscript)
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "Só o segmento.")
    #expect(await speech.receivedFileURLs.isEmpty)
    #expect(snapshot.lastSessionMetrics?.streamingUsed == true)
}

@Test("Segment transcription failure recovers with a single full-file transcription")
func segmentFailureRecoversWithFullFile() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-recovery.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .failure(MimirError.transcriptionFailed("segment failed")),
        .success(SpeechTranscription(text: "texto inteiro recuperado", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "Texto inteiro recuperado.")
    #expect(await speech.receivedFileURLs == [finalURL])
    let metrics = try #require(snapshot.lastSessionMetrics)
    #expect(metrics.streamingUsed == false)
    #expect(metrics.fallbackReason == "segmented-path-recovery")
    #expect(metrics.incrementalErrorCount == 1)
}

@Test("A failed segment mid-speech keeps the committed work — no full-file reread")
func failedSegmentKeepsCommittedWork() async throws {
    // O conserto de set/2026. Antes, UM segmento ruim no meio da fala setava
    // `segmentedPathBroken`, o `maybeCutSegment` desligava a segmentação pelo
    // resto da gravação e o stop re-lia o arquivo inteiro — jogando fora os
    // segmentos já transcritos (medido em prod: uma sessão perdeu 10 commits e
    // pagou 25,4s de re-transcrição). Agora o trecho volta pra fila e o que já
    // estava commitado sobrevive.
    //
    // Com `maxSegmentRequeues = 0` este teste fica vermelho nos quatro
    // #expect — é o comportamento antigo.
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-requeue.wav")
    // 12 chunks × 0.5s = 6s, vales nos índices 4 e 9 → dois cortes.
    var rms = Array(repeating: Float(0.2), count: 12)
    rms[4] = 0.001
    rms[9] = 0.001
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: rms),
        chunkYieldDelayNanoseconds: 20_000_000
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "primeiro trecho", language: "pt")),
        .failure(MimirError.transcriptionFailed("segment failed")),
        .success(SpeechTranscription(text: "cauda final", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 600_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    let metrics = try #require(snapshot.lastSessionMetrics)
    // O ganho: nenhuma re-leitura do WAV completo...
    #expect(await speech.receivedFileURLs.isEmpty)
    #expect(metrics.fallbackReason == nil)
    // ...e o texto já commitado antes da falha continua no resultado.
    // lowercased: o DictationTextCleaner capitaliza a primeira letra do texto.
    #expect(snapshot.lastTranscript?.lowercased().contains("primeiro trecho") == true)
    #expect(metrics.incrementalErrorCount == 1)
}

@Test("Empty segment over real speech retries once and then breaks to full-file recovery")
func loudEmptySegmentBreaksToFullFileRecovery() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-loud-empty.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    // Vazio duas vezes (tentativa + retry cirúrgico) → só então o caminho
    // segmentado é condenado e o release re-transcreve o arquivo completo.
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "", language: "pt")),
        .success(SpeechTranscription(text: "", language: "pt")),
        .success(SpeechTranscription(text: "recuperado do arquivo", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "Recuperado do arquivo.")
    #expect(await speech.receivedFileURLs == [finalURL])
    #expect(snapshot.lastSessionMetrics?.fallbackReason == "segmented-path-recovery")
    #expect(snapshot.lastSessionMetrics?.incrementalEmptyResultCount == 1)
}

@Test("Empty segment over true silence is skipped without breaking the session")
func silentEmptySegmentIsSkippedWithoutRecovery() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-silent-empty.wav")
    // Sessão inteira em silêncio (RMS abaixo do floor): o segmento vazio é
    // legítimo — nenhuma palavra existia ali.
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: Array(repeating: 0.001, count: 6))
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "", language: "pt")),
        .success(SpeechTranscription(text: "final curto", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    // Sem commits → release transcreve o arquivo completo, mas como fluxo
    // normal ("no-segments"), não como recuperação de erro.
    #expect(snapshot.lastTranscript == "Final curto.")
    #expect(snapshot.lastSessionMetrics?.fallbackReason == "no-segments")
    #expect(snapshot.lastSessionMetrics?.incrementalEmptyResultCount == 1)
}

@Test("Short dictation transcribes the whole file exactly once")
func shortDictationTranscribesWholeFileOnce() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-short.wav")
    let recorder = FlowRecorderSpy(finished: FinishedCapture(fileURL: finalURL))
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "ditado curto direto", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "Ditado curto direto.")
    #expect(await speech.receivedFileURLs == [finalURL])
    #expect(await speech.receivedContexts.isEmpty)
    #expect(snapshot.lastSessionMetrics?.streamingUsed == false)
    #expect(snapshot.lastSessionMetrics?.fallbackReason == "no-segments")
}

@Test("Batch strategy never segments during recording")
func batchStrategySkipsSegmentation() async throws {
    var settings = AppSettings.default
    settings.transcriptionStrategy = .batch

    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-batch.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "texto batch", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: settings,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    #expect(await session.snapshot.lastTranscript == "Texto batch.")
    #expect(await speech.receivedContexts.isEmpty)
    #expect(await speech.receivedFileURLs == [finalURL])
}

@Test("Joined segmented text strips a YouTube-artifact farewell at the tail")
func joinedTextStripsYouTubeFarewellAtTail() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-farewell.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "Confere o warning.", language: "pt")),
        .success(SpeechTranscription(text: "Obrigado por assistir.", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    #expect(await session.snapshot.lastTranscript == "Confere o warning.")
    #expect(await inserter.insertedTexts == ["Confere o warning."])
}

// MARK: - Polish único no release
// O pós-processador (cloud/local) roda UMA vez com o texto completo no stop —
// o polish por segmento foi removido junto com o MLX no caminho crítico.

@Test("Empty segment over real speech recovers with a surgical same-segment retry")
func loudEmptySegmentRecoversWithRetry() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-retry-ok.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    // 1ª tentativa vazia, retry do MESMO segmento devolve texto: o caminho
    // segmentado sobrevive e nada é re-transcrito do arquivo.
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "", language: "pt")),
        .success(SpeechTranscription(text: "primeiro trecho ditado", language: "pt")),
        .success(SpeechTranscription(text: "e o final", language: "pt"))
    ])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "Primeiro trecho ditado e o final.")
    #expect(await speech.receivedFileURLs.isEmpty)
    let metrics = try #require(snapshot.lastSessionMetrics)
    #expect(metrics.streamingUsed == true)
    #expect(metrics.fallbackReason == nil)
    #expect(metrics.incrementalEmptyResultCount == 1)
}

@Test("Segmented dictation polishes the whole joined text exactly once at release")
func wholeTextPolishRunsOnceAtRelease() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-whole-polish.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "primeiro trecho ditado", language: "pt")),
        .success(SpeechTranscription(text: "e o final", language: "pt"))
    ])
    let polisher = FlowPolisherSpy()
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: polisher, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let calls = await polisher.calls
    #expect(calls == [FlowPolisherSpy.Call(transcript: "primeiro trecho ditado e o final", intent: .defaults)])
    #expect(await inserter.insertedTexts == ["P(primeiro trecho ditado e o final)"])
    let snapshot = await session.snapshot
    #expect(snapshot.lastTranscript == "P(primeiro trecho ditado e o final)")
    #expect(snapshot.lastSessionMetrics?.streamingUsed == true)
}

@Test("Spoken command prefix routes the whole text to the matching intent")
func commandPrefixRoutesWholeText() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-inc-prefix.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "prompt cria um teste", language: "pt")),
        .success(SpeechTranscription(text: "com dois casos", language: "pt"))
    ])
    let polisher = FlowPolisherSpy()
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: polisher, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let calls = await polisher.calls
    #expect(calls == [FlowPolisherSpy.Call(transcript: "cria um teste com dois casos", intent: .promptEngineer)])
    #expect(await inserter.insertedTexts == ["P(cria um teste com dois casos)"])
}

@Test("Empty tail polishes only the committed text")
func emptyTailPolishesCommittedTextOnly() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-inc-empty-tail.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "só o segmento", language: "pt")),
        .failure(MimirError.emptyTranscript)
    ])
    let polisher = FlowPolisherSpy()
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: polisher, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    #expect(await polisher.calls.count == 1)
    #expect(await inserter.insertedTexts == ["P(só o segmento)"])
}

@Test("Prompt / Rewrite mode rewrites the whole text")
func promptRewriteModeRewritesWholeText() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-inc-rewrite.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "primeiro trecho", language: "pt")),
        .success(SpeechTranscription(text: "final", language: "pt"))
    ])
    let polisher = FlowPolisherSpy()
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: polisher, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed(mode: .promptRewrite)
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let calls = await polisher.calls
    #expect(calls == [FlowPolisherSpy.Call(transcript: "primeiro trecho final", intent: .promptEngineer)])
    #expect(await inserter.insertedTexts == ["P(primeiro trecho final)"])
}

@Test("Farewell-only tail is stripped before the single whole-text polish")
func farewellTailStrippedBeforeWholeTextPolish() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-inc-farewell.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(outcomes: [
        .success(SpeechTranscription(text: "Confere o warning.", language: "pt")),
        .success(SpeechTranscription(text: "Obrigado por assistir.", language: "pt"))
    ])
    let polisher = FlowPolisherSpy()
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: polisher, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 200_000_000)
    try await session.handleActivationReleased()

    let calls = await polisher.calls
    #expect(calls == [FlowPolisherSpy.Call(transcript: "Confere o warning.", intent: .defaults)])
    #expect(await inserter.insertedTexts == ["P(Confere o warning.)"])
}

@Test("Release stops capture immediately and then awaits the in-flight segment")
func releaseStopsCaptureBeforeAwaitingInFlightSegment() async throws {
    let finalURL = URL(fileURLWithPath: "/tmp/mimir-flow-inflight.wav")
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: finalURL),
        scriptedChunks: flowChunks(rmsValues: speechWithValley)
    )
    let speech = FlowSpeechSpy(
        outcomes: [
            .success(SpeechTranscription(text: "segmento demorado", language: "pt")),
            .success(SpeechTranscription(text: "cauda", language: "pt"))
        ],
        delayNanoseconds: 300_000_000
    )
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try? await Task.sleep(nanoseconds: 150_000_000)

    let releaseTask = Task { try await session.handleActivationReleased() }
    try? await Task.sleep(nanoseconds: 80_000_000)

    // O microfone é liberado antes de esperar a transcrição em voo.
    #expect(await recorder.finishCallCount == 1)
    #expect(await session.snapshot.phase == .transcribing)

    try await releaseTask.value
    #expect(await session.snapshot.lastTranscript == "Segmento demorado cauda.")
}

@Test("Teardown releases the microphone and resets the session")
func teardownReleasesMicrophoneAndResetsSession() async throws {
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-flow-teardown.wav"))
    )
    let speech = FlowSpeechSpy(outcomes: [])
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: FlowInserterSpy()),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    #expect(await session.snapshot.phase == .recording)

    await session.teardown()

    #expect(await recorder.finishCallCount == 1)
    #expect(await session.snapshot.phase == .idle)
}

@Test("Empty Whisper transcript behaves like cancellation and does not insert")
func emptyWhisperTranscriptCancelsWithoutError() async throws {
    let recorder = FlowRecorderSpy(
        finished: FinishedCapture(fileURL: URL(fileURLWithPath: "/tmp/mimir-flow-empty.wav"))
    )
    let speech = FlowSpeechSpy(outcomes: [.failure(MimirError.emptyTranscript)])
    let inserter = FlowInserterSpy()
    let session = DictationSessionController(
        settings: .default,
        recorder: recorder,
        pipeline: LocalPipeline(speechToText: speech, postProcessor: nil, textInserter: inserter),
        segmenterConfig: testSegmenterConfig
    )

    try await session.handleActivationPressed()
    try await session.handleActivationReleased()

    let snapshot = await session.snapshot
    #expect(snapshot.phase == .idle)
    #expect(snapshot.lastTranscript == nil)
    #expect(snapshot.lastTranscription == nil)
    #expect(snapshot.lastSessionMetrics == nil)
    #expect(snapshot.activeMode == nil)
    #expect(await inserter.insertedTexts.isEmpty)
}

@Test("WhisperKit float sample conversion maps Int16 PCM to normalized floats")
func whisperFloatSamplesConversionMapsInt16ToNormalizedFloats() {
    let values: [Int16] = [0, Int16.max, Int16.min, 16_384]
    var data = Data()
    for value in values {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let capture = IncrementalAudioCapture(
        audioFormat: AudioCaptureFormat(sampleRate: 16_000, channelCount: 1),
        chunks: [AudioChunk(id: ChunkID(sequence: 0), data: data, frameCount: values.count)]
    )

    let samples = WhisperKitProvider.floatSamples(from: capture)

    #expect(samples.count == 4)
    #expect(samples[0] == 0)
    #expect(abs(samples[1] - 1.0) < 0.001)
    #expect(samples[2] < -1.0 - 0.001 || abs(samples[2] + 1.0) < 0.002)
    #expect(abs(samples[3] - 0.5) < 0.001)
}

@MainActor
@Test("App model applies pushed snapshots without polling")
func appModelAppliesPushedSnapshotsWithoutPolling() async throws {
    let sessionSpy = PushSessionSpy()
    let model = MimirAppModel(session: sessionSpy)
    #expect(model.phase == .idle)

    let recording = DictationSnapshot(phase: .recording)
    var sawRecording = false
    for _ in 0..<50 {
        await sessionSpy.push(recording)
        try? await Task.sleep(nanoseconds: 20_000_000)
        if model.phase == .recording {
            sawRecording = true
            break
        }
    }
    #expect(sawRecording)
}

// MARK: - Spies

private actor FlowRecorderSpy: AudioRecording {
    let finished: FinishedCapture
    let scriptedChunks: [AudioChunk]
    /// Espaçamento entre chunks. Zero = todos de uma vez (default histórico).
    ///
    /// Com entrega instantânea o consumer drena o stream inteiro sem soltar o
    /// actor do controller, então o Task do primeiro segmento só roda DEPOIS do
    /// último chunk — e a sessão nunca passa de um corte. Espaçar a entrega dá
    /// ao segmento a chance de commitar entre um chunk e o próximo, que é a
    /// única forma de exercitar mais de um segmento por sessão aqui.
    private let chunkYieldDelayNanoseconds: UInt64
    var beginCallCount = 0
    var finishCallCount = 0
    private var continuation: AsyncStream<AudioChunk>.Continuation?

    init(
        finished: FinishedCapture,
        scriptedChunks: [AudioChunk] = [],
        chunkYieldDelayNanoseconds: UInt64 = 0
    ) {
        self.finished = finished
        self.scriptedChunks = scriptedChunks
        self.chunkYieldDelayNanoseconds = chunkYieldDelayNanoseconds
    }

    func beginCapture() async throws -> AudioCaptureSession {
        beginCallCount += 1
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        self.continuation = continuation
        if chunkYieldDelayNanoseconds == 0 {
            for chunk in scriptedChunks {
                continuation.yield(chunk)
            }
        } else {
            let chunks = scriptedChunks
            let delay = chunkYieldDelayNanoseconds
            Task {
                for chunk in chunks {
                    try? await Task.sleep(nanoseconds: delay)
                    continuation.yield(chunk)
                }
            }
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
        return finished
    }
}

private enum FlowOutcome {
    case success(SpeechTranscription)
    case failure(Error)
}

private actor FlowSpeechSpy: SpeechToTextProviding {
    private var outcomes: [FlowOutcome]
    private let delayNanoseconds: UInt64
    var receivedFileURLs: [URL] = []
    var receivedContexts: [String?] = []
    var receivedLanguageHints: [String?] = []

    init(outcomes: [FlowOutcome], delayNanoseconds: UInt64 = 0) {
        self.outcomes = outcomes
        self.delayNanoseconds = delayNanoseconds
    }

    private func nextOutcome() throws -> SpeechTranscription {
        guard !outcomes.isEmpty else { return SpeechTranscription(text: "") }
        switch outcomes.removeFirst() {
        case .success(let transcription):
            return transcription
        case .failure(let error):
            throw error
        }
    }

    func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        receivedFileURLs.append(audioFileURL)
        receivedLanguageHints.append(languageHint)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try nextOutcome()
    }

    func transcribe(
        audio: IncrementalAudioCapture,
        languageHint: String?,
        previousContext: String?
    ) async throws -> SpeechTranscription {
        receivedContexts.append(previousContext)
        receivedLanguageHints.append(languageHint)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return try nextOutcome()
    }
}

/// Polidor determinístico: devolve "P(<texto>)" e registra (texto, intent) de
/// cada chamada. Índices em `failingCallIndexes` lançam erro.
private actor FlowPolisherSpy: TextPostProcessing {
    struct Call: Equatable {
        let transcript: String
        let intent: PolishIntent
    }

    private(set) var calls: [Call] = []
    private let failingCallIndexes: Set<Int>

    init(failingCallIndexes: Set<Int> = []) {
        self.failingCallIndexes = failingCallIndexes
    }

    func polish(_ transcript: String) async throws -> String {
        try await polish(transcript, intent: .defaults)
    }

    func polish(_ transcript: String, intent: PolishIntent) async throws -> String {
        let index = calls.count
        calls.append(Call(transcript: transcript, intent: intent))
        if failingCallIndexes.contains(index) {
            throw MimirError.transcriptionFailed("polish failed")
        }
        return "P(" + transcript + ")"
    }
}

private actor FlowInserterSpy: TextInserting {
    var insertedTexts: [String] = []

    func insert(_ text: String) async throws {
        insertedTexts.append(text)
    }
}

private actor PushSessionSpy: DictationControlling {
    private var continuation: AsyncStream<DictationSnapshot>.Continuation?

    var snapshot: DictationSnapshot { DictationSnapshot() }

    func handleActivationPressed() async throws {}
    func handleActivationReleased() async throws {}
    func handleActivationCancelled() async throws {}

    func snapshotUpdates() -> AsyncStream<DictationSnapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func push(_ snapshot: DictationSnapshot) {
        continuation?.yield(snapshot)
    }
}
