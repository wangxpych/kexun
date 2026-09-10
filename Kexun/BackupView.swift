import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

nonisolated private struct BackupDocument: Transferable {
    var url: URL
    var filename: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.filename }
    }
}

struct BackupView: View {
    @ObservedObject var store: CollectionStore
    var onOpenRecord: ((CollectionRecord) -> Void)? = nil
    var onOpenTrash: (() -> Void)? = nil
    var onBusyChange: ((Bool) -> Void)? = nil
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    @State private var document: BackupDocument?
    @State private var message: String?
    @State private var confirmRecovery = false
    @State private var recoveryImport = false
    @State private var readableExport = false
    @State private var exportFilename = "kexun-backup.zip"
    @State private var exportRoot: URL?
    @State private var lastBackup: Date?
    @State private var receipt: LibraryDataManagement.BackupReceipt?
    @State private var pendingReceipt: LibraryDataManagement.BackupReceipt?
    @State private var usage: LibraryDataManagement.Usage?
    @State private var usageError: String?
    @State private var checkingUsage = false
    var body: some View {
        Form {
            Section("备份状态") {
                if let lastBackup {
                    LabeledContent("上次成功导出") { Text(lastBackup, format: .dateTime.year().month().day().hour().minute()) }
                } else { Text("尚未记录成功导出的完整备份。") }
                if let receipt {
                    LabeledContent("备份快照", value: String(localized: "\(receipt.recordCount) 条 · \(bytes(receipt.zipBytes))"))
                    if let usage {
                        Label(usage.fingerprint == receipt.fingerprint ? "当前资料与上次备份快照一致" : "有资料变化尚未包含在上次备份中",
                              systemImage: usage.fingerprint == receipt.fingerprint ? "checkmark.circle" : "clock.badge.exclamationmark")
                            .font(.callout).accessibilityIdentifier("backup.changes")
                    }
                    Text("比较收藏内容与状态，不代表重新校验原始附件或外部备份。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("仅在系统确认完整备份导出成功后记录时间，不代表外部文件仍存在或包含之后的变化。请自行保管并定期更新备份。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("存储用量") {
                if let usage {
                    LabeledContent("当前收藏", value: String(localized: "\(usage.activeCount) 条"))
                    LabeledContent("回收站", value: String(localized: "\(usage.trashCount) 条"))
                    LabeledContent("当前附件", value: bytes(usage.activeAttachmentBytes))
                    LabeledContent("仅回收站引用的附件", value: bytes(usage.trashOnlyAttachmentBytes))
                    LabeledContent("回收站涉及附件", value: bytes(usage.trashReferencedAttachmentBytes))
                    LabeledContent("附件合计", value: bytes(usage.totalAttachmentBytes))
                    if usage.unavailableAttachments > 0 {
                        Text("有 \(usage.unavailableAttachments) 份附件暂时无法读取，未计入占用。")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("按实际文件大小统计被收藏引用的本地附件，共享附件只计一次。不含数据库、临时文件和系统占用；回收站中的资料不会自动删除。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("刷新用量") { refreshUsage() }.disabled(checkingUsage || busy || store.loadError != nil)
                    .accessibilityIdentifier("backup.refreshUsage")
                if checkingUsage { ProgressView("正在统计…") }
                if let usageError { Text(verbatim: usageError).font(.caption).foregroundStyle(.secondary) }
                NavigationLink("查看大附件") { LibraryStorageView(store: store, onOpenRecord: onOpenRecord) }
                    .disabled(busy)
                    .accessibilityIdentifier("backup.largeAttachments")
                if let onOpenTrash { Button("打开回收站") { onOpenTrash() }.disabled(busy) }
            }
            Section {
                Text("完整备份包含收藏、备注、状态、回收站内容和原始附件，未加密，可能含私人信息，请勿公开分享。导出与恢复免费，不包含购买权益。")
                Text("本版本不自动跨设备同步。换机或重新安装前，请将备份保存到可寻之外；仅恢复购买无法找回资料。")
                Text("恢复会合并数据，不清空现有资料；超过 100 条仍可完整恢复。免费版超额后暂停普通新增和回收站恢复，已有资料仍可查看、编辑、搜索与导出。")
                Text("相同记录跳过；同 ID 的不同内容保留为新条目，不覆盖已有内容。支持 ZIP64 大备份；记录元数据上限为 128 MiB、清单上限为 32 MiB。处理时需要足够的本地临时空间，大备份可能耗时较长。")
            }
            Section {
                Button("导出备份") { export() }.disabled(busy || store.loadError != nil)
                Button("从备份恢复") { message = nil; recoveryImport = false; importing = true }.disabled(busy || store.loadError != nil)
                if busy { ProgressView("正在处理，请勿关闭…") }
                if let message { Text(message).textSelection(.enabled) }
            }
            Section("通用资料导出 · 免费") {
                Text("导出普通 Markdown 文本、阅读索引和原始附件，保留正文、备注、网址、状态及识别文本，离开可寻也可阅读。包含回收站内容，未加密，请勿公开分享。")
                Text("通用资料包不能用于可寻备份恢复，也不会更新上方完整备份时间。迁机请使用「导出备份」。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("导出 Markdown 与原始附件") { export(readable: true) }
                    .disabled(busy || store.loadError != nil).accessibilityIdentifier("backup.exportReadable")
            }
            if store.loadError != nil {
                Section("资料库读取失败") {
                    Text("先尝试重新打开。仍无法读取时，可从完整备份恢复到独立资料库；旧故障目录和附件保留，不会清库。恢复只包含备份时已有的内容，不会自动找回备份之后的新增或修改。")
                    Button("重新打开资料库") { store.open() }.disabled(busy)
                    Button("从备份进行故障恢复") { confirmRecovery = true }.disabled(busy)
                }
            }
        }.navigationTitle("数据与备份")
            .interactiveDismissDisabled(busy)
            .navigationBarBackButtonHidden(busy)
            .onAppear { updateReceipt(); refreshUsage() }
            .onChange(of: store.revision) { _, _ in if !busy { refreshUsage() } }
            .fileExporter(isPresented: $exporting, item: document, contentTypes: [.zip], defaultFilename: exportFilename) { result in
                switch result {
                case .success:
                    if !readableExport, let exportRoot {
                        do {
                            if let pendingReceipt { try LibraryDataManagement.recordSuccessfulBackup(root: exportRoot, receipt: pendingReceipt) }
                            updateReceipt()
                        } catch {
                            message = String(localized: "文件已导出，但本机备份记录未更新：\(error.localizedDescription)")
                            cleanupExport()
                            return
                        }
                    }
                    message = readableExport ? String(localized: "通用资料包已导出，可解压后打开 README.md 阅读。") : String(localized: "完整备份已导出。请确认外部位置并妥善保管。")
                case .failure(let error): message = String(localized: "导出未完成：\(error.localizedDescription)")
                }
                cleanupExport()
                refreshUsage()
            } onCancellation: { message = String(localized: "已取消导出，未更新完整备份时间。"); cleanupExport() }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                switch result {
                case .success(let url):
                    if recoveryImport {
                        setBusy(true)
                        Task { message = await store.recoverFromBackup(url); setBusy(false); updateReceipt(); refreshUsage() }
                    } else { restore(url) }
                case .failure(let error): message = error.localizedDescription
                }
            }
            .alert("从备份建立独立资料库？", isPresented: $confirmRecovery) {
                Button("选择备份并恢复") { message = nil; recoveryImport = true; importing = true }
                Button("取消", role: .cancel) {}
            } message: {
                Text("旧故障目录原地保留。校验成功后才切换到备份资料库；备份之后的内容不会自动合并。需要足够的空间保存恢复副本。")
            }
    }

    private func export(readable: Bool = false) {
        guard let repository = store.repository, let assets = store.attachments else { message = String(localized: "存储尚未打开。"); return }
        guard !busy else { return }
        setBusy(true)
        message = nil
        readableExport = readable
        exportRoot = assets.root
        exportFilename = LibraryDataManagement.filename(readable: readable)
        pendingReceipt = nil
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) { () -> (URL, LibraryDataManagement.BackupReceipt?) in
                    if readable { return (try LibraryDataManagement.exportReadable(repository: repository, assets: assets), nil) }
                    let url = try BackupArchive.exportFile(repository: repository, assets: assets)
                    do { return (url, try LibraryDataManagement.snapshotReceipt(archiveURL: url)) }
                    catch { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error }
                }.value
                document = BackupDocument(url: prepared.0, filename: exportFilename)
                pendingReceipt = prepared.1
                exporting = true
            } catch { message = error.localizedDescription; setBusy(false); exportRoot = nil }
        }
    }

    private func restore(_ url: URL) {
        guard let repository = store.repository, let assets = store.attachments else { message = String(localized: "存储尚未打开。"); return }
        guard !busy else { return }
        setBusy(true)
        Task {
            defer { setBusy(false); store.reload(); store.resumeExtraction(); refreshUsage() }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try BackupArchive.restoreFileReport(url, repository: repository, assets: assets)
                }.value
                message = report.message
            } catch { message = String(localized: "恢复未完成：\(error.localizedDescription)") }
        }
    }

    private func cleanupExport() {
        if let document {
            let directory = document.url.deletingLastPathComponent()
            Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: directory) }
        }
        document = nil
        exportRoot = nil
        pendingReceipt = nil
        setBusy(false)
    }

    // Notify synchronously so the parent navigation locks before work starts.
    // Do not unlock on disappearance: an export picker also covers this view,
    // and the underlying operation must retain ownership until it completes.
    private func setBusy(_ value: Bool) {
        busy = value
        onBusyChange?(value)
    }

    private func updateReceipt() {
        lastBackup = store.attachments.flatMap { LibraryDataManagement.lastSuccessfulBackup(root: $0.root) }
        receipt = store.attachments.flatMap { LibraryDataManagement.backupReceipt(root: $0.root) }
    }

    private func refreshUsage() {
        guard !checkingUsage, let repository = store.repository, let assets = store.attachments else { return }
        checkingUsage = true
        usageError = nil
        usage = nil
        let revision = store.revision
        Task {
            defer {
                checkingUsage = false
                if store.revision != revision, !busy { refreshUsage() }
            }
            do {
                let value = try await Task.detached(priority: .utility) {
                    try LibraryDataManagement.usage(repository: repository, assets: assets)
                }.value
                if store.attachments?.root == assets.root { usage = value }
                else { usage = nil }
            } catch { usageError = error.localizedDescription }
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}
