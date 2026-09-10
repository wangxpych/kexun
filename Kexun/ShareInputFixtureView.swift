#if DEBUG
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

/// Explicit UI-test input source, not a normal application screen or release feature.
struct ShareInputFixtureView: View {
    @State private var identifier = UUID().uuidString
    @State private var showingDualRepresentation = false
    @State private var fileSource: URL?
    @State private var sourceRemoved = false
    @State private var fileError: String?
    @State private var fileSHA = ""
    private var dualURL: URL { URL(string: "https://example.com/DualProvider-\(identifier)")! }
    private var dualText: String { "DualProvider-\(identifier)\n中文附带说明\n  保留空格  " }
    private var text: String {
        (1...21).map { "https://example.com/KexunMultiLink/\(identifier)/page-\($0)" }.joined(separator: "\n")
    }
    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--share-file") {
            VStack(spacing: 20) {
                Text("文件分享验收 · 仅 Debug")
                if let fileSource {
                    Text(fileSource.lastPathComponent).accessibilityIdentifier("fixture.fileName")
                    Text(fileSHA)
                        .accessibilityIdentifier("fixture.fileSHA")
                    ShareLink("分享测试文件", item: fileSource).disabled(sourceRemoved)
                    Button("移除测试来源文件") {
                        do {
                            try FileManager.default.removeItem(at: fileSource)
                            sourceRemoved = true
                        } catch { fileError = error.localizedDescription }
                    }.disabled(sourceRemoved)
                    if sourceRemoved { Text("测试来源文件已移除") }
                }
                if let fileError { Text(fileError) }
            }.padding().task {
                guard fileSource == nil else { return }
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("KexunFileShare-\(identifier)")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                    let suffix = ProcessInfo.processInfo.arguments.contains("--share-empty-pdf") || ProcessInfo.processInfo.arguments.contains("--share-corrupt-pdf") ? "pdf" : "bin"
                    let url = directory.appendingPathComponent("FileShare-\(identifier).\(suffix)")
                    let bytes = fileBytes
                    try bytes.write(to: url, options: .atomic)
                    fileSHA = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    fileSource = url
                } catch { fileError = error.localizedDescription }
            }
        } else {
        VStack(spacing: 24) {
            Text("分享扩展验收输入 · 仅 Debug")
            ShareLink("分享 21 个链接的文字", item: text)
            Text(dualURL.absoluteString).accessibilityIdentifier("fixture.dualURL")
            Button("分享 URL 与附带文字") { showingDualRepresentation = true }
        }.padding()
            .sheet(isPresented: $showingDualRepresentation) {
                DualRepresentationShareSheet(url: dualURL, text: dualText,
                                             failText: ProcessInfo.processInfo.arguments.contains("--share-text-failure"),
                                             includeSecondItem: ProcessInfo.processInfo.arguments.contains("--share-batch-partial"),
                                             includeSlowBatch: ProcessInfo.processInfo.arguments.contains("--share-batch-stop"))
            }
        }
    }
    private var fileBytes: Data {
        if ProcessInfo.processInfo.arguments.contains("--share-corrupt-pdf") {
            return Data("%PDF-1.7\ninvalid truncated fixture \(identifier)".utf8)
        }
        if ProcessInfo.processInfo.arguments.contains("--share-empty-pdf") {
            return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
                context.beginPage()
                UIColor.systemGreen.setFill()
                UIBezierPath(ovalIn: CGRect(x: 90, y: 140, width: 120, height: 120)).fill()
            }
        }
        return Data(String(repeating: "FILE-SHARE-\(identifier)\u{0}\n可寻独立附件\n", count: 32).utf8)
    }
}

private struct DualRepresentationShareSheet: UIViewControllerRepresentable {
    let url: URL
    let text: String
    let failText: Bool
    let includeSecondItem: Bool
    let includeSlowBatch: Bool

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        let bytes = Data(text.utf8)
        let failText = failText
        provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            if failText { completion(nil, CocoaError(.fileReadCorruptFile)) }
            else { completion(bytes, nil) }
            return nil
        }
        var providers = [provider]
        if includeSecondItem {
            let secondText = "第二项独立正文\n\(url.absoluteString)/second-1\n\(url.absoluteString)/second-2"
            providers.append(NSItemProvider(object: secondText as NSString))
        }
        if includeSlowBatch {
            let slow = NSItemProvider(object: url.appendingPathComponent("slow") as NSURL)
            let slowText = Data("第二项慢速正文 \(url.lastPathComponent)".utf8)
            slow.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
                // Every request is delayed, including retries; no fail-once state
                // that UIKit prefetching could accidentally consume.
                DispatchQueue.global().asyncAfter(deadline: .now() + 12) { completion(slowText, nil) }
                return Progress(totalUnitCount: 1)
            }
            providers.append(slow)
            providers.append(NSItemProvider(object: "第三项未开始正文 \(url.lastPathComponent)" as NSString))
        }
        let configuration = UIActivityItemsConfiguration(itemProviders: providers)
        return UIActivityViewController(activityItemsConfiguration: configuration)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
