import Foundation
import CoreFoundation
import Testing
@testable import Kexun

struct WebArticleTests {
    private static let source = URL(string: "https://example.com/posts/final")!
    private static let paragraph = "这是一篇公开文章，介绍如何保存资料并在需要时找回。正文包括具体的方法、细节与注意事项，读者可以离线阅读这些已经保存的文字。"

    private static func response(_ html: String, mime: String? = "text/html", encoding: String? = "utf-8") -> PublicLinkResponse {
        PublicLinkResponse(data: Data(html.utf8), contentType: mime, textEncodingName: encoding, finalURL: source)
    }

    @Test func publicArticlePreservesParagraphsAndFinalSourceWithoutActiveContent() throws {
        let date = Date(timeIntervalSince1970: 1234)
        let html = """
        <html><head><title>正文 &amp; 标题</title><script>document.write('<p>FAKE SCRIPT CONTENT</p>')</script></head>
        <body><nav><p>MENU MENU MENU</p></nav><main><article>
        <h1>可离线阅读</h1><p>\(Self.paragraph)</p><p>第二段 &amp; &#x4E2D; &#25991; <strong>关键</strong> 内容。</p><p>保存时间和来源可在之后核对。</p>
        <script src="https://example.com/tracker.js">EVIL SCRIPT</script><style>.foo { display:block }</style>
        <div hidden>SECRET HIDDEN CONTENT</div><div aria-hidden="true">HIDDEN ACCESSIBILITY</div>
        <div style="display: none">HIDDEN STYLE</div><aside>RECOMMENDATIONS</aside></article></main>
        <footer>FOOTER</footer></body></html>
        """
        let result = try WebArticle.parse(Self.response(html), capturedAt: date)
        #expect(result.title == "正文 & 标题")
        #expect(result.text.contains(Self.paragraph + "\n\n第二段 & 中 文 关键 内容。"))
        #expect(!result.text.contains("MENU"))
        #expect(!result.text.contains("SCRIPT"))
        #expect(!result.text.contains("HIDDEN"))
        #expect(!result.text.contains("FOOTER"))
        #expect(result.finalURL == Self.source)
        #expect(result.capturedAt == date)
    }

    @Test func fallbackUsesParagraphRichContainerAndOmitsSidebar() throws {
        let html = "<body><div class='menu'><p>导航链接</p></div><div><h1>普通静态网页</h1>" +
            String(repeating: "<p>\(Self.paragraph)</p>", count: 4) + "<div class='sidebar'>SIDEBAR</div></div></body>"
        let result = try WebArticle.parse(Self.response(html))
        #expect(result.text.contains("普通静态网页"))
        #expect(!result.text.contains("SIDEBAR"))
        #expect(!result.text.contains("导航链接"))
    }

    @Test func unquotedAttributesAndGreaterThanInQuotedAttributeAreInert() throws {
        let html = "<div class=article-content data-example='x > y'><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p></div>"
        #expect(try WebArticle.parse(Self.response(html)).text.contains(Self.paragraph))
    }

    @Test func GB18030DeclaredInHeaderAndMetaDecodesChinese() throws {
        let html = "<html><head><meta charset='gb18030'><title>中文文章</title></head><article><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p></article></html>"
        let value = CFStringConvertIANACharSetNameToEncoding("gb18030" as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(value))
        let data = try #require(html.data(using: encoding))
        for declared in ["gb18030", nil] as [String?] {
            let response = PublicLinkResponse(data: data, contentType: "text/html", textEncodingName: declared, finalURL: Self.source)
            let article = try WebArticle.parse(response)
            #expect(article.title == "中文文章")
            #expect(article.text.contains(Self.paragraph))
        }
    }

