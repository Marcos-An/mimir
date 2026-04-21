import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let assetsURL = root.appendingPathComponent("Assets", isDirectory: true)
let iconsetURL = assetsURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = assetsURL.appendingPathComponent("Mimir.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try? FileManager.default.removeItem(at: icnsURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func stroke(_ path: NSBezierPath, color: NSColor, width: CGFloat, shadowColor: NSColor? = nil, shadowBlur: CGFloat = 0, shadowOffset: NSSize = .zero) {
    NSGraphicsContext.current?.saveGraphicsState()
    if let shadowColor {
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = shadowOffset
        shadow.set()
    }
    path.lineWidth = width
    color.setStroke()
    path.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func fill(_ path: NSBezierPath, color: NSColor, shadowColor: NSColor? = nil, shadowBlur: CGFloat = 0, shadowOffset: NSSize = .zero) {
    NSGraphicsContext.current?.saveGraphicsState()
    if let shadowColor {
        let shadow = NSShadow()
        shadow.shadowColor = shadowColor
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = shadowOffset
        shadow.set()
    }
    color.setFill()
    path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
}

func image(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let bgRect = rect.insetBy(dx: size * 0.04, dy: size * 0.04)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: size * 0.23, yRadius: size * 0.23)
    let background = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.09, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.07, green: 0.11, blue: 0.18, alpha: 1), 0.45),
        (NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.24, alpha: 1), 1.0)
    )!
    background.draw(in: bgPath, angle: -55)

    let topGlow = NSBezierPath(ovalIn: NSRect(x: size * 0.18, y: size * 0.58, width: size * 0.64, height: size * 0.30))
    fill(topGlow, color: NSColor(calibratedRed: 0.32, green: 0.60, blue: 0.80, alpha: 0.10))

    let basinGlow = NSBezierPath(ovalIn: NSRect(x: size * 0.20, y: size * 0.12, width: size * 0.60, height: size * 0.42))
    fill(basinGlow, color: NSColor(calibratedRed: 0.15, green: 0.78, blue: 0.86, alpha: 0.12))

    let eyeHalo = NSBezierPath(ovalIn: NSRect(x: size * 0.23, y: size * 0.30, width: size * 0.54, height: size * 0.36))
    stroke(eyeHalo, color: NSColor(calibratedRed: 0.28, green: 0.93, blue: 0.93, alpha: 0.16), width: size * 0.018)

    let brow = NSBezierPath()
    brow.lineCapStyle = .round
    brow.lineJoinStyle = .round
    brow.move(to: NSPoint(x: size * 0.24, y: size * 0.53))
    brow.curve(to: NSPoint(x: size * 0.40, y: size * 0.63), controlPoint1: NSPoint(x: size * 0.28, y: size * 0.58), controlPoint2: NSPoint(x: size * 0.34, y: size * 0.65))
    brow.curve(to: NSPoint(x: size * 0.50, y: size * 0.56), controlPoint1: NSPoint(x: size * 0.44, y: size * 0.61), controlPoint2: NSPoint(x: size * 0.47, y: size * 0.58))
    brow.curve(to: NSPoint(x: size * 0.60, y: size * 0.63), controlPoint1: NSPoint(x: size * 0.53, y: size * 0.58), controlPoint2: NSPoint(x: size * 0.56, y: size * 0.61))
    brow.curve(to: NSPoint(x: size * 0.76, y: size * 0.53), controlPoint1: NSPoint(x: size * 0.66, y: size * 0.65), controlPoint2: NSPoint(x: size * 0.72, y: size * 0.58))
    stroke(brow, color: NSColor(calibratedRed: 0.82, green: 0.98, blue: 0.96, alpha: 0.96), width: size * 0.055, shadowColor: NSColor(calibratedRed: 0.27, green: 0.93, blue: 0.96, alpha: 0.35), shadowBlur: size * 0.04)

    let lowerLid = NSBezierPath()
    lowerLid.lineCapStyle = .round
    lowerLid.move(to: NSPoint(x: size * 0.28, y: size * 0.39))
    lowerLid.curve(to: NSPoint(x: size * 0.72, y: size * 0.39), controlPoint1: NSPoint(x: size * 0.40, y: size * 0.29), controlPoint2: NSPoint(x: size * 0.60, y: size * 0.29))
    stroke(lowerLid, color: NSColor(calibratedRed: 0.57, green: 0.92, blue: 0.98, alpha: 0.88), width: size * 0.035, shadowColor: NSColor(calibratedRed: 0.21, green: 0.78, blue: 0.95, alpha: 0.25), shadowBlur: size * 0.025)

    let irisRect = NSRect(x: size * 0.42, y: size * 0.37, width: size * 0.16, height: size * 0.16)
    let iris = NSBezierPath(ovalIn: irisRect)
    let irisGradient = NSGradient(colorsAndLocations:
        (NSColor(calibratedRed: 0.88, green: 1.0, blue: 0.99, alpha: 1), 0.0),
        (NSColor(calibratedRed: 0.44, green: 0.94, blue: 0.96, alpha: 1), 0.55),
        (NSColor(calibratedRed: 0.17, green: 0.56, blue: 0.73, alpha: 1), 1.0)
    )!
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedRed: 0.31, green: 0.97, blue: 0.95, alpha: 0.45)
    shadow.shadowBlurRadius = size * 0.04
    shadow.set()
    irisGradient.draw(in: iris, relativeCenterPosition: .zero)
    NSGraphicsContext.current?.restoreGraphicsState()

    let pupil = NSBezierPath(ovalIn: NSRect(x: size * 0.468, y: size * 0.418, width: size * 0.064, height: size * 0.064))
    fill(pupil, color: NSColor(calibratedRed: 0.03, green: 0.07, blue: 0.11, alpha: 0.95))

    let highlight = NSBezierPath(ovalIn: NSRect(x: size * 0.50, y: size * 0.47, width: size * 0.02, height: size * 0.02))
    fill(highlight, color: NSColor(calibratedWhite: 1.0, alpha: 0.95))

    let well = NSBezierPath()
    well.lineCapStyle = .round
    well.move(to: NSPoint(x: size * 0.29, y: size * 0.25))
    well.curve(to: NSPoint(x: size * 0.71, y: size * 0.25), controlPoint1: NSPoint(x: size * 0.39, y: size * 0.19), controlPoint2: NSPoint(x: size * 0.61, y: size * 0.19))
    stroke(well, color: NSColor(calibratedRed: 0.40, green: 0.97, blue: 0.93, alpha: 0.92), width: size * 0.045, shadowColor: NSColor(calibratedRed: 0.28, green: 0.92, blue: 0.88, alpha: 0.40), shadowBlur: size * 0.03)

    let waveform = NSBezierPath()
    waveform.lineCapStyle = .round
    waveform.lineJoinStyle = .round
    waveform.move(to: NSPoint(x: size * 0.39, y: size * 0.18))
    waveform.line(to: NSPoint(x: size * 0.44, y: size * 0.18))
    waveform.line(to: NSPoint(x: size * 0.465, y: size * 0.215))
    waveform.line(to: NSPoint(x: size * 0.50, y: size * 0.15))
    waveform.line(to: NSPoint(x: size * 0.535, y: size * 0.215))
    waveform.line(to: NSPoint(x: size * 0.56, y: size * 0.18))
    waveform.line(to: NSPoint(x: size * 0.61, y: size * 0.18))
    stroke(waveform, color: NSColor(calibratedRed: 0.82, green: 1.0, blue: 0.99, alpha: 0.76), width: size * 0.018)

    image.unlockFocus()
    return image
}

for (name, size) in specs {
    let destination = iconsetURL.appendingPathComponent(name)
    let image = image(size: size)
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MimirIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render \(name)"])
    }
    try png.write(to: destination)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 {
    throw NSError(domain: "MimirIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(icnsURL.path)
