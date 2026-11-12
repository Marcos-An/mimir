import Foundation

public enum WritingAppScope: String, Codable, Sendable, CaseIterable {
    case allApps
    case listedApps
}

/// Which apps the writing check may read. Password fields are blocked
/// separately, in every app.
public struct WritingAppPolicy: Equatable, Sendable {
    public let scope: WritingAppScope
    public let listed: Set<String>
    public let skipped: Set<String>

    public init(scope: WritingAppScope, listed: Set<String>, skipped: Set<String>) {
        self.scope = scope
        self.listed = listed
        self.skipped = skipped
    }

    /// Never checked, even in "All apps": terminals and code editors (code,
    /// commands, noisy and costly), password managers and Keychain (secrets).
    public static let alwaysSkipped: Set<String> = [
        // Terminals
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty", "com.github.wez.wezterm",
        // Code editors
        "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.sublimetext.4", "com.jetbrains.intellij",
        "com.google.android.studio",
        // Secrets
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.Passwords", "com.lastpass.LastPass", "com.apple.keychainaccess",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal"
    ]

    public func allows(_ bundleID: String) -> Bool {
        switch scope {
        case .listedApps:
            return listed.contains(bundleID)
        case .allApps:
            return !Self.alwaysSkipped.contains(bundleID) && !skipped.contains(bundleID)
        }
    }
}
