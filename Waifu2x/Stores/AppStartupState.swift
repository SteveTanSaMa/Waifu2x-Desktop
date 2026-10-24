import AppKit
import Observation

/// Keeps launch, model preparation, and the tutorial in one window and in a
/// strict order. Every model must pass verification before the app is unlocked.
@MainActor @Observable
final class AppStartupState {
    enum Phase { case splash, models, ready }

    private(set) var phase: Phase = .splash
    private(set) var splashProgress = 0.0
    let models: ModelDownloadManager
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isCancelled = false
    @ObservationIgnored private var onReady: (() -> Void)?
    private let splashDuration: TimeInterval

    var isReady: Bool { phase == .ready }

    init(models: ModelDownloadManager? = nil, splashDuration: TimeInterval = 2.2) {
        self.models = models ?? ModelDownloadManager()
        self.splashDuration = max(0, splashDuration)
    }

    deinit { launchTask?.cancel() }

    func begin(isTesting: Bool = false, reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
               onReady: @escaping () -> Void) {
        guard !hasStarted, !isCancelled else { return }
        hasStarted = true
        self.onReady = onReady
        // Unit tests use explicitly injected model fixtures and never initiate
        // a network download simply by mounting the application scene.
        if isTesting {
            splashProgress = 1
            complete()
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
            phase = .models
            observeModelStatus()
            models.start()
        }
    }

    /// Readiness belongs to the launch owner, not to a view's render cycle.
    /// Observation notifications arrive before the mutation, so re-read and
    /// re-arm on the main actor after the manager has published its new state.
    private func observeModelStatus() {
        guard hasStarted, !isCancelled, phase == .models else { return }
        let status = withObservationTracking {
            models.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeModelStatus() }
        }
        if status == .ready { complete() }
    }

    func cancel() {
        isCancelled = true
        onReady = nil
        launchTask?.cancel()
        models.cancel()
    }

    private func complete() {
        guard !isCancelled, phase != .ready else { return }
        let ready = onReady
        onReady = nil
        // Resolve first-run eligibility before the workspace is unblocked so
        // there is no intermediate frame with an interactive canvas.
        ready?()
        phase = .ready
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
                                         canStart: models.canStart)
    }
}
