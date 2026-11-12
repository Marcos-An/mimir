import Foundation

public enum WritingIssueKind: String, Codable, Sendable, CaseIterable {
    case spelling
    case grammar
    /// Right spelling, wrong word ("their" for "there").
    case word
    /// Correct but unnatural; a small rewrite helps a non-native writer.
    case phrasing

    public var title: String {
        switch self {
        case .spelling: "Spelling"
        case .grammar: "Grammar"
        case .word: "Wrong word"
        case .phrasing: "More natural"
        }
    }
}

/// One fix proposed by the model, tied to the sentence it was found in so it
/// can be re-located after the user keeps typing.
public struct WritingFinding: Equatable, Hashable, Sendable, Codable {
    public let sentence: String
    public let original: String
    public let replacement: String
    public let why: String
    public let kind: WritingIssueKind

    public init(sentence: String, original: String, replacement: String, why: String, kind: WritingIssueKind) {
        self.sentence = sentence
        self.original = original
        self.replacement = replacement
        self.why = why
        self.kind = kind
    }
}

/// A finding located in the current text (UTF-16 range, as Accessibility uses).
public struct AnchoredFinding: Equatable, Hashable, Sendable {
    public let finding: WritingFinding
    public let range: NSRange
}

public struct WritingSentence: Equatable, Sendable {
    public let text: String
    /// UTF-16 range in the field's text.
    public let range: NSRange
    /// Ends with . ! ? or a line break; the last sentence may still be typed.
    public let isComplete: Bool
}

public enum WritingText {
    /// Splits a field's text into trimmed sentences. A sentence ends at
    /// . ! ? followed by whitespace or the end of the text, or at a line break.
    public static func sentences(in text: String) -> [WritingSentence] {
        let ns = text as NSString
        var result: [WritingSentence] = []
        var start = 0
        var index = 0
        let length = ns.length
        func emit(end: Int, complete: Bool) {
            let raw = NSRange(location: start, length: max(0, end - start))
            let trimmed = trim(raw, in: ns)
            if trimmed.length > 0 {
                result.append(WritingSentence(text: ns.substring(with: trimmed), range: trimmed, isComplete: complete))
            }
        }
        while index < length {
            let char = ns.character(at: index)
            if char == 10 || char == 13 { // line break
                emit(end: index, complete: true)
                start = index + 1
            } else if char == 46 || char == 33 || char == 63 { // . ! ?
                var end = index + 1
                while end < length, [46, 33, 63].contains(ns.character(at: end)) { end += 1 }
                if end == length || isWhitespace(ns.character(at: end)) {
                    emit(end: end, complete: true)
                    start = end
                    index = end
                    continue
                }
            }
            index += 1
        }
        if start < length { emit(end: length, complete: false) }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 160
    }

    private static func trim(_ range: NSRange, in ns: NSString) -> NSRange {
        var lower = range.location
        var upper = NSMaxRange(range)
        while lower < upper, isWhitespace(ns.character(at: lower)) { lower += 1 }
        while upper > lower, isWhitespace(ns.character(at: upper - 1)) { upper -= 1 }
        return NSRange(location: lower, length: upper - lower)
    }
}

public enum WritingAnchoring {
    /// Where `finding` sits in `text` now, or nil when it can't be placed
    /// without guessing: its sentence is gone or appears twice, or the wrong
    /// words are not exactly once inside that sentence.
    public static func anchor(_ finding: WritingFinding, in text: String) -> NSRange? {
        let ns = text as NSString
        guard let sentenceRange = uniqueRange(of: finding.sentence, in: ns) else { return nil }
        let sentence = ns.substring(with: sentenceRange) as NSString
        guard let local = uniqueRange(of: finding.original, in: sentence) else { return nil }
        return NSRange(location: sentenceRange.location + local.location, length: local.length)
    }

    public static func anchorAll(_ findings: [WritingFinding], in text: String) -> [AnchoredFinding] {
        var seen = Set<NSRange>()
        return findings.compactMap { finding in
            guard let range = anchor(finding, in: text), !seen.contains(range) else { return nil }
            seen.insert(range)
            return AnchoredFinding(finding: finding, range: range)
        }
    }

    /// The text after applying `finding`, re-located against `text` (the
    /// field's value read right before writing). Nil when it no longer fits.
    public static func applying(_ finding: WritingFinding, to text: String) -> (text: String, range: NSRange)? {
        guard let range = anchor(finding, in: text) else { return nil }
        return ((text as NSString).replacingCharacters(in: range, with: finding.replacement), range)
    }

    static func uniqueRange(of needle: String, in haystack: NSString) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let first = haystack.range(of: needle, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let afterFirst = NSRange(location: first.location + 1, length: haystack.length - first.location - 1)
        guard afterFirst.length >= 0 else { return first }
        let second = haystack.range(of: needle, options: .literal, range: afterFirst)
        return second.location == NSNotFound ? first : nil
    }
}
