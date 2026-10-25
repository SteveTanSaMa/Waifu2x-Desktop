import Foundation
import Observation

enum AppUpdateDownloadStatus: Equatable, Sendable {
    case idle, preparing, downloading, verifying, ready, cancelled, failed
}

@MainActor @Observable
final class AppUpdateDownloader {
    private(set) var status: AppUpdateDownloadStatus = .idle
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    private(set) var usesDelta = false
    private(set) var fellBackToFull = false
    private(set) var stagedApplication: URL?
    private(set) var targetVersion: String?
    private(set) var targetBuild: String?
    private(set) var errorMessage: String?
    private var work: Task<Void, Never>?
    @ObservationIgnored private var transfer: (any ModelFileTransferring)?
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let currentBuild: String
    @ObservationIgnored private let installedApplication: URL
    @ObservationIgnored private let cacheDirectory: URL
    @ObservationIgnored private let transport: AppUpdateTransport
    @ObservationIgnored private let transferFactory: ModelDownloadTransportFactory
    @ObservationIgnored private let signatureChecker: ApplicationSignatureChecking
    @ObservationIgnored private var operation = UUID()

    var isBusy: Bool { status == .preparing || status == .downloading || status == .verifying }
    var canStart: Bool { work == nil }
    var progress: Double { totalBytes > 0 ? min(1, Double(downloadedBytes) / Double(totalBytes)) : 0 }

