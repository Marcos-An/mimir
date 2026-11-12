import Foundation

/// Limpeza determinística de defeitos conhecidos da transcrição de ditado.
/// Roda em <1ms, 100% offline, e cobre a camada que o LLM de pós-processamento
/// vinha ignorando (medido no histórico real: reticências sobreviviam em
/// 111/200 ditados e fechos alucinados em 4/4).
///
/// Regras, nesta ordem:
/// 1. Reticências de pausa ("E... eu", "né?...") — artefato de hesitação, não
///    pontuação intencional de fala.
/// 2. Fecho alucinado no final ("Obrigado.", "Tchau.") — completude de treino
///    em vídeos; só remove quando é a última sentença, curta, e há texto antes.
/// 3. Normalização de espaços (duplos, espaço antes de pontuação).
/// 4. Capitalização depois de fim de sentença ("muito. tá demorando" → "Tá").
/// 5. Pontuação final quando o texto termina sem terminador.
public enum DictationTextCleaner {
    public static func clean(_ input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return input }

        text = collapseEllipses(text)
        text = removeHesitations(text)
        text = collapseRepeatedWords(text)
        text = stripTrailingFarewells(text)
        text = normalizeWhitespace(text)
        text = capitalizeSentenceStarts(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    /// Reticências ("..." com 2+ pontos, ou "…"):
    /// - seguidas de letra minúscula → viram um espaço (pausa no meio da frase);
    /// - seguidas de maiúscula → viram ". " (fim de sentença);
    /// - no fim do texto ou antes de outra pontuação → removidas/viram ".".
    static func collapseEllipses(_ input: String) -> String {
        var text = input
        // Normaliza o caractere único de reticências para a forma de 3 pontos.
        text = text.replacingOccurrences(of: "…", with: "...")
        // "?..." / "!..." / ",..." → mantém só a pontuação original.
        text = text.replacingOccurrences(
            of: #"([,;:!?])\s*\.{2,}"#,
            with: "$1",
            options: .regularExpression
        )
        // Reticências seguidas de minúscula (inclui acentuadas): pausa → espaço.
        text = text.replacingOccurrences(
            of: #"\s*\.{2,}\s*(?=\p{Ll})"#,
            with: " ",
            options: .regularExpression
        )
        // Reticências seguidas de maiúscula: fim de sentença.
        text = text.replacingOccurrences(
            of: #"\s*\.{2,}\s*(?=\p{Lu})"#,
            with: ". ",
            options: .regularExpression
        )
        // Reticências restantes (fim de texto/linha): um ponto só.
        text = text.replacingOccurrences(
            of: #"\s*\.{2,}"#,
            with: ".",
            options: .regularExpression
        )
        return text
    }

    /// Hesitation sounds ("ahn", "hum", "hmm", "uh", "éh") with their trailing
    /// comma. "ah" stays: it is usually a real interjection ("Ah, entendi").
    static func removeHesitations(_ input: String) -> String {
        input.replacingOccurrences(
            of: #"(?i)(?<![\p{L}\p{N}])(?:ahn+|hum+|hmm+|uh+|éh+|ehh+)(?![\p{L}\p{N}]),?\s*"#,
            with: "",
            options: .regularExpression
        )
    }

    /// A word said twice in a row with nothing between ("os os", "com com") is a
    /// stutter. A comma between keeps it ("não, não"), and words that are
    /// doubled on purpose in Portuguese ("o que que", "tchau tchau") are kept.
    static func collapseRepeatedWords(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}])(\p{L}{2,})(?:[ \t]+\1)+(?![\p{L}\p{N}])"#,
            options: [.caseInsensitive]
        ) else { return input }
        let nsInput = input as NSString
        var result = input as NSString
        for match in regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length)).reversed() {
            let word = nsInput.substring(with: match.range(at: 1))
            guard !intentionalRepeats.contains(word.lowercased()) else { continue }
            result = result.replacingCharacters(in: match.range, with: word) as NSString
        }
        return result as String
    }

    private static let intentionalRepeats: Set<String> = ["que", "tchau", "tic", "tac", "bye", "very"]

    /// Última sentença igual a uma despedida curta conhecida → removida, desde
    /// que exista fala real antes dela (se o ditado inteiro for "Obrigado!",
    /// o usuário disse isso de propósito e o texto fica intacto).
    /// Diferente do `stripTailFarewells` do Whisper (que só corta assinaturas
    /// inequívocas de YouTube), aqui cortamos também "obrigado"/"tchau" soltos:
    /// no ditado deste usuário eles são sempre alucinação de silêncio final.
    static func stripTrailingFarewells(_ input: String) -> String {
        var text = input
        // Até duas passadas: cobre "… Obrigado. Tchau."
        for _ in 0..<2 {
            let stripped = removeLastSentenceIfFarewell(text)
            if stripped == text { break }
            text = stripped
        }
        return text
    }

    private static func removeLastSentenceIfFarewell(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return input }

        // Poda terminadores/espaços finais para achar o corpo da última sentença.
        var end = trimmed.endIndex
        while end > trimmed.startIndex {
            let prev = trimmed.index(before: end)
            if trimmed[prev].isWhitespace || ".!?".contains(trimmed[prev]) {
                end = prev
            } else {
                break
            }
        }
        let body = String(trimmed[..<end])
        guard !body.isEmpty else { return input }

        let lastTerminator = body.lastIndex(where: { ".!?".contains($0) })
        let tailStart = lastTerminator.map { body.index(after: $0) } ?? body.startIndex
        let tail = String(body[tailStart...])
        let normalized = tail
            .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return input }
        let wordCount = normalized.split(whereSeparator: \.isWhitespace).count
        guard wordCount <= 3, farewells.contains(normalized) else { return input }

        let prefix = String(body[..<tailStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return input }
        return prefix
    }

    /// Whisper also invents "Tchau." / "Obrigado." at pauses in the middle of
    /// a dictation (seen in about half of a sample of real sessions, sometimes
    /// twice in one). A sentence made only of a farewell, with speech on both
    /// sides, is dropped. Runs before the AI cleanup, so the "Off" setting gets
    /// it too and the model has less to fix.
    public static func stripMidTextFarewells(_ input: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+|$)"#) else { return input }
        let nsInput = input as NSString
        let sentences = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
            .map { nsInput.substring(with: $0.range) }
        guard sentences.count >= 3 else { return input }
        var kept: [String] = []
        for (index, sentence) in sentences.enumerated() {
            let isInner = index > 0 && index < sentences.count - 1
            let normalized = sentence
                .replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if isInner, midTextFarewells.contains(normalized) { continue }
            kept.append(sentence)
        }
        guard kept.count != sentences.count else { return input }
        return normalizeWhitespace(kept.joined())
    }

    private static let midTextFarewells: Set<String> = [
        "tchau", "tchau tchau", "e tchau", "obrigado", "obrigada", "obrigado tchau",
        "thanks", "thank you", "bye"
    ]

    private static let farewells: Set<String> = [
        // pt
        "obrigado", "obrigada", "muito obrigado", "muito obrigada", "brigado",
        "tchau", "tchau tchau", "valeu", "até mais", "até logo", "até a próxima",
        "obrigado tchau", "obrigado até mais",
        // en
        "thanks", "thank you", "bye", "goodbye", "see you"
    ]

    static func normalizeWhitespace(_ input: String) -> String {
        var text = input
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        // Espaço antes de pontuação de fecho: "palavra ." → "palavra."
        text = text.replacingOccurrences(of: #" +([.,;:!?])"#, with: "$1", options: .regularExpression)
        // Pontos duplicados produzidos por junções: ".." → "." (reticências já trataram 2+).
        text = text.replacingOccurrences(of: #"\.{2,}"#, with: ".", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Capitaliza a primeira letra do texto e a primeira letra depois de
    /// ".", "!" ou "?" seguidos de espaço. Exigir o espaço evita mexer em
    /// domínios/versões ("site.com", "v1.2").
    static func capitalizeSentenceStarts(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var chars = Array(input)
        var atSentenceStart = true
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if atSentenceStart, char.isLetter {
                chars[index] = Character(char.uppercased())
                atSentenceStart = false
            } else if ".!?".contains(char) {
                // Só conta como fim de sentença se vier espaço/quebra depois.
                let next = index + 1
                if next >= chars.count || chars[next].isWhitespace || chars[next].isNewline {
                    atSentenceStart = true
                }
            } else if char.isNewline {
                atSentenceStart = true
            } else if !char.isWhitespace, atSentenceStart, !char.isLetter {
                // Número ou símbolo abrindo a sentença: não força nada.
                atSentenceStart = false
            }
            index += 1
        }
        return String(chars)
    }

    static func ensureTerminalPunctuation(_ input: String) -> String {
        guard let last = input.last else { return input }
        if last.isLetter || last.isNumber {
            return input + "."
        }
        return input
    }
}
