import Foundation
import Testing
@testable import MimirCore

private func finding(_ sentence: String, _ original: String, _ replacement: String, _ kind: WritingIssueKind = .grammar) -> WritingFinding {
    WritingFinding(sentence: sentence, original: original, replacement: replacement, why: "x", kind: kind)
}

@Test("Sentences split on terminators and line breaks; the last one may be unfinished")
func writingSentenceSplit() {
    let sentences = WritingText.sentences(in: "Hi there. Version 1.2 is out!\nNext line and more")
    #expect(sentences.map(\.text) == ["Hi there.", "Version 1.2 is out!", "Next line and more"])
    #expect(sentences.map(\.isComplete) == [true, true, false])
}

@Test("Model fixes are kept only when exact, unique and small")
func writingValidation() {
    let sentence = "I has went there yesterday."
    #expect(WritingChecker.isAcceptable(finding(sentence, "has went", "went")))
    // Not in the sentence.
    #expect(!WritingChecker.isAcceptable(finding(sentence, "have gone", "went")))
    // Not unique inside its sentence.
    #expect(!WritingChecker.isAcceptable(finding("its fine, its done", "its", "it's", .word)))
    // A rewrite of more than four words, whatever the kind.
    #expect(!WritingChecker.isAcceptable(finding(sentence, "I has went there yesterday.", "Yesterday I finally made my way over to that place.", .phrasing)))
    // A spelling "fix" that is a different word altogether.
    #expect(!WritingChecker.isAcceptable(finding("I recieved it.", "recieved", "telescope", .spelling)))
    #expect(WritingChecker.isAcceptable(finding("I recieved it.", "recieved", "received", .spelling)))
    // No-op.
    #expect(!WritingChecker.isAcceptable(finding(sentence, "went", "went")))
}

@Test("Model replies are parsed defensively")
func writingParse() {
    let sentence = "I has went there yesterday."
    let reply = #"Sure: [{"sentence":"I has went there yesterday.","original":"has went","replacement":"went","why":"Simple past.","kind":"grammar"},{"sentence":"Other text.","original":"x","replacement":"y","why":"","kind":"grammar"},{"sentence":"I has went there yesterday.","original":"there","replacement":"their","why":"","kind":"bogus"}]"#
    let parsed = WritingChecker.parse(reply, checked: [sentence])
    #expect(parsed == [WritingFinding(sentence: sentence, original: "has went", replacement: "went", why: "Simple past.", kind: .grammar)])
    #expect(WritingChecker.parse("not json", checked: [sentence]).isEmpty)
}

@Test("Findings follow their sentence while the user keeps typing")
func writingAnchoring() {
    let fix = finding("I has went there yesterday.", "has went", "went")
    let original = "Hello. I has went there yesterday."
    let moved = "Hello, team! I has went there yesterday. More text"
    let anchored = WritingAnchoring.anchor(fix, in: moved)
    #expect(anchored.map { (moved as NSString).substring(with: $0) } == "has went")
    #expect(WritingAnchoring.anchor(fix, in: original) != nil)
    // The sentence itself changed: the finding is gone.
    #expect(WritingAnchoring.anchor(fix, in: "Hello. I has gone there yesterday.") == nil)
    // The same sentence twice: ambiguous, never applied.
    #expect(WritingAnchoring.anchor(fix, in: "I has went there yesterday. I has went there yesterday.") == nil)
    // Applying rewrites only that span.
    let applied = WritingAnchoring.applying(fix, to: moved)
    #expect(applied?.text == "Hello, team! I went there yesterday. More text")
}

@Test("Finished sentences are checked at once and never re-sent")
func writingSchedulerTerminator() {
    var scheduler = WritingCheckScheduler()
    #expect(scheduler.textChanged("I has went") == .nothing)
    #expect(scheduler.textChanged("I has went there yesterday.") == .checkNow(["I has went there yesterday."]))
    scheduler.markInFlight(["I has went there yesterday."])
    // In flight: typing more doesn't send it twice.
    #expect(scheduler.textChanged("I has went there yesterday. And") == .nothing)
    scheduler.record([finding("I has went there yesterday.", "has went", "went")], for: ["I has went there yesterday."])
    #expect(scheduler.textChanged("I has went there yesterday. And then") == .nothing)
    #expect(scheduler.findings(in: "Hi. I has went there yesterday. And then").count == 1)
}

@Test("The sentence being typed is checked after a pause, once per version")
func writingSchedulerIdle() {
    var scheduler = WritingCheckScheduler()
    #expect(scheduler.textChanged("we was going") == .nothing) // < 4 words
    #expect(scheduler.textChanged("we was going there") == .checkWhenIdle)
    #expect(scheduler.idleFired("we was going there") == ["we was going there"])
    // Same text again: not re-sent.
    #expect(scheduler.textChanged("we was going there") == .nothing)
    #expect(scheduler.idleFired("we was going there").isEmpty)
    // Edited: eligible again.
    #expect(scheduler.textChanged("we was going there now") == .checkWhenIdle)
}

@Test("A stale answer never shows a fix for text that changed")
func writingStaleAnswer() {
    var scheduler = WritingCheckScheduler()
    let sentence = "I has went there yesterday."
    _ = scheduler.textChanged(sentence)
    scheduler.markInFlight([sentence])
    // The user rewrote the sentence before the answer arrived.
    scheduler.record([finding(sentence, "has went", "went")], for: [sentence])
    #expect(scheduler.findings(in: "I went there yesterday.").isEmpty)
}

@Test("Text Mimir pasted is never sent")
func writingSeededPaste() {
    var scheduler = WritingCheckScheduler()
    scheduler.seedAsChecked("Dictated text one. Dictated text two")
    #expect(scheduler.textChanged("Dictated text one. Dictated text two") == .nothing)
    #expect(scheduler.textChanged("Dictated text one. Dictated text two. New typed words here.") == .checkNow(["New typed words here."]))
}

