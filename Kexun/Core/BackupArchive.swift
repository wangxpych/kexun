import Foundation
import CryptoKit

/// ZIP method 0 (stored): portable, deterministic, no external dependency or decompression bomb.
nonisolated enum StoredZIP {
    static let maximumBytes = 256 * 1024 * 1024
    static func encode(_ files: [(String, Data)]) throws -> Data {
        var archive = Data(), central = Data()
        guard files.count < 65535 else { throw CollectionError.invalid(String(localized: "备份条目过多。")) }
        for (name, bytes) in files {
            guard archive.count + bytes.count < maximumBytes else { throw CollectionError.invalid(String(localized: "本次备份超过 256 MB，暂无法导出。")) }
            let path = Data(name.utf8), offset = archive.count, crc = checksum(bytes)
            archive.le(0x04034b50, 4); archive.le(20, 2); archive.le(0x800, 2); archive.le(0, 2)
            archive.le(0, 2); archive.le(0, 2); archive.le(Int(crc), 4)
            archive.le(bytes.count, 4); archive.le(bytes.count, 4); archive.le(path.count, 2); archive.le(0, 2)
            archive.append(path); archive.append(bytes)
            central.le(0x02014b50, 4); central.le(20, 2); central.le(20, 2); central.le(0x800, 2); central.le(0, 2)
            central.le(0, 2); central.le(0, 2); central.le(Int(crc), 4)
            central.le(bytes.count, 4); central.le(bytes.count, 4); central.le(path.count, 2)
            central.le(0, 2); central.le(0, 2); central.le(0, 2); central.le(0, 2); central.le(0, 4); central.le(offset, 4)
            central.append(path)
        }
        let offset = archive.count
        archive.append(central)
        archive.le(0x06054b50, 4); archive.le(0, 2); archive.le(0, 2)
        archive.le(files.count, 2); archive.le(files.count, 2); archive.le(central.count, 4); archive.le(offset, 4); archive.le(0, 2)
        return archive
    }

    static func decode(_ data: Data) throws -> [String: Data] {
        guard data.count <= maximumBytes, data.count >= 22 else { throw CollectionError.invalid(String(localized: "备份为空、损坏或超过 256 MB。")) }
        let end = data.count - 22
        guard try data.number(end, 4) == 0x06054b50,
              try data.number(end + 4, 4) == 0, try data.number(end + 20, 2) == 0 else { throw CollectionError.invalid(String(localized: "不支持此 ZIP 格式，请选择可寻导出的完整备份。")) }
        let count = try data.number(end + 10, 2)
        var position = try data.number(end + 16, 4)
        guard try data.number(end + 8, 2) == count,
              position + (try data.number(end + 12, 4)) == end else { throw CollectionError.invalid(String(localized: "ZIP 目录损坏。")) }
        var result: [String: Data] = [:]
        var decodedBytes = 0
        for _ in 0..<count {
            guard try data.number(position, 4) == 0x02014b50,
                  try data.number(position + 8, 2) == 0x800,
                  try data.number(position + 10, 2) == 0 else { throw CollectionError.invalid(String(localized: "备份含不支持的压缩或加密条目。")) }
            let length = try data.number(position + 20, 4)
            guard length <= maximumBytes - decodedBytes else { throw CollectionError.invalid(String(localized: "备份累计内容超过安全上限。")) }
            decodedBytes += length
            let nameLength = try data.number(position + 28, 2)
            let extra = try data.number(position + 30, 2), comment = try data.number(position + 32, 2)
            let local = try data.number(position + 42, 4)
            guard length == (try data.number(position + 24, 4)),
                  let name = String(data: try data.slice(position + 46, nameLength), encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains(".."), !name.contains("\\"), result[name] == nil,
                  try data.number(local, 4) == 0x04034b50,
                  try data.number(local + 8, 2) == 0,
                  try data.number(local + 18, 4) == length else { throw CollectionError.invalid(String(localized: "备份条目无效或重复。")) }
            let localNameLength = try data.number(local + 26, 2), localExtra = try data.number(local + 28, 2)
            guard try data.slice(local + 30, localNameLength) == Data(name.utf8) else { throw CollectionError.invalid(String(localized: "ZIP 文件名不一致。")) }
            let bytes = try data.slice(local + 30 + localNameLength + localExtra, length)
            guard Int(checksum(bytes)) == (try data.number(position + 16, 4)) else { throw CollectionError.invalid(String(localized: "备份校验失败。")) }
            result[name] = bytes
            position += 46 + nameLength + extra + comment
        }
        guard position == end else { throw CollectionError.invalid(String(localized: "备份目录不完整。")) }
        return result
    }

    private static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) } }
        return crc ^ 0xffffffff
    }
}

