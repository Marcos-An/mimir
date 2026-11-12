import Foundation
import Testing
@testable import MimirCore

// Áudio muito baixo faz o Whisper alucinar descrições de som ("♫", "[Music]")
// ou devolver texto vazio. A normalização usa o RMS (nível médio de fala) como
// referência — normalizar pelo pico deixava fala baixa com um pico alto quase
// tão baixa quanto entrou (perfil real do histórico: -32 dBFS de média com
// pico a -7).

@Test("Quiet speech is amplified so the RMS reaches the target level")
func quietSpeechIsAmplifiedToTargetRMS() {
    // RMS ~0.025 (~-32 dBFS) com pico isolado alto (0.45) — o perfil que a
    // normalização por pico não resolvia (ganho ficava limitado a ~1.5×).
    var samples = [Float](repeating: 0.025, count: 200)
    for i in stride(from: 0, to: 200, by: 2) { samples[i] = -0.025 }
    samples[100] = 0.45

    let result = AudioGain.normalized(samples)
    let rms = sqrt(result.reduce(Float(0)) { $0 + $1 * $1 } / Float(result.count))
    // Ganho ~4× leva o corpo da fala para perto do alvo (tanh comprime só o topo).
    #expect(rms > AudioGain.targetRMS * 0.8)
}

@Test("Isolated peaks are soft-limited instead of clipping")
func peaksAreSoftLimited() {
    var samples = [Float](repeating: 0.02, count: 100)
    samples[50] = 0.6
    let result = AudioGain.normalized(samples)
    for value in result {
        #expect(abs(value) < 1.0)
    }
    // O pico continua sendo o maior valor — comprimido, não decapitado.
    #expect(result[50] == result.max())
}

@Test("Speech waveform stays proportional in the linear range")
func speechRangeStaysProportional() {
    let samples: [Float] = [0.03, -0.02, 0.01, -0.03]
    let result = AudioGain.normalized(samples)
    // tanh é ~linear nessa faixa: proporções preservadas com folga.
    #expect(abs(result[0] / result[1] - samples[0] / samples[1]) < 0.02)
}

@Test("Gain is capped so near-silence is not blown up into noise")
func gainIsCappedForNearSilence() {
    // RMS ~0.002: ganho necessário seria 50×. O teto evita transformar ruído
    // de fundo em "fala".
    let samples = [Float](repeating: 0.002, count: 100)
    #expect(AudioGain.appliedGain(for: samples) <= AudioGain.maximumGain)
    #expect(AudioGain.appliedGain(for: samples) > 1)
}

@Test("Background noise below the noise floor gets no gain at all")
func noiseFloorGetsNoGain() {
    // RMS ~0.0005 (~-66 dBFS): não é fala baixa, é silêncio com ruído.
    let samples = [Float](repeating: 0.0005, count: 100)
    #expect(AudioGain.appliedGain(for: samples) == 1)
}

@Test("Audio already at a healthy level is left untouched")
func healthyAudioIsLeftUntouched() {
    // RMS ~0.35 — bem acima do alvo.
    let samples: [Float] = [0.5, -0.4, 0.3, -0.2, 0.5, -0.4]
    #expect(AudioGain.normalized(samples) == samples)
    #expect(AudioGain.appliedGain(for: samples) == 1)
}

@Test("Digital silence is returned unchanged instead of dividing by zero")
func digitalSilenceIsUnchanged() {
    let samples: [Float] = [0, 0, 0]
    #expect(AudioGain.normalized(samples) == samples)
    #expect(AudioGain.normalized([]).isEmpty)
}
