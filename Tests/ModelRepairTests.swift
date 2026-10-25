import CryptoKit
import Foundation
import Observation
import XCTest
@testable import Waifu2x

final class ModelRepairTests: XCTestCase {
    @MainActor func testRepairDownloadsOnlyMissingOrCorruptPayloadsAndPreservesVerifiedFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1, 2])
        try Data(repeating: 0, count: fixture.contents[1].count)
            .write(to: fixture.paths.root.appendingPathComponent(fixture.catalog.files[1].path))
        let retained = try fixture.inodes([0, 2])
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests)
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertTrue(manager.isIncrementalRepair)
        XCTAssertEqual(requests.urls, [fixture.repairs[3].sourceURL], "The corrupt duplicate is restored from a verified local copy")
        XCTAssertEqual(manager.totalBytes, fixture.repairs[3].bytes)
        XCTAssertEqual(manager.downloadedBytes, manager.totalBytes)
        XCTAssertEqual(manager.progress, 1)
        XCTAssertEqual(manager.completedFiles, fixture.catalog.files.count)
        XCTAssertEqual(try fixture.inodes([0, 2]), retained, "Verified models must retain their original files")
        try fixture.assertComplete()
    }

    @MainActor func testIdenticalLocalPayloadRepairsAMissingPathWithoutAnyNetworkAccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 2, 3])
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            XCTFail("A verified identical local model must be reused")
            return RepairTransfer(destination: destination, sources: [:], requests: RepairRequests())
        }, repairManifestLoader: { _ in
            XCTFail("Local reuse must not need remote metadata")
            throw URLError(.notConnectedToInternet)
        })
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        try fixture.assertComplete()
    }

    @MainActor func testIdenticalMissingModelsShareOneCompressedPayloadDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 3])
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests)
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL])
        XCTAssertEqual(manager.totalBytes, fixture.repairs[1].bytes)
        try fixture.assertComplete()
    }

    @MainActor func testFirstInstallUsesTheUnifiedArchiveWithoutFetchingTheRepairIndex() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests, loader: { _ in
            XCTFail("A first install must keep its single bundled archive transfer")
            throw URLError(.unsupportedURL)
        })
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertFalse(manager.isIncrementalRepair)
        XCTAssertEqual(requests.urls, [fixture.catalog.archive!.sourceURL])
        try fixture.assertComplete()
    }

    @MainActor func testMissingRepairIndexFallsBackToThePinnedFullArchive() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests, loader: { _ in throw URLError(.fileDoesNotExist) })
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertFalse(manager.isIncrementalRepair)
        XCTAssertEqual(requests.urls, [fixture.catalog.archive!.sourceURL])
        try fixture.assertComplete()
    }

    @MainActor func testCorruptRepairArchiveFallsBackWithoutPublishingUnverifiedModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 3])
        let requests = RepairRequests()
        let damaged = fixture.directory.appendingPathComponent("corrupt-repair.tar.xz")
        var data = try Data(contentsOf: fixture.sources[fixture.repairs[1].sourceURL]!)
        data[0] ^= 1
        try data.write(to: damaged)
        var sources = fixture.sources
        sources[fixture.repairs[1].sourceURL] = damaged
        let repairSources = sources
        let manager = ModelDownloadManager(catalog: fixture.catalog, paths: fixture.paths,
                                           transportFactory: { destination, _ in
            RepairTransfer(destination: destination, sources: repairSources, requests: requests)
        }, repairManifestLoader: { _ in fixture.manifest })
        manager.start()
        try await wait { manager.status == .ready || manager.status == .failed }
        XCTAssertEqual(manager.status, .ready, manager.errorMessage ?? "")
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL, fixture.catalog.archive!.sourceURL])
        XCTAssertFalse(manager.isIncrementalRepair)
        try fixture.assertComplete()
    }

    @MainActor func testPauseKeepsCompletedRepairsAndResumesOnlyTheRemainingPayload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let requests = RepairRequests()
        let first = fixture.manager(requests: requests, pauses: fixture.repairs[3].sourceURL)
        first.start()
        try await wait { first.status == .downloading && first.completedFiles == 3 && first.downloadedBytes > fixture.repairs[1].bytes }
        await first.pauseForTermination()
        XCTAssertEqual(first.status, .paused)
        XCTAssertTrue(first.canStart)
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, 3)

        let next = fixture.manager(requests: requests)
        next.start()
        try await wait { next.status == .ready || next.status == .failed }
        XCTAssertEqual(next.status, .ready, next.errorMessage ?? "")
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL, fixture.repairs[3].sourceURL,
                                       fixture.repairs[3].sourceURL])
        XCTAssertEqual(requests.lastResume, Data("repair-resume".utf8))
        XCTAssertEqual(next.totalBytes, fixture.repairs[3].bytes)
        try fixture.assertComplete()
    }

    @MainActor func testCancellingARepairDoesNotStartAFullDownloadOrUnlockTheWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 3])
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests, pauses: fixture.repairs[1].sourceURL)
        manager.start()
        try await wait { manager.status == .downloading && manager.downloadedBytes > 0 }
        manager.cancel()
        try await wait { manager.canStart }
        XCTAssertEqual(manager.status, .paused)
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL])
        XCTAssertEqual(try ModelStore(catalog: fixture.catalog, paths: fixture.paths).validatedFiles().count, 2)
    }

    @MainActor func testResumedRepairPublishesAConsistentRemainingByteSnapshotBeforeYielding() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let requests = RepairRequests()
        let manager = fixture.manager(requests: requests, pauses: fixture.repairs[3].sourceURL)
        manager.start()
        try await wait { manager.status == .downloading && manager.completedFiles == 3
            && manager.downloadedBytes > fixture.repairs[1].bytes }
        await manager.pauseForTermination()
        let remaining = fixture.repairs[3].bytes
        XCTAssertGreaterThan(manager.downloadedBytes, remaining,
                             "The previous aggregate includes the already installed repair")
        let report = RepairCounterReport()
        withObservationTracking {
            _ = manager.totalBytes
        } onChange: {
            Task { @MainActor in
                report.record(bytes: manager.downloadedBytes, total: manager.totalBytes ?? 0,
                              progress: manager.progress)
            }
        }
        manager.togglePause()
        try await wait { report.snapshot != nil && manager.status == .downloading && manager.totalBytes == remaining }
        let observed = try XCTUnwrap(report.snapshot)
        XCTAssertEqual(observed.total, remaining)
        XCTAssertEqual(observed.bytes, remaining / 2)
        XCTAssertLessThanOrEqual(observed.bytes, observed.total)
        XCTAssertEqual(observed.progress, Double(observed.bytes) / Double(observed.total), accuracy: 0.000001)
        await manager.pauseForTermination()
    }

    func testRepairIndexRejectsChangedCatalogEntriesUnsafeSourcesAndUnboundedMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.catalog.validate()
        let verified = Set([fixture.catalog.files[0].path])
        XCTAssertEqual(try ModelRepairManifest.decode(fixture.manifest, catalog: fixture.catalog, verified: verified).count, 2)
        for change in 0..<6 {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.manifest) as? [String: Any])
            var files = try XCTUnwrap(document["files"] as? [[String: Any]])
            switch change {
            case 0: files.removeLast()
            case 1: files[1]["path"] = "../outside.onnx"
            case 2: files[1]["sha256"] = String(repeating: "0", count: 64)
            case 3:
                var archive = try XCTUnwrap(files[1]["archive"] as? [String: Any])
                archive["sourceURL"] = "https://example.invalid/malicious.tar.xz"
                files[1]["archive"] = archive
            case 4:
                var archive = try XCTUnwrap(files[1]["archive"] as? [String: Any])
                archive["path"] = "../payload.tar.xz"
                files[1]["archive"] = archive
            default: files[2] = files[1]
            }
            document["files"] = files
            let data = try JSONSerialization.data(withJSONObject: document)
            XCTAssertThrowsError(try ModelRepairManifest.decode(data, catalog: fixture.catalog, verified: verified), "case \(change)")
        }
        XCTAssertThrowsError(try ModelRepairManifest.decode(Data(repeating: 0, count: ModelRepairManifest.maximumBytes + 1),
                                                            catalog: fixture.catalog, verified: verified))
        for url in ["https://github.com/other/another/releases/latest/download/Waifu2x-models-v1-repair.json",
                    "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest/download/Waifu2x-models-v1-repair.json?x=1",
                    "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.1/other.json"] {
            let bad = ModelCatalog(schemaVersion: 3, catalogVersion: fixture.catalog.catalogVersion,
                                   files: fixture.catalog.files, archive: fixture.catalog.archive,
                                   repairManifestURL: URL(string: url)!)
            XCTAssertThrowsError(try bad.validate())
        }
    }

    func testRepairArchiveCannotAddUnexpectedFilesOrReplaceVerifiedNeighbours() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 3])
        let retained = try fixture.inodes([0, 3])
        let tree = fixture.directory.appendingPathComponent("malicious-tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try fixture.contents[1].write(to: tree.appendingPathComponent("model"))
        try Data("not a model".utf8).write(to: tree.appendingPathComponent("unlisted"))
        let extra = fixture.directory.appendingPathComponent("extra.tar.xz")
        try Fixture.tar(["-cJf", extra.path, "--format", "ustar", "-C", tree.path, "model", "unlisted"])
        let original = fixture.repairs[1]
        let descriptor = ModelCatalog.File(path: original.path,
                                           bytes: Int64(try extra.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
                                           sha256: try ModelStore.sha256(of: extra), sourceURL: original.sourceURL)
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        XCTAssertThrowsError(try store.installRepair(descriptor, files: [fixture.catalog.files[1]], from: extra))
        XCTAssertEqual(try fixture.inodes([0, 3]), retained)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent(fixture.catalog.files[1].path).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("unlisted").path))
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(6)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "ModelRepairTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Fixture: Sendable {
        let directory: URL
        let paths: ModelPaths
        let catalog: ModelCatalog
        let contents: [Data]
        let repairs: [ModelCatalog.File]
        let sources: [URL: URL]
        let manifest: Data

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Waifu2x-ModelRepairTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            self.directory = directory
            paths = ModelPaths(root: directory.appendingPathComponent("installed/models-v1"))
            contents = [Self.randomBytes(seed: 11, count: 40_960), Self.randomBytes(seed: 29, count: 16_384),
                        Self.randomBytes(seed: 29, count: 16_384), Self.randomBytes(seed: 47, count: 24_576)]
            let names = ["ONNXModels/retained.onnx", "ONNXModels/missing.onnx", "ONNXModels/identical.onnx", "Engine/models-cunet/model.bin"]
            let tree = directory.appendingPathComponent("tree")
            var files: [ModelCatalog.File] = [], repairs: [ModelCatalog.File] = [], sources: [URL: URL] = [:]
            let prefix = URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.2/")!
            for index in names.indices {
                let source = tree.appendingPathComponent(names[index])
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents[index].write(to: source)
                let digest = try ModelStore.sha256(of: source)
                files.append(.init(path: names[index], bytes: Int64(contents[index].count), sha256: digest,
                                   sourceURL: URL(string: "https://models.example.invalid/\(index).onnx")!))
                let filename = "Waifu2x-model-\(digest).tar.xz"
                let archiveURL = prefix.appendingPathComponent(filename)
                let payload = directory.appendingPathComponent(filename)
                if sources[archiveURL] == nil {
                    let payloadTree = directory.appendingPathComponent("payload-\(index)")
                    try FileManager.default.createDirectory(at: payloadTree, withIntermediateDirectories: false)
                    try contents[index].write(to: payloadTree.appendingPathComponent("model"))
                    try Self.tar(["-cJf", payload.path, "--format", "ustar", "-C", payloadTree.path, "model"])
                    sources[archiveURL] = payload
                }
                repairs.append(.init(path: filename,
                                     bytes: Int64(try payload.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
                                     sha256: try ModelStore.sha256(of: payload), sourceURL: archiveURL))
            }
            let full = directory.appendingPathComponent("full.tar.xz")
            try Self.tar(["-cJf", full.path, "--format", "ustar", "-C", tree.path] + names)
            let fullURL = URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/download/v1.0.1/Waifu2x-models-v1.tar.xz")!
            let descriptor = ModelCatalog.File(path: "Waifu2x-models-v1.tar.xz",
                                               bytes: Int64(try full.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
                                               sha256: try ModelStore.sha256(of: full), sourceURL: fullURL)
            sources[fullURL] = full
            catalog = ModelCatalog(schemaVersion: 3, catalogVersion: ModelPaths.catalogVersion, files: files, archive: descriptor,
                                   repairManifestURL: URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/latest/download/Waifu2x-models-v1-repair.json")!)
            self.repairs = repairs
            self.sources = sources
            manifest = try JSONEncoder().encode(ModelRepairManifest(schemaVersion: 1, catalogVersion: ModelPaths.catalogVersion,
                                                                   files: files.enumerated().map { index, file in
                .init(path: file.path, bytes: file.bytes, sha256: file.sha256, archive: repairs[index])
            }))
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func install(_ indexes: [Int]) throws {
            let store = ModelStore(catalog: catalog, paths: paths)
            for index in indexes {
                try store.install(catalog.files[index], from: directory.appendingPathComponent("tree").appendingPathComponent(catalog.files[index].path))
            }
        }

        func inodes(_ indexes: [Int]) throws -> [UInt64] {
            try indexes.map {
                (try FileManager.default.attributesOfItem(atPath: paths.root.appendingPathComponent(catalog.files[$0].path).path)[.systemFileNumber] as! NSNumber).uint64Value
            }
        }

        func assertComplete(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try ModelStore(catalog: catalog, paths: paths).validatedFiles().count, catalog.files.count, file: file, line: line)
            for index in contents.indices {
                XCTAssertEqual(try Data(contentsOf: paths.root.appendingPathComponent(catalog.files[index].path)), contents[index], file: file, line: line)
            }
        }

        @MainActor func manager(requests: RepairRequests, loader: ModelRepairManifestLoader? = nil,
                                pauses: URL? = nil) -> ModelDownloadManager {
            ModelDownloadManager(catalog: catalog, paths: paths, transportFactory: { destination, _ in
                RepairTransfer(destination: destination, sources: sources, requests: requests, pauses: pauses)
            }, repairManifestLoader: loader ?? { _ in manifest })
        }

        private static func randomBytes(seed: UInt64, count: Int) -> Data {
            var state = seed
            return Data((0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 40)
            })
        }

        static func tar(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = arguments
            let errors = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ModelRepairTests.Archive", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
            }
        }
    }
}

