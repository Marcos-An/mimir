import Foundation

public struct DashboardItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let isExternal: Bool

    public init(id: String, title: String, systemImage: String, isExternal: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.isExternal = isExternal
    }
}

public enum DashboardSection {
    public static let primaryItems: [DashboardItem] = [
        DashboardItem(id: "overview", title: "Overview", systemImage: "sparkles"),
        DashboardItem(id: "session", title: "Session", systemImage: "waveform"),
        DashboardItem(id: "history", title: "History", systemImage: "text.quote")
    ]

    public static let utilityItems: [DashboardItem] = [
        DashboardItem(id: "permissions", title: "Permissions", systemImage: "checkmark.shield"),
        DashboardItem(id: "settings", title: "Settings", systemImage: "slider.horizontal.3")
    ]

    public static let settingsItems: [DashboardItem] = [
        DashboardItem(id: "general", title: "General", systemImage: "gearshape"),
        DashboardItem(id: "audio", title: "Audio", systemImage: "mic"),
        DashboardItem(id: "pipeline", title: "Pipeline", systemImage: "point.3.connected.trianglepath.dotted"),
        DashboardItem(id: "permissions", title: "Permissions", systemImage: "checkmark.shield"),
        DashboardItem(id: "about", title: "About", systemImage: "info.circle")
    ]
}

public enum DashboardChrome {
    public static let appName = "MIMIR"
    public static let sidebarCardTitle = "Own theme, local flow"
    public static let sidebarCardBody = "Native macOS transcription with an expressive look, built for speed and on-device privacy."
    public static let sidebarCardButton = "Tune pipeline"
    public static let primaryActionTitle = "Start transcribing"
}

public struct DashboardMetric: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let value: String
    public let systemImage: String

    public init(id: String, title: String, value: String, systemImage: String) {
        self.id = id
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    public static let defaultMetrics: [DashboardMetric] = [
        DashboardMetric(id: "shortcut", title: "Active shortcut", value: "Right ⌘", systemImage: "command"),
        DashboardMetric(id: "transcription", title: "Transcription", value: "On-device", systemImage: "waveform.badge.mic"),
        DashboardMetric(id: "insertion", title: "Insertion", value: "Clipboard + paste", systemImage: "document.on.clipboard"),
        DashboardMetric(id: "language", title: "Language", value: "Automatic", systemImage: "globe")
    ]
}

public struct DashboardPromo: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let action: String
    public let systemImage: String

    public init(id: String, title: String, body: String, action: String, systemImage: String) {
        self.id = id
        self.title = title
        self.body = body
        self.action = action
        self.systemImage = systemImage
    }

    public static let defaultCards: [DashboardPromo] = [
        DashboardPromo(
            id: "hotkey",
            title: "Trigger in any app",
            body: "Use your shortcut to start speaking without switching context. MIMIR records, transcribes, and pastes it for you.",
            action: "Open shortcuts",
            systemImage: "command"
        ),
        DashboardPromo(
            id: "privacy",
            title: "Privacy first",
            body: "Review permissions, language, and post-processing in a panel built around what ships today.",
            action: "Review permissions",
            systemImage: "lock.shield"
        )
    ]
}