    init(currentVersion: String = AppInformation.version, currentBuild: String = AppInformation.build,
         installedApplication: URL = Bundle.main.bundleURL, cacheDirectory: URL? = nil,
         transport: AppUpdateTransport? = nil, transferFactory: ModelDownloadTransportFactory? = nil,
         signatureChecker: ApplicationSignatureChecking? = nil) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.installedApplication = installedApplication
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("studio.stevetan.Waifu2x/Updates", isDirectory: true)
        self.transport = transport ?? { try await Self.loadCatalog($0) }
        self.transferFactory = transferFactory ?? { ModelFileDownload(destination: $0, expectedBytes: $1) }
        self.signatureChecker = signatureChecker ?? { try AppUpdateStager.verifySignature($0) }
    }

    func start(_ release: AppUpdateChecker.AvailableRelease) {
        guard canStart else { return }
        let id = UUID(); operation = id
        if let stagedApplication { try? FileManager.default.removeItem(at: stagedApplication.deletingLastPathComponent()) }
        stagedApplication = nil; errorMessage = nil
        targetVersion = release.version; targetBuild = nil
        downloadedBytes = 0; totalBytes = 0; usesDelta = false; fellBackToFull = false
        status = .preparing
        work = Task { [weak self] in
            guard let self else { return }
            let directory = cacheDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer {
                if status != .ready { try? FileManager.default.removeItem(at: directory) }
                if operation == id { work = nil; transfer = nil }
            }
            do {
                let url = try AppUpdateCatalog.assetURL(AppUpdateCatalog.filename, release: release)
                let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                let (data, response) = try await transport(request)
                try check(id)
                guard let response = response as? HTTPURLResponse else { throw AppUpdateFailure.invalidCatalog }
                if response.statusCode == 404 { throw AppUpdateFailure.unavailableCatalog }
                guard response.statusCode == 200, data.count <= 4 * 1024 * 1024,
                      let catalog = try? JSONDecoder().decode(AppUpdateCatalog.self, from: data) else {
                    throw AppUpdateFailure.invalidCatalog
                }
                try catalog.validate(for: release)
                targetBuild = catalog.build
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
                let candidate = directory.appendingPathComponent(catalog.appBundleName, isDirectory: true)
                let installed = installedApplication, signature = signatureChecker
                var delta: AppUpdateCatalog.Delta?
                for proposed in catalog.deltas.sorted(by: { $0.archive.bytes < $1.archive.bytes })
                    where ReleaseVersion(proposed.fromVersion) == ReleaseVersion(currentVersion) && proposed.fromBuild == currentBuild {
                    let matches = (try? await Self.background({ try AppUpdateStager.matches(installed, files: proposed.baseFiles) })) == true
                    try check(id)
                    if matches {
                        delta = proposed
                        break
                    }
                }
                try check(id)
                if let delta {
                    do {
                        usesDelta = true
                        let archive = try await download(delta.archive, release: release, directory: directory, id: id)
                        status = .verifying
                        try await Self.background {
                            try AppUpdateStager.applyDelta(archive, installed: installed, destination: candidate,
                                                           catalog: catalog, delta: delta)
                            try AppUpdateStager.validateApplication(candidate, catalog: catalog, signatureChecker: signature)
                        }
                    } catch {
                        try check(id)
                        fellBackToFull = true; usesDelta = false
                        try? FileManager.default.removeItem(at: candidate)
                        try await downloadFull(catalog, release: release, directory: directory, candidate: candidate, id: id)
                    }
                } else {
                    try await downloadFull(catalog, release: release, directory: directory, candidate: candidate, id: id)
                }
                try check(id)
                for asset in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    where asset.lastPathComponent != catalog.appBundleName {
                    try? FileManager.default.removeItem(at: asset)
                }
                stagedApplication = candidate
                status = .ready
            } catch {
                guard operation == id else { return }
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    status = .cancelled
                } else {
                    status = .failed
                    let failure = (error as? AppUpdateFailure)?.localizedDescription ?? L("更新下载失败，请检查网络连接后重试")
                    errorMessage = failure
                }
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        work?.cancel(); transfer?.cancel()
        status = .cancelled
    }

    private func downloadFull(_ catalog: AppUpdateCatalog, release: AppUpdateChecker.AvailableRelease,
                              directory: URL, candidate: URL, id: UUID) async throws {
        usesDelta = false
        let archive = try await download(catalog.full, release: release, directory: directory, id: id)
        status = .verifying
        let signature = signatureChecker
        try await Self.background {
            try AppUpdateStager.extractFull(archive, destination: candidate, catalog: catalog)
            try AppUpdateStager.validateApplication(candidate, catalog: catalog, signatureChecker: signature)
        }
    }

    private func download(_ asset: AppUpdateCatalog.Asset, release: AppUpdateChecker.AvailableRelease,
                          directory: URL, id: UUID) async throws -> URL {
        try check(id)
        let url = try AppUpdateCatalog.assetURL(asset.path, release: release)
        let destination = directory.appendingPathComponent(asset.path)
        totalBytes = asset.bytes; downloadedBytes = 0; status = .downloading
        let transfer = transferFactory(destination, asset.bytes)
        self.transfer = transfer
        do {
            _ = try await transfer.download(from: url, resumeData: nil) { [weak self] bytes, _ in
                Task { @MainActor in
                    guard let self, self.operation == id, self.status == .downloading else { return }
                    self.downloadedBytes = max(0, min(asset.bytes, bytes))
                }
            }
        } catch {
            try check(id)
            throw AppUpdateFailure.download
        }
        try check(id)
        self.transfer = nil
        status = .verifying
        let matches = try await Self.background {
            guard let attributes = try? destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  Int64(attributes.fileSize ?? -1) == asset.bytes else { return false }
            return try ModelStore.sha256(of: destination) == asset.sha256
        }
        guard matches else { throw AppUpdateFailure.invalidArchive }
        downloadedBytes = asset.bytes
        return destination
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operation == id, status != .cancelled else { throw CancellationError() }
    }

    nonisolated private static func background<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility, operation: action)
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Stop an oversized response while it is arriving, rather than allocating
    /// an unbounded Data value before validating the metadata size.
    nonisolated private static func loadCatalog(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let limit = 4 * 1024 * 1024
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(limit) else { throw AppUpdateFailure.invalidCatalog }
        var data = Data()
        data.reserveCapacity(response.expectedContentLength > 0 ? Int(response.expectedContentLength) : 64 * 1024)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AppUpdateFailure.invalidCatalog }
            data.append(byte)
        }
        return (data, response)
    }
}
