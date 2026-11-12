import Foundation
import Observation

/// The local models Mimir downloads on first use.
public enum LocalModelKind: String, CaseIterable, Sendable {
    /// Whisper, for speech to text.
    case speech
    /// The MLX language model that polishes the transcript.
    case polish
}

/// Download and load state of each local model, observed by the UI (setup
/// window, menu bar, recording island). Speech and polish can load at the same
/// time, so each one is tracked separately.
///
/// Every report carries an `owner` (the model id). A load that a settings
/// change made obsolete keeps running in the background; its reports are
/// ignored once another model of the same kind has begun.
@MainActor
@Observable
public final class ModelDownloadMonitor {
    public enum Status: Equatable, Sendable {
        /// Not requested yet in this launch.
        case idle
        /// Checking the cache, or loading and compiling the model for this Mac.
        case preparing
        /// Fetching files. `fraction` is nil while the size is still unknown.
        case downloading(fraction: Double?)
        /// On disk and loaded.
        case ready
        case failed
    }

    public private(set) var statuses: [LocalModelKind: Status] = [:]
    private var owners: [LocalModelKind: String] = [:]
    /// Kinds still fetching files (progress reports are only honoured here).
    private var downloadPhase: Set<LocalModelKind> = []
    /// Kinds whose fetch took long enough to be shown as a download.
    private var downloadShown: Set<LocalModelKind> = []

    public init() {}

    public func status(of kind: LocalModelKind) -> Status {
        statuses[kind] ?? .idle
    }

    /// A real download is in flight. Loading from disk does not count, so the
    /// recording island stays available while a cached model warms up.
    public var isActive: Bool {
        statuses.values.contains { if case .downloading = $0 { true } else { false } }
    }

    /// Combined progress of every download in flight; 0 when none reports a size.
    public var fractionCompleted: Double {
        let fractions = statuses.values.compactMap { status -> Double? in
            if case .downloading(let fraction) = status { return fraction }
            return nil
        }
        guard !fractions.isEmpty else { return 0 }
        return fractions.reduce(0, +) / Double(fractions.count)
    }

    public var isIndeterminate: Bool {
        isActive && !statuses.values.contains {
            if case .downloading(let fraction) = $0 { fraction != nil } else { false }
        }
    }

    /// A load of `owner` starts: it may download, then prepares the model.
    public func begin(_ kind: LocalModelKind, owner: String) {
        owners[kind] = owner
        downloadPhase.insert(kind)
        downloadShown.remove(kind)
        statuses[kind] = .preparing
    }

    /// The fetch is still running after a grace period: show it as a download.
    /// A cached model finishes its fetch before this and never shows one.
    public func showDownload(_ kind: LocalModelKind, owner: String) {
        guard owners[kind] == owner, downloadPhase.contains(kind) else { return }
        downloadShown.insert(kind)
        if case .preparing = status(of: kind) {
            statuses[kind] = .downloading(fraction: nil)
        }
    }

    public func update(_ kind: LocalModelKind, owner: String, fraction: Double) {
        guard owners[kind] == owner, downloadPhase.contains(kind) else { return }
        if fraction >= 1 {
            downloadFinished(kind, owner: owner)
            return
        }
        guard downloadShown.contains(kind) else { return }
        statuses[kind] = .downloading(fraction: max(0, fraction))
    }

    /// Files are on disk; what remains is loading and compiling the model.
    public func downloadFinished(_ kind: LocalModelKind, owner: String) {
        guard owners[kind] == owner else { return }
        downloadPhase.remove(kind)
        statuses[kind] = .preparing
    }

    public func finish(_ kind: LocalModelKind, owner: String, succeeded: Bool) {
        guard owners[kind] == owner else { return }
        downloadPhase.remove(kind)
        statuses[kind] = succeeded ? .ready : .failed
    }
}

/// Forwards a `Progress` (from Hugging Face downloads) into the monitor.
final class ModelProgressObserver: @unchecked Sendable {
    private weak var monitor: ModelDownloadMonitor?
    private let kind: LocalModelKind
    private let owner: String
    private var observation: NSKeyValueObservation?
    private let lock = NSLock()

    init(monitor: ModelDownloadMonitor?, kind: LocalModelKind, owner: String) {
        self.monitor = monitor
        self.kind = kind
        self.owner = owner
    }

    func attach(_ progress: Progress) {
        lock.lock(); defer { lock.unlock() }
        observation?.invalidate()
        let monitor = monitor
        let kind = kind
        let owner = owner
        let initial = progress.fractionCompleted
        Task { @MainActor in monitor?.update(kind, owner: owner, fraction: initial) }
        observation = progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in monitor?.update(kind, owner: owner, fraction: fraction) }
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        observation?.invalidate()
        observation = nil
    }
}
