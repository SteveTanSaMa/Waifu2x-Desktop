import CryptoKit
import Foundation
import XCTest
@testable import Waifu2x

@MainActor
final class ModelMaintenanceTests: XCTestCase {
    func testStatusDoesNotClaimHealthyUntilStartupActuallyVerifiesModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker)
        XCTAssertEqual(maintenance.diagnosticStatus, .unknown)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        maintenance.startRepair()
        XCTAssertFalse(maintenance.isRepairing)
        maintenance.recordStartupReady()
        XCTAssertEqual(maintenance.diagnosticStatus, .ready)
        XCTAssertTrue(maintenance.modelsCanBeUsed)
        await maintenance.refreshStorage()
        try await wait { maintenance.installedBytes != nil }
        XCTAssertEqual(maintenance.installedBytes, fixture.catalog.totalModelBytes)
    }

    func testApplicationOnlyIssueNeverEnablesModelRepairOrStartsDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let requests = MaintenanceRequests()
        let checker = fixture.checker(signatureValid: false)
        let maintenance = fixture.maintenance(checker: checker, requests: requests)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        XCTAssertEqual(checker.status, .issues)
        XCTAssertEqual(checker.issues.map(\.kind), [.application])
        XCTAssertEqual(checker.modelVerification, .valid)
        XCTAssertFalse(maintenance.hasModelIssues)
        XCTAssertTrue(maintenance.modelsCanBeUsed)
        XCTAssertFalse(maintenance.canStartRepair)
        maintenance.startRepair()
        XCTAssertFalse(maintenance.isRepairing)
        XCTAssertNil(maintenance.downloader)
        XCTAssertTrue(requests.urls.isEmpty)
    }

    func testPartialRepairReservesInferenceGateSynchronouslyAndRefreshesActualStatus() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let retained = try fixture.inode(0)
        let requests = MaintenanceRequests()
        let checker = fixture.checker(signatureValid: false)
        let maintenance = fixture.maintenance(checker: checker, requests: requests)
        checker.canCheck = { [weak maintenance] in maintenance?.isRepairing != true }
        maintenance.recordStartupReady()
        try fixture.removeModel(1)
        checker.check()
        await checker.waitUntilFinished()
        XCTAssertTrue(maintenance.hasModelIssues)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertTrue(maintenance.canStartRepair)
        maintenance.startRepair()
        XCTAssertTrue(maintenance.isRepairing, "Repair reserves the gate before its Task first runs")
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertEqual(maintenance.diagnosticStatus, .repairing)
        checker.check()
        XCTAssertEqual(checker.status, .issues, "A stale enabled menu action cannot start a scan after synchronous reservation")
        XCTAssertFalse(checker.canStart)
        let active = maintenance.downloader
        maintenance.startRepair()
        XCTAssertTrue(active === maintenance.downloader, "A second action cannot create concurrent repair work")
        await maintenance.waitUntilFinished()
        XCTAssertEqual(maintenance.repairOutcome, .completed)
        XCTAssertFalse(maintenance.isRepairing)
        XCTAssertTrue(maintenance.modelsCanBeUsed)
        XCTAssertEqual(maintenance.diagnosticStatus, .ready)
        XCTAssertEqual(checker.modelVerification, .valid)
        XCTAssertEqual(checker.issues.map(\.kind), [.application], "Model repair does not claim to repair the application")
        XCTAssertEqual(requests.urls, [fixture.repairs[1].sourceURL])
        XCTAssertEqual(maintenance.downloader?.downloadedBytes, fixture.repairs[1].bytes)
        XCTAssertEqual(try fixture.inode(0), retained)
        XCTAssertEqual(maintenance.installedBytes, fixture.catalog.totalModelBytes)
        maintenance.startRepair()
        XCTAssertTrue(active === maintenance.downloader, "Healthy models have no reinstall action")
    }

    func testBusyWorkspaceAndStartupReadinessPreventRepair() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let checker = fixture.checker()
        checker.check()
        await checker.waitUntilFinished()
        var workspaceBusy = true
        let maintenance = fixture.maintenance(checker: checker, canRepair: { !workspaceBusy })
        maintenance.startRepair()
        XCTAssertNil(maintenance.downloader, "Startup has not established a usable model baseline")
        maintenance.recordStartupReady()
        XCTAssertFalse(maintenance.canStartRepair)
        maintenance.startRepair()
        XCTAssertFalse(maintenance.isRepairing)
        XCTAssertNil(maintenance.downloader)
        workspaceBusy = false
        XCTAssertTrue(maintenance.canStartRepair)
    }

    func testAnActiveIntegrityWorkerPreventsRepairEvenAfterFindingDamage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let gate = MaintenanceScanGate()
        defer { gate.release() }
        let checker = fixture.checker(scanner: { store, progress in
            let findings = try store.integrityReport(progress: progress)
            gate.wait()
            try Task.checkCancellation()
            return findings
        })
        let maintenance = fixture.maintenance(checker: checker)
        maintenance.recordStartupReady()
        checker.check()
        try await wait { gate.started && checker.modelVerification == .issues }
        XCTAssertFalse(maintenance.modelsCanBeUsed, "A discovered issue blocks inference before the scan ends")
        XCTAssertFalse(maintenance.canStartRepair)
        maintenance.startRepair()
        XCTAssertNil(maintenance.downloader)
        gate.release()
        await checker.waitUntilFinished()
        XCTAssertTrue(maintenance.canStartRepair)
    }

    func testCancellationHoldsInferenceGateUntilTransferCleanupAndRechecksTheCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let control = MaintenanceTransferControl()
        defer { control.release() }
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, control: control)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        maintenance.startRepair()
        try await wait { control.started }
        maintenance.cancelRepair()
        try await wait { control.cancelled }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(maintenance.isRepairing, "Cancelling is not worker cleanup")
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        control.release()
        await maintenance.waitUntilFinished()
        XCTAssertEqual(maintenance.repairOutcome, .cancelled)
        XCTAssertFalse(maintenance.isRepairing)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertEqual(checker.modelVerification, .issues)
        XCTAssertTrue(maintenance.canStartRepair)
        XCTAssertEqual(maintenance.installedBytes, fixture.catalog.files[0].bytes)
    }

    func testImmediateCancellationDoesNotLaunchADownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let requests = MaintenanceRequests()
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, requests: requests)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        maintenance.startRepair()
        maintenance.cancelRepair()
        XCTAssertTrue(maintenance.isRepairing)
        await maintenance.waitUntilFinished()
        XCTAssertTrue(requests.urls.isEmpty)
        XCTAssertEqual(maintenance.repairOutcome, .cancelled)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
    }

    func testTerminationSavesResumeAndWaitsForTransferCleanup() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let control = MaintenanceTransferControl()
        defer { control.release() }
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, control: control)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        maintenance.startRepair()
        try await wait { control.started && (maintenance.downloader?.downloadedBytes ?? 0) > 0 }
        let termination = Task { await maintenance.pauseForTermination() }
        try await wait { control.cancelled }
        XCTAssertTrue(maintenance.isRepairing)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        control.release()
        await termination.value
        XCTAssertFalse(maintenance.isRepairing)
        XCTAssertEqual(maintenance.repairOutcome, .cancelled)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ModelStore(catalog: fixture.catalog, paths: fixture.paths).resumeURL.path))
    }

    func testFailedRepairRefreshesIssuesAndNeverUnlocksInvalidModels() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker, failing: true)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        maintenance.startRepair()
        await maintenance.waitUntilFinished()
        XCTAssertEqual(maintenance.repairOutcome, .failed)
        XCTAssertEqual(checker.modelVerification, .issues)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertTrue(maintenance.hasModelIssues)
        XCTAssertTrue(maintenance.canStartRepair)
    }

    func testFinalIndependentScanDetectsAFileChangedAfterDownloaderVerification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let scans = MaintenanceScanCounter()
        let checker = fixture.checker(scanner: { store, progress in
            if scans.next() == 2 {
                try Data(repeating: 0, count: fixture.contents[0].count)
                    .write(to: fixture.paths.root.appendingPathComponent(fixture.catalog.files[0].path))
            }
            return try store.integrityReport(progress: progress)
        })
        let maintenance = fixture.maintenance(checker: checker)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        maintenance.startRepair()
        await maintenance.waitUntilFinished()
        XCTAssertEqual(maintenance.downloader?.status, .ready)
        XCTAssertEqual(maintenance.repairOutcome, .failed)
        XCTAssertEqual(checker.modelVerification, .issues)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertEqual(checker.issues.first?.path, fixture.catalog.files[0].path)
    }

    func testCancelledRecheckCannotErasePreviouslyDiscoveredModelDamage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0])
        let checker = fixture.checker()
        let maintenance = fixture.maintenance(checker: checker)
        maintenance.recordStartupReady()
        checker.check()
        await checker.waitUntilFinished()
        XCTAssertEqual(checker.modelVerification, .issues)
        checker.check()
        checker.cancel()
        await checker.waitUntilFinished()
        XCTAssertEqual(checker.status, .cancelled)
        XCTAssertEqual(checker.modelVerification, .issues)
        XCTAssertFalse(maintenance.modelsCanBeUsed)
        XCTAssertTrue(maintenance.canStartRepair)
    }

    func testStorageMeasuresActualCatalogFilesAndNeverFollowsSymbolicLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.install([0, 1])
        let changed = Data(repeating: 0x55, count: 89)
        let second = fixture.paths.root.appendingPathComponent(fixture.catalog.files[1].path)
        try changed.write(to: second)
        try Data(repeating: 0x22, count: 10_000).write(to: fixture.paths.root.appendingPathComponent("unlisted.bin"))
        XCTAssertEqual(try ModelStorageFootprint.bytes(catalog: fixture.catalog, paths: fixture.paths),
                       fixture.catalog.files[0].bytes + Int64(changed.count))
        let outside = fixture.directory.appendingPathComponent("outside.bin")
        try Data(repeating: 0x11, count: 20_000).write(to: outside)
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: outside)
        XCTAssertEqual(try ModelStorageFootprint.bytes(catalog: fixture.catalog, paths: fixture.paths), fixture.catalog.files[0].bytes)
        let realFolder = fixture.directory.appendingPathComponent("outside-folder")
        let folder = fixture.paths.root.appendingPathComponent("ONNXModels")
        try FileManager.default.moveItem(at: folder, to: realFolder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: realFolder)
        XCTAssertEqual(try ModelStorageFootprint.bytes(catalog: fixture.catalog, paths: fixture.paths), 0)
        let realRoot = fixture.directory.appendingPathComponent("real-root")
        try FileManager.default.moveItem(at: fixture.paths.root, to: realRoot)
        try FileManager.default.createSymbolicLink(at: fixture.paths.root, withDestinationURL: realRoot)
        XCTAssertEqual(try ModelStorageFootprint.bytes(catalog: fixture.catalog, paths: fixture.paths), 0)
        XCTAssertEqual(try Data(contentsOf: outside).count, 20_000)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "ModelMaintenanceTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    struct Fixture: Sendable {
        let directory: URL
        let paths: ModelPaths
        let catalog: ModelCatalog
        let contents: [Data]
        let repairs: [ModelCatalog.File]
        let sources: [URL: URL]
        let manifest: Data

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("Waifu2x-MaintenanceTests-\(UUID().uuidString)")
            paths = ModelPaths(root: directory.appendingPathComponent("installed/models-v1"))
            contents = [Self.bytes(seed: 7, count: 24_576), Self.bytes(seed: 19, count: 12_288)]
            let names = ["ONNXModels/retained.onnx", "Engine/missing.bin"]
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
                let name = "Waifu2x-model-\(digest).tar.xz"
                let archive = directory.appendingPathComponent(name)
                let payloadTree = directory.appendingPathComponent("payload-\(index)")
                try FileManager.default.createDirectory(at: payloadTree, withIntermediateDirectories: false)
                try contents[index].write(to: payloadTree.appendingPathComponent("model"))
                try Self.tar(["-cJf", archive.path, "--format", "ustar", "-C", payloadTree.path, "model"])
                let url = prefix.appendingPathComponent(name)
                repairs.append(.init(path: name, bytes: Int64(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize!),
                                     sha256: try ModelStore.sha256(of: archive), sourceURL: url))
                sources[url] = archive
            }
            let full = directory.appendingPathComponent("full.tar.xz")
            try Self.tar(["-cJf", full.path, "--format", "ustar", "-C", tree.path] + names)
            let fullURL = prefix.appendingPathComponent("Waifu2x-models-v1.tar.xz")
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
        func removeModel(_ index: Int) throws { try FileManager.default.removeItem(at: paths.root.appendingPathComponent(catalog.files[index].path)) }

        func install(_ indexes: [Int]) throws {
            for index in indexes {
                try ModelStore(catalog: catalog, paths: paths).install(catalog.files[index],
                    from: directory.appendingPathComponent("tree").appendingPathComponent(catalog.files[index].path))
            }
        }

        func inode(_ index: Int) throws -> UInt64 {
            (try FileManager.default.attributesOfItem(atPath: paths.root.appendingPathComponent(catalog.files[index].path).path)[.systemFileNumber] as! NSNumber).uint64Value
        }

        @MainActor func checker(signatureValid: Bool = true, scanner: ModelIntegrityScanning? = nil) -> FileIntegrityChecker {
            FileIntegrityChecker(catalog: catalog, paths: paths, signatureChecker: { _ in signatureValid }, modelScanner: scanner)
        }

        @MainActor func maintenance(checker: FileIntegrityChecker, requests: MaintenanceRequests = .init(),
                                    control: MaintenanceTransferControl? = nil, failing: Bool = false,
                                    canRepair: @escaping @MainActor () -> Bool = { true }) -> ModelMaintenance {
            ModelMaintenance(checker: checker, catalog: catalog, paths: paths, canRepair: canRepair, downloaderFactory: {
                ModelDownloadManager(catalog: catalog, paths: paths, transportFactory: { destination, _ in
                    MaintenanceTransfer(destination: destination, sources: sources, requests: requests,
                                        control: control, failing: failing)
                }, repairManifestLoader: { _ in manifest })
            })
        }

        private static func bytes(seed: UInt64, count: Int) -> Data {
            var state = seed
            return Data((0..<count).map { _ in
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return UInt8(truncatingIfNeeded: state >> 40)
            })
        }

        private static func tar(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw NSError(domain: "MaintenanceFixture.Archive", code: Int(process.terminationStatus)) }
        }
    }
}

