import AppKit
import SwiftUI
import MimirCore

@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    private var anchoredPanel: NSPanel?
    private var anchoredMonitor: Any?

    private let model: MimirAppModel
    private let store: SettingsStore
    private let levelMonitor: AudioLevelMonitor
    private let downloadMonitor: ModelDownloadMonitor

    private let panelSize = NSSize(width: 360, height: 440)

    init(
        store: SettingsStore,
        model: MimirAppModel,
        levelMonitor: AudioLevelMonitor,
        downloadMonitor: ModelDownloadMonitor
    ) {
        self.store = store
        self.model = model
        self.levelMonitor = levelMonitor
        self.downloadMonitor = downloadMonitor
        super.init()

        // Defer AppKit setup until NSApp is fully up. Creating NSStatusItem and
        // hosting SwiftUI inside App.init breaks click routing on macOS 26.
        DispatchQueue.main.async { [weak self] in
            self?.activate()
        }
    }

    private func activate() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = panelSize
        popover.contentViewController = NSHostingController(rootView: panelView())
        self.popover = popover

        if let button = statusItem.button {
            button.image = MenuBarController.defaultIcon()
            button.target = self
            button.action = #selector(togglePopover(_:))
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleNotification(_:)),
            name: .mimirTogglePopover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseNotification(_:)),
            name: .mimirCloseMenuBar,
            object: nil
        )

        observeState()
    }

    private func panelView() -> some View {
        MenuBarPanelView(
            store: store,
            model: model,
            levelMonitor: levelMonitor,
            downloadMonitor: downloadMonitor
        )
    }

    private func observeState() {
        withObservationTracking {
            _ = model.phase
            _ = downloadMonitor.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeState()
            }
        }
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }

        if downloadMonitor.isActive {
            let image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Mimir")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
            return
        }

        switch model.phase {
        case .recording:
            let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Mimir")
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemRed
        case .transcribing, .postProcessing, .inserting:
            let image = NSImage(systemSymbolName: "ellipsis.circle.fill", accessibilityDescription: "Mimir")
            image?.isTemplate = true
            button.image = image
            button.contentTintColor = nil
        case .error:
            let image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Mimir")
            image?.isTemplate = false
            button.image = image
            button.contentTintColor = .systemOrange
        default:
            button.image = MenuBarController.defaultIcon()
            button.contentTintColor = nil
        }
    }

    private static func defaultIcon() -> NSImage {
        let fallback: NSImage = {
            let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Mimir") ?? NSImage()
            img.isTemplate = true
            return img
        }()
        guard let url = Bundle.module.url(forResource: "MenuBarIcon", withExtension: "png"),
              let source = NSImage(contentsOf: url) else {
            return fallback
        }
        let targetHeight: CGFloat = 18
        let sourceSize = source.size
        guard sourceSize.height > 0 else { return fallback }
        let ratio = targetHeight / sourceSize.height
        let target = NSSize(width: sourceSize.width * ratio, height: targetHeight)
        let resized = NSImage(size: target, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        resized.isTemplate = true
        return resized
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    @objc private func handleCloseNotification(_ note: Notification) {
        if anchoredPanel?.isVisible == true {
            closeAnchoredPanel()
        }
        if let popover, popover.isShown {
            close()
        }
    }

    @objc private func handleToggleNotification(_ note: Notification) {
        if anchoredPanel?.isVisible == true {
            closeAnchoredPanel()
            return
        }
        if let popover, popover.isShown {
            close()
        }
        if let value = note.userInfo?["anchor"] as? NSValue {
            showAnchoredPanel(anchor: value.rectValue)
        } else {
            // Sem âncora → popover nativo do status item.
            show()
        }
    }

    func show() {
        guard let popover, let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        popover?.performClose(nil)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    // MARK: - Painel ancorado (clique vindo do mbar com coords da pill)

    private func showAnchoredPanel(anchor: NSRect) {
        let rootView = panelView()
            .frame(width: panelSize.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )

        let hosting = NSHostingView(rootView: rootView)
        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(
            width: panelSize.width,
            height: max(hosting.fittingSize.height, 1)
        )
        hosting.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hosting

        let frame = placement(for: anchor, size: size)
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        self.anchoredPanel = panel

        anchoredMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeAnchoredPanel()
        }
    }

    private func closeAnchoredPanel() {
        anchoredPanel?.orderOut(nil)
        anchoredPanel = nil
        if let anchoredMonitor {
            NSEvent.removeMonitor(anchoredMonitor)
            self.anchoredMonitor = nil
        }
    }

    private func placement(for anchor: NSRect, size: NSSize) -> NSRect {
        // Posiciona centrado horizontalmente em relação ao anchor e logo abaixo dele.
        let gap: CGFloat = 6
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - size.height - gap

        // Clamp dentro da tela que contém o anchor.
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) })
            ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            x = min(max(x, frame.minX + 8), frame.maxX - size.width - 8)
            if y < frame.minY + 8 {
                y = anchor.maxY + gap
            }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}
