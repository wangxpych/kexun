import UIKit
import UniformTypeIdentifiers

// BEGIN SHARE_BATCH_LOGIC
/// A deliberate decision about one input, not a provider failure or batch stop.
nonisolated enum ShareItemDecision: Error { case skipped }
nonisolated enum ShareAttemptAction { case continueBatch, stopBatch }

/// Session-local outcomes: an explicit skip is resolved, but is never a save.
/// Keep this value type UI-independent so the actual retry logic can be checked
/// without loading the extension or touching a real App Group.
nonisolated struct ShareBatchProgress {
    let total: Int
    private(set) var saved = Set<Int>()
    private(set) var skipped = Set<Int>()
    private(set) var failures: [Int: String] = [:]
    var completed: Set<Int> { saved.union(skipped) }
    var pendingCount: Int { max(0, total - completed.count - failures.count) }
    var remaining: [Int] { (0..<total).filter { !completed.contains($0) } }

    mutating func beginAttempt(_ index: Int) { failures[index] = nil }
    mutating func recordSaved(_ index: Int) {
        guard (0..<total).contains(index), !completed.contains(index) else { return }
        failures[index] = nil
        saved.insert(index)
    }
    mutating func recordSkipped(_ index: Int) {
        guard (0..<total).contains(index), !completed.contains(index) else { return }
        failures[index] = nil
        skipped.insert(index)
    }
    mutating func recordFailure(_ index: Int, message: String) {
        guard (0..<total).contains(index), !completed.contains(index) else { return }
        failures[index] = message
    }

    mutating func resolveAttemptError(_ error: Error, at index: Int) -> ShareAttemptAction {
        switch error {
        case is CancellationError:
            return .stopBatch
        case ShareItemDecision.skipped:
            recordSkipped(index)
        default:
            recordFailure(index, message: error.localizedDescription)
        }
        return .continueBatch
    }
}

nonisolated enum ShareFolderSelection {
    static func available(in records: [CollectionRecord]) -> [String] {
        Array(Set(records.compactMap(\.folder).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
    }

    static func validate(_ selected: String?, in records: [CollectionRecord]) throws {
        guard let selected else { return }
        guard available(in: records).contains(selected) else {
            throw CollectionError.invalid(String(localized: "所选收藏夹已不存在或已改名。请重新选择收藏夹，或选择未分组后重试。"))
        }
    }
}
// END SHARE_BATCH_LOGIC

/// Full-size accessible text with a scrollable layout, unlike long UIAlert actions.
private final class AccessibleLinkChoiceController: UIViewController {
    var heading = ""
    var detail = ""
    var bodyText: String?
    var options: [(String, () -> Void)] = []
    var contentIdentifier = "share.linkChoices"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let scroll = UIScrollView()
        scroll.accessibilityIdentifier = contentIdentifier
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        for content in [heading, detail] {
            let label = UILabel()
            label.text = content
            label.font = .preferredFont(forTextStyle: content == heading ? .headline : .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            stack.addArrangedSubview(label)
        }
        for (index, option) in options.enumerated() {
            let (title, callback) = option
            let control = UIButton(type: .system)
            control.accessibilityIdentifier = "\(contentIdentifier).option.\(index)"
            control.isAccessibilityElement = true
            control.accessibilityLabel = title
            control.accessibilityTraits = .button
            control.backgroundColor = .secondarySystemBackground
            control.layer.cornerRadius = 12
            let label = UILabel()
            label.text = title
            label.textColor = .link
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            control.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: control.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -12),
                control.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
            ])
            control.addAction(UIAction { [weak self] _ in
                self?.view.isUserInteractionEnabled = false
                // Release closures which reference the presented controller before resuming.
                self?.options.removeAll()
                callback()
            }, for: .touchUpInside)
            stack.addArrangedSubview(control)
        }
        // The controls own their callbacks until dismissal; avoid a controller/options cycle.
        options.removeAll()
        if let bodyText {
            let label = UILabel()
            label.text = bodyText
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            label.accessibilityIdentifier = "share.existingContent"
            stack.addArrangedSubview(label)
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }
}

