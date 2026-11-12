import Foundation

/// Acumula o texto dos segmentos já transcritos durante a gravação.
/// Como os segmentos são cortados em silêncio real (SilenceSegmenter), a
/// junção com espaço simples é segura — não há palavra partida na fronteira.
public struct SegmentAccumulator: Sendable {
    public private(set) var segmentCount: Int = 0
    public private(set) var text: String = ""
    public private(set) var language: String?
    public private(set) var lastMetrics: TranscriptionMetrics?

    public init() {}

    public var isEmpty: Bool { text.isEmpty }

    public mutating func append(_ transcription: SpeechTranscription) {
        let trimmed = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = text.isEmpty ? trimmed : text + " " + trimmed
        segmentCount += 1
        if let language = transcription.language {
            self.language = language
        }
        if let metrics = transcription.metrics {
            lastMetrics = metrics
        }
    }

    /// Cauda do texto acumulado, cortada em fronteira de palavra, usada como
    /// contexto (promptTokens) da transcrição do próximo segmento — é o que
    /// mantém pontuação/concordância coerentes entre segmentos.
    public func contextTail(maxCharacters: Int = 240) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.count > maxCharacters else { return text }
        let rawTail = String(text.suffix(maxCharacters))
        // Descarta a primeira palavra possivelmente partida pelo corte de chars.
        guard let spaceIndex = rawTail.firstIndex(of: " ") else { return rawTail }
        let tail = String(rawTail[rawTail.index(after: spaceIndex)...])
        return tail.isEmpty ? rawTail : tail
    }

    public mutating func reset() {
        segmentCount = 0
        text = ""
        language = nil
        lastMetrics = nil
    }
}
