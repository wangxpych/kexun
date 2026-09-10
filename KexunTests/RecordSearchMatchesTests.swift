import Testing
import Foundation
import UIKit
import PDFKit
@testable import Kexun

struct RecordSearchMatchesTests {
    @Test func savedArticleBodyHasItsOwnLocatableMatches() throws {
        var record = CollectionRecord(kind: .link, title: "A link")
        record.article = SavedWebArticle(text: "本地网页正文 NEEDLE 内容", sourceURL: "https://example.com", capturedAt: Date())
        let result = try RecordSearchMatches.scan(record: record, query: "needle")
        #expect(result.hits.count == 1)
        let hit = try #require(result.hits.first)
        #expect(hit.field == String(localized: "网页正文"))
        #expect((hit.excerpt as NSString).substring(with: hit.highlight) == "NEEDLE")
        #expect(CollectionQuery(text: "needle").matches(record))
    }

    @Test func cjkEmojiAndCaseInsensitiveMatchesPreserveOriginalText() throws {
        let record = CollectionRecord(kind: .text, title: "资料", body: "👨‍👩‍👧‍👦 去京都 Café SWIFT，京都散步")
        let result = try RecordSearchMatches.scan(record: record, query: "京都 swift café")
        #expect(result.hits.count == 4)
        let highlighted = result.hits.map { ($0.excerpt as NSString).substring(with: $0.highlight) }
        #expect(highlighted == ["京都", "Café", "SWIFT", "京都"])
        #expect(result.hits.first?.excerpt.contains("👨‍👩‍👧‍👦") == true)
        #expect(!result.limited)
    }

    @Test func repeatedTermsAndOverlappingRangesAreOneHit() throws {
        let record = CollectionRecord(kind: .text, title: "", body: "京都散步，京都")
        let result = try RecordSearchMatches.scan(record: record, query: "京都 京都散步 京都")
        #expect(result.hits.count == 2)
        #expect((result.hits[0].excerpt as NSString).substring(with: result.hits[0].highlight) == "京都散步")
    }

    @Test func emptyAndMissingQueryHaveNoHits() throws {
        let record = CollectionRecord(kind: .text, title: "Hello", body: "京都")
        #expect(try RecordSearchMatches.scan(record: record, query: " \n\t ").hits.isEmpty)
        #expect(try RecordSearchMatches.scan(record: record, query: "不存在").hits.isEmpty)
    }

    @Test func searchesEveryPersistedField() throws {
        var record = CollectionRecord(kind: .file, title: "needle", body: "needle", originalURL: "https://example.com/needle", source: "needle", note: "needle")
        record.extractedText = "needle"
        record.attachments = [AttachmentReference(id: UUID(), relativePath: "unused", originalName: "needle.pdf", contentType: "com.adobe.pdf", byteCount: 0, sha256: "")]
        #expect(try RecordSearchMatches.scan(record: record, query: "NEEDLE").hits.count == 7)
    }

    @Test func largeTextAndExcessHitsAreExplicitlyBounded() throws {
        let large = CollectionRecord(kind: .text, title: "", body: String(repeating: "x", count: RecordSearchMatches.maximumTextLength + 1) + "needle")
        let omitted = try RecordSearchMatches.scan(record: large, query: "needle")
        #expect(omitted.hits.isEmpty)
        #expect(omitted.limited)
        let dense = CollectionRecord(kind: .text, title: "", body: String(repeating: "needle ", count: 600))
        let capped = try RecordSearchMatches.scan(record: dense, query: "needle")
        #expect(capped.hits.count == RecordSearchMatches.maximumHits)
        #expect(capped.limited)
        #expect(capped.hits.allSatisfy { $0.excerpt.count < 400 })
        #expect(RecordSearchMatches.terms(String(repeating: "x", count: 300)).limited)
    }

    @Test @MainActor func textPDFPageMatchesAndOriginalBytesStayIntact() throws {
        let format = UIGraphicsPDFRendererFormat()
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400), format: format)
        let data = renderer.pdfData { context in
            for value in ["First page", "Needle on second page", "Third NEEDLE page"] {
                context.beginPage()
                (value as NSString).draw(at: CGPoint(x: 30, y: 50), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
        let result = try RecordSearchMatches.scanPDF(data: data, query: "needle")
        #expect(result.result.hits.map(\.pageIndex) == [1, 2])
        #expect(result.data == data)
        let document = try #require(PDFDocument(data: data))
        for hit in result.result.hits {
            let pageIndex = try #require(hit.pageIndex)
            let page = try #require(document.page(at: pageIndex))
            let selection = try #require(page.selection(for: hit.sourceRange))
            #expect(selection.string?.lowercased() == "needle")
        }
    }

    @Test func invalidPDFAndUnsafeAttachmentPathFailHonestly() throws {
        #expect(throws: (any Error).self) { try RecordSearchMatches.scanPDF(data: Data("not a PDF".utf8), query: "needle") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KexunMatchSecurity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try AttachmentStore(root: root)
        let reference = AttachmentReference(id: UUID(), relativePath: "../../secret.pdf", originalName: "secret.pdf", contentType: "com.adobe.pdf", byteCount: 10, sha256: "")
        #expect(throws: (any Error).self) { try RecordSearchMatches.loadPDF(reference: reference, attachments: storage, query: "needle") }
    }
}
