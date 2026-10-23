import CryptoKit
import XCTest
@testable import Waifu2x

@MainActor
final class AppStartupStateTests: XCTestCase {
    func testSplashFinishesBeforeModelCheckAndTutorialWaitsForVerifiedFiles() async throws {
        let fixture = try makeFixture(installed: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths)
        let startup = AppStartupState(models: manager, splashDuration: 0.08)
        var tutorialPresentations = 0
        startup.begin(reduceMotion: false) { tutorialPresentations += 1 }
        XCTAssertEqual(startup.phase, .splash)
        XCTAssertEqual(manager.currentName, "")
        startup.modelStatusChanged()
        XCTAssertEqual(tutorialPresentations, 0)
        try await wait { manager.status == .ready }
        XCTAssertEqual(startup.phase, .models)
        XCTAssertEqual(startup.splashProgress, 1)
        XCTAssertEqual(tutorialPresentations, 0)
        startup.modelStatusChanged()
        XCTAssertEqual(startup.phase, .ready)
        XCTAssertEqual(tutorialPresentations, 1)
        startup.modelStatusChanged()
        startup.begin { tutorialPresentations += 1 }
        XCTAssertEqual(tutorialPresentations, 1)
    }

    func testMissingOrCorruptedModelsKeepTutorialAndWorkspaceBlocked() async throws {
        let fixture = try makeFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { _, _ in StartupFailedTransfer() })
        let startup = AppStartupState(models: manager, splashDuration: 0)
        var tutorialWasShown = false
        startup.begin(reduceMotion: false) { tutorialWasShown = true }
        try await wait { manager.status == .failed }
        startup.modelStatusChanged()
        XCTAssertEqual(startup.phase, .models)
        XCTAssertFalse(startup.isReady)
        XCTAssertFalse(tutorialWasShown)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertEqual(startup.downloadPresentation.status, .failed)
    }

    func testMountingTestSceneDoesNotStartANetworkRequest() throws {
        let fixture = try makeFixture(installed: false)
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

    private func wait(until condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Startup did not reach the expected state")
    }

    private func makeFixture(installed: Bool) throws -> (directory: URL, paths: ModelPaths, catalog: ModelCatalog) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = ModelPaths(root: directory.appendingPathComponent(ModelPaths.catalogVersion))
        let content = Data("verified model fixture".utf8)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let file = ModelCatalog.File(path: "ONNXModels/fixture.onnx", bytes: Int64(content.count), sha256: digest,
                                     sourceURL: URL(string: "https://models.example.invalid/fixture.onnx")!)
        let catalog = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: [file])
        let model = paths.root.appendingPathComponent(file.path)
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (installed ? content : Data("incomplete".utf8)).write(to: model)
        return (directory, paths, catalog)
    }
}

private final class StartupFailedTransfer: ModelFileTransferring, @unchecked Sendable {
    var resumeData: Data? { nil }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        throw URLError(.notConnectedToInternet)
    }
    func pause() async -> Data? { nil }
    func cancel() {}
}
