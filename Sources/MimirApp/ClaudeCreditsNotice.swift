import AppKit
import MimirCore
import Observation
import SwiftUI

/// Mirrors `AnthropicAccountStatus` on the main actor so views can show that
/// the Claude account ran out of credits. Cleared by the next call that works.
@MainActor
@Observable
final class ClaudeCreditsState {
    static let shared = ClaudeCreditsState()

    private(set) var isOutOfCredits = AnthropicAccountStatus.shared.isOutOfCredits

    @ObservationIgnored private var token: NSObjectProtocol?

    private init() {
        token = NotificationCenter.default.addObserver(
            forName: AnthropicAccountStatus.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isOutOfCredits = AnthropicAccountStatus.shared.isOutOfCredits
            }
        }
    }

    static let billingURL = URL(string: "https://console.anthropic.com/settings/billing")!

    static let message = "Your Anthropic account is out of credits. Dictations are pasted without cleanup and the writing check is paused until you add credits."
}

/// Red notice with a link to the billing page.
struct ClaudeCreditsNotice: View {
    var ink: Color
    var secondaryInk: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "creditcard.trianglebadge.exclamationmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude credits ran out")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ink)
                Text(ClaudeCreditsState.message)
                    .font(.system(size: 11))
                    .foregroundStyle(secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add credits") { NSWorkspace.shared.open(ClaudeCreditsState.billingURL) }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .medium))
                    .pointerStyle(.link)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.red.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}
