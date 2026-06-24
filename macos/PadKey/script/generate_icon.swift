import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets", isDirectory: true)
let sourceSVG = assets.appendingPathComponent("PadKeyAppIcon.svg")
let iconset = assets.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icns = assets.appendingPathComponent("AppIcon.icns")

guard let logo = NSImage(contentsOf: sourceSVG) else {
    fatalError("Could not load \(sourceSVG.path)")
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct IconSpec {
    let pointSize: Int
    let scale: Int

    var pixelSize: Int {
        pointSize * scale
    }

    var fileName: String {
        scale == 1
            ? "icon_\(pointSize)x\(pointSize).png"
            : "icon_\(pointSize)x\(pointSize)@\(scale)x.png"
    }
}

let specs = [
    IconSpec(pointSize: 16, scale: 1),
    IconSpec(pointSize: 16, scale: 2),
    IconSpec(pointSize: 32, scale: 1),
    IconSpec(pointSize: 32, scale: 2),
    IconSpec(pointSize: 128, scale: 1),
    IconSpec(pointSize: 128, scale: 2),
    IconSpec(pointSize: 256, scale: 1),
    IconSpec(pointSize: 256, scale: 2),
    IconSpec(pointSize: 512, scale: 1),
    IconSpec(pointSize: 512, scale: 2)
]

for spec in specs {
    let pixels = spec.pixelSize
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.imageInterpolation = .high

    let maxSide = CGFloat(pixels) * 0.84
    let scale = min(maxSide / logo.size.width, maxSide / logo.size.height)
    let drawSize = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
    let drawRect = NSRect(
        x: (CGFloat(pixels) - drawSize.width) / 2,
        y: (CGFloat(pixels) - drawSize.height) / 2,
        width: drawSize.width,
        height: drawSize.height
    )
    logo.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode \(spec.fileName)")
    }
    try png.write(to: iconset.appendingPathComponent(spec.fileName), options: [.atomic])
}

try? FileManager.default.removeItem(at: icns)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(process.terminationStatus)")
}
