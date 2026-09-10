#if DEBUG
import SwiftUI
import Foundation

/// A persistent, isolated library for organization, offline-article, and export UI acceptance.
/// Only `--organization-feature-reset` removes its dedicated temporary root.
struct FeatureWorkflowFixtureView: View {
    @State private var store: CollectionStore?
    @State private var failure: String?

    var body: some View {
        Group {
            if let store { LibraryView(store: store) }
            else if let failure { Text(failure) }
            else { ProgressView("Organization feature fixture preparing") }
        }
        .task {
            guard store == nil, failure == nil else { return }
            do {
                let root = try Self.prepareRoot()
                let articleFixture = OrganizationArticleFixture()
                store = CollectionStore(openRoot: { root }, fetchArticle: { url in
                    try await articleFixture.fetch(url)
                })
            } catch { failure = error.localizedDescription }
        }
    }

    private static func prepareRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KexunOrganizationFeatureFixture", isDirectory: true)
        if ProcessInfo.processInfo.arguments.contains("--organization-feature-reset"),
           FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"))
        guard try repository.all().isEmpty else { return root }

        var first = CollectionRecord(kind: .text, title: "组织验收文字甲", body: "收藏夹筛选与重命名验收内容甲")
        first.id = UUID(uuidString: "00000000-0000-4000-8000-000000000126")!
        first.source = "组织功能验收"

        var second = CollectionRecord(kind: .text, title: "组织验收文字乙", body: "移除收藏夹后仍应保留的内容乙")
        second.id = UUID(uuidString: "00000000-0000-4000-8000-000000000127")!
        second.source = "组织功能验收"

        var link = CollectionRecord(kind: .link, title: "离线正文验收链接", body: "https://example.com/feature-workflow")
        link.id = UUID(uuidString: "00000000-0000-4000-8000-000000000128")!
        link.originalURL = "https://example.com/feature-workflow"
        link.source = "example.com"
        link.processingState = .complete

        try repository.insert([first, second, link], isPro: false)
        return root
    }
}

private actor OrganizationArticleFixture {
    private var attempts = 0

    func fetch(_ url: URL) throws -> WebArticle {
        attempts += 1
        guard attempts == 1 else { throw URLError(.notConnectedToInternet) }
        let html = """
        <!doctype html><html><head><title>可寻离线正文验收</title></head><body>
        <article>
          <h1>可寻离线正文验收</h1>
          <p>ORGANIZATIONARTICLE126 是这次真实网页正文解析与全文检索的唯一验收词。保存之后，即使网络不可用，用户仍应能够从本机打开已经保存的纯文本正文。</p>
          <p>第二次更新会收到受控的离线错误。此前成功保存的正文、来源地址和阅读入口都必须继续保留，不能因为刷新失败而被清空。</p>
        </article>
        </body></html>
        """
        return try WebArticle.parse(PublicLinkResponse(
            data: Data(html.utf8),
            contentType: "text/html",
            textEncodingName: "utf-8",
            finalURL: url
        ), capturedAt: Date(timeIntervalSince1970: 1_780_000_126))
    }
}
#endif
