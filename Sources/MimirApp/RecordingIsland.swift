import AppKit
import Observation
import SwiftUI
import MimirCore

@MainActor
final class RecordingIslandController {
    private var panel: NSPanel?
    private let model: MimirAppModel
    private let levelMonitor: AudioLevelMonitor
    private let downloadMonitor: ModelDownloadMonitor

    init(
        model: MimirAppModel,
        levelMonitor: AudioLevelMonitor,
        downloadMonitor: ModelDownloadMonitor
    ) {
        self.model = model
        self.levelMonitor = levelMonitor
        self.downloadMonitor = downloadMonitor
        observeState()
    }

    private func observeState() {
        withObservationTracking {
            _ = model.phase
            _ = model.isFlashingMetrics
            _ = model.partialPolishText
            _ = downloadMonitor.isActive
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncVisibility()
                self.observeState()
            }
        }
    }

    private func syncVisibility() {
        if downloadMonitor.isActive {
            hide()
            return
        }
        switch model.phase {
        case .recording, .transcribing, .postProcessing, .inserting:
            show()
        default:
            if model.isFlashingMetrics {
                show()
            } else {
                hide()
            }
        }
    }

    private static let baseSize = NSSize(width: 208, height: 44)
    private static let metricsSize = NSSize(width: 300, height: 44)
    private static let previewSize = NSSize(width: 420, height: 56)

    private var targetSize: NSSize {
        if model.phase == .idle && model.isFlashingMetrics {
            return Self.metricsSize
        }
        if model.phase == .postProcessing && (model.partialPolishText?.isEmpty == false) {
            return Self.previewSize
        }
        return Self.baseSize
    }

    func show() {
        if panel == nil {
            let hosting = NSHostingController(
                rootView: RecordingIslandView(
                    model: model,
                    levelMonitor: levelMonitor,
                    downloadMonitor: downloadMonitor
                )
            )
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.baseSize),
                styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel.contentViewController = hosting
            panel.setContentSize(Self.baseSize)
            self.panel = panel
        }
        if let panel {
            panel.setContentSize(targetSize)
            positionAtBottomCenter(panel)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct RecordingIslandView: View {
    @Bindable var model: MimirAppModel
    @Bindable var levelMonitor: AudioLevelMonitor
    var downloadMonitor: ModelDownloadMonitor

    private var isRecording: Bool { model.phase == .recording }
    private var isPromptRewriteMode: Bool { model.activeMode == .promptRewrite }
    private var isShowingMetrics: Bool {
        model.phase == .idle && model.isFlashingMetrics && model.lastSessionMetrics != nil
    }

    private var isShowingPolishPreview: Bool {
        model.phase == .postProcessing
            && (model.partialPolishText?.isEmpty == false)
    }

    private var promptRewriteAccent: Color {
        Color.blue
    }

    private var waveTint: Color {
        isPromptRewriteMode ? promptRewriteAccent : .white
    }

    private var borderColor: Color {
        isPromptRewriteMode ? promptRewriteAccent.opacity(0.55) : Color.white.opacity(0.08)
    }

    private var borderWidth: CGFloat {
        isPromptRewriteMode ? 1.4 : 1
    }

    private var statusLabel: String {
        let prefix = isPromptRewriteMode ? "Prompt · " : ""
        switch model.phase {
        case .recording: return prefix + "Recording"
        case .transcribing: return prefix + "Transcribing"
        case .postProcessing: return prefix + "Thinking"
        case .inserting: return prefix + "Inserting"
        default: return ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if isRecording {
                IslandButton(systemName: "xmark") {
                    Task { try? await model.cancelDictation() }
                }
            } else {
                Spacer().frame(width: 26, height: 26)
            }

            if isRecording {
                VStack(spacing: 3) {
                    if isPromptRewriteMode {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8, weight: .semibold))
                            Text("Prompt")
                                .font(.system(size: 9, weight: .semibold))
                                .tracking(0.3)
                        }
                        .foregroundStyle(promptRewriteAccent)
                    }
                    AudioWaveView(levels: levelMonitor.levels, tint: waveTint)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isPromptRewriteMode ? promptRewriteAccent.opacity(0.12) : Color.white.opacity(0.08))
                )
            } else if isShowingMetrics, let metrics = model.lastSessionMetrics {
                MetricsFlashView(metrics: metrics)
                    .frame(maxWidth: .infinity)
            } else if isShowingPolishPreview, let partial = model.partialPolishText {
                PolishPreviewView(text: partial)
                    .frame(maxWidth: .infinity)
            } else {
                ProcessingProgressView(phase: model.phase, label: statusLabel, accent: isPromptRewriteMode ? promptRewriteAccent : nil)
                    .frame(maxWidth: .infinity)
            }

            if isRecording {
                IslandButton(systemName: "checkmark", isPrimary: true, tint: isPromptRewriteMode ? promptRewriteAccent : nil) {
                    Task { try? await model.stopDictation() }
                }
            } else {
                Spacer().frame(width: 26, height: 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(
            width: isShowingPolishPreview ? 420 : (isShowingMetrics ? 300 : 208),
            height: isShowingPolishPreview ? 56 : 44
        )
        .background(
            Capsule(style: .continuous)
                .fill(MimirTheme.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 8)
        .animation(.easeInOut(duration: 0.2), value: isPromptRewriteMode)
    }
}

private struct IslandButton: View {
    let systemName: String
    var isPrimary: Bool = false
    var tint: Color? = nil
    let action: () -> Void

    @State private var hovering = false

    private var fillColor: Color {
        if isPrimary {
            return tint ?? Color.white
        }
        return Color.white.opacity(hovering ? 0.18 : 0.12)
    }

    private var iconColor: Color {
        if isPrimary {
            return tint != nil ? Color.white : MimirTheme.surface
        }
        return .white
    }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fillColor)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: systemName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(iconColor)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ProcessingProgressView: View {
    let phase: AppPhase
    let label: String
    var accent: Color? = nil

    @State private var phaseStart: Date = .now
    @State private var trackedPhase: AppPhase = .idle
    @State private var lastProgress: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.opacity)
                .id(label)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: label)

            TimelineView(.animation(minimumInterval: 0.05, paused: false)) { context in
                GeometryReader { geo in
                    let value = progress(at: context.date)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.15))
                        Capsule()
                            .fill(progressGradient)
                            .frame(width: max(3, geo.size.width * CGFloat(value)))
                            .animation(.easeOut(duration: 0.15), value: value)
                    }
                }
                .frame(height: 3)
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 4)
        .onAppear {
            trackedPhase = phase
            phaseStart = .now
            lastProgress = segmentBase(for: phase)
        }
        .onChange(of: phase) { _, newPhase in
            trackedPhase = newPhase
            phaseStart = .now
            // Ao trocar de fase, a barra nunca volta: começa do maior entre onde estava e o início do novo segmento.
            lastProgress = max(lastProgress, segmentBase(for: newPhase))
        }
    }

    // Uma barra única que cobre as três etapas em sequência:
    //   transcribing:    0% → 45%
    //   postProcessing:  45% → 92%
    //   inserting:       92% → 100%
    private func progress(at date: Date) -> Double {
        let (base, span, tau) = segment(for: trackedPhase)
        let elapsed = date.timeIntervalSince(phaseStart)
        guard tau > 0 else { return min(base + span, 0.99) }
        let withinSegment = span * (1 - exp(-elapsed / tau))
        let raw = base + withinSegment
        // Nunca anda pra trás; trava em 0.99 enquanto a fase final não terminar.
        let clamped = min(max(raw, lastProgress), 0.99)
        return clamped
    }

    private func segment(for phase: AppPhase) -> (base: Double, span: Double, tau: Double) {
        switch phase {
        case .transcribing: return (0.0, 0.45, 2.5)
        case .postProcessing: return (0.45, 0.47, 3.5)
        case .inserting: return (0.92, 0.08, 0.3)
        default: return (0.0, 1.0, 1.0)
        }
    }

    private func segmentBase(for phase: AppPhase) -> Double {
        segment(for: phase).base
    }

    private var progressGradient: LinearGradient {
        if let accent {
            return LinearGradient(
                colors: [accent.opacity(0.65), accent],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        return LinearGradient(
            colors: [Color(red: 0.0, green: 0.753, blue: 0.910), Color(red: 0.380, green: 0.333, blue: 0.961)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

private struct ProcessingIndicator: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                Color.white.opacity(0.85),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round)
            )
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

private struct DownloadProgressView: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                    .animation(.easeOut(duration: 0.2), value: fraction)
            }
        }
        .frame(height: 6)
    }
}

