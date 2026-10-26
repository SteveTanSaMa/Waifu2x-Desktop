import Foundation
import Combine

@MainActor
final class ModelDownloadManager: ObservableObject {
    @Published private(set) var status: ModelPreparationStatus = .checking
    @Published private(set) var progress = 0.0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var currentName = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isIncrementalRepair = false
    private let catalog: ModelCatalog?
    private let catalogError: String?
    private let paths: ModelPaths
    private let transportFactory: ModelDownloadTransportFactory
    private let repairManifestLoader: ModelRepairManifestLoader
    // canStart depends on these tasks finishing; their mutations must invalidate the paused UI.
    @Published private var work: Task<Void, Never>?
    private var transfer: (any ModelFileTransferring)?
    private var currentFile: ModelCatalog.File?
    private var completedBytes: Int64 = 0
    private var currentBytes: Int64 = 0
    @Published private var pauseWork: Task<Void, Never>?
    private var operation = UUID()

    var canStart: Bool {
        guard pauseWork == nil, status != .ready else { return false }
        if status == .downloading { return transfer != nil }
        return work == nil && catalog != nil
    }

    init(catalog: ModelCatalog? = nil, paths: ModelPaths = .current,
         transportFactory: ModelDownloadTransportFactory? = nil,
         repairManifestLoader: ModelRepairManifestLoader? = nil) {
        self.paths = paths
        self.transportFactory = transportFactory ?? { ModelFileDownload(destination: $0, expectedBytes: $1) }
        self.repairManifestLoader = repairManifestLoader ?? { try await ModelRepairManifest.load(from: $0) }
        do {
            let loaded = try catalog ?? ModelCatalog.load()
            try loaded.validate()
            self.catalog = loaded; catalogError = nil
            totalFiles = loaded.files.count; totalBytes = loaded.archive?.bytes ?? loaded.totalModelBytes
        } catch {
            self.catalog = nil; catalogError = error.localizedDescription
        }
    }

    func start() {
        guard work == nil, pauseWork == nil, status != .ready else { return }
        let preservesProgressWhileChecking = status == .paused || status == .failed
        let id = UUID(); operation = id
        errorMessage = nil; status = .checking; currentName = L("正在检查已下载的模型")
        if !preservesProgressWhileChecking {
            completedFiles = 0
            setBytes(completed: 0, current: 0)
        }
        work = Task { [weak self] in
            guard let self else { return }
            defer { if operation == id { work = nil; transfer = nil } }
            do {
                guard let catalog else {
                    throw ModelDownloadFailure.message(catalogError ?? L("模型清单无效，请重新安装完整应用"))
                }
                let store = ModelStore(catalog: catalog, paths: paths)
                let initial = try await Self.background {
                    try store.validatedFiles { [weak self] count, _, name in
                        Task { @MainActor in
                            guard let self, self.operation == id, self.status == .checking else { return }
                            self.currentName = name
                            if !preservesProgressWhileChecking { self.completedFiles = count }
                        }
                    }
                }
                try check(id)
                let verified = try await Self.background { try store.reuseVerifiedPayloads(initial) }
                try check(id)
                completedFiles = verified.count
                if verified.count == catalog.files.count {
                    removeResume(store)
                    if let archive = catalog.archive { try? FileManager.default.removeItem(at: store.pendingURL(for: archive)) }
                    markReady()
                    return
                }
                guard let archive = catalog.archive else {
                    throw ModelDownloadFailure.message(L("模型清单无效，请重新安装完整应用"))
                }
                // A complete archive from an interrupted extraction is reusable
                // without fetching either repair metadata or model bytes again.
                let cachedArchive = try await Self.background {
                    try store.archiveMatches(store.pendingURL(for: archive))
                }
                try check(id)
                if !verified.isEmpty, !cachedArchive, let url = catalog.repairManifestURL {
                    isIncrementalRepair = true
                    status = .verifying
                    currentName = L("正在检查增量修复包")
                    do {
                        let data = try await repairManifestLoader(url)
                        try check(id)
                        let repairs = try ModelRepairManifest.decode(data, catalog: catalog, verified: verified)
                        let bytes = repairs.reduce(Int64(0)) { $0 + $1.archive.bytes }
                        if !repairs.isEmpty, bytes < archive.bytes {
                            let resumedBytes = repairs.first.flatMap {
                                self.readResume(for: $0.archive, store: store)?.downloadedBytes
                            } ?? 0
                            totalBytes = bytes
                            // After earlier repairs have finished, the new plan
                            // contains only remaining payloads. Publish its byte
                            // snapshot together before cached-file checks yield.
                            setBytes(completed: 0, current: resumedBytes)
                            try await prepareRepairs(repairs, store: store, verified: verified, id: id)
                            markReady()
                            return
                        }
                    } catch {
                        // Pausing and cancellation never turn into an unexpected
                        // full download. Only an unavailable/invalid repair may fall back.
                        try check(id)
                        transfer = nil
                        removeResume(store)
                        if let file = currentFile {
                            try? FileManager.default.removeItem(at: store.pendingURL(for: file))
                        }
                        currentFile = nil
                    }
                }
                isIncrementalRepair = false
                totalBytes = archive.bytes
                try await prepareFullArchive(archive, store: store, verified: verified,
                                             cached: cachedArchive, id: id)
                markReady()
            } catch {
                guard operation == id, status != .paused, !Task.isCancelled else { return }
                if let catalog {
                    let store = ModelStore(catalog: catalog, paths: paths)
                    if status == .downloading, !(error is ModelDownloadFailure), let file = currentFile,
                       let data = transfer?.resumeData {
                        saveResume(data, file: file, store: store)
                    } else {
                        removeResume(store)
                        setBytes(completed: 0, current: 0)
                    }
                    if let file = currentFile { try? FileManager.default.removeItem(at: store.pendingURL(for: file)) }
                }
                status = .failed
                errorMessage = error is ModelDownloadFailure ? error.localizedDescription : L("模型准备失败：%@", error.localizedDescription)
                currentName = L("模型准备未完成")
            }
        }
    }

