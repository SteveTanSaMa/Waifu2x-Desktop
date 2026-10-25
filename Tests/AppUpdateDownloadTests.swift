import CryptoKit
import Foundation
import XCTest
@testable import Waifu2x

@MainActor
final class AppUpdateDownloadTests: XCTestCase {
    func testDeltaReconstructsTheVerifiedAppAndNeverChangesTheInstalledBundle() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let recorder = UpdateDownloadRecorder()
        let downloader = fixture.downloader(recorder: recorder)
        downloader.start(fixture.release)
        try await wait { downloader.status == .ready || downloader.status == .failed }
        XCTAssertEqual(downloader.status, .ready, downloader.errorMessage ?? "")
        XCTAssertTrue(downloader.usesDelta)
        XCTAssertFalse(downloader.fellBackToFull)
        let app = try XCTUnwrap(downloader.stagedApplication)
        XCTAssertTrue(try AppUpdateStager.matches(app, files: fixture.catalog.files))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/obsolete.txt").path))
        XCTAssertTrue(try AppUpdateStager.matches(fixture.installed, files: fixture.catalog.deltas[0].baseFiles))
        let requests = await recorder.paths
        XCTAssertEqual(requests, [fixture.catalog.deltas[0].archive.path])
        XCTAssertEqual(downloader.downloadedBytes, fixture.catalog.deltas[0].archive.bytes)
        XCTAssertEqual(downloader.progress, 1)
    }

    func testModifiedBaseFallsBackToTheFullZipWithoutDownloadingADelta() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let source = fixture.installed.appendingPathComponent("Contents/Resources/shared.dat")
        var modified = try Data(contentsOf: source)
        modified[0] ^= 1
        try modified.write(to: source)
        let recorder = UpdateDownloadRecorder()
        let downloader = fixture.downloader(recorder: recorder)
        downloader.start(fixture.release)
        try await wait { downloader.status == .ready || downloader.status == .failed }
        XCTAssertEqual(downloader.status, .ready, downloader.errorMessage ?? "")
        XCTAssertFalse(downloader.usesDelta)
        let requests = await recorder.paths
        XCTAssertEqual(requests, [fixture.catalog.full.path])
        XCTAssertEqual(try Data(contentsOf: source), modified, "An update must not repair or replace the running app")
    }

    func testCorruptDeltaAutomaticallyRetriesWithTheVerifiedFullZip() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        var damaged = fixture.delta
        damaged[damaged.count / 2] ^= 1
        let recorder = UpdateDownloadRecorder()
        let downloader = fixture.downloader(recorder: recorder, deltaPayload: damaged)
        downloader.start(fixture.release)
        try await wait { downloader.status == .ready || downloader.status == .failed }
        XCTAssertEqual(downloader.status, .ready, downloader.errorMessage ?? "")
        XCTAssertFalse(downloader.usesDelta)
        XCTAssertTrue(downloader.fellBackToFull)
        let requests = await recorder.paths
        XCTAssertEqual(requests, [fixture.catalog.deltas[0].archive.path, fixture.catalog.full.path])
        XCTAssertTrue(try AppUpdateStager.matches(try XCTUnwrap(downloader.stagedApplication), files: fixture.catalog.files))
    }

    func testFullZipDigestAndFinalSignatureFailuresNeverExposeAReadyApplication() async throws {
        for signatureValid in [false, true] {
            let fixture = try UpdateDownloadFixture()
            defer { fixture.remove() }
            var full = fixture.full
            if signatureValid { full[full.count / 2] ^= 1 }
            let recorder = UpdateDownloadRecorder()
            let downloader = fixture.downloader(recorder: recorder, fullPayload: full,
                                               currentVersion: "0.9.0", signatureValid: signatureValid)
            downloader.start(fixture.release)
            try await wait { downloader.status == .failed }
            XCTAssertNil(downloader.stagedApplication)
            XCTAssertNotNil(downloader.errorMessage)
            XCTAssertTrue(try AppUpdateStager.matches(fixture.installed, files: fixture.catalog.deltas[0].baseFiles))
            let children = (try? FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)) ?? []
            XCTAssertTrue(children.isEmpty, "A failed update must remove its partial candidate")
        }
    }

    func testCancellationWaitsForCleanupAndLeavesInstalledAppUntouched() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let gate = StartupTransferGate()
        let downloader = fixture.downloader(recorder: UpdateDownloadRecorder(), gate: gate)
        downloader.start(fixture.release)
        try await wait { downloader.status == .downloading }
        downloader.cancel()
        XCTAssertEqual(downloader.status, .cancelled)
        try await wait { downloader.canStart }
        XCTAssertNil(downloader.stagedApplication)
        XCTAssertTrue(try AppUpdateStager.matches(fixture.installed, files: fixture.catalog.deltas[0].baseFiles))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: fixture.cache.path)).isEmpty)
    }

    func testCheckingAgainKeepsThePreparedApplicationsVersionIdentity() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let downloader = fixture.downloader(recorder: UpdateDownloadRecorder())
        downloader.start(fixture.release)
        try await wait { downloader.status == .ready || downloader.status == .failed }
        XCTAssertEqual(downloader.status, .ready, downloader.errorMessage ?? "")
        let payload = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v3.0.0", "html_url": "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v3.0.0",
            "draft": false, "prerelease": false
        ])
        let response = HTTPURLResponse(url: AppInformation.latestReleaseAPI, statusCode: 200, httpVersion: "HTTP/2", headerFields: nil)!
        let suite = "Waifu2x.UpdateDownloadCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults,
                                       transport: { _ in (payload, response) }, downloader: downloader)
        checker.check()
        try await wait { checker.status == .available }
        XCTAssertEqual(checker.availableRelease?.version, "3.0.0")
        XCTAssertEqual(downloader.targetVersion, "2.0.0", "An older prepared candidate must keep its own displayed version")
        XCTAssertEqual(downloader.targetBuild, "3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(downloader.stagedApplication).path))
    }

    func testMetadataChecksDoNotInterruptAnActiveDownload() async throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let downloader = fixture.downloader(recorder: UpdateDownloadRecorder(), gate: StartupTransferGate())
        downloader.start(fixture.release)
        try await wait { downloader.status == .downloading }
        let suite = "Waifu2x.UpdateDownloadCheckTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = AppUpdateChecker(currentVersion: "1.0.1", defaults: defaults,
                                       transport: { _ in
            XCTFail("Checking metadata during an update must not start another request")
            throw URLError(.cancelled)
        }, downloader: downloader)
        checker.check()
        XCTAssertEqual(checker.status, .idle)
        XCTAssertEqual(downloader.status, .downloading)
        downloader.cancel()
        try await wait { downloader.canStart }
    }

    func testCatalogRejectsUnsafePathsCaseCollisionsAndInconsistentDeltaLists() throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.catalog)) as! [String: Any]
        for path in ["../escape", "/absolute", "Contents/../escape", "Contents\\escape", "Contents/Resources//file"] {
            var value = original
            var files = value["files"] as! [[String: Any]]
            files[0]["path"] = path
            value["files"] = files
            let catalog = try JSONDecoder().decode(AppUpdateCatalog.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try catalog.validate(for: fixture.release), path)
        }
        var collision = original
        var files = collision["files"] as! [[String: Any]]
        var duplicate = files[0]
        duplicate["path"] = (files[0]["path"] as! String).uppercased()
        files.append(duplicate)
        collision["files"] = files
        XCTAssertThrowsError(try JSONDecoder().decode(AppUpdateCatalog.self,
                                                      from: JSONSerialization.data(withJSONObject: collision)).validate(for: fixture.release))
        var wrongDelta = original
        var deltas = wrongDelta["deltas"] as! [[String: Any]]
        deltas[0]["changedFiles"] = []
        wrongDelta["deltas"] = deltas
        XCTAssertThrowsError(try JSONDecoder().decode(AppUpdateCatalog.self,
                                                      from: JSONSerialization.data(withJSONObject: wrongDelta)).validate(for: fixture.release))
        let foreign = AppUpdateChecker.AvailableRelease(version: "2.0.0", url: URL(string: "https://github.com/other/repo/releases/tag/v2.0.0")!)
        XCTAssertThrowsError(try AppUpdateCatalog.assetURL(AppUpdateCatalog.filename, release: foreign))
    }

    func testFullArchiveWithAnUnexpectedEntryIsRejectedWithoutWritingIt() throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let extra = fixture.target.appendingPathComponent("Contents/Resources/unlisted.txt")
        try Data("unlisted".utf8).write(to: extra)
        let zip = fixture.directory.appendingPathComponent("unsafe.zip")
        try UpdateDownloadFixture.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", fixture.target.path, zip.path])
        let destination = fixture.directory.appendingPathComponent("rejected.app")
        XCTAssertThrowsError(try AppUpdateStager.extractFull(zip, destination: destination, catalog: fixture.catalog))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/Resources/unlisted.txt").path))
    }

    func testDeltaArchiveSymlinksAreRejectedBeforeTheyCanWriteOutsideStaging() throws {
        let fixture = try UpdateDownloadFixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("malicious/Contents/Resources")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let link = source.appendingPathComponent("new.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../escaped.txt")
        let archive = fixture.directory.appendingPathComponent("malicious.tar.xz")
        try UpdateDownloadFixture.run("/usr/bin/tar", ["--format", "ustar", "-cJf", archive.path,
                                                      "-C", fixture.directory.appendingPathComponent("malicious").path,
                                                      "Contents/Resources/new.txt"])
        let candidate = fixture.directory.appendingPathComponent("candidate.app")
        XCTAssertThrowsError(try AppUpdateStager.applyDelta(archive, installed: fixture.installed, destination: candidate,
                                                          catalog: fixture.catalog, delta: fixture.catalog.deltas[0]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("escaped.txt").path))
        XCTAssertTrue(try AppUpdateStager.matches(fixture.installed, files: fixture.catalog.deltas[0].baseFiles))
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Update download did not reach the expected state")
    }
}

