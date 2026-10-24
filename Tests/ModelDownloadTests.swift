import XCTest
import Foundation
import Observation
@testable import Waifu2x

final class ModelDownloadTests: XCTestCase {
    private struct Fixture {
        let temporary: URL
        let sources: [URL]
        let archive: URL
        let catalog: ModelCatalog
        let paths: ModelPaths
        let contents: [Data]
    }

    private func fixture(firstFileBytes: Int = 4096) throws -> Fixture {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ModelDownloadTests-\(UUID().uuidString)")
        let tree = temporary.appendingPathComponent("archive-tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        let contents = [Data(repeating: 0x53, count: firstFileBytes), Data(repeating: 0x71, count: 8192)]
        let names = ["ONNXModels/test.onnx", "Engine/models-cunet/noise0_model.bin"]
        var sources = [URL](), files = [ModelCatalog.File]()
        for index in contents.indices {
            let source = tree.appendingPathComponent(names[index])
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents[index].write(to: source)
            sources.append(source)
            files.append(.init(path: names[index], bytes: Int64(contents[index].count), sha256: try ModelStore.sha256(of: source),
                               sourceURL: URL(string: "https://models.example.invalid/\(UUID().uuidString)/\(index).onnx")!))
        }
        let archive = temporary.appendingPathComponent("models.tar.xz")
        // Include legitimate parent-directory entries as well as an explicit model-file list.
        try runTar(["-cJf", archive.path, "--format", "ustar", "--no-recursion", "-C", tree.path,
                    "ONNXModels", "Engine", "Engine/models-cunet"] + names)
        let archiveFile = try descriptor(for: archive)
        return Fixture(temporary: temporary, sources: sources, archive: archive,
                       catalog: .init(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion, files: files, archive: archiveFile),
                       paths: .init(root: temporary.appendingPathComponent("installed/models-v1")), contents: contents)
    }

    private func descriptor(for archive: URL, sourceURL: URL? = nil) throws -> ModelCatalog.File {
        .init(path: "models.tar.xz", bytes: Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
              sha256: try ModelStore.sha256(of: archive),
              sourceURL: sourceURL ?? URL(string: "https://models.example.invalid/\(UUID().uuidString)/models.tar.xz")!)
    }

    private func replacingArchive(in fixture: Fixture, with archive: URL) throws -> ModelCatalog {
        .init(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion, files: fixture.catalog.files,
              archive: try descriptor(for: archive))
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
        let duplicated = ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion,
                                      files: fixture.catalog.files + fixture.catalog.files, archive: fixture.catalog.archive)
        XCTAssertThrowsError(try duplicated.validate())
        let original = fixture.catalog.files[0]
        let unsafe = ModelCatalog.File(path: original.path, bytes: original.bytes, sha256: original.sha256,
                                       sourceURL: URL(string: "http://models.example.invalid/test.onnx")!)
        XCTAssertThrowsError(try ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion,
                                              files: [unsafe], archive: fixture.catalog.archive).validate())
    }

    func testCatalogRequiresASingleHTTPSArchiveFilenameForSchemaThree() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        XCTAssertThrowsError(try ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion,
                                              files: fixture.catalog.files).validate())
        let original = try XCTUnwrap(fixture.catalog.archive)
        for path in ["nested/models.tar.xz", "../models.tar.xz", "/models.tar.xz", "models.zip"] {
            let archive = ModelCatalog.File(path: path, bytes: original.bytes, sha256: original.sha256, sourceURL: original.sourceURL)
            XCTAssertThrowsError(try ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion,
                                                  files: fixture.catalog.files, archive: archive).validate(), path)
        }
        for url in [URL(string: "http://models.example.invalid/models.tar.xz")!, fixture.archive] {
            let archive = ModelCatalog.File(path: original.path, bytes: original.bytes, sha256: original.sha256, sourceURL: url)
            XCTAssertThrowsError(try ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion,
                                                  files: fixture.catalog.files, archive: archive).validate())
        }
    }

    func testStoreRepairsCorruptFilesAtomicallyAndRejectsBadDownloads() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let legacy = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: fixture.catalog.files)
        let store = ModelStore(catalog: legacy, paths: fixture.paths)
        try FileManager.default.createDirectory(at: fixture.paths.onnxModels, withIntermediateDirectories: true)
        let output = fixture.paths.root.appendingPathComponent(legacy.files[0].path)
        try Data(repeating: 0, count: 4096).write(to: output)
        XCTAssertTrue(try store.validatedFiles().isEmpty)
        try store.install(legacy.files[0], from: fixture.sources[0])
        XCTAssertEqual(try Data(contentsOf: output), fixture.contents[0])
        let corrupt = fixture.temporary.appendingPathComponent("corrupt")
        try Data(repeating: 0, count: 8192).write(to: corrupt)
        XCTAssertThrowsError(try store.install(legacy.files[1], from: corrupt))
        XCTAssertEqual(try store.validatedFiles(), Set([legacy.files[0].path]))
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

    func testArchiveInstallVerifiesEveryFileBeforeReplacingTheCache() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let obsolete = fixture.paths.root.appendingPathComponent("obsolete.bin")
        try Data("old cache".utf8).write(to: obsolete)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let report = ArchiveValidationReport()
        try store.installArchive(from: fixture.archive) { report.record($0, $1) }
        XCTAssertEqual(try store.validatedFiles(), Set(fixture.catalog.files.map(\.path)))
        for index in fixture.contents.indices {
            XCTAssertEqual(try Data(contentsOf: fixture.paths.root.appendingPathComponent(fixture.catalog.files[index].path)), fixture.contents[index])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path), "The complete bundle replaces the previous cache as one unit")
        XCTAssertEqual(report.completed, fixture.catalog.files.count)
        XCTAssertEqual(Set(report.names), Set(fixture.catalog.files.map(\.path)))
    }

    func testArchiveSizeAndHashFailuresPreserveThePreviousCache() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        var corrupt = try Data(contentsOf: fixture.archive)
        corrupt[0] ^= 0x01
        let badHash = fixture.temporary.appendingPathComponent("wrong-hash.tar.xz")
        try corrupt.write(to: badHash)
        let badSize = fixture.temporary.appendingPathComponent("wrong-size.tar.xz")
        try (corrupt + Data([0])).write(to: badSize)
        for archive in [badHash, badSize] {
            XCTAssertThrowsError(try store.installArchive(from: archive))
            XCTAssertEqual(try store.validatedFiles(), Set([fixture.catalog.files[0].path]))
            XCTAssertEqual(try Data(contentsOf: fixture.paths.root.appendingPathComponent(fixture.catalog.files[0].path)), fixture.contents[0])
        }
    }

    func testArchiveRejectsUnsafeIncompleteAndUnverifiedEntriesWithoutChangingTheCache() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let first = ArchiveEntry(path: fixture.catalog.files[0].path, data: fixture.contents[0])
        let second = ArchiveEntry(path: fixture.catalog.files[1].path, data: fixture.contents[1])
        let cases: [(String, [ArchiveEntry])] = [
            ("traversal", [first, second, .init(path: "../escaped.bin", data: Data([1]))]),
            ("absolute", [first, second, .init(path: fixture.temporary.appendingPathComponent("escaped.bin").path, data: Data([1]))]),
            ("extra", [first, second, .init(path: "Engine/unlisted.bin", data: Data([1]))]),
            ("unexpected-directory", [first, second, .init(path: "Engine/unlisted", type: "5")]),
            ("duplicate", [first, second, first]),
            ("symlink", [first, .init(path: second.path, type: "2", link: first.path)]),
            ("hardlink", [first, .init(path: second.path, type: "1", link: first.path)]),
            ("wrong-size", [first, .init(path: second.path, data: Data([0]))]),
            ("wrong-hash", [first, .init(path: second.path, data: Data(repeating: 0, count: fixture.contents[1].count))]),
            ("missing", [first])
        ]
        for (name, entries) in cases {
            let archive = try makeArchive(entries: entries, in: fixture.temporary, name: name)
            let catalog = try replacingArchive(in: fixture, with: archive)
            XCTAssertThrowsError(try ModelStore(catalog: catalog, paths: fixture.paths).installArchive(from: archive), name)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.root.appendingPathComponent(first.path)), fixture.contents[0], name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent(second.path).path), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.temporary.appendingPathComponent("escaped.bin").path), name)
        }
    }

    func testBundledCatalogContainsAllNinetyNineModelsAndOneReleaseArchive() throws {
        let catalog = try ModelCatalog.load()
        try catalog.validate()
        XCTAssertEqual(catalog.schemaVersion, 3)
        XCTAssertEqual(catalog.files.count, 99)
        XCTAssertEqual(catalog.files.filter { $0.path.hasPrefix("ONNXModels/") }.count, 71)
        XCTAssertEqual(catalog.files.filter { $0.path.hasPrefix("Engine/models-") }.count, 28)
        XCTAssertFalse(catalog.files.contains { $0.path.contains("waifu2x-ncnn-vulkan") })
        XCTAssertGreaterThan(catalog.totalModelBytes, 1_000_000_000)
        let archive = try XCTUnwrap(catalog.archive)
        XCTAssertTrue(archive.path.hasSuffix(".tar.xz"))
        XCTAssertFalse(archive.path.contains("/"))
        XCTAssertEqual(archive.sourceURL.scheme, "https")
        XCTAssertEqual(archive.sourceURL.host, "github.com")
        XCTAssertTrue(archive.sourceURL.path.contains("/releases/download/"))
        XCTAssertGreaterThan(archive.bytes, 0)
    }

    @MainActor func testVerifiedCacheIsReadyOfflineAndReportsTheArchiveBytes() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0, 1], in: fixture)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { _, _ in
            XCTFail("A verified cache must not download")
            return FixtureTransfer(source: fixture.archive, destination: fixture.archive, mode: .copy)
        })
        manager.start(); await wait(manager, for: .ready)
        XCTAssertEqual(manager.completedFiles, fixture.catalog.files.count)
        XCTAssertEqual(manager.totalBytes, fixture.catalog.archive?.bytes)
        XCTAssertEqual(manager.downloadedBytes, fixture.catalog.archive?.bytes)
        XCTAssertEqual(manager.progress, 1)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor func testLegacyCatalogOnlyStartsWhenItsEntireCacheIsAlreadyVerified() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let legacy = ModelCatalog(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: fixture.catalog.files)
        let factory: ModelDownloadTransportFactory = { _, _ in
            XCTFail("A legacy catalog cannot fall back to individual source downloads")
            return FixtureTransfer(source: fixture.archive, destination: fixture.archive, mode: .copy)
        }
        let missing = ModelDownloadManager(catalog: legacy, paths: fixture.paths, transportFactory: factory)
        missing.start(); await wait(missing, for: .failed)
        XCTAssertNotNil(missing.errorMessage)
        try install([0, 1], in: fixture)
        let complete = ModelDownloadManager(catalog: legacy, paths: fixture.paths, transportFactory: factory)
        complete.start(); await wait(complete, for: .ready)
        XCTAssertEqual(complete.completedFiles, fixture.catalog.files.count)
    }

    @MainActor func testPreviouslyDownloadedVerifiedBundleFinishesExtractionOffline() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let pending = store.pendingURL(for: archive)
        try FileManager.default.createDirectory(at: pending.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.archive, to: pending)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { _, _ in
            XCTFail("A complete verified bundle retained during extraction must work offline")
            return FixtureTransfer(source: fixture.archive, destination: fixture.archive, mode: .fail)
        })
        manager.start(); await wait(manager, for: .ready)
        XCTAssertEqual(manager.downloadedBytes, archive.bytes)
        XCTAssertEqual(manager.completedFiles, fixture.catalog.files.count)
        XCTAssertEqual(try store.validatedFiles(), Set(fixture.catalog.files.map(\.path)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    @MainActor func testManagerRequestsOnlyTheBundleEvenWhenSomeFilesAreAlreadyCached() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        DownloadFixtureProtocol.register(archive.sourceURL, status: 200, data: try Data(contentsOf: fixture.archive))
        for file in fixture.catalog.files { DownloadFixtureProtocol.register(file.sourceURL, status: 404, data: Data()) }
        defer {
            DownloadFixtureProtocol.remove(archive.sourceURL)
            fixture.catalog.files.forEach { DownloadFixtureProtocol.remove($0.sourceURL) }
        }
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DownloadFixtureProtocol.self]
            return ModelFileDownload(destination: destination, expectedBytes: expected, configuration: configuration)
        })
        manager.start(); manager.start(); await wait(manager, for: .ready)
        XCTAssertEqual(DownloadFixtureProtocol.requestCount(for: archive.sourceURL), 1)
        for file in fixture.catalog.files { XCTAssertEqual(DownloadFixtureProtocol.requestCount(for: file.sourceURL), 0) }
        XCTAssertEqual(manager.downloadedBytes, archive.bytes)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, fixture.catalog.files.count)
    }

    @MainActor func testBundleFailureRetriesTheSingleArchiveAndRetainsVerifiedCache() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination,
                                   mode: attempts.next(for: 0) == 1 ? .fail : .copy, requestedURL: { attempts.record($0) })
        })
        manager.start(); await wait(manager, for: .failed)
        XCTAssertEqual(manager.completedFiles, 1)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles(), Set([fixture.catalog.files[0].path]))
        manager.retry(); await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 2)
        XCTAssertEqual(attempts.urls, [archive.sourceURL, archive.sourceURL])
        XCTAssertEqual(manager.completedFiles, fixture.catalog.files.count)
        XCTAssertEqual(manager.progress, 1)
    }

    @MainActor func testProgressUsesCompressedNetworkBytesWithoutAddingCachedModelBytes() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination, mode: .waitForPause)
        })
        manager.start()
        await waitUntil { manager.status == .downloading && manager.downloadedBytes == archive.bytes / 2 }
        XCTAssertEqual(manager.totalBytes, archive.bytes)
        XCTAssertNotEqual(manager.totalBytes, fixture.catalog.totalModelBytes)
        XCTAssertEqual(manager.completedFiles, 1)
        XCTAssertEqual(manager.progress, Double(archive.bytes / 2) / Double(archive.bytes), accuracy: 0.00001)
        await manager.pauseForTermination()
    }

    @MainActor func testTerminationPersistsArchiveResumeAndANewManagerReusesIt() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let first = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination, mode: .waitForPause)
        })
        first.start(); await waitUntil { first.status == .downloading && first.downloadedBytes == archive.bytes / 2 }
        await first.pauseForTermination()
        XCTAssertEqual(first.status, .paused)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.resumeURL)) as? [String: Any])
        XCTAssertEqual(record["catalogIdentity"] as? String, fixture.catalog.identity)
        XCTAssertEqual((record["file"] as? [String: Any])?["path"] as? String, archive.path)
        XCTAssertEqual(record["downloadedBytes"] as? Int64, archive.bytes / 2)
        let received = TransferAttempts()
        let next = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination, mode: .copy,
                                   receivedResume: { received.recordResume($0) })
        })
        next.start(); await wait(next, for: .ready)
        XCTAssertEqual(received.lastResume, Data("resume-fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeURL.path))
    }

    @MainActor func testResumeCannotCrossArchiveSourceOrCatalogMemberIdentity() async throws {
        for changesArchiveSource in [true, false] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
            let archive = try XCTUnwrap(fixture.catalog.archive)
            let first = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
                FixtureTransfer(source: fixture.archive, destination: destination, mode: .waitForPause)
            })
            first.start(); await waitUntil { first.downloadedBytes == archive.bytes / 2 }
            await first.pauseForTermination()
            var files = fixture.catalog.files
            var changedArchive = archive
            let changedURL = URL(string: "https://models.example.invalid/changed-source")!
            if changesArchiveSource {
                changedArchive = .init(path: archive.path, bytes: archive.bytes, sha256: archive.sha256, sourceURL: changedURL)
            } else {
                let original = files[0]
                files[0] = .init(path: original.path, bytes: original.bytes, sha256: original.sha256, sourceURL: changedURL)
            }
            let changed = ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion, files: files, archive: changedArchive)
            XCTAssertNotEqual(changed.identity, fixture.catalog.identity)
            let received = TransferAttempts()
            let next = ModelDownloadManager(catalog: changed, paths: fixture.paths, transportFactory: { destination, _ in
                FixtureTransfer(source: fixture.archive, destination: destination, mode: .copy, receivedResume: { received.recordResume($0) })
            })
            next.start(); await wait(next, for: .ready)
            XCTAssertEqual(received.resumeCalls, 1)
            XCTAssertNil(received.lastResume)
        }
    }

    @MainActor func testPauseCompletionInvalidatesTheResumeButtonAvailability() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: fixture.archive, destination: destination, mode: .waitForPause)
        })
        manager.start(); await waitUntil { manager.downloadedBytes == archive.bytes / 2 }
        manager.togglePause()
        let change = ObservationChange()
        withObservationTracking { XCTAssertFalse(manager.canStart) } onChange: { change.record() }
        await manager.pauseForTermination()
        XCTAssertTrue(manager.canStart)
        XCTAssertTrue(change.wasRecorded, "Completing resume-data persistence must enable the observed Resume action")
    }

    @MainActor func testSameManagerResumeKeepsTheDrawingStableThroughoutCacheVerification() async throws {
        let fixture = try fixture(firstFileBytes: 16 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination, mode: .waitForPause)
        })
        manager.start(); await waitUntil { manager.status == .downloading && manager.downloadedBytes == archive.bytes / 2 }
        await manager.pauseForTermination()
        let snapshot = manager.progress
        manager.togglePause()
        XCTAssertEqual(manager.status, .checking)
        var observations = 0
        while manager.status == .checking, observations < 500 {
            XCTAssertEqual(manager.downloadedBytes, archive.bytes / 2)
            XCTAssertEqual(manager.progress, snapshot)
            XCTAssertEqual(manager.completedFiles, 1)
            observations += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThan(observations, 0)
        XCTAssertEqual(manager.status, .downloading)
        XCTAssertEqual(manager.downloadedBytes, archive.bytes / 2)
        XCTAssertEqual(manager.progress, snapshot)
        await manager.pauseForTermination()
    }

    @MainActor func testResumeReconcilesMissingPartialDataAndCorruptCacheAfterTheFullScan() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let archive = try XCTUnwrap(fixture.catalog.archive)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, expected in
            XCTAssertEqual(expected, archive.bytes)
            return FixtureTransfer(source: fixture.archive, destination: destination,
                                   mode: attempts.next(for: 0) == 1 ? .waitForPause : .waitWithoutProgress)
        })
        manager.start(); await waitUntil { manager.downloadedBytes == archive.bytes / 2 }
        await manager.pauseForTermination()
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        try FileManager.default.removeItem(at: store.resumeURL)
        try Data(repeating: 0, count: 4096).write(to: fixture.paths.root.appendingPathComponent(fixture.catalog.files[0].path))
        manager.togglePause()
        XCTAssertEqual(manager.status, .checking)
        XCTAssertEqual(manager.downloadedBytes, archive.bytes / 2, "Keep the actual byte snapshot until verification finishes")
        await wait(manager, for: .downloading)
        XCTAssertEqual(manager.downloadedBytes, 0)
        XCTAssertEqual(manager.progress, 0)
        XCTAssertEqual(manager.completedFiles, 0)
        await manager.pauseForTermination()
    }

    @MainActor func testBadArchiveHashNeverBecomesReadyAndRetryPreservesThePreviousCache() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        var data = try Data(contentsOf: fixture.archive)
        data[0] ^= 0x01
        let corrupt = fixture.temporary.appendingPathComponent("corrupt.tar.xz")
        try data.write(to: corrupt)
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: attempts.next(for: 0) == 1 ? corrupt : fixture.archive, destination: destination, mode: .copy)
        })
        manager.start(); await wait(manager, for: .failed)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles(), Set([fixture.catalog.files[0].path]))
        manager.retry(); await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 2)
        XCTAssertEqual(manager.completedFiles, fixture.catalog.files.count)
    }

    @MainActor func testBadArchiveEntryNeverPublishesAPartiallyReplacedCache() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        try install([0], in: fixture)
        let entries = [ArchiveEntry(path: fixture.catalog.files[0].path, data: fixture.contents[0]),
                       ArchiveEntry(path: fixture.catalog.files[1].path, data: Data(repeating: 0, count: fixture.contents[1].count))]
        let archive = try makeArchive(entries: entries, in: fixture.temporary, name: "bad-entry")
        let catalog = try replacingArchive(in: fixture, with: archive)
        let manager = ModelDownloadManager(catalog: catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: archive, destination: destination, mode: .copy)
        })
        manager.start(); await wait(manager, for: .failed)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.root.appendingPathComponent(catalog.files[0].path)), fixture.contents[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent(catalog.files[1].path).path))
    }

    @MainActor func testCancelDoesNotPublishAResultAndCanRestartAfterCleanup() async throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.temporary) }
        let attempts = TransferAttempts()
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths, transportFactory: { destination, _ in
            FixtureTransfer(source: fixture.archive, destination: destination,
                            mode: attempts.next(for: 0) == 1 ? .waitForPause : .copy)
        })
        manager.start(); await wait(manager, for: .downloading)
        manager.cancel(); await waitUntil { manager.canStart }
        XCTAssertEqual(manager.status, .paused)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.path))
        manager.retry(); await wait(manager, for: .ready)
        XCTAssertEqual(attempts.count(for: 0), 2)
    }

    func testURLSessionDownloadDelegateReportsBytesAndMovesTheCompletedFile() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ModelTransportTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = URL(string: "https://models.example.invalid/\(UUID().uuidString).tar.xz")!
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
        let url = URL(string: "https://models.example.invalid/\(UUID().uuidString).tar.xz")!
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

    private struct ArchiveEntry {
        let path: String
        var data = Data()
        var type = "0"
        var link = ""
    }

    /// A tiny ustar writer lets malformed archives exercise the real extractor without Python.
    private func makeArchive(entries: [ArchiveEntry], in temporary: URL, name: String) throws -> URL {
        var tar = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ value: String, at offset: Int, count: Int) {
                for (index, byte) in value.utf8.prefix(count).enumerated() { header[offset + index] = byte }
            }
            field(entry.path, at: 0, count: 100)
            field("0000644\0", at: 100, count: 8)
            field("0000000\0", at: 108, count: 8)
            field("0000000\0", at: 116, count: 8)
            field(String(format: "%011o", entry.data.count) + "\0", at: 124, count: 12)
            field("00000000000\0", at: 136, count: 12)
            field("        ", at: 148, count: 8)
            field(entry.type, at: 156, count: 1)
            field(entry.link, at: 157, count: 100)
            field("ustar\0", at: 257, count: 6)
            field("00", at: 263, count: 2)
            let checksum = header.reduce(0) { $0 + Int($1) }
            field(String(format: "%06o", checksum) + "\0 ", at: 148, count: 8)
            tar.append(contentsOf: header)
            tar.append(entry.data)
            tar.append(Data(repeating: 0, count: (512 - entry.data.count % 512) % 512))
        }
        tar.append(Data(repeating: 0, count: 1024))
        let raw = temporary.appendingPathComponent("\(name).tar")
        try tar.write(to: raw)
        let archive = temporary.appendingPathComponent("\(name).tar.xz")
        // -P preserves malicious names while re-encoding, so rejection belongs to ModelStore.
        try runTar(["-cJf", archive.path, "--format", "ustar", "-P", "@" + raw.path])
        return archive
    }

    private func runTar(_ arguments: [String]) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ModelArchiveFixture", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
        }
    }
}

