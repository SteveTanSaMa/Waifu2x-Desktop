import XCTest
import AppKit
@testable import Waifu2x

final class ONNXTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ONNXTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func fixture(width: Int = 24, height: Int = 16, alpha: Bool = false) throws -> ImageAsset {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(CGColor(red: CGFloat((x * 29 + y * 3) % 256)/255,
                                             green: CGFloat((y * 17 + x * 7) % 256)/255,
                                             blue: CGFloat((x * 5 + y * 11) % 256)/255,
                                             alpha: alpha ? CGFloat(40 + (x * 3 + y * 9) % 170)/255 : 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let image = context.makeImage()!, url = directory.appendingPathComponent("fixture.png")
        try ImageCodec.writePNG(image, to: url)
        return ImageAsset(url: url, image: image, name: "fixture")
    }
    func render(_ input: ImageAsset, _ options: ProcessingOptions, progress: @escaping @Sendable (TileProgress) -> Void = { _ in }) throws -> CGImage {
        try TestModelFixtures.require(.onnx)
        let output = try InferenceEngine().run(input: input, options: options, directory: directory, progress: progress) { _ in }
        return try ImageCodec.readPNG(output)
    }
    func pixels(_ image: CGImage) -> [UInt8] {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func testMultithreadingDefaultsAndMigration() throws {
        let defaults = ProcessingOptions()
        XCTAssertFalse(defaults.multithreading)
        XCTAssertEqual(defaults.inferenceThreads, 1)
        let parallel = ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64, multithreading: true)
        XCTAssertEqual(parallel.inferenceThreads, max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)))
        let encoded = try JSONEncoder().encode(parallel)
        XCTAssertTrue(try JSONDecoder().decode(ProcessingOptions.self, from: encoded).multithreading)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "multithreading")
        let migrated = try JSONDecoder().decode(ProcessingOptions.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(migrated.multithreading)
    }

    func testMultithreadingProducesEquivalentCPUOutput() throws {
        try TestModelFixtures.require(.onnx)
        var parallel = ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64, multithreading: true)
        let input = try fixture()
        let threaded = pixels(try render(input, parallel))
        let enabled = parallel
        parallel.multithreading = false
        XCTAssertNotEqual(parallel, enabled, "Observable settings bindings must detect the thread option change")
        let serial = pixels(try render(input, parallel))
        XCTAssertEqual(threaded.count, serial.count)
        XCTAssertLessThanOrEqual(zip(threaded, serial).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
    }

    func testEveryAvailableModelLoadsAndCatalogueIsComplete() throws {
        try TestModelFixtures.require(.onnx)
        let root = ModelPaths.current.onnxModels
        var count = 0
        let models = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in models where url.pathExtension == "onnx" {
            _ = try W2XSession(path: url.path, provider: "CPU", inputShape: [])
            count += 1
        }
        XCTAssertEqual(count, 71) // 65 image models, six official helper graphs.
    }
    func testAllFiveWebModelsAndNativeFourTimes() throws {
        let input = try fixture()
        for model in [WaifuModel.swinV3, .swinArt, .swinScan, .swinPhoto, .cunet] {
            let output = try render(input, ProcessingOptions(noise: 0, model: model, backend: .cpu, tileSize: 64, alpha: .disabled))
            XCTAssertEqual(output.width, 48, model.title)
            XCTAssertEqual(output.height, 32, model.title)
            XCTAssertGreaterThan(Set(pixels(output)).count, 20)
        }
        let four = try render(input, ProcessingOptions(scale: 4, noise: 3, model: .swinArt, backend: .cpu, tileSize: 64))
        XCTAssertEqual(four.width, 96)
        let denoise = try render(input, ProcessingOptions(scale: 1, noise: 2, model: .swinPhoto, backend: .cpu, tileSize: 64))
        XCTAssertEqual(denoise.width, 24)
        XCTAssertNotEqual(pixels(denoise), pixels(input.image))
    }
    func testTTAAndAlphaSettingsChangeRealProcessing() throws {
        let input = try fixture(alpha: true)
        var results: [[UInt8]] = []
        for tta in [0, 2, 4] {
            let image = try render(input, ProcessingOptions(model: .swinArt, backend: .cpu, tileSize: 64, tta: tta, alpha: .auto))
            let data = pixels(image)
            XCTAssertLessThan(data[3], 255)
            results.append(data)
        }
        XCTAssertNotEqual(results[0], results[1])
        XCTAssertNotEqual(results[1], results[2])
        let opaque = pixels(try render(input, ProcessingOptions(model: .swinArt, backend: .cpu, tileSize: 64, alpha: .disabled)))
        XCTAssertTrue(stride(from: 3, to: opaque.count, by: 4).allSatisfy { opaque[$0] == 255 })
    }
    func testShuffleProgressAndSeamBlendingAreOrderIndependent() throws {
        let input = try fixture(width: 90, height: 70)
        let log = ONNXProgressLog()
        let original = try render(input, ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64))
        let shuffled = try render(input, ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64, shuffle: true), progress: { log.events.append($0) })
        let done = try XCTUnwrap(log.events.last)
        XCTAssertEqual(done.completed, done.total)
        XCTAssertEqual(done.completedRects.count, done.total)
        XCTAssertEqual(done.total, 6)
        let a = pixels(original), b = pixels(shuffled)
        let mae = zip(a,b).map { abs(Double($0) - Double($1)) }.reduce(0,+) / Double(a.count)
        XCTAssertLessThan(mae, 0.1)
        XCTAssertEqual(Set(done.completedRects.map { "\($0.minX),\($0.minY)" }).count, done.total)
    }
    func testNativeWebGPUAndCoreMLProviders() throws {
        try TestModelFixtures.require(.onnx)
        XCTAssertTrue(W2XSession.availableProviders().contains("WebGpuExecutionProvider"))
        let input = try fixture()
        let cpu = pixels(try render(input, ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64)))
        let gpu = pixels(try render(input, ProcessingOptions(model: .swinV3, backend: .webGPU, tileSize: 64)))
        XCTAssertLessThan(zip(cpu,gpu).map { abs(Double($0)-Double($1)) }.reduce(0,+)/Double(cpu.count), 3)
        let coreML = try render(input, ProcessingOptions(model: .cunet, backend: .coreML, tileSize: 64))
        XCTAssertEqual(coreML.width, 48)
    }
    func testWebGPUAllModelsAndTTA() throws {
        let input = try fixture()
        for model in [WaifuModel.swinV3, .swinArt, .swinScan, .swinPhoto, .cunet] {
            let output = try render(input, ProcessingOptions(model: model, backend: .webGPU, tileSize: 64, tta: 2))
            XCTAssertEqual(output.width, 48)
        }
        let output = try render(input, ProcessingOptions(model: .swinArt, backend: .webGPU, tileSize: 64, tta: 4))
        XCTAssertEqual(output.width, 48)
    }
    func testONNXCancellationStopsRun() throws {
        try TestModelFixtures.require(.onnx)
        let input = try fixture(width: 400, height: 400)
        let engine = InferenceEngine()
        let ended = expectation(description: "Native ONNX run terminated")
        let directory = directory!
        DispatchQueue.global().async {
            do {
                _ = try engine.run(input: input, options: ProcessingOptions(backend: .cpu, tileSize: 256, tta: 4), directory: directory) { _ in }
                XCTFail("Expected cancellation")
            } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            ended.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.15)
        engine.cancel()
        wait(for: [ended], timeout: 10)
    }

    func testTileAlignmentAndSettingsPersistenceEncoding() throws {
        for model in [WaifuModel.swinV3, .swinArt, .swinPhoto, .swinScan, .cunet] {
            for tile in [64, 256, 400, 640] {
                let configuration = ONNXConfiguration(model: model, scale: 2, requestedTile: tile)
                XCTAssertGreaterThan(configuration.inputStep, 0)
                XCTAssertGreaterThanOrEqual(configuration.tile, tile)
            }
        }
        let options = ProcessingOptions(scale: 4, noise: 3, model: .swinScan, backend: .webGPU, tileSize: 640, shuffle: true, tta: 4, alpha: .disabled)
        XCTAssertEqual(try JSONDecoder().decode(ProcessingOptions.self, from: JSONEncoder().encode(options)), options)
    }
}
private final class ONNXProgressLog: @unchecked Sendable { var events: [TileProgress] = [] }
