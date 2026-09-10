import Foundation

/// Fault recovery is separate from ordinary merge restore: the unreadable original stays intact.
nonisolated enum RecoveryArchive {
    struct Candidate: Codable, Sendable {
        let generation: UUID
        let itemCount: Int
    }

    static func stage(_ archive: URL, group: URL) throws -> Candidate {
        let generation = UUID()
        let root = try SharedStorage.createRecoveryRoot(group: group, generation: generation)
        do {
            let candidate = try restore(archive, root: root, generation: generation)
            // Written only after SQLite connection closes and the entire backup is validated.
            let marker = root.appendingPathComponent("recovery-ready.json")
            try JSONEncoder().encode(candidate).write(to: marker, options: .atomic)
            try SharedStorage.synchronizeRecoveryRoot(root)
            return candidate
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func restore(_ archive: URL, root: URL, generation: UUID) throws -> Candidate {
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        let assets = try AttachmentStore(root: root)
        _ = try BackupArchive.restoreFileReport(archive, repository: repository, assets: assets)
        try repository.checkIntegrity()
        return try Candidate(generation: generation, itemCount: repository.all().count)
    }
}
