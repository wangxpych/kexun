import Foundation
import CoreFoundation

/// A readable text copy, never a full-page archive. No scripts, styles, images,
/// linked resources, cookies or account sessions are loaded by the extractor.
nonisolated struct WebArticle: Sendable {
    let title: String?
    let text: String
    let finalURL: URL
    let capturedAt: Date

    static let maximumBytes = 2 * 1024 * 1024
    static let maximumTextLength = 200_000

    static func fetch(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> WebArticle {
        let response = try await PublicLinkRequest.fetchResponse(url, maximumBytes: maximumBytes, configuration: configuration)
        let worker = Task.detached(priority: .utility) { try parse(response) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func parse(_ response: PublicLinkResponse, capturedAt: Date = Date()) throws -> WebArticle {
        let html = try WebHTML.decode(response)
        let metadata = LinkMetadata.parse(html, baseURL: response.finalURL)
        let tree = try ArticleHTMLTree(html)
        let text = try tree.articleText()
        return WebArticle(title: metadata.title, text: text, finalURL: response.finalURL, capturedAt: capturedAt)
    }
}

nonisolated enum WebHTML {
    static func decode(_ response: PublicLinkResponse) throws -> String {
        guard response.data.count <= WebArticle.maximumBytes else { throw failure(String(localized: "网页超过 2 MB，暂不保存正文；原链接已保留。")) }
        let mime = response.contentType?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard mime == "text/html" || mime == "application/xhtml+xml" else {
            throw failure(String(localized: "此地址未返回 HTML 网页，原链接已保留；文件请通过文件入口导入。"))
        }
        let bytes = response.data
        let encoding: String.Encoding
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8 }
        else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16 }
        else if let name = response.textEncodingName ?? declaredEncoding(bytes) {
            let value = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            guard value != kCFStringEncodingInvalidId else { throw failure(String(localized: "网页声明的编码暂不支持，原链接已保留。")) }
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        } else { encoding = .utf8 }
        guard let html = String(data: bytes, encoding: encoding), !html.contains("\u{0000}"), !html.contains("\u{FFFD}") else {
            throw failure(String(localized: "无法可靠解码网页正文，原链接已保留。"))
        }
        return html
    }

    private static func declaredEncoding(_ data: Data) -> String? {
        // Only inspect the initial ASCII-compatible head. This regex identifies a
        // charset declaration; article extraction itself uses a bounded tree.
        let prefix = String(decoding: data.prefix(8192), as: UTF8.self)
        let pattern = "(?is)<meta\\b[^>]{0,2048}?charset\\s*=\\s*[\"']?\\s*([A-Za-z0-9._-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let range = Range(match.range(at: 1), in: prefix) else { return nil }
        return String(prefix[range])
    }

    static func failure(_ message: String) -> CollectionError { .invalid(message) }
}

/// A small inert HTML tokenizer/tree for conservative readable-text extraction.
/// It does not implement browser layout or execute/instantiate HTML. Invalid or
/// ambiguous documents fail rather than returning navigation as an article.
nonisolated private struct ArticleHTMLTree {
    private enum Part { case text(String), child(Int) }
    private struct Node {
        var tag: String
        var parts: [Part] = []
        var skipped: Bool
        var priority: Int
        var textCount = 0
        var linkedCount = 0
        var proseBlocks = 0
    }
    private static let rawTags: Set<String> = ["script", "style", "noscript", "template", "iframe", "svg", "math"]
    private static let ignoredTags: Set<String> = ["head", "nav", "header", "footer", "aside", "form", "button", "select", "textarea", "canvas", "object", "embed"]
    private static let voidTags: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let blocks: Set<String> = ["p", "div", "section", "article", "main", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "blockquote", "pre", "tr", "table", "figure", "figcaption", "br", "hr"]
    private var nodes = [Node(tag: "root", skipped: false, priority: 0)]
    private var hasAccessGate = false

    init(_ html: String) throws {
        let bytes = Array(html.utf8)
        let lower = bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }
        var stack = [0]
        var cursor = 0
        while cursor < bytes.count {
            if cursor % 4096 == 0 { try Task.checkCancellation() }
            if bytes[cursor] != 60 {
                let start = cursor
                while cursor < bytes.count && bytes[cursor] != 60 { cursor += 1 }
                if !nodes[stack.last!].skipped {
                    let text = Self.entities(String(decoding: bytes[start..<cursor], as: UTF8.self))
                    nodes[stack.last!].parts.append(.text(text))
                }
                continue
            }
            if Self.starts(lower, at: cursor, with: Array("<!--".utf8)) {
                cursor = Self.end(of: Array("-->".utf8), in: lower, from: cursor + 4) ?? bytes.count
                continue
            }
            var end = cursor + 1
            var quote: UInt8?
            while end < bytes.count {
                let byte = bytes[end]
                if let current = quote { if byte == current { quote = nil } }
                else if byte == 34 || byte == 39 { quote = byte }
                else if byte == 62 { break }
                end += 1
            }
            guard end < bytes.count, end - cursor <= 16_384 else { throw Self.unreadable() }
            let token = Array(bytes[(cursor + 1)..<end])
            cursor = end + 1
            if token.first == 33 || token.first == 63 { continue }
            let closing = token.first == 47
            let parsed = Self.tag(token, closing: closing)
            let name = parsed.name
            if name.isEmpty { throw Self.unreadable() }
            if closing {
                if let index = stack.lastIndex(where: { nodes[$0].tag == name }), index > 0 { stack.removeSubrange(index...) }
                continue
            }
            if Self.rawTags.contains(name) {
                // Raw text can contain fake tags and quoted HTML. Never tokenize
                // it as page content; require a matching closing-tag delimiter.
                let needle = Array("</\(name)".utf8)
                var search = cursor
                var closingEnd: Int?
                while let foundEnd = Self.end(of: needle, in: lower, from: search) {
                    if foundEnd < lower.count && (Self.space(lower[foundEnd]) || lower[foundEnd] == 62) {
                        closingEnd = Self.end(of: [62], in: lower, from: foundEnd)
                        break
                    }
                    search = foundEnd
                }
                cursor = closingEnd ?? bytes.count
                continue
            }
            let attrs = parsed.attributes
            let markers = ((attrs["id"] ?? "") + " " + (attrs["class"] ?? "")).lowercased()
            let tokens = Set(markers.split(whereSeparator: { $0.isWhitespace }).map(String.init))
            if (name == "input" && attrs["type"]?.lowercased() == "password") ||
                !tokens.isDisjoint(with: ["paywall", "paywall-content", "subscription-wall", "login-wall", "content-locked"]) {
                hasAccessGate = true
            }
            let hiddenStyle = (attrs["style"] ?? "").lowercased().filter { !$0.isWhitespace }
            let hidden = attrs["hidden"] != nil || attrs["aria-hidden"]?.lowercased() == "true" ||
                hiddenStyle.contains("display:none") || hiddenStyle.contains("visibility:hidden")
            let clutter = !tokens.isDisjoint(with: ["nav", "navigation", "menu", "sidebar", "footer", "header", "comments", "comment-list", "related", "related-posts", "advertisement", "ads", "social-share", "cookie-banner"])
            let skipped = nodes[stack.last!].skipped || hidden || clutter || Self.ignoredTags.contains(name)
            let semantic = !tokens.isDisjoint(with: ["article-body", "article-content", "post-content", "entry-content", "story-body", "rich_media_content", "js_content"])
            let priority = name == "article" || semantic ? 3 : (name == "main" || attrs["role"] == "main" ? 2 : 0)
            // Common omitted closing tags are safe to recover, without turning
            // an arbitrarily malformed document into an assumed full article.
            if name == "p", nodes[stack.last!].tag == "p" { stack.removeLast() }
            if name == "li", nodes[stack.last!].tag == "li" { stack.removeLast() }
            guard nodes.count < 30_000, stack.count < 64 else { throw Self.unreadable() }
            let index = nodes.count
            nodes.append(Node(tag: name, skipped: skipped, priority: priority))
            nodes[stack.last!].parts.append(.child(index))
            if !Self.voidTags.contains(name) && token.last != 47 { stack.append(index) }
        }
        // Bottom-up statistics avoid copying an entire article into each ancestor.
        for index in nodes.indices.reversed() {
            if nodes[index].skipped { continue }
            for part in nodes[index].parts {
                switch part {
                case .text(let text): nodes[index].textCount += text.filter { !$0.isWhitespace }.count
                case .child(let child):
                    nodes[index].textCount += nodes[child].textCount
                    nodes[index].linkedCount += nodes[child].linkedCount
                    nodes[index].proseBlocks += nodes[child].proseBlocks
                }
            }
            if nodes[index].tag == "a" { nodes[index].linkedCount = nodes[index].textCount }
            if ["p", "pre", "blockquote"].contains(nodes[index].tag), nodes[index].textCount >= 25 { nodes[index].proseBlocks += 1 }
        }
    }

    func articleText() throws -> String {
        guard !hasAccessGate else {
            throw WebHTML.failure(String(localized: "此页包含登录或订阅限制，暂不保存正文；原链接已保留。"))
        }
        let candidates = nodes.indices.filter { index in
            let node = nodes[index]
            guard !node.skipped, node.textCount > 0, Double(node.linkedCount) / Double(node.textCount) < 0.25 else { return false }
            if node.priority > 0 { return node.textCount >= 80 && node.proseBlocks >= 1 }
            return ["div", "section", "body"].contains(node.tag) && node.textCount >= 160 && node.proseBlocks >= 2
        }
        // Multiple independent article previews are a feed, not one full article.
        if candidates.filter({ nodes[$0].tag == "article" }).count > 1 { throw Self.unreadable() }
        guard let selected = candidates.max(by: { left, right in
            let lhs = nodes[left], rhs = nodes[right]
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return lhs.textCount + lhs.proseBlocks * 40 < rhs.textCount + rhs.proseBlocks * 40
        }) else { throw Self.unreadable() }
        var output = ""
        try render(selected, into: &output)
        let text = output.components(separatedBy: "\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard text.count <= WebArticle.maximumTextLength else {
            throw WebHTML.failure(String(localized: "网页正文过长，暂不保存；原链接已保留。"))
        }
        let beginning = text.prefix(200).lowercased()
        if ["请登录后阅读", "登录后查看全文", "订阅后阅读全文", "subscribe to continue", "sign in to continue", "enable javascript"].contains(where: beginning.contains) {
            throw Self.unreadable()
        }
        return text
    }

    private func render(_ index: Int, into output: inout String) throws {
        try Task.checkCancellation()
        let node = nodes[index]
        guard !node.skipped else { return }
        let block = Self.blocks.contains(node.tag)
        if block { output += "\n" }
        for part in node.parts {
            switch part {
            case .text(let text):
                output += (text.first?.isWhitespace == true ? " " : "") +
                    text.split(whereSeparator: \.isWhitespace).joined(separator: " ") +
                    (text.last?.isWhitespace == true ? " " : "")
            case .child(let child): try render(child, into: &output)
            }
            guard output.utf8.count <= WebArticle.maximumBytes else { throw Self.unreadable() }
        }
        if block { output += "\n" }
    }

    private static func unreadable() -> CollectionError {
        WebHTML.failure(String(localized: "未找到可可靠保存的公开正文；此页可能需要登录、动态加载，或暂不支持。原链接已保留。"))
    }

    private static func space(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
    private static func starts(_ bytes: [UInt8], at start: Int, with needle: [UInt8]) -> Bool {
        start + needle.count <= bytes.count && bytes[start..<(start + needle.count)].elementsEqual(needle)
    }
    private static func end(of needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start <= bytes.count - needle.count else { return nil }
        for index in start...(bytes.count - needle.count) where starts(bytes, at: index, with: needle) { return index + needle.count }
        return nil
    }

    private static func tag(_ token: [UInt8], closing: Bool) -> (name: String, attributes: [String: String]) {
        var index = closing ? 1 : 0
        let start = index
        while index < token.count && !space(token[index]) && token[index] != 47 { index += 1 }
        let name = String(decoding: token[start..<index], as: UTF8.self).lowercased()
        var attributes: [String: String] = [:]
        while index < token.count {
            while index < token.count && (space(token[index]) || token[index] == 47) { index += 1 }
            let keyStart = index
            while index < token.count && !space(token[index]) && token[index] != 61 && token[index] != 47 { index += 1 }
            guard index > keyStart else { break }
            let key = String(decoding: token[keyStart..<index], as: UTF8.self).lowercased()
            while index < token.count && space(token[index]) { index += 1 }
            var value = ""
            if index < token.count && token[index] == 61 {
                index += 1
                while index < token.count && space(token[index]) { index += 1 }
                let quote: UInt8? = index < token.count && (token[index] == 34 || token[index] == 39) ? token[index] : nil
                if quote != nil { index += 1 }
                let valueStart = index
                while index < token.count && (quote.map { token[index] != $0 } ?? !space(token[index])) { index += 1 }
                value = entities(String(decoding: token[valueStart..<index], as: UTF8.self))
                if quote != nil && index < token.count { index += 1 }
            }
            if attributes[key] == nil { attributes[key] = value }
        }
        return (name, attributes)
    }

    private static func entities(_ value: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©"]
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            if value[cursor] == "&" {
                let bound = value.index(cursor, offsetBy: 16, limitedBy: value.endIndex) ?? value.endIndex
                if let semi = value[cursor..<bound].firstIndex(of: ";") {
                    let token = String(value[value.index(after: cursor)..<semi])
                    var replacement = named[token]
                    if token.hasPrefix("#") {
                        let hex = token.lowercased().hasPrefix("#x")
                        if let number = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10),
                           number >= 32, let scalar = UnicodeScalar(number) { replacement = String(scalar) }
                    }
                    if let replacement { output += replacement; cursor = value.index(after: semi); continue }
                }
            }
            output.append(value[cursor]); cursor = value.index(after: cursor)
        }
        return output
    }
}
