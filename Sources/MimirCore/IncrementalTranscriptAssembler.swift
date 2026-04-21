import Foundation

struct IncrementalTranscriptAssembler: Sendable {
    struct Entry: Equatable, Sendable {
        var span: ChunkSpan
        var transcription: SpeechTranscription
    }

    private(set) var entries: [Entry] = []
    /// Maior span commitado como seguro — transcrito sobre audio que termina
    /// numa margem conservadora antes do áudio mais recente, pra garantir que
    /// nunca fique no meio de uma palavra.
    private(set) var committedSpan: ChunkSpan?
    /// Transcrição committada para `committedSpan`. O controller concatena
    /// esta com a transcrição do tail no release.
    private(set) var committedTranscription: SpeechTranscription?

    var latestEntry: Entry? {
        entries.last
    }

    mutating func apply(span: ChunkSpan, transcription: SpeechTranscription) {
        if let index = entries.firstIndex(where: { $0.span == span }) {
            entries[index].transcription = transcription
            maybePromoteCommit(span: span, transcription: transcription)
            return
        }
        entries.append(Entry(span: span, transcription: transcription))
        entries.sort { lhs, rhs in
            if lhs.span.endSequence != rhs.span.endSequence {
                return lhs.span.endSequence < rhs.span.endSequence
            }
            return lhs.span.startSequence < rhs.span.startSequence
        }
        maybePromoteCommit(span: span, transcription: transcription)
    }

    /// Delta commit: `span` deve cobrir **apenas** chunks novos depois do
    /// último `committedSpan.endSequence`. O texto é acrescentado ao
    /// `committedTranscription` acumulado em vez de substituí-lo.
    mutating func appendDelta(span: ChunkSpan, transcription: SpeechTranscription) {
        let newText = transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return }

        entries.append(Entry(span: span, transcription: transcription))

        if let existing = committedTranscription, let existingSpan = committedSpan {
            let existingText = existing.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedText = existingText.isEmpty ? newText : existingText + " " + newText
            committedTranscription = SpeechTranscription(
                text: mergedText,
                language: transcription.language ?? existing.language,
                metrics: transcription.metrics ?? existing.metrics
            )
            committedSpan = ChunkSpan(
                startSequence: min(existingSpan.startSequence, span.startSequence),
                endSequence: max(existingSpan.endSequence, span.endSequence)
            )
        } else {
            committedSpan = span
            committedTranscription = SpeechTranscription(
                text: newText,
                language: transcription.language,
                metrics: transcription.metrics
            )
        }
    }

    private mutating func maybePromoteCommit(span: ChunkSpan, transcription: SpeechTranscription) {
        // Commit só avança pra frente: novo span precisa cobrir mais do que o anterior.
        if let existing = committedSpan, existing.endSequence >= span.endSequence {
            return
        }
        committedSpan = span
        committedTranscription = transcription
    }

    func bestCurrentTranscription() -> SpeechTranscription? {
        entries.last?.transcription
    }

    func transcription(exactlyMatching span: ChunkSpan) -> SpeechTranscription? {
        entries.last(where: { $0.span == span })?.transcription
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: false)
        committedSpan = nil
        committedTranscription = nil
    }
}
