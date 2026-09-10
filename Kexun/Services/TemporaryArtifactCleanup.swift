import Foundation

/// Only app-owned staging directories in the app's private temporary container.
nonisolated enum TemporaryArtifactCleanup {
    private static let prefixes = ["kexun-backup-", "KexunPreview-", "KexunPhotoTransfer-"]

    static func candidates(in root: URL, olderThan cutoff: Date) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { eligible($0, cutoff: cutoff) }
    }

    private static func eligible(_ url: URL, cutoff: Date) -> Bool {
        let name = url.lastPathComponent
        guard prefixes.contains(where: { prefix in
            guard name.hasPrefix(prefix) else { return false }
            let suffix = String(name.dropFirst(prefix.count))
            return UUID(uuidString: suffix)?.uuidString == suffix.uppercased()
        }), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        attributes[.type] as? FileAttributeType == .typeDirectory,
        let modified = attributes[.modificationDate] as? Date, modified < cutoff else { return false }
        return true
    }

    /// Recheck before deletion; a recent or replaced staging directory is never removed.
    @discardableResult
    static func remove(_ candidates: [URL], olderThan cutoff: Date) -> Int {
        var removed = 0
        for url in candidates where eligible(url, cutoff: cutoff) {
            do { try FileManager.default.removeItem(at: url); removed += 1 }
            catch { /* Best effort: leave the artifact for a later launch, never fail opening data. */ }
        }
        return removed
    }
}
