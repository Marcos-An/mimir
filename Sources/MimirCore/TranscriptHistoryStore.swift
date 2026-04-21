import Foundation
import Observation

public struct TranscriptEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date
    public let durationSeconds: Double?
    public let sessionMetrics: SessionMetrics?

    public init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        durationSeconds: Double? = nil,
        sessionMetrics: SessionMetrics? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.sessionMetrics = sessionMetrics
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, createdAt, durationSeconds, sessionMetrics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.text = try c.decode(String.self, forKey: .text)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        self.sessionMetrics = try c.decodeIfPresent(SessionMetrics.self, forKey: .sessionMetrics)
    }

    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

@MainActor
@Observable
public final class TranscriptHistoryStore {
    public private(set) var entries: [TranscriptEntry]

    private let defaults: UserDefaults
    private let key: String
    private let maxEntries: Int

    public init(defaults: UserDefaults = .standard, key: String = "com.mimir.history.v1", maxEntries: Int = 200) {
        self.defaults = defaults
        self.key = key
        self.maxEntries = maxEntries
        self.entries = Self.load(from: defaults, key: key)
    }

    public func add(
        _ text: String,
        durationSeconds: Double? = nil,
        sessionMetrics: SessionMetrics? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = TranscriptEntry(
            text: trimmed,
            durationSeconds: durationSeconds,
            sessionMetrics: sessionMetrics
        )
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist()
    }

    public func delete(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    public func clear() {
        entries = []
        persist()
    }

    public var totalWords: Int {
        entries.reduce(0) { $0 + $1.wordCount }
    }

    public var totalSeconds: Double {
        entries.compactMap(\.durationSeconds).reduce(0, +)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> [TranscriptEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TranscriptEntry].self, from: data)) ?? []
    }
}
