import Testing
import Foundation
@testable import Kexun

struct LibraryDataManagementTests {
    @Test func backupReceiptUsesActualArchiveSnapshotAndOnlyExplicitSuccessPersistsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunSnapshotTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "KexunSnapshotReceipt-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let record = CollectionRecord(kind: .text, title: "Exported version", body: "old body")
        try repository.insert([record], isPro: false)
        let url = try BackupArchive.exportFile(repository: repository, assets: assets, temporaryRoot: root)
        // Mutate the live database AFTER the ZIP was generated. Receipt must still describe the old bytes.
        try repository.update(id: record.id) { $0.body = "new body" }
        let receipt = try LibraryDataManagement.snapshotReceipt(archiveURL: url)
        #expect(receipt.recordCount == 1)
        #expect(receipt.zipBytes == Int64(try Data(contentsOf: url).count))
        #expect(receipt.fingerprint == (try LibraryDataManagement.fingerprint([record])))
        #expect(receipt.fingerprint != (try LibraryDataManagement.fingerprint(repository.all())))
        #expect(LibraryDataManagement.backupReceipt(root: root, defaults: defaults) == nil)
        let success = Date(timeIntervalSince1970: 10000)
        try LibraryDataManagement.recordSuccessfulBackup(root: root, receipt: receipt, completedAt: success, defaults: defaults)
        let saved = try #require(LibraryDataManagement.backupReceipt(root: root, defaults: defaults))
        #expect(saved.exportedAt == success)
        #expect(saved.fingerprint == receipt.fingerprint)
        // Preparing another export without a success callback must leave the successful receipt alone.
        let nextURL = try BackupArchive.exportFile(repository: repository, assets: assets, temporaryRoot: root)
        _ = try LibraryDataManagement.snapshotReceipt(archiveURL: nextURL)
        #expect(LibraryDataManagement.backupReceipt(root: root, defaults: defaults) == saved)
    }

    @Test func fingerprintIsOrderIndependentButDetectsFolderArticleAndDeletionChanges() throws {
        let first = CollectionRecord(kind: .text, title: "First")
        let second = CollectionRecord(kind: .link, title: "Second")
        let baseline = try LibraryDataManagement.fingerprint([first, second])
        #expect(baseline == (try LibraryDataManagement.fingerprint([second, first])))
        var changed = first
        changed.folder = "工作"
        #expect(baseline != (try LibraryDataManagement.fingerprint([changed, second])))
        changed = first
        changed.article = SavedWebArticle(text: "article", sourceURL: "https://example.com", capturedAt: Date())
        #expect(baseline != (try LibraryDataManagement.fingerprint([changed, second])))
        changed = first
        changed.deletedAt = Date()
        #expect(baseline != (try LibraryDataManagement.fingerprint([changed, second])))
    }

    @Test func selectedExportContainsOnlyRequestedRecordsAndRejectsMissingIDsAsAWhole() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunSelectedExportTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("source.txt")
        try Data("selected".utf8).write(to: source)
        let wanted = try assets.importFile(source, contentType: "public.plain-text")
        try Data("unselected".utf8).write(to: source)
        let unwanted = try assets.importFile(source, contentType: "public.plain-text")
        var first = CollectionRecord(kind: .file, title: "Selected")
        first.attachments = [wanted]
        var second = CollectionRecord(kind: .file, title: "Not selected")
        second.attachments = [unwanted]
        try repository.insert([first, second], isPro: false)
        let url = try LibraryDataManagement.exportReadable(repository: repository, assets: assets, selectedIDs: [first.id], temporaryRoot: root)
        let decoded = root.appendingPathComponent("decoded")
        try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
        let entries = try StreamingZIP.decode(url, into: decoded)
        #expect(entries["records/\(first.id).md"] != nil)
        #expect(entries["records/\(second.id).md"] == nil)
        #expect(entries["attachments/\(wanted.id).txt"] != nil)
        #expect(entries["attachments/\(unwanted.id).txt"] == nil)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        #expect(throws: (any Error).self) {
            try LibraryDataManagement.exportReadable(repository: repository, assets: assets, selectedIDs: [first.id, UUID()], temporaryRoot: root)
        }
        #expect(throws: (any Error).self) {
            try LibraryDataManagement.exportReadable(repository: repository, assets: assets, selectedIDs: [], temporaryRoot: root)
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == before)
    }

    @Test func backupReceiptIsExplicitAndLibraryScoped() throws {
        let suite = "KexunBackupReceiptTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/test/library-one")
        let second = URL(fileURLWithPath: "/test/library-two")
        #expect(LibraryDataManagement.lastSuccessfulBackup(root: first, defaults: defaults) == nil)
        let time = Date(timeIntervalSince1970: 12345)
        LibraryDataManagement.recordSuccessfulBackup(root: first, date: time, defaults: defaults)
        #expect(LibraryDataManagement.lastSuccessfulBackup(root: first, defaults: defaults) == time)
        #expect(LibraryDataManagement.lastSuccessfulBackup(root: second, defaults: defaults) == nil)
        #expect(LibraryDataManagement.filename(readable: false, date: time).hasPrefix("kexun-backup-"))
        #expect(LibraryDataManagement.filename(readable: true, date: time).hasSuffix(".zip"))
    }

    @Test func readableExportRoundTripsTextAttachmentsAndTrashWithoutRecoveryManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunReadableTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("原始文件.txt")
        let original = Data("原始附件 payload".utf8)
        try original.write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        var record = CollectionRecord(kind: .text, title: "标题 [不是链接]", body: "正文\n```\n![private](https://example.com/image)\n```", originalURL: "https://example.com/item", source: "来源", note: "私密备注")
        record.extractedText = "识别文本内容"
        record.folder = "旅行资料"
        record.article = SavedWebArticle(text: "已保存的网页正文", sourceURL: "https://example.com/original-article", capturedAt: Date(timeIntervalSince1970: 86400))
        record.starred = true
        record.deletedAt = Date(timeIntervalSince1970: 100)
        record.attachments = [reference]
        try repository.insert([record], isPro: false)
        let output = try LibraryDataManagement.exportReadable(repository: repository, assets: assets, temporaryRoot: root)
        let decoded = root.appendingPathComponent("decoded")
        try FileManager.default.createDirectory(at: decoded, withIntermediateDirectories: true)
        let entries = try StreamingZIP.decode(output, into: decoded)
        #expect(entries["manifest.json"] == nil)
        #expect(entries["items.json"] == nil)
        let indexEntry = try #require(entries["README.md"])
        let index = try String(contentsOf: indexEntry.url, encoding: .utf8)
        #expect(index.contains("回收站 / Trash"))
        #expect(index.contains("\\[不是链接\\]"))
        let textEntry = try #require(entries["records/\(record.id.uuidString).md"])
        let text = try String(contentsOf: textEntry.url, encoding: .utf8)
        #expect(text.contains(record.body))
        #expect(text.contains("````text"))
        #expect(text.contains(record.note))
        #expect(text.contains(record.extractedText))
        #expect(text.contains("旅行资料"))
        #expect(text.contains("已保存的网页正文"))
        #expect(text.contains("https://example.com/original-article"))
        #expect(text.contains("Article captured: 1970-01-02T00:00:00Z"))
        #expect(text.contains("Starred: true"))
        #expect(text.contains("https://example.com/item"))
        let attachmentEntry = try #require(entries["attachments/\(reference.id.uuidString).txt"])
        #expect(try Data(contentsOf: attachmentEntry.url) == original)
        #expect(try Data(contentsOf: assets.url(for: reference)) == original)
        #expect(try repository.all() == [record])
    }

    @Test func usageCountsSharedAttachmentsOnceAndReadsActualSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunUsageTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("source.txt")
        try Data(repeating: 1, count: 7).write(to: source)
        let shared = try assets.importFile(source, contentType: "public.plain-text")
        try Data(repeating: 2, count: 11).write(to: source)
        let trashOnly = try assets.importFile(source, contentType: "public.plain-text")
        var live = CollectionRecord(kind: .file, title: "Live")
        live.attachments = [shared]
        var trash = CollectionRecord(kind: .file, title: "Trash")
        trash.deletedAt = Date()
        trash.attachments = [shared, trashOnly]
        try repository.insert([live, trash], isPro: false)
        let usage = try LibraryDataManagement.usage(repository: repository, assets: assets)
        #expect(usage.activeCount == 1)
        #expect(usage.trashCount == 1)
        #expect(usage.activeAttachmentBytes == 7)
        #expect(usage.trashOnlyAttachmentBytes == 11)
        #expect(usage.totalAttachmentBytes == 18)
        #expect(usage.trashReferencedAttachmentBytes == 18)
        #expect(usage.largeAttachments.map(\.bytes) == [11, 7])
        #expect(usage.largeAttachments.first(where: { $0.id == shared.id })?.records.count == 2)
        #expect(usage.unavailableAttachments == 0)
        // A damaged file's real footprint must not be misreported from stale metadata.
        try Data(repeating: 3, count: 5).write(to: assets.url(for: trashOnly))
        #expect(try LibraryDataManagement.usage(repository: repository, assets: assets).trashOnlyAttachmentBytes == 5)
    }

    @Test func corruptAttachmentAbortsExportAndCleansStaging() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunReadableFailureTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("source.txt")
        try Data("original".utf8).write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        var record = CollectionRecord(kind: .file, title: "Damaged")
        record.attachments = [reference]
        try repository.insert([record], isPro: false)
        try Data("changed".utf8).write(to: assets.url(for: reference))
        #expect(throws: (any Error).self) {
            try LibraryDataManagement.exportReadable(repository: repository, assets: assets, temporaryRoot: root)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains { $0.hasPrefix("kexun-backup-") })
        #expect(try repository.all() == [record])
        try FileManager.default.removeItem(at: assets.url(for: reference))
        #expect(try LibraryDataManagement.usage(repository: repository, assets: assets).unavailableAttachments == 1)
    }

    @Test func repeatedAttachmentIDCannotReuseDigestForAnotherPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunReadablePathTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("source.txt")
        try Data("trusted".utf8).write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        try Data("private".utf8).write(to: source)
        let other = try assets.importFile(source, contentType: "public.plain-text")
        var forged = reference
        forged.relativePath = other.relativePath
        var record = CollectionRecord(kind: .file, title: "Conflicting references")
        record.attachments = [reference, forged]
        try repository.insert([record], isPro: false)
        #expect(throws: (any Error).self) {
            try LibraryDataManagement.exportReadable(repository: repository, assets: assets, temporaryRoot: root)
        }
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("kexun-backup-") })
        #expect(try Data(contentsOf: assets.url(for: reference)) == Data("trusted".utf8))
        #expect(try Data(contentsOf: assets.url(for: other)) == Data("private".utf8))
    }
}
