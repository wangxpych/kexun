import Foundation
import Combine
import UniformTypeIdentifiers
import ImageIO

nonisolated struct ImportSummary {
    var saved = 0
    var failures: [String] = []
    /// Session-only sources; successful imports never enter the retry queue.
    var unsavedURLs: [URL] = []
    /// Exact records committed by this batch, excluding unrelated concurrent saves.
    var savedIDs: [UUID] = []
    var message: String {
        String(localized: "已保存 \(saved) 项。")
            + (failures.isEmpty ? "" : String(localized: "\n未保存：\n") + failures.joined(separator: "\n"))
    }
}

@MainActor
final class CollectionStore: ObservableObject {
    @Published private(set) var records: [CollectionRecord] = []
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var loadError: String?
    @Published private(set) var processingPersistenceError: String?
    @Published var error: String? { didSet { if error == nil { quotaExceeded = false } } }
    @Published var quotaExceeded = false
    @Published var duplicateID: UUID?
    private(set) var repository: CollectionRepository?
    private(set) var attachments: AttachmentStore?
    @Published private(set) var importing = false
    @Published private(set) var recovering = false
    @Published var importReport: String?
    private var extracting = Set<UUID>()
    var isProcessingContent: Bool { !extracting.isEmpty || !savingArticles.isEmpty }
    @Published private(set) var requestedExtractions = Set<UUID>()
    @Published private(set) var savingArticles = Set<UUID>()
    var folders: [String] { Array(Set(records.compactMap(\.folder))).sorted() }
    private var previewCopies: [UUID: URL] = [:]
    private let openRoot: (() throws -> URL)?
    private let fetchMetadata: @Sendable (URL) async throws -> LinkMetadata
    private let fetchCover: @Sendable (URL) async throws -> Data
    private let fetchArticle: @Sendable (URL) async throws -> WebArticle
    #if DEBUG
    // Deterministic UI cancellation checkpoint. No hook or delay in Release.
    var beforeImportItem: ((Int) async throws -> Void)?
    // Runs after persisted processing state, before the real text extractor.
    var beforeTextExtraction: (() async throws -> Void)?
    #endif

    init(openRoot: (() throws -> URL)? = nil,
         fetchMetadata: @escaping @Sendable (URL) async throws -> LinkMetadata = { try await LinkMetadata.fetch($0) },
         fetchCover: @escaping @Sendable (URL) async throws -> Data = { try await PublicLinkRequest.fetch($0, maximumBytes: 3 * 1024 * 1024) },
         fetchArticle: @escaping @Sendable (URL) async throws -> WebArticle = { try await WebArticle.fetch($0) }) {
        self.openRoot = openRoot
        self.fetchMetadata = fetchMetadata
        self.fetchCover = fetchCover
        self.fetchArticle = fetchArticle
        open()
    }

