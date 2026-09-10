import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

struct LibraryStorageView: View {
    @ObservedObject var store: CollectionStore
    var onOpenRecord: ((CollectionRecord) -> Void)? = nil
    @State private var usage: LibraryDataManagement.Usage?
    @State private var failure: String?
    @State private var loading = false
    @State private var refreshRequested = false

    var body: some View {
        List {
            Section {
                Text("按本地实际附件大小从大到小排列，同一附件只列一次。打开所属收藏后，使用已有删除确认；这里不会删除任何内容。")
                Text("仅回收站引用的容量是预计可释放的附件内容大小，不等于系统最终释放空间；共享附件仍被当前收藏引用时不会释放。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新") { refresh() }.disabled(loading)
                if loading { ProgressView("正在读取实际文件大小…") }
                if let failure { Text(verbatim: failure).foregroundStyle(.secondary) }
                if let usage, usage.unavailableAttachments > 0 {
                    Text("\(usage.unavailableAttachments) 份附件无法读取，未出现在此列表。")
                }
            }
            if let usage {
                if usage.largeAttachments.isEmpty { Text("暂无可读取的附件。") }
                ForEach(usage.largeAttachments) { attachment in
                    Section {
                        LabeledContent { Text(ByteCountFormatter.string(fromByteCount: attachment.bytes, countStyle: .file)) }
                            label: { Text(verbatim: attachment.filename) }
                        ForEach(attachment.records) { record in
                            if let onOpenRecord {
                                Button { onOpenRecord(record) } label: { ownerLabel(record) }
                                    .accessibilityIdentifier("storage.record.\(record.id)")
                            } else { ownerLabel(record) }
                        }
                    }
                }
            }
        }.navigationTitle("大附件")
            .onAppear { refresh() }
            .onChange(of: store.revision) { _, _ in refresh() }
            .onChange(of: store.attachments?.root) { _, _ in refresh() }
            .onChange(of: store.loadError) { _, _ in refresh() }
    }

    private func ownerLabel(_ record: CollectionRecord) -> some View {
        HStack {
            Text(verbatim: record.title)
            Spacer()
            if record.deletedAt != nil { Text("回收站").font(.caption).foregroundStyle(.secondary) }
            else { Text("当前收藏").font(.caption).foregroundStyle(.secondary) }
            if onOpenRecord != nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func refresh() {
        // Never leave actionable owners from an obsolete snapshot on screen.
        usage = nil
        guard !loading else { refreshRequested = true; return }
        guard store.loadError == nil else { failure = store.loadError; return }
        guard let repository = store.repository, let assets = store.attachments else {
            failure = String(localized: "存储尚未打开。")
            return
        }
        let revision = store.revision
        let root = assets.root
        refreshRequested = false
        loading = true
        // Keep the previous failure visible until a current snapshot succeeds.
        Task {
            defer {
                loading = false
                if refreshRequested || store.revision != revision || store.attachments?.root != root {
                    refresh()
                }
            }
            do {
                let value = try await Task.detached(priority: .utility) {
                    try LibraryDataManagement.usage(repository: repository, assets: assets)
                }.value
                guard store.revision == revision, store.attachments?.root == root, store.loadError == nil else { return }
                usage = value
                failure = nil
            } catch {
                guard store.revision == revision, store.attachments?.root == root else { return }
                failure = store.loadError ?? error.localizedDescription
            }
        }
    }
}

nonisolated private struct ReadableDocument: Transferable {
    var url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.url.lastPathComponent }
    }
}

/// Present as a sheet from detail or multi-selection. nil exports the entire library.
struct ReadableExportView: View {
    @ObservedObject var store: CollectionStore
    var selectedIDs: Set<UUID>? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var document: ReadableDocument?
    @State private var exporting = false
    @State private var busy = false
    @State private var message: String?
    @State private var filename = "kexun-readable.zip"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let selectedIDs { Text("导出选中的 \(selectedIDs.count) 条收藏及其原始附件。") }
                    else { Text("导出全部收藏（含回收站）与原始附件。") }
                    Text("资料包包含普通 Markdown 与阅读索引，不需要可寻即可阅读；它不是用于恢复的完整备份。未加密，可能含私人信息，请勿公开分享。")
                    Button("选择保存位置") { prepare() }.disabled(busy || selectedIDs?.isEmpty == true)
                        .accessibilityIdentifier("readableExport.save")
                    if busy { ProgressView("正在准备并校验资料包…") }
                    if let message { Text(verbatim: message).textSelection(.enabled) }
                }
            }.navigationTitle("导出资料").toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.disabled(busy) }
            }
        }.interactiveDismissDisabled(busy)
            .fileExporter(isPresented: $exporting, item: document, contentTypes: [.zip], defaultFilename: filename) { result in
                switch result {
                case .success: message = String(localized: "资料包已导出，可解压后打开 README.md 阅读。")
                case .failure(let error): message = String(localized: "导出未完成：\(error.localizedDescription)")
                }
                cleanup()
            } onCancellation: { message = String(localized: "已取消导出，没有更新完整备份时间。"); cleanup() }
    }

    private func prepare() {
        guard let repository = store.repository, let assets = store.attachments else {
            message = String(localized: "存储尚未打开。"); return
        }
        busy = true; message = nil
        let ids = selectedIDs
        filename = LibraryDataManagement.filename(readable: true)
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try LibraryDataManagement.exportReadable(repository: repository, assets: assets, selectedIDs: ids)
                }.value
                document = ReadableDocument(url: url)
                exporting = true
            } catch { message = error.localizedDescription; busy = false }
        }
    }

    private func cleanup() {
        if let document {
            let directory = document.url.deletingLastPathComponent()
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
        }
        document = nil; busy = false
    }
}