    private func prepareFullArchive(_ archive: ModelCatalog.File, store: ModelStore,
                                    verified: Set<String>, cached: Bool, id: UUID) async throws {
        currentFile = archive
        try await download(archive, store: store, completed: 0, cached: cached, id: id,
                           name: archive.path)
        status = .verifying; currentName = L("正在解压模型包")
        try await Self.background {
            try store.installArchive(from: store.pendingURL(for: archive)) { [weak self] count, name in
                Task { @MainActor in
                    guard let self, self.operation == id, self.status == .verifying else { return }
                    self.completedFiles = max(verified.count, count)
                    self.currentName = L("正在解压模型包") + "\n" + name
                }
            }
        }
        try check(id)
        try? FileManager.default.removeItem(at: store.pendingURL(for: archive))
        currentFile = nil
    }

    private func prepareRepairs(_ repairs: [ModelRepairManifest.Repair], store: ModelStore,
                                verified: Set<String>, id: UUID) async throws {
        var completed: Int64 = 0
        var installed = verified.count
        for repair in repairs {
            try check(id)
            currentFile = repair.archive
            let cached = try await Self.background {
                try store.downloadedFileMatches(repair.archive, at: store.pendingURL(for: repair.archive))
            }
            try check(id)
            try await download(repair.archive, store: store, completed: completed, cached: cached, id: id,
                               name: L("正在补全缺失的模型") + "\n" + (repair.files.first?.path ?? ""))
            status = .verifying; currentName = L("正在补全缺失的模型")
            try await Self.background {
                try store.installRepair(repair.archive, files: repair.files, from: store.pendingURL(for: repair.archive))
            }
            try check(id)
            installed += repair.files.count
            completedFiles = installed
            completed += repair.archive.bytes
            setBytes(completed: completed, current: 0)
            try? FileManager.default.removeItem(at: store.pendingURL(for: repair.archive))
            currentFile = nil
        }
        // Neighbouring cached files could have changed since the initial scan.
        // Never unlock the workspace until the complete catalog is valid again.
        status = .verifying; currentName = L("正在检查已下载的模型")
        let all = try await Self.background { try store.validatedFiles() }
        try check(id)
        guard all.count == store.catalog.files.count else {
            throw ModelDownloadFailure.message(L("模型准备未完成"))
        }
        removeResume(store)
    }

