//
//  KexunTests.swift
//  KexunTests
//
//  Created by wxp on 2026/9/5.
//

import Testing
import Foundation
import UIKit
import PDFKit
import SQLite3
@testable import Kexun

struct KexunTests {
    @Test func sqliteFullRollsBackAndAllowsRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunSQLiteFull-\(UUID())")
        let url = root.appendingPathComponent("collections.sqlite")
        let repository = try CollectionRepository(url: url)
        let original = CollectionRecord(kind: .text, title: "Before capacity limit", body: "Original content")
        try repository.insert([original], isPro: false)

        // This synchronous test exclusively owns the connection. Inspect it only here
        // so fault injection does not add a database escape hatch to the production API.
        let database = try #require(Mirror(reflecting: repository).children.first(where: { $0.label == "database" })?.value as? OpaquePointer)
        func scalar(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int64(statement, 0)
        }
        let previousLimit = try scalar("PRAGMA max_page_count")
        let pages = try scalar("PRAGMA page_count")
        #expect(try scalar("PRAGMA max_page_count=\(pages)") == pages)
        defer { sqlite3_exec(database, "PRAGMA max_page_count=\(previousLimit)", nil, nil, nil) }
        // Prove the engine emits SQLITE_FULL, not an injected generic SQL error.
        #expect(sqlite3_exec(database, "INSERT INTO records(id,payload) VALUES ('capacity-probe',zeroblob(2097152))", nil, nil, nil) == SQLITE_FULL)
        #expect(try repository.all() == [original])

        let first = CollectionRecord(kind: .text, title: "First item in atomic batch")
        let large = CollectionRecord(kind: .text, title: "Exceeds page budget", body: String(repeating: "x", count: 2 * 1024 * 1024))
        do {
            try repository.insert([first, large], isPro: false)
            Issue.record("Full database must reject the entire batch")
        } catch CollectionError.database(let message) {
            #expect(message.contains("full"))
        }
        #expect(try repository.all() == [original])
        do {
            try repository.update(id: original.id, expectedVersion: original.version) { $0.body = large.body }
            Issue.record("Failed replacement must preserve the original payload and version")
        } catch CollectionError.database(let message) {
            #expect(message.contains("full"))
        }
        #expect(try repository.all() == [original])
        let reader = try CollectionRepository(url: url)
        #expect(try reader.all() == [original])
        try reader.checkIntegrity()

