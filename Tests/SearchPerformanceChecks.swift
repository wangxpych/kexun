import Foundation

@main
struct SearchPerformanceChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunSearchScale-\(UUID())")
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        var records: [CollectionRecord] = []
        for index in 0..<1000 {
            var record = CollectionRecord(kind: ContentKind.allCases[index % 4], title: "资料 \(index)")
            record.body = String(repeating: "收藏资料需要时找回。", count: 100)
            record.extractedText = String(repeating: "识别文本与文件内容。", count: 100)
            record.note = index == 731 ? "唯一目标 售后凭证" : "普通备注"
            record.source = index % 2 == 0 ? "example.com" : "本地文件"
            if record.kind == .link { record.originalURL = "https://example.com/items/\(index)" }
            if index % 3 == 0 { record.archivedAt = Date() }
            records.append(record)
        }
        try repository.insert(records, isPro: true)
        let query = CollectionQuery(text: "唯一目标 凭证")
        var persisted: [Double] = [], inMemory: [Double] = []
        for _ in 0..<10 {
            let start = Date()
            let result = try repository.search(query)
            persisted.append(Date().timeIntervalSince(start) * 1000)
            precondition(result.count == 1 && result.first?.id == records[731].id)
            let memoryStart = Date()
            let visible = records.filter(query.matches)
            inMemory.append(Date().timeIntervalSince(memoryStart) * 1000)
            precondition(visible.count == 1)
        }
        func report(_ name: String, _ values: [Double]) {
            let sorted = values.sorted()
            print(String(format: "%@: median %.2f ms, max %.2f ms (10 runs)", name, sorted[5], sorted.last!))
        }
        print("System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Fixture: 1000 mixed-type metadata records, about 2000 Chinese characters per record; no image decoding or UI rendering measured")
        report("SQLite decode + search", persisted)
        report("In-memory filtering used by list", inMemory)
        print("PASS: every query found the exact expected record. Fixture: \(root.path)")
    }
}
