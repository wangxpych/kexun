#if DEBUG
import SwiftUI

private enum Theme {
    static let green = Color(red: 0.06, green: 0.40, blue: 0.35)
    static let paper = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.06, green: 0.08, blue: 0.07, alpha: 1) : UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1) })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

private struct CollectionItem: Identifiable {
    let id = UUID()
    var title: String
    var source: String
    var kind: String
    var subtitle: String
    var art: Int
    var starred = false
    var archived = false
    var note = ""
    static let examples: [CollectionItem] = [
        .init(title: "把周末，留给山野", source: "小红书", kind: "链接", subtitle: "杭州周边 · 一日徒步路线", art: 0, starred: true, note: "下次天气好的时候，和朋友一起去。记得带水和轻便的鞋。"),
        .init(title: "好的设计，让人少想一步", source: "微信公众号", kind: "链接", subtitle: "关于日常产品里的克制与留白", art: 1),
        .init(title: "家的一个角落", source: "相册", kind: "图片", subtitle: "客厅配色与材质参考", art: 2, starred: true),
        .init(title: "突然想到", source: "随手记", kind: "文字", subtitle: "收藏的意义，是在需要的时候恰好找到。", art: 3),
        .init(title: "京都散步指南.pdf", source: "文件", kind: "文件", subtitle: "PDF 文档 · 2.4 MB", art: 4)
    ]
}

struct ContentView: View {
    @State private var items = CollectionItem.examples
    @State private var tab = ProcessInfo.processInfo.arguments.contains("--library-preview") ? 2 : 0
    @State private var searching = false
    @State private var compact = false
    @State private var addKind = ""
    @State private var newestFirst = true
    @State private var sourceFilter = "全部来源"
    @State private var filter = "全部"
    @State private var query = ""
    @State private var selected: CollectionItem?
    @State private var adding = false
    @State private var settings = false
    @State private var draft = ""
    @State private var libraryFilter = "全部收藏"

