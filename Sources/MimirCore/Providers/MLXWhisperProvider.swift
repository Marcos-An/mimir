import Foundation

public struct MLXWhisperProvider: SpeechToTextProviding {
    public init() {}

    public func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        throw MimirError.notImplemented("Wire MLX Whisper CLI or embedded runtime here")
    }
}
