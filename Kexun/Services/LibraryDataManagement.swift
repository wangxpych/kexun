import Foundation

nonisolated enum LibraryDataManagement {
    struct BackupReceipt: Codable, Equatable, Sendable {
        var exportedAt: Date
        var snapshotAt: Date
        var recordCount: Int
        var zipBytes: Int64
        var fingerprint: String
    }

    struct LargeAttachment: Identifiable, Sendable {
        var id: UUID
        var filename: String
        var bytes: Int64
        var records: [CollectionRecord]
    }

    struct Usage: Sendable {
        var activeCount = 0
        var trashCount = 0
        var activeAttachmentBytes: Int64 = 0
        var trashOnlyAttachmentBytes: Int64 = 0
        var unavailableAttachments = 0
        var fingerprint: String = ""
        var largeAttachments: [LargeAttachment] = []
        var trashReferencedAttachmentBytes: Int64 = 0
        var totalAttachmentBytes: Int64 { activeAttachmentBytes + trashOnlyAttachmentBytes }
    }

    /// Local receipt, scoped to this library. It does not prove the external copy still exists.
    static func receiptKey(root: URL) -> String {
        "kexun.backup.lastSuccessfulExport." + BackupArchive.digest(Data(root.standardizedFileURL.path.utf8))
    }

    static func lastSuccessfulBackup(root: URL, defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: receiptKey(root: root)) as? Date
    }

    static func recordSuccessfulBackup(root: URL, date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: receiptKey(root: root))
    }

    static func backupReceipt(root: URL, defaults: UserDefaults = .standard) -> BackupReceipt? {
        guard let data = defaults.data(forKey: receiptKey(root: root) + ".details") else { return nil }
        return try? JSONDecoder().decode(BackupReceipt.self, from: data)
    }

    static func recordSuccessfulBackup(root: URL, receipt: BackupReceipt, completedAt: Date = Date(), defaults: UserDefaults = .standard) throws {
        var completed = receipt
        completed.exportedAt = completedAt
        let data = try JSONEncoder().encode(completed)
        defaults.set(data, forKey: receiptKey(root: root) + ".details")
        recordSuccessfulBackup(root: root, date: completedAt, defaults: defaults)
    }

    /// Called only for a just-created BackupArchive.exportFile output. These are the exact
    /// staging inputs verified by StreamingZIP.encode, not a before/after database guess.
    static func snapshotReceipt(archiveURL: URL) throws -> BackupReceipt {
        let directory = archiveURL.deletingLastPathComponent()
        let items = try Data(contentsOf: directory.appendingPathComponent("items.json"))
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        guard items.count <= 128 * 1024 * 1024, manifestData.count <= 32 * 1024 * 1024 else {
            throw CollectionError.invalid(String(localized: "备份快照超过安全上限。"))
        }
        let manifest = try JSONDecoder().decode(BackupArchive.Manifest.self, from: manifestData)
        let records = try JSONDecoder().decode([CollectionRecord].self, from: items)
        guard manifest.formatVersion == 1, manifest.itemCount == records.count,
              manifest.checksums["items.json"] == BackupArchive.digest(items) else {
            throw CollectionError.invalid(String(localized: "备份快照与清单不一致，未记录成功状态。"))
        }
        let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else { throw CollectionError.invalid(String(localized: "备份文件为空，未记录成功状态。")) }
        return BackupReceipt(exportedAt: manifest.exportedAt, snapshotAt: manifest.exportedAt,
                             recordCount: records.count, zipBytes: Int64(size), fingerprint: try fingerprint(records))
    }

    static func fingerprint(_ records: [CollectionRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records.sorted { $0.id.uuidString < $1.id.uuidString })
        guard data.count <= 128 * 1024 * 1024 else {
            throw CollectionError.invalid(String(localized: "资料元数据超过变化比较的 128 MB 上限。"))
        }
        return BackupArchive.digest(data)
    }

    static func filename(readable: Bool, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "kexun-\(readable ? "readable" : "backup")-\(formatter.string(from: date)).zip"
    }

    static func usage(repository: CollectionRepository, assets: AttachmentStore) throws -> Usage {
        try assets.withExclusiveAccess {
            let records = try repository.all()
            let active = records.filter { $0.deletedAt == nil }
            let trash = records.filter { $0.deletedAt != nil }
            let liveIDs = Set(active.flatMap(\.attachments).map(\.id))
            let trashIDs = Set(trash.flatMap(\.attachments).map(\.id))
            let owners = Dictionary(grouping: records.flatMap { record in record.attachments.map { ($0.id, record) } }, by: { $0.0 })
            var result = Usage(activeCount: active.count, trashCount: trash.count)
            result.fingerprint = try fingerprint(records)
            var seen = Set<UUID>()
            for reference in records.flatMap(\.attachments) where seen.insert(reference.id).inserted {
                try Task.checkCancellation()
                do {
                    let url = try assets.url(for: reference)
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else {
                        result.unavailableAttachments += 1; continue
                    }
                    if liveIDs.contains(reference.id) { result.activeAttachmentBytes += Int64(size) }
                    else { result.trashOnlyAttachmentBytes += Int64(size) }
                    if trashIDs.contains(reference.id) { result.trashReferencedAttachmentBytes += Int64(size) }
                    var ownerIDs = Set<UUID>()
                    let linked = (owners[reference.id] ?? []).map(\.1).filter { ownerIDs.insert($0.id).inserted }
                    result.largeAttachments.append(LargeAttachment(id: reference.id, filename: reference.originalName, bytes: Int64(size), records: linked))
                } catch { result.unavailableAttachments += 1 }
            }
            result.largeAttachments.sort { $0.bytes == $1.bytes ? $0.id.uuidString < $1.id.uuidString : $0.bytes > $1.bytes }
            return result
        }
    }

    /// General-purpose Markdown and original attachments, NOT an application recovery archive.
    /// Uses the same lifecycle lock and immutable repository snapshot as BackupArchive.exportFile.
    /// The caller owns this UUID staging directory until the system exporter finishes or cancels.
    static func exportReadable(repository: CollectionRepository, assets: AttachmentStore, selectedIDs: Set<UUID>? = nil, temporaryRoot: URL? = nil) throws -> URL {
        // Reuse the existing, tightly scoped stale-artifact cleanup convention.
        let directory = (temporaryRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("kexun-backup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            return try assets.withExclusiveAccess {
                let snapshot = try repository.all()
                if let selectedIDs {
                    guard !selectedIDs.isEmpty, selectedIDs.isSubset(of: Set(snapshot.map(\.id))) else {
                        throw CollectionError.conflict
                    }
                }
                let records = snapshot.filter { selectedIDs?.contains($0.id) ?? true }
                var files: [String: URL] = [:]
                var verified: [UUID: (size: UInt64, sha: String)] = [:]
                var textBytes = 0
                var index = "# 可寻资料导出 / Kexun readable export\n\n"
                    + "此文件夹包含普通 Markdown 和原始附件，可在其他应用阅读，不是可寻完整恢复备份。包含回收站及私人内容，未加密，请勿公开分享。\n\n"
                    + "Markdown files and original attachments. Includes trash and private content. Not encrypted; not a recovery backup.\n\n"
                for record in records {
                    try Task.checkCancellation()
                    for reference in record.attachments {
                        // Validate every reference before using the ID-keyed digest cache.
                        // AttachmentStore requires exactly assets/<this UUID>, including repeated IDs.
                        let url = try assets.url(for: reference)
                        if verified[reference.id] == nil {
                            let info = try StreamingZIP.inspect(url)
                            verified[reference.id] = (info.size, info.sha)
                            files[attachmentPath(reference)] = url
                        }
                        guard reference.byteCount >= 0, let info = verified[reference.id],
                              info.size == UInt64(reference.byteCount), info.sha == reference.sha256 else {
                            throw CollectionError.invalid(String(localized: "附件缺失或损坏，未导出不完整资料包。"))
                        }
                        // Two references may use different original extensions for one underlying attachment.
                        files[attachmentPath(reference)] = url
                    }
                    let name = "records/\(record.id.uuidString).md"
                    let data = Data(markdown(record).utf8)
                    guard data.count <= 128 * 1024 * 1024 - textBytes else {
                        throw CollectionError.invalid(String(localized: "导出文本超过 128 MB 安全上限，未生成不完整资料包。"))
                    }
                    textBytes += data.count
                    let local = directory.appendingPathComponent(record.id.uuidString + ".md")
                    try data.write(to: local)
                    files[name] = local
                    index += "- [\(escapedLabel(record.title.isEmpty ? record.id.uuidString : record.title))](\(name))"
                        + (record.deletedAt != nil ? " — 回收站 / Trash" : "") + "\n"
                    guard index.utf8.count <= 32 * 1024 * 1024 else {
                        throw CollectionError.invalid(String(localized: "导出索引超过 32 MB 安全上限。"))
                    }
                }
                let indexURL = directory.appendingPathComponent("README.md")
                try Data(index.utf8).write(to: indexURL)
                files["README.md"] = indexURL
                let output = directory.appendingPathComponent(filename(readable: true))
                try Task.checkCancellation()
                try StreamingZIP.encode(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, to: output)
                return output
            }
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    private static func attachmentPath(_ reference: AttachmentReference) -> String {
        let suffix = URL(fileURLWithPath: reference.originalName).pathExtension.lowercased()
        let safeSuffix = !suffix.isEmpty && suffix.count <= 12 && suffix.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        return "attachments/\(reference.id.uuidString)" + (safeSuffix ? ".\(suffix)" : "")
    }

    private static func escapedLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func literal(_ value: String) -> String {
        // A content-chosen fence cannot terminate the generated block or inject active Markdown.
        let longest = value.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)text\n\(value)\n\(fence)\n\n"
    }

    private static func markdown(_ record: CollectionRecord) -> String {
        let date = ISO8601DateFormatter()
        var text = "# 收藏 / Record\n\n"
        text += "ID: \(record.id.uuidString)\n\n"
        text += "类型 / Kind: \(record.kind.rawValue)\n\n"
        text += "创建 / Created: \(date.string(from: record.createdAt))\n\n"
        text += "更新 / Updated: \(date.string(from: record.updatedAt))\n\n"
        text += "星标 / Starred: \(record.starred)\n\n"
        text += "归档 / Archived: \(record.archivedAt.map { date.string(from: $0) } ?? "—")\n\n"
        text += "回收站 / Deleted: \(record.deletedAt.map { date.string(from: $0) } ?? "—")\n\n"
        for (label, value) in [("标题 / Title", record.title), ("正文 / Body", record.body), ("备注 / Note", record.note),
                               ("网址 / URL", record.originalURL ?? ""), ("来源 / Source", record.source),
                               ("收藏夹 / Folder", record.folder ?? ""),
                               ("识别文本 / Extracted text", record.extractedText)] {
            text += "## \(label)\n\n" + literal(value)
        }
        if let article = record.article {
            text += "## 网页正文 / Saved article\n\n" + literal(article.text)
            text += "## 网页来源 / Article source\n\n" + literal(article.sourceURL)
            text += "网页保存时间 / Article captured: \(date.string(from: article.capturedAt))\n\n"
        }
        text += "## 原始附件 / Original attachments\n\n"
        for reference in record.attachments {
            text += "[\(escapedLabel(reference.originalName))](../\(attachmentPath(reference)))\n\n"
        }
        return text
    }
}