    private var visible: [CollectionItem] {
        let matches = items.filter { item in
            (searching || tab != 0 || !item.archived) &&
            (searching || tab != 2 || libraryFilter != "星标" || item.starred) &&
            (searching || tab != 2 || libraryFilter != "已归档" || item.archived) &&
            (sourceFilter == "全部来源" || item.source == sourceFilter) &&
            (filter == "全部" || item.kind == filter) &&
            (query.isEmpty || [item.title, item.source, item.subtitle, item.note].joined().localizedCaseInsensitiveContains(query))
        }
        // The preview array is maintained in capture order, newest first.
        return newestFirst ? matches : Array(matches.reversed())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Button { query = ""; sourceFilter = "全部来源"; filter = "全部"; searching = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.green)
                            Text("搜索收藏").foregroundStyle(.secondary)
                            Spacer()
                        }.font(.system(size: 15)).padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                    if tab == 2 { libraryOptions }
                    filterBar
                    HStack {
                        Text(tab == 2 ? libraryFilter : "最近收下").font(.headline)
                        Spacer()
                        Menu {
                            Picker("保存顺序", selection: $newestFirst) {
                                Text("最近保存").tag(true)
                                Text("最早保存").tag(false)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(newestFirst ? "最近保存" : "最早保存")
                                Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.trailing, 8)
                        Button { compact.toggle() } label: { Image(systemName: compact ? "square.grid.2x2" : "list.bullet").frame(width: 36, height: 36) }.accessibilityLabel("切换布局")
                    }
                    if visible.isEmpty {
                        ContentUnavailableView("暂时没有找到", systemImage: "magnifyingglass", description: Text("试试其他关键词或内容类型"))
                    } else if compact {
                        LazyVStack(spacing: 10) { ForEach(visible) { item in Button { selected = item } label: { resultRow(item) }.buttonStyle(.plain) } }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)], spacing: 15) {
                            ForEach(visible) { item in
                                Button { selected = item } label: { card(item) }.buttonStyle(.plain)
                            }
                        }
                    }
                    Label("所存，皆可寻。", systemImage: "leaf").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.padding(.horizontal, 23).padding(.top, 10)
            }.background(Theme.paper)
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $adding, onDismiss: { addKind = "" }) { addSheet }
                .sheet(isPresented: $settings) { settingsSheet }
                .sheet(isPresented: $searching, onDismiss: { query = ""; filter = "全部"; sourceFilter = "全部来源" }) { searchSheet }
                .sheet(item: $selected) { item in detail(item) }
                .onAppear {
                    if ProcessInfo.processInfo.arguments.contains("--detail-preview") { selected = items.first }
                    if ProcessInfo.processInfo.arguments.contains("--search-preview") { query = "设计"; searching = true }
                    if ProcessInfo.processInfo.arguments.contains("--add-preview") { adding = true }
                }
        }.tint(Theme.green)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tab == 0 ? "收集箱" : "资料库").font(.system(size: 29, weight: .bold))
                    Text(tab == 0 ? "\(items.filter { !$0.archived }.count) 条收藏 · 随手收下，随时可寻" : "你的收藏，都在这里").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { settings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 18)).frame(width: 42, height: 42).background(Theme.card, in: Circle())
            }.accessibilityLabel("设置")
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("先收下，\n以后用得上。").font(.system(size: 34, weight: .semibold)).tracking(-1).lineSpacing(3)
            HStack(spacing: 5) {
                Text("散落的灵感，在这里相遇。")
                Spacer()
                Circle().fill(Theme.green).frame(width: 5, height: 5)
                Text("\(items.filter { !$0.archived }.count) 条收藏")
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 5)
        }.padding(.top, 4)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.green)
            TextField("找找你收下的东西", text: $query).font(.system(size: 15)).submitLabel(.search)
            if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
        }.padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 9) {
                ForEach(["全部", "链接", "图片", "文字", "文件"], id: \.self) { value in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { filter = value } } label: {
                        Text(value).font(.system(size: 13, weight: .medium)).padding(.horizontal, 17).padding(.vertical, 10)
                            .foregroundStyle(filter == value ? Color.white : Color.primary)
                            .background(filter == value ? Theme.green : Theme.card, in: Capsule())
                    }
                }
            }
        }.scrollIndicators(.hidden)
    }

    private var libraryOptions: some View {
        VStack(alignment: .leading, spacing: 15) {
            ForEach(["全部收藏", "星标", "已归档"], id: \.self) { value in
                Button { libraryFilter = value } label: {
                    HStack {
                        Image(systemName: value == "星标" ? "star" : value == "已归档" ? "archivebox" : "square.stack")
                        Text(value)
                        Spacer()
                        Text("\(items.filter { value == "星标" ? $0.starred : value == "已归档" ? $0.archived : true }.count)").foregroundStyle(.secondary)
                        if libraryFilter == value { Image(systemName: "checkmark") }
                    }.padding(16).background(Theme.card, in: RoundedRectangle(cornerRadius: 15))
                }
            }
        }
    }

    private func card(_ item: CollectionItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CollectionArtwork(style: item.art).frame(height: 125).clipped()
                .overlay(alignment: .topTrailing) {
                    if item.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.white).padding(6).background(.black.opacity(0.12), in: Circle()).padding(9).accessibilityLabel("已星标") }
                }
            VStack(alignment: .leading, spacing: 9) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(2).frame(height: 40, alignment: .topLeading)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(height: 16, alignment: .leading)
                HStack(spacing: 4) {
                    Circle().fill(item.source == "小红书" ? Color(red: 0.78, green: 0.32, blue: 0.28) : Theme.green.opacity(0.6)).frame(width: 5, height: 5)
                    Text(item.source)
                    Spacer(minLength: 0)
                    Text(item.kind)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(12)
        }.background(Theme.card, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach([0, 1, 2], id: \.self) { index in
                if index == 1 {
                    Button { adding = true } label: {
                        Image(systemName: "plus").font(.system(size: 23, weight: .medium)).foregroundStyle(.white).frame(width: 51, height: 51).background(Theme.green, in: RoundedRectangle(cornerRadius: 18))
                    }.accessibilityLabel("添加内容").frame(maxWidth: .infinity)
                } else {
                Button { tab = index; filter = "全部"; query = "" } label: {
                    VStack(spacing: 5) {
                        Image(systemName: ["tray.fill", "magnifyingglass", "square.stack.3d.up"][index]).font(.system(size: 20))
                        Text(["收集箱", "搜索", "资料库"][index]).font(.system(size: 10, weight: .medium))
                    }.frame(maxWidth: .infinity).foregroundStyle(tab == index ? Theme.green : Color.secondary)
                }
                }
            }
        }.padding(.horizontal, 25).padding(.top, 12).padding(.bottom, 7).background(Theme.paper).overlay(alignment: .top) { Rectangle().fill(.quaternary).frame(height: 0.5) }
    }

    private var addSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("你想收下什么？").font(.title2.bold())
                HStack(spacing: 10) {
                    ForEach(["链接", "文字", "照片", "文件"], id: \.self) { kind in
                        Button { withAnimation { addKind = kind } } label: {
                            VStack(spacing: 10) {
                                Image(systemName: kind == "链接" ? "link" : kind == "文字" ? "text.alignleft" : kind == "照片" ? "photo" : "doc").font(.title2)
                                Text(kind).font(.caption)
                            }.frame(maxWidth: .infinity).padding(.vertical, 18).foregroundStyle(addKind == kind ? Theme.green : .secondary).background(addKind == kind ? Theme.green.opacity(0.1) : Theme.paper, in: RoundedRectangle(cornerRadius: 15))
                        }
                    }
                }
                if addKind == "照片" || addKind == "文件" {
                    ContentUnavailableView(addKind == "照片" ? "从照片中选择" : "从文件中导入", systemImage: addKind == "照片" ? "photo.on.rectangle.angled" : "folder", description: Text("入口布局预览，实际导入将在功能开发时接入。"))
                } else if !addKind.isEmpty {
                Text(addKind == "链接" ? "粘贴链接或完整分享文案" : "写下值得留住的想法").font(.subheadline).foregroundStyle(.secondary)
                TextEditor(text: $draft).frame(height: 140).padding(10).overlay(RoundedRectangle(cornerRadius: 15).stroke(.quaternary))
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    items.insert(.init(title: String(text.prefix(35)), source: "手动添加", kind: text.hasPrefix("https://") ? "链接" : "文字", subtitle: text, art: 3), at: 0)
                    draft = ""; adding = false; tab = 0; filter = "全部"; query = ""
                } label: { Text("收进可寻").font(.headline).frame(maxWidth: .infinity).padding(17).background(Theme.green.opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1), in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white) }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("设计预览 · 新增内容仅在本次运行保留").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(25).navigationTitle("新收藏").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { adding = false } } }
        }.presentationDetents(addKind.isEmpty ? [.height(300)] : [.large]).presentationDragIndicator(.visible)
    }

    private var searchSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    searchBar
                    HStack {
                        Menu {
                            ForEach(["全部来源", "小红书", "微信公众号", "相册", "随手记", "文件"], id: \.self) { source in Button(source) { sourceFilter = source } }
                        } label: { Label(sourceFilter, systemImage: "line.3.horizontal.decrease").font(.subheadline) }
                        Spacer()
                        Text("包含归档").font(.caption).foregroundStyle(.secondary)
                    }
                    filterBar
                    Text(query.isEmpty ? "全部收藏" : "找到 \(visible.count) 条结果").font(.headline)
                    if visible.isEmpty { ContentUnavailableView.search(text: query) }
                    ForEach(visible) { item in
                        NavigationLink { detail(item) } label: { resultRow(item) }.buttonStyle(.plain)
                    }
                }.padding(23)
            }.background(Theme.paper).navigationTitle("搜索").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searching = false } } }
        }
    }

    private func resultRow(_ item: CollectionItem) -> some View {
        HStack(spacing: 14) {
            CollectionArtwork(style: item.art).frame(width: 65, height: 76).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 7) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(item.source) · \(item.kind)\(item.archived ? " · 已归档" : "")").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if item.starred { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 17))
    }

    private var settingsSheet: some View {
        NavigationStack {
            List {
                Section("设计预览") {
                    Text("当前使用示例内容，可试用搜索、添加、星标和归档。")
                    Text("尚未接入分享扩展、持久存储、OCR 或云同步。")
                }
                Section("视觉主题") { Label("暖纸白 · 墨绿色 · 跟随系统深浅色", systemImage: "paintpalette") }
            }.navigationTitle("关于这版可寻").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { settings = false } } }
        }
    }

    private func detail(_ original: CollectionItem) -> some View {
        let item = items.first(where: { $0.id == original.id }) ?? original
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    CollectionArtwork(style: item.art).frame(height: 250).clipped().clipShape(RoundedRectangle(cornerRadius: 24))
                    HStack { Text(item.source); Text("·"); Text("示例收藏") }.font(.caption).foregroundStyle(.secondary)
                    Text(item.title).font(.system(size: 29, weight: .semibold))
                    Text(item.subtitle).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        Label("留给自己的话", systemImage: "pencil.line").font(.subheadline.bold()).foregroundStyle(Theme.green)
                        Text(item.note.isEmpty ? "还没有备注，写下当时为什么想收藏。" : item.note).font(.system(size: 15)).lineSpacing(5)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                    HStack {
                        Button { if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].starred.toggle() } } label: { Label(item.starred ? "已星标" : "星标", systemImage: item.starred ? "star.fill" : "star") }
                        Spacer()
                        Button {
                            if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].archived.toggle() }
                            selected = nil
                        } label: { Label(item.archived ? "移回收集箱" : "归档", systemImage: "archivebox") }
                    }.padding(17).background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                    Label("示例内容，没有连接真实原文", systemImage: "arrow.up.right.square").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(17).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
                }.padding(24)
            }.background(Theme.paper).navigationTitle("收藏详情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selected = nil } } }
        }
    }
}

