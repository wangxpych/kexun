import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

/// Own a bounded, disk-backed copy before the provider's callback returns.
nonisolated struct PhotoTransfer: Transferable, Sendable {
    let url: URL
    let directory: URL

    static func load(seconds: TimeInterval = 30,
                     start: (@escaping @Sendable (Result<PhotoTransfer?, Error>) -> Void) -> Progress) async throws -> PhotoTransfer? {
        var progress: Progress?
        defer { progress?.cancel() }
        return try await BoundedCallback<PhotoTransfer?>.wait(seconds: seconds, discard: { $0?.cleanup() }) { completion in
            progress = start(completion)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let source = received.file
            return try await Task.detached(priority: .userInitiated) {
                try stage(source)
            }.value
        }
    }

    static func stage(_ source: URL) throws -> PhotoTransfer {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPhotoTransfer-\(UUID())")
        do {
            let staging = try AttachmentStore(root: directory)
            let reference = try staging.importFile(source, contentType: UTType.image.identifier)
            let copy = try staging.url(for: reference)
            guard let image = CGImageSourceCreateWithURL(copy as CFURL, nil),
                  let identifier = CGImageSourceGetType(image),
                  let type = UTType(identifier as String), type.conforms(to: .image) else {
                throw CollectionError.invalid(String(localized: "照片格式无法读取，未保存。"))
            }
            let output = directory.appendingPathComponent("照片.\(type.preferredFilenameExtension ?? "img")")
            try FileManager.default.moveItem(at: copy, to: output)
            return PhotoTransfer(url: output, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}
