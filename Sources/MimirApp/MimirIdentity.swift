import AppKit
import SwiftUI

// The approved identity, with a dark counterpart for each color. The
// journal, Settings and welcome follow the Appearance setting.
enum MimirIdentity {
    static let titlebar = Color.adaptive(0xEEECE7, 0x1C1C1E)
    static let wordmark = Color.adaptive(0x242424, 0xECECEC)
    static let surface = Color.adaptive(0xF8F6F1, 0x1E1E20)
    static let surfaceRaised = Color.adaptive(0xFDFCF9, 0x2A2A2D)
    static let ink = Color.adaptive(0x152449, 0xE8ECF6)
    static let secondaryInk = Color.adaptive(0x4C576F, 0x9BA3B6)
    static let brandBlue = Color.adaptive(0x1748FF, 0x4F78FF)
    static let hairline = ink.opacity(0.16)
    // Neutral journal background; the cream `surface` stays on the recording island.
    static let canvas = Color.adaptive(0xF5F5F7, 0x161618)
    static let card = Color.adaptive(0xFBFBFC, 0x1F1F22)
    /// White cards, fields and the hovered card.
    static let paper = Color.adaptive(0xFFFFFF, 0x26262A)
    static let glow = Color.adaptive(0xDCE3FF, 0x1C2650)
}

extension Color {
    /// One color per appearance, resolved by AppKit when drawn.
    static func adaptive(_ light: UInt32, _ dark: UInt32, opacity: Double = 1) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: opacity
            )
        }
        let (l, d) = (ns(light), ns(dark))
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }

    /// Black lines on light, white lines on dark.
    static func line(_ opacity: Double) -> Color {
        adaptive(0x000000, 0xFFFFFF, opacity: opacity)
    }
}

/// Settings > General > Appearance. Applied app-wide through NSApp.appearance,
/// so the menu bar panel follows it too.
enum MimirAppearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    static var current: MimirAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(MimirAppearance.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The app's resource bundle. SwiftPM's generated `Bundle.module` only looks at
/// the .app root and at this machine's `.build` folder, and crashes otherwise;
/// a packaged app keeps the bundle in Contents/Resources (where codesign wants
/// it), so look there first.
enum MimirResources {
    static let bundle: Bundle = {
        let name = "Mimir_MimirApp.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url) { return bundle }
        }
        // `swift run` during development.
        return Bundle.module
    }()
}
