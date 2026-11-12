import Foundation

/// Asks Claude for the mistakes in a few sentences and keeps only fixes that
/// can be placed exactly and stay small. Rules adapted from Trecho's checker.
public actor WritingChecker {
    public static let defaultModelID = "claude-haiku-5-5"

    private let client: AnthropicClient
    private let modelID: String

    public init(client: AnthropicClient, modelID: String = WritingChecker.defaultModelID) {
        self.client = client
        self.modelID = modelID
    }

    /// `sentences` are checked; `context` (text just before them) only helps
    /// the model understand references and is never edited.
    public func check(sentences: [String], context: String, vocabulary: [String] = [], apiKey: String) async throws -> [WritingFinding] {
        guard !sentences.isEmpty else { return [] }
        let reply = try await client.complete(
            apiKey: apiKey,
            model: modelID,
            system: Self.systemPrompt,
            messages: Self.examples + [.init(role: "user", content: Self.userMessage(sentences: sentences, context: context, vocabulary: vocabulary))],
            maxTokens: 600,
            retries: 0
        )
        return Self.parse(reply, checked: sentences).filter { !Self.touchesVocabulary($0, vocabulary) }
    }

    /// The user's custom vocabulary (Settings → Pipeline), one term per line.
    public static func vocabularyTerms(from text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(150)
            .map { String($0) }
    }

    /// A fix that changes one of the user's own terms ("Trecho", "Mimir") is
    /// never shown, whatever the model said.
    static func touchesVocabulary(_ finding: WritingFinding, _ vocabulary: [String]) -> Bool {
        let original = finding.original.lowercased()
        return vocabulary.contains { term in
            let lowered = term.lowercased()
            return original.contains(lowered) && !finding.replacement.lowercased().contains(lowered)
        }
    }

    /// shared/prompts/writing-check-system.txt (same text on every platform).
    static let systemPrompt = SharedPrompts.writingCheckSystem

    /// shared/prompts/writing-check-examples.json
    static let examples: [AnthropicClient.Message] = SharedPrompts.writingCheckExamples.map {
        AnthropicClient.Message(role: $0.role, content: $0.content)
    }

    static func userMessage(sentences: [String], context: String, vocabulary: [String] = []) -> String {
        let terms = vocabulary.isEmpty ? "" : "<terms>\(vocabulary.joined(separator: ", "))</terms>\n"
        return "\(terms)<context>\(context)</context>\n<check>\n\(sentences.joined(separator: "\n"))\n</check>"
    }

    private struct RawFinding: Decodable {
        let sentence: String?
        let original: String?
        let replacement: String?
        let why: String?
        let kind: String?
    }

    /// Parses the model's JSON and drops anything that can't be trusted.
    /// Invalid JSON yields no findings (never a retry).
    public static func parse(_ reply: String, checked: [String]) -> [WritingFinding] {
        guard let start = reply.firstIndex(of: "["), let end = reply.lastIndex(of: "]"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let raw = try? JSONDecoder().decode([RawFinding].self, from: data)
        else { return [] }
        let allowed = Set(checked)
        return raw.prefix(5).compactMap { item in
            guard let sentence = item.sentence, allowed.contains(sentence),
                  let original = item.original, let replacement = item.replacement,
                  let kind = item.kind.flatMap(WritingIssueKind.init(rawValue:))
            else { return nil }
            let finding = WritingFinding(
                sentence: sentence,
                original: original,
                replacement: replacement,
                why: (item.why ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                kind: kind
            )
            return isAcceptable(finding) ? finding : nil
        }
    }

    /// Keeps a fix only when it is placeable and small:
    /// - `original` occurs exactly once in its sentence;
    /// - the replacement differs and is at most 20 characters longer;
    /// - at most 4 words change (any kind);
    /// - a spelling fix stays close to the typed word (no bizarre words).
    public static func isAcceptable(_ finding: WritingFinding) -> Bool {
        let original = finding.original
        let replacement = finding.replacement
        guard !original.trimmingCharacters(in: .whitespaces).isEmpty, original != replacement,
              WritingAnchoring.uniqueRange(of: original, in: finding.sentence as NSString) != nil,
              replacement.count <= original.count + 20
        else { return false }
        let originalWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let replacementWords = replacement.split(whereSeparator: \.isWhitespace).map(String.init)
        guard editDistance(originalWords, replacementWords) <= 4 else { return false }
        if finding.kind == .spelling {
            let limit = max(3, Int((Double(original.count) * 0.6).rounded(.down)))
            guard editDistance(Array(original.lowercased()), Array(replacement.lowercased())) <= limit else { return false }
        }
        return true
    }

    static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
