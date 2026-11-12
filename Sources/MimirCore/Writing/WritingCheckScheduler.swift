import Foundation

/// Decides which sentences to send and when. Pure logic (no clock, no I/O):
/// the controller calls it on every text change and when the idle timer fires.
///
/// - A finished sentence (. ! ? or line break) is sent right away, once.
/// - The sentence still being typed is sent after `idleDelay` without typing,
///   only with 4+ words and only if it changed since its last idle check.
/// - Results are cached by sentence, so editing one sentence never re-sends
///   the others; the controller re-anchors cached findings to the new text.
public struct WritingCheckScheduler: Sendable {
    public static let idleDelay: TimeInterval = 0.8
    static let minimumIdleWords = 4
    static let maxSentencesPerRequest = 6
    static let cacheLimit = 400

    public enum Decision: Equatable, Sendable {
        case nothing
        case checkNow([String])
        case checkWhenIdle
    }

    private(set) var results: [String: [WritingFinding]] = [:]
    private var order: [String] = []
    private var inFlight: Set<String> = []
    private var lastIdleSent: String?
    /// Sentences Mimir pasted, without their final punctuation, so typing a
    /// period after a dictation doesn't send it.
    private var seeded: Set<String> = []

    public init() {}

    /// Findings for every sentence of `text` already checked, placed in `text`.
    public func findings(in text: String) -> [AnchoredFinding] {
        let sentences = WritingText.sentences(in: text)
        let cached = sentences.flatMap { results[$0.text] ?? [] }
        return WritingAnchoring.anchorAll(cached, in: text)
    }

    public mutating func textChanged(_ text: String) -> Decision {
        let sentences = WritingText.sentences(in: text)
        let pending = sentences
            .filter { $0.isComplete && results[$0.text] == nil && !inFlight.contains($0.text) && !isSeeded($0.text) }
            .map(\.text)
        if !pending.isEmpty {
            return .checkNow(Array(pending.suffix(Self.maxSentencesPerRequest)))
        }
        if let last = sentences.last, !last.isComplete, isIdleEligible(last.text) {
            return .checkWhenIdle
        }
        return .nothing
    }

    /// The idle timer fired: the unfinished sentence to send, if any.
    public mutating func idleFired(_ text: String) -> [String] {
        guard let last = WritingText.sentences(in: text).last, !last.isComplete,
              isIdleEligible(last.text) else { return [] }
        lastIdleSent = last.text
        return [last.text]
    }

    public mutating func markInFlight(_ sentences: [String]) {
        inFlight.formUnion(sentences)
    }

    /// A request answered: store what it found (an empty list counts as checked).
    public mutating func record(_ findings: [WritingFinding], for sentences: [String]) {
        inFlight.subtract(sentences)
        for sentence in sentences {
            store(findings.filter { $0.sentence == sentence }, for: sentence)
        }
    }

    /// A request failed: its sentences can be sent again later.
    public mutating func requestFailed(for sentences: [String]) {
        inFlight.subtract(sentences)
        if let lastIdleSent, sentences.contains(lastIdleSent) { self.lastIdleSent = nil }
    }

    /// Text Mimir pasted itself (a dictation) is never sent: mark every
    /// sentence of the field as checked with no findings.
    public mutating func seedAsChecked(_ text: String) {
        for sentence in WritingText.sentences(in: text) {
            seeded.insert(Self.withoutTerminator(sentence.text))
            if seeded.count > Self.cacheLimit { seeded.removeAll() }
            if results[sentence.text] == nil { store([], for: sentence.text) }
        }
        if let last = WritingText.sentences(in: text).last { lastIdleSent = last.text }
    }

    /// Drops a finding the user chose to ignore (kept as "checked").
    public mutating func ignore(_ finding: WritingFinding) {
        guard let current = results[finding.sentence] else { return }
        results[finding.sentence] = current.filter { $0 != finding }
    }

    private func isSeeded(_ sentence: String) -> Bool {
        seeded.contains(Self.withoutTerminator(sentence))
    }

    static func withoutTerminator(_ sentence: String) -> String {
        String(sentence.reversed().drop(while: { ".!?".contains($0) }).reversed())
    }

    private func isIdleEligible(_ sentence: String) -> Bool {
        results[sentence] == nil
            && !isSeeded(sentence)
            && !inFlight.contains(sentence)
            && sentence != lastIdleSent
            && WritingText.wordCount(sentence) >= Self.minimumIdleWords
    }

    private mutating func store(_ findings: [WritingFinding], for sentence: String) {
        if results[sentence] == nil { order.append(sentence) }
        results[sentence] = findings
        if order.count > Self.cacheLimit {
            let dropped = order.removeFirst()
            results[dropped] = nil
        }
    }
}

/// Keeps the writing check cheap when something goes wrong: no retry on
/// client errors, a pause on a bad key, growing backoff on rate limits and
/// server errors, and a daily cap.
public struct WritingRequestBudget: Codable, Equatable, Sendable {
    public static let defaultDailyCap = 1000

    public var dailyCap: Int
    public private(set) var day: String
    public private(set) var sentToday: Int
    public private(set) var blockedUntil: Date?
    public private(set) var keyRejected: Bool
    private var backoff: TimeInterval

    public init(dailyCap: Int = WritingRequestBudget.defaultDailyCap, now: Date = Date()) {
        self.dailyCap = dailyCap
        self.day = Self.dayKey(now)
        self.sentToday = 0
        self.blockedUntil = nil
        self.keyRejected = false
        self.backoff = 0
    }

    public enum Outcome: Sendable {
        case success
        case httpStatus(Int)
        case otherFailure
    }

    public func canSend(now: Date) -> Bool {
        if keyRejected { return false }
        if let blockedUntil, now < blockedUntil { return false }
        return sent(on: now) < dailyCap
    }

    /// Requests sent on `now`'s day.
    public func sent(on now: Date) -> Int {
        Self.dayKey(now) == day ? sentToday : 0
    }

    public mutating func recordSent(now: Date) {
        rollDay(now)
        sentToday += 1
    }

    public mutating func record(_ outcome: Outcome, now: Date) {
        switch outcome {
        case .success:
            backoff = 0
            blockedUntil = nil
        case .httpStatus(let status) where status == 401 || status == 403:
            keyRejected = true
        case .httpStatus, .otherFailure:
            // Rate limit, server error, bad request or no network: pause and
            // grow the pause, so a persistent failure can't loop on every keystroke.
            backoff = backoff == 0 ? 30 : min(backoff * 2, 600)
            blockedUntil = now.addingTimeInterval(backoff)
        }
    }

    /// The key changed in Settings: try again.
    public mutating func keyChanged() {
        keyRejected = false
        backoff = 0
        blockedUntil = nil
    }

    private mutating func rollDay(_ now: Date) {
        let today = Self.dayKey(now)
        if today != day {
            day = today
            sentToday = 0
        }
    }

    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
