import Foundation
import Darwin

@main struct StorageLockChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "hold" {
            let group = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let descriptor = Darwin.open(group.appendingPathComponent("kexun-storage.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0, flock(descriptor, LOCK_EX) == 0 else { fatalError("Child lock failed") }
            defer { Darwin.close(descriptor) }
            try Data("ready".utf8).write(to: group.appendingPathComponent("ready"), options: .atomic)
            while true { pause() }
        }
        let group = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-storage-lock-check-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: group) }
        let root = try SharedStorage.prepare(group: group)
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let record = CollectionRecord(kind: .text, title: "Protected while another process owns storage")
        try repository.insert([record], isPro: false)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["hold", group.path]
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !FileManager.default.fileExists(atPath: group.appendingPathComponent("ready").path), ProcessInfo.processInfo.systemUptime < deadline {
            usleep(10_000)
        }
        guard FileManager.default.fileExists(atPath: group.appendingPathComponent("ready").path) else { fatalError("Child not ready") }
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try SharedStorage.prepare(group: group)
            fatalError("Busy storage must fail with a bounded retry error")
        } catch CollectionError.invalid(let message) {
            precondition(message.contains("稍后重试"))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed >= 4.9 && elapsed < 8, "Unexpected timeout: \(elapsed)")
        precondition(child.isRunning, "Must not kill the other process to resolve contention")
        guard try repository.all() == [record] else { fatalError("Content changed during contention") }
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let reopened = try SharedStorage.prepare(group: group)
        precondition(reopened == root)
        let reader = try CollectionRepository(url: reopened.appendingPathComponent("collections.sqlite"))
        guard try reader.all() == [record] else { fatalError("Content changed after retry") }
        print("PASS: storage contention bounded at \(elapsed)s; records preserved; process death releases lock; retry succeeds")

        var session: StorageSession? = try SharedStorage.session(group: group)
        var leasedRepository: CollectionRepository? = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"), storageLease: session)
        var leasedAssets: AttachmentStore? = try AttachmentStore(root: root, storageLease: session)
        // A second ordinary session must remain possible while the first is alive.
        do {
            let second = try SharedStorage.session(group: group)
            precondition(second.root == root)
            withExtendedLifetime(second) {}
        }
        session = nil
        try expectRecoveryBusy(group)
        guard try leasedRepository?.all() == [record] else { fatalError("Leased repository changed") }
        leasedRepository = nil
        try expectRecoveryBusy(group)
        precondition(leasedAssets?.root == root, "Attachment-only asynchronous users must retain the lease")
        leasedAssets = nil
        var entered = false
        try SharedStorage.withRecoveryAccess(group: group) { entered = true }
        precondition(entered)
        print("PASS: shared sessions coexist; repository and attachment lifetimes retain recovery exclusion; release allows recovery")
    }

    static func expectRecoveryBusy(_ group: URL) throws {
        var entered = false
        do {
            try SharedStorage.withRecoveryAccess(group: group) { entered = true }
            fatalError("Recovery entered with live storage users")
        } catch CollectionError.database(let message) {
            precondition(message.contains("仍在使用"))
        }
        precondition(!entered, "The replacement operation must never run while a lease survives")
    }
}
