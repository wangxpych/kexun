import SwiftUI
import StoreKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import CoreTransferable

struct LibraryView: View {
    @StateObject private var store: CollectionStore
    @StateObject private var purchase = PurchaseService()
    @StateObject private var clipboardHint = ClipboardCaptureHint()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    private let trashOnly: Bool
    @State private var adding = false
    @State private var captureText = ""
    @State private var settings = false
    @State private var settingsSelected: CollectionRecord?
    @State private var showingTrash = false
    @State private var backupBusy = false
    @State private var importedSelection: Set<UUID>?
    @State private var searching = false
    @State private var searchEntryQuery: CollectionQuery?
    @FocusState private var searchFocused: Bool
    @AppStorage("kexun.library.listLayout") private var listLayout = true
    @State private var query: CollectionQuery
    @State private var selected: CollectionRecord?
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var showingFilters = false
    @State private var confirmingTrash = false
    @State private var confirmingPermanent = false
    @State private var namingFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: String?
    @State private var removingFolder = false
    private struct ExportSelection: Identifiable {
        let id = UUID()
        let ids: Set<UUID>
    }
    @State private var exportSelection: ExportSelection?
    @AppStorage("kexun.captureGuide.dismissed") private var captureGuideDismissed = false
    private let green = Color(uiColor: KexunPalette.accent)

