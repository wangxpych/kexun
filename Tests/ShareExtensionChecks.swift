import Foundation

/// Run with `bash Tests/check-share-extension.sh`. These are model/storage checks,
/// not a UI test or evidence of an actual cross-process App Group session.
@main
struct ShareExtensionChecks {
    static func main() throws {
        var batch = ShareBatchProgress(total: 4)
        precondition(batch.pendingCount == 4 && batch.remaining == [0, 1, 2, 3])
        batch.recordSaved(0)
        batch.recordSkipped(1)
        batch.recordFailure(2, message: "provider unavailable")
        precondition(batch.saved == [0] && batch.skipped == [1])
        precondition(batch.completed == [0, 1] && batch.failures.count == 1 && batch.pendingCount == 1)
        precondition(batch.remaining == [2, 3], "Retry must exclude explicitly skipped duplicates")

        batch.beginAttempt(2)
        precondition(batch.failures.isEmpty && batch.pendingCount == 2, "Interrupted attempts stay pending")
        batch.recordSaved(2)
        batch.recordFailure(3, message: "file permission")
        precondition(batch.saved.count == 2 && batch.skipped.count == 1 && batch.failures.count == 1 && batch.pendingCount == 0)
        batch.recordSkipped(3)
        precondition(batch.remaining.isEmpty && batch.saved.count == 2 && batch.skipped.count == 2)
        batch.recordFailure(1, message: "must not retry")
        batch.recordSaved(1)
        precondition(batch.failures.isEmpty && batch.skipped.contains(1) && !batch.saved.contains(1))

        var allSkipped = ShareBatchProgress(total: 2)
        allSkipped.recordSkipped(0)
        allSkipped.recordSkipped(1)
        precondition(allSkipped.remaining.isEmpty && allSkipped.saved.isEmpty && allSkipped.skipped.count == 2)

        // Use the production error dispatcher: choosing Skip in the link picker
        // must not be mistaken for a provider failure or a stop of the whole batch.
        var linkChoices = ShareBatchProgress(total: 4)
        linkChoices.recordSaved(0)
        linkChoices.beginAttempt(1)
        precondition(linkChoices.resolveAttemptError(ShareItemDecision.skipped, at: 1) == .continueBatch)
        linkChoices.beginAttempt(2)
        precondition(linkChoices.resolveAttemptError(CollectionError.invalid("provider unavailable"), at: 2) == .continueBatch)
        linkChoices.beginAttempt(3)
        precondition(linkChoices.resolveAttemptError(CancellationError(), at: 3) == .stopBatch)
        precondition(linkChoices.saved == [0] && linkChoices.skipped == [1])
        precondition(linkChoices.failures.keys.sorted() == [2] && linkChoices.pendingCount == 1)
        precondition(linkChoices.remaining == [2, 3], "Retry excludes saved and deliberately skipped links, but retains failed and stopped inputs")
        linkChoices.beginAttempt(2)
        precondition(linkChoices.resolveAttemptError(ShareItemDecision.skipped, at: 2) == .continueBatch)
        linkChoices.recordSaved(3)
        precondition(linkChoices.remaining.isEmpty && linkChoices.failures.isEmpty)
        precondition(linkChoices.saved == [0, 3] && linkChoices.skipped == [1, 2])

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunShareChecks-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("collections.sqlite")
        let writer = try CollectionRepository(url: url)
        var records: [CollectionRecord] = []
        let boundaryName = String(repeating: "边", count: 40)
        for folder in ["工作", "阅读", "工作", boundaryName, nil] as [String?] {
            var record = CollectionRecord(kind: .text, title: UUID().uuidString)
            record.folder = folder
            records.append(record)
        }
        try writer.insert(records, isPro: true)
        let reader = try CollectionRepository(url: url)
        let decoded = try reader.all()
        precondition(ShareFolderSelection.available(in: decoded) == ["工作", "阅读", boundaryName].sorted())
        for invalidName in [String(repeating: "长", count: 41), " "] {
            var invalid = CollectionRecord(kind: .text, title: "Invalid folder boundary")
            invalid.folder = invalidName
            do {
                try writer.insert([invalid], isPro: true)
                fatalError("Out-of-bounds folder must not enter shared storage")
            } catch CollectionError.invalid { }
        }
        let afterRejections = try reader.all()
        precondition(afterRejections.count == records.count, "Rejected names must not create records")
        try ShareFolderSelection.validate(nil, in: [])
        try ShareFolderSelection.validate("工作", in: decoded)
        do {
            try ShareFolderSelection.validate("已改名的旧组", in: decoded)
            fatalError("Stale folder selection must fail rather than recreate an old group")
        } catch CollectionError.invalid { }

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(records[0])) as! [String: Any]
        legacy.removeValue(forKey: "folder")
        let legacyRecord = try JSONDecoder().decode(CollectionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyRecord.folder == nil, "Existing shared records remain ungrouped")
        print("PASS: saved/skipped/failed/pending, explicit link skip vs provider failure vs batch cancellation, skip-excluding retry, interruption, all-skipped completion, shared SQLite folder decoding, 40-character boundary, oversized/blank rejection, legacy and stale selection")
    }
}
