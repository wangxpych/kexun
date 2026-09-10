import Foundation
import Vision
import PDFKit

nonisolated enum TextExtraction {
    static func extract(url: URL, kind: ContentKind, contentType: String) throws -> String? {
        if kind == .image {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: url).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? ""
        }
        if contentType == "com.adobe.pdf" {
            guard let document = PDFDocument(url: url), !document.isLocked else {
                throw CollectionError.invalid(String(localized: "PDF 无法读取或需要密码，原文件已保留。"))
            }
            guard document.pageCount <= 1000 else { throw CollectionError.invalid(String(localized: "PDF 超过 1000 页，暂不提取文本；原文件已保留。")) }
            return document.string ?? ""
        }
        return nil
    }
}
