import Foundation
import Testing
@testable import MimirCore

/// Runs shared/fixtures against the Mac implementation, which defines the
/// expected behaviour. desktop/core (Rust) runs the same files.
@Suite struct SharedFixtureTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func fixture(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/\(name)"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func cases(_ object: [String: Any], _ key: String) throws -> [[String: Any]] {
        try #require(object[key] as? [[String: Any]], "missing \(key)")
    }

    @Test func cleaner() throws {
        let file = try Self.fixture("cleaner.json")
        for item in try Self.cases(file, "clean") {
            let input = item["in"] as! String
            #expect(DictationTextCleaner.clean(input) == item["out"] as! String, "clean(\(input.debugDescription))")
        }
        for item in try Self.cases(file, "midTextFarewells") {
            let input = item["in"] as! String
            #expect(DictationTextCleaner.stripMidTextFarewells(input) == item["out"] as! String, "mid(\(input.debugDescription))")
        }
    }

    private static func finding(_ item: [String: Any]) -> WritingFinding {
        WritingFinding(
            sentence: item["sentence"] as? String ?? "",
            original: item["original"] as? String ?? "",
            replacement: item["replacement"] as? String ?? "",
            why: item["why"] as? String ?? "x",
            kind: WritingIssueKind(rawValue: item["kind"] as? String ?? "grammar") ?? .grammar
        )
    }

    @Test func writing() throws {
        let file = try Self.fixture("writing.json")
        for item in try Self.cases(file, "sentences") {
            let text = item["text"] as! String
            let expected = (item["sentences"] as! [[Any]]).map { row in
                "\(row[0] as! String)|\(row[1] as! Int)|\(row[2] as! Int)|\(row[3] as! Bool)"
            }
            let actual = WritingText.sentences(in: text).map { "\($0.text)|\($0.range.location)|\($0.range.length)|\($0.isComplete)" }
            #expect(actual == expected, "sentences(\(text.debugDescription))")
        }
        for item in try Self.cases(file, "acceptable") {
            #expect(WritingChecker.isAcceptable(Self.finding(item)) == item["ok"] as! Bool, "acceptable \(item)")
        }
        for item in try Self.cases(file, "parse") {
            let parsed = WritingChecker.parse(item["reply"] as! String, checked: item["checked"] as! [String])
            #expect(parsed == (item["findings"] as! [[String: Any]]).map(Self.finding), "parse \(item["reply"]!)")
        }
        for item in try Self.cases(file, "anchor") {
            let range = WritingAnchoring.anchor(Self.finding(item), in: item["text"] as! String)
            let expected = (item["range"] as? [Int]).map { NSRange(location: $0[0], length: $0[1]) }
            #expect(range == expected, "anchor \(item["text"]!)")
        }
        for item in try Self.cases(file, "apply") {
            #expect(WritingAnchoring.applying(Self.finding(item), to: item["text"] as! String)?.text == item["result"] as? String)
        }
        for item in try Self.cases(file, "touchesVocabulary") {
            let touches = WritingChecker.touchesVocabulary(Self.finding(item), item["vocabulary"] as! [String])
            #expect(touches == item["touches"] as! Bool, "vocabulary \(item)")
        }
    }

    @Test func anthropic() throws {
        for item in try Self.cases(try Self.fixture("anthropic.json"), "outOfCredits") {
            let body = Data((item["body"] as! String).utf8)
            #expect(AnthropicClient.isOutOfCredits(status: item["status"] as! Int, body: body) == item["out"] as! Bool, "\(item)")
        }
    }
}
