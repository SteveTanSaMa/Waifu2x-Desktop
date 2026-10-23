import XCTest
import AppKit
@testable import Waifu2x

final class InferenceTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Waifu2xTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(width: Int = 48, height: Int = 32) throws -> ImageAsset {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<24 {
            context.setFillColor(CGColor(gray: CGFloat(i % 3) / 2, alpha: 1))
            context.fill(CGRect(x: i * 2, y: i % 10, width: 1, height: 18))
        }
        let image = context.makeImage()!
        let url = directory.appendingPathComponent("输入 图.png")
        try ImageCodec.writePNG(image, to: url)
        return ImageAsset(url: url, image: image, name: "输入 图.png")
    }

    func testRealInferenceScaleNoiseAndAlpha() throws {
        try TestModelFixtures.require(.ncnn)
        let input = try fixture()
        for (scale, noise, style) in [(2, 1, ImageStyle.illustration), (4, -1, .illustration), (1, 2, .illustration), (2, 0, .photo)] {
            let options = ProcessingOptions(scale: scale, noise: noise, style: style, backend: .metal, tileSize: 384)
            let output = try InferenceEngine().run(input: input, options: options, directory: directory) { _ in }
            let image = try ImageCodec.readPNG(output)
            XCTAssertEqual(image.width, input.image.width * scale)
            XCTAssertEqual(image.height, input.image.height * scale)
            XCTAssertTrue([CGImageAlphaInfo.last, .premultipliedLast, .first, .premultipliedFirst].contains(image.alphaInfo))
            let data = image.dataProvider!.data! as Data
            XCTAssertGreaterThan(Set(data).count, 20, "Inference must produce nonempty image detail")
            if scale == 1 { XCTAssertNotEqual(data, input.image.dataProvider!.data! as Data, "Denoising must change actual pixels") }
        }
    }

    func testNcnnMultithreadingProducesRealOutput() throws {
        try TestModelFixtures.require(.ncnn)
        let input = try fixture()
        let options = ProcessingOptions(model: .cunet, backend: .metal, tileSize: 64, multithreading: true)
        let output = try InferenceEngine().run(input: input, options: options, directory: directory) { _ in }
        let image = try ImageCodec.readPNG(output)
        XCTAssertEqual(image.width, input.image.width * 2)
        XCTAssertEqual(image.height, input.image.height * 2)
        XCTAssertGreaterThan(Set(image.dataProvider!.data! as Data).count, 20)
    }

    func testTileProgressAndSeamAgreement() throws {
        try TestModelFixtures.require(.ncnn)
        let image = SampleArtwork.make()
        let inputURL = directory.appendingPathComponent("landscape.png")
        try ImageCodec.writePNG(image, to: inputURL)
        let input = ImageAsset(url: inputURL, image: image, name: "landscape")
        let log = ProgressLog()
        let result = try InferenceEngine().run(input: input, options: ProcessingOptions(model: .cunet, backend: .metal, tileSize: 384), directory: directory,
                                               progress: { log.events.append($0) }) { _ in }
        let complete = log.events.filter { $0.activeRect == nil }
        XCTAssertEqual(complete.map(\.completed), [1, 2, 3, 4])
        XCTAssertEqual(complete.last?.fraction, 1)
        XCTAssertNotNil(complete.first?.preview)
        let reference = directory.appendingPathComponent("reference.png")
        let root = Bundle.main.resourceURL!.appendingPathComponent("Engine")
        let worker = Process()
        worker.executableURL = root.appendingPathComponent("waifu2x-ncnn-vulkan")
        worker.arguments = ["-i", inputURL.path, "-o", reference.path, "-m", ModelPaths.current.engine.appendingPathComponent("models-cunet").path, "-s", "2", "-n", "1", "-t", "128", "-j", "1:1:1"]
        worker.standardError = FileHandle.nullDevice
        try worker.run(); worker.waitUntilExit()
        XCTAssertEqual(worker.terminationStatus, 0)
        func pixels(_ image: CGImage) -> [UInt8] {
            let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
        }
        let output = try ImageCodec.readPNG(result)
        let a = pixels(output), b = pixels(try ImageCodec.readPNG(reference))
        var total = 0.0, seam = 0.0, seamCount = 0
        for y in 0..<output.height {
            for x in 0..<output.width {
                for channel in 0..<3 {
                    let index = (y * output.width + x) * 4 + channel
                    let delta = Double(abs(Int(a[index]) - Int(b[index])))
                    total += delta
                    if abs(x - 768) < 8 || abs(y - 768) < 8 { seam += delta; seamCount += 1 }
                }
            }
        }
        let average = total / Double(output.width * output.height * 3)
        let seamAverage = seam / Double(seamCount)
        print("Tiled vs full inference MAE: \(average); seam MAE: \(seamAverage)")
        XCTAssertLessThan(average, 2)
        XCTAssertLessThan(seamAverage, 3)
        let validation = URL(fileURLWithPath: "/tmp/Waifu2x-validation")
        try FileManager.default.createDirectory(at: validation, withIntermediateDirectories: true)
        try ImageCodec.writePNG(output, to: validation.appendingPathComponent("enhanced.png"))
        try ImageCodec.writePNG(complete.first!.preview!, to: validation.appendingPathComponent("first-tile.png"))
    }

    func testCancellationStopsWorker() throws {
        try TestModelFixtures.require(.ncnn)
        let input = try fixture(width: 640, height: 480)
        let engine = InferenceEngine()
        let finished = expectation(description: "Inference cancelled")
        DispatchQueue.global().async {
            do {
                _ = try engine.run(input: input, options: ProcessingOptions(model: .cunet, backend: .metal, tileSize: 384), directory: self.directory) { _ in }
                XCTFail("Expected cancellation")
            } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
            finished.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.15)
        engine.cancel()
        wait(for: [finished], timeout: 10)
    }

    func testInvalidInputOptionsAndCancellationRejected() throws {
        let url = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageCodec.load(url, workingDirectory: directory))
        let input = try fixture()
        XCTAssertThrowsError(try InferenceEngine().run(input: input, options: ProcessingOptions(scale: 1, noise: -1), directory: directory) { _ in })
        let cancelled = InferenceEngine(); cancelled.cancel()
        XCTAssertThrowsError(try cancelled.run(input: input, options: ProcessingOptions(model: .cunet, backend: .metal, tileSize: 384), directory: directory) { _ in })
    }

    func testLargeInputBeyondLegacyPixelLimitLoads() throws {
        let large = try fixture(width: 7000, height: 6000)
        let loaded = try ImageCodec.load(large.url, workingDirectory: directory)
        XCTAssertEqual(loaded.image.width, 7000)
        XCTAssertEqual(loaded.image.height, 6000)
    }

    func testEXIFOrientationNormalization() throws {
        let input = try fixture()
        let url = directory.appendingPathComponent("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, input.image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let loaded = try ImageCodec.load(url, workingDirectory: directory)
        XCTAssertEqual(loaded.image.width, 32)
        XCTAssertEqual(loaded.image.height, 48)
    }
}
import ImageIO

private final class ProgressLog: @unchecked Sendable { var events: [TileProgress] = [] }
