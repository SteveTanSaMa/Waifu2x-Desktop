import Foundation
import Observation

@MainActor @Observable
final class ModelDownloadManager {
    private(set) var status: ModelPreparationStatus = .checking
    private(set) var progress = 0.0
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64?
    private(set) var completedFiles = 0
    private(set) var totalFiles = 0
    private(set) var currentName = ""
    private(set) var errorMessage: String?
    private let catalog: ModelCatalog?
    private let catalogError: String?
    private let paths: ModelPaths
    private let transportFactory: ModelDownloadTransportFactory
    // canStart depends on these tasks finishing; their mutations must invalidate the paused UI.
    private var work: Task<Void, Never>?
    @ObservationIgnored private var transfer: (any ModelFileTransferring)?
    @ObservationIgnored private var currentFile: ModelCatalog.File?
    @ObservationIgnored private var completedBytes: Int64 = 0
    @ObservationIgnored private var currentBytes: Int64 = 0
    private var pauseWork: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()

    var canStart: Bool {
        guard pauseWork == nil, status != .ready else { return false }
        if status == .downloading { return transfer != nil }
        return work == nil && catalog != nil
    }

    init(catalog: ModelCatalog? = nil, paths: ModelPaths = .current,
         transportFactory: ModelDownloadTransportFactory? = nil) {
        self.paths = paths
        self.transportFactory = transportFactory ?? { ModelFileDownload(destination: $0, expectedBytes: $1) }
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
                let verified = try await Self.background {
                    try store.validatedFiles { [weak self] count, _, name in
                        Task { @MainActor in
                            guard let self, self.operation == id, self.status == .checking else { return }
                            self.currentName = name
                            if !preservesProgressWhileChecking { self.completedFiles = count }
                        }
                    }
                }
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
                currentFile = archive
                let pending = store.pendingURL(for: archive)
                let resume = readResume(for: archive, store: store)
                // A verified archive survives termination during extraction, avoiding another download.
                let cachedArchive = try await Self.background { try store.archiveMatches(pending) }
                try check(id)
                if !cachedArchive {
                    setBytes(completed: 0, current: resume?.downloadedBytes ?? 0)
                    try? FileManager.default.removeItem(at: pending)
                    let transfer = transportFactory(pending, archive.bytes)
                    self.transfer = transfer
                    status = .downloading; currentName = archive.path
                    _ = try await transfer.download(from: archive.sourceURL, resumeData: resume?.data) { [weak self] bytes, _ in
                        Task { @MainActor in
                            guard let self, self.operation == id, self.status == .downloading else { return }
                            self.setBytes(completed: 0, current: min(archive.bytes, max(0, bytes)))
                        }
                    }
                    try check(id)
                    self.transfer = nil
                }
                setBytes(completed: 0, current: archive.bytes)
                status = .verifying; currentName = L("正在解压模型包")
                removeResume(store)
                try await Self.background {
                    try store.installArchive(from: pending) { [weak self] count, name in
                        Task { @MainActor in
                            guard let self, self.operation == id, self.status == .verifying else { return }
                            self.completedFiles = max(verified.count, count)
                            self.currentName = L("正在解压模型包") + "\n" + name
                        }
                    }
                }
                try check(id)
                try? FileManager.default.removeItem(at: pending)
                currentFile = nil
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
