import CryptoKit
import XCTest
@testable import Waifu2x

@MainActor
final class AppStartupStateTests: XCTestCase {
    func testSplashFinishesBeforeModelCheckAndTutorialWaitsForVerifiedFiles() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0.08,
                                      completionHoldDuration: 0, revealDuration: 0)
        var tutorialPresentations = 0
        startup.begin(reduceMotion: false) {
            XCTAssertEqual(startup.phase, .splash, "A verified cache must never enter the install surface")
            XCTAssertFalse(startup.showsModelPreparation)
            tutorialPresentations += 1
        }
        XCTAssertEqual(startup.phase, .splash)
        XCTAssertEqual(manager.currentName, "")
        XCTAssertEqual(tutorialPresentations, 0)
        try await wait { startup.isReady }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertEqual(startup.splashProgress, 1)
        XCTAssertEqual(startup.phase, .ready)
        XCTAssertFalse(startup.showsModelPreparation)
        XCTAssertEqual(tutorialPresentations, 1)
        startup.begin { tutorialPresentations += 1 }
        XCTAssertEqual(tutorialPresentations, 1)
    }

    func testFirstDownloadAutomaticallyPresentsTutorialWithoutAViewNotification() async throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "Waifu2x.StartupFirstDownloadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let onboarding = OnboardingState(defaults: defaults)
        let gate = StartupTransferGate()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            StartupSuccessfulTransfer(destination: destination, payload: fixture.archivePayload, gate: gate)
        })
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0, revealDuration: 0)
        defer { startup.cancel() }
        var tutorialPresentations = 0
        startup.begin(reduceMotion: false) {
            XCTAssertFalse(startup.isReady, "First-run eligibility must be resolved before the canvas is unblocked")
            tutorialPresentations += 1
            onboarding.presentIfNeeded(arguments: [])
        }
        try await wait { manager.status == .downloading }
        XCTAssertEqual(startup.phase, .models)
        XCTAssertTrue(startup.showsModelPreparation)
        XCTAssertFalse(onboarding.isPresented)
        XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey))

        await gate.release()
        // There is deliberately no WorkspaceRootView or manual status callback:
        // the launch owner must deliver download completion by itself.
        try await wait { startup.isReady }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, 1)
        XCTAssertEqual(tutorialPresentations, 1)
        XCTAssertTrue(onboarding.isPresented)
        XCTAssertEqual(onboarding.step, .addImages)
        XCTAssertNil(defaults.object(forKey: OnboardingState.completionKey),
                     "Downloading models must not mark the tutorial completed")

        onboarding.complete()
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), OnboardingState.currentVersion)
    }

    func testCompletedVersionOneTutorialIsNotRepeatedAfterDownloadingModelsAgain() async throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "Waifu2x.StartupUpgradeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(1, forKey: OnboardingState.completionKey)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let onboarding = OnboardingState(defaults: defaults)
        let gate = StartupTransferGate()
        await gate.release()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            StartupSuccessfulTransfer(destination: destination, payload: fixture.archivePayload, gate: gate)
        })
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0, revealDuration: 0)
        startup.begin(reduceMotion: false) { onboarding.presentIfNeeded(arguments: []) }
        try await wait { startup.isReady }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertFalse(onboarding.isPresented, "Users who completed the 1.0.0 tutorial keep their completion when upgrading")
        XCTAssertEqual(defaults.integer(forKey: OnboardingState.completionKey), 1)
    }

    func testFailedPreparationBlocksTheTutorialAndRetryAutomaticallyCompletesStartup() async throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let attempts = StartupTransferAttempts()
        let gate = StartupTransferGate()
        await gate.release()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            if attempts.next() == 1 { return StartupFailedTransfer() }
            return StartupSuccessfulTransfer(destination: destination, payload: fixture.archivePayload, gate: gate)
        })
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0, revealDuration: 0)
        var tutorialWasShown = false
        startup.begin(reduceMotion: false) { tutorialWasShown = true }
        try await wait { manager.status == .failed }
        XCTAssertEqual(startup.phase, .models)
        XCTAssertTrue(startup.showsModelPreparation, "Preparation failures must remain visible for retry")
        XCTAssertFalse(startup.isReady)
        XCTAssertFalse(tutorialWasShown)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertEqual(startup.downloadPresentation.status, .failed)

        manager.retry()
        try await wait { startup.isReady }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertTrue(tutorialWasShown, "Retry must keep the model-to-tutorial handoff connected")
    }

    func testMountingTestSceneDoesNotStartANetworkRequest() throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager)
        var ready = false
        startup.begin(isTesting: true) { ready = true }
        XCTAssertTrue(ready)
        XCTAssertTrue(startup.isReady)
        XCTAssertEqual(manager.status, .checking)
        XCTAssertEqual(manager.currentName, "")
    }

    func testVerifiedModelsKeepTheSplashThroughoutTheHandoffWithoutFlashingTheInstaller() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0.08, revealDuration: 0.12)
        defer { startup.cancel() }
        var readyCallbacks = 0
        startup.begin(reduceMotion: false) {
            XCTAssertFalse(startup.isReady)
            readyCallbacks += 1
        }
        try await wait { startup.phase == .completed }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertFalse(startup.showsModelPreparation, "Cache verification must not mount a completed install screen")
        XCTAssertEqual(startup.downloadPresentation.fraction, 1)
        XCTAssertEqual(readyCallbacks, 1, "Tutorial eligibility is resolved before the handoff begins")
        XCTAssertFalse(startup.isReady, "The outgoing splash must not unlock workspace input")

        try await wait { startup.phase == .revealing }
        XCTAssertFalse(startup.showsModelPreparation, "The outgoing surface must remain the splash during the crossfade")
        XCTAssertFalse(startup.isReady, "Workspace commands stay blocked until the crossfade ends")
        XCTAssertEqual(readyCallbacks, 1)
        try await wait { startup.isReady }
        XCTAssertFalse(startup.showsModelPreparation)
        XCTAssertEqual(readyCallbacks, 1)
    }

    func testReducedMotionUsesAShortHandoffAfterVerification() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0)
        defer { startup.cancel() }
        startup.begin(reduceMotion: true) {}
        try await wait { startup.phase == .completed }
        XCTAssertFalse(startup.showsModelPreparation)
        XCTAssertTrue(startup.usesReducedMotion)
        XCTAssertEqual(startup.revealDuration, 0.18, accuracy: 0.001)
        XCTAssertFalse(startup.isReady)
        try await wait { startup.isReady }
        XCTAssertEqual(manager.status, .ready)
    }

    func testInstalledModelsUseABriefRevealOnNormalLaunch() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0)
        defer { startup.cancel() }
        startup.begin(reduceMotion: false) {}
        try await wait { startup.phase == .completed }
        XCTAssertFalse(startup.usesReducedMotion)
        XCTAssertFalse(startup.showsModelPreparation)
        XCTAssertEqual(startup.revealDuration, 0.35, accuracy: 0.001)
        try await wait { startup.isReady }
    }

    func testFirstDownloadKeepsTheFullLandscapeReveal() async throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = StartupTransferGate()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            StartupSuccessfulTransfer(destination: destination, payload: fixture.archivePayload, gate: gate)
        })
        let startup = AppStartupState(models: manager, splashDuration: 0)
        defer { startup.cancel() }
        startup.begin(reduceMotion: false) {}
        try await wait { manager.status == .downloading }
        XCTAssertTrue(startup.showsModelPreparation)
        await gate.release()
        try await wait { startup.phase == .completed }
        XCTAssertEqual(startup.revealDuration, 0.65, accuracy: 0.001)
        XCTAssertFalse(startup.isReady)
    }

    func testCachedArchiveExtractionStillShowsTheInstallSurfaceAndFullReveal() async throws {
        let fixture = try makeStartupModelFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let pending = store.pendingURL(for: archive)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.archivePayload.write(to: pending)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { _, _ in
            XCTFail("A verified archive must be reused without another download")
            return StartupFailedTransfer()
        })
        let startup = AppStartupState(models: manager, splashDuration: 0)
        defer { startup.cancel() }
        startup.begin(reduceMotion: false) {}
        try await wait { startup.phase == .completed }
        XCTAssertEqual(manager.status, .ready)
        XCTAssertTrue(startup.showsModelPreparation, "Extraction is a real install even when its archive is already cached")
        XCTAssertEqual(startup.revealDuration, 0.65, accuracy: 0.001)
        XCTAssertEqual(try store.validatedFiles().count, fixture.catalog.files.count)
    }

    func testCorruptInstalledModelStillEntersRepairBeforeUnlockingTheWorkspace() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let file = try XCTUnwrap(fixture.catalog.files.first)
        try Data(repeating: 0, count: Int(file.bytes)).write(to: fixture.paths.root.appendingPathComponent(file.path))
        let gate = StartupTransferGate()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            StartupSuccessfulTransfer(destination: destination, payload: fixture.archivePayload, gate: gate)
        })
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0, revealDuration: 0)
        defer { startup.cancel() }
        var readyCallbacks = 0
        startup.begin(reduceMotion: false) { readyCallbacks += 1 }
        try await wait { manager.status == .downloading }
        XCTAssertEqual(startup.phase, .models)
        XCTAssertTrue(startup.showsModelPreparation)
        XCTAssertFalse(startup.isReady)
        XCTAssertEqual(readyCallbacks, 0, "Suppressing routine verification UI must not skip integrity checks")
        await gate.release()
        try await wait { startup.isReady }
        XCTAssertEqual(readyCallbacks, 1)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, 1)
    }

    func testCancellingTheCompletedHoldCannotRevealOrUnlockTheWorkspace() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0.08, revealDuration: 0.04)
        var readyCallbacks = 0
        startup.begin(reduceMotion: false) { readyCallbacks += 1 }
        try await wait { startup.phase == .completed }
        startup.cancel()
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(startup.phase, .completed)
        XCTAssertFalse(startup.isReady)
        XCTAssertEqual(readyCallbacks, 1)
    }

    func testCancellingTheRevealCannotUnlockTheWorkspace() async throws {
        let fixture = try makeStartupModelFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0,
                                      completionHoldDuration: 0, revealDuration: 0.08)
        startup.begin(reduceMotion: false) {}
        try await wait { startup.phase == .revealing }
        startup.cancel()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(startup.phase, .revealing)
        XCTAssertFalse(startup.isReady)
    }

    private func wait(until condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Startup did not reach the expected state")
        throw NSError(domain: "AppStartupStateTests.Timeout", code: 1)
    }
}

