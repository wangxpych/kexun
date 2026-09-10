import Foundation
import PDFKit

/// Read-only, bounded search for the detail reader. Offsets are UTF-16, as required by PDFKit.
nonisolated enum RecordSearchMatches {
    static let maximumTextLength = 1_000_000
    static let maximumHits = 500
    static let maximumPDFBytes = 32 * 1024 * 1024

    struct Hit: Sendable {
        var field: String
        var excerpt: String
        var highlight: NSRange
        var sourceRange: NSRange
        var pageIndex: Int?
    }

    struct Result: Sendable {
        var hits: [Hit] = []
        var limited = false
    }

    struct PDFResult: Sendable {
        var data: Data
        var result: Result
    }

    static func terms(_ query: String) -> (values: [String], limited: Bool) {
        // Bound query processing before tokenization, including hostile or accidental pasted text.
        let prefix = String(query.prefix(4096))
        let raw = prefix.split(whereSeparator: \.isWhitespace)
        var values: [String] = []
        var limited = prefix != query || raw.count > 32
        for value in raw.prefix(32) {
            let term = String(value.prefix(256))
            limited = limited || term != value
            if !values.contains(where: { $0.compare(term, options: .caseInsensitive, locale: .current) == .orderedSame }) {
                values.append(term)
            }
        }
        return (values, limited)
    }

    static func scan(record: CollectionRecord, query: String) throws -> Result {
        let parsed = terms(query)
        guard !parsed.values.isEmpty else { return Result() }
        let fields = [(String(localized: "标题"), record.title), (String(localized: "正文"), record.body),
                      (String(localized: "网页正文"), record.article?.text ?? ""),
                      (String(localized: "备注"), record.note), (String(localized: "链接"), record.originalURL ?? ""),
                      (String(localized: "来源"), record.source)]
            + record.attachments.map { (String(localized: "文件名"), $0.originalName) }
            + [(String(localized: "识别文本"), record.extractedText)]
        var result = Result(limited: parsed.limited)
        var budget = maximumTextLength
        for (label, text) in fields {
            try append(text: text, field: label, terms: parsed.values, page: nil, budget: &budget, result: &result)
        }
        return result
    }

    static func scanPDF(data: Data, query: String) throws -> PDFResult {
        guard data.count <= maximumPDFBytes else {
            throw CollectionError.invalid(String(localized: "页码定位暂支持 32 MB 以内的 PDF；仍可查看下方已保存的识别文本。"))
        }
        guard let document = PDFDocument(data: data), !document.isLocked else {
            throw CollectionError.invalid(String(localized: "PDF 无法读取或需要密码；仍可查看下方已保存的识别文本。"))
        }
        let parsed = terms(query)
        var result = Result(limited: parsed.limited || document.pageCount > 1000)
        var budget = maximumTextLength
        if !parsed.values.isEmpty {
            for index in 0..<min(document.pageCount, 1000) {
                try Task.checkCancellation()
                if budget <= 0 || result.hits.count >= maximumHits { result.limited = true; break }
                let value = document.page(at: index)?.string ?? ""
                try append(text: value, field: String(localized: "PDF 正文"), terms: parsed.values,
                           page: index, budget: &budget, result: &result)
            }
        }
        return PDFResult(data: data, result: result)
    }

    static func loadPDF(reference: AttachmentReference, attachments: AttachmentStore, query: String) throws -> PDFResult {
        try Task.checkCancellation()
        let data = try attachments.withExclusiveAccess {
            let url = try attachments.url(for: reference)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= maximumPDFBytes else {
                throw CollectionError.invalid(String(localized: "页码定位暂支持 32 MB 以内的普通 PDF 文件；仍可查看下方已保存的识别文本。"))
            }
            // Read a bounded snapshot under the attachment lifecycle lock, never expose a mutable original to PDFView.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try handle.read(upToCount: maximumPDFBytes + 1) ?? Data()
        }
        try Task.checkCancellation()
        return try scanPDF(data: data, query: query)
    }

    private static func append(text: String, field: String, terms: [String], page: Int?,
                               budget: inout Int, result: inout Result) throws {
        try Task.checkCancellation()
        guard !text.isEmpty else { return }
        guard budget > 0, result.hits.count < maximumHits else { result.limited = true; return }
        let original = text as NSString
        var length = min(original.length, budget)
        if length > 0, length < original.length {
            let boundary = original.rangeOfComposedCharacterSequence(at: length - 1)
            if NSMaxRange(boundary) > length { length = boundary.location }
        }
        let bounded = original.substring(to: length) as NSString
        budget -= length
        if length < original.length { result.limited = true }
        var ranges: [NSRange] = []
        for term in terms {
            var cursor = 0
            var termHits = 0
            while cursor < bounded.length {
                try Task.checkCancellation()
                let found = bounded.range(of: term, options: .caseInsensitive,
                                          range: NSRange(location: cursor, length: bounded.length - cursor), locale: .current)
                guard found.location != NSNotFound, found.length > 0 else { break }
                ranges.append(found)
                termHits += 1
                if termHits > maximumHits { result.limited = true; break }
                cursor = NSMaxRange(found)
            }
        }
        ranges.sort { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in ranges {
            if let last = merged.last, range.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        for range in merged {
            guard result.hits.count < maximumHits else { result.limited = true; break }
            let start = max(0, range.location - 100)
            let end = min(bounded.length, NSMaxRange(range) + 180)
            let context = bounded.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            let leading = context.location > 0 ? "…" : ""
            let excerpt = leading + bounded.substring(with: context) + (NSMaxRange(context) < original.length ? "…" : "")
            result.hits.append(Hit(field: field, excerpt: excerpt,
                                   highlight: NSRange(location: (leading as NSString).length + range.location - context.location, length: range.length),
                                   sourceRange: range, pageIndex: page))
        }
    }
}
