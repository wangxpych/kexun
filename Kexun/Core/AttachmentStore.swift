import Foundation
import CryptoKit
import Darwin

nonisolated final class AttachmentStore: Sendable {
    let root: URL
    static let maximumBytes: Int64 = 100 * 1024 * 1024
    private let storageLease: (any Sendable)?

    init(root: URL, storageLease: (any Sendable)? = nil) throws {
        self.storageLease = storageLease
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
    }

    /// Lock ordering: attachment lifecycle lock, then repository transaction.
    /// All operations that reuse/remove existing attachment IDs must follow this order.
    func withExclusiveAccess<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = Darwin.open(root.appendingPathComponent("attachment-lifecycle.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CollectionError.invalid(String(localized: "无法锁定附件存储。")) }
        defer { Darwin.close(descriptor) }
        let deadline = Date().addingTimeInterval(5)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw CollectionError.invalid(String(localized: "附件存储锁不可用。")) }
            guard Date() < deadline else { throw CollectionError.invalid(String(localized: "另一项数据操作正在进行，请稍后重试。")) }
            usleep(10_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    func importFile(_ source: URL, contentType: String) throws -> AttachmentReference {
        let lease = try beginImport()
        defer { withExtendedLifetime(lease) {} }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CollectionError.invalid(String(localized: "请选择普通文件，不支持文件夹或符号链接。"))
        }
        guard Int64(values.fileSize ?? 0) <= Self.maximumBytes else {
            throw CollectionError.invalid(String(localized: "单个附件暂支持最大 100 MB，请选择较小文件。"))
        }
        let id = UUID()
        let path = "assets/\(id.uuidString)"
        let target = root.appendingPathComponent(path)
        let temporary = root.appendingPathComponent("assets/.\(id.uuidString).partial")
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw CollectionError.invalid(String(localized: "无法创建附件副本，请检查存储空间。"))
        }
        do {
            let writer = try FileHandle(forWritingTo: temporary)
            defer { try? writer.close() }
            var digest = SHA256()
            var size: Int64 = 0
            while let chunk = try reader.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                guard size <= Self.maximumBytes else { throw CollectionError.invalid(String(localized: "附件超过 100 MB，未保存。")) }
                digest.update(data: chunk)
                try writer.write(contentsOf: chunk)
            }
            try writer.synchronize()
            try writer.close()
            try FileManager.default.moveItem(at: temporary, to: target)
            return AttachmentReference(id: id, relativePath: path, originalName: source.lastPathComponent,
                                       contentType: contentType, byteCount: size,
                                       sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func url(for reference: AttachmentReference) throws -> URL {
        // Generated references are a single UUID under assets, never arbitrary archive paths.
        let expected = "assets/\(reference.id.uuidString)"
        guard reference.relativePath == expected else { throw CollectionError.invalid(String(localized: "附件路径无效。")) }
        let url = root.appendingPathComponent(expected)
        guard url.resolvingSymlinksInPath().deletingLastPathComponent() == root.appendingPathComponent("assets").resolvingSymlinksInPath() else {
            throw CollectionError.invalid(String(localized: "附件路径不安全。"))
        }
        return url
    }

    func removeUnreferenced(_ references: [AttachmentReference], keeping records: [CollectionRecord]) throws {
        let used = Set(records.flatMap(\.attachments).map(\.relativePath))
        for reference in references where !used.contains(reference.relativePath) {
            let target = try url(for: reference)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
    }

    /// Callers retain this lease across copying AND committing the record.
    /// Process termination closes the descriptor and releases the kernel lock.
    func beginImport() throws -> AttachmentImportLease {
        try AttachmentImportLease(url: root.appendingPathComponent("attachment-import.lock"))
    }

    /// Returns nil when another process is importing. Never uses a stale record snapshot.
    func reclaimOrphans(repository: CollectionRepository) throws -> Int? {
        try withExclusiveAccess {
            let descriptor = Darwin.open(root.appendingPathComponent("attachment-import.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw CollectionError.invalid(String(localized: "无法检查附件导入状态。")) }
            defer { Darwin.close(descriptor) }
            // Nonblocking is required: an importer can hold a shared import lock while
            // waiting for the lifecycle lock to commit metadata. Do not invert that wait.
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
                throw CollectionError.invalid(String(localized: "附件导入状态检查失败。"))
            }
            defer { flock(descriptor, LOCK_UN) }
            let used = Set(try repository.all().flatMap(\.attachments).map(\.relativePath))
            let directory = root.appendingPathComponent("assets", isDirectory: true)
            guard directory.resolvingSymlinksInPath() == root.resolvingSymlinksInPath().appendingPathComponent("assets", isDirectory: true) else {
                throw CollectionError.invalid(String(localized: "附件目录不安全，未进行整理。"))
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            var removed = 0
            for file in files {
                let name = file.lastPathComponent
                guard !used.contains("assets/" + name) else { continue }
                let isAsset = UUID(uuidString: name) != nil
                let isPartial = name.hasPrefix(".") && name.hasSuffix(".partial") && UUID(uuidString: String(name.dropFirst().dropLast(8))) != nil
                let isMigration = name.hasPrefix(".migration-") && UUID(uuidString: String(name.dropFirst(11))) != nil
                guard isAsset || isPartial || isMigration else { continue }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try FileManager.default.removeItem(at: file)
                removed += 1
            }
            return removed
        }
    }
}

nonisolated final class AttachmentImportLease: Sendable {
    private let descriptor: Int32
    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CollectionError.invalid(String(localized: "无法锁定附件导入。")) }
        guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw CollectionError.invalid(String(localized: "正在整理附件存储，请稍后重试导入。"))
        }
        self.descriptor = descriptor
    }
    deinit { Darwin.close(descriptor) }
}
