import AppKit

/// Notificação postada quando chega uma URL `mimir://toggle`.
/// O `MenuBarController` escuta e alterna o popover.
extension Notification.Name {
    static let mimirTogglePopover = Notification.Name("mimir.togglePopover")
    static let mimirCloseMenuBar = Notification.Name("mimir.closeMenuBar")
}

final class MimirAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Se já existe outra instância do Mimir rodando (ex.: uma sob launchd
        // e o usuário abriu outra pelo Finder), sai dessa. A instância
        // "canônica" segue viva. Evita duas pills/dois menu bar icons.
        if Self.anotherInstanceIsRunning() {
            Self.activateOtherInstance()
            NSApp.terminate(nil)
            return
        }

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private static func anotherInstanceIsRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        return !others.isEmpty
    }

    private static func activateOtherInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
        others.first?.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @MainActor
    static func presentDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "dashboard" || $0.title == "Mimir" }) {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
        }
    }

    @objc func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        guard
            let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: urlString),
            url.scheme == "mimir"
        else { return }

        switch url.host {
        case "toggle":
            var info: [AnyHashable: Any] = [:]
            if let rect = parseAnchor(from: url) {
                info["anchor"] = NSValue(rect: rect)
            }
            NotificationCenter.default.post(name: .mimirTogglePopover, object: nil, userInfo: info)
        default:
            break
        }
    }

    private func parseAnchor(from url: URL) -> NSRect? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        func value(_ name: String) -> Double? {
            items.first(where: { $0.name == name })?.value.flatMap(Double.init)
        }
        guard let x = value("x"), let y = value("y"), let w = value("w"), let h = value("h") else {
            return nil
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }
}