    private func download(_ file: ModelCatalog.File, store: ModelStore, completed: Int64,
                          cached: Bool, id: UUID, name: String) async throws {
        let pending = store.pendingURL(for: file)
        if !cached {
            let resume = readResume(for: file, store: store)
            setBytes(completed: completed, current: resume?.downloadedBytes ?? 0)
            try? FileManager.default.removeItem(at: pending)
            let active = transportFactory(pending, file.bytes)
            transfer = active
            status = .downloading; currentName = name
            _ = try await active.download(from: file.sourceURL, resumeData: resume?.data) { [weak self] bytes, _ in
                Task { @MainActor in
                    guard let self, self.operation == id, self.status == .downloading,
                          self.currentFile == file else { return }
                    self.setBytes(completed: completed, current: min(file.bytes, max(0, bytes)))
                }
            }
            try check(id)
            transfer = nil
        }
        setBytes(completed: completed, current: file.bytes)
        removeResume(store)
    }

    func togglePause() {
        if status == .downloading { beginPause() }
        else if status == .paused { start() }
    }

    func retry() {
        guard status == .failed || status == .paused else { return }
        start()
    }

    func cancel() {
        guard status != .ready else { return }
        work?.cancel(); transfer?.cancel()
        status = .paused; currentName = L("模型下载已暂停")
    }

    /// The application waits for this before replying to a deferred termination request.
    func pauseForTermination() async {
        if let pauseWork { await pauseWork.value; return }
        if status == .downloading {
            beginPause()
            await pauseWork?.value
        } else {
            let active = work
            active?.cancel()
            // Cancel verification/extraction; a complete downloaded archive remains reusable.
            await active?.value
            if status != .ready, status != .failed {
                status = .paused; currentName = L("模型下载已暂停")
            }
        }
    }

    private func beginPause() {
        guard status == .downloading, pauseWork == nil, let transfer, let file = currentFile else { return }
        status = .paused; currentName = L("模型下载已暂停")
        let id = operation, active = work
        pauseWork = Task { [weak self] in
            let data = await transfer.pause()
            guard let self else { return }
            if self.operation == id, let catalog = self.catalog {
                let store = ModelStore(catalog: catalog, paths: self.paths)
                if let data { self.saveResume(data, file: file, store: store) }
                else { self.removeResume(store); self.setBytes(completed: self.completedBytes, current: 0) }
            }
            // URLSession must finish cancellation before another transfer reuses its resume data.
            await active?.value
            self.pauseWork = nil
        }
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        if operation != id || status == .paused { throw CancellationError() }
    }
    private func setBytes(completed: Int64, current: Int64) {
        completedBytes = completed; currentBytes = current
        downloadedBytes = max(0, min(totalBytes ?? 0, completed + current))
        progress = Double(downloadedBytes) / Double(max(1, totalBytes ?? 0))
    }
    private func markReady() {
        setBytes(completed: totalBytes ?? 0, current: 0)
        status = .ready; completedFiles = totalFiles
        currentName = L("模型已就绪"); errorMessage = nil
    }

    private struct ResumeRecord: Codable {
        let catalogIdentity: String
        let file: ModelCatalog.File
        let downloadedBytes: Int64
        let data: Data
    }
    private func readResume(for file: ModelCatalog.File, store: ModelStore) -> ResumeRecord? {
        guard let data = try? Data(contentsOf: store.resumeURL),
              let record = try? JSONDecoder().decode(ResumeRecord.self, from: data),
              record.catalogIdentity == store.catalog.identity, record.file == file,
              record.downloadedBytes >= 0, record.downloadedBytes <= file.bytes, !record.data.isEmpty else {
            removeResume(store); return nil
        }
        return record
    }
    private func saveResume(_ data: Data, file: ModelCatalog.File, store: ModelStore) {
        do {
            try FileManager.default.createDirectory(at: paths.downloadDirectory, withIntermediateDirectories: true)
            let record = ResumeRecord(catalogIdentity: store.catalog.identity, file: file,
                                      downloadedBytes: min(file.bytes, max(0, currentBytes)), data: data)
            try JSONEncoder().encode(record).write(to: store.resumeURL, options: .atomic)
        } catch { errorMessage = L("无法保存下载进度：%@", error.localizedDescription) }
    }
    private func removeResume(_ store: ModelStore) { try? FileManager.default.removeItem(at: store.resumeURL) }

    private nonisolated static func background<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: action)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}
