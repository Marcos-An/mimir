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

    public init(defaults: UserDefaults = .standard, defaultsKey: String = "com.mimir.settings.v1") {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        var loaded = Self.loadSettings(from: defaults, key: defaultsKey) ?? .default
        if loaded.postProcessingProvider == .disabled {
            loaded.postProcessingProvider = .mlx
        }
        self.settings = loaded
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
