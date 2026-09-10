import Foundation
import Darwin
import SQLite3

@main struct OrphanChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "child" {
            let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let assets = try AttachmentStore(root: root)
            let lease = try assets.beginImport()
            let copied = try assets.importFile(root.appendingPathComponent("source.txt"), contentType: "public.plain-text")
            try Data("partial".utf8).write(to: root.appendingPathComponent("assets/.\(UUID()).partial"))
            try Data(copied.relativePath.utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
            withExtendedLifetime(lease) { Thread.sleep(forTimeInterval: 10) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-orphan-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("retained content".utf8).write(to: source)
        let assets = try AttachmentStore(root: root)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let reference = try assets.importFile(source, contentType: "public.plain-text")
        var record = CollectionRecord(kind: .file, title: "Trashed but recoverable")
        record.attachments = [reference]
        record.deletedAt = Date()
        try repository.insert([record], isPro: true)
        let unknown = root.appendingPathComponent("assets/user-note.txt")
        try Data("unknown: do not delete".utf8).write(to: unknown)
        let symlink = root.appendingPathComponent("assets/\(UUID())")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["child", root.path]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: ready.path) else { throw CollectionError.invalid("Child never reached copied-but-uncommitted state") }
        let pending = root.appendingPathComponent(try String(contentsOf: ready, encoding: .utf8))
        let whileLive = try assets.reclaimOrphans(repository: repository)
        guard whileLive == nil, FileManager.default.fileExists(atPath: pending.path) else { throw CollectionError.invalid("Live importer was not protected") }
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let count = try assets.reclaimOrphans(repository: repository)
        precondition(count == 2, "Only crash copy and partial file should be reclaimed")
        precondition(!FileManager.default.fileExists(atPath: pending.path))
        let retained = try assets.url(for: reference)
        precondition(FileManager.default.fileExists(atPath: retained.path), "Trash attachments remain recoverable")
        precondition(FileManager.default.fileExists(atPath: unknown.path))
        precondition(FileManager.default.fileExists(atPath: symlink.path))
        let again = try assets.reclaimOrphans(repository: repository)
        precondition(again == 0, "Cleanup is idempotent")
        let undecidable = try assets.importFile(source, contentType: "public.plain-text")
        var database: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("collections.sqlite").path, &database) == SQLITE_OK else { throw CollectionError.invalid("Test database unavailable") }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "UPDATE records SET payload = X'00'", nil, nil, nil) == SQLITE_OK else { throw CollectionError.invalid("Unable to inject corrupt test record") }
        do { _ = try assets.reclaimOrphans(repository: repository); fatalError("Invalid record must stop reclamation") }
        catch { }
        let undecidableURL = try assets.url(for: undecidable)
        precondition(FileManager.default.fileExists(atPath: undecidableURL.path), "Unreadable references must never mean empty library")
        let missingGroup = root.appendingPathComponent("missing-db", isDirectory: true)
        let missingRoot = missingGroup.appendingPathComponent("Kexun", isDirectory: true)
        let stranded = try AttachmentStore(root: missingRoot)
        let strandedReference = try stranded.importFile(source, contentType: "public.plain-text")
        do { _ = try SharedStorage.prepare(group: missingGroup); fatalError("Missing DB with assets must not become an empty library") }
        catch { }
        let strandedURL = try stranded.url(for: strandedReference)
        precondition(FileManager.default.fileExists(atPath: strandedURL.path))
        precondition(!FileManager.default.fileExists(atPath: missingRoot.appendingPathComponent("collections.sqlite").path))
        print("PASS: live import protected; SIGKILL releases lease; orphan/partial reclaimed; trash/unknown/symlink retained; corrupt and missing database stop cleanup")
    }
}