final class ShareViewController: UIViewController {
    private static let accent = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.43, green: 0.79, blue: 0.67, alpha: 1) : UIColor(red: 0.06, green: 0.40, blue: 0.35, alpha: 1) }
    private static let page = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.06, green: 0.08, blue: 0.07, alpha: 1) : UIColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1) }
    private let status = UILabel()
    private let stateIcon = UIImageView()
    private let header = UIStackView()
    private let actions = UIStackView()
    private let progress = UIProgressView(progressViewStyle: .default)
    private var attempted = false
    private let saveButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let folderButton = UIButton(type: .system)
    private let folderHint = UILabel()
    private var selectedFolder: String?
    private var loadingFolders = false
    private var providers: [NSItemProvider] = []
    private var batch = ShareBatchProgress(total: 0)
    private var saving = false
    private var saveTask: Task<Void, Never>?
    private var contexts: [String] = []
    private var savedWarnings: [Int: String] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.page
        view.tintColor = Self.accent
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let inputs = ShareInput.collect(from: items)
        providers = inputs.map(\.provider)
        contexts = inputs.map(\.context)
        batch = ShareBatchProgress(total: providers.count)
        let title = UILabel()
        title.text = String(localized: "收下到可寻")
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        status.numberOfLines = 0
        status.accessibilityIdentifier = "share.status"
        status.font = .preferredFont(forTextStyle: .body)
        status.adjustsFontForContentSizeCategory = true
        status.textColor = .secondaryLabel
        status.text = String(localized: "共 \(providers.count) 项。保存本地副本后即可关闭，文字识别将在可寻中继续。")
        saveButton.setTitle(String(localized: "保存"), for: .normal)
        saveButton.accessibilityIdentifier = "share.save"
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        closeButton.setTitle(String(localized: "取消"), for: .normal)
        closeButton.accessibilityIdentifier = "share.close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        for button in [saveButton, closeButton] {
            button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
        }
        folderButton.accessibilityIdentifier = "share.folder"
        folderButton.addTarget(self, action: #selector(chooseFolder), for: .touchUpInside)
        folderButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        folderButton.titleLabel?.adjustsFontForContentSizeCategory = true
        folderButton.titleLabel?.numberOfLines = 0
        folderButton.titleLabel?.lineBreakMode = .byWordWrapping
        folderButton.contentHorizontalAlignment = .leading
        folderHint.font = .preferredFont(forTextStyle: .caption1)
        folderHint.adjustsFontForContentSizeCategory = true
        folderHint.textColor = .secondaryLabel
        folderHint.numberOfLines = 0
        folderHint.text = String(localized: "可选；本次新收藏默认未分组，可在可寻中管理收藏夹。")
        let folderArea = UIStackView(arrangedSubviews: [folderButton, folderHint])
        folderArea.axis = .vertical
        folderArea.spacing = 4
        let accessibilityLayout = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        header.axis = accessibilityLayout ? .vertical : .horizontal
        header.alignment = accessibilityLayout ? .fill : .center
        header.spacing = 12
        header.addArrangedSubview(title)
        header.addArrangedSubview(closeButton)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stateIcon.contentMode = .scaleAspectFit
        stateIcon.tintColor = Self.accent
        stateIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .medium)
        stateIcon.isAccessibilityElement = false
        let iconTile = UIView()
        iconTile.backgroundColor = Self.accent.withAlphaComponent(0.10)
        iconTile.layer.cornerRadius = 18
        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(stateIcon)
        NSLayoutConstraint.activate([
            iconTile.widthAnchor.constraint(equalToConstant: 64),
            iconTile.heightAnchor.constraint(equalToConstant: 64),
            stateIcon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            stateIcon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor)
        ])
        let preview = UILabel()
        preview.font = .preferredFont(forTextStyle: .headline)
        preview.adjustsFontForContentSizeCategory = true
        preview.numberOfLines = 3
        preview.text = items.first?.attributedTitle?.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.text?.isEmpty != false {
            preview.text = providers.first?.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if preview.text?.isEmpty != false { preview.text = String(localized: "共 \(providers.count) 项") }
        let previewRow = UIStackView(arrangedSubviews: [iconTile, preview])
        previewRow.axis = accessibilityLayout ? .vertical : .horizontal
        previewRow.alignment = accessibilityLayout ? .leading : .center
        previewRow.spacing = 16
        progress.progressTintColor = Self.accent
        progress.trackTintColor = Self.accent.withAlphaComponent(0.10)
        let card = UIStackView(arrangedSubviews: [previewRow, status, progress])
        card.axis = .vertical
        card.spacing = 20
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 24, leading: 20, bottom: 24, trailing: 20)
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        actions.axis = .vertical
        actions.spacing = 12
        actions.addArrangedSubview(saveButton)
        let stack = UIStackView(arrangedSubviews: [header, card, folderArea, actions])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 30),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            folderButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            closeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        if providers.isEmpty { status.text = String(localized: "没有收到可保存的内容，请返回来源 App 重新分享。"); saveButton.isEnabled = false }
        refreshPresentation()
    }

    private func style(_ button: UIButton, primary: Bool) {
        let title = button.title(for: .normal)
        var configuration = primary ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        configuration.title = title
        configuration.baseBackgroundColor = Self.accent
        configuration.baseForegroundColor = primary ? UIColor { $0.userInterfaceStyle == .dark ? .black : .white } : Self.accent
        configuration.cornerStyle = .large
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 16, leading: 18, bottom: 16, trailing: 18)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        button.configuration = configuration
    }

    private func refreshPresentation() {
        let finished = attempted && !saving
        let allResolved = !providers.isEmpty && batch.completed.count == providers.count
        let destination = finished ? actions : header
        if closeButton.superview !== destination {
            (closeButton.superview as? UIStackView)?.removeArrangedSubview(closeButton)
            closeButton.removeFromSuperview()
            destination.addArrangedSubview(closeButton)
        }
        saveButton.isHidden = saving || (finished && allResolved)
        saveButton.isEnabled = !saving && !loadingFolders && !batch.remaining.isEmpty
        folderButton.isEnabled = !saving && !loadingFolders && !allResolved
        folderButton.setTitle(loadingFolders ? String(localized: "正在读取收藏夹…") : String(localized: "收藏夹：\(selectedFolder ?? String(localized: "未分组"))"), for: .normal)
        style(saveButton, primary: true)
        style(closeButton, primary: finished && allResolved)
        stateIcon.image = UIImage(systemName: finished ? (allResolved ? "checkmark" : "exclamationmark") : "bookmark")
        progress.isHidden = !saving
        progress.progress = providers.isEmpty ? 0 : Float(batch.completed.count) / Float(providers.count)
    }

    @objc private func chooseFolder() {
        guard !saving && !loadingFolders else { return }
        loadingFolders = true
        refreshPresentation()
        Task {
            defer { loadingFolders = false; refreshPresentation() }
            do {
                let folders = try await Task.detached(priority: .userInitiated) {
                    guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.groupID) else {
                        throw CollectionError.invalid(String(localized: "共享存储不可用，请检查 App Group 配置。"))
                    }
                    let session = try SharedStorage.session(group: group)
                    let repository = try CollectionRepository(url: session.root.appendingPathComponent("collections.sqlite"), storageLease: session)
                    return ShareFolderSelection.available(in: try repository.all())
                }.value
                guard view.window != nil else { return }
                showFolderChoices(folders)
            } catch {
                folderHint.text = String(localized: "收藏夹读取失败：\(error.localizedDescription) 请重试选择，当前选择保持不变。")
            }
        }
    }

    private func showFolderChoices(_ folders: [String], page: Int = 0) {
        let panel = AccessibleLinkChoiceController()
        panel.contentIdentifier = "share.folderChoices"
        panel.heading = String(localized: "选择收藏夹")
        panel.detail = folders.isEmpty ? String(localized: "暂无收藏夹。可先保存为未分组，再到可寻中创建或移动。") : String(localized: "仅影响本次尚未保存的项目，已保存和已跳过的项目不变。")
        @MainActor func option(_ title: String, action: @escaping @MainActor () -> Void) {
            panel.options.append((title, { [weak panel] in panel?.dismiss(animated: true) { action() } }))
        }
        option(String(localized: "取消选择")) {}
        option(String(localized: "未分组")) { [weak self] in self?.setFolder(nil) }
        let start = page * 20
        let end = min(start + 20, folders.count)
        if page > 0 { option(String(localized: "上一页收藏夹")) { [weak self] in self?.showFolderChoices(folders, page: page - 1) } }
        if end < folders.count { option(String(localized: "下一页收藏夹")) { [weak self] in self?.showFolderChoices(folders, page: page + 1) } }
        for folder in folders[start..<end] {
            option(folder) { [weak self] in self?.setFolder(folder) }
        }
        present(panel, animated: true)
    }

    private func setFolder(_ folder: String?) {
        selectedFolder = folder
        folderHint.text = String(localized: "仅影响本次尚未保存的项目；已保存的项目不变。")
        refreshPresentation()
    }

    private var resultSummary: String {
        String(localized: "共 \(batch.total) 项：已保存 \(batch.saved.count) 项，已跳过 \(batch.skipped.count) 项，失败 \(batch.failures.count) 项，待保存 \(batch.pendingCount) 项。")
    }

    @objc private func close() {
        if saving {
            saveTask?.cancel()
            closeButton.isEnabled = false
            status.text = String(localized: "正在停止…已保存的内容会保留。")
            return
        }
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func save() {
        guard !saving && !loadingFolders else { return }
        saving = true
        attempted = true
        saveButton.isEnabled = false
        closeButton.isEnabled = true
        closeButton.setTitle(String(localized: "停止保存"), for: .normal)
        isModalInPresentation = true
        status.text = String(localized: "正在保存…")
        refreshPresentation()
        saveTask = Task {
            defer {
                saving = false; saveTask = nil
                closeButton.isEnabled = true
                closeButton.setTitle(String(localized: "完成"), for: .normal)
                isModalInPresentation = false
                refreshPresentation()
            }
            do {
                guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.groupID) else {
                    throw CollectionError.invalid(String(localized: "共享存储不可用，请检查 App Group 配置。"))
                }
                let session = try SharedStorage.session(group: group)
                let root = session.root
                let repository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"), storageLease: session)
                let assets = try AttachmentStore(root: root, storageLease: session)
                let lease = try assets.beginImport()
                defer { withExtendedLifetime(lease) {} }
                let pro = UserDefaults(suiteName: SharedStorage.groupID)?.bool(forKey: "kexun.pro.verified") ?? false
                let records = try repository.all()
                try ShareFolderSelection.validate(selectedFolder, in: records)
                let remaining = max(0, 100 - records.filter { $0.deletedAt == nil }.count)
                guard pro || batch.remaining.count <= remaining else {
                    throw CollectionError.invalid(String(localized: "剩余免费额度 \(remaining) 条，本次未保存。请减少分享项目，或打开可寻升级 Pro 后重新分享。"))
                }
                var stopped = false
                for (index, provider) in providers.enumerated() where !batch.completed.contains(index) {
                    do {
                        try Task.checkCancellation()
                        batch.beginAttempt(index)
                        status.text = String(localized: "正在处理第 \(index + 1) / \(providers.count) 项。") + "\n" + resultSummary
                        var itemWarnings: [String] = []
                        var record = try await makeRecord(provider, sharedText: contexts[index], assets: assets) { itemWarnings.append($0) }
                        record.folder = selectedFolder
                        var skipped = false
                        do {
                            try Task.checkCancellation()
                            // Recheck after provider loading, which may have taken
                            // time while the main app renamed or removed a folder.
                            try ShareFolderSelection.validate(selectedFolder, in: repository.all())
                            do {
                                try repository.insert([record], isPro: UserDefaults(suiteName: SharedStorage.groupID)?.bool(forKey: "kexun.pro.verified") ?? false)
                            } catch CollectionError.duplicate(let id) {
                                let existing = try repository.all().first { $0.id == id }
                                let saveDuplicate = await confirmDuplicate(existing)
                                try Task.checkCancellation()
                                if saveDuplicate {
                                    try ShareFolderSelection.validate(selectedFolder, in: repository.all())
                                    try repository.insert([record], isPro: UserDefaults(suiteName: SharedStorage.groupID)?.bool(forKey: "kexun.pro.verified") ?? false, allowDuplicate: true)
                                } else {
                                    // A deliberate skip resolves this input and
                                    // must never enter a later failure retry.
                                    batch.recordSkipped(index)
                                    skipped = true
                                    try? assets.removeUnreferenced(record.attachments, keeping: repository.all())
                                }
                            }
                        } catch {
                            try? assets.removeUnreferenced(record.attachments, keeping: repository.all())
                            throw error
                        }
                        if !skipped {
                            batch.recordSaved(index)
                            if !itemWarnings.isEmpty { savedWarnings[index] = String(localized: "第 \(index + 1) 项：") + itemWarnings.joined(separator: "\n") }
                        }
                        progress.setProgress(Float(batch.completed.count) / Float(providers.count), animated: true)
                    } catch {
                        if batch.resolveAttemptError(error, at: index) == .stopBatch {
                            stopped = true
                            break
                        }
                        progress.setProgress(Float(batch.completed.count) / Float(providers.count), animated: true)
                    }
                }
                status.text = resultSummary
                if stopped { status.text? += "\n" + String(localized: "已停止；失败和待保存的项目可重试，已保存及已跳过的项目不会重复处理。") }
                if !batch.failures.isEmpty {
                    status.text? += "\n" + batch.failures.keys.sorted().map { String(localized: "第 \($0 + 1) 项：\(batch.failures[$0] ?? "")") }.joined(separator: "\n")
                }
                if !savedWarnings.isEmpty {
                    status.text? += "\n" + savedWarnings.keys.sorted().compactMap { savedWarnings[$0] }.joined(separator: "\n")
                }
                saveButton.isEnabled = !batch.remaining.isEmpty
                saveButton.setTitle(String(localized: "重试未保存项目"), for: .normal)
                closeButton.setTitle(String(localized: "完成"), for: .normal)
            } catch {
                status.text = resultSummary + "\n" + error.localizedDescription
                saveButton.isEnabled = true
            }
        }
    }

    private func makeRecord(_ provider: NSItemProvider, sharedText: String, assets: AttachmentStore, warning: (String) -> Void) async throws -> CollectionRecord {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL = try await load(provider, type: UTType.fileURL.identifier)
            guard url.isFileURL else { throw CollectionError.invalid(String(localized: "文件地址无效。")) }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let reference = try await Task.detached(priority: .userInitiated) { try assets.importFile(url, contentType: type.identifier) }.value
            var record = CollectionRecord(kind: type.conforms(to: .image) ? .image : .file, title: provider.suggestedName ?? reference.originalName)
            record.attachments = [reference]
            record.body = sharedText
            record.source = "系统分享"
            record.processingState = .pending
            return record
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) && !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL = try await load(provider, type: UTType.url.identifier)
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw CollectionError.invalid(String(localized: "链接格式不受支持。"))
            }
            var providedText = ""
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                do { providedText = try await load(provider, type: UTType.plainText.identifier) }
                catch is CancellationError { throw CancellationError() }
                catch { warning(String(localized: "链接可保存，但来源附带文字读取失败。请返回来源复制文字后另行保存。")) }
            }
            var body = ShareText.merge([sharedText, providedText])
            if !LinkParser.urls(in: body).contains(url) { body = ShareText.merge([body, url.absoluteString]) }
            let urls = LinkParser.urls(in: body)
            let chosen = urls.count > 1 ? try await chooseURL(urls) : url
            let suggestedTitle = chosen.flatMap { LinkShareText.suggestedTitle(in: body, selectedURL: $0) }
            var record = CollectionRecord(kind: chosen == nil ? .text : .link, title: provider.suggestedName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } ?? CaptureTitle.resolve(body: suggestedTitle ?? body).value)
            record.originalURL = chosen?.absoluteString
            record.body = body
            record.source = chosen?.host ?? "分享文字"
            record.processingState = chosen == nil ? .complete : .pending
            return record
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let providedText: String = try await load(provider, type: UTType.plainText.identifier)
            let text = ShareText.merge([sharedText, providedText])
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CollectionError.invalid(String(localized: "分享文字为空。")) }
            let urls = LinkParser.urls(in: text)
            let chosen = urls.count > 1 ? try await chooseURL(urls) : urls.first
            let suggestedTitle = chosen.flatMap { LinkShareText.suggestedTitle(in: text, selectedURL: $0) }
            var record = CollectionRecord(kind: chosen == nil ? .text : .link, title: CaptureTitle.resolve(body: suggestedTitle ?? text).value)
            record.body = text
            record.originalURL = chosen?.absoluteString
            record.source = chosen?.host ?? "分享文字"
            record.processingState = chosen == nil ? .complete : .pending
            return record
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .image) || type.conforms(to: .data)
        }) else { throw CollectionError.invalid(String(localized: "此内容类型暂不支持，请分享链接、文字、图片或文件。")) }
        let reference: AttachmentReference = try await BoundedCallback.wait(discard: { reference in
            // Only a newly copied, never committed attachment reaches this path.
            try? assets.removeUnreferenced([reference], keeping: [])
        }) { completion in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw CollectionError.invalid(String(localized: "来源未提供文件。")) }
                    // Provider temporary URLs are valid only during this callback.
                    let reference = try assets.importFile(url, contentType: identifier)
                    completion(.success(reference))
                } catch { completion(.failure(error)) }
            }
        }
        let kind: ContentKind = UTType(identifier)?.conforms(to: .image) == true ? .image : .file
        var record = CollectionRecord(kind: kind, title: provider.suggestedName ?? reference.originalName)
        record.attachments = [reference]
        record.body = sharedText
        record.source = "系统分享"
        record.processingState = .pending
        return record
    }

    private func load<Value: Sendable>(_ provider: NSItemProvider, type: String) async throws -> Value {
        try await ShareInput.load(provider, type: type)
    }

    private enum LinkChoice { case link(URL), text, previous, next, skip }

    private func chooseURL(_ urls: [URL]) async throws -> URL? {
        var page = 0
        let pageSize = 5
        while true {
            try Task.checkCancellation()
            let start = page * pageSize
            let end = min(start + pageSize, urls.count)
            let choice: LinkChoice = await withCheckedContinuation { continuation in
                if traitCollection.preferredContentSizeCategory.isAccessibilityCategory {
                    let panel = AccessibleLinkChoiceController()
                    panel.heading = String(localized: "选择要保存的链接")
                    panel.detail = String(localized: "共 \(urls.count) 个链接，第 \(start + 1)–\(end) 个。原始文字会完整保留。")
                    @MainActor func option(_ title: String, _ choice: LinkChoice) {
                        panel.options.append((title, { [weak panel] in
                            panel?.dismiss(animated: true) { continuation.resume(returning: choice) }
                        }))
                    }
                    // Navigation comes before potentially very long URLs; every row can scroll.
                    if start > 0 { option(String(localized: "上一页链接"), .previous) }
                    if end < urls.count { option(String(localized: "下一页链接"), .next) }
                    option(String(localized: "完整保存为文字"), .text)
                    option(String(localized: "跳过此项"), .skip)
                    for url in urls[start..<end] { option(url.absoluteString, .link(url)) }
                    panel.isModalInPresentation = true
                    present(panel, animated: true)
                    return
                }
                let alert = UIAlertController(title: String(localized: "选择要保存的链接"), message: String(localized: "共 \(urls.count) 个链接，当前显示第 \(start + 1)–\(end) 个。原始分享文字会完整保留；也可以将全部内容保存为文字。"), preferredStyle: .alert)
                @MainActor func action(_ title: String, _ choice: LinkChoice, style: UIAlertAction.Style = .default) {
                    alert.addAction(UIAlertAction(title: title, style: style) { [weak alert] _ in
                        // Wait for this alert to close before presenting another page.
                        alert?.dismiss(animated: true) { continuation.resume(returning: choice) }
                    })
                }
                for url in urls[start..<end] { action(url.absoluteString, .link(url)) }
                if start > 0 { action(String(localized: "上一页链接"), .previous) }
                if end < urls.count { action(String(localized: "下一页链接"), .next) }
                action(String(localized: "完整保存为文字"), .text)
                action(String(localized: "跳过此项"), .skip, style: .cancel)
                present(alert, animated: true)
            }
            try Task.checkCancellation()
            switch choice {
            case .link(let url): return url
            case .text: return nil
            case .previous: page -= 1
            case .next: page += 1
            case .skip: throw ShareItemDecision.skipped
            }
        }
    }

    private func confirmDuplicate(_ record: CollectionRecord?) async -> Bool {
        enum Choice { case save, skip, view }
        while true {
            let choice: Choice = await withCheckedContinuation { continuation in
                let alert = UIAlertController(title: String(localized: "这个链接已收下"), message: record.map { String(localized: "已有收藏：\($0.title)") } ?? String(localized: "已有相同链接。"), preferredStyle: .alert)
                @MainActor func action(_ title: String, _ choice: Choice, style: UIAlertAction.Style = .default) {
                    alert.addAction(UIAlertAction(title: title, style: style) { [weak alert] _ in
                        alert?.dismiss(animated: true) { continuation.resume(returning: choice) }
                    })
                }
                if record != nil { action(String(localized: "查看已有收藏"), .view) }
                action(String(localized: "仍然保存"), .save)
                action(String(localized: "跳过"), .skip, style: .cancel)
                present(alert, animated: true)
            }
            switch choice {
            case .save: return true
            case .skip: return false
            case .view:
                guard let record else { continue }
                await withCheckedContinuation { continuation in
                    let panel = AccessibleLinkChoiceController()
                    panel.heading = String(localized: "已有收藏")
                    panel.detail = record.title
                    panel.bodyText = [
                        String(localized: "原链接：\(record.originalURL ?? String(localized: "未提供"))"),
                        String(localized: "来源：\(record.source)"),
                        String(localized: "收藏夹：\(record.folder ?? String(localized: "未分组"))"),
                        String(localized: "保存时间：\(record.createdAt.formatted())"),
                        String(localized: "状态：\(record.starred ? String(localized: "已星标") : String(localized: "未星标")) · \(record.archivedAt == nil ? String(localized: "收集箱") : String(localized: "已归档"))"),
                        String(localized: "备注：\(record.note.isEmpty ? String(localized: "无") : record.note)"),
                        String(localized: "原始内容：\n\(record.body)"),
                        String(localized: "附件：\(record.attachments.isEmpty ? String(localized: "无") : record.attachments.map(\.originalName).joined(separator: "、"))")
                    ].joined(separator: "\n\n")
                    panel.options = [(String(localized: "返回重复提醒"), { [weak panel] in
                        panel?.dismiss(animated: true) { continuation.resume() }
                    })]
                    panel.isModalInPresentation = true
                    present(panel, animated: true)
                }
            }
        }
    }
}
