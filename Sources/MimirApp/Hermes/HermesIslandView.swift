import AppKit
import MimirCore
import SwiftTerm
import SwiftUI

/// Host da ilha do Hermes: header com título + botão fechar no topo, SwiftTerm
/// rodando o processo abaixo. O terminal é mantido vivo enquanto o host existir.
final class HermesTerminalHost: NSView {
    let terminal: LocalProcessTerminalView
    private let onRequestClose: @MainActor () -> Void
    private var headerHost: NSHostingView<HermesIslandHeader>!
    private var blurView: NSVisualEffectView!
    private var resizeHandle: HermesResizeHandle!
    private let state = HermesIslandHeaderState()

    /// Caminho resolvido do executável do Hermes (via `$HERMES_PATH` ou `~/.local/bin/hermes`).
    /// `nil` quando o binário não está disponível — neste caso `startHermes()` mostra
    /// uma tela informativa em vez de iniciar um processo.
    private static var hermesPath: String? { MimirEnvironment.hermesExecutablePath }
    private static var workingDirectory: String { MimirEnvironment.defaultWorkingDirectory }
    static let surfaceColor = NSColor(srgbRed: 0.090, green: 0.090, blue: 0.094, alpha: 1.0)
    private static let contentPadding: CGFloat = 10
    private static let headerHeight: CGFloat = 34
    private static let accentColor = NSColor(srgbRed: 0.209, green: 0.349, blue: 0.831, alpha: 1.0)
    private static let idleBorderColor = NSColor(white: 1, alpha: 0.08)

    init(frame frameRect: NSRect, onRequestClose: @escaping @MainActor () -> Void) {
        self.terminal = LocalProcessTerminalView(frame: frameRect)
        self.onRequestClose = onRequestClose
        super.init(frame: frameRect)
        configureBackground()
        configureHeader()
        configureTerminal()
        configureResizeHandle()
        addSubview(blurView)
        addSubview(terminal)
        addSubview(headerHost)
        addSubview(resizeHandle)
        startHermes()
    }

    private func configureResizeHandle() {
        let size: CGFloat = 18
        let handle = HermesResizeHandle(frame: NSRect(
            x: bounds.maxX - size,
            y: bounds.minY,
            width: size,
            height: size
        ))
        handle.autoresizingMask = [.minXMargin, .maxYMargin]
        resizeHandle = handle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layout() {
        super.layout()
        let inset = HermesTerminalHost.contentPadding
        let headerHeight = HermesTerminalHost.headerHeight
        let contentRect = bounds.insetBy(dx: inset, dy: inset)
        blurView.frame = bounds
        headerHost.frame = NSRect(
            x: contentRect.minX,
            y: contentRect.maxY - headerHeight,
            width: contentRect.width,
            height: headerHeight
        )
        terminal.frame = NSRect(
            x: contentRect.minX,
            y: contentRect.minY,
            width: contentRect.width,
            height: contentRect.height - headerHeight - 4
        )
    }

    private func configureBackground() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 16
        layer?.borderWidth = 1
        layer?.borderColor = HermesTerminalHost.idleBorderColor.cgColor
        layer?.masksToBounds = true

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blurView = blur
    }

    private func configureHeader() {
        let view = NSHostingView(rootView: HermesIslandHeader(
            state: state,
            onClose: { [weak self] in
                MainActor.assumeIsolated { self?.onRequestClose() }
            },
            onRestart: { [weak self] in
                MainActor.assumeIsolated { self?.restartSession() }
            }
        ))
        view.autoresizingMask = [.width]
        headerHost = view
    }

    private func configureTerminal() {
        terminal.autoresizingMask = [.width, .height]
        if let font = NSFont(name: "SF Mono", size: 13)
            ?? NSFont(name: "Menlo", size: 13) {
            terminal.font = font
        }
        terminal.nativeForegroundColor = NSColor(white: 0.94, alpha: 1.0)
        terminal.nativeBackgroundColor = NSColor.clear
        terminal.wantsLayer = true
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.processDelegate = self
        DispatchQueue.main.async { [weak self] in
            self?.applyThinScroller()
        }
    }

