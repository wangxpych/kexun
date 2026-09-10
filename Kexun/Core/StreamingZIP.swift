import Foundation
import CryptoKit

/// Strict stored ZIP reader/writer. Payloads are streamed in 1 MiB chunks; never inflate input.
/// PKWARE APPNOTE 6.3.10 sections 4.3.14–16 / 4.5.3: ZIP64 only where needed.
/// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
nonisolated enum StreamingZIP {
    static let maximumBytes: UInt64 = UInt64(Int64.max)
    private static let marker32 = UInt64(UInt32.max)
    struct Entry { let name: String; let url: URL; let size: UInt64; let crc: UInt32; let sha: String }
    private static let table: [UInt32] = (0..<256).map { value in
        var value = UInt32(value)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }
    static func inspect(_ url: URL) throws -> (size: UInt64, crc: UInt32, sha: String) {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw invalid(String(localized: "备份仅支持普通文件。")) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try transfer(input, output: nil, remaining: nil)
    }
    private static func transfer(_ input: FileHandle, output: FileHandle?, remaining: UInt64?) throws -> (size: UInt64, crc: UInt32, sha: String) {
        var total: UInt64 = 0, crc: UInt32 = 0xffffffff
        var sha = SHA256()
        while remaining == nil || total < remaining! {
            let count = Int(min(1024 * 1024, remaining.map { $0 - total } ?? 1024 * 1024))
            guard let chunk = try input.read(upToCount: count), !chunk.isEmpty else {
                if let remaining, total != remaining { throw invalid(String(localized: "备份数据被截断。")) }
                break
            }
            total = try adding(total, UInt64(chunk.count))
            sha.update(data: chunk)
            for byte in chunk { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 255)] }
            try output?.write(contentsOf: chunk)
        }
        return (total, crc ^ 0xffffffff, sha.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func encode(_ files: [(String, URL)], to destination: URL, forceZIP64: Bool = false) throws {
        guard Set(files.map(\.0)).count == files.count else { throw invalid(String(localized: "备份文件重复。")) }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw invalid(String(localized: "备份目标已存在，未覆盖。")) }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw invalid(String(localized: "无法创建备份，请检查剩余空间。")) }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let centralURL = destination.deletingLastPathComponent().appendingPathComponent(".zip-directory-\(UUID())")
        guard FileManager.default.createFile(atPath: centralURL.path, contents: nil) else {
            try? FileManager.default.removeItem(at: destination)
            throw invalid(String(localized: "无法创建 ZIP 目录，请检查剩余空间。"))
        }
        defer { try? FileManager.default.removeItem(at: centralURL) }
        do {
            let centralFile = try FileHandle(forWritingTo: centralURL)
            defer { try? centralFile.close() }
            var hasZIP64Entry = forceZIP64
            for (name, url) in files {
                try validate(name)
                let info = try inspect(url), path = Data(name.utf8), offset = try output.offset()
                let size64 = forceZIP64 || info.size >= marker32
                let offset64 = forceZIP64 || offset >= marker32
                hasZIP64Entry = hasZIP64Entry || size64 || offset64
                let localExtra = zip64Extra(size64 ? [info.size, info.size] : [])
                let centralExtra = zip64Extra((size64 ? [info.size, info.size] : []) + (offset64 ? [offset] : []))
                _ = try adding(offset, try adding(info.size, UInt64(30 + path.count + localExtra.count)))
                var header = Data()
                header.put(0x04034b50, 4); header.put(size64 ? 45 : 20, 2); header.put(0x800, 2); header.put(0, 2)
                header.put(0, 2); header.put(0, 2); header.put(UInt64(info.crc), 4)
                header.put(size64 ? marker32 : info.size, 4); header.put(size64 ? marker32 : info.size, 4)
                header.put(UInt64(path.count), 2); header.put(UInt64(localExtra.count), 2); header.append(path); header.append(localExtra)
                try output.write(contentsOf: header)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                let copied = try transfer(input, output: output, remaining: nil)
                guard copied == info else { throw invalid(String(localized: "文件在备份期间发生变化，请重试。")) }
                var central = Data()
                central.put(0x02014b50, 4); central.put(size64 || offset64 ? 45 : 20, 2); central.put(size64 || offset64 ? 45 : 20, 2); central.put(0x800, 2); central.put(0, 2)
                central.put(0, 2); central.put(0, 2); central.put(UInt64(info.crc), 4)
                central.put(size64 ? marker32 : info.size, 4); central.put(size64 ? marker32 : info.size, 4); central.put(UInt64(path.count), 2)
                central.put(UInt64(centralExtra.count), 2); central.put(0, 2); central.put(0, 2); central.put(0, 2); central.put(0, 4)
                central.put(offset64 ? marker32 : offset, 4); central.append(path); central.append(centralExtra)
                try centralFile.write(contentsOf: central)
            }
            let offset = try output.offset()
            let centralSize = try centralFile.offset()
            try centralFile.close()
            let directoryInput = try FileHandle(forReadingFrom: centralURL)
            defer { try? directoryInput.close() }
            while let chunk = try directoryInput.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            let zip64 = hasZIP64Entry || files.count >= 65535 || offset >= marker32 || centralSize >= marker32
            if zip64 {
                let endOffset = try output.offset()
                var end64 = Data()
                end64.put(0x06064b50, 4); end64.put(44, 8); end64.put(45, 2); end64.put(45, 2)
                end64.put(0, 4); end64.put(0, 4); end64.put(UInt64(files.count), 8); end64.put(UInt64(files.count), 8)
                end64.put(centralSize, 8); end64.put(offset, 8)
                end64.put(0x07064b50, 4); end64.put(0, 4); end64.put(endOffset, 8); end64.put(1, 4)
                try output.write(contentsOf: end64)
            }
            var end = Data()
            end.put(0x06054b50, 4); end.put(0, 4)
            end.put(zip64 ? 65535 : UInt64(files.count), 2); end.put(zip64 ? 65535 : UInt64(files.count), 2)
            end.put(zip64 ? marker32 : centralSize, 4); end.put(zip64 ? marker32 : offset, 4); end.put(0, 2)
            try output.write(contentsOf: end); try output.synchronize()
        } catch { try? output.close(); try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func decode(_ source: URL, into directory: URL) throws -> [String: Entry] {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size >= 22, size <= maximumBytes else { throw invalid(String(localized: "备份为空或超出文件系统可寻址范围。")) }
        func read(_ at: UInt64, _ count: Int) throws -> Data {
            guard at <= size, count >= 0, UInt64(count) <= size - at else { throw invalid(String(localized: "ZIP 数据被截断。")) }
            if count == 0 { return Data() }
            try input.seek(toOffset: at)
            guard let data = try input.read(upToCount: count), data.count == count else { throw invalid(String(localized: "ZIP 数据被截断。")) }
            return data
        }
        let end = try read(size - 22, 22)
        var centralStart = end.get(16, 4), centralSize = end.get(12, 4), count = end.get(10, 2), directoryEnd = size - 22
        guard end.get(0, 4) == 0x06054b50, end.get(4, 4) == 0, end.get(8, 2) == count,
              end.get(20, 2) == 0 else { throw invalid(String(localized: "备份目录不完整或 ZIP 格式不支持。")) }
        if count == 65535 || centralStart == marker32 || centralSize == marker32 {
            guard size >= 98 else { throw invalid(String(localized: "ZIP64 目录被截断。")) }
            let locator = try read(size - 42, 20)
            let endOffset = locator.get(8, 8)
            guard locator.get(0, 4) == 0x07064b50, locator.get(4, 4) == 0, locator.get(16, 4) == 1,
                  endOffset <= size - 98 else { throw invalid(String(localized: "ZIP64 定位器无效或不支持分卷。")) }
            let end64 = try read(endOffset, 56)
            guard end64.get(0, 4) == 0x06064b50, end64.get(4, 8) == 44, end64.get(14, 2) == 45,
                  end64.get(16, 4) == 0, end64.get(20, 4) == 0, end64.get(24, 8) == end64.get(32, 8),
                  endOffset + 56 == size - 42 else { throw invalid(String(localized: "ZIP64 结束记录无效。")) }
            let count64 = end64.get(32, 8), size64 = end64.get(40, 8), start64 = end64.get(48, 8)
            guard (count == 65535 || count == count64), (centralSize == marker32 || centralSize == size64),
                  (centralStart == marker32 || centralStart == start64) else { throw invalid(String(localized: "ZIP64 与经典目录不一致。")) }
            count = count64; centralSize = size64; centralStart = start64; directoryEnd = endOffset
        }
        guard centralStart <= directoryEnd, centralSize == directoryEnd - centralStart,
              count <= centralSize / 47 else { throw invalid(String(localized: "ZIP 目录范围或条目数量无效。")) }
        var position = centralStart, localEnd: UInt64 = 0
        var result: [String: Entry] = [:]
        for _ in 0..<count {
            let header = try read(position, 46)
            let nameLength = Int(header.get(28, 2)), extraLength = Int(header.get(30, 2))
            let next = try adding(position, UInt64(46 + nameLength + extraLength))
            guard header.get(0, 4) == 0x02014b50, header.get(8, 2) == 0x800, header.get(10, 2) == 0,
                  header.get(32, 2) == 0, header.get(34, 2) == 0, header.get(38, 4) == 0,
                  next <= directoryEnd else { throw invalid(String(localized: "备份含压缩、加密或不受支持的条目。")) }
            let extra = try read(position + 46 + UInt64(nameLength), extraLength)
            let fields = try expanded(extra, uncompressed: header.get(24, 4), compressed: header.get(20, 4), offset: header.get(42, 4))
            let length = fields.size, offset = fields.offset!
            guard offset == localEnd, (extra.isEmpty || header.get(6, 2) == 45) else { throw invalid(String(localized: "备份条目重叠或 ZIP64 版本无效。")) }
            let path = try read(position + 46, nameLength)
            guard let name = String(data: path, encoding: .utf8), result[name] == nil else { throw invalid(String(localized: "备份文件名无效或重复。")) }
            try validate(name)
            let local = try read(offset, 30)
            let localExtraLength = Int(local.get(28, 2))
            let payload = try adding(offset, UInt64(30 + nameLength + localExtraLength))
            let localExtra = try read(try adding(offset, UInt64(30 + nameLength)), localExtraLength)
            let localFields = try expanded(localExtra, uncompressed: local.get(22, 4), compressed: local.get(18, 4), offset: nil)
            guard local.get(0, 4) == 0x04034b50, local.get(6, 2) == 0x800, local.get(8, 2) == 0,
                  local.get(14, 4) == header.get(16, 4), localFields.size == length,
                  local.get(26, 2) == UInt64(nameLength), (localExtra.isEmpty || local.get(4, 2) == 45),
                  try read(offset + 30, nameLength) == path, payload <= centralStart, length <= centralStart - payload else { throw invalid(String(localized: "ZIP 本地记录与目录不一致。")) }
            let target = directory.appendingPathComponent(UUID().uuidString)
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw invalid(String(localized: "无法展开备份，请检查存储空间。")) }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try input.seek(toOffset: payload)
            let info = try transfer(input, output: output, remaining: length)
            guard UInt64(info.crc) == header.get(16, 4) else { throw invalid(String(localized: "备份 CRC 校验失败。")) }
            try output.synchronize()
            result[name] = Entry(name: name, url: target, size: length, crc: info.crc, sha: info.sha)
            position = next; localEnd = payload + length
        }
        guard position == directoryEnd, localEnd == centralStart else { throw invalid(String(localized: "备份含未登记内容或目录不完整。")) }
        return result
    }
    private static func zip64Extra(_ fields: [UInt64]) -> Data {
        guard !fields.isEmpty else { return Data() }
        var data = Data(); data.put(1, 2); data.put(UInt64(fields.count * 8), 2)
        for field in fields { data.put(field, 8) }
        return data
    }
    /// Only fields whose legacy value is the sentinel occur, in APPNOTE's fixed order.
    private static func expanded(_ extra: Data, uncompressed: UInt64, compressed: UInt64, offset: UInt64?) throws -> (size: UInt64, offset: UInt64?) {
        let needsSize = uncompressed == marker32, needsCompressed = compressed == marker32, needsOffset = offset == marker32
        let expected = (needsSize ? 8 : 0) + (needsCompressed ? 8 : 0) + (needsOffset ? 8 : 0)
        guard expected == 0 ? extra.isEmpty : (extra.count == expected + 4 && extra.get(0, 2) == 1 && extra.get(2, 2) == UInt64(expected)),
              offset != nil || needsSize == needsCompressed else { throw invalid(String(localized: "ZIP64 扩展字段缺失、重复或长度无效。")) }
        var cursor = 4
        func value(_ original: UInt64) -> UInt64 {
            guard original == marker32 else { return original }
            defer { cursor += 8 }
            return extra.get(cursor, 8)
        }
        let originalSize = value(uncompressed), storedSize = value(compressed), originalOffset = offset.map { value($0) }
        guard originalSize == storedSize, originalSize <= maximumBytes, originalOffset.map({ $0 <= maximumBytes }) ?? true else { throw invalid(String(localized: "ZIP64 长度溢出或包含压缩内容。")) }
        return (originalSize, originalOffset)
    }
    private static func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        guard lhs <= maximumBytes, rhs <= maximumBytes - lhs else { throw invalid(String(localized: "ZIP 偏移或长度溢出。")) }
        return lhs + rhs
    }
    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name.utf8.count < 65536, !name.contains("\\"), !name.contains("\0"),
              !name.hasPrefix("/"), name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw invalid(String(localized: "备份文件路径不安全。")) }
    }
    private static func invalid(_ text: String) -> CollectionError { .invalid(text) }
}

nonisolated private extension Data {
    mutating func put(_ value: UInt64, _ width: Int) { for index in 0..<width { append(UInt8((value >> (index * 8)) & 255)) } }
    func get(_ offset: Int, _ width: Int) -> UInt64 { (0..<width).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) } }
}
