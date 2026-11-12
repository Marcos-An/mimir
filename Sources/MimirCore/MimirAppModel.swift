import Foundation
import Observation

public protocol DictationControlling: Sendable {
    var snapshot: DictationSnapshot { get async }
    func handleActivationPressed() async throws
    func handleActivationPressed(mode: DictationMode) async throws
    func handleActivationReleased() async throws
    func handleActivationCancelled() async throws
    func preload() async
    /// Downloads and loads every local model the session uses, including the
    /// ones `preload()` defers. Used by first-run setup.
    func prepareModels() async
    /// Stream de snapshots emitido a cada mudança de estado (push). O default
    /// termina imediatamente — consumidores caem no `snapshot` sob demanda.
    func snapshotUpdates() async -> AsyncStream<DictationSnapshot>
    /// Libera recursos da sessão (mic, tasks). Chamado antes do controller ser
    /// substituído em um rebuild.
    func teardown() async
    /// A UI já exibiu a falha: sai do estado de erro.
    func acknowledgeError() async
}

public extension DictationControlling {
    /// Default: modo ditado normal. Implementações podem sobrescrever.
    func handleActivationPressed(mode: DictationMode) async throws {
        try await handleActivationPressed()
    }

    func preload() async {}

    func prepareModels() async {
        await preload()
    }

    func snapshotUpdates() async -> AsyncStream<DictationSnapshot> {
        AsyncStream { $0.finish() }
    }

    func teardown() async {}

    func acknowledgeError() async {}
}

extension DictationSessionController: DictationControlling {}

/// Aviso efêmero mostrado na ilha depois de uma sessão que não colou texto.
/// Sem isso a ilha só desaparecia e o usuário não sabia o que aconteceu.
public enum SessionNotice: Equatable, Sendable {
    case error(message: String)
    case noSpeech
    /// Sem fala reconhecida E o áudio estava muito baixo — a causa provável é o
    /// microfone, não o modelo. Dizer isso evita o usuário culpar a transcrição.
    case audioTooQuiet

    public var displayText: String {
        switch self {
        case .error(let message):
            message
        case .noSpeech:
            "No speech detected"
        case .audioTooQuiet:
            "Audio too quiet — check your microphone"
        }
    }
}

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
    public private(set) var activeMode: DictationMode?
    public private(set) var metricsFlashID: UUID?
    public private(set) var isFlashingMetrics: Bool = false
    /// Aviso de erro / "sem fala" a exibir na ilha. Auto-dispensa.
    public private(set) var sessionNotice: SessionNotice?
    private var metricsFlashTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var lastCompletion: SessionCompletion?
    private static let noticeDisplaySeconds: UInt64 = 4_000_000_000

    private var session: any DictationControlling
    private let makeSession: SessionFactory?
    private var recordingStartedAt: Date?
    private var snapshotSubscriptionTask: Task<Void, Never>?

    public init(store: SettingsStore, history: TranscriptHistoryStore = TranscriptHistoryStore(), makeSession: @escaping SessionFactory) {
        self.store = store
        self.history = history
        self.makeSession = makeSession
        self.session = makeSession(store.settings)
        self.phase = .idle
        self.lastTranscript = nil
        self.lastTranscription = nil
        self.activeMode = nil
        subscribeToSession()
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
        subscribeToSession()
    }

    public func refresh() async {
        apply(await session.snapshot)
    }

    /// Consome o stream de snapshots da sessão (push). Substitui o polling de
    /// 80 ms — a UI só acorda quando o estado realmente muda.
    private func subscribeToSession() {
        snapshotSubscriptionTask?.cancel()
        let session = self.session
        snapshotSubscriptionTask = Task { @MainActor [weak self] in
            for await snapshot in await session.snapshotUpdates() {
                guard !Task.isCancelled else { break }
                self?.apply(snapshot)
            }
        }
    }

    /// Atribui apenas os campos que mudaram — cada set em @Observable invalida
    /// a UI, então writes incondicionais re-renderizam à toa.
    private func apply(_ snapshot: DictationSnapshot) {
        let previousPhase = phase
        let previousCompletion = lastCompletion

        if phase != snapshot.phase { phase = snapshot.phase }
        if lastTranscript != snapshot.lastTranscript { lastTranscript = snapshot.lastTranscript }
        if lastTranscription != snapshot.lastTranscription { lastTranscription = snapshot.lastTranscription }
        if lastSessionMetrics != snapshot.lastSessionMetrics { lastSessionMetrics = snapshot.lastSessionMetrics }
        if activeMode != snapshot.activeMode { activeMode = snapshot.activeMode }
        lastCompletion = snapshot.lastCompletion

        if snapshot.phase == .recording {
            // Nova gravação começou: o aviso da sessão anterior não interessa mais.
            dismissNotice()
        }
        if case .error(let message) = snapshot.phase, previousPhase != snapshot.phase {
            presentNotice(.error(message: message))
            // Sem o ack a fase ficaria travada em .error e o ícone do menu bar
            // laranja pra sempre.
            let session = self.session
            Task { await session.acknowledgeError() }
        }
        if let completion = snapshot.lastCompletion, completion != previousCompletion {
            switch completion {
            case .noSpeech:
                presentNotice(.noSpeech)
            case .audioTooQuiet:
                presentNotice(.audioTooQuiet)
            case .inserted:
                break
            }
        }
    }

    private func presentNotice(_ notice: SessionNotice) {
        noticeTask?.cancel()
        sessionNotice = notice
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.noticeDisplaySeconds)
            guard !Task.isCancelled else { return }
            self?.sessionNotice = nil
        }
    }

    private func dismissNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        if sessionNotice != nil { sessionNotice = nil }
    }

    public func preloadSession() async {
        await session.preload()
    }

    /// First-run setup: fetch every local model now instead of on first use.
    public func prepareAllModels() async {
        await session.prepareModels()
    }

    public func startDictation(mode: DictationMode = .dictation) async throws {
        do {
            try await session.handleActivationPressed(mode: mode)
            recordingStartedAt = Date()
            await refresh()
        } catch {
            await refresh()
            throw error
        }
    }

    public func stopDictation() async throws {
        let startedAt = recordingStartedAt
        let stoppedAt = Date()
        recordingStartedAt = nil
        do {
            try await session.handleActivationReleased()
            await refresh()
            if let transcript = lastTranscript, !transcript.isEmpty {
                let duration = startedAt.map { stoppedAt.timeIntervalSince($0) }
                // Preenche audioSeconds com a duração real da gravação
                // (o controller não tem essa informação).
                var metrics = lastSessionMetrics
                metrics?.audioSeconds = duration
                lastSessionMetrics = metrics
                history.add(
                    transcript,
                    rawText: lastTranscription?.text,
                    durationSeconds: duration,
                    sessionMetrics: metrics
                )
                metricsFlashID = UUID()
                beginMetricsFlash()
            }
        } catch {
            await refresh()
            throw error
        }
    }

    public func cancelDictation() async throws {
        do {
            try await session.handleActivationCancelled()
            await refresh()
        } catch {
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
        // A sessão antiga precisa soltar o microfone e cancelar tasks antes de
        // ser abandonada — sem isso um rebuild durante gravação deixa o engine
        // antigo capturando indefinidamente.
        let previous = session
        Task { await previous.teardown() }
        session = makeSession(store.settings)
        subscribeToSession()
    }
}
