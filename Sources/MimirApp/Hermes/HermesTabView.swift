import AppKit
import SwiftUI

/// View do tab lateral. Pill escuro com ícone, clicável para expandir a ilha.
struct HermesTabView: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.08, blue: 0.10).opacity(0.96))
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
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
            }
            .frame(width: HermesTabPanel.width, height: HermesTabPanel.height)
        }
        .buttonStyle(.plain)
    }
}
