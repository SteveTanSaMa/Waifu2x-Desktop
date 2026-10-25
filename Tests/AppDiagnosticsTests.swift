import AppKit
import XCTest
@testable import Waifu2x

final class AppDiagnosticsTests: XCTestCase {
    func testReportContainsOnlyTheAllowlistedFactsInAStableFormat() {
        XCTAssertEqual(AppDiagnostics.text(modelStatus: .ready, snapshot: fixture), """
        Waifu2x Desktop 1.0.1 (Build 12)
        macOS: 26.1.0
        Chip: Apple M4 Pro
        Memory: 24 GB
        Architecture: arm64
        ONNX Runtime: 1.23.2
        Model Package: models-v1
        Model Status: Verified
        """)
    }

    func testEveryModelStateHasAFixedDiagnosticValue() {
        let expected: [(DiagnosticModelStatus, String)] = [
            (.unverified, "Not checked"), (.checking, "Checking"), (.ready, "Verified"),
            (.needsRepair, "Needs repair"), (.repairing, "Repairing")
        ]
        XCTAssertEqual(expected.count, DiagnosticModelStatus.allCases.count)
        for (state, value) in expected {
            let report = AppDiagnostics.text(modelStatus: state, snapshot: fixture)
            XCTAssertEqual(report.split(separator: "\n").last, "Model Status: \(value)")
            XCTAssertEqual(report.split(separator: "\n").count, 8)
        }
    }

    func testUnexpectedStringsCannotInjectPathsOrExtraReportFields() {
        var facts = fixture
        let privatePath = "/Users/diagnostics-sentinel/private-image.png"
        facts.appVersion = "1.0.1\nUser: diagnostics-sentinel"
        facts.appBuild = privatePath
        facts.runtimeVersion = "https://host-sentinel.invalid/\(privatePath)"
        facts.modelPackage = "models-v1\nSerial: serial-sentinel"
        facts.chipName = "Apple M4 Pro\nHome: \(privatePath)"
        let report = AppDiagnostics.text(modelStatus: .needsRepair, snapshot: facts)
        XCTAssertEqual(report.split(separator: "\n").count, 8)
        for privateValue in [privatePath, "diagnostics-sentinel", "private-image.png",
                             "host-sentinel", "serial-sentinel"] {
            XCTAssertFalse(report.contains(privateValue))
        }
        XCTAssertTrue(report.contains("Chip: Unknown"))
        XCTAssertTrue(report.contains("Model Status: Needs repair"))
    }

    func testSystemCaptureReadsOnlyTheProcessorSysctlEvenWhenOtherPrivateValuesExist() {
        let injectedSystem = [
            "machdep.cpu.brand_string": "Apple M4 Pro",
            "kern.hostname": "host-sentinel",
            "USER": "username-sentinel",
            "HOME": "/Users/home-sentinel",
            "WAIFU2X_MODEL_ROOT": "/private/model-path-sentinel",
            "IOPlatformSerialNumber": "serial-sentinel"
        ]
        var requestedKeys: [String] = []
        let facts = AppDiagnostics.Snapshot.capture { name in
            requestedKeys.append(name)
            return injectedSystem[name]
        }
        let report = AppDiagnostics.text(modelStatus: .unverified, snapshot: facts)
        XCTAssertEqual(requestedKeys, ["machdep.cpu.brand_string"])
        XCTAssertEqual(facts.physicalMemory, ProcessInfo.processInfo.physicalMemory)
        XCTAssertEqual(facts.architecture, .current)
        XCTAssertEqual(facts.modelPackage, ModelPaths.catalogVersion)
        XCTAssertEqual(facts.runtimeVersion, W2XRuntimeVersion())
        XCTAssertNotEqual(facts.runtimeVersion, "Unknown")
        XCTAssertFalse(report.contains("sentinel"))
        XCTAssertFalse(report.contains(NSHomeDirectory()))
        XCTAssertTrue(report.hasSuffix("Model Status: Not checked"))
    }

    @MainActor
    func testCopyWritesPlainTextOnlyToTheInjectedPasteboard() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("old contents", forType: .string)
        XCTAssertTrue(AppDiagnostics.copy(modelStatus: .repairing, to: pasteboard, snapshot: fixture))
        let report = AppDiagnostics.text(modelStatus: .repairing, snapshot: fixture)
        let types = Set(pasteboard.types ?? [])
        // macOS may advertise its legacy alias alongside public.utf8-plain-text.
        let textTypes: Set<NSPasteboard.PasteboardType> = [.string, .init("NSStringPboardType")]
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.isSubset(of: textTypes))
        XCTAssertTrue(types.isDisjoint(with: [.fileURL, .URL, .rtf, .rtfd, .html]))
        for type in types {
            XCTAssertEqual(pasteboard.string(forType: type), report)
        }
    }

    private var fixture: AppDiagnostics.Snapshot {
        .init(appVersion: "1.0.1", appBuild: "12",
              operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0),
              chipName: "Apple M4 Pro", physicalMemory: 24 * (1 << 30), architecture: .arm64,
              runtimeVersion: "1.23.2", modelPackage: "models-v1")
    }
}
