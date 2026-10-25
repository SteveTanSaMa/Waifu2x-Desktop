import Foundation
import Observation

enum ModelDiagnosticStatus: Equatable, Sendable {
    case unknown, checking, ready, issues, repairing
}

enum ModelRepairOutcome: Equatable, Sendable {
    case none, completed, cancelled, failed
}

/// App-owned so closing Settings never interrupts a repair or releases its inference gate.
@MainActor @Observable
final class ModelMaintenance {
    private(set) var isRepairing = false
    private(set) var isVerifyingRepair = false
    private(set) var repairOutcome: ModelRepairOutcome = .none
    private(set) var installedBytes: Int64?
    private(set) var isReadingStorage = false
    private(set) var downloader: ModelDownloadManager?
    private var startupValidated = false
    private var requiresValidation = false
    @ObservationIgnored private let checker: FileIntegrityChecker
    @ObservationIgnored private let catalog: ModelCatalog?
    @ObservationIgnored private let paths: ModelPaths
    @ObservationIgnored private let canRepair: @MainActor () -> Bool
    @ObservationIgnored private let downloaderFactory: @MainActor () -> ModelDownloadManager
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cancellationRequested = false
    @ObservationIgnored private var storageOperation = UUID()

    var hasModelIssues: Bool { checker.modelVerification == .issues }

    var modelsCanBeUsed: Bool {
        startupValidated && !isRepairing && !requiresValidation && !hasModelIssues
    }

    var canStartRepair: Bool {
        startupValidated && catalog != nil && hasModelIssues && !isRepairing
            && checker.canStart && canRepair()
    }

    var canCancelRepair: Bool { isRepairing && !isVerifyingRepair && !cancellationRequested }

    var diagnosticStatus: ModelDiagnosticStatus {
        if isRepairing { return .repairing }
        if checker.status == .checking { return .checking }
        if hasModelIssues { return .issues }
        return modelsCanBeUsed ? .ready : .unknown
    }

    /// This is actual transfer/check progress, rather than an elapsed-time animation.
    var progress: Double {
        isVerifyingRepair ? checker.progress : (downloader?.progress ?? 0)
    }

    init(checker: FileIntegrityChecker, catalog: ModelCatalog? = nil, paths: ModelPaths = .current,
         canRepair: @escaping @MainActor () -> Bool = { true },
         downloaderFactory: (@MainActor () -> ModelDownloadManager)? = nil) {
        self.checker = checker
        self.paths = paths
        self.canRepair = canRepair
        let loaded: ModelCatalog?
        do {
            let candidate = try catalog ?? ModelCatalog.load()
            try candidate.validate()
            loaded = candidate
        } catch { loaded = nil }
        self.catalog = loaded
        self.downloaderFactory = downloaderFactory ?? { ModelDownloadManager(catalog: loaded, paths: paths) }
    }

    /// Called only after startup's complete model verification has succeeded.
    func recordStartupReady() {
        guard catalog != nil else { return }
        startupValidated = true
        Task { await refreshStorage() }
    }

    func refreshStorage() async {
        guard let catalog else { return }
        let id = UUID()
        storageOperation = id
        isReadingStorage = true
        let paths = paths
        let bytes = await Task.detached(priority: .utility) {
            try? ModelStorageFootprint.bytes(catalog: catalog, paths: paths)
        }.value
        guard storageOperation == id else { return }
        installedBytes = bytes
        isReadingStorage = false
    }

    func startRepair() {
        guard canStartRepair else { return }
        // Reserve on the main actor before creating work; a queued Process action
        // must see the closed inference gate even before this task first executes.
        isRepairing = true
        requiresValidation = true
        isVerifyingRepair = false
        repairOutcome = .none
        cancellationRequested = false
        let manager = downloaderFactory()
        downloader = manager
        work = Task { [weak self] in
            guard let self else { return }
            if !cancellationRequested && !Task.isCancelled { manager.start() }
            while manager.status == .checking || manager.status == .downloading || manager.status == .verifying {
                if cancellationRequested || Task.isCancelled { manager.cancel(); break }
                do { try await Task.sleep(for: .milliseconds(25)) }
                catch { manager.cancel(); break }
            }
            // A paused transfer or cancelled extractor can still own a worker.
            // Keep inference blocked until every worker has released the cache.
            await manager.pauseForTermination()
            let prepared = manager.status == .ready
            isVerifyingRepair = true
            let valid = await checker.refreshAfterModelRepair()
            requiresValidation = !valid
            await refreshStorage()
            if cancellationRequested || Task.isCancelled {
                repairOutcome = .cancelled
            } else {
                repairOutcome = prepared && valid ? .completed : .failed
            }
            isVerifyingRepair = false
            work = nil
            isRepairing = false
        }
    }

    func cancelRepair() {
        guard isRepairing, !isVerifyingRepair, !cancellationRequested else { return }
        cancellationRequested = true
        downloader?.cancel()
        work?.cancel()
    }

    func waitUntilFinished() async {
        await work?.value
    }

    /// Save any resumable transfer before the app finishes its deferred termination.
    func pauseForTermination() async {
        guard isRepairing else { return }
        cancellationRequested = true
        await downloader?.pauseForTermination()
        await waitUntilFinished()
    }
}
