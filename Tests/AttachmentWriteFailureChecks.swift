import Foundation
import Darwin

/// Run as a standalone macOS check. The file-size limit is confined to a child
/// process, never the app, test runner, shell, or host filesystem capacity.
@main struct AttachmentWriteFailureChecks {
    static func main() throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "limited-copy" {
            try limitedCopy(root: URL(fileURLWithPath: CommandLine.arguments[2]),
                            source: URL(fileURLWithPath: CommandLine.arguments[3]))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunWriteFailure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AttachmentStore(root: root)
        let source = root.appendingPathComponent("source.bin")
        let originalSource = root.appendingPathComponent("original.txt")
        let bytes = Data(repeating: 0x5A, count: 3 * 1024 * 1024)
        try bytes.write(to: source)
        try Data("Existing attachment must survive".utf8).write(to: originalSource)
        let original = try store.importFile(originalSource, contentType: "public.plain-text")
        let originalBytes = try Data(contentsOf: store.url(for: original))
        let before = try assetNames(root)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["limited-copy", root.path, source.path]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationReason == .exit && child.terminationStatus == 0,
                     "Limited copy subprocess failed: \(child.terminationStatus)")
        check(try assetNames(root) == before, "Failed copy left a partial or published asset")
        check(try Data(contentsOf: store.url(for: original)) == originalBytes)
        check(try Data(contentsOf: source) == bytes, "Source changed after failed copy")
        let retried = try store.importFile(source, contentType: "public.data")
        precondition(retried.byteCount == Int64(bytes.count))
        check(try Data(contentsOf: store.url(for: retried)) == bytes)
        check(try assetNames(root) == before.union([retried.id.uuidString]))
        print("PASS: real EFBIG write failure leaves no partial/published asset; existing attachment and source unchanged; unrestricted retry preserves all 3 MiB")
    }

    static func assetNames(_ root: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("assets").path))
    }

    static func check(_ value: Bool, _ message: String = "Attachment write failure check failed") {
        precondition(value, message)
    }

    static func limitedCopy(root: URL, source: URL) throws {
        let store = try AttachmentStore(root: root)
        let before = try assetNames(root)
        var original = rlimit()
        guard getrlimit(RLIMIT_FSIZE, &original) == 0 else { fatalError("Cannot read child limit") }
        let oldSignal = signal(SIGXFSZ, SIG_IGN)
        defer { signal(SIGXFSZ, oldSignal) }
        var limited = original
        limited.rlim_cur = min(original.rlim_cur, 1536 * 1024)
        guard setrlimit(RLIMIT_FSIZE, &limited) == 0 else { fatalError("Cannot constrain child file size") }
        defer { precondition(setrlimit(RLIMIT_FSIZE, &original) == 0) }
        do {
            _ = try store.importFile(source, contentType: "public.data")
            fatalError("Oversized copy unexpectedly succeeded under child file-size limit")
        } catch {
            func isFileTooLarge(_ error: NSError) -> Bool {
                if error.domain == NSPOSIXErrorDomain && error.code == Int(EFBIG) { return true }
                if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isFileTooLarge(underlying) }
                return false
            }
            precondition(isFileTooLarge(error as NSError), "Expected actual EFBIG, got \(error)")
        }
        check(try assetNames(root) == before)
    }
}
