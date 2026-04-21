import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public var activationMode: ActivationMode
    public var activationTrigger: KeyBinding
    public var hermesActivationTrigger: KeyBinding
    public var transcriptionProvider: TranscriptionProvider
    public var transcriptionStrategy: TranscriptionStrategy
    public var whisperKitModel: WhisperKitModel
    public var postProcessingProvider: PostProcessingProvider
    public var postProcessingStyle: PostProcessingStyle
    public var insertionStrategy: InsertionStrategy
    public var shouldAutoPaste: Bool
    public var preferredLanguage: String?
    public var inputDeviceUID: String?

    public init(
        activationMode: ActivationMode,
        activationTrigger: KeyBinding,
        hermesActivationTrigger: KeyBinding,
        transcriptionProvider: TranscriptionProvider,
        transcriptionStrategy: TranscriptionStrategy,
        whisperKitModel: WhisperKitModel,
        postProcessingProvider: PostProcessingProvider,
        postProcessingStyle: PostProcessingStyle,
        insertionStrategy: InsertionStrategy,
        shouldAutoPaste: Bool,
        preferredLanguage: String?,
        inputDeviceUID: String? = nil
    ) {
        self.activationMode = activationMode
        self.activationTrigger = activationTrigger
        self.hermesActivationTrigger = hermesActivationTrigger
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionStrategy = transcriptionStrategy
        self.whisperKitModel = whisperKitModel
        self.postProcessingProvider = postProcessingProvider
        self.postProcessingStyle = postProcessingStyle
        self.insertionStrategy = insertionStrategy
        self.shouldAutoPaste = shouldAutoPaste
        self.preferredLanguage = preferredLanguage
        self.inputDeviceUID = inputDeviceUID
    }

    private enum CodingKeys: String, CodingKey {
        case activationMode, activationTrigger, hermesActivationTrigger
        case transcriptionProvider
        case transcriptionStrategy, whisperKitModel
        case postProcessingProvider, postProcessingStyle
        case insertionStrategy, shouldAutoPaste
        case preferredLanguage, inputDeviceUID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activationMode = try container.decode(ActivationMode.self, forKey: .activationMode)
        self.activationTrigger = try container.decode(KeyBinding.self, forKey: .activationTrigger)
        self.hermesActivationTrigger = try container.decodeIfPresent(KeyBinding.self, forKey: .hermesActivationTrigger) ?? .defaultRightOptionSpace
        self.transcriptionProvider = try container.decode(TranscriptionProvider.self, forKey: .transcriptionProvider)
        self.transcriptionStrategy = try container.decodeIfPresent(TranscriptionStrategy.self, forKey: .transcriptionStrategy) ?? .chunked
        self.whisperKitModel = try container.decodeIfPresent(WhisperKitModel.self, forKey: .whisperKitModel) ?? .largeV3TurboQuantized
        self.postProcessingProvider = try container.decode(PostProcessingProvider.self, forKey: .postProcessingProvider)
        self.postProcessingStyle = try container.decodeIfPresent(PostProcessingStyle.self, forKey: .postProcessingStyle) ?? .structured
        self.insertionStrategy = try container.decode(InsertionStrategy.self, forKey: .insertionStrategy)
        self.shouldAutoPaste = try container.decode(Bool.self, forKey: .shouldAutoPaste)
        self.preferredLanguage = try container.decodeIfPresent(String.self, forKey: .preferredLanguage)
        self.inputDeviceUID = try container.decodeIfPresent(String.self, forKey: .inputDeviceUID)
    }

    public static let `default` = AppSettings(
        activationMode: .tapToToggle,
        activationTrigger: .defaultRightCommand,
        hermesActivationTrigger: .defaultRightOptionSpace,
        transcriptionProvider: .whisperKit,
        transcriptionStrategy: .chunked,
        whisperKitModel: .largeV3TurboQuantized,
        postProcessingProvider: .mlx,
        postProcessingStyle: .structured,
        insertionStrategy: .clipboardPaste,
        shouldAutoPaste: true,
        preferredLanguage: nil,
        inputDeviceUID: nil
    )
}

public enum TranscriptionStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case batch
    case chunked

    public var displayName: String {
        switch self {
        case .batch:
            "Lote (arquivo inteiro)"
        case .chunked:
            "Em chunks (VAD)"
        }
    }
}

public enum WhisperKitModel: String, Codable, CaseIterable, Equatable, Sendable {
    case tiny
    case base
    case small
    case medium
    case largeV3TurboQuantized
    case largeV3Turbo
    case largeV3

    public var displayName: String {
        switch self {
        case .tiny:
            "Tiny (39M, muito rápido, qualidade baixa)"
        case .base:
            "Base (74M, rápido, qualidade ok)"
        case .small:
            "Small (244M, bom equilíbrio)"
        case .medium:
            "Medium (769M, qualidade alta)"
        case .largeV3TurboQuantized:
            "Large v3 Turbo quantizado (~950MB, qualidade quase full)"
        case .largeV3Turbo:
            "Large v3 Turbo full (~3GB, qualidade top)"
        case .largeV3:
            "Large v3 (1.5B, qualidade máxima, mais lento)"
        }
    }

