import Foundation

/// Decide onde cortar o áudio acumulado em segmentos para transcrição.
/// O corte só acontece em vales de silêncio (RMS baixo) — nunca em posição
/// arbitrária no meio da fala, que é o que fazia o Whisper "comer" palavras
/// nas fronteiras de segmento.
public enum SilenceSegmenter {
    public struct Config: Sendable {
        /// Segundos de áudio acumulado a partir dos quais procuramos um corte.
        public var targetSeconds: Double
        /// Target para cortes SEGUINTES ao primeiro. Cortar mais cedo encolhe a
        /// cauda que sobra pra transcrever no stop — latência menor, mesma
        /// qualidade.
        ///
        /// Cada segmento herda a cauda do texto anterior como prompt do decoder
        /// (`WhisperKitProvider.performTranscription`).
        public var followUpTargetSeconds: Double
        /// Janela (contada do fim do áudio) onde o vale é procurado.
        public var searchWindowSeconds: Double
        /// Margem final que nunca entra no segmento — a fala pode estar no meio
        /// de uma palavra exatamente no fim do áudio disponível.
        public var minTrailingSeconds: Double
        /// Atingida esta duração, corta no mínimo da janela mesmo sem vale
        /// qualificado — segmento não pode crescer além da janela do Whisper.
        public var hardCapSeconds: Double
        /// RMS máximo (samples normalizados [-1, 1]) para contar como silêncio.
        public var silenceRMSFloor: Float
        /// Alternativa relativa: fração do RMS médio do áudio acumulado.
        /// O threshold efetivo é o MAIOR entre floor e relativo — ambientes
        /// ruidosos ainda têm vales, só que mais altos.
        public var silenceRelativeFactor: Float

        public init(
            targetSeconds: Double,
            followUpTargetSeconds: Double? = nil,
            searchWindowSeconds: Double,
            minTrailingSeconds: Double,
            hardCapSeconds: Double,
            silenceRMSFloor: Float,
            silenceRelativeFactor: Float
        ) {
            self.targetSeconds = targetSeconds
            self.followUpTargetSeconds = followUpTargetSeconds ?? targetSeconds
            self.searchWindowSeconds = searchWindowSeconds
            self.minTrailingSeconds = minTrailingSeconds
            self.hardCapSeconds = hardCapSeconds
            self.silenceRMSFloor = silenceRMSFloor
            self.silenceRelativeFactor = silenceRelativeFactor
        }

        /// Histórico: todos os segmentos ~10s até nov/2026.
        ///
        /// O primeiro era 20s, e a telemetria de 200 sessões mostrou o preço:
        /// abaixo de 20s de fala NENHUM corte acontecia, o `accumulator` ficava
        /// vazio e o stop caía no ramo `no-segments` — o arquivo inteiro ia pro
        /// Whisper só DEPOIS de soltar o gatilho. Fallback em 100% dos ditados
        /// abaixo de 20s contra 0% acima, e ditado curto saía MAIS LENTO que
        /// ditado longo (mediana de stop→paste 4,79s contra 3,59s). Com 10s o
        /// primeiro corte cabe em ditado de 10–20s, que é onde estava a perda.
        ///
        /// Nov/2026: 8s / 6s with a 3s search window. Telemetry of 200 sessions
        /// showed a median of 7.8s of audio still untranscribed at stop (the
        /// tail), costing ~1.7s of the ~3s stop→paste. Follow-up segments now
        /// cut at ~3–5.5s, so the tail stays around 3s; every segment gets the
        /// end of the previous text as decoder context (`contextTail()`), so
        /// shorter segments keep sentence continuity.
        public static let `default` = Config(
            targetSeconds: 8,
            followUpTargetSeconds: 6,
            searchWindowSeconds: 3,
            minTrailingSeconds: 0.5,
            hardCapSeconds: 28,
            silenceRMSFloor: 0.015,
            silenceRelativeFactor: 0.35
        )
    }

    /// Índice (inclusivo) do último chunk do segmento a cortar, ou nil para
    /// continuar acumulando. O chamador extrai `chunks[0...index]` e mantém o
    /// restante como início do próximo segmento — nenhum áudio se perde.
    public static func cutIndex(
        chunks: [AudioChunk],
        sampleRate: Double,
        config: Config = .default,
        hasPriorSegment: Bool = false
    ) -> Int? {
        guard sampleRate > 0, !chunks.isEmpty else { return nil }

        var totalSeconds: Double = 0
        var endTimes = [Double]()
        endTimes.reserveCapacity(chunks.count)
        for chunk in chunks {
            totalSeconds += Double(chunk.frameCount) / sampleRate
            endTimes.append(totalSeconds)
        }
        let effectiveTarget = hasPriorSegment ? config.followUpTargetSeconds : config.targetSeconds
        guard totalSeconds >= effectiveTarget else { return nil }

        // Candidatos: chunks cujo FIM cai dentro da janela de busca, excluída
        // a margem final.
        let windowStart = totalSeconds - config.searchWindowSeconds
        let windowEnd = totalSeconds - config.minTrailingSeconds
        var quietestIndex: Int?
        var quietestRMS = Float.greatestFiniteMagnitude
        for (index, endTime) in endTimes.enumerated() {
            guard endTime >= windowStart, endTime <= windowEnd else { continue }
            if chunks[index].rms < quietestRMS {
                quietestRMS = chunks[index].rms
                quietestIndex = index
            }
        }
        guard let quietestIndex else { return nil }

        let meanRMS = chunks.reduce(Float(0)) { $0 + $1.rms } / Float(chunks.count)
        let threshold = max(config.silenceRMSFloor, config.silenceRelativeFactor * meanRMS)
        if quietestRMS <= threshold {
            return quietestIndex
        }
        // Sem vale qualificado: espera — a não ser que o segmento já esteja no
        // limite da janela do Whisper.
        if totalSeconds >= config.hardCapSeconds {
            return quietestIndex
        }
        return nil
    }
}
