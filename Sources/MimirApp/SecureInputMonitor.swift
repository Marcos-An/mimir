import AppKit
import Carbon.HIToolbox
import IOKit
import Observation

/// While an app holds macOS "Secure Input" (a focused password field, or a
/// browser that forgot to release it), no other app sees keystrokes: Mimir's
/// Esc tap and key monitors go blind. Modifier keys still arrive, which is why
/// the dictation shortcut keeps working while Esc does not. This watches for
/// that state during a recording so the island can say so and offer ✕.
@MainActor
@Observable
final class SecureInputMonitor {
    /// Name of the app holding Secure Input, or nil when keys are visible.
    private(set) var blockingAppName: String?

    @ObservationIgnored private var timer: Timer?

    func setWatching(_ watching: Bool) {
        if watching {
            guard timer == nil else { return }
            check()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            blockingAppName = nil
        }
    }

    private func check() {
        let name: String?
        if IsSecureEventInputEnabled() {
            name = Self.holderPID().flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "Another app"
        } else {
            name = nil
        }
        if name != blockingAppName { blockingAppName = name }
    }

    /// The PID macOS records for the Secure Input holder (same value
    /// `ioreg -l | grep SecureInput` shows), from the console user session.
    private static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? Int, pid > 0 {
                return pid_t(pid)
            }
        }
        return nil
    }
}