    init(store: CollectionStore? = nil, trashOnly: Bool = false) {
        _store = StateObject(wrappedValue: store ?? CollectionStore())
        self.trashOnly = trashOnly
        _query = State(initialValue: CollectionQuery(scope: trashOnly ? .trash : .library))
    }
    private var versionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return String(localized: "可寻 \(version)（\(build)）")
    }
    private struct SearchRequest: Hashable {
        let query: CollectionQuery
        let revision: UInt64
    }
    @State private var searchResults: [CollectionRecord] = []
    @State private var completedRequest: SearchRequest?
    private var searchRequest: SearchRequest { SearchRequest(query: query, revision: store.revision) }
    private var filtering: Bool { completedRequest != searchRequest }
    private var visible: [CollectionRecord] { filtering ? [] : searchResults }
    private var folderTitle: String {
        query.folder.map { $0.isEmpty ? String(localized: "未分组") : $0 } ?? String(localized: "资料库")
    }
    private var additionalFilterCount: Int {
        [query.kind != nil, query.source != nil, query.since != nil,
         query.archived == true || (query.starredOnly && query.archived == false)].filter { $0 }.count
    }
    private var filterSummary: String {
        var pieces: [String] = []
        if let kind = query.kind { pieces.append(kind.title) }
        if let source = query.source { pieces.append(sourceFilterLabel(source)) }
        if let since = query.since { pieces.append(String(localized: "\(since.formatted(date: .abbreviated, time: .omitted))起")) }
        if query.archived == true { pieces.append(String(localized: "已归档")) }
        if query.starredOnly && query.archived == false { pieces.append(String(localized: "未归档")) }
        return pieces.joined(separator: " · ")
    }
    private var clipboardEligible: Bool {
        scenePhase == .active && !trashOnly && !adding && !settings && selected == nil &&
        exportSelection == nil && !showingFilters && !selecting && !searchFocused && !searching &&
        !namingFolder && !removingFolder && store.error == nil && !store.importing
    }
    private func sourceFilterLabel(_ source: String) -> String {
        let name = LinkSource.displayName(for: source)
        return name == source ? source : "\(name) · \(source)"
    }
    private var emptyState: (title: String, message: String) {
        if !query.text.isEmpty || query.activeFilterCount > 0 {
            return (String(localized: "没有找到内容"), String(localized: "试试其他关键词，或调整当前收藏夹与筛选。"))
        }
        if trashOnly { return (String(localized: "回收站为空"), String(localized: "删除的收藏会先保留在这里，可恢复或永久删除。")) }
        return (String(localized: "先收下第一条内容"), String(localized: "点击“收藏”保存链接、文字、照片或文件。收藏会保存在本机。"))
    }

    private var folderMenu: some View {
        Menu {
            Button("全部收藏夹") { query.folder = nil }
            Button("未分组") { query.folder = "" }
            ForEach(store.folders, id: \.self) { folder in
                Button(folder) { query.folder = folder }
            }
            if let folder = query.folder, !folder.isEmpty {
                Divider()
                Button("重命名当前收藏夹") { renamingFolder = folder; newFolderName = folder; namingFolder = true }
                Button("移除当前收藏夹", role: .destructive) { removingFolder = true }
            }
        } label: {
            HStack(spacing: 7) {
                Text(folderTitle).font(.largeTitle.bold()).lineLimit(2)
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold))
            }.foregroundStyle(.primary).frame(minHeight: 44)
        }.accessibilityIdentifier("library.folders")
    }

    private var moreMenu: some View {
        Menu {
            Button("多选", systemImage: "checkmark.circle") { selecting = true; selection.removeAll() }
            Section("排序") {
                Button { query.newestFirst = true } label: { Label("最近保存", systemImage: query.newestFirst ? "checkmark" : "clock") }
                Button { query.newestFirst = false } label: { Label("最早保存", systemImage: !query.newestFirst ? "checkmark" : "clock") }
            }
            Section("布局") {
                Button { listLayout = true } label: { Label("列表", systemImage: listLayout ? "checkmark" : "list.bullet") }
                Button { listLayout = false } label: { Label("卡片", systemImage: !listLayout ? "checkmark" : "square.grid.2x2") }
            }
            if trashOnly {
                Button("清空回收站", role: .destructive) {
                    selection = Set(store.records.filter { $0.deletedAt != nil }.map(\.id))
                    confirmingPermanent = true
                }.disabled(!store.records.contains { $0.deletedAt != nil })
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 22)).frame(width: 44, height: 44)
        }.accessibilityLabel("更多").accessibilityIdentifier("library.more")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                if trashOnly { Text("回收站").font(.largeTitle.bold()) }
                else { folderMenu }
                Text(store.loadError != nil ? String(localized: "暂时无法确认收藏数量") :
                        filtering ? String(localized: "正在查找…") : String(localized: "\(visible.count) 条收藏"))
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("library.count")
            }
            Spacer(minLength: 0)
            moreMenu
            if !trashOnly {
                Button { searchFocused = false; settings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 22)).frame(width: 44, height: 44)
                }.accessibilityLabel("设置").accessibilityIdentifier("library.settings")
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索收藏", text: $query.text)
                .focused($searchFocused).submitLabel(.search).accessibilityIdentifier("library.search")
                .onSubmit { searchFocused = false }
            if searching {
                Button("取消") {
                    if let searchEntryQuery { query = searchEntryQuery }
                    searching = false
                    searchFocused = false
                }.accessibilityIdentifier("library.cancelSearch")
            }
        }.padding(.horizontal, 14).frame(minHeight: 48)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private var quickFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { query.starredOnly = false; query.archived = nil } label: { Text("全部").frame(minHeight: 30) }
                    .tint(!query.starredOnly && query.archived == nil ? green : .secondary)
                    .accessibilityIdentifier("quick.all")
                    .accessibilityAddTraits(!query.starredOnly && query.archived == nil ? .isSelected : [])
                Button { query.starredOnly = false; query.archived = false } label: { Text("未归档").frame(minHeight: 30) }
                    .tint(!query.starredOnly && query.archived == false ? green : .secondary)
                    .accessibilityIdentifier("quick.unarchived")
                    .accessibilityAddTraits(!query.starredOnly && query.archived == false ? .isSelected : [])
                Button { query.starredOnly = true; query.archived = nil } label: { Text("星标").frame(minHeight: 30) }
                    .tint(query.starredOnly ? green : .secondary)
                    .accessibilityIdentifier("quick.starred")
                    .accessibilityAddTraits(query.starredOnly ? .isSelected : [])
                Button { searchFocused = false; showingFilters = true } label: {
                    Label(additionalFilterCount == 0 ? String(localized: "筛选") : String(localized: "筛选 \(additionalFilterCount)"),
                          systemImage: "line.3.horizontal.decrease").frame(minHeight: 30)
                }.tint(additionalFilterCount > 0 ? green : .secondary)
                    .accessibilityIdentifier("library.filters")
            }.buttonStyle(.bordered).controlSize(.regular)
                .frame(minHeight: 44)
        }.scrollIndicators(.hidden)
    }

    private var filterSheet: some View {
        NavigationStack {
            Form {
                Section("内容类型") {
                    Picker("类型", selection: $query.kind) {
                        Text("全部类型").tag(Optional<ContentKind>.none)
                        ForEach(ContentKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }.accessibilityIdentifier("filter.kind")
                }
                Section("来源与时间") {
                    Picker("来源", selection: $query.source) {
                        Text("全部来源").tag(Optional<String>.none)
                        ForEach(Array(Set(store.records.filter { ($0.deletedAt != nil) == trashOnly }.map(\.source))).sorted(), id: \.self) {
                            Text(sourceFilterLabel($0)).tag(Optional($0))
                        }
                    }.accessibilityIdentifier("filter.source")
                    Picker("保存时间", selection: Binding(get: { query.since == nil ? 0 : (Date().timeIntervalSince(query.since!) < 8 * 86400 ? 7 : 30) },
                                                       set: { query.since = $0 == 0 ? nil : Date().addingTimeInterval(-Double($0) * 86400) })) {
                        Text("不限时间").tag(0)
                        Text("最近 7 天").tag(7)
                        Text("最近 30 天").tag(30)
                    }.accessibilityIdentifier("filter.time")
                }
                Section("归档状态") {
                    Picker("归档状态", selection: $query.archived) {
                        Text("全部归档状态").tag(Optional<Bool>.none)
                        Text("未归档").tag(Optional(false))
                        Text("已归档").tag(Optional(true))
                    }.accessibilityIdentifier("filter.archive")
                }
                Section {
                    Button("重置筛选") {
                        query.kind = nil; query.source = nil; query.since = nil
                        query.archived = nil; query.starredOnly = false
                    }
                } footer: { Text("筛选只作用于当前收藏夹。重置不会改变收藏夹、关键词或排序。") }
            }.navigationTitle("筛选")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingFilters = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.loadError {
                Label("暂时无法读取资料", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).textSelection(.enabled)
                Text("这不表示资料为空。不会自动清空或重建资料，请勿卸载应用。").font(.caption)
                Button("重试读取") { store.open() }.frame(minHeight: 44)
            }
            if let error = store.processingPersistenceError {
                Label("自动处理已暂停", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).textSelection(.enabled)
                Button("重试自动处理") { store.open() }.frame(minHeight: 44)
            }
            if !captureGuideDismissed && !trashOnly {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("从分享菜单收下，或复制链接后粘贴").font(.subheadline.weight(.medium))
                        Text("资料只保存在本机。换机前，请到设置导出备份。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button { captureGuideDismissed = true } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("关闭收集提示")
                }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var selectionActions: some View {
        (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
            Button("取消多选") { selecting = false; selection.removeAll() }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 4) }
            Text("已选 \(selection.count) 条").font(.caption)
            Button("全选") { selection = Set(visible.map(\.id)) }.disabled(filtering)
                .accessibilityLabel("全选当前结果")
            Menu("操作") {
                Button("导出所选资料") { exportSelection = ExportSelection(ids: selection) }
                if trashOnly {
                    Button("恢复所选") { if store.restoreMany(selection) { selection.removeAll() } }
                    Button("永久删除所选", role: .destructive) { confirmingPermanent = true }
                } else {
                    Button("星标") { apply(.star(true)) }
                    Button("取消星标") { apply(.star(false)) }
                    Button("归档") { apply(.archive(true)) }
                    Button("取消归档") { apply(.archive(false)) }
                    Menu("移入收藏夹") {
                        Button("新建收藏夹并移入") { renamingFolder = nil; newFolderName = ""; namingFolder = true }
                        ForEach(store.folders, id: \.self) { folder in Button(folder) { apply(.folder(folder)) } }
                        Button("移出收藏夹") { apply(.folder(nil)) }
                    }
                    Button("移入回收站", role: .destructive) { confirmingTrash = true }
                }
            }.disabled(selection.isEmpty || filtering)
        }.buttonStyle(.bordered).font(.subheadline)
    }

    private var bottomActions: some View {
        VStack(spacing: 10) {
            if clipboardEligible && clipboardHint.isAvailable {
                (dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))) {
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("可能有链接").font(.caption)
                            .accessibilityLabel("剪贴板可能有链接，粘贴后预览，确认再保存")
                            .accessibilityIdentifier("clipboard.hint")
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("剪贴板可能有链接").font(.subheadline.weight(.medium)).accessibilityIdentifier("clipboard.hint")
                            Text("粘贴后预览，确认再保存").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 0) }
                    HStack {
                        ClipboardCaptureButton { text in
                            guard clipboardEligible else { return }
                            clipboardHint.dismiss()
                            captureText = text
                            adding = true
                        }
                        Button { clipboardHint.dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("关闭粘贴提示").accessibilityIdentifier("clipboard.dismiss")
                    }
                }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
            if selecting { selectionActions }
            else if !trashOnly && !searchFocused {
                HStack {
                    Spacer()
                    Button {
                        captureText = ""
                        adding = true
                    } label: {
                        Label("收藏", systemImage: "plus").font(.headline).padding(.horizontal, 14).frame(minHeight: 48)
                    }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        .accessibilityLabel("添加内容").accessibilityIdentifier("library.add")
                }
            }
        }.padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var libraryPage: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    searchBar
                    quickFilters
                    if !filterSummary.isEmpty {
                        Text(filterSummary).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("library.filterSummary")
                    }
                    if searching && query.activeFilterCount > 0 {
                        Button("在全部收藏中搜索") {
                            query.resetFilters()
                        }.font(.caption).frame(minHeight: 44)
                    }
                    if store.loadError != nil || store.processingPersistenceError != nil || (!captureGuideDismissed && !trashOnly) { notices }
                    if !adding && selected == nil && store.quotaExceeded { QuotaUpgradeView(store: store) }
                    if filtering { ProgressView("正在读取结果…") }
                    if visible.isEmpty && !filtering && store.loadError == nil {
                        ContentUnavailableView(emptyState.title, systemImage: "tray", description: Text(emptyState.message))
                    }
                    LazyVGrid(columns: listLayout || dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(visible) { record in
                            Button {
                                if selecting {
                                    if selection.contains(record.id) { selection.remove(record.id) } else { selection.insert(record.id) }
                                } else { selected = record }
                            } label: {
                                LibraryRecordTile(record: record, store: store,
                                                  compact: listLayout || dynamicTypeSize.isAccessibilitySize,
                                                  snippet: searching ? query.snippet(for: record) : nil,
                                                  selected: selecting ? selection.contains(record.id) : nil)
                            }.buttonStyle(.plain).accessibilityIdentifier("record.\(record.id.uuidString)")
                        }
                    }.accessibilityIdentifier(listLayout ? "library.list" : "library.grid")
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            }.scrollDismissesKeyboard(.interactively)
                .background(Color(uiColor: KexunPalette.page))
                .toolbar {
                    if trashOnly {
                        ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                    }
                }
                .toolbar(trashOnly ? .visible : .hidden, for: .navigationBar)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomActions }
        }
    }

    private var settingsPage: some View {
        NavigationStack {
            Form {
                Section("数据") {
                    NavigationLink("数据与备份") {
                        BackupView(store: store, onOpenRecord: { record in
                            if let current = store.records.first(where: { $0.id == record.id }) { settingsSelected = current }
                            else { store.error = CollectionError.missing.localizedDescription }
                        }, onOpenTrash: { showingTrash = true }, onBusyChange: { backupBusy = $0 })
                    }
                    Button("回收站") {
                        showingTrash = true
                    }.accessibilityIdentifier("settings.trash")
                }
                Section("可寻 Pro · 永久版") {
                    Text(purchase.isPro ? String(localized: "已永久解锁收藏数量限制") : String(localized: "免费版可保存 100 条，所有核心功能均可使用。"))
                    if !purchase.isPro {
                        Button(purchase.displayPrice.map { String(localized: "升级 Pro · \($0)") } ?? String(localized: "加载商品")) { Task { if purchase.product == nil { await purchase.load() } else { await purchase.purchase() } } }.disabled(purchase.busy)
                    }
                    Button("恢复购买") { Task { await purchase.restore() } }.disabled(purchase.busy)
                    Text("恢复购买仅恢复 Pro 解锁权益，不恢复收藏资料。找回资料请使用“数据与备份”。永久版解锁收藏条数，不包含未来另行收费的云服务或 AI 服务。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let message = purchase.message { Text(message).font(.caption) }
                }
                Section("如何收集") {
                    NavigationLink("使用帮助") { UsageHelpView() }
                    Text("在 Safari 或其他 App 点击系统分享，选择“可寻”。首次使用可在分享列表的“更多”中启用可寻。")
                    Text("也可以点击资料库的“收藏”按钮 保存链接、文字，或从照片与文件选择器导入内容。来源 App 未提供的正文或附件无法自动收集。")
                }
                Section("隐私与数据") {
                    Text("收藏及附件保存在本机。本版本不提供跨设备同步，也不建立可寻账号。换机或重新安装前，请在“数据与备份”中导出并保存到可寻之外；恢复购买不会找回本地资料。")
                    Text("保存链接后会访问该网站及其封面地址补全标题和图片，目标网站可能接收网络请求信息。图片 OCR 与 PDF 文本提取在设备上进行。")
                    Text("回到资料库时，仅检测剪贴板是否可能包含链接；点击系统粘贴按钮后才读取内容，确认保存后才收藏。不收集定位或通讯录，不上传收藏到分析服务。购买由 Apple 处理。导出的备份包含私人内容，请妥善保管。")
                }
                Section { Text(versionDescription).accessibilityIdentifier("settings.version") }
            }.navigationTitle("设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { self.settings = false }.disabled(backupBusy)
                    }
                }
                .sheet(isPresented: $showingTrash) { LibraryView(store: store, trashOnly: true) }
                .sheet(item: $settingsSelected) { RecordDetailView(store: store, record: $0) }
        }
    }


    var body: some View {
        libraryPage
            .sheet(isPresented: $settings) { settingsPage.interactiveDismissDisabled(backupBusy) }
            .sheet(isPresented: $showingFilters) { filterSheet }
            .alert(renamingFolder == nil ? String(localized: "新建收藏夹并移入") : String(localized: "重命名收藏夹"), isPresented: $namingFolder) {
                TextField("收藏夹名称", text: $newFolderName)
                Button("确定") {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let old = renamingFolder {
                        if store.renameFolder(old, to: name) { query.folder = name }
                    } else { apply(.folder(name)) }
                }.disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).count > 40)
                Button("取消", role: .cancel) {}
            } message: { Text("最多 40 个字符。同名收藏夹会合并；每条收藏属于一个收藏夹，不包含子文件夹。空收藏夹不保留。") }
            .alert("移除收藏夹？", isPresented: $removingFolder) {
                Button("仅移除分组", role: .destructive) {
                    if let folder = query.folder, store.renameFolder(folder, to: nil) { query.folder = nil }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("其中的收藏与回收站内容都保留，只取消分组。") }
            .sheet(isPresented: $adding, onDismiss: {
                captureText = ""
                guard let ids = importedSelection else { return }
                importedSelection = nil
                if ids.count == 1, let id = ids.first { selected = store.records.first { $0.id == id } }
                else {
                    query = CollectionQuery(scope: .library)
                    searching = false
                    selecting = true
                    selection = ids
                }
            }) {
                CaptureEntryView(store: store, initialText: captureText, initialFolder: query.folder,
                                 onViewSaved: { importedSelection = $0 })
            }
            .sheet(item: $selected) { RecordDetailView(store: store, record: $0, searchQuery: searching ? query.text : "") }
            .sheet(item: $exportSelection) { ReadableExportView(store: store, selectedIDs: $0.ids) }
            .alert("未完成操作", isPresented: Binding(get: { !settings && selected == nil && !adding && store.error != nil && !store.quotaExceeded },
                                             set: { if !$0 && !store.quotaExceeded { store.error = nil } })) {
                Button("知道了") { store.error = nil }
            } message: { Text(store.error ?? "") }
            .tint(green)
            .confirmationDialog("将所选 \(selection.count) 条移入回收站？", isPresented: $confirmingTrash) {
                Button("移入回收站", role: .destructive) { apply(.trash) }
            }
            .alert("永久删除 \(selection.count) 条收藏及其无引用附件？此操作不可撤销。", isPresented: $confirmingPermanent) {
                Button("永久删除", role: .destructive) { if store.permanentlyDelete(selection) { selection.removeAll() } }
                Button("取消", role: .cancel) {}
            }
            .task { await purchase.load() }
            .task(id: searchRequest) {
                let request = searchRequest
                let snapshot = store.records
                do {
                    let result = try await CollectionSearch.run(records: snapshot, query: request.query)
                    guard !Task.isCancelled, request == searchRequest else { return }
                    searchResults = result
                    completedRequest = request
                    selection.formIntersection(result.map(\.id))
                } catch is CancellationError {
                    // A newer request owns the loading/result state.
                } catch { store.error = error.localizedDescription }
            }
            .task(id: clipboardEligible) {
                if clipboardEligible { await clipboardHint.refresh() }
                else { clipboardHint.invalidate() }
            }
            .onChange(of: searchFocused) { _, focused in
                if focused && !searching { searchEntryQuery = query; searching = true }
            }
            .onChange(of: scenePhase) { _, value in
                if value == .active { store.reload(); store.resumeExtraction(); Task { await purchase.refresh() } }
            }
    }

    private func apply(_ action: CollectionRepository.BatchAction) {
        if store.batch(selection, action: action) { selection.removeAll() }
    }
}

