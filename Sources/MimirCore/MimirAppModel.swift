import Foundation
import Observation

public protocol DictationControlling: Sendable {
    var snapshot: DictationSnapshot { get async }
    func handleActivationPressed() async throws
    func handleActivationPressed(mode: DictationMode) async throws
    func handleActivationReleased() async throws
    func handleActivationCancelled() async throws
}

public extension DictationControlling {
    /// Default: modo ditado normal. Implementações podem sobrescrever.
    func handleActivationPressed(mode: DictationMode) async throws {
        try await handleActivationPressed()
    }
}

extension DictationSessionController: DictationControlling {}

@MainActor
@Observable
public final class MimirAppModel {
    public typealias SessionFactory = @MainActor (AppSettings) -> any DictationControlling

    public let store: SettingsStore
    public let history: TranscriptHistoryStore
    public private(set) var phase: AppPhase
    public private(set) var lastTranscript: String?
    public private(set) var lastTranscription: SpeechTranscription?
    public private(set) var lastSessionMetrics: SessionMetrics?
    public private(set) var partialPolishText: String?
    public private(set) var activeMode: DictationMode?
    public private(set) var metricsFlashID: UUID?
    public private(set) var isFlashingMetrics: Bool = false
    private var metricsFlashTask: Task<Void, Never>?

    private var session: any DictationControlling
    private let makeSession: SessionFactory?
    private var recordingStartedAt: Date?
    private var statePollingTask: Task<Void, Never>?

    public init(store: SettingsStore, history: TranscriptHistoryStore = TranscriptHistoryStore(), makeSession: @escaping SessionFactory) {
        self.store = store
        self.history = history
        self.makeSession = makeSession
        self.session = makeSession(store.settings)
        self.phase = .idle
        self.lastTranscript = nil
        self.lastTranscription = nil
        self.activeMode = nil
    }

    public init(session: any DictationControlling) {
        self.store = SettingsStore(defaults: UserDefaults(suiteName: "mimir.inmemory.\(UUID().uuidString)") ?? .standard)
        self.history = TranscriptHistoryStore(defaults: UserDefaults(suiteName: "mimir.history.inmemory.\(UUID().uuidString)") ?? .standard)
        self.makeSession = nil
        self.session = session
        self.phase = .idle
        self.lastTranscript = nil
        self.lastTranscription = nil
        self.activeMode = nil
    }

    public func refresh() async {
        let snapshot = await session.snapshot
        phase = snapshot.phase
        lastTranscript = snapshot.lastTranscript
        lastTranscription = snapshot.lastTranscription
        lastSessionMetrics = snapshot.lastSessionMetrics
        partialPolishText = snapshot.partialPolishText
        activeMode = snapshot.activeMode
    }

    public func startDictation(mode: DictationMode = .dictation) async throws {
        do {
            try await session.handleActivationPressed(mode: mode)
            recordingStartedAt = Date()
            startStatePollingIfNeeded()
            await refresh()
        } catch {
            stopStatePolling()
            await refresh()
            throw error
        }
    }

    public func stopDictation() async throws {
        startStatePollingIfNeeded()
        let startedAt = recordingStartedAt
        recordingStartedAt = nil
        do {
            try await session.handleActivationReleased()
            await refresh()
            stopStatePolling()
            if let transcript = lastTranscript, !transcript.isEmpty {
                let duration = startedAt.map { Date().timeIntervalSince($0) }
                // Preenche audioSeconds com a duração real da gravação
                // (o controller não tem essa informação).
                var metrics = lastSessionMetrics
                metrics?.audioSeconds = duration
                lastSessionMetrics = metrics
                history.add(
                    transcript,
                    durationSeconds: duration,
                    sessionMetrics: metrics
                )
                metricsFlashID = UUID()
                beginMetricsFlash()
            }
        } catch {
            stopStatePolling()
            await refresh()
            throw error
        }
    }

    private func startStatePollingIfNeeded() {
        guard statePollingTask == nil else { return }
        statePollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    private func stopStatePolling() {
        statePollingTask?.cancel()
        statePollingTask = nil
    }

    public func cancelDictation() async throws {
        do {
            try await session.handleActivationCancelled()
            stopStatePolling()
            await refresh()
        } catch {
            stopStatePolling()
            await refresh()
            throw error
        }
    }

    private func beginMetricsFlash() {
        metricsFlashTask?.cancel()
        isFlashingMetrics = true
        metricsFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.isFlashingMetrics = false
        }
    }

    public func rebuildSession() {
        guard let makeSession else { return }
        session = makeSession(store.settings)
    }
}
