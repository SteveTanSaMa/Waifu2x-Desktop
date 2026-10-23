import XCTest
import Foundation
import Observation
@testable import Waifu2x

final class ModelDownloadTests: XCTestCase {
    private struct Fixture {
        let temporary: URL
        let sources: [URL]
        let catalog: ModelCatalog
        let paths: ModelPaths
        let contents: [Data]
    }

    private func fixture(firstFileBytes: Int = 4096) throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ModelDownloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let contents = [Data(repeating: 0x53, count: firstFileBytes), Data(repeating: 0x71, count: 8192)]
        let names = ["ONNXModels/test.onnx", "Engine/models-cunet/noise0_model.bin"]
        var sources = [URL](), files = [ModelCatalog.File]()
        for index in contents.indices {
            let source = temporary.appendingPathComponent("source-\(index)")
            try contents[index].write(to: source); sources.append(source)
            files.append(.init(path: names[index], bytes: Int64(contents[index].count), sha256: try ModelStore.sha256(of: source),
                               sourceURL: URL(string: "https://models.example.invalid/\(UUID().uuidString)/\(index).onnx")!))
        }
        return Fixture(temporary: temporary, sources: sources,
                       catalog: .init(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: files),
                       paths: .init(root: temporary.appendingPathComponent("installed/models-v1")), contents: contents)
    }

    private func install(_ indexes: [Int], in fixture: Fixture) throws {
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        for index in indexes { try store.install(fixture.catalog.files[index], from: fixture.sources[index]) }
    }

    func testCatalogRejectsTraversalDuplicateDestinationsAndNonHTTPSURLs() throws {
        for path in ["../outside.onnx", "/outside.onnx", "Engine/../outside", "Engine\\outside", "a//b", "a/./b", "C:/outside", "line\nbreak"] {
            XCTAssertThrowsError(try ModelCatalog.validateRelativePath(path), path)
        }
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let duplicated = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: fixture.catalog.files + fixture.catalog.files)
        XCTAssertThrowsError(try duplicated.validate())
        let original = fixture.catalog.files[0]
        let unsafe = ModelCatalog.File(path: original.path, bytes: original.bytes, sha256: original.sha256,
                                       sourceURL: URL(string: "http://models.example.invalid/test.onnx")!)
        XCTAssertThrowsError(try ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: [unsafe]).validate())
    }

    func testStoreRepairsCorruptFilesAtomicallyAndRejectsBadDownloads() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        try FileManager.default.createDirectory(at: fixture.paths.onnxModels, withIntermediateDirectories: true)
        let output = fixture.paths.root.appendingPathComponent(fixture.catalog.files[0].path)
        try Data(repeating: 0, count: 4096).write(to: output)
        XCTAssertTrue(try store.validatedFiles().isEmpty)
        try store.install(fixture.catalog.files[0], from: fixture.sources[0])
        XCTAssertEqual(try Data(contentsOf: output), fixture.contents[0])
        let corrupt = fixture.temporary.appendingPathComponent("corrupt")
        try Data(repeating: 0, count: 8192).write(to: corrupt)
        XCTAssertThrowsError(try store.install(fixture.catalog.files[1], from: corrupt))
        XCTAssertEqual(try store.validatedFiles(), Set([fixture.catalog.files[0].path]))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.onnxModels.path)
        XCTAssertFalse(siblings.contains { $0.contains("staging") })
    }

    func testStoreDoesNotFollowSymlinkedModelDirectories() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: true)
        let outside = fixture.temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.paths.onnxModels, withDestinationURL: outside)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        XCTAssertThrowsError(try store.install(fixture.catalog.files[0], from: fixture.sources[0]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testBundledCatalogContainsExactWeightAndHelperFilesWithDirectSources() throws {
        let catalog = try ModelCatalog.load()
        try catalog.validate()
        XCTAssertEqual(catalog.files.count, 99)
        XCTAssertEqual(catalog.files.filter { $0.path.hasPrefix("ONNXModels/") }.count, 71)
        XCTAssertEqual(catalog.files.filter { $0.path.hasPrefix("Engine/models-") }.count, 28)
        XCTAssertFalse(catalog.files.contains { $0.path.contains("waifu2x-ncnn-vulkan") })
        XCTAssertEqual(Set(catalog.files.filter { $0.path.hasPrefix("ONNXModels/") }.map { $0.sourceURL.host }), ["unlimited.waifu2x.net"])
        XCTAssertEqual(Set(catalog.files.filter { $0.path.hasPrefix("Engine/") }.map { $0.sourceURL.host }), ["raw.githubusercontent.com"])
        XCTAssertGreaterThan(catalog.totalModelBytes, 1_000_000_000)
    }

    @MainActor func testVerifiedCacheIsReadyOfflineWithoutStartingATransfer() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0, 1], in: fixture)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { _, _ in
            XCTFail("A verified cache must not download")
            return FixtureTransfer(source: fixture.sources[0], destination: fixture.sources[0], mode: .copy)
        })
        manager.start(); await wait(manager, for: .ready)
        XCTAssertEqual(manager.completedFiles, 2)
        XCTAssertEqual(manager.downloadedBytes, fixture.catalog.totalModelBytes)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor func testFailedSecondFileRetainsTheFirstAndRetryDownloadsOnlyTheMissingFile() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let index = expected == 4096 ? 0 : 1
            let attempt = attempts.next(for: index)
            return FixtureTransfer(source: fixture.sources[index], destination: destination, mode: index == 1 && attempt == 1 ? .fail : .copy)
        })
        manager.start(); manager.start()
        await wait(manager, for: .failed)
        XCTAssertEqual(manager.completedFiles, 1)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles(), [fixture.catalog.files[0].path])
        manager.retry()
        XCTAssertEqual(manager.status, .checking)
        XCTAssertEqual(manager.downloadedBytes, 4096, "Retry must retain its real byte snapshot while checking the cache")
        XCTAssertEqual(manager.progress, 1.0 / 3.0, accuracy: 0.00001)
        await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 1, "The first verified file must survive retries")
        XCTAssertEqual(attempts.count(for: 1), 2)
        XCTAssertEqual(manager.progress, 1)
    }

    @MainActor func testManagerInstallsThroughURLSessionAndDoesNotRequestCachedFiles() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        for index in fixture.catalog.files.indices {
            DownloadFixtureProtocol.register(fixture.catalog.files[index].sourceURL, status: 200, data: fixture.contents[index])
        }
        defer { fixture.catalog.files.forEach { DownloadFixtureProtocol.remove($0.sourceURL) } }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DownloadFixtureProtocol.self]
            return ModelFileDownload(destination: destination, expectedBytes: expected, configuration: configuration)
        })
        manager.start(); await wait(manager, for: .ready)
        XCTAssertEqual(DownloadFixtureProtocol.requestCount(for: fixture.catalog.files[0].sourceURL), 0)
        XCTAssertEqual(DownloadFixtureProtocol.requestCount(for: fixture.catalog.files[1].sourceURL), 1)
        XCTAssertEqual(manager.downloadedBytes, 12288)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, 2)
    }

    @MainActor func testOverallProgressWeightsActualBytesAndSkipsVerifiedFiles() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, 8192)
            _ = attempts.next(for: 1)
            return FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .waitForPause)
        })
        manager.start()
        await waitUntil { manager.status == .downloading && manager.downloadedBytes == 8192 }
        XCTAssertEqual(manager.totalBytes, 12288)
        XCTAssertEqual(manager.completedFiles, 1)
        XCTAssertEqual(manager.progress, 2.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(attempts.count(for: 1), 1)
        await manager.pauseForTermination()
    }

    @MainActor func testTerminationPersistsOnlyCurrentFileResumeAndANewManagerReusesIt() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let attempts = TransferAttempts()
        let first = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let index = expected == 4096 ? 0 : 1
            _ = attempts.next(for: index)
            return FixtureTransfer(source: fixture.sources[index], destination: destination, mode: index == 0 ? .copy : .waitForPause)
        })
        first.start(); await waitUntil { first.status == .downloading && first.downloadedBytes == 8192 }
        XCTAssertTrue(first.canStart)
        await first.pauseForTermination()
        XCTAssertEqual(first.status, .paused)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.resumeURL)) as? [String: Any])
        XCTAssertEqual(record["catalogIdentity"] as? String, fixture.catalog.identity)
        XCTAssertEqual((record["file"] as? [String: Any])?["path"] as? String, fixture.catalog.files[1].path)
        XCTAssertEqual(record["downloadedBytes"] as? Int, 4096)
        let next = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, 8192)
            return FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .copy, receivedResume: { attempts.record($0) })
        })
        next.start(); await wait(next, for: .ready)
        XCTAssertEqual(attempts.lastResume, Data("resume-fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeURL.path))
    }

    @MainActor func testResumeCannotCrossCatalogOrSourceIdentity() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let first = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .waitForPause)
        })
        first.start(); await waitUntil { first.downloadedBytes == 8192 }
        await first.pauseForTermination()
        var files = fixture.catalog.files
        let original = files[1]
        files[1] = .init(path: original.path, bytes: original.bytes, sha256: original.sha256,
                         sourceURL: URL(string: "https://models.example.invalid/changed-source.onnx")!)
        let changed = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: files)
        XCTAssertNotEqual(changed.identity, fixture.catalog.identity)
        let received = TransferAttempts()
        let next = ModelDownloadManager(catalog: changed, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .copy, receivedResume: { received.record($0) })
        })
        next.start(); await wait(next, for: .ready)
        XCTAssertNil(received.lastResume)
    }

    @MainActor func testPauseCompletionInvalidatesTheResumeButtonAvailability() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: fixture.sources[0], destination: destination, mode: .waitForPause)
        })
        manager.start(); await waitUntil { manager.downloadedBytes == 2048 }
        manager.togglePause()
        let change = ObservationChange()
        withObservationTracking { XCTAssertFalse(manager.canStart) } onChange: { change.record() }
        await manager.pauseForTermination()
        XCTAssertTrue(manager.canStart)
        XCTAssertTrue(change.wasRecorded, "Completing resume-data persistence must enable the observed Resume action")
    }

    @MainActor func testSameManagerResumeKeepsTheDrawingStableThroughoutCacheVerification() async throws {
        // A sizeable verified file keeps the SHA scan visible long enough to observe its intermediate updates.
        let fixture = try fixture(firstFileBytes: 16 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, 8192)
            return FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .waitForPause)
        })
        manager.start()
        let receivedBytes = fixture.catalog.files[0].bytes + 4096
        await waitUntil { manager.status == .downloading && manager.downloadedBytes == receivedBytes }
        await manager.pauseForTermination()
        let snapshot = manager.progress
        manager.togglePause()
        XCTAssertEqual(manager.status, .checking)
        var observations = 0
        while manager.status == .checking, observations < 500 {
            XCTAssertEqual(manager.downloadedBytes, receivedBytes)
            XCTAssertEqual(manager.progress, snapshot)
            XCTAssertEqual(manager.completedFiles, 1)
            observations += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(observations, 0)
        XCTAssertEqual(manager.status, .downloading)
        XCTAssertEqual(manager.downloadedBytes, receivedBytes)
        XCTAssertEqual(manager.progress, snapshot)
        await manager.pauseForTermination()
    }

    @MainActor func testResumeReconcilesMissingPartialDataAndCorruptCacheAfterTheFullScan() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let attempt = attempts.next(for: 0)
            if attempt == 1 {
                XCTAssertEqual(expected, 8192)
                return FixtureTransfer(source: fixture.sources[1], destination: destination, mode: .waitForPause)
            }
            XCTAssertEqual(expected, 4096, "A same-size corrupted cache file must be checked and requested again")
            return FixtureTransfer(source: fixture.sources[0], destination: destination, mode: .waitWithoutProgress)
        })
        manager.start(); await waitUntil { manager.downloadedBytes == 8192 }
        await manager.pauseForTermination()
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        try FileManager.default.removeItem(at: store.resumeURL)
        try Data(repeating: 0, count: 4096).write(to: fixture.paths.root.appendingPathComponent(fixture.catalog.files[0].path))
        manager.togglePause()
        XCTAssertEqual(manager.status, .checking)
        XCTAssertEqual(manager.downloadedBytes, 8192, "Keep the last actual byte snapshot until verification finishes")
        await wait(manager, for: .downloading)
        XCTAssertEqual(manager.downloadedBytes, 0, "A corrupted cache and unavailable partial file cannot retain claimed progress")
        XCTAssertEqual(manager.progress, 0)
        XCTAssertEqual(manager.completedFiles, 0)
        await manager.pauseForTermination()
    }

    @MainActor func testCorruptFileNeverBecomesReadyAndRetryRedownloadsIt() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let corrupt = fixture.temporary.appendingPathComponent("corrupt")
        try Data(repeating: 0, count: 8192).write(to: corrupt)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let index = expected == 4096 ? 0 : 1
            let count = attempts.next(for: index)
            return FixtureTransfer(source: index == 1 && count == 1 ? corrupt : fixture.sources[index], destination: destination, mode: .copy)
        })
        manager.start(); await wait(manager, for: .failed)
        XCTAssertEqual(manager.completedFiles, 1)
        XCTAssertNotEqual(manager.status, .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent(fixture.catalog.files[1].path).path))
        XCTAssertEqual(manager.downloadedBytes, 4096)
        manager.retry(); await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 1)
        XCTAssertEqual(attempts.count(for: 1), 2)
    }

    @MainActor func testCancelDoesNotPublishAResultAndCanRestartAfterCleanup() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            let index = expected == 4096 ? 0 : 1
            return FixtureTransfer(source: fixture.sources[index], destination: destination,
                                   mode: attempts.next(for: index) == 1 && index == 0 ? .waitForPause : .copy)
        })
        manager.start(); await wait(manager, for: .downloading)
        manager.cancel(); await waitUntil { manager.canStart }
        XCTAssertEqual(manager.status, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.onnxModels.appendingPathComponent("test.onnx").path))
        manager.retry(); await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 2)
    }

    func testURLSessionDownloadDelegateReportsBytesAndMovesTheCompletedFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ModelTransportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = URL(string: "https://models.example.invalid/\(UUID().uuidString).onnx")!
        let payload = Data(repeating: 0x53, count: 65_536)
        DownloadFixtureProtocol.register(url, status: 200, data: payload)
        defer { DownloadFixtureProtocol.remove(url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let destination = temporary.appendingPathComponent("model.downloaded")
        let transport = ModelFileDownload(destination: destination, expectedBytes: Int64(payload.count), configuration: configuration)
        let report = DownloadByteReport()
        let result = try await transport.download(from: url, resumeData: nil) { report.record($0, $1) }
        XCTAssertEqual(result, destination)
        XCTAssertEqual(try Data(contentsOf: result), payload)
        XCTAssertEqual(report.bytes, Int64(payload.count))
        XCTAssertEqual(report.total, Int64(payload.count))
    }

    func testURLSessionDownloadDelegateRejectsHTTP404WithoutPublishingAFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ModelTransportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = URL(string: "https://models.example.invalid/\(UUID().uuidString).onnx")!
        let payload = Data("not found".utf8)
        DownloadFixtureProtocol.register(url, status: 404, data: payload)
        defer { DownloadFixtureProtocol.remove(url) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        let destination = temporary.appendingPathComponent("model.downloaded")
        let transport = ModelFileDownload(destination: destination, expectedBytes: Int64(payload.count), configuration: configuration)
        do {
            _ = try await transport.download(from: url, resumeData: nil) { _, _ in }
            XCTFail("An HTTP error must fail the transfer")
        } catch { XCTAssertTrue(error.localizedDescription.contains("404")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor private func wait(_ manager: ModelDownloadManager, for status: ModelPreparationStatus) async {
        await waitUntil { manager.status == status }
        XCTAssertEqual(manager.status, status, manager.errorMessage ?? "")
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for download state")
    }
}

private final class TransferAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Int] = [:]
    private var received: Data?
    var lastResume: Data? { lock.lock(); defer { lock.unlock() }; return received }
    func count(for index: Int) -> Int { lock.lock(); defer { lock.unlock() }; return values[index, default: 0] }
    func next(for index: Int) -> Int { lock.lock(); defer { lock.unlock() }; values[index, default: 0] += 1; return values[index]! }
    func record(_ data: Data?) { lock.lock(); received = data; lock.unlock() }
}

private final class ObservationChange: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded = false
    var wasRecorded: Bool { lock.lock(); defer { lock.unlock() }; return recorded }
    func record() { lock.lock(); recorded = true; lock.unlock() }
}