    /// Canonical WhisperKit model identifier used to resolve Core ML bundles.
    public var modelName: String {
        switch self {
        case .tiny:
            "openai_whisper-tiny"
        case .base:
            "openai_whisper-base"
        case .small:
            "openai_whisper-small"
        case .medium:
            "openai_whisper-medium"
        case .largeV3TurboQuantized:
            "openai_whisper-large-v3_turbo_954MB"
        case .largeV3Turbo:
            "openai_whisper-large-v3_turbo"
        case .largeV3:
            "openai_whisper-large-v3"
        }
    }
}

public enum PostProcessingStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case disabled
    case cleanup
    case structured

    public var displayName: String {
        switch self {
        case .disabled:
            "Desativado"
        case .cleanup:
            "Correção leve"
        case .structured:
            "Estruturado"
        }
    }
}

public enum ActivationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case holdToTalk
    case tapToToggle

    public var displayName: String {
        switch self {
        case .holdToTalk:
            "Segurar para falar"
        case .tapToToggle:
            "Tocar para alternar"
        }
    }
}

public struct KeyBinding: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt
    public var label: String

    public init(keyCode: UInt16, modifiers: UInt, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    public var isModifierOnly: Bool {
        Self.modifierKeyCodes.contains(keyCode)
    }

    /// Combo formado apenas por modificadores (sem tecla principal). Exemplo: ⌃+⇧.
    public var isModifierCombo: Bool {
        keyCode == 0 && modifiers != 0
    }

    public static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 58, 59, 60, 61, 62, 63]

    public static let defaultRightCommand = KeyBinding(
        keyCode: 54,
        modifiers: 0,
        label: "Right ⌘"
    )

    /// Default para o modo Hermes: ⌥ + espaço.
    /// keyCode 49 = space; modifiers = .option (1 << 19).
    public static let defaultRightOptionSpace = KeyBinding(
        keyCode: 49,
        modifiers: 1 << 19,
        label: "⌥ Space"
    )

    public var keyCaps: [String] {
        if isModifierOnly {
            return [label]
        }
        var caps: [String] = []
        if modifiers & (1 << 18) != 0 { caps.append("⌃") }   // control
        if modifiers & (1 << 19) != 0 { caps.append("⌥") }   // option
        if modifiers & (1 << 17) != 0 { caps.append("⇧") }   // shift
        if modifiers & (1 << 20) != 0 { caps.append("⌘") }   // command
        if modifiers & (1 << 23) != 0 { caps.append("fn") }  // function
        var key = label
        for symbol in ["⌃", "⌥", "⇧", "⌘", "fn"] {
            key = key.replacingOccurrences(of: symbol, with: "")
        }
        key = key.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { caps.append(key) }
        return caps
    }
}

public enum TranscriptionProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case appleSpeech
    case whisperKit
    case mlxWhisper
    case whisperCPP
    case fasterWhisper

    public var displayName: String {
        switch self {
        case .appleSpeech:
            "Apple Speech (on-device)"
        case .whisperKit:
            "Whisper (Core ML)"
        case .mlxWhisper:
            "MLX Whisper"
        case .whisperCPP:
            "whisper.cpp"
        case .fasterWhisper:
            "faster-whisper"
        }
    }

    public var isAvailable: Bool {
        self == .appleSpeech || self == .whisperKit
    }
}

public enum PostProcessingProvider: String, Codable, CaseIterable, Equatable, Sendable {
    case disabled
    case mlx

    public var displayName: String {
        switch self {
        case .disabled:
            "Desativado"
        case .mlx:
            "MLX (local)"
        }
    }

    public var isAvailable: Bool {
        true
    }
}

public enum InsertionStrategy: String, Codable, CaseIterable, Equatable, Sendable {
    case clipboardPaste
    case accessibilityAPI

    public var displayName: String {
        switch self {
        case .clipboardPaste:
            "Colar via área de transferência"
        case .accessibilityAPI:
            "Acessibilidade (em breve)"
        }
    }

    public var isAvailable: Bool {
        self == .clipboardPaste
    }
}

public struct LanguageOption: Identifiable, Equatable, Sendable {
    public let code: String?
    public let displayName: String

    public var id: String { code ?? "auto" }

    public init(code: String?, displayName: String) {
        self.code = code
        self.displayName = displayName
    }

    public static let supported: [LanguageOption] = [
        LanguageOption(code: nil, displayName: "Automático (sistema)"),
        LanguageOption(code: "pt-BR", displayName: "Português (Brasil)"),
        LanguageOption(code: "pt-PT", displayName: "Português (Portugal)"),
        LanguageOption(code: "en-US", displayName: "Inglês (EUA)"),
        LanguageOption(code: "en-GB", displayName: "Inglês (Reino Unido)"),
        LanguageOption(code: "es-ES", displayName: "Espanhol (Espanha)"),
        LanguageOption(code: "es-MX", displayName: "Espanhol (México)"),
        LanguageOption(code: "fr-FR", displayName: "Francês"),
        LanguageOption(code: "de-DE", displayName: "Alemão"),
        LanguageOption(code: "it-IT", displayName: "Italiano"),
        LanguageOption(code: "ja-JP", displayName: "Japonês")
    ]

    public static func displayName(for code: String?) -> String {
        supported.first(where: { $0.code == code })?.displayName
            ?? code
            ?? "Automático (sistema)"
    }
}