private struct UpdateDownloadFixture: Sendable {
    let directory: URL
    let installed: URL
    let target: URL
    let cache: URL
    let catalog: AppUpdateCatalog
    let delta: Data
    let full: Data
    let release = AppUpdateChecker.AvailableRelease(version: "2.0.0",
                                                   url: URL(string: "https://github.com/SteveTanSaMa/Waifu2x-Desktop/releases/tag/v2.0.0")!,
                                                   hasUpdateCatalog: true)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Waifu2x-AppUpdateTests-\(UUID().uuidString)")
        installed = directory.appendingPathComponent("installed/Waifu2x.app")
        target = directory.appendingPathComponent("target/Waifu2x.app")
        cache = directory.appendingPathComponent("cache")
        var generator: UInt64 = 0x1234567890abcdef
        let shared = Data((0..<32768).map { _ -> UInt8 in
            generator = generator &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: generator >> 32)
        })
        for (app, version, build) in [(installed, "1.0.1", "2"), (target, "2.0.0", "3")] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "studio.stevetan.Waifu2x", "CFBundleShortVersionString": version,
                        "CFBundleVersion": build, "CFBundleExecutable": "Waifu2x"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Contents/Info.plist"))
            let executable = app.appendingPathComponent("Contents/MacOS/Waifu2x")
            try Data("executable \(version)".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try shared.write(to: app.appendingPathComponent("Contents/Resources/shared.dat"))
        }
        try Data("obsolete".utf8).write(to: installed.appendingPathComponent("Contents/Resources/obsolete.txt"))
        try Data("new resource".utf8).write(to: target.appendingPathComponent("Contents/Resources/new.txt"))
        let files = try Self.inventory(target), base = try Self.inventory(installed)
        let baseMap = Dictionary(uniqueKeysWithValues: base.map { ($0.path, $0) })
        let changed = files.filter { baseMap[$0.path] != $0 }.map(\.path)
        let removed = Set(base.map(\.path)).subtracting(files.map(\.path)).sorted()
        let zip = directory.appendingPathComponent("Waifu2x-2.0.0-macos-arm64.zip")
        let deltaURL = directory.appendingPathComponent("Waifu2x-1.0.1-to-2.0.0.delta.tar.xz")
        try Self.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", target.path, zip.path])
        try Self.run("/usr/bin/tar", ["--format", "ustar", "-cJf", deltaURL.path, "-C", target.path] + changed)
        delta = try Data(contentsOf: deltaURL); full = try Data(contentsOf: zip)
        catalog = AppUpdateCatalog(schemaVersion: 1, version: "2.0.0", build: "3", appBundleName: "Waifu2x.app",
                                   full: Self.asset(zip, full), files: files,
                                   deltas: [.init(fromVersion: "1.0.1", fromBuild: "2", baseFiles: base,
                                                  archive: Self.asset(deltaURL, delta), changedFiles: changed, removedFiles: removed)])
        try catalog.validate(for: release)
    }

    @MainActor
    func downloader(recorder: UpdateDownloadRecorder, deltaPayload: Data? = nil, fullPayload: Data? = nil,
                    currentVersion: String = "1.0.1", signatureValid: Bool = true,
                    gate: StartupTransferGate? = nil) -> AppUpdateDownloader {
        let metadata = try! JSONEncoder().encode(catalog)
        let response = HTTPURLResponse(url: try! AppUpdateCatalog.assetURL(AppUpdateCatalog.filename, release: release),
                                       statusCode: 200, httpVersion: "HTTP/2", headerFields: [:])!
        let payloads = [catalog.full.path: fullPayload ?? full, catalog.deltas[0].archive.path: deltaPayload ?? delta]
        return AppUpdateDownloader(currentVersion: currentVersion, currentBuild: "2", installedApplication: installed,
                                   cacheDirectory: cache, transport: { _ in (metadata, response) },
                                   transferFactory: { destination, _ in
            UpdateFixtureTransfer(destination: destination, payload: payloads[destination.lastPathComponent]!, recorder: recorder, gate: gate)
        }, signatureChecker: { _ in signatureValid })
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    private static func inventory(_ root: URL) throws -> [AppUpdateCatalog.File] {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        return try enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { url in
            let data = try Data(contentsOf: url)
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            return AppUpdateCatalog.File(path: String(path.dropFirst(root.path.count + 1)), bytes: Int64(data.count),
                                          sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                          mode: (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue)
        }.sorted { $0.path < $1.path }
    }

    private static func asset(_ url: URL, _ data: Data) -> AppUpdateCatalog.Asset {
        .init(path: url.lastPathComponent, bytes: Int64(data.count),
              sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["COPYFILE_DISABLE": "1"]) { _, value in value }
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpdateDownloadFixture.Archive", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments.joined(separator: " ")): \(detail)"])
        }
    }
}

private actor UpdateDownloadRecorder {
    private(set) var paths = [String]()
    func record(_ value: String) { paths.append(value) }
}

private final class UpdateFixtureTransfer: ModelFileTransferring, @unchecked Sendable {
    let destination: URL
    let payload: Data
    let recorder: UpdateDownloadRecorder
    let gate: StartupTransferGate?
    var resumeData: Data? { nil }
    init(destination: URL, payload: Data, recorder: UpdateDownloadRecorder, gate: StartupTransferGate?) {
        self.destination = destination; self.payload = payload; self.recorder = recorder; self.gate = gate
    }
    func download(from url: URL, resumeData: Data?, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        await recorder.record(url.lastPathComponent)
        progress(Int64(payload.count / 2), Int64(payload.count))
        try await gate?.wait()
        try Task.checkCancellation()
        try payload.write(to: destination)
        progress(Int64(payload.count), Int64(payload.count))
        return destination
    }
    func pause() async -> Data? { nil }
    func cancel() {}
}
