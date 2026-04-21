public enum AppPhase: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case postProcessing
    case inserting
    case error(message: String)

    public var displayTitle: String {
        switch self {
        case .idle:
            "Ready"
        case .recording:
            "Recording…"
        case .transcribing:
            "Transcribing…"
        case .postProcessing:
            "Polishing…"
        case .inserting:
            "Pasting…"
        case .error:
            "Error"
        }
    }
}