private enum CollectionInputField: Hashable { case title, body, note, folder }

private struct CaptureEntryView: View {
    @ObservedObject var store: CollectionStore
    let onViewSaved: (Set<UUID>) -> Void
    let initialText: String
    let initialFolder: String?
    @Environment(\.dismiss) private var dismiss
    private enum Route { case link, text, photos, files }
    @State private var route: Route?
    @State private var choosingPhotos = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var files: [URL] = []
    @State private var choosingFiles = false
    @State private var failure: String?

    init(store: CollectionStore, initialText: String = "", initialFolder: String? = nil,
         onViewSaved: @escaping (Set<UUID>) -> Void) {
        self.store = store
        self.initialText = initialText
        self.initialFolder = initialFolder
        self.onViewSaved = onViewSaved
        _route = State(initialValue: initialText.isEmpty ? nil : .link)
    }

    var body: some View {
        Group {
            switch route {
            case .link: CaptureTextView(store: store, initialKind: .link, initialText: initialText, initialFolder: initialFolder)
            case .text: CaptureTextView(store: store, initialKind: .text, initialFolder: initialFolder)
            case .photos: AttachmentImportView(store: store, initialPhotos: photos, onViewSaved: onViewSaved)
            case .files: AttachmentImportView(store: store, initialFiles: files, onViewSaved: onViewSaved)
            case nil:
                NavigationStack {
                    List {
                        Section("编辑后保存") {
                            Button { route = .link } label: { Label("保存链接", systemImage: "link") }
                                .accessibilityIdentifier("capture.link")
                            Button { route = .text } label: { Label("写下文字", systemImage: "text.alignleft") }
                                .accessibilityIdentifier("capture.text")
                        }
                        Section {
                            Button { choosingPhotos = true } label: {
                                Label("选择照片", systemImage: "photo")
                            }
                            Button { choosingFiles = true } label: { Label("导入文件 / PDF", systemImage: "doc") }
                        } header: { Text("选完即导入") } footer: {
                            Text("照片和文件会在选择后直接保存到资料库，无需再次点击保存。")
                        }
                        if let failure { Text(verbatim: failure) }
                    }.navigationTitle("添加内容").toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if !urls.isEmpty { files = urls; route = .files }
            case .failure(let error): failure = error.localizedDescription
            }
        }
        // Keep the presenting modifier alive as the content switches to results.
        // Removing an active PhotosPicker can dismiss its enclosing sheet too.
        .photosPicker(isPresented: $choosingPhotos, selection: $photos, maxSelectionCount: 20, matching: .images)
        .onChange(of: photos) { _, items in if !choosingPhotos && !items.isEmpty { route = .photos } }
        .onChange(of: choosingPhotos) { _, presented in if !presented && !photos.isEmpty { route = .photos } }
    }
}

private struct CaptureTextView: View {
    @ObservedObject var store: CollectionStore
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: CollectionInputField?
    @State private var bodyFocused = false
    @State private var kind: ContentKind = .link
    init(store: CollectionStore, initialKind: ContentKind = .link, initialText: String = "", initialFolder: String? = nil) {
        self.store = store
        _kind = State(initialValue: initialKind)
        _text = State(initialValue: initialText)
        _folder = State(initialValue: initialFolder ?? "")
    }
    @State private var text = ""
    @State private var title = ""
    @State private var folder = ""
    @State private var pendingPaste: String?
    @State private var confirmingReplace = false
    @State private var chosenURL = ""
    @State private var allowDuplicate = false
    @State private var existingRecord: CollectionRecord?
    @State private var duplicateRecordID: UUID?
    @State private var confirmingDiscard = false
    private var busy: Bool { store.importing }
    private var urls: [URL] { LinkParser.urls(in: text) }
    private var hasDraft: Bool { !text.isEmpty || !title.isEmpty }
    private var previewURL: URL? { try? LinkParser.selectedURL(in: text, selection: chosenURL) }
    private var suggestedTitle: String? {
        guard kind == .link, let previewURL else { return nil }
        return LinkShareText.suggestedTitle(in: text, selectedURL: previewURL)
    }
    private var captureTitleResolution: (value: String, edited: Bool) {
        CaptureTitle.resolve(explicit: title, body: suggestedTitle ?? text)
    }
    private var canSave: Bool {
        !busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind != .link || (!urls.isEmpty && (urls.count == 1 || urls.contains(where: { $0.absoluteString == chosenURL }))))
    }

