import SwiftUI
import MimirCore

/// Paleta do popover/menu bar panel: usa cores semânticas do sistema para
/// acompanhar light/dark do macOS sem afetar o tema principal do app.
private enum PanelPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let ink = Color.primary
    static let secondaryInk = Color.secondary
    static let softFill = Color.primary.opacity(0.08)
    static let green = Color.green
    static let orange = Color.orange
    static let blue = Color.blue
    static let red = Color.red
}

struct MenuBarIconView: View {
    let phase: AppPhase
    let downloadActive: Bool

    var body: some View {
        Image(systemName: iconName)
            .foregroundStyle(tint)
    }

    private var iconName: String {
        if downloadActive { return "arrow.down.circle" }
        switch phase {
        case .recording: return "mic.fill"
        case .transcribing, .postProcessing, .inserting: return "ellipsis.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        default: return "waveform"
        }
    }

    private var tint: Color {
        if downloadActive { return .primary }
        switch phase {
        case .recording: return .red
        case .error: return .orange
        default: return .primary
        }
    }
}

struct MenuBarPanelView: View {
    @Bindable var store: SettingsStore
    @Bindable var model: MimirAppModel
    @Bindable var levelMonitor: AudioLevelMonitor
    @Bindable var downloadMonitor: ModelDownloadMonitor

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            if downloadMonitor.isActive {
                DownloadPanelSection(monitor: downloadMonitor)
                Divider().opacity(0.5)
            }

            PanelHeader(
                phase: model.phase,
                shortcutLabel: store.settings.activationTrigger.label,
                activationMode: store.settings.activationMode
            )

            Divider().opacity(0.5)

            LatestSection(history: model.history, phase: model.phase)

            Divider().opacity(0.5)

            PanelFooter(openDashboard: {
                NotificationCenter.default.post(name: .mimirCloseMenuBar, object: nil)
                openWindow(id: "dashboard")
                DispatchQueue.main.async {
                    MimirAppDelegate.presentDashboard()
                }
            })
        }
        .frame(width: 360)
        .background(PanelPalette.background)
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let phase: AppPhase
    let shortcutLabel: String
    let activationMode: ActivationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                StatusDot(phase: phase)
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PanelPalette.ink)
                Spacer()
                Text("Mimir")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .kerning(0.6)
            }

            HStack(spacing: 6) {
                Text(leadingVerb)
                    .font(.system(size: 12))
                    .foregroundStyle(PanelPalette.secondaryInk)
                Text(shortcutLabel)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(PanelPalette.softFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(PanelPalette.ink.opacity(0.1), lineWidth: 1)
                    )
                    .foregroundStyle(PanelPalette.ink)
                Text(trailingHint)
                    .font(.system(size: 12))
                    .foregroundStyle(PanelPalette.secondaryInk)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusText: String {
        switch phase {
        case .idle: return "Ready"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .postProcessing: return "Thinking"
        case .inserting: return "Inserting"
        case .error(let message): return "Error — \(message)"
        }
    }

    private var leadingVerb: String {
        switch activationMode {
        case .holdToTalk: return "Hold"
        case .tapToToggle: return "Tap"
        }
    }

    private var trailingHint: String {
        switch activationMode {
        case .holdToTalk: return "and speak."
        case .tapToToggle: return "to start/stop."
        }
    }
}

private struct StatusDot: View {
    let phase: AppPhase

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(shouldPulse ? (pulse ? 1.15 : 0.85) : 1)
            .animation(shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse)
            .onAppear { pulse = true }
    }

    private var shouldPulse: Bool {
        switch phase {
        case .recording, .transcribing, .postProcessing, .inserting: return true
        default: return false
        }
    }

    private var color: Color {
        switch phase {
        case .idle: return PanelPalette.green
        case .recording: return PanelPalette.orange
        case .transcribing, .postProcessing, .inserting: return PanelPalette.blue
        case .error: return PanelPalette.red
        }
    }
}

// MARK: - Latest

private struct LatestSection: View {
    @Bindable var history: TranscriptHistoryStore
    let phase: AppPhase

    private var latest: TranscriptEntry? { history.entries.first }
    private var recent: [TranscriptEntry] { Array(history.entries.dropFirst().prefix(3)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Latest text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .kerning(0.4)
                Spacer()
                if let latest {
                    Button {
                        copy(latest.text)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Copy")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(PanelPalette.ink.opacity(0.8))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let latest {
                Text(latest.text)
                    .font(.system(size: 13))
                    .foregroundStyle(PanelPalette.ink)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(phase != .idle ? "Processing…" : "Say something to get started.")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !recent.isEmpty {
                Divider().opacity(0.5).padding(.vertical, 2)
                Text("Earlier")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .kerning(0.4)
                VStack(spacing: 6) {
                    ForEach(recent) { entry in
                        RecentItem(entry: entry)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct RecentItem: View {
    let entry: TranscriptEntry

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation { copied = false }
            }
        } label: {
            HStack(spacing: 10) {
                Text(humanizedDate(entry.createdAt))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .frame(width: 70, alignment: .leading)
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(PanelPalette.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .opacity(hovering || copied ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? PanelPalette.softFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

// MARK: - Footer

private struct PanelFooter: View {
    let openDashboard: () -> Void

    @State private var moreHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: openDashboard) {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Open Mimir")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(PanelPalette.ink)
            }
            .buttonStyle(PanelIconButton())

            Spacer()

            Menu {
                Button("About Mimir") {
                    // Could open about window
                }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PanelPalette.secondaryInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct PanelIconButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(configuration.isPressed ? PanelPalette.softFill : Color.clear)
            )
            .contentShape(Rectangle())
    }
}

// MARK: - Download

private struct DownloadPanelSection: View {
    @Bindable var monitor: ModelDownloadMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PanelPalette.blue)
                Text("Preparing model")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PanelPalette.ink)
                Spacer()
                if !monitor.isIndeterminate {
                    Text("\(Int(monitor.fractionCompleted * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PanelPalette.secondaryInk)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelPalette.softFill)
                    if monitor.isIndeterminate {
                        IndeterminateBar(color: PanelPalette.blue)
                    } else {
                        Capsule()
                            .fill(PanelPalette.blue)
                            .frame(width: max(4, geo.size.width * CGFloat(monitor.fractionCompleted)))
                            .animation(.easeOut(duration: 0.25), value: monitor.fractionCompleted)
                    }
                }
            }
            .frame(height: 4)

            Text("~1.5 GB · runs 100% local after this")
                .font(.system(size: 11))
                .foregroundStyle(PanelPalette.secondaryInk)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct IndeterminateBar: View {
    let color: Color
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(color)
                .frame(width: geo.size.width * 0.35)
                .offset(x: geo.size.width * phase)
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        phase = 1.0
                    }
                }
        }
        .clipShape(Capsule())
    }
}