private struct CollectionArtwork: View {
    let style: Int
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if style == 0 {
                    Color(red: 0.76, green: 0.83, blue: 0.75)
                    Circle().fill(Color(red: 0.95, green: 0.91, blue: 0.72)).frame(width: 40, height: 40).offset(x: 45, y: -28)
                    mountain(size: geo.size, peak: 0.17).fill(Color(red: 0.43, green: 0.57, blue: 0.46))
                    mountain(size: geo.size, peak: 0.5).fill(Color(red: 0.19, green: 0.39, blue: 0.32)).offset(x: -40, y: 25)
                    VStack { Spacer(); HStack { Text("WEEKEND\nWANDER").font(.system(size: 11, weight: .medium, design: .serif)).tracking(2).foregroundStyle(.white.opacity(0.85)); Spacer() } }.padding(16)
                } else if style == 1 {
                    Color(red: 0.85, green: 0.87, blue: 0.93)
                    Circle().stroke(Color.white.opacity(0.7), lineWidth: 1).frame(width: 160, height: 160).offset(x: 60, y: -35)
                    HStack(alignment: .bottom) { Text("Less,\nbut better.").font(.system(size: 24, weight: .medium, design: .serif)).tracking(-1); Spacer(minLength: 0); Image(systemName: "asterisk").font(.system(size: 32, weight: .ultraLight)) }.foregroundStyle(Color(red: 0.24, green: 0.28, blue: 0.40)).padding(17)
                } else if style == 2 {
                    Color(red: 0.85, green: 0.79, blue: 0.67)
                    RoundedRectangle(cornerRadius: 50).fill(Color(red: 0.94, green: 0.91, blue: 0.84)).frame(width: 75, height: 120).offset(x: 30, y: -25)
                    Rectangle().fill(Color(red: 0.59, green: 0.65, blue: 0.52)).frame(width: 100, height: 45).offset(x: -20, y: 45)
                    Image(systemName: "leaf.fill").font(.system(size: 49)).rotationEffect(.degrees(-25)).foregroundStyle(Color(red: 0.27, green: 0.38, blue: 0.27)).offset(x: 45, y: 28)
                } else if style == 3 {
                    Color(red: 0.94, green: 0.89, blue: 0.76)
                    VStack(alignment: .leading, spacing: 8) { Image(systemName: "quote.opening").font(.system(size: 26)).opacity(0.4); Text("灵感不必整理好，\n先让它有个住处。").font(.system(size: 15, weight: .medium, design: .serif)).lineSpacing(5) }.foregroundStyle(Color(red: 0.43, green: 0.35, blue: 0.22)).padding(15)
                } else {
                    Color(red: 0.89, green: 0.87, blue: 0.83)
                    VStack(spacing: 10) { Image(systemName: "doc.richtext").font(.system(size: 35, weight: .light)); Text("A WALK IN KYOTO").font(.system(size: 10, weight: .medium)).tracking(2) }.foregroundStyle(Color(red: 0.40, green: 0.37, blue: 0.32))
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
        }.accessibilityHidden(true)
    }

    private func mountain(size: CGSize, peak: CGFloat) -> Path {
        Path { p in
            p.move(to: CGPoint(x: -50, y: size.height))
            p.addLine(to: CGPoint(x: size.width * 0.4, y: size.height * peak))
            p.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.58))
            p.addLine(to: CGPoint(x: size.width + 60, y: size.height * 0.2))
            p.addLine(to: CGPoint(x: size.width + 60, y: size.height + 70))
            p.closeSubpath()
        }
    }
}

#Preview { ContentView() }
#endif
