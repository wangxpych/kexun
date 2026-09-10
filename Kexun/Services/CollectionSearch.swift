import Foundation

nonisolated enum CollectionSearch {
    static func run(records: [CollectionRecord], query: CollectionQuery) async throws -> [CollectionRecord] {
        let worker = Task.detached(priority: .userInitiated) {
            var results: [CollectionRecord] = []
            for record in records {
                try Task.checkCancellation()
                if query.matches(record) { results.append(record) }
            }
            try Task.checkCancellation()
            results.sort {
                if $0.createdAt == $1.createdAt { return $0.id.uuidString < $1.id.uuidString }
                return query.newestFirst ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
            }
            try Task.checkCancellation()
            return results
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
