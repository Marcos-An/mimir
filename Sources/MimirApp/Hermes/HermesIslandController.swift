import AppKit
import SwiftUI

/// Controla a ilha do Hermes dentro do Mimir.
/// Estados: `hidden` (nada visível), `tab` (pill pequeno na borda, estilo
/// Grammarly), `expanded` (painel completo com Hermes).
/// - Hover na borda → mostra o tab.
/// - Clique no tab → expande.
/// - Mouse sai do painel → volta a hidden.
/// - Handoff do Mimir via `receiveExternalInput`: pula o tab e vai direto pro expanded.
@MainActor
final class HermesIslandController {
    private enum State {
        case hidden
        case tab
        case expanded
    }

    private var panel: HermesIslandPanel?
    private var terminalHost: HermesTerminalHost?
    private var tabPanel: HermesTabPanel?

    private var state: State = .hidden
    private var animating = false

    private var hoverTimer: Timer?
    private var tabShowTask: Task<Void, Never>?
    private var tabHideTask: Task<Void, Never>?

    private static let triggerZoneWidth: CGFloat = 3
    private static let triggerVerticalPadding: CGFloat = 24
    private static let tabShowDelaySeconds: Double = 0.35
    private static let tabHideDelaySeconds: Double = 0.45
    private static let pollIntervalSeconds: TimeInterval = 0.08

    func start() {
        installHoverWatcher()
        preWarmHermes()
    }

