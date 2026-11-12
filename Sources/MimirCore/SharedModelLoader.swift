import Foundation

/// Keeps one loaded model of a kind alive across dictation-session rebuilds.
///
/// Changing almost any setting rebuilds the session, which creates new
/// providers. Without this, each rebuild reloaded the full model (hundreds of
/// MB, plus Neural Engine compilation for Whisper). Concurrent callers for the
/// same model share one load; asking for a different model replaces it.
actor SharedModelLoader<Value> {
    /// Model objects are used by one session at a time; the box only lets them
    /// cross into this actor.
    struct Box: @unchecked Sendable {
        let value: Value
    }

    private var key: String?
    private var task: Task<Box, Error>?

    func value(
        for key: String,
        load: @escaping @Sendable () async throws -> Box
    ) async throws -> Value {
        if self.key == key, let task {
            return try await task.value.value
        }
        let task = Task { try await load() }
        self.key = key
        self.task = task
        do {
            return try await task.value.value
        } catch {
            // Let the next call retry, unless another model replaced this one.
            if self.task == task {
                self.task = nil
                self.key = nil
            }
            throw error
        }
    }
}
