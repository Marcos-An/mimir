import AppKit
import os.log

/// Swallows Esc while Mimir is recording, so cancelling a dictation doesn't
/// also reach the app in front (where Esc would, say, stop an AI chat that is
/// still working). Global `NSEvent` monitors only observe keys; consuming one
/// needs a session event tap, which the Accessibility permission allows.
///
/// The tap exists for the whole launch but is enabled only while recording.
/// If it can't be created (permission missing), `isEnabled` stays false and
/// the regular Esc monitor keeps cancelling, as before.
@MainActor
final class EscapeKeyInterceptor {
    private static let escapeKeyCode: Int64 = 53
    private static let logger = Logger(subsystem: "dev.mimir.app", category: "EscapeKey")

    private var tap: CFMachPort?
    private var swallowedKeyDown = false
    private let onEscape: () -> Void
    private(set) var isEnabled = false
    /// Uptime (seconds) of the last Esc this tap consumed, so the observing
    /// monitor can skip the same keypress if it sees it too.
    private(set) var lastHandledTimestamp: TimeInterval = 0

    init(onEscape: @escaping () -> Void) {
        self.onEscape = onEscape
    }

    func setEnabled(_ enabled: Bool) {
        if enabled, tap == nil { install() }
        guard let tap else {
            isEnabled = false
            return
        }
        guard enabled != isEnabled else { return }
        CGEvent.tapEnable(tap: tap, enable: enabled)
        isEnabled = enabled
        if enabled { swallowedKeyDown = false }
    }

    private func install() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<EscapeKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                // The tap's run loop source lives on the main run loop.
                let swallow = MainActor.assumeIsolated {
                    interceptor.shouldSwallow(type: type, event: event)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else { return }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
    }

    private func shouldSwallow(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Self.logger.notice("Esc tap disabled by the system (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)); re-enabling")
            if isEnabled, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        case .keyDown:
            guard isEnabled,
                  event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode
            else { return false }
            // ⌘Esc, ⌥Esc… are someone else's shortcuts.
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            guard event.flags.intersection(modifiers).isEmpty else { return false }
            swallowedKeyDown = true
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                lastHandledTimestamp = Double(event.timestamp) / 1_000_000_000
                onEscape()
            }
            return true
        case .keyUp:
            guard swallowedKeyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Self.escapeKeyCode
            else { return false }
            swallowedKeyDown = false
            return true
        default:
            return false
        }
    }
}
