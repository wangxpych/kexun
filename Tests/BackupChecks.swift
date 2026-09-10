import Foundation

@main
struct BackupChecks {
    static func check(_ value: Bool) { precondition(value) }
    static func main() throws {
        try checkCompleteRecordMatrix()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-backup-checks-\(UUID())")
        let source = try CollectionRepository(url: root.appendingPathComponent("source/db.sqlite"))
        let assets = try AttachmentStore(root: root.appendingPathComponent("source"))
        let file = root.appendingPathComponent("文档.txt")
        try Data("完整附件".utf8).write(to: file)
        let reference = try assets.importFile(file, contentType: "public.plain-text")
        var record = CollectionRecord(kind: .file, title: "测试附件")
        record.attachments = [reference]; record.starred = true; record.archivedAt = Date()
        try source.insert([record] + (0..<110).map { CollectionRecord(kind: .text, title: "备份\($0)") }, isPro: true)
        let archive = try BackupArchive.export(repository: source, assets: assets)
        let archiveURL = root.appendingPathComponent("kexun-backup.zip")
        try archive.write(to: archiveURL)
        let target = try CollectionRepository(url: root.appendingPathComponent("target/db.sqlite"))
        let targetAssets = try AttachmentStore(root: root.appendingPathComponent("target"))
        check(try BackupArchive.restore(archive, repository: target, assets: targetAssets) == 111)
        check(try BackupArchive.restore(archive, repository: target, assets: targetAssets) == 0)
        check(try Set(target.all().map(\.id)) == Set(source.all().map(\.id)))
        check(try Data(contentsOf: targetAssets.url(for: reference)) == Data("完整附件".utf8))
        let reporting = try CollectionRepository(url: root.appendingPathComponent("reporting/db.sqlite"))
        let reportingAssets = try AttachmentStore(root: root.appendingPathComponent("reporting"))
        let texts = try source.all().filter { $0.kind == .text }
        var locallyEdited = texts[0]
        locallyEdited.note = "Keep this local edit"
        try reporting.insert([locallyEdited, texts[1]], isPro: true)
        let report = try BackupArchive.restoreFileReport(archiveURL, repository: reporting, assets: reportingAssets)
        check(report == BackupMergeReport(inserted: 109, conflicts: 1, skipped: 1))
        check(report.added == 110 && report.processed == 111)
        check(report.message.contains("冲突保留 1 条") && report.message.contains("跳过 1 条"))
        check(try reporting.all().first { $0.id == locallyEdited.id } == locallyEdited)
        let repeated = try BackupArchive.restoreFileReport(archiveURL, repository: reporting, assets: reportingAssets)
        check(repeated == BackupMergeReport(inserted: 0, conflicts: 0, skipped: 111))
        check(try reporting.all().count == 112)
        print("PASS: restore report counts new/conflicting/skipped records accurately; repeated conflicts skip without overwriting local edits")
        var broken = archive
        broken[45] ^= 0xff
        do { _ = try BackupArchive.restore(broken, repository: target, assets: targetAssets); fatalError("corruption accepted") } catch { }
        check(try target.all().count == 111)
        let traversal = try StoredZIP.encode([("../escape", Data())])
        do { _ = try StoredZIP.decode(traversal); fatalError("traversal accepted") } catch { }
        func rejectStream(_ data: Data) throws {
            let input = root.appendingPathComponent("malicious.zip")
            let output = root.appendingPathComponent("malicious-\(UUID())")
            try data.write(to: input)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            do { _ = try StreamingZIP.decode(input, into: output); fatalError("malicious ZIP accepted") } catch { }
        }
        try rejectStream(traversal)
        var overlapping = try StoredZIP.encode([("a", Data([1])), ("b", Data([2]))])
        let central = (0..<4).reduce(0) { $0 | Int(overlapping[overlapping.count - 6 + $1]) << (8 * $1) }
        for index in 0..<4 { overlapping[central + 47 + 42 + index] = 0 }
        try rejectStream(overlapping)
        var compressed = try StoredZIP.encode([("a", Data([1]))])
        compressed[8] = 8
        compressed[32 + 10] = 8
        try rejectStream(compressed)
        var forged = try StoredZIP.decode(archive)
        var manifest = try JSONDecoder().decode(BackupArchive.Manifest.self, from: forged["manifest.json"]!)
        manifest.checksums["items.json"] = String(repeating: "0", count: 64)
        forged["manifest.json"] = try JSONEncoder().encode(manifest)
        let forgedArchive = try StoredZIP.encode(forged.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
        do { _ = try BackupArchive.restore(forgedArchive, repository: target, assets: targetAssets); fatalError("SHA mismatch accepted") } catch { }
        check(try target.all().count == 111)
        print("PASS: streaming traversal, overlap, compressed payload, and valid-CRC/invalid-SHA rejected")
        let recordID = record.id
        for _ in 0..<3 {
            try target.batch(ids: [recordID], action: .trash)
            let tasks = DispatchGroup()
            tasks.enter()
            DispatchQueue.global().async {
                defer { tasks.leave() }
                do {
                    try targetAssets.withExclusiveAccess {
                        let candidates = try target.permanentlyDelete(ids: [recordID])
                        try targetAssets.removeUnreferenced(candidates, keeping: target.all())
                    }
                } catch CollectionError.conflict {
                    // A competing restore can change the selected record before deletion starts.
                } catch { fatalError("delete failure: \(error)") }
            }
            tasks.enter()
            DispatchQueue.global().async {
                defer { tasks.leave() }
                do { _ = try BackupArchive.restore(archive, repository: target, assets: targetAssets) }
                catch { fatalError("restore failure: \(error)") }
            }
            tasks.wait()
            for restored in try target.all() {
                for attachment in restored.attachments { check(FileManager.default.fileExists(atPath: try targetAssets.url(for: attachment).path)) }
            }
            _ = try BackupArchive.restore(archive, repository: target, assets: targetAssets)
        }
        print("PASS: concurrent restore and permanent delete preserve all referenced attachments")
        let conflict = try CollectionRepository(url: root.appendingPathComponent("conflict/db.sqlite"))
        let conflictAssets = try AttachmentStore(root: root.appendingPathComponent("conflict"))
        let different = Data("different existing attachment".utf8)
        try different.write(to: conflictAssets.url(for: reference))
        var existing = record
        existing.attachments[0].byteCount = Int64(different.count)
        existing.attachments[0].sha256 = BackupArchive.digest(different)
        try conflict.insert([existing], isPro: false)
        check(try BackupArchive.restore(archive, repository: conflict, assets: conflictAssets) == 111)
        check(try BackupArchive.restore(archive, repository: conflict, assets: conflictAssets) == 0)
        check(try conflict.all().count == 112)
        check(try Data(contentsOf: conflictAssets.url(for: reference)) == different)
        for value in try conflict.all().flatMap(\.attachments) {
            check(try StreamingZIP.inspect(conflictAssets.url(for: value)).sha == value.sha256)
        }
        print("PASS: conflicting attachment ID remapped without overwrite; repeated restore idempotent")

        // A real 288 MiB library, larger than the removed in-memory UI limit.
        let largeRepository = try CollectionRepository(url: root.appendingPathComponent("large/db.sqlite"))
        let largeAssets = try AttachmentStore(root: root.appendingPathComponent("large"))
        let largeFile = root.appendingPathComponent("large.bin")
        check(FileManager.default.createFile(atPath: largeFile.path, contents: nil))
        let writer = try FileHandle(forWritingTo: largeFile)
        let chunk = Data(repeating: 0x6b, count: 1024 * 1024)
        for _ in 0..<96 { try writer.write(contentsOf: chunk) }
        try writer.close()
        var largeRecords: [CollectionRecord] = []
        for index in 0..<3 {
            var value = CollectionRecord(kind: .file, title: "Large \(index)")
            value.attachments = [try largeAssets.importFile(largeFile, contentType: "public.data")]
            largeRecords.append(value)
        }
        try largeRepository.insert(largeRecords, isPro: false)
        let largeZIP = try BackupArchive.exportFile(repository: largeRepository, assets: largeAssets)
        check(try largeZIP.resourceValues(forKeys: [.fileSizeKey]).fileSize! > 256 * 1024 * 1024)
        let largeTarget = try CollectionRepository(url: root.appendingPathComponent("large-target/db.sqlite"))
        let largeTargetAssets = try AttachmentStore(root: root.appendingPathComponent("large-target"))
        check(try BackupArchive.restoreFile(largeZIP, repository: largeTarget, assets: largeTargetAssets) == 3)
        for value in try largeTarget.all().flatMap(\.attachments) {
            check(try StreamingZIP.inspect(largeTargetAssets.url(for: value)).sha == value.sha256)
        }
        print("PASS: 288 MiB file-stream export and restore with CRC and SHA validation")
        print("LARGE ZIP: \(largeZIP.path)")
        print("PASS: ZIP roundtrip with 111 records and attachment, repeat import, corruption rejection, path traversal rejection")
        print(archiveURL.path)
    }

    static func checkCompleteRecordMatrix() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("kexun-backup-matrix-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let source = try CollectionRepository(url: root.appendingPathComponent("source/db.sqlite"))
        let assets = try AttachmentStore(root: root.appendingPathComponent("source"))
        let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aVZkAAAAASUVORK5CYII=")!
        let fileBytes = Data("完整文件正文\nSecond line\t原始附件\n".utf8)
        let imageURL = root.appendingPathComponent("原图.png")
        let fileURL = root.appendingPathComponent("原文件.txt")
        try imageBytes.write(to: imageURL)
        try fileBytes.write(to: fileURL)
        let imageReference = try assets.importFile(imageURL, contentType: "public.png")
        let fileReference = try assets.importFile(fileURL, contentType: "public.plain-text")
        let states: [ProcessingState] = [.pending, .processing, .complete, .failed, .unsupported]
        var records: [CollectionRecord] = []
        for (kindIndex, kind) in ContentKind.allCases.enumerated() {
            for (stateIndex, state) in states.enumerated() {
                let offset = kindIndex * states.count + stateIndex
                let created = Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
                var record = CollectionRecord(kind: kind, title: "完整字段 \(kind.rawValue) \(state.rawValue)")
                record.createdAt = created
                record.updatedAt = created.addingTimeInterval(60)
                record.deletedAt = stateIndex >= 3 ? created.addingTimeInterval(50) : nil
                record.archivedAt = stateIndex == 1 || stateIndex == 4 ? created.addingTimeInterval(40) : nil
                record.version = offset + 2
                record.body = "原始分享正文\nhttps://example.com/\(offset)?keep=1&value=中文\n尾行 😀"
                record.originalURL = kind == .link ? "https://example.com/\(offset)?keep=1&value=中文" : nil
                record.source = "来源 \(kind.rawValue)"
                record.note = "备注\n保留空格  与换行 \(offset)"
                record.starred = stateIndex.isMultiple(of: 2)
                record.titleEdited = stateIndex.isMultiple(of: 2)
                record.attachments = kind == .link || kind == .image ? [imageReference] : kind == .file ? [fileReference] : []
                record.extractedText = "提取正文 OCR / PDF \(offset)"
                record.processingState = state
                record.processingError = state == .failed ? "测试处理失败：保留原文" : nil
                records.append(record)
            }
        }
        try source.insert(records, isPro: false)
        let expected = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        check(try Dictionary(uniqueKeysWithValues: source.all().map { ($0.id, $0) }) == expected)
        let archive = try BackupArchive.exportFile(repository: source, assets: assets)
        defer { try? manager.removeItem(at: archive.deletingLastPathComponent()) }
        check(archive.lastPathComponent == "kexun-backup.zip")
        // The archive must remain self-contained after both original inputs and source assets disappear.
        try manager.removeItem(at: imageURL)
        try manager.removeItem(at: fileURL)
        try manager.removeItem(at: assets.url(for: imageReference))
        try manager.removeItem(at: assets.url(for: fileReference))
        let destinationURL = root.appendingPathComponent("destination/db.sqlite")
        let destination = try CollectionRepository(url: destinationURL)
        let destinationAssets = try AttachmentStore(root: root.appendingPathComponent("destination"))
        check(try destination.all().isEmpty)
        check(try BackupArchive.restoreFileReport(archive, repository: destination, assets: destinationAssets)
              == BackupMergeReport(inserted: records.count, conflicts: 0, skipped: 0))
        let reopened = try CollectionRepository(url: destinationURL)
        check(try Dictionary(uniqueKeysWithValues: reopened.all().map { ($0.id, $0) }) == expected)
        for (reference, bytes) in [(imageReference, imageBytes), (fileReference, fileBytes)] {
            let restored = try destinationAssets.url(for: reference)
            check(try Data(contentsOf: restored) == bytes)
            let inspected = try StreamingZIP.inspect(restored)
            check(inspected.sha == reference.sha256 && inspected.size == UInt64(reference.byteCount))
        }
        func assetSnapshot() throws -> [String: Data] {
            let directory = root.appendingPathComponent("destination/assets")
            return try Dictionary(uniqueKeysWithValues: manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let beforeAssets = try assetSnapshot()
        check(try BackupArchive.restoreFileReport(archive, repository: destination, assets: destinationAssets)
              == BackupMergeReport(inserted: 0, conflicts: 0, skipped: records.count))
        check(try Dictionary(uniqueKeysWithValues: reopened.all().map { ($0.id, $0) }) == expected)
        check(try assetSnapshot() == beforeAssets)
        // Recompute ZIP CRC while leaving the manifest SHA stale: this reaches content validation.
        var entries = try StoredZIP.decode(Data(contentsOf: archive))
        entries["items.json"]!.append(0x20)
        let corrupted = root.appendingPathComponent("bad-content.zip")
        try StoredZIP.encode(entries.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }).write(to: corrupted)
        do {
            _ = try BackupArchive.restoreFileReport(corrupted, repository: destination, assets: destinationAssets)
            fatalError("Corrupt full-field backup accepted")
        } catch CollectionError.invalid { }
        check(try Dictionary(uniqueKeysWithValues: reopened.all().map { ($0.id, $0) }) == expected)
        check(try assetSnapshot() == beforeAssets)
        try reopened.checkIntegrity()
        print("PASS: all four kinds and five processing states preserve every record field in a new reopened library; archived/starred/trash states and shared PNG/file bytes/SHA survive source removal; repeat import skips all 20 records; invalid SHA leaves complete records and asset inventory unchanged")
    }
}
