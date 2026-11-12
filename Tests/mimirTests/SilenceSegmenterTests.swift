import Foundation
import Testing
@testable import MimirCore

/// Helpers: chunks de 0.5s (8000 frames @16kHz) com RMS controlado por teste.
private func makeChunk(sequence: Int, rms: Float) -> AudioChunk {
    AudioChunk(
        id: ChunkID(sequence: sequence),
        data: Data(count: 16_000),
        frameCount: 8_000,
        rms: rms
    )
}

private func makeChunks(rmsValues: [Float]) -> [AudioChunk] {
    rmsValues.enumerated().map { makeChunk(sequence: $0.offset, rms: $0.element) }
}

private let testConfig = SilenceSegmenter.Config(
    targetSeconds: 10,
    searchWindowSeconds: 4,
    minTrailingSeconds: 0.5,
    hardCapSeconds: 16,
    silenceRMSFloor: 0.015,
    silenceRelativeFactor: 0.35
)

@Test("No cut before the accumulated audio reaches the target duration")
func noCutBeforeTargetSeconds() {
    // 19 chunks × 0.5s = 9.5s < 10s target.
    let chunks = makeChunks(rmsValues: Array(repeating: 0.2, count: 18) + [0.001])
    #expect(SilenceSegmenter.cutIndex(chunks: chunks, sampleRate: 16_000, config: testConfig) == nil)
}

@Test("Cuts at the quietest chunk inside the search window when it is silence-like")
func cutsAtQuietValleyInsideSearchWindow() {
    // 24 chunks × 0.5s = 12s ≥ target. Janela de busca: últimos 4s menos os
    // 0.5s finais → índices 16...22. Vale claro no índice 19.
    var rms = Array(repeating: Float(0.2), count: 24)
    rms[19] = 0.005
    rms[3] = 0.001 // vale MAIS silencioso, mas fora da janela — deve ser ignorado.
    let chunks = makeChunks(rmsValues: rms)
    #expect(SilenceSegmenter.cutIndex(chunks: chunks, sampleRate: 16_000, config: testConfig) == 19)
}

@Test("Ignores valleys inside the trailing margin — speech may be mid-word there")
func ignoresValleyInsideTrailingMargin() {
    // Vale só no último chunk (dentro da margem de 0.5s) → não corta.
    var rms = Array(repeating: Float(0.2), count: 24)
    rms[23] = 0.001
    let chunks = makeChunks(rmsValues: rms)
    #expect(SilenceSegmenter.cutIndex(chunks: chunks, sampleRate: 16_000, config: testConfig) == nil)
}

@Test("Continuous loud speech defers the cut until the hard cap")
func continuousSpeechDefersCutUntilHardCap() {
    // 12s de fala contínua (sem vale): espera.
    let loud12s = makeChunks(rmsValues: Array(repeating: 0.25, count: 24))
    #expect(SilenceSegmenter.cutIndex(chunks: loud12s, sampleRate: 16_000, config: testConfig) == nil)

    // 16s (hard cap): corta no mínimo da janela mesmo sem silêncio qualificado.
    var rms = Array(repeating: Float(0.25), count: 32)
    rms[28] = 0.18 // menos alto, ainda não "silêncio" — mas é o melhor disponível.
    let loud16s = makeChunks(rmsValues: rms)
    #expect(SilenceSegmenter.cutIndex(chunks: loud16s, sampleRate: 16_000, config: testConfig) == 28)
}

@Test("Relative threshold qualifies valleys in noisy environments")
func relativeThresholdQualifiesValleysInNoisyEnvironments() {
    // Ambiente ruidoso: RMS médio ~0.4; vale de 0.1 < 0.35 × 0.4 = 0.14 qualifica
    // mesmo acima do floor absoluto.
    var rms = Array(repeating: Float(0.4), count: 24)
    rms[20] = 0.1
    let chunks = makeChunks(rmsValues: rms)
    #expect(SilenceSegmenter.cutIndex(chunks: chunks, sampleRate: 16_000, config: testConfig) == 20)
}

@Test("Default config fits inside the Whisper window")
func defaultConfigFitsInsideWhisperWindow() {
    let config = SilenceSegmenter.Config.default
    #expect(config.hardCapSeconds <= 30)
    #expect(config.minTrailingSeconds > 0)
    #expect(config.searchWindowSeconds > config.minTrailingSeconds)
}

@Test("Default config cuts a short dictation — no full-file fallback at stop")
func defaultConfigCutsShortDictation() {
    // REGRESSÃO (set/2026): com `targetSeconds: 20` nenhum corte acontecia
    // abaixo de 20s de fala, o accumulator ficava vazio e o stop caía no
    // fallback de arquivo completo. Telemetria: 100% dos ditados <20s.
    // 28 chunks × 0.5s = 14s, vale no índice 22.
    var rms = Array(repeating: Float(0.2), count: 28)
    rms[22] = 0.001
    let chunks = makeChunks(rmsValues: rms)
    #expect(
        SilenceSegmenter.cutIndex(
            chunks: chunks,
            sampleRate: 16_000,
            config: .default
        ) != nil
    )
}

@Test("Follow-up segments cut sooner than the first — smaller tail at stop")
func followUpSegmentsCutSooner() {
    var config = testConfig
    config.followUpTargetSeconds = 4

    // 12 chunks × 0.5s = 6s: abaixo do target inicial (10s), acima do follow-up (4s).
    var rms = Array(repeating: Float(0.2), count: 12)
    rms[9] = 0.001

    let chunks = makeChunks(rmsValues: rms)
    // Sem segmento anterior: ainda não corta.
    #expect(SilenceSegmenter.cutIndex(chunks: chunks, sampleRate: 16_000, config: testConfig) == nil)
    // Com segmento anterior: corta no vale.
    #expect(
        SilenceSegmenter.cutIndex(
            chunks: chunks,
            sampleRate: 16_000,
            config: config,
            hasPriorSegment: true
        ) == 9
    )
}

@Test("Default follow-up target never exceeds the first target")
func defaultFollowUpTargetNeverExceedsFirst() {
    let config = SilenceSegmenter.Config.default
    // Já foram 20s/10s e 10s/10s. Segmentos seguintes herdam o fim do texto
    // anterior como contexto (`contextTail()`), o que permite cortes menores;
    // abaixo de ~5s o Whisper perde contexto acústico demais.
    #expect(config.followUpTargetSeconds <= config.targetSeconds)
    #expect(config.followUpTargetSeconds >= 5)
    #expect(config.targetSeconds <= 10)
    // A janela de busca não pode gerar segmentos muito curtos.
    #expect(config.followUpTargetSeconds - config.searchWindowSeconds >= 2.5)
}
