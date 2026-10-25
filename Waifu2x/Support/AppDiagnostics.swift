import AppKit
import Darwin
import Foundation

/// Diagnostic state is deliberately closed to paths and free-form error messages.
enum DiagnosticModelStatus: CaseIterable, Sendable {
    case unverified, checking, ready, needsRepair, repairing

    var reportValue: String {
        switch self {
        case .unverified: "Not checked"
        case .checking: "Checking"
        case .ready: "Verified"
        case .needsRepair: "Needs repair"
        case .repairing: "Repairing"
        }
    }
}

enum AppDiagnostics {
    enum Architecture: String, Sendable {
        case arm64, x86_64, unknown

        static var current: Self {
            #if arch(arm64)
            .arm64
            #elseif arch(x86_64)
            .x86_64
            #else
            .unknown
            #endif
        }
    }

    /// Only these public product and hardware facts can enter a report.
    /// No environment, computer name, user information or filesystem URLs are read.
    struct Snapshot: Sendable {
        var appVersion: String
        var appBuild: String
        var operatingSystem: OperatingSystemVersion
        var chipName: String?
        var physicalMemory: UInt64
        var architecture: Architecture
        var runtimeVersion: String
        var modelPackage: String

        static var current: Self { capture() }

        static func capture(systemString: (String) -> String? = readSystemString) -> Self {
            let process = ProcessInfo.processInfo
            return Self(appVersion: AppInformation.version, appBuild: AppInformation.build,
                        operatingSystem: process.operatingSystemVersion,
                        chipName: systemString("machdep.cpu.brand_string"),
                        physicalMemory: process.physicalMemory, architecture: .current,
                        runtimeVersion: W2XRuntimeVersion(), modelPackage: ModelPaths.catalogVersion)
        }

        private static func readSystemString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1, size <= 256 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return buffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return nil }
                return String(validatingCString: base)
            }
        }
    }

    static func text(modelStatus: DiagnosticModelStatus, snapshot: Snapshot? = nil) -> String {
        let facts = snapshot ?? .current
        let system = facts.operatingSystem
        let systemVersion = [system.majorVersion, system.minorVersion, system.patchVersion]
            .map { String(max(0, $0)) }.joined(separator: ".")
        return [
            "Waifu2x Desktop \(version(facts.appVersion)) (Build \(version(facts.appBuild)))",
            "macOS: \(systemVersion)",
            "Chip: \(chip(facts.chipName))",
            "Memory: \(memory(facts.physicalMemory))",
            "Architecture: \(facts.architecture.rawValue)",
            "ONNX Runtime: \(version(facts.runtimeVersion))",
            "Model Package: \(modelPackage(facts.modelPackage))",
            "Model Status: \(modelStatus.reportValue)"
        ].joined(separator: "\n")
    }

    /// Explicit user action is the only clipboard write; tests inject a unique pasteboard.
    @MainActor
    @discardableResult
    static func copy(modelStatus: DiagnosticModelStatus, to pasteboard: NSPasteboard = .general,
                     snapshot: Snapshot? = nil) -> Bool {
        let report = text(modelStatus: modelStatus, snapshot: snapshot)
        pasteboard.clearContents()
        return pasteboard.setString(report, forType: .string)
    }

    private static func version(_ value: String) -> String {
        matches(value, #"^[0-9]{1,10}(?:\.[0-9]{1,10}){0,3}$"#) ? value : "Unknown"
    }

    private static func modelPackage(_ value: String) -> String {
        matches(value, #"^models-v[0-9]{1,10}$"#) ? value : "Unknown"
    }

    private static func chip(_ value: String?) -> String {
        guard let value, value.count <= 120,
              matches(value, #"^(?:Apple|Intel|AMD)[ A-Za-z0-9()@+.,_-]+$"#) else { return "Unknown" }
        return value
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        guard !value.contains("\n"), !value.contains("\r") else { return false }
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func memory(_ bytes: UInt64) -> String {
        let gibibyte = UInt64(1 << 30)
        let whole = bytes / gibibyte
        let remainder = bytes % gibibyte
        guard remainder != 0 else { return "\(whole) GB" }
        let tenths = (remainder * 10 + gibibyte / 2) / gibibyte
        if tenths == 10 { return "\(whole + 1) GB" }
        return "\(whole).\(tenths) GB"
    }
}
