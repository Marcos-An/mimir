import Foundation

public enum MimirError: LocalizedError, Equatable, Sendable {
    case notImplemented(String)
    case microphonePermissionDenied
    case speechPermissionDenied
    case onDeviceSpeechUnavailable
    case transcriptionFailed(String)
    case clipboardAccessFailed
    case accessibilityPermissionDenied
    case noRecordingInProgress

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let message):
            message
        case .microphonePermissionDenied:
            "Microphone permission denied. Enable Mimir in System Settings > Privacy & Security > Microphone."
        case .speechPermissionDenied:
            "Speech recognition permission denied. Enable Mimir in System Settings > Privacy & Security > Speech Recognition."
        case .onDeviceSpeechUnavailable:
            "On-device speech recognition is unavailable for the selected language on this Mac."
        case .transcriptionFailed(let message):
            "Transcription failed: \(message)"
        case .clipboardAccessFailed:
            "Could not write to the clipboard."
        case .accessibilityPermissionDenied:
            "Accessibility permission denied. Enable Mimir in System Settings > Privacy & Security > Accessibility."
        case .noRecordingInProgress:
            "No recording is currently in progress."
        }
    }
}
