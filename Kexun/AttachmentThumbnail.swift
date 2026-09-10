import SwiftUI
import ImageIO

/// Immutable managed attachments use stable paths. Decode misses serially off the main actor.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for url: URL, maximumPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let limit = max(1, min(maximumPixelSize, 2048))
        let key = "\(url.absoluteString)|\(limit)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

struct AttachmentThumbnail: View {
    let url: URL
    var maximumPixelSize = 600
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary) }
        }.task(id: "\(url.absoluteString)|\(maximumPixelSize)") {
            image = nil
            let result = await ThumbnailLoader.shared.image(for: url, maximumPixelSize: maximumPixelSize)
            guard !Task.isCancelled else { return }
            image = result.map(UIImage.init(cgImage:))
        }
    }
}