nonisolated private extension Data {
    mutating func le(_ value: Int, _ width: Int) { for shift in 0..<width { append(UInt8((value >> (8 * shift)) & 255)) } }
    func number(_ offset: Int, _ width: Int) throws -> Int {
        try slice(offset, width).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
    }
    func slice(_ offset: Int, _ length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else { throw CollectionError.invalid(String(localized: "备份数据被截断。")) }
        return subdata(in: offset..<(offset + length))
    }
}

nonisolated enum BackupArchive {
    struct Manifest: Codable { var formatVersion = 1; var exportedAt = Date(); var itemCount: Int; var checksums: [String: String] }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func export(repository: CollectionRepository, assets: AttachmentStore) throws -> Data {
        let url = try exportFile(repository: repository, assets: assets)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try Data(contentsOf: url)
    }

    static func restore(_ data: Data, repository: CollectionRepository, assets: AttachmentStore) throws -> Int {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.zip")
        try data.write(to: url)
        return try restoreFile(url, repository: repository, assets: assets)
    }

    // Tests may choose a bounded filesystem; normal callers keep the system
    // temporary directory. Every operation still owns a fresh UUID subdirectory.
    private static func temporaryDirectory(root: URL? = nil) throws -> URL {
        let url = (root ?? FileManager.default.temporaryDirectory).appendingPathComponent("kexun-backup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Caller owns the returned temporary directory until the export/share sheet is dismissed.
    static func exportFile(repository: CollectionRepository, assets: AttachmentStore, temporaryRoot: URL? = nil) throws -> URL {
        let directory = try temporaryDirectory(root: temporaryRoot)
        do {
            return try assets.withExclusiveAccess {
                let records = try repository.all()
                let items = directory.appendingPathComponent("items.json")
                let itemData = try JSONEncoder().encode(records)
                guard itemData.count <= 128 * 1024 * 1024 else { throw CollectionError.invalid(String(localized: "收藏记录元数据超过当前备份安全上限（128 MB），未导出不可恢复的备份。")) }
                try itemData.write(to: items)
                var files: [String: URL] = ["items.json": items]
                var checksums = ["items.json": try StreamingZIP.inspect(items).sha]
                var attachmentSizes: [String: UInt64] = [:]
                for reference in records.flatMap(\.attachments) {
                    let url = try assets.url(for: reference)
                    if checksums[reference.relativePath] == nil {
                        let info = try StreamingZIP.inspect(url)
                        files[reference.relativePath] = url
                        checksums[reference.relativePath] = info.sha
                        attachmentSizes[reference.relativePath] = info.size
                    }
                    guard reference.byteCount >= 0, attachmentSizes[reference.relativePath] == UInt64(reference.byteCount), checksums[reference.relativePath] == reference.sha256 else {
                        throw CollectionError.invalid(String(localized: "附件缺失或损坏，未导出不完整备份。"))
                    }
                }
                let manifest = directory.appendingPathComponent("manifest.json")
                let manifestData = try JSONEncoder().encode(Manifest(itemCount: records.count, checksums: checksums))
                guard manifestData.count <= 32 * 1024 * 1024 else { throw CollectionError.invalid(String(localized: "备份清单超过安全上限。")) }
                try manifestData.write(to: manifest)
                files["manifest.json"] = manifest
                let result = directory.appendingPathComponent("kexun-backup.zip")
                try StreamingZIP.encode(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, to: result)
                return result
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    static func restoreFile(_ url: URL, repository: CollectionRepository, assets: AttachmentStore) throws -> Int {
        try restoreFileReport(url, repository: repository, assets: assets).added
    }

    static func restoreFileReport(_ url: URL, repository: CollectionRepository, assets: AttachmentStore, temporaryRoot: URL? = nil) throws -> BackupMergeReport {
        let directory = try temporaryDirectory(root: temporaryRoot)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Parse and hash untrusted input before holding the shared lifecycle lock.
        let files = try StreamingZIP.decode(url, into: directory)
        guard let manifestEntry = files["manifest.json"], let itemEntry = files["items.json"],
              manifestEntry.size <= 32 * 1024 * 1024, itemEntry.size <= 128 * 1024 * 1024 else {
            throw CollectionError.invalid(String(localized: "备份清单缺失或记录元数据超过安全上限（128 MB）。"))
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestEntry.url))
        guard manifest.formatVersion == 1, Set(files.keys) == Set(manifest.checksums.keys).union(["manifest.json"]) else {
            throw CollectionError.invalid(String(localized: "备份版本或清单不受支持。"))
        }
        for (path, checksum) in manifest.checksums where files[path]?.sha != checksum {
            throw CollectionError.invalid(String(localized: "备份 SHA-256 校验失败。"))
        }
        var records = try JSONDecoder().decode([CollectionRecord].self, from: Data(contentsOf: itemEntry.url))
        guard records.count == manifest.itemCount, Set(records.map(\.id)).count == records.count else { throw CollectionError.invalid(String(localized: "备份记录数量或 ID 无效。")) }
        var references: [String: AttachmentReference] = [:]
        for record in records {
            guard record.version > 0, !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CollectionError.invalid(String(localized: "备份记录无效。")) }
            for reference in record.attachments {
                _ = try assets.url(for: reference)
                guard reference.byteCount >= 0, let entry = files[reference.relativePath], entry.size == UInt64(reference.byteCount), entry.sha == reference.sha256,
                      references[reference.relativePath].map({ $0.sha256 == reference.sha256 && $0.byteCount == reference.byteCount }) ?? true else { throw CollectionError.invalid(String(localized: "备份附件不完整或引用冲突。")) }
                references[reference.relativePath] = reference
            }
        }
        guard Set(files.keys) == Set(references.keys).union(["items.json", "manifest.json"]) else { throw CollectionError.invalid(String(localized: "备份包含未引用的文件。")) }
        return try assets.withExclusiveAccess {
            var mapped: [String: AttachmentReference] = [:]
            var reserved: [String: String] = [:]
            for (path, original) in references.sorted(by: { $0.key < $1.key }) {
                var reference = original
                var attempt = 0
                while true {
                    let exists = FileManager.default.fileExists(atPath: try assets.url(for: reference).path)
                    let reservedHash = reserved[reference.relativePath]
                    if !exists && (reservedHash == nil || reservedHash == reference.sha256) { break }
                    if exists, reservedHash == nil || reservedHash == reference.sha256,
                       try StreamingZIP.inspect(assets.url(for: reference)).sha == reference.sha256 { break }
                    // Deterministic collision remapping makes subsequent restores idempotent.
                    let hex = digest(Data("\(original.id.uuidString):\(original.sha256):\(attempt)".utf8))
                    let value = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
                    reference.id = UUID(uuidString: value)!
                    reference.relativePath = "assets/\(reference.id.uuidString)"
                    attempt += 1
                    guard attempt < 100 else { throw CollectionError.invalid(String(localized: "附件 ID 冲突过多，未改变现有资料。")) }
                }
                mapped[path] = reference
                reserved[reference.relativePath] = reference.sha256
            }
            for index in records.indices {
                records[index].attachments = records[index].attachments.map { original in
                    var reference = original
                    reference.id = mapped[original.relativePath]!.id
                    reference.relativePath = mapped[original.relativePath]!.relativePath
                    return reference
                }
            }
            // Every input is validated before any persistent writes. Track fresh copies for rollback.
            var created: [URL] = []
            do {
                for (path, reference) in mapped {
                    let target = try assets.url(for: reference)
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: files[path]!.url, to: target)
                        created.append(target)
                    }
                }
                return try repository.mergeBackupReport(records)
            } catch {
                for target in created { try? FileManager.default.removeItem(at: target) }
                throw error
            }
        }
    }

}
