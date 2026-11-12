import Foundation

/// Where the Anthropic API key lives: a file only the user can read
/// (permissions 600) in Mimir's Application Support folder, like the gh and
/// claude CLIs keep their tokens.
///
/// It used to live in the Keychain, but Mimir is signed with a local
/// certificate, so macOS treated every new build as a different app and asked
/// for the login password again. A key found in the Keychain is moved to the
/// file once (one last prompt) and removed from the Keychain.
public enum AnthropicAPIKey {
    public static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mimir", isDirectory: true).appendingPathComponent("anthropic-api-key")
    }

    /// File, then a one-time move from the Keychain, then ANTHROPIC_API_KEY
    /// (development escape hatch).
    public static func resolve(
        fileURL: URL = defaultFileURL,
        legacyKeychainRead: () -> String? = { KeychainStore.read(account: AnthropicPostProcessor.apiKeyAccount) },
        legacyKeychainDelete: () -> Void = { KeychainStore.delete(account: AnthropicPostProcessor.apiKeyAccount) },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let key = readFile(fileURL) { return key }
        if let legacy = legacyKeychainRead(), write(legacy, to: fileURL) {
            legacyKeychainDelete()
            return legacy
        }
        if let env = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        return nil
    }

    /// True when a key is saved in the file. Never touches the Keychain, so it
    /// can't trigger a password prompt.
    public static func hasStoredKey(fileURL: URL = defaultFileURL) -> Bool {
        readFile(fileURL) != nil
    }

    @discardableResult
    public static func write(_ key: String, to fileURL: URL = defaultFileURL) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Create with 600 before writing, so the key is never readable by others.
            if !manager.fileExists(atPath: fileURL.path) {
                guard manager.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            try Data(trimmed.utf8).write(to: fileURL, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            return true
        } catch {
            return false
        }
    }

    /// Removes the key everywhere it may be (file and old Keychain item).
    public static func delete(
        fileURL: URL = defaultFileURL,
        legacyKeychainDelete: () -> Void = { KeychainStore.delete(account: AnthropicPostProcessor.apiKeyAccount) }
    ) {
        try? FileManager.default.removeItem(at: fileURL)
        legacyKeychainDelete()
    }

    private static func readFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
