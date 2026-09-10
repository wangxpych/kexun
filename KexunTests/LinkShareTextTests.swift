import Foundation
import Testing
@testable import Kexun

struct LinkShareTextTests {
    @Test func realXiaohongshuShareKeepsTheCompleteVisibleTitle() {
        let text = "手机电脑传文件，不一定要微信 手机里的视频想放到电... https://xhslink.cn/o/560xb7O8hFJ 打开【小红书】，这篇笔记超精彩！"

        #expect(LinkShareText.suggestedTitle(in: text) == "手机电脑传文件，不一定要微信 手机里的视频想放到电...")
        #expect(text.hasSuffix("打开【小红书】，这篇笔记超精彩！"))
    }

    @Test func pureURLHasNoInventedTitle() {
        #expect(LinkShareText.suggestedTitle(in: "  https://example.com/article  ") == nil)
    }

    @Test func helperDoesNotMutateTheOriginalBodyOrTrimNormalPrefixText() {
        let original = "打开思路 与 正常正文 https://unknown.example/path 这是原文的后续正文"
        let body = original

        #expect(LinkShareText.suggestedTitle(in: body) == "打开思路 与 正常正文 这是原文的后续正文")
        #expect(body == original)
    }

    @Test func whitelistedSourceStillPreservesNonPromotionTextAfterTheURL() {
        let text = "笔记标题 https://xhslink.cn/o/abc123 这是用户自己写的补充"

        #expect(LinkShareText.suggestedTitle(in: text) == "笔记标题 这是用户自己写的补充")
    }

    @Test func multipleLinksRequireAnExplicitCurrentSelection() throws {
        let first = try #require(URL(string: "https://first.example/a"))
        let text = "完整标题 https://first.example/a https://second.example/b"

        #expect(LinkShareText.suggestedTitle(in: text) == nil)
        #expect(LinkShareText.suggestedTitle(in: text, selectedURL: first) == "完整标题")
        #expect(LinkShareText.suggestedTitle(in: text, selectedURL: URL(string: "https://stale.example/c")) == nil)
    }

    @Test func URLQueryAndFragmentRemainUntouched() throws {
        let raw = "https://example.com/read?item=42&from=share#comments"
        let text = "查询与片段标题 \(raw)"
        let parsed = try #require(LinkParser.urls(in: text).first)

        #expect(parsed.absoluteString == raw)
        #expect(LinkShareText.suggestedTitle(in: text, selectedURL: parsed) == "查询与片段标题")
    }

    @Test func sourceDisplayNameRequiresARealWhitelistedDomainBoundary() {
        for source in ["xhslink.cn", "www.xhslink.com", "XIAOHONGSHU.COM", "creator.xiaohongshu.com"] {
            #expect(LinkSource.displayName(for: source) == "小红书")
        }
        for source in ["evilxiaohongshu.com", "xiaohongshu.com.evil.example", "not-xhslink.cn"] {
            #expect(LinkSource.displayName(for: source) == source)
        }
    }
}