final class MaintenanceRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []
    var urls: [URL] { lock.withLock { values } }
    func record(_ url: URL) { lock.withLock { values.append(url) } }
}

final class MaintenanceTransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var didCancel = false
    private var released = false
    private var waiters = [CheckedContinuation<Void, Never>]()
    var started: Bool { lock.withLock { didStart } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func begin() { lock.withLock { didStart = true } }
    func cancel() { lock.withLock { didCancel = true } }
    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let resume = lock.withLock {
                if released { return true }
                waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock {
            released = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}

private final class MaintenanceTransfer: ModelFileTransferring, @unchecked Sendable {
    let destination: URL
    let sources: [URL: URL]
    let requests: MaintenanceRequests
    let control: MaintenanceTransferControl?
    let failing: Bool
    var resumeData: Data? { control?.cancelled == true ? Data("maintenance-resume".utf8) : nil }

    init(destination: URL, sources: [URL: URL], requests: MaintenanceRequests,
         control: MaintenanceTransferControl?, failing: Bool) {
        self.destination = destination
        self.sources = sources
        self.requests = requests
        self.control = control
        self.failing = failing
    }

    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        requests.record(url)
        guard !failing, let source = sources[url] else { throw URLError(.notConnectedToInternet) }
        let bytes = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        progress(bytes / 2, bytes)
        if let control {
            control.begin()
            // Deliberately hold a cancelled worker until the test releases it.
            await control.waitForRelease()
            if control.cancelled { throw URLError(.cancelled) }
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        progress(bytes, bytes)
        return destination
    }

    func pause() async -> Data? { control?.cancel(); return resumeData }
    func cancel() { control?.cancel() }
}

private final class MaintenanceScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var didStart = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func wait() {
        condition.lock()
        didStart = true
        while !released { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}

private final class MaintenanceScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