    private func startHermes() {
        guard let hermesPath = HermesTerminalHost.hermesPath else {
            // Hermes não instalado — mostra mensagem informativa no terminal
            // e mantém o host vivo (sem processo filho).
            state.running = false
            let message = """

            \u{1B}[1;33mHermes não está instalado.\u{1B}[0m

            O Mimir integra com o Hermes, uma CLI separada e opcional.
            Pra ativar este painel:

              1. Instale o Hermes no seu PATH, ou
              2. Defina HERMES_PATH apontando pro binário:
                   export HERMES_PATH=/caminho/para/hermes

            O restante do Mimir funciona normalmente sem o Hermes.

            """
            terminal.feed(text: message)
            return
        }

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let extraPath = "\(NSString(string: "~/.local/bin").expandingTildeInPath):/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = [extraPath, env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")

        let envArray = env.map { "\($0.key)=\($0.value)" }

        terminal.startProcess(
            executable: hermesPath,
            args: [],
            environment: envArray,
            execName: nil,
            currentDirectory: HermesTerminalHost.workingDirectory
        )
        state.running = true
    }

    func sendInput(_ text: String) {
        terminal.send(txt: text)
    }

    /// SwiftTerm usa um NSScroller fixo em `.legacy` (grosso). Fazemos override
    /// pós-layout para aplicar `.overlay` (thin auto-hide) no scroller dele.
    private func applyThinScroller() {
        for subview in terminal.subviews {
            if let scroller = subview as? NSScroller {
                scroller.scrollerStyle = .overlay
                scroller.controlSize = .small
            }
        }
    }

    /// Pisca a borda em azul por ~400ms para indicar que o Mimir entregou algo novo.
    func flashAccent() {
        guard let layer else { return }
        let anim = CABasicAnimation(keyPath: "borderColor")
        anim.fromValue = HermesTerminalHost.accentColor.cgColor
        anim.toValue = HermesTerminalHost.idleBorderColor.cgColor
        anim.duration = 0.45
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.borderColor = HermesTerminalHost.idleBorderColor.cgColor
        layer.add(anim, forKey: "flashAccent")
    }

    /// Mata o processo atual e reinicia uma nova sessão do Hermes.
    func restartSession() {
        guard MimirEnvironment.isHermesAvailable else { return }
        terminal.send(txt: "\u{0003}") // Ctrl+C para terminar comando em curso
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.startHermes()
        }
    }
}

extension HermesTerminalHost: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.state.running = false
        }
    }
}

/// Estado observável do header (status do processo).
@MainActor
final class HermesIslandHeaderState: ObservableObject {
    @Published var running: Bool = false
}

/// Header com título, indicador de estado, grip de drag, restart e fechar.
struct HermesIslandHeader: View {
    @ObservedObject var state: HermesIslandHeaderState
    let onClose: () -> Void
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.28))
                .help("Arraste daqui para mover")

            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.55, green: 0.40, blue: 0.98),
                            Color(red: 0.78, green: 0.45, blue: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text("Hermes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.85))
                .tracking(0.3)

            Circle()
                .fill(state.running ? Color.green : Color.red)
                .frame(width: 6, height: 6)
                .help(state.running ? "Sessão ativa" : "Processo encerrado")

            Spacer()

            HermesIconButton(systemName: "arrow.clockwise", help: "Nova sessão", action: onRestart)
            HermesIconButton(systemName: "minus", help: "Minimizar (Esc)", action: onClose)
        }
        .padding(.horizontal, 6)
    }
}

/// Handle visível no canto inferior-direito para redimensionar o painel.
/// Consome cliques para não disparar o drag-to-move do window background.
final class HermesResizeHandle: NSView {
    private var initialMouse: NSPoint = .zero
    private var initialFrame: NSRect = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        initialMouse = NSEvent.mouseLocation
        initialFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - initialMouse.x
        let dy = initialMouse.y - now.y
        let minSize = window.minSize
        let newWidth = max(minSize.width, initialFrame.width + dx)
        let newHeight = max(minSize.height, initialFrame.height + dy)
        // Mantém o topo fixo (painel ancorado no top-right); cresce pra baixo e pra direita.
        var newFrame = initialFrame
        newFrame.size.width = newWidth
        newFrame.origin.y = initialFrame.maxY - newHeight
        newFrame.size.height = newHeight
        window.setFrame(newFrame, display: true)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let color = NSColor.white.withAlphaComponent(0.22)
        color.setStroke()
        path.lineWidth = 1
        // Três linhas diagonais pequenas.
        for offset in stride(from: CGFloat(4), to: bounds.width, by: 4) {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: bounds.minY + 2))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + offset))
        }
        path.stroke()
    }
}

private struct HermesIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(hovering ? 0.18 : 0.10))
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
