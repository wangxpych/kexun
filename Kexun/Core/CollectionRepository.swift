import Foundation

nonisolated struct BackupMergeReport: Equatable, Sendable {
    var inserted = 0
    var conflicts = 0
    var skipped = 0
    var added: Int { inserted + conflicts }
    var processed: Int { added + skipped }
    var message: String {
        String(localized: "恢复完成：新增 \(added) 条（其中冲突保留 \(conflicts) 条），跳过 \(skipped) 条相同记录。共处理 \(processed) 条，已有内容未被覆盖。")
    }
}
import SQLite3

/// Each connection is serialized; BEGIN IMMEDIATE also serializes writers in other processes.
nonisolated final class CollectionRepository: @unchecked Sendable {
    private var database: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let storageLease: (any Sendable)?

    init(url: URL, storageLease: (any Sendable)? = nil) throws {
        self.storageLease = storageLease
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "无法打开数据库")
            sqlite3_close(database)
            database = nil
            throw CollectionError.database(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try transaction {
                let version = try scalar("PRAGMA user_version")
                guard version <= 1 else { throw CollectionError.invalid(String(localized: "数据来自更新版本，请升级可寻后再打开。")) }
                try execute("CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
                try execute("PRAGMA user_version=1")
            }
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    enum BatchAction { case star(Bool), archive(Bool), folder(String?), trash }

    func checkIntegrity() throws {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("PRAGMA integrity_check")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0), String(cString: result) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionError.database(String(localized: "恢复数据库完整性检查失败，未切换资料库。"))
        }
    }

    func batch(ids: Set<UUID>, action: BatchAction) throws {
        try transaction {
            let records = try all().filter { ids.contains($0.id) }
            guard records.count == ids.count else { throw CollectionError.conflict }
            let now = Date()
            for var record in records {
                guard record.deletedAt == nil else { throw CollectionError.conflict }
                switch action {
                case .star(let value): record.starred = value
                case .archive(let value): record.archivedAt = value ? now : nil
                case .folder(let name): record.folder = name
                case .trash: record.deletedAt = now
                }
                record.updatedAt = now
                record.version = try nextVersion(record.version)
                try validate(record)
                try write(record)
            }
        }
    }

    func all() throws -> [CollectionRecord] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare("SELECT payload FROM records")
        defer { sqlite3_finalize(statement) }
        var records: [CollectionRecord] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw CollectionError.database(String(localized: "记录内容损坏")) }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
            records.append(try decoder.decode(CollectionRecord.self, from: data))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw failure() }
        return records
    }

    /// Folder names are carried by records, so backups preserve membership without a second catalog.
    /// Removing a folder only clears membership, including in the trash; it never deletes content.
    func renameFolder(_ old: String, to new: String?) throws {
        try transaction {
            let members = try all().filter { $0.folder == old }
            guard !members.isEmpty else { throw CollectionError.conflict }
            for var record in members {
                record.folder = new
                record.version = try nextVersion(record.version)
                record.updatedAt = Date()
                try validate(record)
                try write(record)
            }
        }
    }

    func search(_ query: CollectionQuery) throws -> [CollectionRecord] {
        try all().filter(query.matches).sorted {
            if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
            return query.newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
    }

    func insert(_ records: [CollectionRecord], isPro: Bool, allowDuplicate: Bool = false) throws {
        try transaction {
            let existing = try all()
            let remaining = max(0, 100 - existing.filter { $0.deletedAt == nil }.count)
            guard isPro || records.filter({ $0.deletedAt == nil }).count <= remaining else { throw CollectionError.limit(remaining) }
            var known = existing
            for record in records {
                try validate(record)
                guard !known.contains(where: { $0.id == record.id }) else { throw CollectionError.conflict }
                if !allowDuplicate, let url = record.originalURL,
                   let duplicate = known.first(where: { $0.deletedAt == nil && $0.originalURL.map(LinkParser.normalized) == LinkParser.normalized(url) }) {
                    throw CollectionError.duplicate(duplicate.id)
                }
                try write(record)
                known.append(record)
            }
        }
    }

    func update(id: UUID, expectedVersion: Int? = nil, change: (inout CollectionRecord) throws -> Void) throws {
        try transaction {
            guard var record = try all().first(where: { $0.id == id }) else { throw CollectionError.missing }
            if let expectedVersion, record.version != expectedVersion { throw CollectionError.conflict }
            let original = record
            try change(&record)
            // Restoring/inserting and changing identity must go through their quota-aware APIs.
            guard record.id == original.id, record.createdAt == original.createdAt,
                  !(original.deletedAt != nil && record.deletedAt == nil) else { throw CollectionError.invalid(String(localized: "请使用恢复入口。")) }
            record.version = try nextVersion(original.version)
            record.updatedAt = Date()
            try validate(record)
            try write(record)
        }
    }

    /// Atomically claim current, non-trashed data rather than a UI scheduling snapshot.
    func beginProcessing(id: UUID) throws -> CollectionRecord? {
        try transaction {
            guard var record = try all().first(where: { $0.id == id }), record.deletedAt == nil else { return nil }
            record.processingState = .processing
            record.processingError = nil
            record.version = try nextVersion(record.version)
            record.updatedAt = Date()
            try validate(record)
            try write(record)
            return record
        }
    }

    func restore(ids: Set<UUID>, isPro: Bool) throws {
        try transaction {
            let allRecords = try all()
            let restoring = allRecords.filter { ids.contains($0.id) && $0.deletedAt != nil }
            // A stale selection must not silently turn into a partial successful operation.
            guard restoring.count == ids.count else { throw CollectionError.conflict }
            let remaining = max(0, 100 - allRecords.filter { $0.deletedAt == nil }.count)
            guard isPro || restoring.count <= remaining else { throw CollectionError.limit(remaining) }
            for var record in restoring {
                record.deletedAt = nil
                record.version = try nextVersion(record.version)
                record.updatedAt = Date()
                try write(record)
            }
        }
    }

    /// Returns attachment candidates. Caller removes only paths no longer referenced by any record.
    func permanentlyDelete(ids: Set<UUID>) throws -> [AttachmentReference] {
        try transaction {
            let records = try all()
            let deleted = records.filter { ids.contains($0.id) && $0.deletedAt != nil }
            guard deleted.count == ids.count else { throw CollectionError.conflict }
            for record in deleted {
                let statement = try prepare("DELETE FROM records WHERE id = ?")
                defer { sqlite3_finalize(statement) }
                bind(record.id.uuidString, to: statement, index: 1)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
            }
            let stillUsed = Set(try all().flatMap(\.attachments).map(\.relativePath))
            return deleted.flatMap(\.attachments).filter { !stillUsed.contains($0.relativePath) }
        }
    }

    /// Complete validated backup restores deliberately bypass the free quota, never purchase verification.
    func mergeBackup(_ incoming: [CollectionRecord]) throws -> Int {
        try mergeBackupReport(incoming).added
    }

    func mergeBackupReport(_ incoming: [CollectionRecord]) throws -> BackupMergeReport {
        try transaction {
            var known = Dictionary(uniqueKeysWithValues: try all().map { ($0.id, $0) })
            var report = BackupMergeReport()
            for var record in incoming {
                try validate(record)
                var conflict = false
                if let existing = known[record.id] {
                    if existing == record { report.skipped += 1; continue }
                    // Repeated import of the same conflicting payload must not keep creating copies.
                    if known.values.contains(where: { candidate in
                        var comparable = candidate
                        comparable.id = record.id
                        return comparable == record
                    }) { report.skipped += 1; continue }
                    record.id = UUID()
                    conflict = true
                }
                try write(record)
                known[record.id] = record
                if conflict { report.conflicts += 1 } else { report.inserted += 1 }
            }
            return report
        }
    }

    private func nextVersion(_ version: Int) throws -> Int {
        let (next, overflow) = version.addingReportingOverflow(1)
        guard version > 0, !overflow else {
            throw CollectionError.invalid(String(localized: "收藏版本无法继续更新，本次操作未保存。原内容仍可查看和导出，请保留备份。"))
        }
        return next
    }

    private func validate(_ record: CollectionRecord) throws {
        if let folder = record.folder {
            guard !folder.isEmpty, folder.count <= 40,
                  folder == folder.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CollectionError.invalid(String(localized: "收藏夹名称须为 1 至 40 个字符，且首尾不能为空格。"))
            }
        }
        guard record.version > 0, !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CollectionError.invalid(String(localized: "收藏标题不能为空，版本必须有效。"))
        }
        for attachment in record.attachments {
            guard attachment.relativePath.hasPrefix("assets/"), !attachment.relativePath.contains(".."),
                  !attachment.relativePath.contains("\\"), attachment.byteCount >= 0 else {
                throw CollectionError.invalid(String(localized: "附件引用无效。"))
            }
        }
    }

    private func write(_ record: CollectionRecord) throws {
        let data = try encoder.encode(record)
        let statement = try prepare("INSERT OR REPLACE INTO records (id, payload) VALUES (?, ?)")
        defer { sqlite3_finalize(statement) }
        bind(record.id.uuidString, to: statement, index: 1)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        return statement
    }

    private func bind(_ string: String, to statement: OpaquePointer, index: Int32) {
        _ = string.withCString { sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func failure() -> CollectionError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? String(localized: "数据库未打开"))
    }
}