    private var captureFolderSection: some View {
    Section("收藏夹") {
        TextField("未分组（可填写收藏夹）", text: $folder)
            .focused($focusedField, equals: .folder).accessibilityIdentifier("capture.folder")
        if !store.folders.isEmpty {
            Menu("选择已有收藏夹") {
                Button("未分组") { folder = "" }
                ForEach(store.folders, id: \.self) { name in Button(name) { folder = name } }
            }
        }
    }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                Picker("内容类型", selection: $kind) { Text("链接").tag(ContentKind.link); Text("文字").tag(ContentKind.text) }.pickerStyle(.segmented)
                TextField("标题（选填）", text: $title).focused($focusedField, equals: .title)
                if kind == .link, let url = previewURL {
                    Section("保存预览") {
                        Text(captureTitleResolution.value)
                            .font(.headline).accessibilityIdentifier("capture.previewTitle")
                        LabeledContent("来源", value: LinkSource.displayName(for: url.host ?? ""))
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if kind == .link && previewURL != nil { captureFolderSection }
                if kind == .link {
                    Section {
                        ClipboardCaptureButton { pasted in
                            if hasDraft { pendingPaste = pasted; confirmingReplace = true }
                            else { text = pasted }
                        }
                    } footer: { Text("点击系统粘贴按钮后才读取剪贴板；保存前可以检查和修改。") }
                }
                Section(kind == .link ? String(localized: "粘贴链接或分享文字") : String(localized: "写下要保存的文字")) {
                    CollectionTextEditor(text: $text, isFocused: $bodyFocused, label: String(localized: "收藏内容")).frame(height: 160)
                        .id(CollectionInputField.body)
                }
                if kind == .link && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && urls.isEmpty {
                    Text("未找到有效的 HTTP 或 HTTPS 链接；如果要保存纯文字，请切换到文字。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if kind == .link && urls.count > 1 {
                    Picker("选择要保存的链接", selection: $chosenURL) {
                        Text("请选择").tag("")
                        ForEach(urls, id: \.absoluteString) { Text($0.absoluteString).tag($0.absoluteString) }
                    }
                }
                if kind != .link || previewURL == nil { captureFolderSection }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                QuotaUpgradeView(store: store)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("新收藏").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { bodyFocused = false; focusedField = nil }.accessibilityIdentifier("keyboard.dismiss")
                }
                ToolbarItem(placement: .cancellationAction) { Button("取消") {
                    bodyFocused = false; focusedField = nil
                    if hasDraft { confirmingDiscard = true } else { dismiss() }
                }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(!canSave) }
            }
            .onChange(of: bodyFocused) { _, focused in
                if focused { scroll.scrollTo(CollectionInputField.body, anchor: .bottom) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if bodyFocused { scroll.scrollTo(CollectionInputField.body, anchor: .bottom) }
            }
            }
        }.interactiveDismissDisabled(busy || hasDraft)
            .confirmationDialog("替换当前分享内容？", isPresented: $confirmingReplace, titleVisibility: .visible) {
                Button("替换内容", role: .destructive) {
                    if let pendingPaste { text = pendingPaste; title = ""; chosenURL = "" }
                    pendingPaste = nil
                }
                Button("保留当前内容", role: .cancel) { pendingPaste = nil }
            } message: { Text("当前未保存的正文和标题将被替换，收藏夹保持不变。") }
            .confirmationDialog("有未保存的内容", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("保存并继续") { save() }.disabled(!canSave).accessibilityIdentifier("draft.save")
                Button("放弃修改并继续", role: .destructive) { dismiss() }.accessibilityIdentifier("draft.discard")
                // Popover confirmation dialogs omit cancel-role buttons. Keep this choice explicit on every size class.
                Button("继续编辑") { confirmingDiscard = false }.accessibilityIdentifier("draft.continue")
            } message: {
                Text("退出前请选择保存或放弃；继续编辑会保留当前输入。")
            }
            .confirmationDialog("这个链接已经收下过了", isPresented: Binding(get: { store.duplicateID != nil }, set: { if !$0 { store.duplicateID = nil } }), titleVisibility: .visible) {
                Button("查看已有收藏") {
                    existingRecord = store.records.first { $0.id == duplicateRecordID }
                    store.duplicateID = nil
                }
                Button("仍然保存一条") { allowDuplicate = true; store.duplicateID = nil; save(); allowDuplicate = false }
                Button("取消", role: .cancel) { store.duplicateID = nil }
            }
            .sheet(item: $existingRecord) { RecordDetailView(store: store, record: $0) }
            .onChange(of: store.duplicateID) { _, value in if let value { duplicateRecordID = value } }
            .onChange(of: urls.map(\.absoluteString)) { _, current in
                if !current.contains(chosenURL) { chosenURL = "" }
            }
    }