func makeStartupModelFixture(installed: Bool) throws -> (directory: URL, paths: ModelPaths, catalog: ModelCatalog, archivePayload: Data) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let paths = ModelPaths(root: directory.appendingPathComponent(ModelPaths.catalogVersion))
    let content = Data("verified model fixture".utf8)
    let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let file = ModelCatalog.File(path: "ONNXModels/fixture.onnx", bytes: Int64(content.count), sha256: digest,
                                 sourceURL: URL(string: "https://models.example.invalid/fixture.onnx")!)
    let sourceRoot = directory.appendingPathComponent("archive-source")
    let source = sourceRoot.appendingPathComponent(file.path)
    try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: source)
    let archiveURL = directory.appendingPathComponent("Waifu2x-models.tar.xz")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-cJf", archiveURL.path, "-C", sourceRoot.path, file.path]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else { throw NSError(domain: "AppStartupStateTests.Archive", code: 1) }
    let archivePayload = try Data(contentsOf: archiveURL)
    let archiveDigest = SHA256.hash(data: archivePayload).map { String(format: "%02x", $0) }.joined()
    let archive = ModelCatalog.File(path: archiveURL.lastPathComponent, bytes: Int64(archivePayload.count), sha256: archiveDigest,
                                    sourceURL: URL(string: "https://models.example.invalid/Waifu2x-models.tar.xz")!)
    let catalog = ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion, files: [file], archive: archive)
    if installed {
        let model = paths.root.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: model)
    }
    return (directory, paths, catalog, archivePayload)
}

actor StartupTransferGate {
    private var isReleased = false
    func release() { isReleased = true }
    func wait() async throws {
        while !isReleased { try await Task.sleep(for: .milliseconds(5)) }
    }
}

final class StartupSuccessfulTransfer: ModelFileTransferring, @unchecked Sendable {
    let destination: URL
    let payload: Data
    let gate: StartupTransferGate
    var resumeData: Data? { nil }
    init(destination: URL, payload: Data, gate: StartupTransferGate) {
        self.destination = destination; self.payload = payload; self.gate = gate
    }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        progress(Int64(payload.count / 2), Int64(payload.count))
        try await gate.wait()
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        return destination
    }
    func pause() async -> Data? { nil }
    func cancel() {}
}

private final class StartupFailedTransfer: ModelFileTransferring, @unchecked Sendable {
    var resumeData: Data? { nil }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        throw URLError(.notConnectedToInternet)
    }
    func pause() async -> Data? { nil }
    func cancel() {}
}

private final class StartupTransferAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
