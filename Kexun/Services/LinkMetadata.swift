import Foundation
import Darwin

nonisolated struct LinkMetadata: Sendable {
    var title: String?
    var imageURL: URL?

    static func parse(_ html: String, baseURL: URL) -> LinkMetadata {
        func decode(_ text: String) -> String {
            text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func capture(_ pattern: String, in text: String) -> String? {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return decode(String(text[range]))
        }
        let tags = (try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: [.caseInsensitive]))?.matches(in: html, range: NSRange(html.startIndex..., in: html)) ?? []
        var values: [String: String] = [:]
        for match in tags {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            if let key = capture("(?:property|name)\\s*=\\s*['\"]([^'\"]+)['\"]", in: tag),
               let value = capture("content\\s*=\\s*['\"]([^'\"]*)['\"]", in: tag) { values[key.lowercased()] = value }
        }
        let title = values["og:title"] ?? capture("<title[^>]*>(.*?)</title>", in: html)
        let image = values["og:image"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        return LinkMetadata(title: title.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }, imageURL: image)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> LinkMetadata {
        let response = try await PublicLinkRequest.fetchResponse(url, maximumBytes: 2 * 1024 * 1024, configuration: configuration)
        let worker = Task.detached(priority: .utility) {
            let html = try WebHTML.decode(response)
            return parse(html, baseURL: response.finalURL)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}

nonisolated struct PublicLinkResponse: Sendable {
    let data: Data
    let contentType: String?
    let textEncodingName: String?
    let finalURL: URL

    init(data: Data, contentType: String?, textEncodingName: String?, finalURL: URL) {
        self.data = data
        self.contentType = contentType
        self.textEncodingName = textEncodingName
        self.finalURL = finalURL
    }

    /// Shared by streaming requests and deterministic response fixtures.
    init(data: Data, response: HTTPURLResponse, maximumBytes: Int) throws {
        guard maximumBytes > 0, (200..<300).contains(response.statusCode),
              response.expectedContentLength <= maximumBytes, data.count <= maximumBytes,
              let url = response.url else {
            throw CollectionError.invalid(String(localized: "网页暂不可用或内容过大，原链接已保留。"))
        }
        self.init(data: data, contentType: response.mimeType,
                  textEncodingName: response.textEncodingName, finalURL: url)
    }
}

nonisolated enum PublicLinkRequest {
    static func validate(_ url: URL) throws {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.port == nil || url.port == 80 || url.port == 443,
              host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), host.contains(".") else {
            throw CollectionError.invalid(String(localized: "此地址不自动联网补全，原内容已保留。"))
        }
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &result) == 0, let first = result else { throw CollectionError.invalid(String(localized: "无法解析网址，请联网后重试。")) }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let address = cursor {
            defer { cursor = address.pointee.ai_next }
            if address.pointee.ai_family == AF_INET {
                let raw = address.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let a = raw >> 24, b = (raw >> 16) & 255
                guard a != 0, a != 10, a != 127, a < 224,
                      !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                      !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)) else {
                    throw CollectionError.invalid(String(localized: "不自动访问本地或私有网络地址。"))
                }
            } else if address.pointee.ai_family == AF_INET6 {
                let global = address.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { ($0[0] & 0xe0) == 0x20 }
                }
                guard global else { throw CollectionError.invalid(String(localized: "不自动访问本地或私有网络地址。")) }
            }
        }
    }

    static func fetch(_ url: URL, maximumBytes: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        try await fetchResponse(url, maximumBytes: maximumBytes, configuration: configuration).data
    }

    static func fetchResponse(_ url: URL, maximumBytes: Int, configuration: URLSessionConfiguration = .ephemeral) async throws -> PublicLinkResponse {
        guard maximumBytes > 0 else { throw CollectionError.invalid(String(localized: "网页大小上限无效。")) }
        try Task.checkCancellation()
        try await Task.detached { try validate(url) }.value
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = nil
        let delegate = PublicRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw CollectionError.invalid(String(localized: "网页暂不可用或内容过大，原链接已保留。"))
        }
        _ = try PublicLinkResponse(data: Data(), response: response, maximumBytes: maximumBytes)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw CollectionError.invalid(String(localized: "补全内容超过大小上限。")) }
            data.append(byte)
        }
        return try PublicLinkResponse(data: data, response: response, maximumBytes: maximumBytes)
    }
}

nonisolated private final class PublicRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var redirects = 0 // URLSession's serial delegate queue owns this value.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 8, let url = request.url else { completionHandler(nil); return }
        do { try PublicLinkRequest.validate(url); completionHandler(request) }
        catch { completionHandler(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use normal TLS verification, but never supply account credentials.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
