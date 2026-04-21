import AppKit
import ApplicationServices
import Foundation

public struct ClipboardPasteInserter: TextInserting {
    public let autoPaste: Bool

    public init(autoPaste: Bool = true) {
        self.autoPaste = autoPaste
    }

    public func insert(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let previousItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                }
            }
            return clone
        }

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw MimirError.clipboardAccessFailed
        }

        guard autoPaste else { return }

        do {
            _ = try PermissionCoordinator.ensureAccessibilityAccess(prompt: false)
            await yieldFocusFromMimir()
            try await Task.sleep(for: .milliseconds(120))
            try sendCommandV()
        } catch {
            restorePasteboard(previousItems)
            throw error
        }

        try? await Task.sleep(for: .milliseconds(150))
        restorePasteboard(previousItems)
    }

    @MainActor
    private func yieldFocusFromMimir() {
        let bundleID = Bundle.main.bundleIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return }
        guard frontmost.bundleIdentifier == bundleID else { return }
        NSApp.hide(nil)
    }

    private func sendCommandV() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw MimirError.accessibilityPermissionDenied
        }
        source.localEventsSuppressionInterval = 0.0

        let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

        [commandDown, vDown, vUp, commandUp].forEach { event in
            event?.flags = .maskCommand
            event?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func restorePasteboard(_ items: [NSPasteboardItem]?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let items, !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
