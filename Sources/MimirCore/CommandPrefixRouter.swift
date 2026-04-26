import Foundation

/// How the post-processor should treat the transcribed text. Selected per
/// dictation based on a spoken command prefix — `prompt`, `traduzir` etc.
/// `.defaults` falls back to the user's configured post-processing style.
public enum PolishIntent: Equatable, Sendable {
    case defaults
    case translateToEnglish
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
            intent = .translateToEnglish
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
