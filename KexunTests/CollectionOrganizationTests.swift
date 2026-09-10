import Foundation
import Testing
import Darwin
@testable import Kexun

struct CollectionOrganizationTests {
    @Test @MainActor func titleOnlyMetadataDoesNotNeedAnAttachmentImportLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunMetadataImportGate-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var record = CollectionRecord(kind: .link, title: "original", originalURL: "https://example.com/gate")
        record.processingState = .pending
        try repository.insert([record], isPro: false)
        // Hold exactly the exclusive import gate used by orphan cleanup, not the lifecycle lock.
        let descriptor = Darwin.open(root.appendingPathComponent("attachment-import.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        defer { Darwin.close(descriptor) }
        try #require(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in LinkMetadata(title: "title completed", imageURL: nil) })
        for _ in 0..<100 {
            if store.records.first?.processingState == .complete && !store.isProcessingContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try #require(try repository.all().first)
        #expect(saved.title == "title completed" && saved.processingState == .complete)
        #expect(saved.attachments.isEmpty)
    }

    @Test func oldRecordDecodesAndNewFieldsSurviveBackupAndReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunOrganization-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var record = CollectionRecord(kind: .link, title: "old bookmark", body: "original share", originalURL: "https://example.com/article")
        let oldData = try JSONEncoder().encode(record)
        let oldJSON = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        #expect(oldJSON["folder"] == nil && oldJSON["article"] == nil)
        let legacy = try JSONDecoder().decode(CollectionRecord.self, from: oldData)
        #expect(legacy == record)
        record.folder = "研究"
        record.article = SavedWebArticle(text: "离线正文 offlineNeedle", sourceURL: "https://example.com/final", capturedAt: Date(timeIntervalSince1970: 1234))
        try repository.insert([record], isPro: false)
        let archive = try BackupArchive.exportFile(repository: repository, assets: assets, temporaryRoot: root)
        let restoredRoot = root.appendingPathComponent("restored")
        let restoredAssets = try AttachmentStore(root: restoredRoot)
        let restoredRepository = try CollectionRepository(url: restoredRoot.appendingPathComponent("collections.sqlite"))
        #expect(try BackupArchive.restoreFile(archive, repository: restoredRepository, assets: restoredAssets) == 1)
        let reopened = try CollectionRepository(url: restoredRoot.appendingPathComponent("collections.sqlite"))
        let restored = try #require(try reopened.all().first)
        #expect(restored == record)
        #expect(CollectionQuery(text: "offlineNeedle", folder: "研究").matches(restored))
        #expect(CollectionQuery(text: "offlineNeedle").snippet(for: restored).contains("离线正文"))
        #expect(!CollectionQuery(folder: "").matches(restored))
    }

    @Test func folderMoveRenameAndRemovalAreAtomicAndNeverDeleteRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunFolderAtomic-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let first = CollectionRecord(kind: .text, title: "first", body: "body")
        var second = CollectionRecord(kind: .text, title: "second", body: "body")
        second.deletedAt = Date()
        second.folder = "阅读"
        try repository.insert([first, second], isPro: false)
        #expect(throws: (any Error).self) {
            try repository.batch(ids: [first.id, second.id], action: .folder("研究"))
        }
        #expect(try repository.all().first(where: { $0.id == first.id })?.folder == nil)
        try repository.batch(ids: [first.id], action: .folder("阅读"))
        let beforeInvalid = try repository.all()
        #expect(throws: (any Error).self) { try repository.renameFolder("阅读", to: String(repeating: "x", count: 41)) }
        #expect(try repository.all() == beforeInvalid)
        try repository.renameFolder("阅读", to: "研究")
        #expect(try repository.all().allSatisfy { $0.folder == "研究" })
        try repository.renameFolder("研究", to: nil)
        let final = try repository.all()
        #expect(final.count == 2 && final.allSatisfy { $0.folder == nil })
        #expect(final.first(where: { $0.id == second.id })?.deletedAt == second.deletedAt)
        #expect(final.first(where: { $0.id == first.id })?.body == first.body)
    }

    @Test @MainActor func failedFileRetryDoesNotDuplicatePreviouslySavedItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunImportRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CollectionStore(openRoot: { root })
        let good = root.appendingPathComponent("good.txt")
        let missing = root.appendingPathComponent("temporarily-missing.txt")
        try Data("first original".utf8).write(to: good)
        let first = await store.importFiles([good, missing])
        #expect(first.saved == 1 && first.unsavedURLs == [missing])
        #expect(store.records.count == 1)
        try Data("now available".utf8).write(to: missing)
        let retry = await store.importFiles(first.unsavedURLs)
        #expect(retry.saved == 1 && retry.unsavedURLs.isEmpty && retry.failures.isEmpty)
        #expect(store.records.count == 2)
        #expect(store.records.filter { $0.title == "good.txt" }.count == 1)
    }

    @Test @MainActor func articleRefreshPreservesEditsAndFailureKeepsOfflineCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunArticlePersistence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CollectionStore(openRoot: { root }, fetchArticle: { url in
            WebArticle(title: "remote title", text: "saved offline paragraph", finalURL: url.appendingPathComponent("final"), capturedAt: Date(timeIntervalSince1970: 111))
        })
        var original = CollectionRecord(kind: .link, title: "my title", body: "original share", originalURL: "https://example.com/")
        original.folder = "阅读"
        original.note = "my note"
        #expect(store.save(original))
        #expect(await store.saveWebArticle(original))
        let saved = try #require(store.records.first)
        #expect(saved.title == original.title && saved.note == original.note && saved.body == original.body)
        #expect(saved.folder == "阅读" && saved.article?.text == "saved offline paragraph")
        let failingStore = CollectionStore(openRoot: { root }, fetchArticle: { _ in throw URLError(.notConnectedToInternet) })
        #expect(!(await failingStore.saveWebArticle(saved)))
        let failed = try #require(failingStore.records.first)
        #expect(failed.article == saved.article && failed.articleError != nil)
        #expect(CollectionQuery(text: "offline").matches(failed))
        #expect(failed.originalURL == original.originalURL)
    }
}
