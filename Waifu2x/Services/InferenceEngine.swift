import Foundation

/// Owns cancellation for either native inference implementation.
final class InferenceEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var ncnn: NcnnEngine?
    private var onnx: ONNXRenderer?
    let root: URL
    init(root: URL = Bundle.main.resourceURL!.appendingPathComponent("Engine")) { self.root = root }
    func cancel() {
        lock.lock(); cancelled = true; let ncnn = ncnn, onnx = onnx; lock.unlock()
        ncnn?.cancel(); onnx?.cancel()
    }
    func run(input: ImageAsset, options: ProcessingOptions, directory: URL,
             progress: @escaping @Sendable (TileProgress) -> Void = { _ in },
             stage: @escaping @Sendable (String) -> Void) throws -> URL {
        if let message = options.validationMessage { throw AppFailure.message(message) }
        try ImageCodec.validateOutputDimensions(width: input.image.width, height: input.image.height, scale: options.scale)
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        if options.resolvedBackend == .metal {
            let worker = NcnnEngine(root: root); ncnn = worker; lock.unlock()
            return try worker.run(input: input, options: options, directory: directory, progress: progress, stage: stage)
        }
        let worker = ONNXRenderer(threadCount: options.inferenceThreads); onnx = worker; lock.unlock()
        return try worker.run(input: input, options: options, directory: directory, progress: progress, stage: stage)
    }
}
