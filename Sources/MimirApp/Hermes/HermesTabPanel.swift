import AppKit

/// Painel "tab" — pill pequeno que aparece colado na borda direita quando o
/// mouse se aproxima. Clicar nele expande a ilha completa do Hermes.
final class HermesTabPanel: NSPanel {
    static let width: CGFloat = 30
    static let height: CGFloat = 60
    static let rightMargin: CGFloat = 6
    /// Distância do topo da área visível até o topo do tab.
    static let topMargin: CGFloat = 120

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func targetFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
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
