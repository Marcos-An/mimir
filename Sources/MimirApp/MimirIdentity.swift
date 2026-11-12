import SwiftUI

// Approved light identity, scoped to the journal and recording island.
// Settings and diagnostics retain their existing appearance.
enum MimirIdentity {
    static let titlebar = Color(red: 238 / 255, green: 236 / 255, blue: 231 / 255)
    static let wordmark = Color(red: 36 / 255, green: 36 / 255, blue: 36 / 255)
    static let surface = Color(red: 248 / 255, green: 246 / 255, blue: 241 / 255)
    static let surfaceRaised = Color(red: 253 / 255, green: 252 / 255, blue: 249 / 255)
    static let ink = Color(red: 21 / 255, green: 36 / 255, blue: 73 / 255)
    static let secondaryInk = Color(red: 76 / 255, green: 87 / 255, blue: 111 / 255)
    static let brandBlue = Color(red: 23 / 255, green: 72 / 255, blue: 1)
    static let hairline = ink.opacity(0.16)
    // Neutral journal background; the cream `surface` stays on the recording island.
    static let canvas = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    static let card = Color(red: 251 / 255, green: 251 / 255, blue: 252 / 255)
    static let glow = Color(red: 220 / 255, green: 227 / 255, blue: 1)
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
