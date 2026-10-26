import AppKit
import Combine

/// Keeps launch, model preparation, and the tutorial in one window and in a
/// strict order. Every model must pass verification before the app is unlocked.
@MainActor
final class AppStartupState: ObservableObject {
    enum Phase { case splash, models, completed, revealing, ready }

    @Published private(set) var phase: Phase = .splash
    @Published private(set) var splashProgress = 0.0
    /// The install surface is only needed when preparation actually requires
    /// a download, extraction, or user attention. Routine cache verification
    /// stays behind the splash, including its outgoing transition.
    @Published private(set) var showsModelPreparation = false
    @Published private(set) var usesReducedMotion = false
    @Published private(set) var revealDuration: TimeInterval
    let models: ModelDownloadManager
    private var launchTask: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var hasStarted = false
    private var isCancelled = false
    private var onReady: (() -> Void)?
    private var modelChanges: AnyCancellable?
    private var modelStatusChanges: AnyCancellable?
    private let splashDuration: TimeInterval
    private let completionHoldDuration: TimeInterval

    var isReady: Bool { phase == .ready }

    init(models: ModelDownloadManager? = nil, splashDuration: TimeInterval = 2.2,
         completionHoldDuration: TimeInterval = 0.35, revealDuration: TimeInterval = 0.65) {
        self.models = models ?? ModelDownloadManager()
        self.splashDuration = max(0, splashDuration)
        self.completionHoldDuration = max(0, completionHoldDuration)
        self.revealDuration = max(0, revealDuration)
        modelChanges = self.models.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        modelStatusChanges = self.models.$status.removeDuplicates().sink { [weak self] _ in
            // @Published emits before storing. Inspect readiness only after the
            // model manager has committed its state and completed this actor turn.
            Task { @MainActor [weak self] in self?.observeModelStatus() }
        }
    }

    deinit { launchTask?.cancel(); revealTask?.cancel() }

    func begin(isTesting: Bool = false, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               onReady: @escaping () -> Void) {
        guard !hasStarted, !isCancelled else { return }
        hasStarted = true
        self.onReady = onReady
        usesReducedMotion = reduceMotion
        if reduceMotion { revealDuration = min(revealDuration, 0.18) }
        // Unit tests use explicitly injected model fixtures and never initiate
        // a network download simply by mounting the application scene.
        if isTesting {
            splashProgress = 1
            complete(immediately: true)
            return
        }
        let duration = reduceMotion ? min(splashDuration, 0.7) : splashDuration
        launchTask = Task { [weak self] in
            let started = ContinuousClock.now
            while let self, !Task.isCancelled {
                let elapsed = started.duration(to: .now)
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                splashProgress = duration > 0 ? min(1, seconds / duration) : 1
                if splashProgress >= 1 { break }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
            guard let self, !Task.isCancelled else { return }
            observeModelStatus()
            models.start()
        }
    }

    /// Readiness belongs to the launch owner, not to a view's render cycle.
    private func observeModelStatus() {
        guard hasStarted, !isCancelled, phase == .splash || phase == .models else { return }
        let status = models.status
        switch status {
        case .checking:
            break
        case .downloading, .verifying, .paused, .failed:
            showsModelPreparation = true
            phase = .models
        case .ready:
            complete()
        }
    }

    func cancel() {
        isCancelled = true
        onReady = nil
        launchTask?.cancel()
        revealTask?.cancel()
        models.cancel()
    }

    private func complete(immediately: Bool = false) {
        guard !isCancelled, phase == .models || phase == .splash else { return }
        let ready = onReady
        onReady = nil
        // Resolve first-run eligibility before the workspace is unblocked so
        // there is no intermediate frame with an interactive canvas.
        ready?()
        guard !isCancelled else { return }
        if immediately {
            phase = .ready
            return
        }
        // Retain the existing splash or finished install landscape for the
        // handoff. The owner keeps the workspace locked throughout it.
        phase = .completed
        // A normal launch with installed models only needs a brief handoff.
        if !showsModelPreparation { revealDuration = min(revealDuration, 0.35) }
        let holdsBriefly = usesReducedMotion || !showsModelPreparation
        let holdDuration = holdsBriefly ? min(completionHoldDuration, 0.12) : completionHoldDuration
        let duration = revealDuration
        revealTask = Task { [weak self] in
            if holdDuration > 0 {
                do { try await Task.sleep(for: .seconds(holdDuration)) }
                catch { return }
            }
            guard let self, !Task.isCancelled, !isCancelled else { return }
            phase = .revealing
            if duration > 0 {
                do { try await Task.sleep(for: .seconds(duration)) }
                catch { return }
            }
            guard !Task.isCancelled, !isCancelled else { return }
            phase = .ready
            revealTask = nil
        }
    }

    var downloadPresentation: ModelDownloadPresentation {
        let status: ModelDownloadStatus
        switch models.status {
        case .checking: status = .checking
        case .downloading: status = .downloading
        case .paused: status = .paused
        case .verifying, .ready: status = .verifying
        case .failed: status = .failed
        }
        return ModelDownloadPresentation(progress: models.progress,
                                         downloadedBytes: models.downloadedBytes,
                                         totalBytes: models.totalBytes,
                                         completedFiles: models.completedFiles,
                                         totalFiles: models.totalFiles,
                                         currentName: models.currentName,
                                         status: status,
                                         errorMessage: models.errorMessage,
                                         canStart: models.canStart,
                                         isIncrementalRepair: models.isIncrementalRepair)
    }
}
