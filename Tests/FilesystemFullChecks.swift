import Foundation
import Darwin
import SQLite3

/// Standalone macOS integration check. Requires a separately mounted, <=64 MiB
/// disposable filesystem under /private/tmp/kexun-enospc.*/mount. Never fills a
/// workspace, a simulator container, or the host volume.
@main struct FilesystemFullChecks {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }

    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { fatalError("Pass the isolated mount path") }
        let mount = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let resolved = mount.resolvingSymlinksInPath()
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp").standardizedFileURL
        guard resolved.path == mount.path,
              mount.lastPathComponent == "mount",
              mount.deletingLastPathComponent().lastPathComponent.hasPrefix("kexun-enospc."),
              mount.deletingLastPathComponent().deletingLastPathComponent().path == temporaryRoot.path else {
            fatalError("Refusing an unexpected or symlinked mount path")
        }
        let capacity = try mount.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity ?? 0
        guard capacity > 8 * 1024 * 1024, capacity <= 64 * 1024 * 1024 else {
            fatalError("Refusing filesystem capacity \(capacity); only a bounded disposable volume is allowed")
        }
        let root = mount.appendingPathComponent("check-\(UUID())")
        let sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KexunENOSPCSource-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sourceRoot)
        }
        print("Bounded filesystem capacity: \(capacity); fixture: \(root.path)")
        let expected = try exercise(root: root, sourceRoot: sourceRoot)
        // All writer connections from exercise() have closed. Verify a fresh open.
        let reopened = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        try reopened.checkIntegrity()
        check(try reopened.all().sorted { $0.id.uuidString < $1.id.uuidString } == expected.sorted { $0.id.uuidString < $1.id.uuidString },
              "Fresh reopen did not preserve final records")
        print("PASS: close/reopen preserves all records after real ENOSPC recovery")
        try exerciseBackup(root: root, sourceRoot: sourceRoot)
    }

    static func exerciseBackup(root: URL, sourceRoot: URL) throws {
        let fm = FileManager.default
        let sourceStoreRoot = sourceRoot.appendingPathComponent("backup-source")
        let sourceRepository = try CollectionRepository(url: sourceStoreRoot.appendingPathComponent("collections.sqlite"))
        let sourceAssets = try AttachmentStore(root: sourceStoreRoot)
        let sourceBytes = Data(repeating: 0x6B, count: 3 * 1024 * 1024)
        let sourceFile = sourceRoot.appendingPathComponent("backup-source.bin")
        try sourceBytes.write(to: sourceFile)
        let reference = try sourceAssets.importFile(sourceFile, contentType: "public.data")
        var incoming = CollectionRecord(kind: .file, title: "Backup survives full filesystem", body: "Backup body")
        incoming.attachments = [reference]
        incoming.starred = true
        incoming.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        incoming.note = "Preserve every field and attachment"
        try sourceRepository.insert([incoming], isPro: false)
        let temporaryRoot = root.appendingPathComponent("export-temp")
        try fm.createDirectory(at: temporaryRoot, withIntermediateDirectories: false)
        let archive = sourceRoot.appendingPathComponent("backup-final.zip")
        let filler = root.appendingPathComponent("backup-filler.bin")
        try fillLeaving(filler, bytes: 1024 * 1024)
        try attemptExport(repository: sourceRepository, assets: sourceAssets, destination: archive, temporaryRoot: temporaryRoot, expectFailure: true)
        check(!fm.fileExists(atPath: archive.path), "Failed export published a backup")
        check(try fm.contentsOfDirectory(atPath: temporaryRoot.path).isEmpty, "Failed export left a partial archive directory")
        check(try sourceRepository.all() == [incoming], "Failed export changed source records")
        check(try Data(contentsOf: sourceAssets.url(for: reference)) == sourceBytes, "Failed export changed source bytes")
        try fm.removeItem(at: filler)
        try attemptExport(repository: sourceRepository, assets: sourceAssets, destination: archive, temporaryRoot: temporaryRoot, expectFailure: false)
        let archiveInfo = try StreamingZIP.inspect(archive)
        check(archiveInfo.size > UInt64(sourceBytes.count), "Retried archive is incomplete")
        print("PASS: backup export hits real temporary-volume ENOSPC, cleans partial archive, preserves source, and retries")

        let targetRoot = root.appendingPathComponent("restore-target")
        let targetRepository = try CollectionRepository(url: targetRoot.appendingPathComponent("collections.sqlite"))
        let targetAssets = try AttachmentStore(root: targetRoot)
        try targetAssets.withExclusiveAccess { }
        let existingBytes = Data("Keep existing target attachment".utf8)
        let existingSource = sourceRoot.appendingPathComponent("target-original.txt")
        try existingBytes.write(to: existingSource)
        let existingReference = try targetAssets.importFile(existingSource, contentType: "public.plain-text")
        var existing = CollectionRecord(kind: .file, title: "Existing target record", body: "Do not overwrite")
        existing.attachments = [existingReference]
        existing.starred = true
        try targetRepository.insert([existing], isPro: false)
        let names = try assetNames(targetRoot)
        try fillLeaving(filler, bytes: 1024 * 1024)
        do {
            _ = try BackupArchive.restoreFileReport(archive, repository: targetRepository, assets: targetAssets, temporaryRoot: temporaryRoot)
            fatalError("Backup decode unexpectedly succeeded on full temporary filesystem")
        } catch {
            check(isOutOfSpace(error as NSError), "Expected restore temporary-volume ENOSPC, got \(error)")
            print("Actual backup decode failure: \(error)")
        }
        check(try fm.contentsOfDirectory(atPath: temporaryRoot.path).isEmpty, "Failed decode left partial temporary files")
        check(try targetRepository.all() == [existing] && assetNames(targetRoot) == names, "Failed decode changed target")
        try fm.removeItem(at: filler)
        print("PASS: backup decode temporary ENOSPC cleans extracted partials without changing target")
        try fillLeaving(filler, bytes: 512 * 1024)
        do {
            _ = try BackupArchive.restoreFileReport(archive, repository: targetRepository, assets: targetAssets)
            fatalError("Backup restore unexpectedly succeeded without space for its attachment")
        } catch {
            check(isOutOfSpace(error as NSError), "Expected actual restore ENOSPC, got \(error)")
            print("Actual backup restore failure: \(error)")
        }
        check(try targetRepository.all() == [existing], "Failed restore changed target records")
        check(try assetNames(targetRoot) == names, "Failed restore left a partial or unreferenced attachment")
        check(try Data(contentsOf: targetAssets.url(for: existingReference)) == existingBytes, "Failed restore changed old attachment")
        check(try StreamingZIP.inspect(archive).sha == archiveInfo.sha, "Failed restore changed backup archive")
        try fm.removeItem(at: filler)
        let restored = try BackupArchive.restoreFileReport(archive, repository: targetRepository, assets: targetAssets)
        check(restored == BackupMergeReport(inserted: 1, conflicts: 0, skipped: 0), "Restore retry did not import exactly one record")
        let repeated = try BackupArchive.restoreFileReport(archive, repository: targetRepository, assets: targetAssets)
        check(repeated == BackupMergeReport(inserted: 0, conflicts: 0, skipped: 1), "Restore retry was not idempotent")
        let records = try targetRepository.all()
        check(records.count == 2 && records.contains(existing) && records.contains(incoming), "Restore retry changed fields or duplicated records")
        check(try Data(contentsOf: targetAssets.url(for: reference)) == sourceBytes, "Restore retry changed incoming attachment bytes")
        try targetRepository.checkIntegrity()
        print("PASS: backup restore ENOSPC leaves old records/assets/archive intact, cleans partial copy, retries all bytes and skips repeat")
    }

    static func attemptExport(repository: CollectionRepository, assets: AttachmentStore,
                              destination: URL, temporaryRoot: URL, expectFailure: Bool) throws {
        do {
            let archive = try BackupArchive.exportFile(repository: repository, assets: assets, temporaryRoot: temporaryRoot)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            check(!expectFailure, "Backup export unexpectedly succeeded on full temporary filesystem")
            try FileManager.default.copyItem(at: archive, to: destination)
        } catch {
            check(expectFailure && isOutOfSpace(error as NSError), "Unexpected backup export failure: \(error)")
            print("Actual backup export failure: \(error)")
        }
    }

    static func fillLeaving(_ filler: URL, bytes: Int) throws {
        let filled = try fillToENOSPC(filler)
        check(filled > bytes, "Not enough independent free space for controlled test")
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(filled - bytes))
        try handle.close()
    }

    static func exercise(root: URL, sourceRoot: URL) throws -> [CollectionRecord] {
        let fm = FileManager.default
        let url = root.appendingPathComponent("collections.sqlite")
        let repository = try CollectionRepository(url: url)
        let assets = try AttachmentStore(root: root)
        try assets.withExclusiveAccess { } // Prime the real lifecycle lock before filling.
        let originalSource = sourceRoot.appendingPathComponent("original.txt")
        let originalBytes = Data("Existing attachment survives ENOSPC\n原始附件".utf8)
        try originalBytes.write(to: originalSource)
        let originalAttachment = try assets.importFile(originalSource, contentType: "public.plain-text")
        var original = CollectionRecord(kind: .file, title: "Existing archived and starred file",
                                        body: String(repeating: "A", count: 2 * 1024 * 1024))
        original.attachments = [originalAttachment]
        original.starred = true
        original.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        original.note = "Must not change on failed save"
        try repository.insert([original], isPro: false)
        let source = sourceRoot.appendingPathComponent("retry.bin")
        let sourceBytes = Data(repeating: 0x5A, count: 3 * 1024 * 1024)
        try sourceBytes.write(to: source)
        let filler = root.appendingPathComponent("bounded-filler.bin")

        let filled = try fillToENOSPC(filler)
        // Leave enough for file/lock bookkeeping but not the 3 MiB copy.
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(filled - 512 * 1024))
        try handle.close()
        let names = try assetNames(root)
        do {
            _ = try assets.importFile(source, contentType: "public.data")
            fatalError("Attachment copy unexpectedly succeeded on bounded full volume")
        } catch {
            check(isOutOfSpace(error as NSError), "Expected ENOSPC/Cocoa out-of-space from actual copy, got \(error)")
            print("Actual attachment failure: \(error)")
        }
        check(try assetNames(root) == names, "Failed copy left a partial or published asset")
        check(try repository.all() == [original], "Attachment failure changed existing records")
        check(try Data(contentsOf: assets.url(for: originalAttachment)) == originalBytes, "Existing attachment changed")
        check(try Data(contentsOf: source) == sourceBytes, "External source changed")
        try fm.removeItem(at: filler)
        let retried = try assets.importFile(source, contentType: "public.data")
        check(try Data(contentsOf: assets.url(for: retried)) == sourceBytes, "Attachment retry lost bytes")
        check(try assetNames(root) == names.union([retried.id.uuidString]), "Retry created extra files")
        var retriedRecord = CollectionRecord(kind: .file, title: "Recovered attachment")
        retriedRecord.attachments = [retried]
        try repository.insert([retriedRecord], isPro: false)
        print("PASS: actual attachment ENOSPC cleans partial file, preserves original and source, retries all 3 MiB")

        let before = try repository.all()
        var connection: OpaquePointer?
        check(sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, "Cannot open WAL probe")
        defer { sqlite3_close(connection) }
        // Opening SQLite is lazy: force this probe connection to discover the WAL
        // before requesting a checkpoint, otherwise the API can return a no-op.
        var mode: OpaquePointer?
        check(sqlite3_prepare_v2(connection, "PRAGMA journal_mode", -1, &mode, nil) == SQLITE_OK, "Cannot inspect journal mode")
        check(sqlite3_step(mode) == SQLITE_ROW, "Missing journal mode")
        check(String(cString: sqlite3_column_text(mode, 0)) == "wal", "Expected production WAL mode")
        sqlite3_finalize(mode)
        check(fm.fileExists(atPath: url.path + "-wal"), "Expected production WAL path")
        _ = try fillToENOSPC(filler)
        var total: Int32 = 0
        var checkpointed: Int32 = 0
        let checkpointFailure = sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_FULL, &total, &checkpointed)
        print("Database checkpoint result=\(checkpointFailure), frames=\(total), checkpointed=\(checkpointed)")
        check(checkpointFailure == SQLITE_FULL, "Expected actual database checkpoint SQLITE_FULL, got \(checkpointFailure)")
        check(try repository.all() == before, "Failed database checkpoint lost committed WAL records")
        print("PASS: database-file checkpoint returns SQLITE_FULL while committed WAL records remain readable")

        let small = CollectionRecord(kind: .text, title: "Atomic batch first item")
        let large = CollectionRecord(kind: .text, title: "Atomic batch large item", body: String(repeating: "B", count: 2 * 1024 * 1024))
        do {
            try repository.insert([small, large], isPro: false)
            fatalError("WAL batch unexpectedly succeeded with no filesystem space")
        } catch CollectionError.database(let message) {
            check(message.contains("full"), "Expected SQLite out-of-space, got \(message)")
            print("Actual repository WAL failure: \(message)")
        }
        check(try repository.all() == before, "Failed WAL batch partially changed records")
        do {
            try repository.update(id: original.id) { $0.body = String(repeating: "C", count: 3 * 1024 * 1024) }
            fatalError("WAL update unexpectedly succeeded with no filesystem space")
        } catch CollectionError.database(let message) {
            check(message.contains("full"), "Expected update SQLite out-of-space, got \(message)")
        }
        check(try repository.all() == before, "Failed WAL update changed version or fields")
        check(try Data(contentsOf: assets.url(for: originalAttachment)) == originalBytes, "Database failure changed attachment")
        try fm.removeItem(at: filler)
        check(sqlite3_wal_checkpoint_v2(connection, nil, SQLITE_CHECKPOINT_FULL, &total, &checkpointed) == SQLITE_OK,
              "Checkpoint retry failed after releasing space")
        try repository.insert([small, large], isPro: false)
        try repository.update(id: original.id) { $0.note = "Updated after releasing space" }
        try repository.checkIntegrity()
        let after = try repository.all()
        check(after.count == before.count + 2, "Retry duplicated or lost batch rows")
        check(after.filter { $0.id == small.id || $0.id == large.id }.count == 2, "Retry IDs differ")
        guard let restored = after.first(where: { $0.id == original.id }) else { fatalError("Original record disappeared") }
        var expectedOriginal = original
        expectedOriginal.note = restored.note
        expectedOriginal.version = restored.version
        expectedOriginal.updatedAt = restored.updatedAt
        check(restored == expectedOriginal && restored.note == "Updated after releasing space" && restored.version == original.version + 1,
              "Original fields/version changed beyond successful retry")
        print("PASS: actual WAL insert/update SQLITE_FULL roll back atomically; checkpoint, batch and edit retry after space release")
        return after
    }

    static func fillToENOSPC(_ url: URL) throws -> Int {
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(descriptor) }
        let buffer = Data(repeating: 0xD7, count: 64 * 1024)
        var written = 0
        while written < 64 * 1024 * 1024 {
            let result = buffer.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!, $0.count) }
            if result < 0 {
                let code = errno
                check(code == ENOSPC, "Expected real filesystem ENOSPC, got errno \(code)")
                print("Actual bounded write errno=ENOSPC (\(code)), filled \(written) bytes")
                return written
            }
            check(result > 0, "Unexpected zero-length write")
            written += result
        }
        fatalError("Safety cap reached without ENOSPC; refusing further writes")
    }

    static func assetNames(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path))
    }

    static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC) { return true }
        if error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isOutOfSpace(underlying) }
        return false
    }
}
