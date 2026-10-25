import Foundation
import Observation

enum FileIntegrityStatus: Equatable, Sendable {
    case idle, checking, valid, issues, cancelled, failed
}

enum ModelIntegrityVerification: Equatable, Sendable {
    case unknown, valid, issues
}

typealias ApplicationSignatureChecking = @Sendable (URL) throws -> Bool
typealias ModelIntegrityScanning = @Sendable (ModelStore, @Sendable (Int, String, ModelStore.IntegrityFinding?) -> Void) throws -> [ModelStore.IntegrityFinding]

@MainActor @Observable
final class FileIntegrityChecker {
    struct Issue: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case application, model }
        let path: String
        let reason: String
        let kind: Kind
        var id: String { "\(kind):\(path)" }
    }

    private(set) var status: FileIntegrityStatus = .idle
    private(set) var progress = 0.0
    private(set) var checkedFiles = 0
    private(set) var totalFiles = 0
    private(set) var currentName = ""
    private(set) var issues = [Issue]()
    private(set) var lastChecked: Date?
    private(set) var errorMessage: String?
    // A cancelled/failed scan cannot erase previously discovered model damage.
    private(set) var modelVerification: ModelIntegrityVerification = .unknown
    private var work: Task<Void, Never>?
    @ObservationIgnored private let catalog: ModelCatalog?
    @ObservationIgnored private let catalogError: String?
    @ObservationIgnored private let paths: ModelPaths
    @ObservationIgnored private let bundleURL: URL
    @ObservationIgnored var canCheck: @MainActor () -> Bool
    @ObservationIgnored private let signatureChecker: ApplicationSignatureChecking
    @ObservationIgnored private let modelScanner: ModelIntegrityScanning
    @ObservationIgnored private var operation = UUID()

    var canStart: Bool { work == nil && canCheck() }

    init(catalog: ModelCatalog? = nil, paths: ModelPaths = .current,
         bundleURL: URL = Bundle.main.bundleURL, canCheck: @escaping @MainActor () -> Bool = { true },
         signatureChecker: ApplicationSignatureChecking? = nil, modelScanner: ModelIntegrityScanning? = nil) {
        self.paths = paths
        self.bundleURL = bundleURL
        self.canCheck = canCheck
        self.signatureChecker = signatureChecker ?? { try Self.verifyApplicationSignature($0) }
        self.modelScanner = modelScanner ?? { try $0.integrityReport(progress: $1) }
        do {
            let loaded = try catalog ?? ModelCatalog.load()
            try loaded.validate()
            self.catalog = loaded
            catalogError = nil
            totalFiles = loaded.files.count
        } catch {
            self.catalog = nil
            catalogError = error.localizedDescription
        }
    }

    func check() {
        guard canStart else { return }
        beginCheck()
    }

    private func beginCheck() {
        let id = UUID()
        operation = id
        status = .checking
        progress = 0
        checkedFiles = 0
        currentName = bundleURL.lastPathComponent
        issues = []
        errorMessage = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { if operation == id { work = nil } }
            do {
                let signatureChecker = self.signatureChecker, bundleURL = self.bundleURL
                let signatureValid = try await Self.background { try signatureChecker(bundleURL) }
                try checkCancellation(id)
                if !signatureValid {
                    issues.append(.init(path: bundleURL.path, reason: L("应用签名验证失败，请重新安装官方应用"), kind: .application))
                }
                guard let catalog else {
                    throw IntegrityFailure.message(catalogError ?? L("模型清单无效，请重新安装完整应用"))
                }
                let store = ModelStore(catalog: catalog, paths: paths)
                let modelScanner = self.modelScanner
                let findings = try await Self.background { [weak self] in
                    try modelScanner(store) { [weak self] count, name, finding in
                        Task { @MainActor in
                            guard let self, self.operation == id else { return }
                            if finding != nil { self.modelVerification = .issues }
                            guard self.status == .checking else { return }
                            self.checkedFiles = min(self.totalFiles, max(self.checkedFiles, count))
                            self.progress = Double(self.checkedFiles) / Double(max(1, self.totalFiles))
                            self.currentName = name
                            if let finding {
                                let issue = Self.issue(from: finding)
                                if !self.issues.contains(where: { $0.id == issue.id }) { self.issues.append(issue) }
                            }
                        }
                    }
                }
                try checkCancellation(id)
                issues = issues.filter { $0.kind == .application } + findings.map(Self.issue)
                modelVerification = findings.isEmpty ? .valid : .issues
                checkedFiles = totalFiles
                progress = 1
                currentName = ""
                lastChecked = Date()
                status = issues.isEmpty ? .valid : .issues
            } catch {
                guard operation == id, status != .cancelled else { return }
                if error is CancellationError || Task.isCancelled {
                    status = .cancelled
                } else {
                    status = .failed
                    errorMessage = L("完整性检查未能完成：%@", error.localizedDescription)
                    lastChecked = Date()
                }
                currentName = ""
            }
        }
    }

    func cancel() {
        guard status == .checking else { return }
        work?.cancel()
        status = .cancelled
        currentName = ""
    }

    func waitUntilFinished() async {
        await work?.value
    }

    /// Repair owns the model cache until this full scan and its worker cleanup finish.
    /// Ordinary menu checks remain subject to the external readiness gate.
    func refreshAfterModelRepair() async -> Bool {
        await waitUntilFinished()
        beginCheck()
        await waitUntilFinished()
        return (status == .valid || status == .issues) && modelVerification == .valid
    }

    private func checkCancellation(_ id: UUID) throws {
        try Task.checkCancellation()
        guard operation == id, status == .checking else { throw CancellationError() }
    }

    private static func issue(from finding: ModelStore.IntegrityFinding) -> Issue {
        .init(path: finding.path, reason: finding.reason.localizedDescription, kind: .model)
    }

    nonisolated private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let worker = Task.detached(priority: .utility, operation: operation)
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    nonisolated private static func verifyApplicationSignature(_ bundleURL: URL) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", bundleURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        do {
            while process.isRunning {
                try Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.02)
            }
            try Task.checkCancellation()
            return process.terminationReason == .exit && process.terminationStatus == 0
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    private enum IntegrityFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
    }
}