        #expect(try scalar("PRAGMA max_page_count=\(previousLimit)") == previousLimit)
        try repository.insert([first, large], isPro: false)
        let saved = try reader.all()
        #expect(Set(saved.map(\.id)) == Set([original.id, first.id, large.id]))
        #expect(saved.first(where: { $0.id == large.id }) == large)
        #expect(saved.first(where: { $0.id == original.id }) == original)
        try repository.checkIntegrity()
    }

    @Test func chineseSourceCatalogsShipInAppAndExtension() throws {
        let extensionURL = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("KexunShare.appex"))
        let extensionBundle = try #require(Bundle(url: extensionURL))
        for bundle in [Bundle.main, extensionBundle] {
            #expect(bundle.developmentLocalization == "zh-Hans")
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "zh-Hans"))
            let data = try Data(contentsOf: url)
            let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            #expect(strings["保存"] == "保存")
            #expect(strings["收藏已发生变化，请刷新后再操作。"] == "收藏已发生变化，请刷新后再操作。")
            #expect(!strings.keys.contains { $0.contains("仅 Debug") || $0.contains("分享 21 个链接的文字") })
        }
    }

    @Test func cancellingActivePhotoReadCancelsProvider() async throws {
        actor Marker {
            var started = false
            func mark() { started = true }
        }
        let marker = Marker()
        let progress = Progress(totalUnitCount: 1)
        let task = Task {
            try await PhotoTransfer.load(seconds: 5) { _ in
                Task { await marker.mark() }
                return progress
            }
        }
        for _ in 0..<100 {
            if await marker.started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await marker.started)
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled read must not return a photo")
        } catch { #expect(error is CancellationError) }
        #expect(progress.isCancelled)
    }

    @Test func photoProviderTimeoutCancelsAndCleansLateCopy() async throws {
        let progress = Progress(totalUnitCount: 1)
        var callback: (@Sendable (Result<PhotoTransfer?, Error>) -> Void)?
        do {
            _ = try await PhotoTransfer.load(seconds: 0.02) { completion in
                callback = completion
                return progress
            }
            Issue.record("Unresponsive provider must time out")
        } catch { #expect(error is CallbackTimeout) }
        #expect(progress.isCancelled)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunLatePhoto-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let url = root.appendingPathComponent("late.jpg")
        try Data([1, 2, 3]).write(to: url)
        let complete = try #require(callback)
        complete(.success(PhotoTransfer(url: url, directory: root)))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test @MainActor func themeAccentContrastInBothAppearances() {
        func luminance(_ color: UIColor, _ traits: UITraitCollection) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #expect(color.resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a))
            func linear(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let accent = luminance(KexunPalette.accent, traits)
            for background in [KexunPalette.page, KexunPalette.onAccent] {
                let other = luminance(background, traits)
                #expect((max(accent, other) + 0.05) / (min(accent, other) + 0.05) >= 4.5)
            }
        }
    }

    @Test func filterCountAndResetPreserveSearchScope() {
        var query = CollectionQuery(scope: .trash)
        query.text = "关键词"
        query.newestFirst = false
        #expect(query.activeFilterCount == 0)
        query.kind = .text
        query.source = "随手记"
        query.starredOnly = true
        query.archived = false
        query.since = Date()
        #expect(query.activeFilterCount == 5)
        query.resetFilters()
        #expect(query.activeFilterCount == 0)
        #expect(query.text == "关键词")
        #expect(query.scope == .trash)
        #expect(!query.newestFirst)
    }

    @Test func searchTimeBoundariesIntersectFiltersAndResetResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunSearchFilters-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // V1 uses inclusive rolling windows. Each case has a record immediately
        // outside, exactly on, and immediately inside the documented cutoff.
        let windows: [(name: String, cutoff: Date)] = [
            ("Window7", Date(timeIntervalSince1970: 1_799_395_200)),
            ("Window30", Date(timeIntervalSince1970: 1_797_408_000))
        ]
        for window in windows {
            var outside = CollectionRecord(kind: .text, title: window.name + " outside")
            outside.createdAt = window.cutoff.addingTimeInterval(-1)
            var boundary = CollectionRecord(kind: .text, title: window.name + " boundary")
            boundary.createdAt = window.cutoff
            var inside = CollectionRecord(kind: .text, title: window.name + " inside")
            inside.createdAt = window.cutoff.addingTimeInterval(1)
            try repository.insert([outside, boundary, inside], isPro: false)
            var query = CollectionQuery(scope: .library, text: window.name)
            query.since = window.cutoff
            let found = try await CollectionSearch.run(records: repository.all(), query: query)
            #expect(found.map(\.id) == [inside.id, boundary.id])
            query.since = nil
            let unrestricted = try await CollectionSearch.run(records: repository.all(), query: query)
            #expect(unrestricted.map(\.id) == [inside.id, boundary.id, outside.id])
        }

        func matchingRecord() -> CollectionRecord {
            var record = CollectionRecord(kind: .text, title: "交集验收 Match")
            record.createdAt = now.addingTimeInterval(-60)
            record.source = "随手记"
            record.starred = true
            record.archivedAt = now
            return record
        }
        let match = matchingRecord()
        var otherKind = matchingRecord()
        otherKind.kind = .link
        otherKind.originalURL = "https://example.com/search-filter-fixture"
        var otherSource = matchingRecord()
        otherSource.source = "其他来源"
        var unstarred = matchingRecord()
        unstarred.starred = false
        var unarchived = matchingRecord()
        unarchived.archivedAt = nil
        var tooOld = matchingRecord()
        tooOld.createdAt = windows[0].cutoff.addingTimeInterval(-1)
        var deleted = matchingRecord()
        deleted.deletedAt = now
        var unrelated = matchingRecord()
        unrelated.title = "Unrelated content"
        let activeMatches = [match, otherKind, otherSource, unstarred, unarchived, tooOld]
        try repository.insert(activeMatches + [deleted, unrelated], isPro: false)

        // Each decoy differs in exactly one filter dimension; requiring the sole
        // positive result catches either a missing dimension or accidental OR.
        var query = CollectionQuery(scope: .library, text: "交集验收 match", kind: .text,
                                    source: "随手记", starredOnly: true, archived: true,
                                    since: windows[0].cutoff, newestFirst: false)
        let intersection = try await CollectionSearch.run(records: repository.all(), query: query)
        #expect(intersection.map(\.id) == [match.id])
        query.resetFilters()
        let reset = try await CollectionSearch.run(records: repository.all(), query: query)
        #expect(Set(reset.map(\.id)) == Set(activeMatches.map(\.id)))
        #expect(reset.first?.id == tooOld.id)
        #expect(query.scope == .library && query.text == "交集验收 match" && !query.newestFirst)
    }

    @Test @MainActor func staleDetailUpdatePreservesLatestAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunEditConflict-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let original = CollectionRecord(kind: .text, title: "原始标题")
        try repository.insert([original], isPro: false)
        let store = CollectionStore(openRoot: { root })
        let stale = try #require(store.records.first)
        let otherWriter = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        try otherWriter.update(id: stale.id) { $0.note = "另一写入者的更新"; $0.starred = true }
        #expect(!store.update(stale) { $0.title = "尚未保存的标题" })
        #expect(store.error != nil)
        let latest = try #require(store.records.first)
        #expect(latest.title == "原始标题")
        #expect(latest.note == "另一写入者的更新")
        #expect(latest.starred)
        #expect(latest.version == stale.version + 1)
        #expect(store.update(latest) { $0.title = "重新编辑的标题" })
        #expect(store.error == nil)
        let saved = try #require(repository.all().first)
        #expect(saved.title == "重新编辑的标题")
        #expect(saved.note == latest.note)
        #expect(saved.starred)
        #expect(saved.version == latest.version + 1)
    }

    @Test @MainActor func damagedPDFRemainsAvailableAfterExtractionFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunDamagedPDF-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("damaged.pdf")
        let bytes = Data("%PDF-1.7\ninvalid truncated fixture".utf8)
        try bytes.write(to: source)
        let store = CollectionStore(openRoot: { root })
        let report = await store.importFiles([source])
        #expect(report.saved == 1)
        try FileManager.default.removeItem(at: source)
        for _ in 0..<150 {
            if store.records.first?.processingState == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = try #require(store.records.first)
        #expect(record.processingState == .failed)
        #expect(record.processingError?.contains("原文件已保留") == true)
        let reference = try #require(record.attachments.first)
        let preview = try await store.previewURL(for: reference)
        #expect(try Data(contentsOf: preview) == bytes)
        #expect(try repository.all().count == 1)
        var query = CollectionQuery()
        query.text = "damaged.pdf"
        #expect(try await CollectionSearch.run(records: store.records, query: query).count == 1)
    }

    @Test @MainActor func importedPDFSurvivesSourceRemovalAndBecomesSearchable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPDFImport-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("route.pdf")
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { context in
            context.beginPage()
            ("KEXUN native PDF retrieval" as NSString).draw(at: CGPoint(x: 30, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        try bytes.write(to: source)
        let store = CollectionStore(openRoot: { root })
        let report = await store.importFiles([source])
        #expect(report.saved == 1)
        #expect(report.failures.isEmpty)
        try FileManager.default.removeItem(at: source)
        for _ in 0..<150 {
            if store.records.first?.processingState == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let record = try #require(store.records.first)
        #expect(record.kind == .file)
        #expect(record.processingState == .complete)
        #expect(record.extractedText.contains("KEXUN native PDF retrieval"))
        let attachment = try #require(record.attachments.first)
        #expect(attachment.contentType == "com.adobe.pdf")
        let preview = try await store.previewURL(for: attachment)
        #expect(try Data(contentsOf: preview) == bytes)
        #expect(PDFDocument(url: preview)?.pageCount == 1)
        let persisted = try repository.all()
        var query = CollectionQuery()
        query.text = "native retrieval"
        let found = try await CollectionSearch.run(records: persisted, query: query)
        #expect(found.map(\.id) == [record.id])
        let reopened = CollectionStore(openRoot: { root })
        #expect(reopened.records.first?.extractedText == record.extractedText)
    }

    @Test @MainActor func failedLinkCoverKeepsTitleAndRetriesWithoutOverwritingEdits() async throws {
        actor CoverFixture {
            var attempts = 0
            func fetch() throws -> Data {
                attempts += 1
                if attempts == 1 { throw CollectionError.invalid("模拟封面下载失败") }
                return Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aXioAAAAASUVORK5CYII=")!
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunCoverRetry-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var record = CollectionRecord(kind: .link, title: "原链接")
        record.originalURL = "https://example.com/article"
        record.processingState = .pending
        try repository.insert([record], isPro: false)
        let fixture = CoverFixture()
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in
            LinkMetadata(title: "网页标题", imageURL: URL(string: "https://example.com/cover.png"))
        }, fetchCover: { _ in try await fixture.fetch() })
        for _ in 0..<100 {
            if store.records.first?.processingState == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let failed = try #require(store.records.first)
        #expect(failed.processingState == .failed)
        #expect(failed.processingError?.contains("封面补全失败") == true)
        #expect(failed.title == "网页标题")
        #expect(failed.originalURL == record.originalURL)
        #expect(failed.attachments.isEmpty)
        try repository.update(id: record.id) { $0.title = "我的标题"; $0.titleEdited = true }
        store.reload()
        store.extract(try #require(store.records.first))
        for _ in 0..<100 {
            if store.records.first?.processingState == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let retried = try #require(store.records.first)
        #expect(retried.processingState == .complete)
        #expect(retried.processingError == nil)
        #expect(retried.title == "我的标题")
        let cover = try #require(retried.attachments.first)
        #expect(FileManager.default.fileExists(atPath: try #require(store.attachments).url(for: cover).path))
        #expect(try repository.all().count == 1)
    }

    @Test func editedMultiLinkTextRejectsStaleSelection() throws {
        let old = "https://a.example/one"
        #expect(try LinkParser.selectedURL(in: old + " https://b.example/two", selection: old).absoluteString == old)
        let changed = "https://c.example/three https://d.example/four"
        #expect(throws: CollectionError.self) { try LinkParser.selectedURL(in: changed, selection: old) }
        #expect(throws: CollectionError.self) { try LinkParser.selectedURL(in: changed, selection: "") }
        #expect(throws: CollectionError.self) { try LinkParser.selectedURL(in: "没有链接", selection: old) }
        #expect(try LinkParser.selectedURL(in: "https://c.example/three", selection: old).host == "c.example")
    }

    @Test @MainActor func cancelledImportDoesNotCommitOrLeaveAttachment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunCancelledImport-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("cancelled.txt")
        try Data("not to be saved".utf8).write(to: source)
        let store = CollectionStore(openRoot: { root })
        let task = Task { @MainActor in await store.importFiles([source]) }
        task.cancel()
        let report = await task.value
        #expect(report.saved == 0)
        #expect(report.failures.count == 1)
        #expect(report.message.contains("导入已取消"))
        #expect(try repository.all().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path)
        #expect(files.isEmpty)
        #expect(!store.importing)
    }

    @Test @MainActor func batchFileImportKeepsSuccessAndReportsMissingSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPartialImport-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let first = root.appendingPathComponent("first.txt")
        let last = root.appendingPathComponent("last.txt")
        try Data("first content".utf8).write(to: first)
        try Data("last content".utf8).write(to: last)
        let missing = root.appendingPathComponent("missing.txt")
        let store = CollectionStore(openRoot: { root })
        let result = await store.importFiles([first, missing, last])
        #expect(result.saved == 2)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.contains("missing.txt") == true)
        #expect(store.importReport == result.message)
        #expect(!store.importing)
        let records = try repository.all()
        #expect(Set(records.map(\.title)) == ["first.txt", "last.txt"])
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: last)
        let assets = try AttachmentStore(root: root)
        for record in records {
            let reference = try #require(record.attachments.first)
            let content = try String(contentsOf: assets.url(for: reference), encoding: .utf8)
            #expect(content == (record.title == "first.txt" ? "first content" : "last content"))
        }
        // A failed member did not reserve a phantom slot: all 98 remaining slots are usable.
        try repository.insert((0..<98).map { CollectionRecord(kind: .text, title: "Quota fixture \($0)") }, isPro: false)
        #expect(try repository.all().count == 100)
        do {
            try repository.insert([CollectionRecord(kind: .text, title: "over limit")], isPro: false)
            Issue.record("Free limit was bypassed")
        } catch CollectionError.limit { }
    }

    @Test @MainActor func attachmentPreparationReportsMissingAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPreviewNative-\(UUID())")
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("original name.txt")
        let bytes = Data("Attachment survives preview and retry".utf8)
        try bytes.write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        var record = CollectionRecord(kind: .file, title: reference.originalName)
        record.attachments = [reference]
        try repository.insert([record], isPro: false)
        let store = CollectionStore(openRoot: { root })
        let savedURL = try assets.url(for: reference)
        try FileManager.default.removeItem(at: savedURL)
        do { _ = try await store.previewURL(for: reference); Issue.record("Missing attachment silently prepared") }
        catch { }
        #expect(store.records.count == 1)
        try bytes.write(to: savedURL)
        let prepared = try await store.previewURL(for: reference)
        #expect(prepared.lastPathComponent == reference.originalName)
        #expect(try Data(contentsOf: prepared) == bytes)
        #expect(try await store.previewURL(for: reference) == prepared)
        #expect(store.records.first == record)
        var shared = CollectionRecord(kind: .file, title: "另一条引用同一附件")
        shared.attachments = [reference]
        try repository.insert([shared], isPro: false)
        try repository.batch(ids: [record.id], action: .trash)
        store.reload()
        store.permanentlyDelete([record.id])
        #expect(FileManager.default.fileExists(atPath: prepared.path), "A shared attachment preview must remain available")
        #expect(FileManager.default.fileExists(atPath: savedURL.path))
        try repository.batch(ids: [shared.id], action: .trash)
        store.reload()
        store.permanentlyDelete([shared.id])
        #expect(!FileManager.default.fileExists(atPath: prepared.deletingLastPathComponent().path))
        #expect(!FileManager.default.fileExists(atPath: savedURL.path))
        #expect(store.records.isEmpty)
    }

    @Test func faultRecoveryPublishesIndependentGeneration() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("KexunRecoveryNative-\(UUID())", isDirectory: true)
        let group = fixture.appendingPathComponent("group", isDirectory: true)
        let original = try SharedStorage.prepare(group: group)
        let damaged = Data("damaged original database".utf8)
        try damaged.write(to: original.appendingPathComponent("collections.sqlite"))
        let sourceRoot = fixture.appendingPathComponent("source", isDirectory: true)
        let source = try CollectionRepository(url: sourceRoot.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: sourceRoot)
        let record = CollectionRecord(kind: .text, title: "完整恢复后找得到")
        try source.insert([record], isPro: false)
        let archive = try BackupArchive.exportFile(repository: source, assets: assets)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let candidate = try RecoveryArchive.stage(archive, group: group)
        #expect(try SharedStorage.prepare(group: group) == original)
        try SharedStorage.publishRecovery(group: group, generation: candidate.generation)
        let session = try SharedStorage.session(group: group)
        let recovered = try CollectionRepository(url: session.root.appendingPathComponent("collections.sqlite"), storageLease: session)
        #expect(try recovered.all() == [record])
        #expect(try Data(contentsOf: original.appendingPathComponent("collections.sqlite")) == damaged)
        // The ready marker's initial count must not reject legitimate later additions.
        try recovered.insert([CollectionRecord(kind: .text, title: "恢复后的新增")], isPro: false)
        let reopened = try SharedStorage.session(group: group)
        let reader = try CollectionRepository(url: reopened.root.appendingPathComponent("collections.sqlite"), storageLease: reopened)
        #expect(try reader.all().count == 2)
    }

    @Test @MainActor func storageRetryPreservesLastGoodState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunRetry-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let original = CollectionRecord(kind: .text, title: "Last good record")
        try repository.insert([original], isPro: true)
        var available = true
        let store = CollectionStore(openRoot: {
            guard available else { throw CollectionError.database("Injected unavailable storage") }
            return root
        })
        #expect(store.records == [original])
        let revision = store.revision
        available = false
        store.open()
        #expect(store.loadError != nil)
        #expect(store.records == [original])
        #expect(store.revision == revision)
        store.reload()
        #expect(store.loadError != nil, "A cached connection must not hide a failed storage reopen")
        available = true
        try repository.update(id: original.id) { $0.title = "Updated while unavailable" }
        store.open()
        #expect(store.loadError == nil)
        #expect(store.error == nil)
        #expect(store.records.first?.title == "Updated while unavailable")
        #expect(store.revision > revision)
        let unavailable = CollectionStore(openRoot: { throw CollectionError.database("Unavailable on first open") })
        #expect(unavailable.loadError != nil)
        #expect(unavailable.repository == nil && unavailable.attachments == nil)
        #expect(unavailable.records.isEmpty)
        // Unique fixture retained until asynchronous startup maintenance releases it.
    }

    @Test @MainActor func failedBatchRestoreKeepsRecordsAndCanRetry() throws {
        try #require(!PurchaseService.cachedIsPro, "Run quota acceptance with free local entitlement")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunRestoreRetry-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let active = (0..<100).map { CollectionRecord(kind: .text, title: "Active \($0)") }
        var trashed = CollectionRecord(kind: .text, title: "Keep archived and starred", body: "Original body")
        trashed.deletedAt = Date()
        trashed.archivedAt = Date()
        trashed.starred = true
        try repository.insert(active + [trashed], isPro: true)
        let store = CollectionStore(openRoot: { root })
        #expect(!store.restoreMany([trashed.id]))
        #expect(store.quotaExceeded)
        #expect(store.error != nil)
        let rejected = try #require(store.records.first { $0.id == trashed.id })
        #expect(rejected.deletedAt == trashed.deletedAt)
        #expect(rejected.version == trashed.version)
        #expect(store.records.filter { $0.deletedAt == nil }.count == 100)
        try repository.batch(ids: [active[0].id], action: .trash)
        #expect(store.restoreMany([trashed.id]))
        #expect(!store.quotaExceeded)
        #expect(store.error == nil)
        let restored = try #require(store.records.first { $0.id == trashed.id })
        #expect(restored.deletedAt == nil)
        #expect(restored.archivedAt == trashed.archivedAt)
        #expect(restored.starred && restored.body == trashed.body)
        #expect(store.records.filter { $0.deletedAt == nil }.count == 100)
        #expect(try repository.all().first { $0.id == trashed.id }?.deletedAt == nil)
    }

    @Test @MainActor func staleTrashSelectionRejectsWholeOperationAndCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunTrashConflict-\(UUID())")
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let source = root.appendingPathComponent("shared.txt")
        let bytes = Data("Keep this attachment until all references are deleted".utf8)
        try bytes.write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        let trashed = (0..<3).map { index in
            var record = CollectionRecord(kind: .file, title: "Trash conflict \(index)", body: "Original body")
            record.deletedAt = Date()
            record.archivedAt = Date()
            record.starred = true
            record.attachments = [reference]
            return record
        }
        let unrelated = CollectionRecord(kind: .text, title: "Unrelated active record")
        try repository.insert(trashed + [unrelated], isPro: false)
        let store = CollectionStore(openRoot: { root })
        let otherWriter = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        try otherWriter.restore(ids: [trashed[0].id], isPro: false)
        let afterOtherRestore = try repository.all()
        let staleRestoredSelection: Set<UUID> = [trashed[0].id, trashed[1].id]
        #expect(!store.restoreMany(staleRestoredSelection))
        #expect(!store.quotaExceeded)
        #expect(store.error == CollectionError.conflict.localizedDescription)
        #expect(try repository.all() == afterOtherRestore)
        #expect(!store.permanentlyDelete(staleRestoredSelection))
        #expect(try repository.all() == afterOtherRestore)
        #expect(try Data(contentsOf: assets.url(for: reference)) == bytes)

        _ = try otherWriter.permanentlyDelete(ids: [trashed[2].id])
        let afterOtherDelete = try repository.all()
        let staleMissingSelection: Set<UUID> = [trashed[1].id, trashed[2].id]
        #expect(!store.restoreMany(staleMissingSelection))
        #expect(!store.permanentlyDelete(staleMissingSelection))
        #expect(try repository.all() == afterOtherDelete)
        #expect(store.records == afterOtherDelete)
        #expect(try Data(contentsOf: assets.url(for: reference)) == bytes)

        #expect(store.restoreMany([trashed[1].id]))
        #expect(store.error == nil)
        let restored = try #require(store.records.first { $0.id == trashed[1].id })
        #expect(restored.deletedAt == nil && restored.starred)
        #expect(restored.archivedAt == trashed[1].archivedAt && restored.body == trashed[1].body)
        #expect(store.batch(staleRestoredSelection, action: .trash))
        store.error = "Previous operation failed"
        #expect(store.permanentlyDelete(staleRestoredSelection))
        #expect(store.error == nil)
        #expect(try repository.all() == [unrelated])
        #expect(!FileManager.default.fileExists(atPath: try assets.url(for: reference).path))
    }

    @Test func temporaryCleanupOnlyRemovesOldOwnedDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CleanupTest-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-86400)
        let old = cutoff.addingTimeInterval(-3600)
        func directory(_ name: String, date: Date) throws -> URL {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("private test content".utf8).write(to: url.appendingPathComponent("payload"))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let stale = try directory("kexun-backup-\(UUID())", date: old)
        let recent = try directory("KexunPreview-\(UUID())", date: Date())
        let unknown = try directory("kexun-backup-not-a-uuid", date: old)
        let refreshed = try directory("KexunPhotoTransfer-\(UUID())", date: old)
        let external = try directory("unrelated", date: old)
        let link = root.appendingPathComponent("kexun-backup-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let snapshot = try TemporaryArtifactCleanup.candidates(in: root, olderThan: cutoff)
        #expect(Set(snapshot.map(\.path)) == [stale.path, refreshed.path])
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: refreshed.path)
        #expect(TemporaryArtifactCleanup.remove(snapshot, olderThan: cutoff) == 1)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        for kept in [recent, unknown, refreshed, external, link] {
            #expect(FileManager.default.fileExists(atPath: kept.appendingPathComponent("payload").path))
        }
        #expect(try TemporaryArtifactCleanup.candidates(in: root, olderThan: cutoff).isEmpty)
    }

    @Test @MainActor func queuedRetryRespectsConcurrencyAndRunsOnce() async throws {
        actor Requests {
            var active = 0
            var maximum = 0
            var counts: [String: Int] = [:]
            func begin(_ key: String) {
                active += 1
                maximum = max(maximum, active)
                counts[key, default: 0] += 1
            }
            func end() { active -= 1 }
            func result() -> (Int, [String: Int]) { (maximum, counts) }
        }
        let requests = Requests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunQueueRetry-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var records = (0..<4).map { index in
            var record = CollectionRecord(kind: .link, title: "Queue \(index)")
            record.originalURL = "https://example.com/queue-\(index)"
            record.processingState = index == 3 ? .failed : .pending
            return record
        }
        records[0].processingState = .processing // Resume interrupted work too.
        try repository.insert(records, isPro: false)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { url in
            await requests.begin(url.absoluteString)
            try await Task.sleep(for: .milliseconds(60))
            await requests.end()
            return LinkMetadata(title: "Completed", imageURL: nil)
        })
        // open() synchronously schedules two jobs before their asynchronous bodies begin.
        store.extract(records[3])
        store.extract(records[3])
        #expect(try repository.all().first { $0.id == records[3].id }?.processingState == .pending)
        for _ in 0..<150 {
            if store.records.allSatisfy({ $0.processingState == .complete }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.records.count == 4)
        #expect(store.records.allSatisfy { $0.processingState == .complete })
        let (maximum, counts) = await requests.result()
        #expect(maximum == 2)
        #expect(counts.count == 4)
        #expect(counts.values.allSatisfy { $0 == 1 })
    }

    @Test @MainActor func trashBeforeScheduledProcessingDoesNotFetch() async throws {
        actor Requests {
            var count = 0
            func record() { count += 1 }
            func total() -> Int { count }
        }
        let requests = Requests()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunQueueTrash-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let records = (0..<3).map { index in
            var record = CollectionRecord(kind: .link, title: "Trash queued \(index)")
            record.originalURL = "https://example.com/trash-\(index)"
            record.processingState = index == 2 ? .failed : .pending
            return record
        }
        try repository.insert(records, isPro: false)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in
            await requests.record()
            return LinkMetadata(title: "Must not run", imageURL: nil)
        })
        store.extract(records[2])
        // Synchronous second connection deletes after scheduling, before task bodies can run.
        let writer = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        try writer.batch(ids: Set(records.map(\.id)), action: .trash)
        let expected = try writer.all()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await requests.total() == 0)
        #expect(store.requestedExtractions.isEmpty)
        #expect(try writer.all() == expected, "Skipped work must not update deleted record versions or state")
        #expect(store.records.allSatisfy { $0.deletedAt != nil })
    }

    @Test @MainActor func trashDuringMetadataSkipsCoverAndRestoreResumes() async throws {
        actor Source {
            var metadataCalls = 0
            var coverCalls = 0
            var returned = 0
            func metadata() async throws -> LinkMetadata {
                metadataCalls += 1
                let attempt = metadataCalls
                if attempt == 1 { try await Task.sleep(for: .milliseconds(200)) }
                returned += 1
                return LinkMetadata(title: "Restored completion", imageURL: attempt == 1 ? URL(string: "https://example.com/unused-cover.png") : nil)
            }
            func cover() -> Data { coverCalls += 1; return Data() }
            func counts() -> (Int, Int, Int) { (metadataCalls, coverCalls, returned) }
        }
        let source = Source()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunInFlightTrash-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var original = CollectionRecord(kind: .link, title: "Original before deletion")
        original.originalURL = "https://example.com/in-flight"
        original.processingState = .pending
        try repository.insert([original], isPro: false)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in try await source.metadata() }, fetchCover: { _ in await source.cover() })
        for _ in 0..<100 {
            if await source.counts().0 == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await source.counts().0 == 1)
        #expect(store.batch([original.id], action: .trash))
        for _ in 0..<100 {
            if await source.counts().2 == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(await source.counts().1 == 0)
        let trashed = try #require(store.records.first)
        #expect(trashed.deletedAt != nil)
        #expect(trashed.title == original.title)
        #expect(trashed.attachments.isEmpty)
        #expect(store.restore(trashed))
        for _ in 0..<100 {
            if store.records.first?.processingState == .complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await source.counts().0 == 2)
        #expect(await source.counts().1 == 0)
        #expect(store.records.first?.processingState == .complete)
        #expect(store.records.first?.title == "Restored completion")
        #expect(store.records.first?.deletedAt == nil)
    }

    @Test @MainActor func shareInputsKeepItemContextsAndMixedTextOnlyItems() async throws {
        let firstURL = NSItemProvider(object: NSURL(string: "https://example.com/first")!)
        firstURL.registerDataRepresentation(forTypeIdentifier: "public.plain-text", visibility: .all) { completion in
            completion("链接附带的独立说明".data(using: .utf8), nil)
            return nil
        }
        let firstText = NSItemProvider(object: "第一项附带文字" as NSString)
        let first = NSExtensionItem()
        first.attributedContentText = NSAttributedString(string: "第一项上下文")
        first.attachments = [firstURL, firstText]
        let textOnly = NSExtensionItem()
        let exactText = " 第二项只有文字\n保留换行 "
        textOnly.attributedContentText = NSAttributedString(string: exactText)
        let thirdProvider = NSItemProvider(object: "第三项内容" as NSString)
        let third = NSExtensionItem()
        third.attachments = [thirdProvider]
        let empty = NSExtensionItem()
        empty.attributedContentText = NSAttributedString(string: " \n")
        let inputs = ShareInput.collect(from: [first, textOnly, third, empty])
        #expect(inputs.count == 4)
        #expect(inputs[0].provider === firstURL)
        #expect(inputs[1].provider === firstText)
        #expect(inputs[3].provider === thirdProvider)
        #expect(inputs.map(\.context) == ["第一项上下文", "第一项上下文", exactText, ""])
        let supplied: String = try await ShareInput.load(inputs[2].provider, type: "public.plain-text")
        let suppliedURL: URL = try await ShareInput.load(firstURL, type: "public.url")
        #expect(suppliedURL.absoluteString == "https://example.com/first")
        let accompanyingText: String = try await ShareInput.load(firstURL, type: "public.plain-text")
        #expect(accompanyingText == "链接附带的独立说明")
        #expect(ShareText.merge([inputs[0].context, accompanyingText, suppliedURL.absoluteString]) == "第一项上下文\n链接附带的独立说明\nhttps://example.com/first")
        #expect(supplied == exactText)
        #expect(ShareText.merge([inputs[2].context, supplied]) == exactText)
        #expect(ShareText.decodeProviderValue(Data([0xFF, 0xFF]) as NSData) == nil)
        #expect(ShareText.decodeProviderValue(exactText.data(using: .utf16)! as NSData) == exactText)
    }

    @Test func shareTextMergePreservesDistinctRepresentationsExactly() throws {
        let context = " 来源说明\n第二行 "
        let representation = "https://example.com/article\n正文说明"
        let merged = ShareText.merge([context, representation, context, " \n"])
        #expect(merged == context + "\n" + representation)
        #expect(ShareText.merge(["短文", "短文与其他内容"]) == "短文\n短文与其他内容")
        let recordTitle = CaptureTitle.resolve(body: merged)
        var record = CollectionRecord(kind: .link, title: recordTitle.value)
        record.body = merged
        record.originalURL = "https://example.com/article"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunShareText-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        try repository.insert([record], isPro: false)
        #expect(try repository.all().first?.body == merged)
    }

    @Test func automaticTitleSkipsLeadingWhitespaceWithoutChangingBody() throws {
        let body = String(repeating: " \n\t", count: 100) + "有效内容\n第二行" + String(repeating: "尾", count: 100)
        let resolved = CaptureTitle.resolve(explicit: " \n", body: body)
        #expect(resolved.value.hasPrefix("有效内容\n第二行"))
        #expect(resolved.value.count == 80)
        #expect(!resolved.edited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunTitleWhitespace-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var record = CollectionRecord(kind: .text, title: resolved.value)
        record.body = body
        record.titleEdited = resolved.edited
        try repository.insert([record], isPro: false)
        #expect(try repository.all().first?.body == body)
        #expect(try repository.all().first?.title == resolved.value)
        let custom = CaptureTitle.resolve(explicit: " 自定标题 ", body: body)
        #expect(custom.value == "自定标题" && custom.edited)
        #expect(CaptureTitle.resolve(body: " \n\t").value.isEmpty)
    }

    @Test @MainActor func permanentDeletionDuringCoverDownloadLeavesNoOrphan() async throws {
        actor CoverGate {
            var started = false
            var continuation: CheckedContinuation<Data, Never>?
            func fetch() async -> Data {
                started = true
                return await withCheckedContinuation { continuation = $0 }
            }
            func hasStarted() -> Bool { started }
            func release(_ bytes: Data) { continuation?.resume(returning: bytes); continuation = nil }
        }
        let gate = CoverGate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunLateCoverDelete-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var original = CollectionRecord(kind: .link, title: "Delete while cover is downloading")
        original.originalURL = "https://example.com/late-cover"
        original.processingState = .pending
        let survivor = CollectionRecord(kind: .text, title: "Unrelated record must survive")
        try repository.insert([original, survivor], isPro: false)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in
            LinkMetadata(title: "Late metadata", imageURL: URL(string: "https://example.com/cover.png"))
        }, fetchCover: { _ in await gate.fetch() })
        for _ in 0..<100 {
            if await gate.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.hasStarted())
        #expect(store.batch([original.id], action: .trash))
        store.permanentlyDelete([original.id])
        #expect(store.error == nil)
        #expect(try repository.all() == [survivor])
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        await gate.release(bytes)
        for _ in 0..<300 {
            if !store.isProcessingContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!store.isProcessingContent, "Wait for the late cover import and cleanup, not merely the deletion")
        #expect(try repository.all() == [survivor], "Late processing must never recreate deleted records")
        #expect(store.records == [survivor])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path)
        #expect(files.isEmpty, "A cover returned after permanent deletion must not remain orphaned")
    }

    @Test @MainActor func thumbnailLoaderDownsamplesAndReusesDecodedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunThumbnail-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("large.png")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000), format: format).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        try bytes.write(to: url)
        let loader = ThumbnailLoader()
        let first = try #require(await loader.image(for: url, maximumPixelSize: 300))
        let cached = try #require(await loader.image(for: url, maximumPixelSize: 300))
        #expect(first.width == 300 && first.height == 150)
        #expect(first === cached)
        let larger = try #require(await loader.image(for: url, maximumPixelSize: 600))
        #expect(larger.width == 600 && larger.height == 300)
        #expect(larger !== first)
        #expect(await loader.image(for: root.appendingPathComponent("missing.png"), maximumPixelSize: 300) == nil)
    }

    @Test @MainActor func thousandMixedRecordsRemainSearchable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunScale-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: root)
        let imageURL = root.appendingPathComponent("scale-image.png")
        try UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).pngData { context in
            UIColor.green.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }.write(to: imageURL)
        let pdfURL = root.appendingPathComponent("scale-document.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)).pdfData { context in
            context.beginPage()
            ("Scale PDF" as NSString).draw(at: .zero, withAttributes: nil)
        }.write(to: pdfURL)
        let image = try assets.importFile(imageURL, contentType: "public.png")
        let pdf = try assets.importFile(pdfURL, contentType: "com.adobe.pdf")
        let padding = String(repeating: "普通内容 ", count: 200)
        let records = (0..<1000).map { index in
            var record = CollectionRecord(kind: ContentKind.allCases[index % 4], title: "标题标记\(index)号")
            record.body = "正文标记\(index)号 " + padding
            record.note = "备注标记\(index)号"
            record.source = "来源标记\(index)号"
            record.createdAt = Date(timeIntervalSince1970: 1700000000 + Double(index))
            if record.kind == .link { record.originalURL = "https://example.com/scale-\(index)-end" }
            if record.kind == .image { record.attachments = [image]; record.extractedText = "识别标记\(index)号" }
            if record.kind == .file { record.attachments = [pdf]; record.extractedText = "PDF标记\(index)号" }
            if index % 3 == 0 { record.archivedAt = record.createdAt }
            if index % 20 == 0 { record.deletedAt = record.createdAt }
            return record
        }
        try repository.insert(records, isPro: true) // Fixture setup only; no entitlement is granted.
        let start = ProcessInfo.processInfo.systemUptime
        let store = CollectionStore(openRoot: { root })
        let loadMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        #expect(store.records.count == 1000)
        #expect(store.records.filter { $0.deletedAt == nil }.count == 950)
        let cases: [(String, Int)] = [("标题标记3号", 3), ("正文标记2号", 2), ("备注标记5号", 5),
                                    ("SCALE-4-END", 4), ("来源标记7号", 7), ("识别标记6号", 6), ("PDF标记11号", 11)]
        var durations: [Double] = []
        for (text, index) in cases {
            var query = CollectionQuery(scope: .library)
            query.text = text
            let before = ProcessInfo.processInfo.systemUptime
            let found = try await CollectionSearch.run(records: store.records, query: query)
            durations.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
            #expect(found.map(\.id) == [records[index].id])
        }
        var query = CollectionQuery(scope: .library)
        query.text = "scale-image.png"
        #expect(try await CollectionSearch.run(records: store.records, query: query).count == 250)
        query.text = "标题标记0号"
        #expect(try await CollectionSearch.run(records: store.records, query: query).isEmpty)
        query.text = "备注标记5号 普通内容"
        #expect(try await CollectionSearch.run(records: store.records, query: query).map(\.id) == [records[5].id])
        print("KEXUN_SCALE records=1000 active=950 sharedAssets=2 system=\(ProcessInfo.processInfo.operatingSystemVersionString) loadMS=\(loadMS) searchMS=\(durations)")
    }

    @Test func persistentCollectionLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunNativeTests-\(UUID())")
        let url = root.appendingPathComponent("test.sqlite")
        let repository = try CollectionRepository(url: url)
        let record = CollectionRecord(kind: .text, title: "原生测试", body: "需要时可以找回来")
        try repository.insert([record], isPro: false)
        let reopened = try CollectionRepository(url: url)
        #expect(try reopened.all().first?.body == record.body)
        try repository.batch(ids: [record.id], action: .archive(true))
        var query = CollectionQuery(scope: .library)
        query.text = "找回来"
        #expect(try reopened.search(query).count == 1)
        query.scope = .inbox
        #expect(try reopened.search(query).isEmpty)
        try repository.batch(ids: [record.id], action: .trash)
        try repository.restore(ids: [record.id], isPro: false)
        #expect(try reopened.all().first?.archivedAt != nil)
    }

    @Test func freeBackupRestoresOverQuota() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunNativeBackup-\(UUID())")
        let source = try CollectionRepository(url: root.appendingPathComponent("source/test.sqlite"))
        let sourceAssets = try AttachmentStore(root: root.appendingPathComponent("source"))
        try source.insert((0..<101).map { CollectionRecord(kind: .text, title: "内容\($0)") }, isPro: true)
        let backup = try BackupArchive.exportFile(repository: source, assets: sourceAssets)
        let destination = try CollectionRepository(url: root.appendingPathComponent("destination/test.sqlite"))
        let destinationAssets = try AttachmentStore(root: root.appendingPathComponent("destination"))
        #expect(try BackupArchive.restoreFile(backup, repository: destination, assets: destinationAssets) == 101)
        #expect(try BackupArchive.restoreFile(backup, repository: destination, assets: destinationAssets) == 0)
        do {
            try destination.insert([CollectionRecord(kind: .text, title: "超额新增")], isPro: false)
            Issue.record("Free quota was bypassed")
        } catch CollectionError.limit { }
    }

    @Test @MainActor func extremeBackupVersionsFailSafelyWithoutProcessingLoop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunVersionBoundary-\(UUID())")
        let sourceRoot = root.appendingPathComponent("source")
        let source = try CollectionRepository(url: sourceRoot.appendingPathComponent("collections.sqlite"))
        let sourceAssets = try AttachmentStore(root: sourceRoot)
        var active = CollectionRecord(kind: .text, title: "Readable boundary record", body: "Do not lose this content")
        active.version = Int.max
        var trashed = active
        trashed.id = UUID()
        trashed.deletedAt = Date()
        let ordinary = CollectionRecord(kind: .text, title: "Ordinary unaffected record")
        try source.insert([active, trashed, ordinary], isPro: false)
        let archive = try BackupArchive.exportFile(repository: source, assets: sourceAssets)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let destinationRoot = root.appendingPathComponent("destination")
        let repository = try CollectionRepository(url: destinationRoot.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: destinationRoot)
        #expect(try BackupArchive.restoreFile(archive, repository: repository, assets: assets) == 3)
        let snapshot = try repository.all()
        func rejectsWithoutChanges(_ action: () throws -> Void) throws {
            do { try action(); Issue.record("Version overflow must reject the operation") }
            catch CollectionError.invalid(let message) { #expect(message.contains("版本无法继续更新")) }
            #expect(try repository.all() == snapshot)
        }
        try rejectsWithoutChanges { try repository.update(id: active.id) { $0.title = "Must not overwrite" } }
        try rejectsWithoutChanges { try repository.batch(ids: [active.id, ordinary.id], action: .trash) }
        try rejectsWithoutChanges { try repository.restore(ids: [trashed.id], isPro: false) }
        try rejectsWithoutChanges { _ = try repository.beginProcessing(id: active.id) }
        #expect(try repository.search(CollectionQuery(text: "Do not lose")).map(\.id) == [active.id])
        let exportedAgain = try BackupArchive.exportFile(repository: repository, assets: assets)
        defer { try? FileManager.default.removeItem(at: exportedAgain.deletingLastPathComponent()) }
        #expect(try BackupArchive.restoreFile(exportedAgain, repository: repository, assets: assets) == 0)
        var nearBoundary = ordinary
        nearBoundary.id = UUID()
        nearBoundary.version = Int.max - 1
        try repository.insert([nearBoundary], isPro: false)
        try repository.update(id: nearBoundary.id) { $0.note = "Last valid increment" }
        #expect(try repository.all().first { $0.id == nearBoundary.id }?.version == Int.max)

        let processingRoot = root.appendingPathComponent("processing")
        let processingRepository = try CollectionRepository(url: processingRoot.appendingPathComponent("collections.sqlite"))
        var pending = CollectionRecord(kind: .link, title: "Untrusted pending version")
        pending.version = Int.max
        pending.originalURL = "https://example.com/version-boundary"
        pending.processingState = .pending
        try processingRepository.insert([pending], isPro: false)
        let store = CollectionStore(openRoot: { processingRoot }, fetchMetadata: { _ in
            Issue.record("A failed processing claim must not start network work")
            throw CollectionError.invalid("Unexpected fetch")
        })
        for _ in 0..<100 {
            if store.processingPersistenceError != nil && !store.isProcessingContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.processingPersistenceError?.contains("自动处理已暂停") == true)
        #expect(store.loadError == nil)
        #expect(!store.isProcessingContent)
        store.reload()
        store.resumeExtraction()
        #expect(!store.isProcessingContent)
        #expect(store.processingPersistenceError != nil)
        #expect(try processingRepository.all() == [pending])
    }

    @Test @MainActor func processingWriteFailurePausesAndExplicitRetryRecovers() async throws {
        actor FetchCounter {
            var count = 0
            func fetch() -> LinkMetadata {
                count += 1
                return LinkMetadata(title: "Completed after storage recovered", imageURL: nil)
            }
        }
        let counter = FetchCounter()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunProcessingWriteFailure-\(UUID())")
        let databaseURL = root.appendingPathComponent("collections.sqlite")
        let repository = try CollectionRepository(url: databaseURL)
        var pending = CollectionRecord(kind: .link, title: "Original title", body: "Original saved content")
        pending.originalURL = "https://example.com/write-failure"
        pending.processingState = .pending
        try repository.insert([pending], isPro: false)
        var handle: OpaquePointer?
        try #require(sqlite3_open(databaseURL.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, "CREATE TRIGGER reject_record_write BEFORE INSERT ON records BEGIN SELECT RAISE(ABORT, 'Injected fixture write failure'); END", nil, nil, nil) == SQLITE_OK)
        let store = CollectionStore(openRoot: { root }, fetchMetadata: { _ in await counter.fetch() })
        for _ in 0..<100 {
            if store.processingPersistenceError != nil && !store.isProcessingContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.processingPersistenceError?.contains("Injected fixture write failure") == true)
        #expect(store.loadError == nil && !store.isProcessingContent)
        #expect(try repository.all() == [pending])
        #expect(await counter.count == 0)
        try #require(sqlite3_exec(handle, "DROP TRIGGER reject_record_write", nil, nil, nil) == SQLITE_OK)
        store.reload()
        store.resumeExtraction()
        #expect(!store.isProcessingContent, "Ordinary refresh must not restart a paused worker")
        #expect(store.processingPersistenceError != nil)
        store.open() // Same explicit retry action as the UI.
        for _ in 0..<100 {
            if store.records.first?.processingState == .complete && !store.isProcessingContent { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let saved = try #require(repository.all().first)
        #expect(saved.processingState == .complete)
        #expect(saved.title == "Completed after storage recovered")
        #expect(saved.body == pending.body && saved.id == pending.id)
        #expect(saved.version == pending.version + 2)
        #expect(await counter.count == 1)
        #expect(store.processingPersistenceError == nil && store.loadError == nil)
        #expect(store.error == nil && !store.isProcessingContent)
    }

    @Test func metadataDoesNotRequireCompleteHTML() {
        let metadata = LinkMetadata.parse("<TITLE>可寻 &amp; 收藏</TITLE>", baseURL: URL(string: "https://example.com/")!)
        #expect(metadata.title == "可寻 & 收藏")
    }

}
