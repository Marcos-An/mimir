import Foundation

/// Normalização de nível aplicada ao áudio **antes** de mandar pro Whisper.
///
/// Whisper é treinado com áudio em nível de broadcast. Gravação baixa (mic
/// interno longe da boca, ganho de hardware no mínimo) faz o modelo classificar
/// a faixa como não-fala e devolver descrições de som — "♫", "[Music]" — ou
/// texto vazio em vez de transcrever.
///
/// A referência do ganho é o **RMS** (nível médio de fala), não o pico: fala
/// baixa costuma vir com um ou outro pico alto (plosiva, clique do teclado), e
/// normalizar pelo pico deixava o resto da fala quase tão baixo quanto entrou
/// (medido: fala a -32 dBFS com pico a -7 ganhava só +4 dB). O RMS alvo é
/// ~-20 dBFS; picos que estourariam o fundo de escala são comprimidos por um
/// limitador suave (tanh) em vez de clipados — clipping duro cria harmônicos
/// que atrapalham o ASR.
///
/// O arquivo gravado em disco não é alterado: a normalização acontece só no
/// caminho de transcrição, e a telemetria de dBFS continua medindo o nível
/// real capturado pelo microfone.
public enum AudioGain {
    /// RMS alvo (~-20 dBFS) — faixa prática de fala em nível de broadcast.
    public static let targetRMS: Float = 0.1
    /// Teto de amplificação. Sem ele, silêncio quase absoluto viraria ruído
    /// amplificado — e o Whisper alucina em cima de ruído.
    public static let maximumGain: Float = 12
    /// Abaixo deste pico o sinal é tratado como silêncio digital.
    private static let silenceFloor: Float = 1e-5
    /// RMS abaixo disso (~-60 dBFS) é ruído de fundo, não fala baixa — não
    /// merece ganho nenhum.
    private static let noiseRMSFloor: Float = 0.001

    /// Fator de ganho que será aplicado a estas amostras (1 = nenhum).
    public static func appliedGain(for samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 1 }
        guard let peak = samples.map(abs).max(), peak > silenceFloor else { return 1 }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        guard rms > noiseRMSFloor, rms < targetRMS else { return 1 }
        return min(targetRMS / rms, maximumGain)
    }

    /// Amostras com o ganho aplicado. O limitador tanh é ~linear na faixa de
    /// fala (|x·ganho| < 0.5) e só comprime o topo, então a forma da onda da
    /// fala é preservada enquanto picos isolados dobram suavemente até ±1.
    public static func normalized(_ samples: [Float]) -> [Float] {
        let gain = appliedGain(for: samples)
        guard gain > 1 else { return samples }
        return samples.map { tanh($0 * gain) }
    }
}
