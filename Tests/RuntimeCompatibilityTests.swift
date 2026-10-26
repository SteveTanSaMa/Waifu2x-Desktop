import Foundation
import XCTest
@testable import Waifu2x

/// Exercises the bundled runtime without fetching application model weights.
final class RuntimeCompatibilityTests: XCTestCase {
    func testBundledRuntimeKeepsThePinnedVersionAndAllExecutionProviders() {
        XCTAssertEqual(W2XRuntimeVersion(), "1.23.2")
        let providers = Set(W2XSession.availableProviders())
        XCTAssertTrue(providers.contains("CPUExecutionProvider"))
        XCTAssertTrue(providers.contains("CoreMLExecutionProvider"))
        XCTAssertTrue(providers.contains("WebGpuExecutionProvider"))
    }

    func testTinyGraphRunsOnCPUCoreMLAndWebGPU() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeCompatibility-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let graph = directory.appendingPathComponent("relu.onnx")
        try Self.reluModel.write(to: graph)
        let values: [Float] = [-1, 2, 0, 3]
        let results = try await Task.detached(priority: .userInitiated) {
            let tensor = W2XTensor(data: values.withUnsafeBytes { Data($0) }, shape: [1, 1, 2, 2], integer: false)
            return try ["CPU", "CoreML", "WebGPU"].map { provider in
                let session = try W2XSession(path: graph.path, provider: provider, inputShape: [1, 1, 2, 2])
                let result = try XCTUnwrap(session.run(["x": tensor])["y"], provider)
                return (provider, result.shape.map(\.intValue), result.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
            }
        }.value
        for (provider, shape, output) in results {
            XCTAssertEqual(shape, [1, 1, 2, 2], provider)
            XCTAssertEqual(output, [0, 2, 0, 3], provider)
        }
    }

    // Minimal ONNX protobuf encoding keeps this test independent of Python,
    // ONNX packages, and downloaded weights: y = Relu(x), float [1, 1, 2, 2].
    private static var reluModel: Data {
        func variable(_ value: UInt64) -> Data {
            var value = value, bytes = Data()
            repeat {
                var byte = UInt8(value & 0x7f)
                value >>= 7
                if value != 0 { byte |= 0x80 }
                bytes.append(byte)
            } while value != 0
            return bytes
        }
        func integer(_ field: UInt64, _ value: UInt64) -> Data {
            variable(field << 3) + variable(value)
        }
        func message(_ field: UInt64, _ value: Data) -> Data {
            variable((field << 3) | 2) + variable(UInt64(value.count)) + value
        }
        func string(_ field: UInt64, _ value: String) -> Data { message(field, Data(value.utf8)) }
        func info(_ name: String) -> Data {
            let dimensions = [1, 1, 2, 2].reduce(Data()) { $0 + message(1, integer(1, UInt64($1))) }
            let tensorType = integer(1, 1) + message(2, dimensions)
            return string(1, name) + message(2, message(1, tensorType))
        }
        let node = string(1, "x") + string(2, "y") + string(4, "Relu")
        let graph = message(1, node) + string(2, "runtime-compatibility")
            + message(11, info("x")) + message(12, info("y"))
        return integer(1, 8) + message(7, graph) + message(8, integer(2, 13))
    }
}
