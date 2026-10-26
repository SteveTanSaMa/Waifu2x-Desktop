import Foundation
import Combine

enum ModelDiagnosticStatus: Equatable, Sendable {
    case unknown, checking, ready, issues, repairing
}

enum ModelRepairOutcome: Equatable, Sendable {
    case none, completed, cancelled, failed
}

/// App-owned so closing Settings never interrupts a repair or releases its inference gate.
@MainActor
final class ModelMaintenance: ObservableObject {
    @Published private(set) var isRepairing = false
    @Published private(set) var isVerifyingRepair = false
    @Published private(set) var repairOutcome: ModelRepairOutcome = .none
    @Published private(set) var installedBytes: Int64?
    @Published private(set) var isReadingStorage = false
    @Published private(set) var downloader: ModelDownloadManager? {
        didSet {
            downloadChanges = downloader?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        }
    }
    @Published private var startupValidated = false
    @Published private var requiresValidation = false
    private let checker: FileIntegrityChecker
    private let catalog: ModelCatalog?
    private let paths: ModelPaths
    private let canRepair: @MainActor () -> Bool
    private let downloaderFactory: @MainActor () -> ModelDownloadManager
    private var work: Task<Void, Never>?
    private var cancellationRequested = false
    private var storageOperation = UUID()
    private var checkerChanges: AnyCancellable?
    private var downloadChanges: AnyCancellable?
    private var workspaceAvailabilityChanges: AnyCancellable?

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
        checkerChanges = checker.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    /// Only the workspace's own busy flags are observed. Forwarding its entire
    /// object publisher would cycle through the reverse inference-gate dependency.
    func observeRepairAvailability(_ workspace: Workspace) {
        workspaceAvailabilityChanges = workspace.$isProcessing
            .combineLatest(workspace.$isLoading, workspace.$isExporting)
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
