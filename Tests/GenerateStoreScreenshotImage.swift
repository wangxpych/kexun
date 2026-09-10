// Run with macOS Swift. Creates original sample content, not an app mockup.
// Usage: swift GenerateStoreScreenshotImage.swift <new-output.png>
import AppKit

guard CommandLine.arguments.count == 2 else { fatalError("Expected new PNG output path") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
guard destination.pathExtension == "png", !FileManager.default.fileExists(atPath: destination.path) else {
    fatalError("Refusing to overwrite an existing file")
}
let width = 1200
let height = 900
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.97, green: 0.96, blue: 0.91, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
let ink = NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.26, alpha: 1)
func label(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) {
    (value as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: ink])
}
label("WEEKEND NOTES", x: 85, y: 768, size: 26, weight: .medium)
label("沿着河岸，慢慢走。", x: 85, y: 625, size: 76, weight: .semibold)
ink.setFill()
NSBezierPath(rect: NSRect(x: 85, y: 560, width: 1030, height: 3)).fill()
label("01  带上相机和一瓶水", x: 85, y: 435, size: 48)
label("02  走一段安静的步道", x: 85, y: 325, size: 48)
label("03  留一点时间等日落", x: 85, y: 215, size: 48)
label("给周末留白，也把灵感留下。", x: 85, y: 78, size: 32)
NSGraphicsContext.restoreGraphicsState()
guard let bytes = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try bytes.write(to: destination, options: .withoutOverwriting)
print(destination.path, bytes.count)
