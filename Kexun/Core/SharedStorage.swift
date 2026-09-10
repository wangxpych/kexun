import Foundation
import CryptoKit
import Darwin

/// Retained by both the database and attachment store, including asynchronous users.
nonisolated final class StorageSession: Sendable {
    let root: URL
    private let lease: StorageGenerationLease

    fileprivate init(root: URL, lease: StorageGenerationLease) {
        self.root = root
        self.lease = lease
    }
}

nonisolated private final class StorageGenerationLease: Sendable {
    private let descriptor: Int32

    init(group: URL, exclusive: Bool) throws {
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let opened = Darwin.open(group.appendingPathComponent("kexun-generation.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard opened >= 0 else { throw CollectionError.database(String(localized: "无法保护资料库会话，请稍后重试。")) }
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while flock(opened, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
                let failure = errno
                guard failure == EWOULDBLOCK || failure == EAGAIN || failure == EINTR else {
                    throw CollectionError.database(String(localized: "资料库会话锁不可用，请稍后重试。"))
                }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw CollectionError.database(String(localized: "资料库仍在使用或恢复中，请关闭分享保存页面后重试；现有资料未被替换。"))
                }
                usleep(10_000)
            }
        } catch { Darwin.close(opened); throw error }
        descriptor = opened
    }

    deinit { Darwin.close(descriptor) }
}

