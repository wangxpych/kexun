import Foundation

nonisolated enum CaptureTitle {
    static func resolve(explicit: String = "", body: String) -> (value: String, edited: Bool) {
        let supplied = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty { return (supplied, true) }
        return (String(body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)), false)
    }
}

/// Derives an optional display title without changing the text that will be saved as the body.
nonisolated enum LinkShareText {
    static func suggestedTitle(in text: String, selectedURL: URL? = nil) -> String? {
        let urls = LinkParser.urls(in: text)
        let url: URL
        if let selectedURL {
            guard let match = urls.first(where: { $0.absoluteString == selectedURL.absoluteString }) else { return nil }
            url = match
        } else {
            guard urls.count == 1, let onlyURL = urls.first else { return nil }
            url = onlyURL
        }

        guard let range = text.range(of: url.absoluteString) else { return nil }
        if urls.count > 1 {
            let earlierEnd = urls.compactMap { candidate -> String.Index? in
                guard candidate.absoluteString != url.absoluteString,
                      let candidateRange = text.range(of: candidate.absoluteString),
                      candidateRange.upperBound <= range.lowerBound else { return nil }
                return candidateRange.upperBound
            }.max() ?? text.startIndex
            let candidate = text[earlierEnd..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }

        let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        var after = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if LinkSource.isXiaohongshuHost(url.host), after == "打开【小红书】，这篇笔记超精彩！" {
            after = ""
        }

        // Preserve unknown text instead of treating generic words such as “打开” as boilerplate.
        // The original body remains entirely owned by the caller.
        let candidate = [before, after].filter { !$0.isEmpty }.joined(separator: " ")
        return candidate.isEmpty ? nil : candidate
    }
}

nonisolated enum LinkSource {
    static func displayName(for source: String) -> String {
        isXiaohongshuHost(source) ? "小红书" : source
    }

    fileprivate static func isXiaohongshuHost(_ source: String?) -> Bool {
        guard let source else { return false }
        let host = source.lowercased()
        return ["xhslink.cn", "xhslink.com", "xiaohongshu.com"]
            .contains { host == $0 || host.hasSuffix(".\($0)") }
    }
}

nonisolated enum ShareText {
    static func decodeProviderValue(_ value: NSSecureCoding?) -> String? {
        if let text = value as? String { return text }
        guard let data = value as? Data else { return nil }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
    }

    static func merge(_ pieces: [String]) -> String {
        var seen = Set<String>()
        return pieces.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }.joined(separator: "\n")
    }
}

nonisolated enum ContentKind: String, Codable, CaseIterable, Sendable, Hashable {
    case link, text, image, file
    var title: String {
        switch self { case .link: String(localized: "链接"); case .text: String(localized: "文字"); case .image: String(localized: "图片"); case .file: String(localized: "文件") }
    }
    var symbol: String {
        switch self { case .link: "link"; case .text: "text.alignleft"; case .image: "photo"; case .file: "doc" }
    }
}

nonisolated enum ProcessingState: String, Codable, Sendable { case pending, processing, complete, failed, unsupported }

nonisolated struct AttachmentReference: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var relativePath: String
    var originalName: String
    var contentType: String
    var byteCount: Int64
    var sha256: String
}

nonisolated struct CollectionRecord: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var updatedAt = Date()
    var deletedAt: Date?
    var archivedAt: Date?
    var version = 1
    var kind: ContentKind
    var title: String
    var body = ""
    var originalURL: String?
    var source = ""
    var note = ""
    var starred = false
    var titleEdited = false
    var attachments: [AttachmentReference] = []
    var extractedText = ""
    var processingState: ProcessingState = .complete
    var processingError: String?
    // Optional additions preserve decoding of existing databases and version-1 backups.
    var folder: String?
    var article: SavedWebArticle?
    var articleError: String?

    var searchableText: String {
        ([title, body, originalURL ?? "", source, note, extractedText, article?.text ?? ""] + attachments.map(\.originalName)).joined(separator: "\n")
    }
}

nonisolated struct SavedWebArticle: Codable, Equatable, Sendable {
    var text: String
    var sourceURL: String
    var capturedAt: Date
}