    private func save() {
        let url: String?
        do { url = kind == .link ? try LinkParser.selectedURL(in: text, selection: chosenURL).absoluteString : nil }
        catch { store.error = error.localizedDescription; return }
        let resolvedTitle = captureTitleResolution
        var record = CollectionRecord(kind: kind, title: resolvedTitle.value)
        record.body = text
        record.originalURL = url
        record.source = url.flatMap(URL.init(string:))?.host ?? "随手记"
        let folderName = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard folderName.count <= 40 else { store.error = String(localized: "收藏夹名称最多 40 个字符。"); return }
        record.folder = folderName.isEmpty ? nil : folderName
        record.titleEdited = resolvedTitle.edited
        record.processingState = kind == .link ? .pending : .complete
        if store.save(record, allowDuplicate: allowDuplicate) { dismiss() }
    }
}

private struct RecordDetailView: View {
    @ObservedObject var store: CollectionStore
    @State var record: CollectionRecord
    let searchQuery: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @FocusState private var focusedField: CollectionInputField?
    @State private var noteFocused = false
    @State private var bodyFocused = false
    @State private var editingBody = false
    @ScaledMetric(relativeTo: .body) private var noteEditorHeight: CGFloat = 100
    @State private var draft: CollectionEditDraft
    @State private var deleting = false
    @State private var deletingPermanently = false
    @State private var confirmingReload = false
    @State private var originalOpenFailed = false
    @State private var confirmingChanges = false
    @State private var pendingAction: DetailAction = .close
    @State private var operationFailure: String?
    @State private var exportingReadable = false

