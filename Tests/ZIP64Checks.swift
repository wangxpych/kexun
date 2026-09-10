import Foundation

@main
struct ZIP64Checks {
    static func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("kexun-zip64-checks-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        func folder(_ name: String) throws -> URL {
            let result = root.appendingPathComponent(name)
            try fm.createDirectory(at: result, withIntermediateDirectories: true)
            return result
        }
        func reject(_ data: Data, _ name: String) throws {
            let url = root.appendingPathComponent("\(name).zip")
            try data.write(to: url)
            do { _ = try StreamingZIP.decode(url, into: folder(name)); preconditionFailure("Accepted \(name)") }
            catch { print("PASS reject: \(name)") }
        }
        let source = root.appendingPathComponent("source")
        try Data("ZIP64 可寻".utf8).write(to: source)
        let archive = root.appendingPathComponent("small64.zip")
        try StreamingZIP.encode([("assets/one", source)], to: archive, forceZIP64: true)
        let entries = try StreamingZIP.decode(archive, into: folder("small-out"))
        let result = try Data(contentsOf: entries["assets/one"]!.url)
        check(result == Data("ZIP64 可寻".utf8), "ZIP64 payload differs")
        let bytes = try Data(contentsOf: archive)
        check(bytes.get(18, 4) == UInt64(UInt32.max), "Not ZIP64 local size")
        check(bytes.get(bytes.count - 98, 4) == 0x06064b50, "Missing ZIP64 EOCD")
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        verify.arguments = ["-t", archive.path]
        try verify.run(); verify.waitUntilExit()
        check(verify.terminationStatus == 0, "System unzip rejected small ZIP64")
        print("PASS: forced small ZIP64 roundtrip and system unzip interoperability")

        var bad = bytes
        bad.replace(at: bad.count - 34, with: UInt64.max, width: 8)
        try reject(bad, "locator-overflow")
        bad = bytes
        bad.replace(at: 30 + "assets/one".utf8.count + 4, with: UInt64.max, width: 8)
        try reject(bad, "local-size-overflow")
        bad = bytes
        bad.replace(at: bad.count - 98 + 48, with: UInt64.max, width: 8)
        try reject(bad, "central-offset-overflow")
        bad = bytes
        bad.replace(at: bad.count - 98 + 24, with: UInt64.max, width: 8)
        bad.replace(at: bad.count - 98 + 32, with: UInt64.max, width: 8)
        try reject(bad, "entry-count-bomb")
        bad = bytes
        bad.replace(at: 28, with: 4, width: 2)
        try reject(bad, "truncated-local-extra")
        bad = bytes
        bad.replace(at: 8, with: 8, width: 2)
        try reject(bad, "compressed-local")
        try reject(Data(bytes.dropLast(1)), "truncated-eocd")

        let classic = root.appendingPathComponent("classic.zip")
        try StreamingZIP.encode([("a", source)], to: classic)
        let classicEntries = try StreamingZIP.decode(classic, into: folder("classic-out"))
        check(classicEntries.count == 1, "Classic compatibility failed")
        print("PASS: classic ZIP remains readable")

        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        let many = root.appendingPathComponent("many.zip")
        try StreamingZIP.encode((0..<65536).map { ("item-\($0)", empty) }, to: many)
        let manyEntries = try StreamingZIP.decode(many, into: folder("many-out"))
        check(manyEntries.count == 65536, "ZIP64 entry count truncated")
        print("PASS: actual 65,536 entries encoded and extracted")

        if CommandLine.arguments.contains("--large") {
            let start = Date()
            let sparse = root.appendingPathComponent("large-source")
            check(fm.createFile(atPath: sparse.path, contents: nil), "Create sparse source failed")
            let handle = try FileHandle(forWritingTo: sparse)
            let length: UInt64 = 4 * 1024 * 1024 * 1024 + 1024
            try handle.truncate(atOffset: length); try handle.close()
            let large = root.appendingPathComponent("large.zip")
            // Production streaming reads every byte of the sparse source, writes actual ZIP payload,
            // then extracts every byte. The second entry exercises a >32-bit local header offset.
            try StreamingZIP.encode([("large", sparse), ("after-large", source)], to: large)
            let restored = try StreamingZIP.decode(large, into: folder("large-out"))
            check(restored["large"]?.size == length, "64-bit size truncated")
            let originalHash = try StreamingZIP.inspect(sparse).sha
            check(restored["large"]?.sha == originalHash, "Large SHA mismatch")
            let tail = try Data(contentsOf: restored["after-large"]!.url)
            check(tail == Data("ZIP64 可寻".utf8), "64-bit offset corrupted tail")
            print("PASS: actual \(length)-byte payload (>4 GiB) roundtrip, CRC/SHA and second entry 64-bit offset; elapsed \(Date().timeIntervalSince(start)) s")
        } else {
            print("NOT RUN: actual >4 GiB payload; use --large (about 8 GiB temporary disk)")
        }
        print("PASS: ZIP64 checks complete; test-owned fixtures cleaned on exit")
    }
}

private extension Data {
    func get(_ offset: Int, _ width: Int) -> UInt64 { (0..<width).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) } }
    mutating func replace(at offset: Int, with value: UInt64, width: Int) {
        for index in 0..<width { self[offset + index] = UInt8((value >> (index * 8)) & 255) }
    }
}