nonisolated struct CollectionQuery: Sendable, Hashable {
    enum Scope: Sendable, Hashable { case inbox, library, trash }
    var scope: Scope = .library
    var text = ""
    var kind: ContentKind?
    var source: String?
    /// nil = all folders; empty string = records with no folder.
    var folder: String?
    var starredOnly = false
    var archived: Bool?
    var since: Date?
    var newestFirst = true

    var activeFilterCount: Int {
        [kind != nil, source != nil, folder != nil, starredOnly, archived != nil, since != nil].filter { $0 }.count
    }

    mutating func resetFilters() {
        kind = nil
        source = nil
        folder = nil
        starredOnly = false
        archived = nil
        since = nil
    }

    /// Show the matching field, including OCR/PDF content, instead of unrelated body text.
    func snippet(for record: CollectionRecord, limit: Int = 160) -> String {
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let fields = [(String(localized: "正文"), record.body), (String(localized: "网页正文"), record.article?.text ?? ""), (String(localized: "备注"), record.note), (String(localized: "识别文本"), record.extractedText),
                      (String(localized: "链接"), record.originalURL ?? ""), (String(localized: "来源"), record.source)]
            + record.attachments.map { (String(localized: "文件名"), $0.originalName) } + [(String(localized: "标题"), record.title)]
        guard limit > 0 else { return "" }
        var best: (label: String, value: String, hits: Int)?
        for (label, value) in fields where !value.isEmpty {
            let hits = terms.filter { value.localizedCaseInsensitiveContains($0) }.count
            if best == nil || hits > best!.hits { best = (label, value, hits) }
        }
        guard let best else { return "" }
        let value = best.value
        let match = terms.compactMap { value.range(of: $0, options: .caseInsensitive, locale: .current) }
            .min { $0.lowerBound < $1.lowerBound }
        let start = match.map { value.index($0.lowerBound, offsetBy: -min(24, limit / 4), limitedBy: value.startIndex) ?? value.startIndex } ?? value.startIndex
        let end = value.index(start, offsetBy: limit, limitedBy: value.endIndex) ?? value.endIndex
        let excerpt = (start > value.startIndex ? "…" : "") + value[start..<end] + (end < value.endIndex ? "…" : "")
        return terms.isEmpty ? excerpt : String(localized: "\(best.label)：\(excerpt)")
    }

    func matches(_ record: CollectionRecord) -> Bool {
        if scope == .trash {
            guard record.deletedAt != nil else { return false }
        } else {
            guard record.deletedAt == nil else { return false }
            if scope == .inbox && record.archivedAt != nil { return false }
        }
        if let kind, record.kind != kind { return false }
        if let source, record.source != source { return false }
        if let folder, (record.folder ?? "") != folder { return false }
        if starredOnly && !record.starred { return false }
        if let archived, (record.archivedAt != nil) != archived { return false }
        if let since, record.createdAt < since { return false }
        return text.split(whereSeparator: \.isWhitespace).allSatisfy {
            record.searchableText.localizedCaseInsensitiveContains(String($0))
        }
    }
}

nonisolated enum CollectionError: LocalizedError {
    case database(String), limit(Int), missing, conflict, invalid(String), duplicate(UUID)
    var errorDescription: String? {
        switch self {
        case .database(let message): String(localized: "数据操作失败：\(message)。请重试，现有数据不会被清空。")
        case .limit(let remaining): String(localized: "免费版最多保存 100 条，目前还可保存 \(remaining) 条。可删除部分收藏，或升级 Pro。")
        case .missing: String(localized: "这条收藏已不存在，请刷新后重试。")
        case .conflict: String(localized: "收藏已发生变化，请刷新后再操作。")
        case .invalid(let message): message
        case .duplicate: String(localized: "这个链接已经收下过了。")
        }
    }
}

nonisolated enum LinkParser {
    static func selectedURL(in text: String, selection: String) throws -> URL {
        let candidates = urls(in: text)
        if candidates.count == 1 { return candidates[0] }
        guard !candidates.isEmpty else { throw CollectionError.invalid(String(localized: "请输入有效的 HTTP 或 HTTPS 链接。")) }
        guard let selected = candidates.first(where: { $0.absoluteString == selection }) else {
            throw CollectionError.invalid(String(localized: "请选择当前正文中要保存的链接。"))
        }
        return selected
    }

    static func urls(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    static func normalized(_ raw: String) -> String {
        guard var parts = URLComponents(string: raw) else { return raw }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        // Preserve query and fragment: either can select distinct application content.
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? raw
    }
}
