#if DEBUG
import SwiftUI
import UIKit

/// Explicit, disposable performance/interaction data. Collection storage is
/// separate from the App Group; seeding never grants a purchase entitlement.
struct LibraryScaleFixtureView: View {
    @State private var store: CollectionStore?
    @State private var error: String?

    var body: some View {
        Group {
            if let store { LibraryView(store: store) }
            else if let error { Text(error) }
            else { ProgressView("正在准备独立验收资料…") }
        }.task {
            guard store == nil, error == nil else { return }
            do {
                let root = try Self.seed()
                store = CollectionStore(openRoot: { root })
            } catch { self.error = error.localizedDescription }
        }
    }

    @MainActor private static func seed() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunScaleFixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: root)
        var records: [CollectionRecord] = []
        let source = root.appendingPathComponent("fixture-source")
        defer { try? FileManager.default.removeItem(at: source) }
        for index in 0..<1000 {
            let kind = ContentKind.allCases[index % 4]
            var record = CollectionRecord(kind: kind, title: String(format: "SCALE-%04d", index),
                                          body: String(repeating: "Mixed library fixture. 测试资料可找回。", count: 12))
            record.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
            record.createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
            record.updatedAt = record.createdAt
            record.source = "独立验收资料"
            record.starred = index.isMultiple(of: 3)
            if index.isMultiple(of: 5) { record.archivedAt = record.createdAt }
            if kind == .link { record.originalURL = "https://example.com/scale/\(index)" }
            if kind == .image {
                let bytes = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).pngData { context in
                    UIColor(hue: CGFloat(index) / 1000, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                    UIColor.white.setFill()
                    context.fill(CGRect(x: 40 + index % 300, y: 50, width: 120, height: 320))
                }
                try bytes.write(to: source)
                record.attachments = [try assets.importFile(source, contentType: "public.png")]
                record.extractedText = "Seeded metadata for rendering and search only"
            } else if kind == .file {
                try Data(repeating: UInt8(index % 255), count: 4096).write(to: source)
                record.attachments = [try assets.importFile(source, contentType: "public.data")]
                record.processingState = .unsupported
            }
            records.append(record)
        }
        // Same unlimited data-restore route as a legitimate over-quota backup;
        // no Pro flag, shared entitlement, or live-user repository is altered.
        let report = try repository.mergeBackupReport(records)
        guard report.added == 1000 else { throw CollectionError.invalid("Scale fixture was incomplete") }
        return root
    }
}
#endif
