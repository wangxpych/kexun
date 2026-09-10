// Read-only public-network smoke checks; not part of deterministic unit tests.
// Never pass a private user URL or account session to this executable.
import Foundation

@main
struct WebArticleLiveChecks {
    static func main() async {
        let samples: [(String, Bool)] = [
            ("https://www.swift.org/blog/announcing-swift-6", true),
            ("https://www.ruanyifeng.com/blog/2025/02/weekly-issue-337.html", true),
            ("https://example.com/", false),
            ("https://www.swift.org/kexun-missing-article-verification", false)
        ]
        var failures = 0
        for (raw, expectedArticle) in samples {
            let start = Date()
            do {
                let result = try await WebArticle.fetch(URL(string: raw)!)
                let enough = result.text.count >= 80
                print("\(expectedArticle && enough ? "PASS" : "FAIL") article source=\(raw) final=\(result.finalURL.absoluteString) chars=\(result.text.count) title=\(result.title ?? "none") elapsed=\(Date().timeIntervalSince(start))")
                if !expectedArticle || !enough { failures += 1 }
            } catch {
                print("\(expectedArticle ? "FAIL" : "PASS") rejected source=\(raw) error=\(error.localizedDescription) elapsed=\(Date().timeIntervalSince(start))")
                if expectedArticle { failures += 1 }
            }
        }
        if failures > 0 { exit(1) }
    }
}