nonisolated enum SharedStorage {
    static let groupID = "group.com.wangxp.Kexun"
    private struct ActiveStorage: Codable {
        var formatVersion = 1
        var generation: UUID
    }
    private struct ReadyStorage: Codable {
        var generation: UUID
        var itemCount: Int
    }

    static func recoveryRoot(group: URL, generation: UUID) -> URL {
        group.appendingPathComponent("recovery-generations", isDirectory: true)
            .appendingPathComponent(generation.uuidString, isDirectory: true)
    }

    static func createRecoveryRoot(group: URL, generation: UUID) throws -> URL {
        let base = group.appendingPathComponent("recovery-generations", isDirectory: true)
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        if Darwin.mkdir(base.path, S_IRWXU) != 0, errno != EEXIST {
            throw CollectionError.database(String(localized: "无法创建恢复目录，请检查存储空间。"))
        }
        let values = try base.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              base.resolvingSymlinksInPath() == group.resolvingSymlinksInPath().appendingPathComponent("recovery-generations", isDirectory: true) else {
            throw CollectionError.database(String(localized: "恢复目录不安全，未写入恢复副本。"))
        }
        let root = recoveryRoot(group: group, generation: generation)
        guard Darwin.mkdir(root.path, S_IRWXU) == 0 else {
            throw CollectionError.database(String(localized: "无法创建独立恢复目录，未覆盖已有目录。"))
        }
        return root
    }

    static func synchronizeRecoveryRoot(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
            throw CollectionError.database(String(localized: "无法校验恢复目录。"))
        }
        var directories = [root]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw CollectionError.database(String(localized: "恢复目录含不安全链接。")) }
            if values.isDirectory == true { directories.append(url) }
            else if values.isRegularFile == true { try synchronize(url) }
            else { throw CollectionError.database(String(localized: "恢复目录含不支持的文件。")) }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) { try synchronize(directory) }
        try synchronize(root.deletingLastPathComponent())
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CollectionError.database(String(localized: "无法同步恢复文件，请检查存储空间。")) }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else { throw CollectionError.database(String(localized: "恢复文件同步失败，请稍后重试。")) }
    }

    /// Publishes only a complete independently restored library. Never moves/deletes the old root.
    static func publishRecovery(group: URL, generation: UUID) throws {
        try withRecoveryAccess(group: group) {
            let root = recoveryRoot(group: group, generation: generation)
            let ready = try validateRecoveryRoot(root, group: group)
            try validateRecoveryContents(root, expectedCount: ready.itemCount)
            try synchronizeRecoveryRoot(root)
            let pointer = group.appendingPathComponent("active-storage.json")
            let temporary = group.appendingPathComponent(".active-storage-\(UUID()).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try JSONEncoder().encode(ActiveStorage(generation: generation)).write(to: temporary, options: .withoutOverwriting)
            try synchronize(temporary)
            guard Darwin.rename(temporary.path, pointer.path) == 0 else {
                throw CollectionError.database(String(localized: "无法切换恢复资料库，旧资料库仍保留，请重试。"))
            }
            // Rename is the commit point. A subsequent sync error MUST NOT delete this generation.
            do { try synchronize(group) }
            catch { throw CollectionError.database(String(localized: "资料库指针已切换，但目录同步未确认。请重新打开检查；旧目录和恢复目录均保留。")) }
        }
    }

    private static func validateRecoveryContents(_ root: URL, expectedCount: Int) throws {
            let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
            try repository.checkIntegrity()
            let records = try repository.all()
            guard records.count == expectedCount else {
                throw CollectionError.database(String(localized: "恢复记录数量与校验结果不一致，未切换资料库。"))
            }
            let assets = try AttachmentStore(root: root)
            for reference in records.flatMap(\.attachments) {
                let url = try assets.url(for: reference)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      values.fileSize.map(Int64.init) == reference.byteCount,
                      try checksum(url) == reference.sha256 else {
                    throw CollectionError.database(String(localized: "恢复资料的附件校验失败，旧资料库未被切换。"))
                }
            }
    }

    @discardableResult
    private static func validateRecoveryRoot(_ root: URL, group: URL) throws -> ReadyStorage {
        let manager = FileManager.default
        let canonicalGroup = group.resolvingSymlinksInPath().standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL == canonicalGroup
            .appendingPathComponent("recovery-generations", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true) else {
            throw CollectionError.database(String(localized: "恢复资料目录不安全，未打开替代资料库。"))
        }
        for file in [root.appendingPathComponent("collections.sqlite"), root.appendingPathComponent("recovery-ready.json")] {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0 else {
                throw CollectionError.database(String(localized: "恢复资料不完整，未创建替代空库。"))
            }
        }
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        guard manager.fileExists(atPath: assets.path), assets.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent("assets", isDirectory: true) else {
            throw CollectionError.database(String(localized: "恢复附件目录缺失或不安全。"))
        }
        let marker = root.appendingPathComponent("recovery-ready.json")
        guard (try marker.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 4096 else {
            throw CollectionError.database(String(localized: "恢复校验记录损坏，未切换资料库。"))
        }
        let ready = try JSONDecoder().decode(ReadyStorage.self, from: Data(contentsOf: marker))
        guard ready.generation.uuidString == root.lastPathComponent, ready.itemCount >= 0 else {
            throw CollectionError.database(String(localized: "恢复校验记录身份不一致，未切换资料库。"))
        }
        return ready
    }

    private static func activeRecoveryRoot(group: URL) throws -> URL? {
        let pointer = group.appendingPathComponent("active-storage.json")
        guard FileManager.default.fileExists(atPath: pointer.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: pointer.path)) != nil else { return nil }
        let values = try pointer.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4096 else {
            throw CollectionError.database(String(localized: "资料库位置记录损坏，请从备份恢复；不会回退为空库。"))
        }
        let active = try JSONDecoder().decode(ActiveStorage.self, from: Data(contentsOf: pointer))
        guard active.formatVersion == 1 else { throw CollectionError.database(String(localized: "资料库位置记录版本不受支持，请升级可寻。")) }
        let root = recoveryRoot(group: group, generation: active.generation)
        try validateRecoveryRoot(root, group: group)
        return root
    }

    static func sessionForMainApp() throws -> StorageSession {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CollectionError.invalid(String(localized: "共享存储未配置。请检查可寻的 App Group 签名配置；不会创建替代空库。"))
        }
        let legacy = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Kexun")
        return try session(group: group, legacy: legacy)
    }

    static func session(group: URL, legacy: URL? = nil) throws -> StorageSession {
        // Order: generation lease, then preparation lock, then attachment/repository locks.
        let lease = try StorageGenerationLease(group: group, exclusive: false)
        return try StorageSession(root: prepare(group: group, legacy: legacy), lease: lease)
    }

    /// Call only after this process releases its own database/attachment sessions.
    /// A live extension or asynchronous operation prevents replacement, never gets forced out.
    static func withRecoveryAccess<T>(group: URL, _ operation: () throws -> T) throws -> T {
        let lease = try StorageGenerationLease(group: group, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        return try operation()
    }

    static func openForMainApp() throws -> URL {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw CollectionError.invalid(String(localized: "共享存储未配置。请检查可寻的 App Group 签名配置；不会创建替代空库。"))
        }
        let legacy = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Kexun")
        return try prepare(group: group, legacy: legacy)
    }

    static func prepare(group: URL, legacy: URL? = nil) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: group, withIntermediateDirectories: true)
        let descriptor = Darwin.open(group.appendingPathComponent("kexun-storage.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CollectionError.invalid(String(localized: "无法锁定共享存储，请稍后重试。")) }
        defer { Darwin.close(descriptor) }
        // Another process may be migrating. Never wait forever on the UI/extension launch path.
        // Monotonic time keeps this bound independent of wall-clock changes.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            guard failure == EWOULDBLOCK || failure == EAGAIN || failure == EINTR else {
                throw CollectionError.invalid(String(localized: "共享存储锁不可用，请稍后重试。"))
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw CollectionError.invalid(String(localized: "共享存储正由另一项操作使用，请稍后重试；现有资料未被更改。"))
            }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        // Restored generations never re-run the original legacy migration.
        if let restored = try activeRecoveryRoot(group: group) { return restored }
        let root = group.appendingPathComponent("Kexun", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appendingPathComponent("legacy-migrated-v1")
        guard let legacy, !manager.fileExists(atPath: marker.path),
              manager.fileExists(atPath: legacy.appendingPathComponent("collections.sqlite").path) else {
            // A missing database is not an empty library when attachment files remain.
            // Do not create a replacement DB and subsequently classify those files as orphans.
            let assetDirectory = root.appendingPathComponent("assets", isDirectory: true)
            if !manager.fileExists(atPath: root.appendingPathComponent("collections.sqlite").path),
               manager.fileExists(atPath: assetDirectory.path),
               !(try manager.contentsOfDirectory(atPath: assetDirectory.path)).isEmpty {
                throw CollectionError.database(String(localized: "收藏数据库缺失，但附件仍在。已保留文件，请从完整备份恢复或联系支持；不会创建空库清理附件。"))
            }
            return root
        }

        return try AttachmentStore(root: root).withExclusiveAccess {
        // Read through SQLite, including committed WAL contents; do not copy only the .sqlite file.
        let source = try CollectionRepository(url: legacy.appendingPathComponent("collections.sqlite"))
        let records = try source.all()
        let originalAssets = try AttachmentStore(root: legacy)
        let targetAssets = try AttachmentStore(root: root)
        for reference in records.flatMap(\.attachments) {
            let from = try originalAssets.url(for: reference)
            let to = try targetAssets.url(for: reference)
            guard try checksum(from) == reference.sha256 else { throw CollectionError.invalid(String(localized: "旧库附件校验失败，迁移已停止；旧数据保留。")) }
            if manager.fileExists(atPath: to.path) {
                guard try checksum(to) == reference.sha256 else { throw CollectionError.invalid(String(localized: "共享库存在同名不同内容附件，迁移停止，未覆盖。")) }
            } else {
                let temporary = root.appendingPathComponent("assets/.migration-\(UUID())")
                do {
                    try manager.copyItem(at: from, to: temporary)
                    guard try checksum(temporary) == reference.sha256 else { throw CollectionError.invalid(String(localized: "附件复制校验失败。")) }
                    try manager.moveItem(at: temporary, to: to)
                } catch { try? manager.removeItem(at: temporary); throw error }
            }
        }
        let destination = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        _ = try destination.mergeBackup(records)
        // Marker is only written after the transaction succeeds. Keep original files recoverable.
        try Data("migrated-v1".utf8).write(to: marker, options: .atomic)
        return root
        }
    }

    private static func checksum(_ url: URL) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        var hash = SHA256()
        while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
