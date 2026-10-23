import Foundation

/// A versioned model cache. Only an explicit development environment can use fixtures.
struct ModelPaths: Sendable {
    static let catalogVersion = "models-v1"
    let root: URL

    init(root: URL) { self.root = root }

    static var current: ModelPaths {
        if let fixture = ProcessInfo.processInfo.environment["WAIFU2X_MODEL_ROOT"], !fixture.isEmpty {
            return ModelPaths(root: URL(fileURLWithPath: fixture, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ModelPaths(root: support.appendingPathComponent("studio.stevetan.Waifu2x/Models", isDirectory: true)
            .appendingPathComponent(catalogVersion, isDirectory: true))
    }

    var onnxModels: URL { root.appendingPathComponent("ONNXModels", isDirectory: true) }
    var engine: URL { root.appendingPathComponent("Engine", isDirectory: true) }
    var downloadDirectory: URL {
        root.deletingLastPathComponent().appendingPathComponent(".Downloads", isDirectory: true)
            .appendingPathComponent(Self.catalogVersion, isDirectory: true)
    }
}
