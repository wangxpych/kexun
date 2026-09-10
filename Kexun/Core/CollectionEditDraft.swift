import Foundation

/// Only the user's editable fields. Saving a draft never replaces source files or extraction results.
nonisolated struct CollectionEditDraft: Equatable, Sendable {
    var title: String
    var body: String
    var note: String
    var folder: String
    let editsBody: Bool

    init(record: CollectionRecord) {
        title = record.title
        body = record.body
        note = record.note
        folder = record.folder ?? ""
        editsBody = record.kind == .text
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && folder.trimmingCharacters(in: .whitespacesAndNewlines).count <= 40
            && (!editsBody || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func hasChanges(from record: CollectionRecord) -> Bool {
        title != record.title || note != record.note || folder != (record.folder ?? "") || (editsBody && body != record.body)
    }

    func apply(to record: inout CollectionRecord) {
        if title != record.title {
            record.title = title
            record.titleEdited = true
        }
        record.note = note
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        record.folder = name.isEmpty ? nil : name
        if editsBody && record.kind == .text { record.body = body }
    }

    /// Three-way merge against the record read inside the repository transaction.
    /// Background extraction may advance the version without changing user edits.
    func merge(from base: CollectionRecord, into latest: inout CollectionRecord) throws {
        guard base.id == latest.id, base.createdAt == latest.createdAt,
              base.kind == latest.kind, base.deletedAt == latest.deletedAt,
              base.starred == latest.starred, base.archivedAt == latest.archivedAt,
              editsBody == (base.kind == .text) else { throw CollectionError.conflict }
        guard isValid else { throw CollectionError.invalid(String(localized: "请检查标题、正文和收藏夹名称。")) }
        var merged = latest
        func mergeField<Value: Equatable>(_ key: WritableKeyPath<CollectionRecord, Value>, _ value: Value) throws {
            let initial = base[keyPath: key]
            guard value != initial else { return }
            guard latest[keyPath: key] == initial || latest[keyPath: key] == value else { throw CollectionError.conflict }
            merged[keyPath: key] = value
        }
        try mergeField(\.title, title)
        if title != base.title { merged.titleEdited = true }
        try mergeField(\.note, note)
        let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        try mergeField(\.folder, name.isEmpty ? nil : name)
        if editsBody { try mergeField(\.body, body) }
        latest = merged
    }
}
