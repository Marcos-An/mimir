import AppKit
import Testing
@testable import MimirApp

@MainActor
@Test("Short transcripts do not offer an expansion that changes nothing")
func shortTranscriptFits() {
    #expect(!TranscriptTextLayout.isTruncated("Review this diff and add regression tests.", width: 600))
    #expect(!TranscriptTextLayout.isTruncated("", width: 600))
}

@MainActor
@Test("Long transcripts offer expansion and respond to the available width")
func wrappedTranscriptExpands() {
    let text = String(repeating: "Preserve existing behavior and cover failure paths. ", count: 5)
    #expect(TranscriptTextLayout.isTruncated(text, width: 200))
    #expect(!TranscriptTextLayout.isTruncated(text, width: 1000))
}

@MainActor
@Test("The four-line limit includes explicit line breaks and Unicode")
func explicitLinesAndUnicode() {
    #expect(!TranscriptTextLayout.isTruncated("one\ntwo\nthree\nfour", width: 600))
    #expect(TranscriptTextLayout.isTruncated("one\ntwo\nthree\nfour\nfive", width: 600))
    #expect(TranscriptTextLayout.isTruncated(String(repeating: "Revisão 日本語 👩🏽‍💻\n", count: 6), width: 600))
}

@MainActor
@Test("Unmeasured widths do not show a speculative expansion control")
func invalidWidthDoesNotTruncate() {
    #expect(!TranscriptTextLayout.isTruncated("Example", width: 0))
    #expect(!TranscriptTextLayout.isTruncated("Example", width: .infinity))
}

@Test("Rendered text pieces map a range across paragraph breaks")
@MainActor
func renderedFragmentsMapAcrossLineBreaks() {
    let source = "Hello there\nI has went home"
    let range = (source as NSString).range(of: "has went")
    let parts = FocusedTextReader.fragmentParts(source: source, range: range, fragments: ["Hello there", "I has went home"])
    #expect(parts.count == 1)
    #expect(parts.first?.index == 1)
    #expect(parts.first?.range == NSRange(location: 2, length: 8))
    // Pieces that don't describe the text: no mapping.
    #expect(FocusedTextReader.fragmentParts(source: source, range: range, fragments: ["Other", "text"]).isEmpty)
}

@MainActor
@Test func typedFixesAreSplitIntoShortChunks() {
    let text = "had already gone there 👍🏽 ok"
    let chunks = FocusedTextReader.typingChunks(text)
    #expect(chunks.allSatisfy { $0.count <= FocusedTextReader.maxTypedChunk })
    #expect(chunks.count > 1)
    #expect(String(decoding: chunks.flatMap { $0 }, as: UTF16.self) == text)
    // No chunk ends in the middle of a character.
    #expect(chunks.allSatisfy { String(utf16CodeUnits: $0, count: $0.count).utf16.count == $0.count && !(UTF16.isLeadSurrogate($0.last ?? 0)) })
    #expect(FocusedTextReader.typingChunks("").isEmpty)
}
