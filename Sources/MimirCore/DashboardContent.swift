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
        DashboardItem(id: "overview", title: "Painel", systemImage: "sparkles"),
        DashboardItem(id: "session", title: "Sessão", systemImage: "waveform"),
        DashboardItem(id: "history", title: "Histórico", systemImage: "text.quote")
    ]

    public static let utilityItems: [DashboardItem] = [
        DashboardItem(id: "permissions", title: "Permissões", systemImage: "checkmark.shield"),
        DashboardItem(id: "settings", title: "Configurações", systemImage: "slider.horizontal.3")
    ]

    public static let settingsItems: [DashboardItem] = [
        DashboardItem(id: "general", title: "Geral", systemImage: "gearshape"),
        DashboardItem(id: "audio", title: "Áudio", systemImage: "mic"),
        DashboardItem(id: "pipeline", title: "Pipeline", systemImage: "point.3.connected.trianglepath.dotted"),
        DashboardItem(id: "permissions", title: "Permissões", systemImage: "checkmark.shield"),
        DashboardItem(id: "about", title: "Sobre", systemImage: "info.circle")
    ]
}

public enum DashboardChrome {
    public static let appName = "MIMIR"
    public static let sidebarCardTitle = "Tema próprio, fluxo local"
    public static let sidebarCardBody = "Transcrição nativa para macOS com visual expressivo, foco em velocidade e privacidade no dispositivo."
    public static let sidebarCardButton = "Ajustar pipeline"
    public static let primaryActionTitle = "Começar a transcrever"
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
        DashboardMetric(id: "shortcut", title: "Atalho ativo", value: "Right ⌘", systemImage: "command"),
        DashboardMetric(id: "transcription", title: "Transcrição", value: "On-device", systemImage: "waveform.badge.mic"),
        DashboardMetric(id: "insertion", title: "Inserção", value: "Clipboard + paste", systemImage: "document.on.clipboard"),
        DashboardMetric(id: "language", title: "Idioma", value: "Automático", systemImage: "globe")
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
            title: "Ative em qualquer app",
            body: "Use o atalho configurado para começar a falar sem trocar de contexto. O MIMIR grava, transcreve e cola para você.",
            action: "Abrir atalhos",
            systemImage: "command"
        ),
        DashboardPromo(
            id: "privacy",
            title: "Privacidade primeiro",
            body: "Revise permissões, idioma e pós-processamento num painel pensado para o que já existe hoje no produto.",
            action: "Revisar permissões",
            systemImage: "lock.shield"
        )
    ]
}
