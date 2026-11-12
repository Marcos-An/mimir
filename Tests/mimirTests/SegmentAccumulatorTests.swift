import Foundation
import Testing
@testable import MimirCore

@Test("Appended segments join with a single space and trimmed whitespace")
func appendedSegmentsJoinWithSingleSpace() {
    var accumulator = SegmentAccumulator()
    accumulator.append(SpeechTranscription(text: "  Primeira parte ", language: "pt"))
    accumulator.append(SpeechTranscription(text: "segunda parte.", language: nil))

    #expect(accumulator.text == "Primeira parte segunda parte.")
    #expect(accumulator.segmentCount == 2)
    #expect(accumulator.language == "pt")
}

@Test("Empty or whitespace-only segments are ignored")
func emptySegmentsAreIgnored() {
    var accumulator = SegmentAccumulator()
    accumulator.append(SpeechTranscription(text: "   ", language: "pt"))

    #expect(accumulator.isEmpty)
    #expect(accumulator.segmentCount == 0)
    #expect(accumulator.text.isEmpty)
}

@Test("Latest non-nil language wins")
func latestNonNilLanguageWins() {
    var accumulator = SegmentAccumulator()
    accumulator.append(SpeechTranscription(text: "hello", language: "en"))
    accumulator.append(SpeechTranscription(text: "olá de novo", language: "pt"))
    accumulator.append(SpeechTranscription(text: "sem idioma", language: nil))

    #expect(accumulator.language == "pt")
}

@Test("Context tail is nil when empty and whole text when short")
func contextTailNilWhenEmptyWholeTextWhenShort() {
    var accumulator = SegmentAccumulator()
    #expect(accumulator.contextTail() == nil)

    accumulator.append(SpeechTranscription(text: "Texto curto de contexto.", language: "pt"))
    #expect(accumulator.contextTail() == "Texto curto de contexto.")
}

@Test("Context tail keeps only the last characters cut at a word boundary")
func contextTailCutsAtWordBoundary() {
    var accumulator = SegmentAccumulator()
    let words = (1...100).map { "palavra\($0)" }.joined(separator: " ")
    accumulator.append(SpeechTranscription(text: words, language: "pt"))

    let tail = try! #require(accumulator.contextTail(maxCharacters: 50))
    #expect(tail.count <= 50)
    // Nunca começa no meio de uma palavra: o primeiro token deve ser uma
    // "palavraN" completa.
    let firstToken = tail.split(separator: " ").first.map(String.init) ?? ""
    #expect(firstToken.hasPrefix("palavra"))
    #expect(words.hasSuffix(tail))
}

@Test("Reset clears all accumulated state")
func resetClearsState() {
    var accumulator = SegmentAccumulator()
    accumulator.append(SpeechTranscription(text: "algo", language: "pt"))
    accumulator.reset()

    #expect(accumulator.isEmpty)
    #expect(accumulator.segmentCount == 0)
    #expect(accumulator.text.isEmpty)
    #expect(accumulator.language == nil)
    #expect(accumulator.contextTail() == nil)
}
