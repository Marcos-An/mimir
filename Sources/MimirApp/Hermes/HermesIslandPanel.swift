import AppKit
import SwiftUI

/// Painel lateral direita que hospeda o terminal do Hermes dentro do Mimir.
/// Mesma ergonomia da BarController do mbar: floating, nonactivating, visível em todos os Spaces.
final class HermesIslandPanel: NSPanel {
    static let width: CGFloat = 620
    static let rightMargin: CGFloat = 16
    static let verticalPadding: CGFloat = 48
    static let maxHeight: CGFloat = 900
    static let minWidth: CGFloat = 420
    static let minHeight: CGFloat = 320

    var onEscape: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        minSize = NSSize(width: Self.minWidth, height: Self.minHeight)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        // Esc = minimizar o painel.
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    static let topMargin: CGFloat = 74

    static func targetFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let height = min(maxHeight, visible.height - topMargin - verticalPadding)
        let y = visible.maxY - height - topMargin
        return NSRect(
            x: visible.maxX - width - rightMargin,
            y: y,
            width: width,
            height: height
        )
    }

    static func offscreenFrame(on screen: NSScreen) -> NSRect {
        var frame = targetFrame(on: screen)
        frame.origin.x = screen.visibleFrame.maxX
        return frame
    }
}