    @Test func BOMOverridesConflictingHeaderAndUnknownOrInvalidEncodingsFail() throws {
        let html = "<article><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p></article>"
        let response = PublicLinkResponse(data: Data([0xEF, 0xBB, 0xBF]) + Data(html.utf8), contentType: "text/html", textEncodingName: "bad-encoding", finalURL: Self.source)
        #expect(try WebArticle.parse(response).text.contains(Self.paragraph))
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(html, encoding: "not-a-real-encoding")) }
        let invalid = PublicLinkResponse(data: Data([0xFF, 0x80, 0xFF]), contentType: "text/html", textEncodingName: nil, finalURL: Self.source)
        #expect(throws: (any Error).self) { try WebArticle.parse(invalid) }
    }

    @Test func loginSubscriptionAndDynamicShellFailWithoutSavingTeasers() throws {
        let samples = [
            "<body><h1>登录</h1><form><input type=password></form><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p></body>",
            "<article><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p><div class=paywall>订阅后继续</div></article>",
            "<article><p>请登录后阅读\(Self.paragraph)</p><p>\(Self.paragraph)</p></article>",
            "<html><body><div id=app></div><script>document.write('<article><p>\(Self.paragraph)</p></article>')</script></body></html>",
            "<html><body><noscript>Enable JavaScript</noscript></body></html>"
        ]
        for html in samples { #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(html)) } }
    }

    @Test func linkMenusAndMultipleArticleFeedsAreNotArticles() throws {
        let menu = "<body><div>" + String(repeating: "<p><a href='/next'>\(Self.paragraph)</a></p>", count: 8) + "</div></body>"
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(menu)) }
        let feed = "<main>" + String(repeating: "<article><p>\(Self.paragraph)</p><p>\(Self.paragraph)</p></article>", count: 3) + "</main>"
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(feed)) }
    }

    @Test func nonHTMLAndMissingContentTypeFailHonestly() throws {
        for mime in ["application/pdf", "application/json", "text/plain", nil] as [String?] {
            #expect(throws: (any Error).self) { try WebArticle.parse(Self.response("<article><p>\(Self.paragraph)</p></article>", mime: mime)) }
        }
    }

    @Test func oversizedDeepAndMalformedDocumentsFailWithoutPartialText() throws {
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(String(repeating: "a", count: WebArticle.maximumBytes + 1))) }
        let deep = String(repeating: "<div>", count: 65) + "<p>\(Self.paragraph)</p>" + String(repeating: "</div>", count: 65)
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(deep)) }
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response("<article data-x='unterminated>\(Self.paragraph)")) }
        let longText = "<article><p>" + String(repeating: "x", count: WebArticle.maximumTextLength + 1) + "</p></article>"
        #expect(throws: (any Error).self) { try WebArticle.parse(Self.response(longText)) }
    }

    @Test func HTTPResponseRetainsRedirectDestinationMIMEAndEncoding() throws {
        // The post-redirect HTTP response is injected here. This does not claim
        // to exercise a live redirect or a URLProtocol redirect callback.
        let url = URL(string: "https://example.com/new-location/article")!
        let http = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html; charset=gb18030"]))
        let response = try PublicLinkResponse(data: Data(), response: http, maximumBytes: 100)
        #expect(response.finalURL == url)
        #expect(response.contentType == "text/html")
        #expect(response.textEncodingName == "gb18030")
    }

    @Test func unavailableHTTPAndDeclaredOrActualSizeOverflowFail() throws {
        for status in [301, 401, 403, 404, 500] {
            let response = try #require(HTTPURLResponse(url: Self.source, statusCode: status, httpVersion: nil, headerFields: nil))
            #expect(throws: (any Error).self) { try PublicLinkResponse(data: Data(), response: response, maximumBytes: 100) }
        }
        let declared = try #require(HTTPURLResponse(url: Self.source, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "101"]))
        #expect(throws: (any Error).self) { try PublicLinkResponse(data: Data(), response: declared, maximumBytes: 100) }
        let unknown = try #require(HTTPURLResponse(url: Self.source, statusCode: 200, httpVersion: nil, headerFields: nil))
        #expect(throws: (any Error).self) { try PublicLinkResponse(data: Data(repeating: 0, count: 101), response: unknown, maximumBytes: 100) }
    }

    @Test func privateAndCredentialedSourcesAreRejected() {
        for raw in ["http://127.0.0.1/page", "http://192.168.1.1/page", "http://localhost/page", "https://user:password@example.com/", "file:///tmp/article.html"] {
            #expect(throws: (any Error).self) { try PublicLinkRequest.validate(URL(string: raw)!) }
        }
    }

    @Test func streamingTransportKeepsDataContractAndChecksUnknownLength() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArticleFixtureProtocol.self]
        // A public numeric address makes the validator deterministic. URLProtocol
        // serves all bytes locally; this test makes no HTTP connection.
        let url = URL(string: "https://93.184.216.34/bytes")!
        let response = try await PublicLinkRequest.fetchResponse(url, maximumBytes: 32, configuration: configuration)
        #expect(response.data == Data("fixture bytes".utf8))
        #expect(response.finalURL == url)
        #expect(try await PublicLinkRequest.fetch(url, maximumBytes: 32, configuration: configuration) == response.data)
        await #expect(throws: (any Error).self) { try await PublicLinkRequest.fetch(url, maximumBytes: 3, configuration: configuration) }
        await #expect(throws: (any Error).self) { try await PublicLinkRequest.fetch(URL(string: "https://93.184.216.34/unavailable")!, maximumBytes: 32, configuration: configuration) }
    }
}

nonisolated private final class ArticleFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "93.184.216.34" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: url.path == "/unavailable" ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain; charset=utf-8"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fixture bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