private final class FixtureTransfer: ModelFileTransferring, @unchecked Sendable {
    enum Mode: Equatable, Sendable { case fail, copy, waitForPause, waitWithoutProgress }
    let source: URL
    let destination: URL
    let mode: Mode
    let receivedResume: @Sendable (Data?) -> Void
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return paused || cancelled }
    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return paused ? Data("resume-fixture".utf8) : nil }
    init(source: URL, destination: URL, mode: Mode, receivedResume: @escaping @Sendable (Data?) -> Void = { _ in }) {
        self.source = source; self.destination = destination; self.mode = mode; self.receivedResume = receivedResume
    }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        receivedResume(resumeData)
        if mode == .fail { throw URLError(.notConnectedToInternet) }
        let size = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        if mode != .waitWithoutProgress { progress(size / 2, size) }
        if mode == .waitForPause || mode == .waitWithoutProgress {
            while true {
                if stopped { throw URLError(.cancelled) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        progress(size, size)
        return destination
    }
    private func markPaused() { lock.lock(); paused = true; lock.unlock() }
    func pause() async -> Data? { markPaused(); return resumeData }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

private final class DownloadByteReport: @unchecked Sendable {
    private let lock = NSLock()
    private var written: Int64 = 0
    private var expected: Int64?
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return written }
    var total: Int64? { lock.lock(); defer { lock.unlock() }; return expected }
    func record(_ bytes: Int64, _ total: Int64?) { lock.lock(); written = bytes; expected = total; lock.unlock() }
}

/// Exercises URLSessionDownloadTask itself without making a network request.
private final class DownloadFixtureProtocol: URLProtocol, @unchecked Sendable {
    private struct Response: Sendable { let status: Int; let data: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: Response] = [:]
    nonisolated(unsafe) private static var requests: [URL: Int] = [:]
    static func register(_ url: URL, status: Int, data: Data) {
        lock.lock(); responses[url] = Response(status: status, data: data); requests[url] = 0; lock.unlock()
    }
    static func remove(_ url: URL) { lock.lock(); responses.removeValue(forKey: url); requests.removeValue(forKey: url); lock.unlock() }
    static func requestCount(for url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return requests[url, default: 0] }
    private static func response(for url: URL) -> Response? {
        lock.lock(); defer { lock.unlock() }; requests[url, default: 0] += 1; return responses[url]
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.response(for: url),
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Length": String(fixture.data.count), "Accept-Ranges": "bytes"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for start in stride(from: 0, to: fixture.data.count, by: 8192) {
            client?.urlProtocol(self, didLoad: fixture.data.subdata(in: start..<min(start + 8192, fixture.data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
