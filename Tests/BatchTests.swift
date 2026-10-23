import XCTest
import AppKit
@testable import Waifu2x

@MainActor
final class BatchTests: XCTestCase {
    private func source(_ workspace: Workspace, width: Int = 32, height: Int = 24, name: String = "小图.png") throws -> URL {
        let url = workspace.directory.appendingPathComponent(name)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(SampleArtwork.make(), in: CGRect(x: 0, y: 0, width: width, height: height))
        try ImageCodec.writePNG(context.makeImage()!, to: url)
        return url
    }
    private func solidSource(_ workspace: Workspace, width: Int, height: Int, name: String) throws -> URL {
        let url = workspace.directory.appendingPathComponent(name)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try ImageCodec.writePNG(context.makeImage()!, to: url)
        return url
    }
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw AppFailure.message("等待队列状态超时") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testQueuedImportsSelectionAndRemovalWithoutInference() async throws {
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let url = try source(workspace)
        let invalid = workspace.directory.appendingPathComponent("invalid.png")
        try Data("invalid image".utf8).write(to: invalid)
        workspace.load([url, invalid])
        workspace.load(url)
        try await waitUntil { !workspace.isLoading }
        XCTAssertEqual(workspace.images.count, 2)
        XCTAssertNotNil(workspace.errorMessage)
        let first = try XCTUnwrap(workspace.images.first)
        XCTAssertEqual(workspace.processingImages.map(\.id), [first.id])
        workspace.toggleMultiSelection()
        workspace.markAll()
        XCTAssertEqual(workspace.markedIDs.count, 2)
        workspace.remove(first)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertFalse(workspace.markedIDs.contains(first.id))
        XCTAssertNotNil(workspace.input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.input.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCollisionSafeBatchExportWithoutInference() throws {
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let url = try source(workspace, name: "input.png")
        let asset = ImageAsset(url: url, image: try ImageCodec.readPNG(url), name: "input.png")
        let result = ProcessingResult(asset: asset, options: ProcessingOptions(scale: 2), duration: 0)
        let target = workspace.directory.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appendingPathComponent("input_waifu2x_2x.png")
        let userData = Data("existing user file".utf8)
        try userData.write(to: existing)
        let report = BatchExporter.write([result, result], to: target)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.urls.map(\.lastPathComponent), ["input_waifu2x_2x (2).png", "input_waifu2x_2x (3).png"])
        XCTAssertEqual(try Data(contentsOf: existing), userData)
        for output in report.urls { XCTAssertEqual(try Data(contentsOf: output), try Data(contentsOf: url)) }
    }

    func testCurrentImageDefaultAndExplicitMultiSelectionProcessing() async throws {
        try TestModelFixtures.require(.ncnn)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(noise: -1, model: .cunet, backend: .metal, tileSize: 64)
        let url = try source(workspace)
        workspace.load([url, url, url])
        try await waitUntil { !workspace.isLoading }
        let images = workspace.images
        XCTAssertEqual(workspace.processingImages.map(\.id), [images[0].id])
        workspace.process()
        try await waitUntil { !workspace.isProcessing }
        XCTAssertNotNil(images[0].result)
        XCTAssertNil(images[1].result)
        XCTAssertNil(images[2].result)
        let oldResult = images[0].result?.asset.id
        workspace.toggleMultiSelection()
        workspace.clearMarks()
        XCTAssertFalse(workspace.canProcessSelection)
        workspace.toggleMarked(images[1])
        workspace.toggleMarked(images[2])
        workspace.select(images[0])
        XCTAssertEqual(workspace.processingImages.map(\.id), [images[1].id, images[2].id])
        workspace.process()
        try await waitUntil { !workspace.isProcessing }
        XCTAssertEqual(workspace.batchCount, 2)
        XCTAssertEqual(images[0].result?.asset.id, oldResult)
        XCTAssertNotNil(images[1].result)
        XCTAssertNotNil(images[2].result)
        workspace.markAll()
        XCTAssertEqual(workspace.markedIDs.count, 3)
        workspace.remove(images[1])
        XCTAssertFalse(workspace.markedIDs.contains(images[1].id))
        workspace.toggleMultiSelection()
        XCTAssertTrue(workspace.markedIDs.isEmpty)
        XCTAssertEqual(workspace.processingImages.count, 1)
    }

    func testMultipleImportsBatchInferenceAndCollisionSafeExport() async throws {
        try TestModelFixtures.require(.ncnn)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(noise: -1, model: .cunet, backend: .metal, tileSize: 64)
        let url = try source(workspace)
        let invalid = workspace.directory.appendingPathComponent("无法解码.png")
        try Data("invalid image".utf8).write(to: invalid)
        workspace.load([url, invalid])
        // Additional Finder open events arriving while decoding join the import queue.
        workspace.load(url)
        try await waitUntil { !workspace.isLoading }
        XCTAssertEqual(workspace.images.count, 2)
        XCTAssertNotNil(workspace.errorMessage)
        workspace.errorMessage = nil
        let first = try XCTUnwrap(workspace.images.first)
        workspace.processAll()
        // Editing UI state cannot change the in-flight batch's settings snapshot.
        workspace.options.scale = 4
        try await waitUntil { !workspace.isProcessing }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.completedImages.count, 2)
        for image in workspace.images {
            XCTAssertEqual(image.state, .completed)
            XCTAssertEqual(image.result?.asset.image.width, 64)
            XCTAssertEqual(image.result?.options.scale, 2)
            XCTAssertEqual(image.result?.options.noise, -1)
        }
        let target = workspace.directory.appendingPathComponent("导出", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let existing = target.appendingPathComponent("小图_waifu2x_2x.png")
        let original = Data("existing user file".utf8)
        try original.write(to: existing)
        let results = workspace.completedImages.compactMap(\.result)
        let report = BatchExporter.write(results, to: target)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertEqual(report.urls.map(\.lastPathComponent), ["小图_waifu2x_2x (2).png", "小图_waifu2x_2x (3).png"])
        XCTAssertEqual(try Data(contentsOf: existing), original)
        for url in report.urls { XCTAssertEqual(try ImageCodec.readPNG(url).width, 64) }
        workspace.select(first)
        XCTAssertEqual(workspace.result?.options.scale, 2)
        workspace.remove(first)
        XCTAssertEqual(workspace.images.count, 1)
        XCTAssertNotNil(workspace.input)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.input.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCancelBatchPreservesCompletedResultsAndStopsRemainingImages() async throws {
        try TestModelFixtures.require(.onnx)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(model: .cunet, backend: .cpu, tileSize: 64, tta: 4)
        let small = try source(workspace)
        let large = try source(workspace, width: 400, height: 300, name: "大图.png")
        workspace.load([small, large, small])
        try await waitUntil { !workspace.isLoading }
        workspace.processAll()
        try await waitUntil { workspace.images[0].result != nil && workspace.batchIndex == 2 }
        let completedURL = try XCTUnwrap(workspace.images[0].result?.asset.url)
        workspace.cancel()
        try await waitUntil({ !workspace.isProcessing }, timeout: 15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedURL.path))
        XCTAssertEqual(workspace.images[0].state, .completed)
        XCTAssertEqual(workspace.images[1].state, .cancelled)
        XCTAssertNil(workspace.images[1].result)
        XCTAssertNil(workspace.images[2].result)
        XCTAssertEqual(workspace.images[2].state, .ready)
        XCTAssertNil(workspace.tileProgress)
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.notice, L("已停止批量处理 · 保留已完成的 %d 张结果", 1))
    }