@Test("Budget: a bad key stops, rate limits back off, the daily cap blocks")
func writingBudget() {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var budget = WritingRequestBudget(dailyCap: 2, now: start)
    #expect(budget.canSend(now: start))
    budget.recordSent(now: start)
    budget.record(.httpStatus(429), now: start)
    #expect(!budget.canSend(now: start.addingTimeInterval(10)))
    #expect(budget.canSend(now: start.addingTimeInterval(31)))
    budget.recordSent(now: start.addingTimeInterval(31))
    #expect(!budget.canSend(now: start.addingTimeInterval(32))) // cap of 2
    #expect(budget.canSend(now: start.addingTimeInterval(86_400 * 2))) // next day

    var keyed = WritingRequestBudget(now: start)
    keyed.record(.httpStatus(401), now: start)
    #expect(!keyed.canSend(now: start.addingTimeInterval(3600)))
    keyed.keyChanged()
    #expect(keyed.canSend(now: start))
}

@Test("Writing check settings default to off with Slack and Notes allowed")
func writingSettingsDecodeOldJSON() throws {
    let old = try JSONEncoder().encode(AppSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
    object.removeValue(forKey: "writingCheckEnabled")
    object.removeValue(forKey: "writingAllowedBundleIDs")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.writingCheckEnabled == false)
    #expect(decoded.writingAllowedBundleIDs == ["com.tinyspeck.slackmacgap", "com.apple.Notes"])
}

extension AnthropicRequestTests {
    @Test("The writing request is sent once, without retries")
    func writingRequestShape() async throws {
    let reply = #"{"content":[{"type":"text","text":"[]"}],"stop_reason":"end_turn"}"#
    let session = StubURLProtocol.session(replies: [.failure(.timedOut), .http(200, reply)])
    let checker = WritingChecker(client: AnthropicClient(session: session))
    await #expect(throws: AnthropicClient.Failure.transport(.timedOut)) {
        try await checker.check(sentences: ["I has went there."], context: "", apiKey: "k")
    }
    #expect(StubURLProtocol.requests.count == 1)
}
}

@Test("The API key moves from the Keychain to a private file once")
func apiKeyMigratesToPrivateFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let file = dir.appendingPathComponent("Mimir/anthropic-api-key")
    defer { try? FileManager.default.removeItem(at: dir) }

    var keychainDeletes = 0
    let key = AnthropicAPIKey.resolve(
        fileURL: file,
        legacyKeychainRead: { "sk-legacy" },
        legacyKeychainDelete: { keychainDeletes += 1 },
        environment: [:]
    )
    #expect(key == "sk-legacy")
    #expect(keychainDeletes == 1)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)

    // Next launch: read from the file, Keychain never touched.
    let again = AnthropicAPIKey.resolve(
        fileURL: file,
        legacyKeychainRead: { Issue.record("Keychain read after migration"); return nil },
        legacyKeychainDelete: {},
        environment: [:]
    )
    #expect(again == "sk-legacy")
    #expect(AnthropicAPIKey.hasStoredKey(fileURL: file))

    AnthropicAPIKey.delete(fileURL: file, legacyKeychainDelete: {})
    #expect(!AnthropicAPIKey.hasStoredKey(fileURL: file))
    #expect(AnthropicAPIKey.resolve(fileURL: file, legacyKeychainRead: { nil }, legacyKeychainDelete: {}, environment: ["ANTHROPIC_API_KEY": " sk-env "]) == "sk-env")
}

@Test("Fixes that change the user's own vocabulary are dropped")
func writingRespectsVocabulary() {
    let vocabulary = WritingChecker.vocabularyTerms(from: "Trecho\n  Mimir \n\nOffering Tree")
    #expect(vocabulary == ["Trecho", "Mimir", "Offering Tree"])
    let renamed = finding("I use trecho daily.", "trecho", "excerpt", .word)
    #expect(WritingChecker.touchesVocabulary(renamed, vocabulary))
    // Capitalising the term itself is fine.
    let capitalised = finding("I use offering tree daily.", "offering tree", "Offering Tree", .spelling)
    #expect(!WritingChecker.touchesVocabulary(capitalised, vocabulary))
}

@Test func keyStoreReloadPicksUpANewKeyWithoutRestart() {
    final class Box: @unchecked Sendable { var key: String? = "old" }
    let box = Box()
    let store = AnthropicKeyStore(read: { box.key })
    #expect(store.load() == "old")
    box.key = "new"
    #expect(store.load() == "old")
    store.reload()
    #expect(store.cachedKey == "new")
    box.key = nil
    store.reload()
    #expect(store.cachedKey == nil)
}

@Test func appPolicyChecksEveryAppExceptSkippedOnesByDefault() throws {
    let legacy = try JSONEncoder().encode(AppSettings.default)
    var object = try #require(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    object.removeValue(forKey: "writingAppScope")
    object.removeValue(forKey: "writingSkippedBundleIDs")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.writingAppScope == .allApps)

    let all = WritingAppPolicy(scope: .allApps, listed: [], skipped: ["com.example.private"])
    #expect(all.allows("com.anthropic.claudefordesktop"))
    #expect(all.allows("com.google.Chrome"))
    #expect(!all.allows("com.apple.Terminal"))
    #expect(!all.allows("com.1password.1password"))
    #expect(!all.allows("com.example.private"))

    let listed = WritingAppPolicy(scope: .listedApps, listed: ["com.apple.Notes"], skipped: [])
    #expect(listed.allows("com.apple.Notes"))
    #expect(!listed.allows("com.google.Chrome"))
}