    private enum DetailAction { case close, star, archive, trash, restore }
    private var hasChanges: Bool { draft.hasChanges(from: record) }

    init(store: CollectionStore, record: CollectionRecord, searchQuery: String = "") {
        self.store = store
        self.searchQuery = searchQuery
        _record = State(initialValue: record)
        _draft = State(initialValue: CollectionEditDraft(record: record))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
            Form {
                if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("搜索定位") {
                        RecordSearchMatchesView(record: store.records.first(where: { $0.id == record.id }) ?? record,
                                                query: searchQuery, attachments: store.attachments)
                    }
                }
                if let latest = store.records.first(where: { $0.id == record.id }), latest.version != record.version {
                    Section {
                        Text("后台内容已有更新，你的输入仍保留。保存时会合并未冲突的修改；同一字段发生冲突时会提示，不会覆盖。")
                        Button("载入最新内容") { confirmingReload = true }
                    }
                }
                TextField("标题", text: $draft.title).accessibilityLabel("标题").focused($focusedField, equals: .title)
                if let raw = record.originalURL, let url = URL(string: raw) {
                    Text(raw).textSelection(.enabled)
                    Button("复制链接") { UIPasteboard.general.string = raw }
                    Button("打开原文") { openURL(url) { success in if !success { originalOpenFailed = true } } }
                    ShareLink("分享链接", item: url)
                }
                if record.kind == .link {
                    Section("网页正文 · 离线阅读") {
                        let current = store.records.first(where: { $0.id == record.id }) ?? record
                        if let article = current.article {
                            Text("保存于 \(article.capturedAt.formatted())").font(.caption).foregroundStyle(.secondary)
                            Text(article.sourceURL).font(.caption).textSelection(.enabled)
                            Text(String(article.text.prefix(240)) + (article.text.count > 240 ? "…" : ""))
                                .textSelection(.enabled).accessibilityIdentifier("detail.article")
                            NavigationLink("阅读已保存正文") { OfflineArticleReader(article: article) }
                                .accessibilityIdentifier("detail.readArticle")
                            Button("复制网页正文") { UIPasteboard.general.string = article.text }
                        } else {
                            Text("尚未保存网页正文；当前链接不等于原文备份。")
                        }
                        Text("按需联网提取公开网页的纯文本，保存后可离线阅读和搜索。不含图片、样式或视频，不保证完整；登录、付费及部分动态网页不支持。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let failure = current.articleError {
                            Text(current.article == nil ? String(localized: "正文未保存：\(failure)") : String(localized: "更新未完成，之前保存的正文仍保留：\(failure)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if store.savingArticles.contains(record.id) { ProgressView("正在保存网页正文…") }
                        else if current.deletedAt == nil {
                            Button(current.article == nil ? String(localized: "保存网页正文") : String(localized: "更新网页正文")) {
                                Task {
                                    _ = await store.saveWebArticle(current)
                                    if !hasChanges, let latest = store.records.first(where: { $0.id == record.id }) {
                                        record = latest; draft = CollectionEditDraft(record: latest)
                                    }
                                }
                            }.disabled(hasChanges).accessibilityIdentifier("detail.saveArticle")
                            if hasChanges { Text("请先保存当前修改，再抓取网页正文。").font(.caption) }
                        }
                    }
                }
                if !record.body.isEmpty || draft.editsBody {
                    Section(draft.editsBody ? String(localized: "正文") : String(localized: "原始分享文字")) {
                        if editingBody {
                            CollectionTextEditor(text: $draft.body, isFocused: $bodyFocused, label: String(localized: "正文"))
                                .frame(height: 220)
                                .id(CollectionInputField.body)
                            Button("完成正文编辑") { bodyFocused = false; editingBody = false }
                            if draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("正文不能为空，请输入内容后保存。").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(draft.body).textSelection(.enabled).accessibilityIdentifier("detail.body")
                            if draft.editsBody {
                                Button("编辑正文") { editingBody = true; bodyFocused = true }
                                    .accessibilityIdentifier("detail.editBody")
                            }
                        }
                        Button("复制文字") { UIPasteboard.general.string = draft.body }
                            .frame(minHeight: 44)
                    }
                }
                Section("备注") {
                    CollectionTextEditor(text: $draft.note, isFocused: $noteFocused, label: String(localized: "备注"))
                        .frame(height: min(noteEditorHeight, 160))
                        .id(CollectionInputField.note)
                }
                Section("收藏夹") {
                    TextField("收藏夹名称（留空为未分组）", text: $draft.folder)
                        .accessibilityIdentifier("detail.folder")
                        .focused($focusedField, equals: .folder)
                    if !store.folders.isEmpty {
                        Menu("选择已有收藏夹") {
                            Button("未分组") { draft.folder = "" }
                            ForEach(store.folders, id: \.self) { name in Button(name) { draft.folder = name } }
                        }
                    }
                    Text("输入新名称即可在保存时分组，最多 40 个字符；空收藏夹不保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("来源", value: record.source.isEmpty ? String(localized: "未提供") : record.source)
                Text(record.createdAt.formatted()).font(.caption)
                ForEach(record.attachments) { reference in
                    AttachmentDetailActions(store: store, reference: reference, isImage: record.kind == .image)
                }
                if let current = store.records.first(where: { $0.id == record.id }), !current.attachments.isEmpty || current.kind == .link {
                    Section(current.kind == .link ? String(localized: "链接信息") : String(localized: "可检索文本")) {
                        switch current.processingState {
                        case .pending: ProgressView("等待处理…")
                        case .processing: ProgressView(current.kind == .link ? String(localized: "正在补全链接信息…") : String(localized: "正在提取文本…"))
                        case .complete: Text(current.kind == .link ? String(localized: "链接信息已补全。") : (current.extractedText.isEmpty ? String(localized: "未识别到文字，仍可通过标题和备注查找。") : current.extractedText)).textSelection(.enabled)
                        case .unsupported: Text("此格式支持保存与导出，暂不提取文本。")
                        case .failed:
                            Text(current.processingError ?? String(localized: "文本提取失败"))
                            if store.requestedExtractions.contains(current.id) {
                                ProgressView("等待处理…")
                            } else {
                                Button(current.kind == .link ? String(localized: "重试补全") : String(localized: "重试提取")) { store.extract(current) }
                            }
                        }
                    }
                }
                if hasChanges { Text("有未保存的修改，关闭前可选择保存或放弃。").font(.caption).foregroundStyle(.secondary) }
                Button("导出此条资料") { exportingReadable = true }
                    .disabled(hasChanges).accessibilityIdentifier("detail.exportReadable")
                if hasChanges { Text("通用导出使用已保存内容，请先保存修改。").font(.caption).foregroundStyle(.secondary) }
                Button(record.starred ? String(localized: "取消星标") : String(localized: "星标")) { request(.star) }
                    .accessibilityIdentifier("detail.star")
                if record.deletedAt == nil {
                    Button(record.archivedAt == nil ? String(localized: "归档") : String(localized: "取消归档")) { request(.archive) }
                    Button("移入回收站", role: .destructive) { deleting = true }
                } else {
                    Button("恢复收藏") { request(.restore) }
                    Button("永久删除", role: .destructive) { deletingPermanently = true }
                }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                QuotaUpgradeView(store: store)
            }.scrollDismissesKeyboard(.interactively).navigationTitle("收藏详情").toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { endEditing() }.accessibilityIdentifier("keyboard.dismiss")
                }
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { request(.close) } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { perform(.close, saveEdits: true) }.disabled(!draft.isValid) }
            }
            .onChange(of: noteFocused) { _, focused in
                if focused { scroll.scrollTo(CollectionInputField.note, anchor: .bottom) }
            }
            .onChange(of: bodyFocused) { _, focused in
                if focused { scroll.scrollTo(CollectionInputField.body, anchor: .bottom) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                if noteFocused { scroll.scrollTo(CollectionInputField.note, anchor: .bottom) }
                if bodyFocused { scroll.scrollTo(CollectionInputField.body, anchor: .bottom) }
            }
            }
                .alert("未完成操作", isPresented: $originalOpenFailed) {
                    if let raw = record.originalURL {
                        Button("复制链接") { UIPasteboard.general.string = raw }
                    }
                    Button("知道了", role: .cancel) {}
                } message: {
                    Text("无法打开原文，请复制链接后重试。")
                }
                .alert("载入最新内容将放弃本次未保存的修改，是否继续？", isPresented: $confirmingReload) {
                    Button("放弃本次编辑并载入", role: .destructive) {
                        store.reload()
                        if let latest = store.records.first(where: { $0.id == record.id }) {
                            record = latest
                            draft = CollectionEditDraft(record: latest)
                            editingBody = false
                            endEditing()
                            store.error = nil
                        } else { store.error = String(localized: "这条收藏已不存在，请关闭详情后刷新。") }
                    }
                    Button("取消", role: .cancel) {}
                }
                .confirmationDialog("移入回收站？", isPresented: $deleting) { Button("移入回收站", role: .destructive) { request(.trash) } }
                .alert("永久删除这条收藏？", isPresented: $deletingPermanently) {
                    Button("永久删除", role: .destructive) {
                        if store.permanentlyDelete([record.id]) { dismiss() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除这条收藏及不再被其他收藏引用的附件，未保存的修改也会丢弃。此操作不可撤销；其他收藏不受影响。")
                }
                .confirmationDialog("有未保存的内容", isPresented: $confirmingChanges, titleVisibility: .visible) {
                    Button("保存并继续") { perform(pendingAction, saveEdits: true) }
                        .disabled(!draft.isValid).accessibilityIdentifier("draft.save")
                    Button("放弃修改并继续", role: .destructive) { perform(pendingAction, saveEdits: false) }
                        .accessibilityIdentifier("draft.discard")
                Button("继续编辑") { confirmingChanges = false }.accessibilityIdentifier("draft.continue")
                } message: {
                    Text("先保存或放弃本次编辑，再继续刚才的操作；继续编辑会保留当前输入。")
                }
                .alert("操作未完成", isPresented: Binding(get: { operationFailure != nil }, set: { if !$0 { operationFailure = nil } })) {
                    Button("知道了", role: .cancel) {}
                } message: { Text(operationFailure ?? "") }
        }
        .interactiveDismissDisabled(hasChanges)
        .sheet(isPresented: $exportingReadable) { ReadableExportView(store: store, selectedIDs: [record.id]) }
    }

    private func endEditing() {
        noteFocused = false
        bodyFocused = false
        focusedField = nil
    }

    private func request(_ action: DetailAction) {
        endEditing()
        if hasChanges {
            pendingAction = action
            confirmingChanges = true
        } else { perform(action, saveEdits: false) }
    }

    private func perform(_ action: DetailAction, saveEdits: Bool) {
        endEditing()
        guard !saveEdits || draft.isValid else { return }
        let success: Bool
        switch action {
        case .close:
            success = !saveEdits || !hasChanges || store.updateDraft(base: record, draft: draft)
        case .star, .archive, .trash:
            success = store.updateDraft(base: record, draft: saveEdits ? draft : CollectionEditDraft(record: record)) { updated in
                switch action {
                case .star: updated.starred.toggle()
                case .archive: updated.archivedAt = updated.archivedAt == nil ? Date() : nil
                case .trash: updated.deletedAt = Date()
                default: break
                }
            }
        case .restore:
            if saveEdits && hasChanges {
                guard store.updateDraft(base: record, draft: draft) else {
                    operationFailure = store.error
                    return
                }
                if let latest = store.records.first(where: { $0.id == record.id }) {
                    record = latest
                    draft = CollectionEditDraft(record: latest)
                }
            }
            success = store.restore(record)
        }
        if success { dismiss() }
        else { operationFailure = store.error ?? String(localized: "请重试，当前输入会保留。") }
    }
}

nonisolated private struct AttachmentExport: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
            .suggestedFileName { $0.url.lastPathComponent }
    }
}