private final class RepairRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [URL] = []
    private var resumed: Data?
    var urls: [URL] { lock.withLock { requested } }
    var lastResume: Data? { lock.withLock { resumed } }
    func record(_ url: URL, resume: Data?) { lock.withLock { requested.append(url); resumed = resume } }
}

private final class RepairCounterReport: @unchecked Sendable {
    struct Snapshot { let bytes: Int64; let total: Int64; let progress: Double }
    private let lock = NSLock()
    private var value: Snapshot?
    var snapshot: Snapshot? { lock.withLock { value } }
    func record(bytes: Int64, total: Int64, progress: Double) {
        lock.withLock { value = Snapshot(bytes: bytes, total: total, progress: progress) }
    }
}

private final class RepairTransfer: ModelFileTransferring, @unchecked Sendable {
    let destination: URL
    let sources: [URL: URL]
    let requests: RepairRequests
    let pauses: URL?
    private let lock = NSLock()
    private var stopped = false
    private var savedResume: Data?
    var resumeData: Data? { lock.withLock { savedResume } }

    init(destination: URL, sources: [URL: URL], requests: RepairRequests, pauses: URL? = nil) {
        self.destination = destination
        self.sources = sources
        self.requests = requests
        self.pauses = pauses
    }

    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        requests.record(url, resume: resumeData)
        guard let source = sources[url] else { throw URLError(.fileDoesNotExist) }
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        progress(bytes / 2, bytes)
        if url == pauses {
            while !lock.withLock({ stopped }) { try await Task.sleep(for: .milliseconds(10)) }
            throw URLError(.cancelled)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        progress(bytes, bytes)
        return destination
    }

    func pause() async -> Data? {
        lock.withLock { savedResume = Data("repair-resume".utf8); stopped = true }
        return resumeData
    }

    func cancel() { lock.withLock { stopped = true } }
}
