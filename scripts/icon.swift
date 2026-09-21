import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift icon.swift output.icns") }
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 76, y: 76, width: 872, height: 872), xRadius: 196, yRadius: 196).fill()
for (x, y) in [(CGFloat(326), CGFloat(420)), (CGFloat(512), CGFloat(636)), (CGFloat(698), CGFloat(488))] {
    NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 13, y: 286, width: 26, height: 452), xRadius: 13, yRadius: 13).fill()
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: x - 51, y: y - 32, width: 102, height: 64), xRadius: 22, yRadius: 22).fill()
}
image.unlockFocus()
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Still-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: rep) else {
            fatalError("Couldn't allocate icon image")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("Couldn't encode icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", folder.path, "-o", CommandLine.arguments[1]]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
