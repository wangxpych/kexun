import Foundation

@main
struct MetadataChecks {
    static func main() throws {
        let base = URL(string: "https://example.com/article")!
        let parsed = LinkMetadata.parse("<title>fallback</title><meta content='中文 &amp; English' property='og:title'><meta property='og:image' content='/cover.png'>", baseURL: base)
        precondition(parsed.title == "中文 & English")
        precondition(parsed.imageURL?.absoluteString == "https://example.com/cover.png")
        precondition(LinkMetadata.parse("<TITLE> Plain title </TITLE>", baseURL: base).title == "Plain title")
        precondition(LinkMetadata.parse("<html>empty</html>", baseURL: base).title == nil)
        for raw in ["http://127.0.0.1/", "http://10.0.0.1/", "http://192.168.1.1/", "http://localhost/", "file:///tmp/x", "https://user:password@example.com/"] {
            do { try PublicLinkRequest.validate(URL(string: raw)!); fatalError("unsafe URL accepted") }
            catch { }
        }
        print("PASS: metadata attribute order, Chinese/entity parsing, relative image, fallback, private/file/credential URL rejection")
    }
}
