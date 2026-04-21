import Foundation
import Speech

public struct AppleSpeechProvider: SpeechToTextProviding {
    public init() {}

    public func transcribe(audioFileURL: URL, languageHint: String?) async throws -> SpeechTranscription {
        try await PermissionCoordinator.ensureSpeechAccess()

        let locale = languageHint.flatMap(Locale.init(identifier:)) ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw MimirError.transcriptionFailed("No speech recognizer is available")
        }

        guard recognizer.supportsOnDeviceRecognition else {
            throw MimirError.onDeviceSpeechUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: audioFileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if let languageHint {
            request.taskHint = .dictation
            _ = languageHint
        }

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: MimirError.transcriptionFailed(error.localizedDescription))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    resumed = true
                    continuation.resume(returning: SpeechTranscription(
                        text: result.bestTranscription.formattedString,
                        language: recognizer.locale.identifier
                    ))
                }
            }
        }
    }
}
