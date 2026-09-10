import Foundation
import AppKit
import CoreText
import PDFKit

@main
struct ExtractionChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kexun-extraction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 1200, height: 400))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 400).fill()
        NSString(string: "KEXUN SEARCH 2026").draw(at: NSPoint(x: 50, y: 240), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        NSString(string: "收藏资料 随时可寻").draw(at: NSPoint(x: 50, y: 110), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let imageURL = root.appendingPathComponent("ocr.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let recognized = try TextExtraction.extract(url: imageURL, kind: .image, contentType: "public.png") ?? ""
        precondition(recognized.contains("KEXUN") && recognized.contains("2026"), "OCR output: \(recognized)")
        precondition(recognized.contains("收藏") && recognized.contains("资料"), "Chinese OCR output: \(recognized)")
        print("PASS: actual Chinese + English image OCR: \(recognized.replacingOccurrences(of: "\n", with: " / "))")
        let pdfURL = root.appendingPathComponent("text.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 400)
        let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 40, y: 200)
        let attributed = NSAttributedString(string: "Kexun PDF searchable text", attributes: [.font: NSFont.systemFont(ofSize: 24)])
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        let extracted = try TextExtraction.extract(url: pdfURL, kind: .file, contentType: "com.adobe.pdf") ?? ""
        precondition(extracted.contains("searchable"), "PDF output: \(extracted)")
        print("PASS: real PDF text-layer extraction: \(extracted.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Embed only bitmap pixels: visible text without a searchable PDF text layer.
        let scanURL = root.appendingPathComponent("image-only.pdf")
        let scanContext = CGContext(scanURL as CFURL, mediaBox: &box, nil)!
        scanContext.beginPDFPage(nil)
        scanContext.draw(bitmap.cgImage!, in: CGRect(x: 0, y: 100, width: 600, height: 200))
        scanContext.endPDFPage()
        scanContext.closePDF()
        precondition(PDFDocument(url: scanURL)?.pageCount == 1)
        let scanText = try TextExtraction.extract(url: scanURL, kind: .file, contentType: "com.adobe.pdf")
        precondition(scanText?.trimmingCharacters(in: .whitespacesAndNewlines) == "", "Image-only PDF unexpectedly yielded text: \(scanText ?? "nil")")
        print("PASS: image-only PDF returns empty text; no unsupported scan OCR claimed")

        let encryptedURL = root.appendingPathComponent("password-required.pdf")
        let document = PDFDocument(url: pdfURL)!
        precondition(document.write(to: encryptedURL, withOptions: [.ownerPasswordOption: "test-owner", .userPasswordOption: "test-user"]))
        let locked = PDFDocument(url: encryptedURL)!
        precondition(locked.isEncrypted && locked.isLocked, "Fixture encryption was not applied")
        let encryptedBytes = try Data(contentsOf: encryptedURL)
        do {
            _ = try TextExtraction.extract(url: encryptedURL, kind: .file, contentType: "com.adobe.pdf")
            preconditionFailure("Locked PDF accepted")
        } catch {
            precondition(error is CollectionError, "Unexpected locked PDF error: \(error)")
            print("PASS: encrypted/locked PDF rejected: \(error.localizedDescription)")
        }
        let encryptedAfter = try Data(contentsOf: encryptedURL)
        precondition(encryptedAfter == encryptedBytes, "Extraction modified encrypted original")

        let damagedURL = root.appendingPathComponent("damaged.pdf")
        let damagedBytes = Data("%PDF-1.7\ntruncated invalid PDF without objects or xref\n".utf8)
        try damagedBytes.write(to: damagedURL)
        precondition(PDFDocument(url: damagedURL) == nil, "Corrupt fixture was unexpectedly parseable")
        do {
            _ = try TextExtraction.extract(url: damagedURL, kind: .file, contentType: "com.adobe.pdf")
            preconditionFailure("Damaged PDF accepted")
        } catch {
            precondition(error is CollectionError, "Unexpected damaged PDF error: \(error)")
            print("PASS: damaged PDF rejected: \(error.localizedDescription)")
        }
        let damagedAfter = try Data(contentsOf: damagedURL)
        precondition(damagedAfter == damagedBytes, "Extraction modified damaged original")
        let unsupported = try TextExtraction.extract(url: pdfURL, kind: .file, contentType: "public.data")
        precondition(unsupported == nil)
        print("PASS: unsupported content type returns nil. Fixtures: \(root.path)")
    }
}
