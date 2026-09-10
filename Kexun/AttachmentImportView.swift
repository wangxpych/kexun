import SwiftUI
import PhotosUI

/// A single attachment-import session. Text drafts never share its save/close controls.
struct AttachmentImportView: View {
    @ObservedObject var store: CollectionStore
    var initialFiles: [URL] = []
    var initialPhotos: [PhotosPickerItem] = []
    let onViewSaved: (Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var task: Task<Void, Never>?
    @State private var stopping = false
    @State private var retryFiles: [URL] = []
    @State private var retryPhotos: [PhotosPickerItem] = []
    @State private var savedIDs = Set<UUID>()
    @State private var failures: [String] = []
    @State private var photos: [PhotosPickerItem] = []
    @State private var choosingFiles = false
    @State private var confirmDiscard = false
    @State private var exitAfterDiscard = false
    @State private var viewAfterDiscard = false
    private var busy: Bool { task != nil }
    private var remaining: Int { retryFiles.count + retryPhotos.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(busy ? "正在导入" : (remaining > 0 ? "还有项目未保存" : "导入完成"),
                          systemImage: busy ? "tray.and.arrow.down" : (remaining > 0 ? "exclamationmark.circle" : "checkmark.circle"))
                        .font(.headline)
                    Text("本次已导入 \(savedIDs.count) 项，已保存到资料库。")
                        .accessibilityIdentifier("import.savedCount")
                    if busy {
                        ProgressView(stopping ? "正在停止，请稍候…" : "正在保存本地副本…")
                        Button("停止剩余导入") { stopping = true; task?.cancel() }.disabled(stopping)
                        Text("已经导入的资料会保留；停止只影响尚未保存的项目。")
                    } else if !savedIDs.isEmpty {
                        Button("查看已保存资料") { requestExit(viewSaved: true) }
                            .accessibilityIdentifier("import.viewSaved")
                    }
                }
                if !failures.isEmpty {
                    Section("本次未保存的原因") {
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                            Text(verbatim: failure).textSelection(.enabled)
                        }
                    }
                }
                if remaining > 0 {
                    Section("未保存项目") {
                        Text("还有 \(remaining) 项未保存，重试不会重复导入成功项。")
                            .accessibilityIdentifier("import.remaining")
                        Button("重试未保存项目") {
                            if !retryFiles.isEmpty { importFiles(retryFiles) }
                            else { importPhotos(retryPhotos) }
                        }.disabled(busy).accessibilityIdentifier("import.retry")
                        Button("放弃未保存项目", role: .destructive) {
                            exitAfterDiscard = false; viewAfterDiscard = false; confirmDiscard = true
                        }.disabled(busy).accessibilityIdentifier("import.discard")
                        Text("清单只在本次导入页面保留。如果来源权限失效，请明确放弃此清单后重新选择。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("继续导入") {
                    PhotosPicker(selection: $photos, maxSelectionCount: 20, matching: .images) {
                        Label("选择照片", systemImage: "photo")
                    }.disabled(busy || remaining > 0)
                    Button("导入文件 / PDF") { choosingFiles = true }.disabled(busy || remaining > 0)
                    if remaining > 0 {
                        Text("请先重试或明确放弃未保存项目，再选择下一批。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("选完即导入，每项单独保存，无需再点保存。单附件最大 100 MB；照片每次最多 20 张。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                QuotaUpgradeView(store: store)
            }.navigationTitle("导入资料")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { requestExit(viewSaved: false) }.disabled(busy)
                            .accessibilityIdentifier("import.done")
                    }
                }
        }
        .interactiveDismissDisabled(busy || remaining > 0)
        .confirmationDialog("还有 \(remaining) 项未保存", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(exitAfterDiscard ? "放弃未保存项目并继续" : "放弃未保存项目", role: .destructive) {
                retryFiles = []; retryPhotos = []; failures = []
                if exitAfterDiscard { finish(viewSaved: viewAfterDiscard) }
            }.accessibilityIdentifier("import.confirmDiscard")
            Button("继续处理") {}.accessibilityIdentifier("import.keepPending")
        } message: {
            Text("已导入的资料不会删除。放弃后将清除本次重试清单，未保存项目需要重新选择。")
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if !busy && remaining == 0 { importFiles(urls) }
            case .failure(let error): failures = [error.localizedDescription]
            }
        }
        .onChange(of: photos) { _, selection in
            if !selection.isEmpty && !busy && remaining == 0 { importPhotos(selection) }
        }
        .task {
            guard !started else { return }
            started = true
            if !initialFiles.isEmpty { importFiles(initialFiles) }
            else if !initialPhotos.isEmpty { importPhotos(initialPhotos) }
        }
    }

    private func requestExit(viewSaved: Bool) {
        guard !busy else { return }
        if remaining > 0 {
            exitAfterDiscard = true; viewAfterDiscard = viewSaved; confirmDiscard = true
        } else { finish(viewSaved: viewSaved) }
    }

    private func finish(viewSaved: Bool) {
        if viewSaved { onViewSaved(savedIDs) }
        dismiss()
    }

    private func importFiles(_ urls: [URL]) {
        guard !busy else { return }
        stopping = false
        failures = []
        task = Task {
            defer { task = nil; stopping = false }
            let result = await store.importFiles(urls)
            savedIDs.formUnion(result.savedIDs)
            retryFiles = result.unsavedURLs
            failures = result.failures
        }
    }

    private func importPhotos(_ selection: [PhotosPickerItem]) {
        guard !busy else { return }
        stopping = false
        failures = []
        task = Task {
            defer { photos = []; task = nil; stopping = false }
            guard store.canImport(selection.count) else {
                retryPhotos = selection
                failures = [store.error ?? String(localized: "无法导入所选照片。")]
                return
            }
            retryPhotos = []
            for (index, item) in selection.enumerated() {
                do {
                    try Task.checkCancellation()
                    guard let photo = try await PhotoTransfer.load(start: { completion in
                        item.loadTransferable(type: PhotoTransfer.self, completionHandler: completion)
                    }) else { throw CollectionError.invalid(String(localized: "无法读取所选照片。")) }
                    defer { photo.cleanup() }
                    let result = await store.importFiles([photo.url], imageOverride: true)
                    savedIDs.formUnion(result.savedIDs)
                    failures += result.failures.map { String(localized: "第 \(index + 1) 张：\($0)") }
                    if result.saved == 0 { retryPhotos.append(item) }
                    if Task.isCancelled {
                        retryPhotos.append(contentsOf: selection.dropFirst(index + 1))
                        break
                    }
                } catch is CancellationError {
                    retryPhotos.append(contentsOf: selection[index...])
                    failures.append(String(localized: "已停止，剩余 \(selection.count - index) 张未保存。"))
                    break
                } catch {
                    retryPhotos.append(item)
                    failures.append(String(localized: "第 \(index + 1) 张：\(error.localizedDescription)"))
                }
            }
        }
    }
}