    func stop() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        tabShowTask?.cancel()
        tabHideTask?.cancel()
    }

    /// Cria painel + terminal no boot para o Hermes iniciar cedo, sem exibir.
    private func preWarmHermes() {
        guard let screen = targetScreen() else { return }
        _ = ensureExpandedPanel(on: screen)
    }

    /// Endpoint público para o Mimir entregar texto ao Hermes.
    /// Expande o painel se necessário e escreve no PTY. O painel só fecha
    /// quando o usuário clicar no X do header.
    func receiveExternalInput(_ text: String) {
        if state != .expanded {
            if state == .tab, let tabPanel {
                tabPanel.orderOut(nil)
                state = .hidden
            }
            showExpanded()
        }
        let payload = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.terminalHost?.sendInput(payload)
            self?.terminalHost?.flashAccent()
        }
    }

    // MARK: - Hover

    private func installHoverWatcher() {
        let timer = Timer(timeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateMouseLocation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func evaluateMouseLocation() {
        guard !animating else { return }
        let location = NSEvent.mouseLocation
        let inTriggerZone = isInTriggerZone(location)
        let inTabBounds = isInTabBounds(location)

        switch state {
        case .hidden:
            if inTriggerZone {
                scheduleTabShow()
            } else {
                tabShowTask?.cancel()
                tabShowTask = nil
            }

        case .tab:
            if inTriggerZone || inTabBounds {
                tabHideTask?.cancel()
                tabHideTask = nil
            } else {
                scheduleTabHide()
            }

        case .expanded:
            // Modal expandido só fecha explicitamente pelo botão de fechar.
            break
        }
    }

    private func isInTriggerZone(_ location: NSPoint) -> Bool {
        guard let screen = screen(containing: location) ?? NSScreen.main else { return false }
        let visible = screen.visibleFrame
        let tabY = visible.maxY - HermesTabPanel.height - HermesTabPanel.topMargin
        let tabMaxY = tabY + HermesTabPanel.height
        return location.x >= visible.maxX - Self.triggerZoneWidth
            && location.x <= visible.maxX
            && location.y >= tabY - Self.triggerVerticalPadding
            && location.y <= tabMaxY + Self.triggerVerticalPadding
    }

    private func isInTabBounds(_ location: NSPoint) -> Bool {
        guard state == .tab, let tabPanel else { return false }
        return tabPanel.frame.insetBy(dx: -4, dy: -4).contains(location)
    }

    private func screen(containing location: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(location) }
    }

    // MARK: - Tab

    private func scheduleTabShow() {
        guard tabShowTask == nil else { return }
        tabShowTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tabShowDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.tabShowTask = nil
            guard self.state == .hidden else { return }
            guard self.isInTriggerZone(NSEvent.mouseLocation) else { return }
            self.showTab()
        }
    }

    private func scheduleTabHide() {
        guard tabHideTask == nil else { return }
        tabHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.tabHideDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.tabHideTask = nil
            guard self.state == .tab else { return }
            let mouse = NSEvent.mouseLocation
            if self.isInTabBounds(mouse) || self.isInTriggerZone(mouse) { return }
            self.hideTab()
        }
    }

    private func showTab() {
        guard state == .hidden, !animating else { return }
        guard let screen = targetScreen() else { return }
        let panel = ensureTabPanel(on: screen)
        let target = HermesTabPanel.targetFrame(on: screen)
        let start = HermesTabPanel.offscreenFrame(on: screen)

        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating = false
                self?.state = .tab
            }
        })
    }

    private func hideTab() {
        guard state == .tab, !animating else { return }
        guard let tabPanel, let screen = tabPanel.screen ?? targetScreen() else { return }
        let offscreen = HermesTabPanel.offscreenFrame(on: screen)
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            tabPanel.animator().setFrame(offscreen, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                tabPanel.orderOut(nil)
                self?.animating = false
                self?.state = .hidden
            }
        })
    }

    private func ensureTabPanel(on screen: NSScreen) -> HermesTabPanel {
        if let tabPanel { return tabPanel }
        let target = HermesTabPanel.targetFrame(on: screen)
        let panel = HermesTabPanel(contentRect: target)
        let hosting = NSHostingController(rootView: HermesTabView { [weak self] in
            Task { @MainActor [weak self] in self?.handleTabClicked() }
        })
        hosting.view.frame = panel.contentView?.bounds ?? target
        hosting.view.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting.view)
        self.tabPanel = panel
        return panel
    }

    private func handleTabClicked() {
        expandFromTab()
    }

    private func expandFromTab() {
        guard state == .tab, !animating else { return }
        if let tabPanel { tabPanel.orderOut(nil) }
        state = .hidden
        showExpanded()
    }

    // MARK: - Expanded

    private func showExpanded() {
        guard state != .expanded, !animating else { return }
        guard let screen = targetScreen() else { return }
        let panel = ensureExpandedPanel(on: screen)
        let target = HermesIslandPanel.targetFrame(on: screen)
        let start = HermesIslandPanel.offscreenFrame(on: screen)

        // Reset para a posição-casa (direita) antes de cada exibição, independente de
        // o usuário ter arrastado o painel enquanto estava aberto.
        panel.orderOut(nil)
        panel.setFrame(start, display: false)
        panel.orderFrontRegardless()
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.animating = false
                self?.state = .expanded
            }
        })
    }

    private func hideExpanded() {
        guard state == .expanded, !animating else { return }
        guard let panel, let screen = panel.screen ?? targetScreen() else { return }
        let offscreen = HermesIslandPanel.offscreenFrame(on: screen)
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(offscreen, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                // Depois que sumiu, reposiciona no ponto-casa para que qualquer
                // reabertura comece da direita, não da posição arrastada.
                panel.setFrame(offscreen, display: false)
                self?.animating = false
                self?.state = .hidden
            }
        })
    }

    private func ensureExpandedPanel(on screen: NSScreen) -> HermesIslandPanel {
        if let panel { return panel }
        let target = HermesIslandPanel.targetFrame(on: screen)
        let panel = HermesIslandPanel(contentRect: target)
        panel.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.hideExpanded() }
        }

        let host = HermesTerminalHost(
            frame: panel.contentView?.bounds ?? target,
            onRequestClose: { [weak self] in
                self?.hideExpanded()
            }
        )
        host.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(host)

        self.panel = panel
        self.terminalHost = host
        return panel
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }
}
