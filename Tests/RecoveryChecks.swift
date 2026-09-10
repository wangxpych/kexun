import Foundation
import Darwin

@main struct RecoveryChecks {
    static func main() throws {
        if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "interrupt-child" {
            let phase = CommandLine.arguments[2]
            let group = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
            let archive = URL(fileURLWithPath: CommandLine.arguments[4])
            let candidate = try RecoveryArchive.stage(archive, group: group)
            if phase == "after" { try SharedStorage.publishRecovery(group: group, generation: candidate.generation) }
            try JSONEncoder().encode(candidate).write(to: group.appendingPathComponent("child-ready.json"), options: .atomic)
            while true { pause() }
        }
        let manager = FileManager.default
        let fixture = manager.temporaryDirectory.appendingPathComponent("kexun-recovery-check-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: fixture) }
        let group = fixture.appendingPathComponent("group", isDirectory: true)
        let original = try SharedStorage.prepare(group: group)
        let damaged = Data("Unreadable original database: retain exactly".utf8)
        try damaged.write(to: original.appendingPathComponent("collections.sqlite"))
        let oldAssets = try AttachmentStore(root: original)
        let raw = fixture.appendingPathComponent("old.txt")
        try Data("old attachment retained".utf8).write(to: raw)
        let oldReference = try oldAssets.importFile(raw, contentType: "public.plain-text")
        let archive = try makeBackup(fixture)
        defer { try? manager.removeItem(at: archive.deletingLastPathComponent()) }
        let candidate = try RecoveryArchive.stage(archive, group: group)
        precondition(candidate.itemCount == 102)
        // Staging (or dying before publication) must not change which root is opened.
        let before = try SharedStorage.prepare(group: group)
        precondition(before == original)
        guard try Data(contentsOf: original.appendingPathComponent("collections.sqlite")) == damaged else { fatalError("Old database changed") }
        do {
            let active = try SharedStorage.session(group: group)
            do { try SharedStorage.publishRecovery(group: group, generation: candidate.generation); fatalError("Published with live session") }
            catch CollectionError.database { }
            withExtendedLifetime(active) {}
        }
        try SharedStorage.publishRecovery(group: group, generation: candidate.generation)
        let resumed = try SharedStorage.session(group: group)
        let database = try CollectionRepository(url: resumed.root.appendingPathComponent("collections.sqlite"), storageLease: resumed)
        let records = try database.all()
        precondition(records.count == 102)
        precondition(records.filter { $0.deletedAt != nil }.count == 1)
        precondition(records.filter { $0.archivedAt != nil && $0.starred }.count == 1)
        guard try Data(contentsOf: original.appendingPathComponent("collections.sqlite")) == damaged else { fatalError("Old database not retained") }
        let retainedURL = try oldAssets.url(for: oldReference)
        precondition(manager.fileExists(atPath: retainedURL.path))
        print("PASS: independent complete 102-record recovery; staging leaves old root active; live sessions prevent publication; reopen reads chosen generation; old database/assets retained")

        let badGroup = fixture.appendingPathComponent("bad-group", isDirectory: true)
        let badRoot = try SharedStorage.prepare(group: badGroup)
        try Data("{broken".utf8).write(to: badGroup.appendingPathComponent("active-storage.json"))
        do { _ = try SharedStorage.prepare(group: badGroup); fatalError("Invalid pointer fell back") } catch { }
        precondition(!manager.fileExists(atPath: badRoot.appendingPathComponent("collections.sqlite").path))
        let invalid = fixture.appendingPathComponent("invalid.zip")
        try Data("not a backup".utf8).write(to: invalid)
        do { _ = try RecoveryArchive.stage(invalid, group: badGroup); fatalError("Accepted invalid backup") } catch { }
        guard try String(contentsOf: badGroup.appendingPathComponent("active-storage.json"), encoding: .utf8) == "{broken" else { fatalError("Invalid backup changed pointer") }
        print("PASS: invalid pointer never falls back to an empty library; invalid backup does not publish")

        for fault in ["empty-database", "bad-marker", "wrong-generation", "wrong-count"] {
            let test = try RecoveryArchive.stage(archive, group: badGroup)
            let root = SharedStorage.recoveryRoot(group: badGroup, generation: test.generation)
            switch fault {
            case "empty-database": try Data().write(to: root.appendingPathComponent("collections.sqlite"))
            case "bad-marker": try Data("broken".utf8).write(to: root.appendingPathComponent("recovery-ready.json"))
            default:
                let changed = RecoveryArchive.Candidate(generation: fault == "wrong-generation" ? UUID() : test.generation, itemCount: fault == "wrong-count" ? 999 : test.itemCount)
                try JSONEncoder().encode(changed).write(to: root.appendingPathComponent("recovery-ready.json"))
            }
            do { try SharedStorage.publishRecovery(group: badGroup, generation: test.generation); fatalError("Published \(fault)") } catch { }
            guard try String(contentsOf: badGroup.appendingPathComponent("active-storage.json"), encoding: .utf8) == "{broken" else { fatalError("Fault changed pointer") }
        }
        let linkedGroup = fixture.appendingPathComponent("linked-group", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try manager.createDirectory(at: linkedGroup, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: linkedGroup.appendingPathComponent("recovery-generations"), withDestinationURL: outside)
        do { _ = try RecoveryArchive.stage(archive, group: linkedGroup); fatalError("Staged through symlink") } catch { }
        let outsideFiles = try manager.contentsOfDirectory(atPath: outside.path)
        precondition(outsideFiles.isEmpty)
        print("PASS: empty database, invalid/mismatched ready marker and count rejected without pointer change; staging symlink rejected before external write")
        try interruptedRecovery(phase: "before", archive: archive, fixture: fixture)
        try interruptedRecovery(phase: "after", archive: archive, fixture: fixture)
    }

    static func interruptedRecovery(phase: String, archive: URL, fixture: URL) throws {
        let manager = FileManager.default
        let group = fixture.appendingPathComponent("interrupt-\(phase)", isDirectory: true)
        let original = try SharedStorage.prepare(group: group)
        let damaged = Data("original damaged database retained across SIGKILL".utf8)
        try damaged.write(to: original.appendingPathComponent("collections.sqlite"))
        let sentinel = original.appendingPathComponent("retained.txt")
        try damaged.write(to: sentinel)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["interrupt-child", phase, group.path, archive.path]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let ready = group.appendingPathComponent("child-ready.json")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !manager.fileExists(atPath: ready.path), child.isRunning, ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        guard manager.fileExists(atPath: ready.path), child.isRunning else { fatalError("Child did not reach \(phase) publication boundary") }
        let candidate = try JSONDecoder().decode(RecoveryArchive.Candidate.self, from: Data(contentsOf: ready))
        guard kill(child.processIdentifier, SIGKILL) == 0 else { fatalError("Unable to interrupt test child") }
        child.waitUntilExit()
        precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
        let reopened = try SharedStorage.session(group: group)
        if phase == "before" {
            precondition(reopened.root == original, "Unpublished candidates must never be auto-selected")
            precondition(!manager.fileExists(atPath: group.appendingPathComponent("active-storage.json").path))
        } else {
            precondition(reopened.root == SharedStorage.recoveryRoot(group: group, generation: candidate.generation))
            let repository = try CollectionRepository(url: reopened.root.appendingPathComponent("collections.sqlite"), storageLease: reopened)
            let records = try repository.all()
            precondition(records.count == 102)
            let assets = try AttachmentStore(root: reopened.root, storageLease: reopened)
            guard let reference = records.flatMap(\.attachments).first else { fatalError("Recovered attachment missing") }
            let restored = try Data(contentsOf: assets.url(for: reference))
            precondition(restored == Data("recovered attachment".utf8))
        }
        guard try Data(contentsOf: original.appendingPathComponent("collections.sqlite")) == damaged,
              try Data(contentsOf: sentinel) == damaged else { fatalError("SIGKILL changed original files") }
        print("PASS: actual child SIGKILL \(phase) publication; restart selects correct root; original bytes retained")
    }

    static func makeBackup(_ fixture: URL) throws -> URL {
        let root = fixture.appendingPathComponent("source", isDirectory: true)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: root)
        var records = (0..<102).map { CollectionRecord(kind: .text, title: "恢复内容 \($0)") }
        records[0].deletedAt = Date()
        records[1].archivedAt = Date()
        records[1].starred = true
        let file = fixture.appendingPathComponent("source.txt")
        try Data("recovered attachment".utf8).write(to: file)
        records[1].attachments = [try assets.importFile(file, contentType: "public.plain-text")]
        try repository.insert(records, isPro: true)
        return try BackupArchive.exportFile(repository: repository, assets: assets)
    }
}
