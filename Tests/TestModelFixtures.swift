import Foundation
import XCTest
@testable import Waifu2x

/// Real inference is optional for a fresh clone; synthetic tests never need downloaded models.
enum TestModelFixtures {
    enum Family: Hashable {
        case onnx, ncnn
        var prefix: String { self == .onnx ? "ONNXModels/" : "Engine/" }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var verifiedFamilies: Set<Family> = []

    static func require(_ family: Family) throws {
        let mode = ProcessInfo.processInfo.environment["WAIFU2X_TEST_MODE"]
        if mode == "unit" {
            throw XCTSkip("Real inference is excluded from unit tests; run ./script/test.sh --integration to download and test the pinned models")
        }
        lock.lock()
        defer { lock.unlock() }
        if verifiedFamilies.contains(family) { return }
        let catalog = try ModelCatalog.load()
        try catalog.validate()
        for file in catalog.files where file.path.hasPrefix(family.prefix) {
            let url = ModelPaths.current.root.appendingPathComponent(file.path)
            let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard size?.isRegularFile == true, size?.isSymbolicLink != true,
                  Int64(size?.fileSize ?? -1) == file.bytes,
                  (try? ModelStore.sha256(of: url)) == file.sha256 else {
                let message = "Missing or invalid test models at \(ModelPaths.current.root.path); run python3 script/fetch_test_models.py or ./script/test.sh --integration"
                if mode == "integration" {
                    throw NSError(domain: "TestModelFixtures", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                throw XCTSkip(message)
            }
        }
        verifiedFamilies.insert(family)
    }
}
