import Foundation

/// How the post-processor should treat the transcribed text. Selected per
/// dictation based on a spoken command prefix — `prompt`, `traduzir` etc.
/// `.defaults` falls back to the user's configured post-processing style.
public enum PolishIntent: Equatable, Sendable {
    case defaults
    /// Translate the input into the given BCP-47 language code (e.g. "en", "pt-BR").
    /// Spoken-command routing produces `.translateTo("en")`; the keyboard-driven
    /// translate flow passes whatever the user configured as default target.
    case translateTo(String)
    case promptEngineer
}

/// Detects a spoken command prefix on the **first word** of a transcription
/// and returns the routed intent with the prefix stripped out. Everything
/// else passes through unchanged.
public enum CommandPrefixRouter {
    public struct Routed: Equatable, Sendable {
        public let intent: PolishIntent
        public let text: String
    }

    private static let translateTriggers: Set<String> = ["traduzir", "translate"]
    private static let promptTriggers: Set<String> = ["prompt"]

    /// `true` quando a primeira palavra é um gatilho de comando, mesmo sem
    /// payload depois dela. Usado pelo polish incremental: o primeiro segmento
    /// revela o prefixo antes de o texto completo existir — se há gatilho, o
    /// intent final não será `defaults` e polir por segmento seria descartado.
    public static func hasTriggerPrefix(_ rawText: String) -> Bool {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.firstMatch(of: /^(\p{L}+)[\p{P}\s]*/) else { return false }
        let firstWord = String(match.output.1).lowercased()
        return translateTriggers.contains(firstWord) || promptTriggers.contains(firstWord)
    }

    public static func route(_ rawText: String) -> Routed {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Routed(intent: .defaults, text: rawText)
        }

        guard let match = trimmed.firstMatch(of: /^(\p{L}+)[\p{P}\s]*/) else {
            return Routed(intent: .defaults, text: rawText)
        }

        let firstWord = String(match.output.1).lowercased()
        let intent: PolishIntent
        if translateTriggers.contains(firstWord) {
            // Comando falado "traduzir/translate" historicamente significa
            // "para inglês" — mantém o contrato de antes; o fluxo de
            // tradução por teclado usa o idioma configurado pelo usuário.
            intent = .translateTo("en")
        } else if promptTriggers.contains(firstWord) {
            intent = .promptEngineer
        } else {
            return Routed(intent: .defaults, text: rawText)
        }

        let rest = String(trimmed[match.output.0.endIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // If nothing follows the trigger word, there's nothing to route —
        // return the original so we don't feed an empty payload downstream.
        guard !rest.isEmpty else {
            return Routed(intent: .defaults, text: rawText)
        }
        return Routed(intent: intent, text: rest)
    }
}