private struct AudioWaveView: View {
    let levels: [Float]
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(tint)
                    .frame(width: 2.5, height: barHeight(for: level))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(maxHeight: 16)
    }

    private func barHeight(for level: Float) -> CGFloat {
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 14
        return minHeight + CGFloat(level) * (maxHeight - minHeight)
    }
}

private struct PolishPreviewView: View {
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.66, blue: 1.0))
            Text(text)
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .transition(.opacity)
    }
}

private struct MetricsFlashView: View {
    let metrics: SessionMetrics

    var body: some View {
        HStack(spacing: 10) {
            if let audio = metrics.audioSeconds {
                metricItem(icon: "🎤", value: formatSeconds(audio))
            }
            metricItem(icon: "📝", value: formatSeconds(metrics.transcriptionSeconds))
            if let post = metrics.postProcessingSeconds {
                metricItem(icon: "✨", value: formatSeconds(post))
            }
            Text(metrics.streamingUsed ? "🔗" : "⚠︎")
                .font(.system(size: 11))
                .foregroundStyle(
                    metrics.streamingUsed ? Color.green.opacity(0.85) : Color.yellow.opacity(0.85)
                )
                .help(metrics.streamingUsed ? "Streaming active" : "Fallback: transcribed the whole file on stop")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .transition(.opacity)
    }

    @ViewBuilder
    private func metricItem(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(icon).font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        DurationFormat.short(seconds)
    }
}

enum DurationFormat {
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 60 {
            let minutes = total / 60
            let secs = total % 60
            return secs == 0 ? "\(minutes)m" : "\(minutes)m\(secs)s"
        }
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(total)s"
    }
}

private extension Color {
    init(hex: UInt64, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
