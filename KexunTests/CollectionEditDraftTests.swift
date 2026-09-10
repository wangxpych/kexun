import Foundation
import Testing
@testable import Kexun

struct CollectionEditDraftTests {
    private func repository() throws -> CollectionRepository {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunDraftMerge-\(UUID())")
        return try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
    }

    @Test func backgroundExtractionAndTitleSurviveNoteSave() throws {
        let repository = try repository()
        let base = CollectionRecord(kind: .image, title: "image", extractedText: "")
        try repository.insert([base], isPro: false)
        var draft = CollectionEditDraft(record: base)
        draft.note = "my annotation"
        try repository.update(id: base.id) {
            $0.extractedText = "recognized words"
            $0.processingState = .complete
            $0.title = "background title"
            $0.article = SavedWebArticle(text: "saved article", sourceURL: "https://example.com", capturedAt: Date())
        }
        try repository.update(id: base.id) { try draft.merge(from: base, into: &$0) }
        let saved = try #require(try repository.all().first)
        #expect(saved.note == draft.note)
        #expect(saved.title == "background title" && !saved.titleEdited)
        #expect(saved.extractedText == "recognized words" && saved.article?.text == "saved article")
        #expect(saved.version == base.version + 2)
    }

    @Test func sameFieldConflictRollsBackDraftAndManagementAction() throws {
        let repository = try repository()
        let base = CollectionRecord(kind: .text, title: "title", body: "body")
        try repository.insert([base], isPro: false)
        var draft = CollectionEditDraft(record: base)
        draft.title = "my title"
        draft.note = "my note"
        try repository.update(id: base.id) { $0.note = "other note" }
        do {
            try repository.update(id: base.id) {
                try draft.merge(from: base, into: &$0)
                $0.starred = true
            }
            Issue.record("Concurrent note changes must conflict")
        } catch CollectionError.conflict { }
        let saved = try #require(try repository.all().first)
        #expect(saved.title == base.title && saved.note == "other note" && !saved.starred)
        #expect(saved.version == base.version + 1)
        #expect(draft.title == "my title" && draft.note == "my note")
    }

    @Test func trashedRecordCannotBeEditedFromStaleDetail() throws {
        let repository = try repository()
        let base = CollectionRecord(kind: .text, title: "title", body: "body")
        try repository.insert([base], isPro: false)
        var draft = CollectionEditDraft(record: base)
        draft.note = "unsaved note"
        try repository.update(id: base.id) { $0.deletedAt = Date() }
        do {
            try repository.update(id: base.id) { try draft.merge(from: base, into: &$0) }
            Issue.record("Trashed record must reject stale detail edits")
        } catch CollectionError.conflict { }
        let saved = try #require(try repository.all().first)
        #expect(saved.deletedAt != nil && saved.note.isEmpty)
        #expect(saved.version == base.version + 1)
    }

    @Test func draftAndStarCommitTogetherAfterBackgroundUpdate() throws {
        let repository = try repository()
        let base = CollectionRecord(kind: .link, title: "link", originalURL: "https://example.com")
        try repository.insert([base], isPro: false)
        var draft = CollectionEditDraft(record: base)
        draft.note = "annotation"
        draft.folder = " Reading "
        try repository.update(id: base.id) { $0.title = "fetched title" }
        try repository.update(id: base.id) {
            try draft.merge(from: base, into: &$0)
            $0.starred.toggle()
        }
        let saved = try #require(try repository.all().first)
        #expect(saved.starred && saved.note == "annotation" && saved.folder == "Reading")
        #expect(saved.title == "fetched title" && saved.version == base.version + 2)
    }

    @Test func identicalConcurrentEditIsAcceptedButIdentityChangeIsRejected() throws {
        let base = CollectionRecord(kind: .text, title: "title", body: "body")
        var draft = CollectionEditDraft(record: base)
        draft.body = "same new body"
        var latest = base
        latest.body = draft.body
        try draft.merge(from: base, into: &latest)
        #expect(latest.body == draft.body)
        latest.kind = .image
        do {
            try draft.merge(from: base, into: &latest)
            Issue.record("Changed content identity must conflict")
        } catch CollectionError.conflict { }
    }

