import Foundation

extension W2XTensor {
    static func floats(_ values: [Float], shape: [Int]) -> W2XTensor {
        let data = values.withUnsafeBytes { Data($0) }
        return W2XTensor(data: data, shape: shape.map(NSNumber.init), integer: false)
    }
    static func scalar(_ value: Int) -> W2XTensor {
        var integer = Int64(value)
        return W2XTensor(data: Data(bytes: &integer, count: 8), shape: [], integer: true)
    }
    var dimensions: [Int] { shape.map(\.intValue) }
    var floats: [Float] { data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    func reshaped(_ shape: [Int]) -> W2XTensor { W2XTensor(data: data, shape: shape.map(NSNumber.init), integer: integer) }
}

final class ONNXRuntime: @unchecked Sendable {
    let root: URL
    let threadCount: Int
    private var sessions: [String: W2XSession] = [:]
    private let lock = NSLock()
    private var cancelled = false
    init(root: URL = ModelPaths.current.onnxModels, threadCount: Int = 1) {
        self.root = root; self.threadCount = max(1, min(8, threadCount))
    }
    func cancel() {
        lock.lock(); cancelled = true
        let active = Array(sessions.values); lock.unlock()
        active.forEach { $0.cancel() }
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
    func run(_ path: String, inputs: [String: W2XTensor], backend: InferenceBackend = .cpu) throws -> W2XTensor {
        try check()
        let key = path + "#" + backend.rawValue + (backend == .coreML ? String(describing: inputs["x"]?.dimensions) : "")
        lock.lock(); var session = sessions[key]; lock.unlock()
        if session == nil {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else {
                throw AppFailure.message(L("缺少模型：%@，请重新打开应用以下载模型", path))
            }
            do {
                session = try W2XSession(path: root.appendingPathComponent(path).path, provider: backend == .coreML ? "CoreML" : (backend == .webGPU ? "WebGPU" : "CPU"), inputShape: inputs["x"]?.shape ?? [], threadCount: threadCount)
            } catch {
                try check()
                throw AppFailure.message(L("无法载入模型：%@", error.localizedDescription))
            }
            lock.lock(); sessions[key] = session; lock.unlock()
        }
        try check()
        do {
            let outputs = try session!.run(inputs)
            try check()
            guard let output = outputs["y"] else { throw AppFailure.message(L("ONNX 模型未返回 y 张量。")) }
            return output
        } catch {
            try check()
            if error is AppFailure { throw error }
            throw AppFailure.message(L("模型推理失败：%@", error.localizedDescription))
        }
    }
    func helper(_ name: String, _ inputs: [String: W2XTensor]) throws -> W2XTensor {
        try run("utils/\(name).onnx", inputs: inputs)
    }
}
