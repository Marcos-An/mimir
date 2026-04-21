import AppKit
import SwiftUI
import MimirCore

struct SetupOverlayView: View {
    @Bindable var monitor: ModelDownloadMonitor

    @State private var pulse = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.98, blue: 0.99),
                    Color(red: 0.93, green: 0.94, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [Color(red: 0.0, green: 0.753, blue: 0.910).opacity(0.35), Color(red: 0.380, green: 0.333, blue: 0.961).opacity(0.35)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 150, height: 150)
                        .blur(radius: 26)
                        .scaleEffect(pulse ? 1.06 : 0.94)
                        .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: pulse)

                    appIcon
                        .frame(width: 104, height: 104)
                        .shadow(color: Color(red: 0.35, green: 0.3, blue: 0.9).opacity(0.35), radius: 24, y: 10)
                }
                .onAppear { pulse = true }

                VStack(spacing: 12) {
                    Text("We're getting everything ready for you")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.09, blue: 0.15))
                        .multilineTextAlignment(.center)

                    Text("Mimir is downloading the brain that will polish your speech. This happens only once and everything stays instant afterwards — no internet needed, your audio never leaves the machine.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(red: 0.32, green: 0.34, blue: 0.42))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 480)
                }

                VStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.black.opacity(0.08))
                            if monitor.isIndeterminate {
                                SetupIndeterminateBar()
                            } else {
                                Capsule()
                                    .fill(LinearGradient(
                                        colors: [Color(red: 0.15, green: 0.35, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
                                        startPoint: .leading, endPoint: .trailing
                                    ))
                                    .frame(width: max(8, geo.size.width * CGFloat(monitor.fractionCompleted)))
                                    .animation(.easeOut(duration: 0.3), value: monitor.fractionCompleted)
                            }
                        }
                    }
                    .frame(width: 380, height: 8)

                    HStack {
                        Text(percentLabel)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.2, green: 0.22, blue: 0.3))
                        Spacer()
                        Text("≈ 1.5 GB · one time only")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(red: 0.45, green: 0.47, blue: 0.55))
                    }
                    .frame(width: 380)
                }

                Text("Feel free to leave it running — I'll let you know when it's ready.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.45, green: 0.47, blue: 0.55))
                    .padding(.top, 6)
            }
            .padding(40)
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.0, green: 0.753, blue: 0.910), Color(red: 0.380, green: 0.333, blue: 0.961)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 42, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    private var percentLabel: String {
        if monitor.isIndeterminate { return "Downloading…" }
        let pct = Int(monitor.fractionCompleted * 100)
        return pct <= 0 ? "Connecting…" : "\(pct)%"
    }
}

private struct SetupIndeterminateBar: View {
    @State private var phase: CGFloat = -0.35

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(
                    colors: [Color(red: 0.15, green: 0.35, blue: 0.95), Color(red: 0.55, green: 0.25, blue: 0.85)],
                    startPoint: .leading, endPoint: .trailing
                ))
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
