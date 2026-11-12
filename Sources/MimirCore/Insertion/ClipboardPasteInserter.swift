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
        let ourChangeCount = pasteboard.changeCount

        guard autoPaste else { return }

        do {
            _ = try PermissionCoordinator.ensureAccessibilityAccess(prompt: false)
            let yieldedFocus = await yieldFocusFromMimir()
            if yieldedFocus {
                // Só espera o foco assentar quando o Mimir estava frontmost e
                // precisou se esconder. No fluxo normal (ditando em outro app via
                // painel non-activating) o alvo já está focado — esperar aqui era
                // 120 ms de latência pura em todo paste.
                try await Task.sleep(for: .milliseconds(120))
            }
            try sendCommandV()
        } catch {
            restorePasteboard(previousItems)
            throw error
        }

        // Restoring doesn't hold the return (or the "Pasting…" phase): ⌘V is
        // already posted. The target app reads the clipboard when it handles
        // the keystroke, and a busy app (Slack) can take far longer than the
        // 150 ms used before — it then pasted the user's OLD clipboard. Wait
        // 1 s, and skip the restore if anything else wrote the clipboard since.
        Task {
            try? await Task.sleep(for: .milliseconds(1000))
            guard NSPasteboard.general.changeCount == ourChangeCount else { return }
            restorePasteboard(previousItems)
        }
    }

    /// Retorna `true` quando o Mimir estava frontmost e cedeu o foco.
    @MainActor
    private func yieldFocusFromMimir() -> Bool {
        let bundleID = Bundle.main.bundleIdentifier
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        guard frontmost.bundleIdentifier == bundleID else { return false }
        NSApp.hide(nil)
        return true
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