private final class TransferAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Int] = [:]
    private var received: Data?
    private var calls = 0
    private var requested: [URL] = []
    var lastResume: Data? { lock.lock(); defer { lock.unlock() }; return received }
    var resumeCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return requested }
    func count(for index: Int) -> Int { lock.lock(); defer { lock.unlock() }; return values[index, default: 0] }
    func next(for index: Int) -> Int { lock.lock(); defer { lock.unlock() }; values[index, default: 0] += 1; return values[index]! }
    func recordResume(_ data: Data?) { lock.lock(); received = data; calls += 1; lock.unlock() }
    func record(_ url: URL) { lock.lock(); requested.append(url); lock.unlock() }
}

private final class ArchiveValidationReport: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var paths: [String] = []
    var completed: Int { lock.lock(); defer { lock.unlock() }; return count }
    var names: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func record(_ completed: Int, _ name: String) { lock.lock(); count = completed; paths.append(name); lock.unlock() }
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
    let requestedURL: @Sendable (URL) -> Void
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return paused || cancelled }
    var resumeData: Data? { lock.lock(); defer { lock.unlock() }; return paused ? Data("resume-fixture".utf8) : nil }
    init(source: URL, destination: URL, mode: Mode, receivedResume: @escaping @Sendable (Data?) -> Void = { _ in },
         requestedURL: @escaping @Sendable (URL) -> Void = { _ in }) {
        self.source = source; self.destination = destination; self.mode = mode
        self.receivedResume = receivedResume; self.requestedURL = requestedURL
    }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        receivedResume(resumeData); requestedURL(url)
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
