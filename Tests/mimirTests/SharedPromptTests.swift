import CryptoKit
import Foundation
import Testing
@testable import MimirCore

/// The prompts live in shared/prompts (also read by desktop/, the Windows and
/// Linux app). These tests keep the Mac app honest about them.
@Suite struct SharedPromptTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func shared(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("shared/prompts/\(name)"), encoding: .utf8)
    }

    @Test("The generated Swift file matches shared/prompts (run scripts/gen_shared_prompts.py)")
    func generatedFileIsCurrent() throws {
        #expect(SharedPrompts.cleanupLight == (try Self.shared("cleanup-light.txt")))
        #expect(SharedPrompts.cleanupCleanDictation == (try Self.shared("cleanup-clean-dictation.txt")))
        #expect(SharedPrompts.cleanupStructured == (try Self.shared("cleanup-structured.txt")))
        #expect(SharedPrompts.cleanupPromptEngineer == (try Self.shared("cleanup-prompt-engineer.txt")))
        #expect(SharedPrompts.cleanupVocabularySection == (try Self.shared("cleanup-vocabulary-section.txt")))
        #expect(SharedPrompts.writingCheckSystem == (try Self.shared("writing-check-system.txt")))
        let data = Data(try Self.shared("writing-check-examples.json").utf8)
        let examples = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(examples.map { $0["role"] ?? "" } == SharedPrompts.writingCheckExamples.map(\.role))
        #expect(examples.map { $0["content"] ?? "" } == SharedPrompts.writingCheckExamples.map(\.content))
    }

    /// SHA-256 of every assembled system prompt, taken from the literals in
    /// the Swift code before the extraction (commit b59deb8). A change here
    /// means Claude now receives a different prompt: update the pin only on
    /// purpose.
    static let pins: [String: String] = [
        "light": "7c82faa71a849d254f86286fc0b833582c4f4d4ba0dab9a89df55901e2c6cadd",
        "light+vocab": "a9982f88d40eeebabcf9d68c6e29e6b6460c27dad4d04e29f01c8af8e7864de3",
        "clean": "942a19229deabd615193dcda5da2814fe93f0c2a867766216923c7e920f05b4c",
        "clean+vocab": "e00162c1e9c673c9fef1885660ba402c58f023a576d1f0bf7f55db7fcb535e52",
        "structured": "56e62e67e5d2f66c73a082d5d5a78c133d2a524082aa58c4ca1adcafc93c5881",
        "structured+vocab": "87b7a1651e761abc2659afcd2146c081ed19b505d30dde2bf99096c4c7c46734",
        "engineer": "4ac4adf98f5634006e381c9320ab2d47d35cbde72a56992b311ed80265be4bdb",
        "engineer+vocab": "d72c2bbb41d7c4d4192bc09af61c57ab4d5beae01dde4ea7236e222d44a36724",
        "writing-system": "d48b23b191f9f86546d7b067a269843299ceb2aae7991629633a438b6f44d921",
        "writing-examples": "05e7c95d5c3a02752462c05aa3f7f556399cf38e8a0dd23050faad8ad8410d72"
    ]

    @Test("Claude receives exactly the prompts it received before the extraction")
    func assembledPromptsArePinned() {
        let vocabulary = "Trecho\nMimir\nOffering Tree"
        let p = MLXPostProcessor.self
        var assembled: [String: String] = [:]
        for (name, style) in [("light", PostProcessingStyle.cleanup), ("clean", .cleanDictation), ("structured", .structured)] {
            assembled[name] = p.systemPrompt(for: .defaults, fallbackStyle: style, customVocabulary: "")
            assembled["\(name)+vocab"] = p.systemPrompt(for: .defaults, fallbackStyle: style, customVocabulary: vocabulary)
        }
        assembled["engineer"] = p.systemPrompt(for: .promptEngineer, fallbackStyle: .cleanup, customVocabulary: "")
        assembled["engineer+vocab"] = p.systemPrompt(for: .promptEngineer, fallbackStyle: .cleanup, customVocabulary: vocabulary)
        assembled["writing-system"] = WritingChecker.systemPrompt
        assembled["writing-examples"] = WritingChecker.examples.map { "\($0.role)\u{1}\($0.content)" }.joined(separator: "\u{2}")

        #expect(Set(assembled.keys) == Set(Self.pins.keys))
        for (label, text) in assembled {
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            #expect(hash == Self.pins[label], "\(label) changed")
        }
    }
}