    func testOneProcessingFailureDoesNotStopBatch() async throws {
        try TestModelFixtures.require(.ncnn)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(scale: 4, model: .cunet, backend: .metal, tileSize: 64)
        let url = try source(workspace)
        let oversizedOutput = try solidSource(workspace, width: 7600, height: 7600, name: "输出超过限制.png")
        workspace.load([url, oversizedOutput, url])
        try await waitUntil { !workspace.isLoading }
        // This image's 4× output reaches 924 MP and exceeds the engine's 900 MP limit; neighbors remain valid.
        workspace.processAll()
        try await waitUntil { !workspace.isProcessing }
        XCTAssertEqual(workspace.images[0].state, .completed)
        XCTAssertEqual(workspace.images[1].state, .failed)
        XCTAssertNotNil(workspace.images[1].failure)
        XCTAssertEqual(workspace.images[2].state, .completed)
        XCTAssertEqual(workspace.completedImages.count, 2)
        XCTAssertNil(workspace.errorMessage)
    }

    func testRestartConfirmationKeepsPanelsAndUsesNewSettingsAfterWorkerStops() async throws {
        try TestModelFixtures.require(.onnx)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(model: .swinV3, backend: .cpu, tileSize: 64, tta: 4)
        workspace.load(try source(workspace, width: 96, height: 64))
        try await waitUntil { !workspace.isLoading }
        let panels = workspace.activePanels
        workspace.process()
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertTrue(workspace.canProcessSelection)
        try await waitUntil { workspace.tileProgress != nil }
        workspace.process()
        XCTAssertTrue(workspace.showsRestartConfirmation)
        workspace.dismissRestartConfirmation()
        XCTAssertFalse(workspace.showsRestartConfirmation)
        XCTAssertTrue(workspace.isProcessing, "Dismissing confirmation must not cancel the active worker")
        workspace.options.scale = 1
        workspace.options.tta = 0
        workspace.process()
        XCTAssertTrue(workspace.showsRestartConfirmation)
        workspace.confirmRestart()
        XCTAssertFalse(workspace.showsRestartConfirmation)
        try await waitUntil { !workspace.isProcessing }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.result?.options.scale, 1)
        XCTAssertEqual(workspace.result?.options.tta, 0)
        XCTAssertEqual(workspace.result?.asset.image.width, 96)
        XCTAssertEqual(workspace.result?.asset.image.height, 64)
        XCTAssertEqual(workspace.activePanels, panels)
        XCTAssertEqual(workspace.selectedImage?.state, .completed)
    }

    func testRestartStillWorksIfOriginalTaskFinishesWhileConfirmationIsOpen() async throws {
        try TestModelFixtures.require(.ncnn)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(noise: -1, model: .cunet, backend: .metal, tileSize: 64)
        workspace.load(try source(workspace))
        try await waitUntil { !workspace.isLoading }
        workspace.process()
        workspace.process()
        XCTAssertTrue(workspace.showsRestartConfirmation)
        try await waitUntil { !workspace.isProcessing }
        XCTAssertTrue(workspace.showsRestartConfirmation)
        workspace.options.scale = 4
        workspace.confirmRestart()
        XCTAssertTrue(workspace.isProcessing)
        try await waitUntil { !workspace.isProcessing }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.result?.asset.image.width, 128)
        XCTAssertEqual(workspace.result?.options.scale, 4)
    }

    func testDirectNoiseAndScaleChoicesAndLegacySettingsMigration() throws {
        var options = ProcessingOptions(scale: 4, noise: 2)
        options.scale = 1
        XCTAssertEqual(options.noise, 2)
        XCTAssertTrue(options.isValid)
        XCTAssertEqual(options.method, "noise2")
        options.noise = -1
        XCTAssertEqual(options.scale, 1)
        XCTAssertFalse(options.isValid)
        options.scale = 2
        XCTAssertEqual(options.noise, -1)
        XCTAssertTrue(options.isValid)
        XCTAssertEqual(options.method, "scale2x")
        options.noise = 2
        XCTAssertEqual(options.scale, 2)
        XCTAssertEqual(options.method, "noise2_scale2x")
        options.scale = 1
        options.noise = -1
        let restored = try JSONDecoder().decode(ProcessingOptions.self, from: JSONEncoder().encode(options))
        XCTAssertEqual(restored.scale, 1)
        XCTAssertEqual(restored.noise, -1)
        XCTAssertFalse(restored.isValid)
        let legacy = Data(#"{"scale":2,"noise":3,"model":"swinV3","backend":"automatic","tileSize":256,"shuffle":false,"tta":0,"alpha":"auto"}"#.utf8)
        var migrated = try JSONDecoder().decode(ProcessingOptions.self, from: legacy)
        XCTAssertEqual(migrated.noise, 3)
        XCTAssertEqual(migrated.scale, 2)
        migrated.noise = -1
        XCTAssertEqual(migrated.scale, 2)
        migrated.scale = 1
        XCTAssertEqual(migrated.noise, -1)
    }
}