    @Test func staleStarOrArchiveStateRejectsCombinedAction() throws {
        for archive in [false, true] {
            let repository = try repository()
            let base = CollectionRecord(kind: .text, title: "title", body: "body")
            try repository.insert([base], isPro: false)
            var draft = CollectionEditDraft(record: base)
            draft.note = "unsaved note"
            try repository.update(id: base.id) {
                if archive { $0.archivedAt = Date() } else { $0.starred = true }
            }
            do {
                try repository.update(id: base.id) {
                    try draft.merge(from: base, into: &$0)
                    $0.starred.toggle()
                }
                Issue.record("Changed management state must conflict")
            } catch CollectionError.conflict { }
            let saved = try #require(try repository.all().first)
            #expect(saved.note.isEmpty && saved.version == base.version + 1)
            #expect(archive ? saved.archivedAt != nil : saved.starred)
        }
    }

    @Test func textEditRoundTripsAndUpdatesSearchWithoutReplacingMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunEditDraft-\(UUID())")
        let databaseURL = root.appendingPathComponent("collections.sqlite")
        let repository = try CollectionRepository(url: databaseURL)
        var original = CollectionRecord(kind: .text, title: "原来的标题", body: "旧正文", source: "来源保留")
        original.starred = true
        original.archivedAt = Date()
        try repository.insert([original], isPro: false)
        var draft = CollectionEditDraft(record: original)
        draft.body = "新正文与 emoji 🧭\n第二行 searchable126"
        draft.note = "新备注"
        #expect(draft.isValid && draft.hasChanges(from: original))
        try repository.update(id: original.id, expectedVersion: original.version) { draft.apply(to: &$0) }
        let reopened = try CollectionRepository(url: databaseURL)
        let saved = try #require(try reopened.all().first)
        #expect(saved.body == draft.body && saved.note == draft.note)
        #expect(saved.title == original.title && !saved.titleEdited)
        #expect(saved.source == original.source && saved.createdAt == original.createdAt)
        #expect(saved.starred && saved.archivedAt == original.archivedAt)
        #expect(saved.version == original.version + 1)
        #expect(CollectionQuery(text: "searchable126").matches(saved))
        #expect(!CollectionQuery(text: "旧正文").matches(saved))
    }

    @Test func nonTextSourceAndExtractionStayImmutable() {
        for kind in [ContentKind.link, .image, .file] {
            var record = CollectionRecord(kind: kind, title: "title", body: "original share text", originalURL: "https://example.com/", extractedText: "OCR result")
            var draft = CollectionEditDraft(record: record)
            draft.body = "must not replace original"
            #expect(!draft.hasChanges(from: record))
            draft.note = "annotation"
            draft.apply(to: &record)
            #expect(record.body == "original share text")
            #expect(record.extractedText == "OCR result")
            #expect(record.originalURL == "https://example.com/")
            #expect(record.note == "annotation" && !record.titleEdited)
        }
    }

    @Test func blankDraftInvalidAndConflictKeepsEditsAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunEditConflict-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let original = CollectionRecord(kind: .text, title: "title", body: "body")
        try repository.insert([original], isPro: false)
        var draft = CollectionEditDraft(record: original)
        draft.body = " \n\t"
        #expect(!draft.isValid)
        draft.body = "unsaved body"
        draft.title = "my title"
        #expect(draft.isValid)
        try repository.update(id: original.id, expectedVersion: original.version) { $0.note = "another writer" }
        do {
            try repository.update(id: original.id, expectedVersion: original.version) { draft.apply(to: &$0) }
            Issue.record("Stale draft must not overwrite another writer")
        } catch CollectionError.conflict { }
        #expect(draft.body == "unsaved body" && draft.title == "my title")
        let saved = try #require(try repository.all().first)
        #expect(saved.body == "body" && saved.note == "another writer")
    }
}