    func previewURL(for reference: AttachmentReference) async throws -> URL {
        if let cached = previewCopies[reference.id], FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard let attachments else { throw CollectionError.database(String(localized: "附件存储未打开")) }
        let destination = try await Task.detached(priority: .userInitiated) {
            try attachments.withExclusiveAccess {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KexunPreview-\(UUID())", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                do {
                    let name = URL(fileURLWithPath: reference.originalName).lastPathComponent
                    let destination = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "附件" : name)
                    try FileManager.default.copyItem(at: attachments.url(for: reference), to: destination)
                    return destination
                } catch { try? FileManager.default.removeItem(at: folder); throw error }
            }
        }.value
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw CancellationError()
        }
        do {
            guard let repository, try repository.all().contains(where: { $0.attachments.contains(reference) }) else {
                throw CollectionError.invalid(String(localized: "附件所属收藏已删除或更改，请重新打开详情。"))
            }
        } catch {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            throw error
        }
        // Two detail tasks can overlap while copying; keep one cache owner and discard our duplicate.
        if let cached = previewCopies[reference.id], FileManager.default.fileExists(atPath: cached.path) {
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
            return cached
        }
        previewCopies[reference.id] = destination
        return destination
    }

    func open() {
        guard !recovering else { return }
        do {
            let session: StorageSession?
            let root: URL
            if let openRoot { session = nil; root = try openRoot() }
            else { let opened = try SharedStorage.sessionForMainApp(); session = opened; root = opened.root }
            let openedRepository = try CollectionRepository(url: root.appendingPathComponent("collections.sqlite"), storageLease: session)
            let openedAttachments = try AttachmentStore(root: root, storageLease: session)
            let openedRecords = try openedRepository.all()
            repository = openedRepository
            attachments = openedAttachments
            records = openedRecords
            revision &+= 1
            loadError = nil
            processingPersistenceError = nil
            error = nil
            resumeExtraction()
            Task {
                do {
                    _ = try await Task.detached(priority: .utility) {
                        try openedAttachments.reclaimOrphans(repository: openedRepository)
                    }.value
                } catch { self.error = String(localized: "附件整理未完成：\(error.localizedDescription) 现有收藏仍可使用。") }
            }
        } catch { loadError = error.localizedDescription; self.error = error.localizedDescription }
    }

    func resumeExtraction() {
        guard loadError == nil, processingPersistenceError == nil, !recovering else { return }
        requestedExtractions.formIntersection(Set(records.filter { $0.deletedAt == nil }.map(\.id)))
        for record in records where record.deletedAt == nil && (record.processingState == .pending || record.processingState == .processing || requestedExtractions.contains(record.id)) {
            guard extracting.count < 2 else { break }
            guard !extracting.contains(record.id) else { continue }
            requestedExtractions.remove(record.id)
            startExtraction(record)
        }
    }

    func extract(_ record: CollectionRecord) {
        guard !extracting.contains(record.id), !requestedExtractions.contains(record.id), record.deletedAt == nil else { return }
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.update(id: record.id) {
                if $0.deletedAt == nil { $0.processingState = .pending; $0.processingError = nil }
            }
            reload()
        } catch { self.error = error.localizedDescription; return }
        requestedExtractions.insert(record.id)
        resumeExtraction()
    }

    private func startExtraction(_ record: CollectionRecord) {
        guard !extracting.contains(record.id), extracting.count < 2,
              let attachments, let repository else { return }
        guard record.kind == .link || record.attachments.first != nil else { return }
        extracting.insert(record.id)
        Task {
            defer { extracting.remove(record.id); reload(); resumeExtraction() }
            do {
                guard let record = try repository.beginProcessing(id: record.id) else { return }
                reload()
                if record.kind == .link, let raw = record.originalURL, let url = URL(string: raw) {
                    let metadata = try await fetchMetadata(url)
                    guard let latest = try repository.all().first(where: { $0.id == record.id }), latest.deletedAt == nil else { return }
                    var coverLease: AttachmentImportLease?
                    defer { withExtendedLifetime(coverLease) {} }
                    var cover: AttachmentReference?
                    var coverError: String?
                    if let imageURL = metadata.imageURL, latest.attachments.isEmpty {
                        do {
                            // A title-only result must not fail because orphan cleanup temporarily holds the import gate.
                            coverLease = try attachments.beginImport()
                            let bytes = try await fetchCover(imageURL)
                            cover = try await Task.detached(priority: .utility) {
                                guard CGImageSourceCreateWithData(bytes as CFData, nil) != nil else { throw CollectionError.invalid(String(localized: "封面不是图片。")) }
                                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID()).jpg")
                                defer { try? FileManager.default.removeItem(at: temporary) }
                                try bytes.write(to: temporary, options: .atomic)
                                return try attachments.importFile(temporary, contentType: "public.image")
                            }.value
                        } catch {
                            coverError = String(localized: "封面补全失败，已保留链接与已获取的标题。可重试。\n") + error.localizedDescription
                        }
                    }
                    try attachments.withExclusiveAccess {
                        defer { if let cover { try? attachments.removeUnreferenced([cover], keeping: repository.all()) } }
                        try repository.update(id: record.id) {
                            if $0.deletedAt == nil {
                                if !$0.titleEdited, let title = metadata.title { $0.title = title }
                                if $0.attachments.isEmpty, let cover { $0.attachments = [cover] }
                            }
                            $0.processingState = coverError == nil ? .complete : .failed
                            $0.processingError = coverError
                        }
                    }
                    return
                }
                guard let attachment = record.attachments.first else { throw CollectionError.invalid(String(localized: "没有可处理内容。")) }
                #if DEBUG
                try await beforeTextExtraction?()
                #endif
                let value = try await Task.detached(priority: .utility) {
                    try TextExtraction.extract(url: attachments.url(for: attachment), kind: record.kind, contentType: attachment.contentType)
                }.value
                try repository.update(id: record.id) {
                    $0.extractedText = value ?? ""
                    $0.processingState = value == nil ? .unsupported : .complete
                }
            } catch {
                let processingError = error
                do {
                    try repository.update(id: record.id) { $0.processingState = .failed; $0.processingError = processingError.localizedDescription }
                } catch CollectionError.missing {
                    // A concurrent permanent deletion is terminal, not a storage failure.
                } catch {
                    // If even the failure state cannot be committed, reloading still sees
                    // pending/processing. Pause automatic retries until storage is reopened.
                    processingPersistenceError = String(localized: "无法保存处理状态：\(error.localizedDescription) 自动处理已暂停，原内容仍可查看和导出。")
                    self.error = processingPersistenceError
                }
            }
        }
    }

    func canImport(_ count: Int) -> Bool {
        quotaExceeded = false
        guard repository != nil, attachments != nil else { error = String(localized: "存储尚未打开。"); return false }
        reload()
        guard loadError == nil else { return false }
        let remaining = max(0, 100 - records.filter({ $0.deletedAt == nil }).count)
        guard PurchaseService.cachedIsPro || count <= remaining else {
            quotaExceeded = true
            error = String(localized: "本次选择 \(count) 项，剩余免费额度 \(remaining) 条。请减少选择后重试，或升级 Pro。")
            return false
        }
        return true
    }

    @discardableResult
    func importFiles(_ urls: [URL], imageOverride: Bool = false) async -> ImportSummary {
        guard !importing, let attachments, let repository else {
            return ImportSummary(failures: [String(localized: "另一项导入正在进行，或存储尚未打开。")], unsavedURLs: urls)
        }
        guard canImport(urls.count) else { return ImportSummary(failures: [error ?? String(localized: "无法导入所选内容。")], unsavedURLs: urls) }
        importing = true
        defer { importing = false; reload(); resumeExtraction() }
        var saved = 0
        var savedIDs: [UUID] = []
        var failures: [String] = []
        var unsavedURLs: [URL] = []
        for (index, url) in urls.enumerated() {
            do {
                try Task.checkCancellation()
                #if DEBUG
                try await beforeImportItem?(index)
                #endif
                let lease = try attachments.beginImport()
                defer { withExtendedLifetime(lease) {} }
                let reference = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let type = UTType(filenameExtension: url.pathExtension) ?? .data
                    return try attachments.importFile(url, contentType: type.identifier)
                }.value
                let type = UTType(reference.contentType)
                let kind: ContentKind = imageOverride || type?.conforms(to: .image) == true ? .image : .file
                var record = CollectionRecord(kind: kind, title: reference.originalName)
                record.source = kind == .image ? "图片" : "文件"
                record.attachments = [reference]
                record.processingState = .pending
                do {
                    try Task.checkCancellation()
                    try repository.insert([record], isPro: PurchaseService.cachedIsPro)
                }
                catch {
                    try? attachments.removeUnreferenced([reference], keeping: repository.all())
                    throw error
                }
                saved += 1
                savedIDs.append(record.id)
            } catch is CancellationError {
                unsavedURLs.append(contentsOf: urls[index...])
                failures.append(String(localized: "导入已取消，剩余 \(urls.count - index) 项未保存；已成功保存的内容保留。"))
                break
            } catch {
                unsavedURLs.append(url)
                if case CollectionError.limit = error { quotaExceeded = true }
                failures.append(String(localized: "\(url.lastPathComponent)：\(error.localizedDescription)"))
            }
        }
        let summary = ImportSummary(saved: saved, failures: failures, unsavedURLs: unsavedURLs, savedIDs: savedIDs)
        importReport = summary.message
        return summary
    }

    func reload() {
        guard !recovering else { return }
        if loadError != nil { open(); return }
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            records = try repository.all()
            revision &+= 1
            loadError = nil
        } catch { loadError = error.localizedDescription; self.error = error.localizedDescription }
    }

    func recoverFromBackup(_ url: URL) async -> String {
        guard loadError != nil else { return String(localized: "资料库已可正常读取，请使用普通备份恢复合并内容。") }
        guard !recovering, !importing, extracting.isEmpty, savingArticles.isEmpty else {
            return String(localized: "仍有导入或内容处理任务，请等待结束后重试故障恢复。")
        }
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedStorage.groupID) else {
            return String(localized: "共享存储未配置，无法恢复；请先检查 App Group 签名配置。")
        }
        recovering = true
        // Captured asynchronous users retain their own leases; publication will refuse while live.
        repository = nil
        attachments = nil
        do {
            let candidate = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let candidate = try RecoveryArchive.stage(url, group: group)
                try SharedStorage.publishRecovery(group: group, generation: candidate.generation)
                return candidate
            }.value
            recovering = false
            open()
            guard loadError == nil else { return String(localized: "备份资料库已切换，但重新读取失败，请重试打开。旧故障目录和恢复目录均保留。") }
            return String(localized: "故障恢复完成：已载入备份中的 \(candidate.itemCount) 条内容（含回收站）。旧故障资料库及附件原地保留，备份之后的内容不会自动出现在新资料库中。")
        } catch {
            recovering = false
            open()
            return String(localized: "故障恢复未完成：\(error.localizedDescription) 原资料目录保留，请勿卸载应用。")
        }
    }

    @discardableResult
    func save(_ record: CollectionRecord, allowDuplicate: Bool = false) -> Bool {
        quotaExceeded = false
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.insert([record], isPro: PurchaseService.cachedIsPro, allowDuplicate: allowDuplicate)
            error = nil
            reload()
            resumeExtraction()
            return true
        } catch CollectionError.duplicate(let id) { duplicateID = id; return false }
        catch CollectionError.limit(let remaining) {
            quotaExceeded = true; error = CollectionError.limit(remaining).localizedDescription; reload(); return false
        }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func update(_ record: CollectionRecord, change: (inout CollectionRecord) -> Void) -> Bool {
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.update(id: record.id, expectedVersion: record.version, change: change)
            error = nil
            reload()
            return true
        } catch { self.error = error.localizedDescription; reload(); return false }
    }

    @discardableResult
    func updateDraft(base: CollectionRecord, draft: CollectionEditDraft, change: (inout CollectionRecord) -> Void = { _ in }) -> Bool {
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.update(id: base.id) { latest in
                try draft.merge(from: base, into: &latest)
                change(&latest)
            }
            error = nil
            reload()
            return true
        } catch { self.error = error.localizedDescription; reload(); return false }
    }

    @discardableResult
    func renameFolder(_ old: String, to new: String?) -> Bool {
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            let trimmed = new?.trimmingCharacters(in: .whitespacesAndNewlines)
            try repository.renameFolder(old, to: trimmed?.isEmpty == true ? nil : trimmed)
            error = nil
            reload()
            return true
        } catch { self.error = error.localizedDescription; reload(); return false }
    }

    @discardableResult
    func saveWebArticle(_ record: CollectionRecord) async -> Bool {
        guard record.kind == .link, record.deletedAt == nil, !savingArticles.contains(record.id),
              let raw = record.originalURL, let url = URL(string: raw), let repository else { return false }
        savingArticles.insert(record.id)
        defer { savingArticles.remove(record.id); reload() }
        do {
            let article = try await fetchArticle(url)
            try Task.checkCancellation()
            guard let latest = try repository.all().first(where: { $0.id == record.id }),
                  latest.deletedAt == nil, latest.originalURL == raw else { throw CollectionError.conflict }
            try repository.update(id: latest.id, expectedVersion: latest.version) {
                $0.article = SavedWebArticle(text: article.text, sourceURL: article.finalURL.absoluteString, capturedAt: article.capturedAt)
                $0.articleError = nil
            }
            error = nil
            return true
        } catch {
            let reason = error.localizedDescription
            // A failed refresh retains the previously saved offline copy, never replaces it with an error page.
            do {
                if let latest = try repository.all().first(where: { $0.id == record.id }), latest.deletedAt == nil, latest.originalURL == raw {
                    try repository.update(id: latest.id, expectedVersion: latest.version) { $0.articleError = reason }
                }
            } catch { self.error = String(localized: "网页正文处理未完成：\(reason)；保存失败状态时发生错误：\(error.localizedDescription)"); return false }
            self.error = reason
            return false
        }
    }

    @discardableResult
    func restore(_ record: CollectionRecord) -> Bool {
        quotaExceeded = false
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.restore(ids: [record.id], isPro: PurchaseService.cachedIsPro)
            error = nil
            reload()
            resumeExtraction()
            return true
        } catch {
            if case CollectionError.limit = error { quotaExceeded = true }
            self.error = error.localizedDescription; reload(); return false
        }
    }

    @discardableResult
    func batch(_ ids: Set<UUID>, action: CollectionRepository.BatchAction) -> Bool {
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.batch(ids: ids, action: action)
            reload()
            return true
        } catch { self.error = error.localizedDescription; reload(); return false }
    }

    @discardableResult
    func restoreMany(_ ids: Set<UUID>) -> Bool {
        quotaExceeded = false
        do {
            guard let repository else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            try repository.restore(ids: ids, isPro: PurchaseService.cachedIsPro)
            error = nil
            reload()
            resumeExtraction()
            return true
        } catch {
            if case CollectionError.limit = error { quotaExceeded = true }
            self.error = error.localizedDescription; reload(); return false
        }
    }

    @discardableResult
    func permanentlyDelete(_ ids: Set<UUID>) -> Bool {
        do {
            guard let repository, let attachments else { throw CollectionError.database(String(localized: "存储尚未打开")) }
            let unused = try attachments.withExclusiveAccess {
                let candidates = try repository.permanentlyDelete(ids: ids)
                let remaining = try repository.all()
                try attachments.removeUnreferenced(candidates, keeping: remaining)
                let referenced = Set(remaining.flatMap(\.attachments).map(\.id))
                return candidates.filter { !referenced.contains($0.id) }
            }
            reload()
            for id in unused.map(\.id) {
                if let cached = previewCopies.removeValue(forKey: id) {
                    let directory = cached.deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
            }
            error = nil
            return true
        } catch { self.error = error.localizedDescription; reload(); return false }
    }
}
