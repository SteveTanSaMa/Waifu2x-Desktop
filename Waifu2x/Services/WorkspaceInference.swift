import Foundation

/// Small worker seam keeps queue lifecycle tests independent of model files.
protocol WorkspaceInference: AnyObject, Sendable {
    func cancel()
    func run(input: ImageAsset, options: ProcessingOptions, directory: URL,
             progress: @escaping @Sendable (TileProgress) -> Void,
             stage: @escaping @Sendable (String) -> Void) throws -> URL
}

extension InferenceEngine: WorkspaceInference {}
