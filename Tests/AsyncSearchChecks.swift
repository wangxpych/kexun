import Foundation

@main
struct AsyncSearchChecks {
    static func main() async throws {
        var first = CollectionRecord(kind: .text, title: "中文目标", body: "alpha searchable")
        first.createdAt = Date(timeIntervalSince1970: 100)
        var second = CollectionRecord(kind: .text, title: "中文目标", body: "alpha searchable")
        second.createdAt = Date(timeIntervalSince1970: 200)
        second.archivedAt = Date()
        var deleted = second
        deleted.id = UUID()
        deleted.deletedAt = Date()
        var query = CollectionQuery(text: "中文 ALPHA")
        let newest = try await CollectionSearch.run(records: [first, deleted, second], query: query)
        precondition(newest.map(\.id) == [second.id, first.id])
        query.newestFirst = false
        let oldest = try await CollectionSearch.run(records: [first, second], query: query)
        precondition(oldest.map(\.id) == [first.id, second.id])
        query.scope = .inbox
        let inbox = try await CollectionSearch.run(records: [first, second], query: query)
        precondition(inbox.map(\.id) == [first.id])
        let large = (0..<25000).map { CollectionRecord(kind: .text, title: "记录\($0)", body: String(repeating: "普通文字", count: 100)) }
        let cancelled = Task { try await CollectionSearch.run(records: large, query: CollectionQuery(text: "不存在")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled worker published a result") }
        catch is CancellationError { }
        print("PASS: async Chinese/case-insensitive search, archive/trash scopes, both sort directions, cancelled worker rejects results")
    }
}
