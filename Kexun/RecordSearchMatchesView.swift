import SwiftUI
import PDFKit

/// Place inside a Section at the top of the detail Form. Searches saved content, not editing drafts.
struct RecordSearchMatchesView: View {
    let record: CollectionRecord
    let query: String
    let attachments: AttachmentStore?
    @State private var result: RecordSearchMatches.Result?
    @State private var index = 0
    @State private var failure: String?
    @State private var selectedPDF: AttachmentReference?

    private struct Request: Equatable {
        let record: CollectionRecord
        let query: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("搜索定位", systemImage: "text.magnifyingglass").font(.headline)
            Text(verbatim: query).font(.subheadline).textSelection(.enabled)
            if let result {
                if result.hits.isEmpty {
                    Text("当前已保存内容中没有可定位的匹配。内容可能已更新，或命中位于定位上限之外。")
                        .font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("searchMatch.status")
                } else {
                    MatchNavigation(index: $index, count: result.hits.count, prefix: "searchMatch")
                    if result.hits.indices.contains(index) {
                        let hit = result.hits[index]
                        Text(verbatim: hit.field).font(.caption).foregroundStyle(.secondary)
                        MatchExcerpt(hit: hit).id(index)
                    }
                }
                if result.limited { searchLimitNotice }
            } else if let failure {
                Text(verbatim: failure).font(.callout).foregroundStyle(.secondary)
            } else { ProgressView("正在定位关键词…") }
            if let attachments {
                ForEach(record.attachments.filter { $0.contentType == "com.adobe.pdf" }) { reference in
                    Button { selectedPDF = reference } label: {
                        Label { Text("在 PDF 中定位：\(reference.originalName)") } icon: { Image(systemName: "doc.text.magnifyingglass") }
                    }.buttonStyle(.borderless).accessibilityIdentifier("searchMatch.pdf.\(reference.id)")
                }
                // A separate snapshot is loaded only on request; nothing writes to the original PDF.
                Color.clear.frame(height: 0).sheet(item: $selectedPDF) { reference in
                    PDFSearchReader(reference: reference, attachments: attachments, query: query)
                }
            }
        }
        .task(id: Request(record: record, query: query)) {
            result = nil; index = 0; failure = nil
            let current = record
            let search = query
            let worker = Task.detached(priority: .userInitiated) { try RecordSearchMatches.scan(record: current, query: search) }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                result = value
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}

private var searchLimitNotice: some View {
    Text("为保持响应，仅定位前 100 万个文本单位、最多 500 处匹配；关键词最多 32 个，每个最多 256 字符。此处数量不代表全文总数，原内容不受影响。")
        .font(.caption).foregroundStyle(.secondary)
}

private struct MatchNavigation: View {
    @Binding var index: Int
    let count: Int
    let prefix: String
    var body: some View {
        HStack {
            Text("第 \(index + 1) / \(count) 处").font(.subheadline.monospacedDigit())
                .accessibilityIdentifier("\(prefix).status")
            Spacer()
            Button { index -= 1 } label: { Image(systemName: "chevron.up").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("上一处匹配").accessibilityIdentifier("\(prefix).previous")
                .disabled(index <= 0).buttonStyle(.borderless)
            Button { index += 1 } label: { Image(systemName: "chevron.down").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("下一处匹配").accessibilityIdentifier("\(prefix).next")
                .disabled(index >= count - 1).buttonStyle(.borderless)
        }
    }
}

private struct MatchExcerpt: View {
    let hit: RecordSearchMatches.Hit
    var identifier = "searchMatch.excerpt"
    private var highlighted: AttributedString {
        var value = AttributedString(hit.excerpt)
        if let range = Range(hit.highlight, in: hit.excerpt), let attributedRange = Range(range, in: value) {
            value[attributedRange].backgroundColor = .yellow.opacity(0.5)
            value[attributedRange].foregroundColor = .primary
            value[attributedRange].font = .body.bold()
        }
        return value
    }
    var body: some View {
        Text(highlighted).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

private struct PDFSearchReader: View {
    let reference: AttachmentReference
    let attachments: AttachmentStore
    let query: String
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: RecordSearchMatches.PDFResult?
    @State private var failure: String?
    @State private var index = 0

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if let loaded {
                    if loaded.result.hits.isEmpty {
                        ContentUnavailableView("PDF 中没有可定位的文字", systemImage: "doc.text.magnifyingglass",
                                               description: Text("扫描件、字体编码或内容差异可能导致无法定位。关闭后仍可查看已保存的识别文本；这里不会新增 OCR。"))
                    } else {
                        MatchNavigation(index: $index, count: loaded.result.hits.count, prefix: "pdfSearchMatch")
                        let hit = loaded.result.hits[index]
                        Text("第 \((hit.pageIndex ?? 0) + 1) 页").font(.caption)
                        MatchExcerpt(hit: hit, identifier: "pdfSearchMatch.excerpt")
                        SearchPDFView(data: loaded.data, hit: hit)
                            .accessibilityIdentifier("pdfSearchMatch.document")
                    }
                    if loaded.result.limited {
                        searchLimitNotice
                        Text("PDF 页码定位最多检查前 1000 页。").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let failure {
                    ContentUnavailableView("暂时无法定位 PDF", systemImage: "doc.badge.ellipsis", description: Text(verbatim: failure))
                } else { ProgressView("正在读取本地 PDF…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.padding().navigationTitle(reference.originalName).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.task {
            let current = reference
            let storage = attachments
            let search = query
            let worker = Task.detached(priority: .userInitiated) {
                try RecordSearchMatches.loadPDF(reference: current, attachments: storage, query: search)
            }
            do {
                let value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                loaded = value
            } catch is CancellationError { } catch { failure = error.localizedDescription }
        }
    }
}

private struct SearchPDFView: UIViewRepresentable {
    let data: Data
    let hit: RecordSearchMatches.Hit
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        guard let pageIndex = hit.pageIndex, let page = view.document?.page(at: pageIndex) else { return }
        if let selection = page.selection(for: hit.sourceRange) {
            selection.color = .systemYellow
            view.highlightedSelections = [selection]
            view.setCurrentSelection(selection, animate: false)
            view.go(to: selection)
        } else {
            view.highlightedSelections = []
            view.go(to: page)
        }
    }
}
