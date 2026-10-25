import Foundation
import CryptoKit
import XCTest
@testable import Waifu2x

@MainActor
final class FileIntegrityCheckerTests: XCTestCase {
    func testReadOnlyReportDistinguishesMissingLinksTypesSizesAndHashes() throws {
        let fixture = try fixture(names: ["valid.bin", "missing.bin", "size.bin", "hash.bin", "link.bin", "directory.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let root = fixture.paths.root
        try Data("wrong size".utf8).write(to: root.appendingPathComponent("size.bin"))
        try Data(repeating: 0x17, count: fixture.payload.count).write(to: root.appendingPathComponent("hash.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("missing.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("link.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.bin"), withDestinationURL: root.appendingPathComponent("valid.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("directory.bin"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.bin"), withIntermediateDirectories: false)
        let before = try snapshot(root)
        let progress = IntegrityProgressRecorder()
        let findings = try ModelStore(catalog: fixture.catalog, paths: fixture.paths).integrityReport { count, _, _ in progress.record(count) }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: findings.map { ($0.path, $0.reason) }), [
            "missing.bin": .missing, "size.bin": .sizeMismatch, "hash.bin": .hashMismatch,
            "link.bin": .symbolicLink, "directory.bin": .notRegularFile
        ])
        XCTAssertEqual(progress.counts, [0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6])
        XCTAssertEqual(try snapshot(root), before, "Verification must not repair, delete, or add files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.downloadDirectory.path))
    }

    func testReportRefusesSymlinkedParentDirectoriesAndTheCacheRoot() throws {
        let fixture = try fixture(names: ["folder/model.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = ModelStore(catalog: fixture.catalog, paths: fixture.paths)
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: fixture.paths.root.appendingPathComponent("folder"), to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.paths.root.appendingPathComponent("folder"), withDestinationURL: outside)
        XCTAssertEqual(try store.integrityReport().first?.reason, .symbolicLink)
        let realRoot = fixture.directory.appendingPathComponent("real-root")
        try FileManager.default.moveItem(at: fixture.paths.root, to: realRoot)
        try FileManager.default.createSymbolicLink(at: fixture.paths.root, withDestinationURL: realRoot)
        XCTAssertEqual(try store.integrityReport().first?.reason, .symbolicLink)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("model.bin")), fixture.payload)
    }

    func testSuccessfulScanRunsOffMainThreadAndShowsActualCompletedFiles() async throws {
        let fixture = try fixture(names: ["one.bin", "two.bin", "three.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = IntegrityScanGate()
        defer { gate.release() }
        let signatureCalls = IntegritySignatureRecorder()
        let checker = FileIntegrityChecker(catalog: fixture.catalog, paths: fixture.paths, bundleURL: fixture.directory,
                                           signatureChecker: { url in
            signatureCalls.record(url: url, mainThread: Thread.isMainThread)
            return true
        }, modelScanner: { _, progress in
            gate.record(mainThread: Thread.isMainThread)
            progress(1, "two.bin", nil)
            gate.waitForRelease()
            try Task.checkCancellation()
            progress(3, "three.bin", nil)
            return []
        })
        checker.check()
        XCTAssertEqual(checker.status, .checking)
        XCTAssertFalse(checker.canStart)
        try await wait { gate.started && checker.checkedFiles == 1 }
        XCTAssertEqual(checker.totalFiles, 3)
        XCTAssertEqual(checker.progress, 1.0 / 3.0, accuracy: 0.000001)
        XCTAssertEqual(checker.currentName, "two.bin")
        gate.release()
        try await wait { checker.status != .checking && checker.canStart }
        XCTAssertEqual(checker.status, .valid)
        XCTAssertEqual(checker.checkedFiles, 3)
        XCTAssertEqual(checker.progress, 1)
        XCTAssertTrue(checker.issues.isEmpty)
        XCTAssertNotNil(checker.lastChecked)
        XCTAssertEqual(signatureCalls.urls, [fixture.directory])
        XCTAssertFalse(signatureCalls.usedMainThread)
        XCTAssertFalse(gate.usedMainThread)
    }

    func testSignatureFailureAndMissingModelRemainSeparateIssuesWithoutRepair() async throws {
        let fixture = try fixture(names: ["missing.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.removeItem(at: fixture.paths.root)
        let checker = FileIntegrityChecker(catalog: fixture.catalog, paths: fixture.paths, bundleURL: fixture.directory,
                                           signatureChecker: { _ in false })
        checker.check()
        try await wait { checker.status != .checking }
        XCTAssertEqual(checker.status, .issues)
        XCTAssertEqual(checker.issues.count, 2)
        XCTAssertEqual(checker.issues.first?.kind, .application)
        XCTAssertEqual(checker.issues.first?.path, fixture.directory.path)
        XCTAssertEqual(checker.issues.last?.kind, .model)
        XCTAssertEqual(checker.issues.last?.path, "missing.bin")
        XCTAssertEqual(checker.issues.last?.reason, L("模型文件缺失"))
        XCTAssertEqual(checker.checkedFiles, 1)
        XCTAssertEqual(checker.progress, 1)
        XCTAssertNil(checker.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.downloadDirectory.path))
    }

    func testCancellationKeepsProgressAndWaitsForWorkerCleanupBeforeRetry() async throws {
        let fixture = try fixture(names: ["one.bin", "two.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = IntegrityScanGate()
        defer { gate.release() }
        let checker = FileIntegrityChecker(catalog: fixture.catalog, paths: fixture.paths,
                                           signatureChecker: { _ in true }, modelScanner: { _, progress in
            progress(1, "two.bin", nil)
            gate.waitForRelease()
            try Task.checkCancellation()
            return []
        })
        checker.check()
        try await wait { gate.started && checker.checkedFiles == 1 }
        checker.cancel()
        XCTAssertEqual(checker.status, .cancelled)
        XCTAssertEqual(checker.progress, 0.5)
        XCTAssertFalse(checker.canStart, "The cancelled utility worker must finish before another scan can start")
        gate.release()
        try await wait { checker.canStart }
        XCTAssertEqual(checker.status, .cancelled)
        XCTAssertNil(checker.lastChecked)
        XCTAssertNil(checker.errorMessage)
        checker.check()
        try await wait { checker.status != .checking }
        XCTAssertEqual(checker.status, .valid)
    }

    func testReadinessGatePreventsScanningAndScannerErrorsAreReported() async throws {
        let fixture = try fixture(names: ["one.bin"])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var ready = false
        let calls = IntegritySignatureRecorder()
        let checker = FileIntegrityChecker(catalog: fixture.catalog, paths: fixture.paths, canCheck: { ready },
                                           signatureChecker: { url in calls.record(url: url, mainThread: Thread.isMainThread); return true },
                                           modelScanner: { _, _ in throw CocoaError(.fileReadNoPermission) })
        checker.check()
        XCTAssertEqual(checker.status, .idle)
        XCTAssertFalse(checker.canStart)
        XCTAssertTrue(calls.urls.isEmpty)
        ready = true
        XCTAssertTrue(checker.canStart)
        checker.check()
        try await wait { checker.status != .checking }
        XCTAssertEqual(checker.status, .failed)
        XCTAssertNotNil(checker.errorMessage)
        XCTAssertNotNil(checker.lastChecked)
        XCTAssertTrue(checker.issues.isEmpty)
        XCTAssertEqual(checker.progress, 0)
    }

    private struct Fixture {
        let directory: URL
        let paths: ModelPaths
        let catalog: ModelCatalog
        let payload: Data
    }

    private func fixture(names: [String]) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("IntegrityTests-\(UUID().uuidString)")
        let paths = ModelPaths(root: directory.appendingPathComponent("models-v1"))
        let payload = Data(repeating: 0x51, count: 257)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let files = try names.map { name in
            let url = paths.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try payload.write(to: url)
            return ModelCatalog.File(path: name, bytes: Int64(payload.count), sha256: hash,
                                     sourceURL: URL(string: "https://models.example.invalid/\(name)")!)
        }
        return .init(directory: directory, paths: paths,
                     catalog: .init(schemaVersion: 2, catalogVersion: ModelPaths.catalogVersion, files: files), payload: payload)
    }

    private func snapshot(_ root: URL) throws -> [String: String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        var result = [String: String]()
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let name = String(url.path.dropFirst(root.path.count))
            if values.isSymbolicLink == true { result[name] = "symlink:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }
            else if values.isRegularFile == true { result[name] = try ModelStore.sha256(of: url) }
            else { result[name] = "directory" }
        }
        return result
    }

    private func wait(until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(predicate(), "Integrity check did not reach the expected state")
    }
}

private final class IntegrityProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [Int]()
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ count: Int) { lock.lock(); values.append(count); lock.unlock() }
}

private final class IntegritySignatureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [URL]()
    private var wasMainThread = false
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return values }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return wasMainThread }
    func record(url: URL, mainThread: Bool) {
        lock.lock(); values.append(url); wasMainThread = wasMainThread || mainThread; lock.unlock()
    }
}

private final class IntegrityScanGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isReleased = false
    private var didStart = false
    private var wasMainThread = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    var usedMainThread: Bool { condition.lock(); defer { condition.unlock() }; return wasMainThread }
    func record(mainThread: Bool) { condition.lock(); wasMainThread = wasMainThread || mainThread; condition.unlock() }
    func waitForRelease() {
        condition.lock()
        didStart = true
        while !isReleased { condition.wait() }
        condition.unlock()
    }
    func release() { condition.lock(); isReleased = true; condition.broadcast(); condition.unlock() }
}
