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
