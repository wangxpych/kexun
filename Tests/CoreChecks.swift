import Foundation

@main
struct CoreChecks {
    static func check(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--writer" {
            let repository = try CollectionRepository(url: URL(fileURLWithPath: CommandLine.arguments[2]))
            do { try repository.insert([CollectionRecord(kind: .text, title: "子进程写入")], isPro: false) }
            catch CollectionError.limit { }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-core-checks-\(UUID())")
        var snippetRecord = CollectionRecord(kind: .image, title: "笔记照片", body: "不相关的分享文字")
        snippetRecord.extractedText = String(repeating: "前文", count: 100) + "中文 Finding 测试" + String(repeating: "后文", count: 100)
        var snippetQuery = CollectionQuery(scope: .library, text: "中文 finding", kind: .image, source: "Safari", starredOnly: true, archived: true, since: Date(), newestFirst: false)
        let snippet = snippetQuery.snippet(for: snippetRecord)
        check(snippet.hasPrefix("识别文本：…") && snippet.contains("中文 Finding") && snippet.count < 175)
        check(snippetQuery.snippet(for: snippetRecord, limit: 0).isEmpty)
        snippetQuery.resetFilters()
        check(snippetQuery.text == "中文 finding" && snippetQuery.scope == .library && !snippetQuery.newestFirst)
        check(snippetQuery.kind == nil && snippetQuery.source == nil && !snippetQuery.starredOnly && snippetQuery.archived == nil && snippetQuery.since == nil)
        check(snippetQuery.matches(snippetRecord))
        snippetQuery.scope = .trash
        snippetQuery.resetFilters()
        check(snippetQuery.scope == .trash && !snippetQuery.matches(snippetRecord))
        print("PASS: OCR match context, case-insensitive multiword snippet, bounded excerpt, filter reset preserves keyword/scope/sort")
        let url = root.appendingPathComponent("collections.sqlite")
        let repo = try CollectionRepository(url: url)
        let initial = (0..<99).map { CollectionRecord(kind: .text, title: "收藏 \($0)", body: "中文检索测试") }
        try repo.insert(initial, isPro: false)
        let connection2 = try CollectionRepository(url: url)
        let group = DispatchGroup()
        for repository in [repo, connection2] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try repository.insert([CollectionRecord(kind: .text, title: "并发新增")], isPro: false) }
                catch CollectionError.limit { }
                catch { fatalError("unexpected concurrent error: \(error)") }
            }
        }
        group.wait()
        check(try repo.all().count == 100)
        let first = initial[0]
        try repo.update(id: first.id) { $0.archivedAt = Date(); $0.starred = true }
        do {
            try repo.insert([CollectionRecord(kind: .text, title: "超限")], isPro: false)
            fatalError("quota bypass")
        } catch CollectionError.limit { }
        try repo.update(id: first.id) { $0.deletedAt = Date() }
        try repo.insert([CollectionRecord(kind: .text, title: "释放额度")], isPro: false)
        do { try repo.restore(ids: [first.id], isPro: false); fatalError("restore bypass") }
        catch CollectionError.limit { }
        var query = CollectionQuery()
        query.text = "中文 检索"
        check(try repo.search(query).count == 98)
        query.scope = .trash
        check(try repo.search(query).count == 1)
        let reopened = try CollectionRepository(url: url)
        check(try reopened.all().count == 101)
        let backups = (0..<120).map { CollectionRecord(kind: .text, title: "恢复 \($0)") }
        check(try repo.mergeBackup(backups) == 120)
        check(try repo.mergeBackup(backups) == 0)
        var conflict = backups[0]
        conflict.note = "备份冲突内容"
        check(try repo.mergeBackup([conflict]) == 1)
        check(try repo.mergeBackup([conflict]) == 0)
        let before = try repo.all().count
        var invalid = CollectionRecord(kind: .text, title: "")
        invalid.version = 0
        do { _ = try repo.mergeBackup([CollectionRecord(kind: .text, title: "需回滚"), invalid]); fatalError("invalid accepted") }
        catch CollectionError.invalid { }
        check(try repo.all().count == before)
        try repo.restore(ids: [first.id], isPro: true)
        let restored = try repo.all().first { $0.id == first.id }!
        precondition(restored.archivedAt != nil && restored.starred && restored.version == 4)
        precondition(LinkParser.normalized("HTTPS://EXAMPLE.COM:443?a=1") == "https://example.com/?a=1")
        precondition(LinkParser.normalized("https://example.com/?a=1") != LinkParser.normalized("https://example.com/?a=2"))
        let processURL = root.appendingPathComponent("process.sqlite")
        let processRepo = try CollectionRepository(url: processURL)
        try processRepo.insert(initial, isPro: false)
        let processes = (0..<2).map { _ in Process() }
        for process in processes {
            process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            process.arguments = ["--writer", processURL.path]
            try process.run()
        }
        for process in processes { process.waitUntilExit(); precondition(process.terminationStatus == 0) }
        check(try processRepo.all().count == 100)
        let assets = try AttachmentStore(root: root)
        let source = root.appendingPathComponent("原始文件.txt")
        try Data("附件原文".utf8).write(to: source)
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        try FileManager.default.removeItem(at: source)
        check(try Data(contentsOf: assets.url(for: reference)) == Data("附件原文".utf8))
        var invalidReference = reference
        invalidReference.relativePath = "assets/../../outside"
        do { _ = try assets.url(for: invalidReference); fatalError("path traversal accepted") }
        catch CollectionError.invalid { }
        let legacyRoot = root.appendingPathComponent("legacy")
        let legacyRepo = try CollectionRepository(url: legacyRoot.appendingPathComponent("collections.sqlite"))
        let legacyRecord = CollectionRecord(kind: .text, title: "旧库 WAL 内容")
        let legacyAssets = try AttachmentStore(root: legacyRoot)
        let legacySource = legacyRoot.appendingPathComponent("需要保留的原始附件.txt")
        let legacyBytes = Data("旧库附件独立字节\nArchive and trash retain their attachment".utf8)
        try legacyBytes.write(to: legacySource)
        let legacyReference = try legacyAssets.importFile(legacySource, contentType: "public.plain-text")
        var legacyFile = CollectionRecord(kind: .file, title: "已归档星标文件", body: "多行原始内容\n不能丢失")
        legacyFile.createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
        legacyFile.updatedAt = Date(timeIntervalSinceReferenceDate: 700_000_100)
        legacyFile.archivedAt = Date(timeIntervalSinceReferenceDate: 700_000_050)
        legacyFile.starred = true
        legacyFile.titleEdited = true
        legacyFile.note = "旧库备注"
        legacyFile.source = "旧版文件导入"
        legacyFile.originalURL = "https://example.com/original?business=keep"
        legacyFile.version = 7
        legacyFile.attachments = [legacyReference]
        legacyFile.extractedText = "已提取文本"
        legacyFile.processingState = .failed
        legacyFile.processingError = "历史处理失败原因"
        var legacyTrashed = legacyFile
        legacyTrashed.id = UUID()
        legacyTrashed.title = "已删除但仍持有共享附件"
        legacyTrashed.deletedAt = Date(timeIntervalSinceReferenceDate: 700_000_080)
        legacyTrashed.version = 8
        let legacyRecords = [legacyRecord, legacyFile, legacyTrashed]
        try legacyRepo.insert(legacyRecords, isPro: false, allowDuplicate: true)
        let sharedRoot = try SharedStorage.prepare(group: root.appendingPathComponent("group"), legacy: legacyRoot)
        let migrated = try CollectionRepository(url: sharedRoot.appendingPathComponent("collections.sqlite"))
        func byID(_ records: [CollectionRecord]) -> [UUID: CollectionRecord] {
            Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        }
        check(try byID(migrated.all()) == byID(legacyRecords))
        let migratedAssets = try AttachmentStore(root: sharedRoot)
        check(try Data(contentsOf: migratedAssets.url(for: legacyReference)) == legacyBytes)
        check(try Data(contentsOf: legacyAssets.url(for: legacyReference)) == legacyBytes)
        check(try FileManager.default.contentsOfDirectory(atPath: sharedRoot.appendingPathComponent("assets").path) == [legacyReference.id.uuidString])
        try migrated.checkIntegrity()
        try migrated.update(id: legacyRecord.id) { $0.deletedAt = Date() }
        let afterLocalDelete = try migrated.all()
        _ = try SharedStorage.prepare(group: root.appendingPathComponent("group"), legacy: legacyRoot)
        check(try byID(migrated.all()) == byID(afterLocalDelete))
        check(try migrated.all().first(where: { $0.id == legacyRecord.id })?.deletedAt != nil)
        check(try byID(legacyRepo.all()) == byID(legacyRecords))
        check(try Data(contentsOf: legacyAssets.url(for: legacyReference)) == legacyBytes)
        check(try Data(contentsOf: migratedAssets.url(for: legacyReference)) == legacyBytes)
        print("PASS: persistence, cross-process/concurrent quota, archive/star count, trash, restore quota, search, backup overage/idempotency/conflicts/rollback, version, URL normalization, attachment independence/path safety")
        print("PASS: legacy WAL migration preserves every field, archived/starred/trash state and shared attachment bytes; original database/assets retained; marker prevents resurrection")
        let batchRepo = try CollectionRepository(url: root.appendingPathComponent("batch.sqlite"))
        let batchRecords = (0..<3).map { CollectionRecord(kind: .text, title: "批量\($0)") }
        try batchRepo.insert(batchRecords, isPro: false)
        let ids = Set(batchRecords.map(\.id))
        try batchRepo.batch(ids: ids, action: .star(true))
        try batchRepo.batch(ids: ids, action: .archive(true))
        check(try batchRepo.all().allSatisfy { $0.starred && $0.archivedAt != nil && $0.version == 3 })
        try batchRepo.batch(ids: ids, action: .archive(false))
        check(try batchRepo.all().allSatisfy { $0.starred && $0.archivedAt == nil && $0.version == 4 })
        check(try Set(batchRepo.search(CollectionQuery(scope: .inbox)).map(\.id)) == ids)
        try batchRepo.batch(ids: ids, action: .archive(true))
        do { try batchRepo.batch(ids: ids.union([UUID()]), action: .trash); fatalError("stale batch accepted") }
        catch CollectionError.conflict { }
        check(try batchRepo.all().allSatisfy { $0.deletedAt == nil })
        do { _ = try batchRepo.permanentlyDelete(ids: ids); fatalError("active selection accepted") }
        catch CollectionError.conflict { }
        check(try batchRepo.all().count == 3)
        try batchRepo.batch(ids: ids, action: .trash)
        let beforeStale = try batchRepo.all()
        do { try batchRepo.restore(ids: ids.union([UUID()]), isPro: true); fatalError("partial stale restore accepted") }
        catch CollectionError.conflict { }
        do { _ = try batchRepo.permanentlyDelete(ids: ids.union([UUID()])); fatalError("partial stale deletion accepted") }
        catch CollectionError.conflict { }
        check(try batchRepo.all() == beforeStale)
        _ = try batchRepo.permanentlyDelete(ids: ids)
        check(try batchRepo.all().isEmpty)
        print("PASS: atomic batch state/version, stale selection rollback, permanent delete restricted to trash")
        print("Isolated fixture: \(root.path)")
    }
}
