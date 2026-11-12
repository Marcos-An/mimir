import Foundation
import Observation

@MainActor
@Observable
public final class SettingsStore {
    public var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
        }
    }

    private let defaults: UserDefaults
    private let defaultsKey: String
    private let legacyCleanDictationMigrationKey = "com.mimir.migrations.cleanDictationDefault.v1"
    private let cleanDictationMigrationKey = "com.mimir.migrations.cleanDictationDefault.v2"
    private let whisperTurboMigrationKey = "com.mimir.migrations.whisperTurboDefault.v1"
    private let disabledProviderMigrationKey = "com.mimir.migrations.disabledProvider.v1"

    public init(defaults: UserDefaults = .standard, defaultsKey: String = "com.mimir.settings.v1") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        var loaded = Self.loadSettings(from: defaults, key: defaultsKey) ?? .default
        // Early builds saved "disabled" as a placeholder; moved to local AI
        // once. Afterwards "Off" is a real choice and must stick.
        let shouldMigrateDisabled = !defaults.bool(forKey: disabledProviderMigrationKey)
            && loaded.postProcessingProvider == .disabled
        if shouldMigrateDisabled {
            loaded.postProcessingProvider = .mlx
            loaded.promptPostProcessingProvider = .mlx
        }
        let shouldMigrateCleanDictation = !defaults.bool(forKey: cleanDictationMigrationKey)
            && loaded.postProcessingStyle == .structured
        if shouldMigrateCleanDictation {
            loaded.postProcessingStyle = .cleanDictation
        }
        // O padrão antigo era o large-v3 completo comprimido (~3× mais lento que
        // o turbo de verdade). Quem ainda está nele migra uma vez; escolher o
        // modelo antigo de novo depois disso é respeitado.
        let shouldMigrateWhisperTurbo = !defaults.bool(forKey: whisperTurboMigrationKey)
            && loaded.whisperKitModel == .largeV3TurboQuantized
        if shouldMigrateWhisperTurbo {
            loaded.whisperKitModel = .whisperTurbo
        }
        self.settings = loaded
        defaults.set(true, forKey: whisperTurboMigrationKey)
        defaults.set(true, forKey: disabledProviderMigrationKey)
        if shouldMigrateDisabled {
            persist()
        }
        if shouldMigrateWhisperTurbo {
            persist()
        }
        if shouldMigrateCleanDictation {
            defaults.set(true, forKey: legacyCleanDictationMigrationKey)
            defaults.set(true, forKey: cleanDictationMigrationKey)
            persist()
        }
    }

    public func reset() {
        settings = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    private static func loadSettings(from defaults: UserDefaults, key: String) -> AppSettings? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }
}