private struct AttachmentDetailActions: View {
    @ObservedObject var store: CollectionStore
    let reference: AttachmentReference
    let isImage: Bool
    @State private var exported: URL?
    @State private var preview: URL?
    @State private var failure: String?
    @State private var attempt = 0
    @State private var exporting = false
    @State private var exportMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reference.originalName).font(.caption)
            Text("\(UTType(reference.contentType)?.localizedDescription ?? reference.contentType) · \(ByteCountFormatter.string(fromByteCount: reference.byteCount, countStyle: .file))")
                .font(.caption).foregroundStyle(.secondary)
            if let exported {
                if isImage { AttachmentThumbnail(url: exported, maximumPixelSize: 1400).frame(maxHeight: 400).accessibilityLabel(reference.originalName) }
                Button("预览附件") { preview = exported }.frame(minHeight: 44)
                Button("导出附件") { exportMessage = nil; exporting = true }.frame(minHeight: 44)
                ShareLink("分享附件", item: exported).frame(minHeight: 44)
                if let exportMessage { Text(exportMessage).font(.caption).textSelection(.enabled) }
            } else if let failure {
                Text("附件暂时无法打开：\(failure)").foregroundStyle(.red).textSelection(.enabled)
                Text("收藏记录仍保留。请重试，或从完整备份恢复缺失附件。不会自动删除这条收藏。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重试准备附件") { attempt += 1 }.frame(minHeight: 44)
            } else { ProgressView("正在准备附件…") }
        }
        .buttonStyle(.borderless)
        .quickLookPreview($preview)
        .fileExporter(isPresented: $exporting, item: exported.map { AttachmentExport(url: $0) },
                      contentTypes: [.data], defaultFilename: reference.originalName) { result in
            switch result {
            case .success: exportMessage = String(localized: "附件已导出。")
            case .failure(let error): exportMessage = String(localized: "导出未完成：\(error.localizedDescription)")
            }
        } onCancellation: { exportMessage = String(localized: "已取消导出，原附件仍保留。") }
        .task(id: attempt) {
            failure = nil
            do { exported = try await store.previewURL(for: reference) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
