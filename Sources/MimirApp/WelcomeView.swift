import AppKit
import Combine
import MimirCore
import SwiftUI

/// First-run setup: the permissions Mimir needs, the local models it downloads,
/// and the shortcut to use. Shown at launch until the user finishes it once;
/// reachable again from Settings → Permissions.
struct WelcomeView: View {
    @Bindable var store: SettingsStore
    @Bindable var model: MimirAppModel
    @Bindable var downloadMonitor: ModelDownloadMonitor
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var snapshot = PermissionSnapshot.current()
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static let completedKey = "com.mimir.onboarding.completed.v1"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    private var modelKinds: [LocalModelKind] {
        (store.settings.postProcessingProvider == .mlx || store.settings.promptPostProcessingProvider == .mlx)
            ? [.speech, .polish] : [.speech]
    }

    private var modelsReady: Bool {
        modelKinds.allSatisfy { downloadMonitor.status(of: $0) == .ready }
    }

    private var allGranted: Bool {
        snapshot.microphone == .granted
            && snapshot.accessibility == .granted
            && snapshot.inputMonitoring == .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up Mimir")
                    .font(.system(size: 30, weight: .medium, design: .serif))
                    .foregroundStyle(MimirIdentity.ink)
                Text("Allow three things and let the models download. Audio is transcribed on this Mac and never leaves it.")
                    .font(.system(size: 14))
                    .foregroundStyle(MimirIdentity.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 24)

            VStack(spacing: 0) {
                WelcomePermissionRow(
                    title: "Microphone",
                    detail: "To hear you while you hold the shortcut.",
                    state: snapshot.microphone,
                    action: requestMicrophone
                )
                WelcomePermissionRow(
                    title: "Accessibility",
                    detail: "To paste the text where your cursor is.",
                    state: snapshot.accessibility,
                    action: requestAccessibility
                )
                WelcomePermissionRow(
                    title: "Input monitoring",
                    detail: "To notice the shortcut while you're in other apps.",
                    state: snapshot.inputMonitoring,
                    action: requestInputMonitoring
                )
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MimirIdentity.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.line(0.07), lineWidth: 1)
            )

            VStack(spacing: 0) {
                ForEach(modelKinds, id: \.self) { kind in
                    WelcomeModelRow(kind: kind, status: downloadMonitor.status(of: kind)) {
                        Task { await model.prepareAllModels() }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MimirIdentity.paper))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.line(0.07), lineWidth: 1)
            )
            .padding(.top, 12)

            HStack(spacing: 10) {
                Text("Then press")
                KeycapRow(caps: store.settings.activationTrigger.keyCaps)
                Text("in any app and start talking.")
            }
            .font(.system(size: 14))
            .foregroundStyle(MimirIdentity.ink)
            .padding(.top, 24)

            Spacer(minLength: 24)

            HStack {
                if !modelsReady {
                    Text("Downloads keep going if you close this window.")
                        .font(.system(size: 12))
                        .foregroundStyle(MimirIdentity.secondaryInk)
                } else if !allGranted {
                    Text("You can finish this later in Settings → Permissions.")
                        .font(.system(size: 12))
                        .foregroundStyle(MimirIdentity.secondaryInk)
                }
                Spacer()
                Button(action: finish) {
                    Text(allGranted && modelsReady ? "Start using Mimir" : "Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(Capsule().fill(MimirIdentity.brandBlue))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(36)
        .frame(width: 560, height: 680)
        .background(MimirIdentity.canvas)
        .onReceive(refresh) { _ in
            snapshot = PermissionSnapshot.current()
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            // Closing the window counts as done; it stays one click away in
            // Settings → Permissions.
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
        .task {
            // Fetch everything now, while permissions are being granted, so the
            // first dictation doesn't wait on a download.
            await model.prepareAllModels()
        }
    }

    private func requestMicrophone() {
        if snapshot.microphone == .missing {
            Self.openPrivacyPane("Privacy_Microphone")
            return
        }
        Task {
            try? await PermissionCoordinator.ensureMicrophoneAccess()
            snapshot = PermissionSnapshot.current()
        }
    }

    private func requestAccessibility() {
        // The system prompt only appears once; after that, send people to the pane.
        _ = try? PermissionCoordinator.ensureAccessibilityAccess(prompt: true)
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    private func requestInputMonitoring() {
        if !PermissionCoordinator.ensureInputMonitoring() {
            Self.openPrivacyPane("Privacy_ListenEvent")
        }
        snapshot = PermissionSnapshot.current()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        dismissWindow(id: "welcome")
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct WelcomePermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MimirIdentity.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MimirIdentity.secondaryInk)
            }
            Spacer()
            if state == .granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Text("Allowed")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(MimirTheme.green)
            } else {
                Button("Allow", action: action)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .pointerStyle(.link)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line(0.06)).frame(height: 1)
        }
    }
}

private struct WelcomeModelRow: View {
    let kind: LocalModelKind
    let status: ModelDownloadMonitor.Status
    let retry: () -> Void

    private var title: String {
        switch kind {
        case .speech: return "Speech model"
        case .polish: return "Writing model"
        }
    }

    private var detail: String {
        switch kind {
        case .speech: return "Turns your voice into text, on this Mac."
        case .polish: return "Cleans up punctuation and filler words, on this Mac."
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MimirIdentity.ink)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(MimirIdentity.secondaryInk)
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.line(0.06)).frame(height: 1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch status {
        case .idle:
            Text("Waiting…")
                .font(.system(size: 13))
                .foregroundStyle(MimirIdentity.secondaryInk)
        case .preparing:
            HStack(spacing: 10) {
                ModelProgressBar(fraction: nil)
                    .frame(width: 120, height: 6)
                Text("Preparing…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MimirIdentity.secondaryInk)
                    .frame(width: 62, alignment: .trailing)
            }
            .help("Getting the model ready for this Mac. The first time can take a few minutes.")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preparing the model")
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ModelProgressBar(fraction: fraction)
                    .frame(width: 120, height: 6)
                Text(fraction.map { "\(Int($0 * 100))%" } ?? "Starting…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MimirIdentity.secondaryInk)
                    .frame(width: 62, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Downloading")
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "starting")
        case .ready:
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text("Ready")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(MimirTheme.green)
        case .failed:
            HStack(spacing: 10) {
                Text("Download failed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MimirTheme.red)
                Button("Retry", action: retry)
                    .buttonStyle(SecondaryCapsuleButtonStyle())
                    .pointerStyle(.link)
            }
        }
    }
}

/// Thin cobalt bar; slides while the size is unknown.
struct ModelProgressBar: View {
    let fraction: Double?
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MimirTheme.softFillStrong)
                if let fraction {
                    Capsule()
                        .fill(MimirIdentity.brandBlue)
                        .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    Capsule()
                        .fill(MimirIdentity.brandBlue)
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: geo.size.width * phase)
                        .onAppear {
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                                phase = 1.0
                            }
                        }
                }
            }
            .clipShape(Capsule())
        }
    }
}
