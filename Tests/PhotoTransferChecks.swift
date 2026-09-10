import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
struct PhotoTransferChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPhotoChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("provider-without-extension")
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: source)
        let photo = try PhotoTransfer.stage(source)
        try FileManager.default.removeItem(at: source)
        precondition(photo.url.pathExtension == "png")
        let copied = try Data(contentsOf: photo.url)
        precondition(copied == bytes)
        photo.cleanup()
        precondition(!FileManager.default.fileExists(atPath: photo.directory.path))
        let bad = root.appendingPathComponent("invalid.jpg")
        try Data("not an image".utf8).write(to: bad)
        do { _ = try PhotoTransfer.stage(bad); fatalError("Invalid image accepted") }
        catch CollectionError.invalid { }
        let large = root.appendingPathComponent("too-large.jpg")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let writer = try FileHandle(forWritingTo: large)
        try writer.truncate(atOffset: UInt64(AttachmentStore.maximumBytes + 1))
        try writer.close()
        do { _ = try PhotoTransfer.stage(large); fatalError("Oversized image accepted") }
        catch CollectionError.invalid { }
        print("PASS: disk-backed photo copy survives provider removal, actual format extension, explicit cleanup, invalid and oversized file rejection")
    }
}
