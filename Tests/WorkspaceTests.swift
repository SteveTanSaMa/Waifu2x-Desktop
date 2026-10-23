import XCTest
import AppKit
@testable import Waifu2x

@MainActor
final class WorkspaceTests: XCTestCase {
    func testPanelVisibilityIsIndependent() {
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        XCTAssertTrue(workspace.showsImages, "The image queue opens on launch, including the empty state")
        XCTAssertTrue(workspace.showsOptions, "The adjustment panel opens on launch")
        workspace.zoom = 1.5
        workspace.showsImages = true
        workspace.showsOptions = true
        XCTAssertTrue(workspace.showsImages)
        XCTAssertTrue(workspace.showsOptions)
        workspace.showsImages = false
        XCTAssertTrue(workspace.showsOptions)
        workspace.showsImages = true
        workspace.showsOptions = false
        XCTAssertTrue(workspace.showsImages)
        workspace.showsOptions = true
        workspace.dismissPanelOrCancel()
        XCTAssertFalse(workspace.showsImages)
        XCTAssertFalse(workspace.showsOptions)
        XCTAssertEqual(workspace.zoom, 1.5)
    }

    func testClipboardImageImport() async throws {
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let pasteboard = NSPasteboard.withUniqueName()
        let image = NSImage(cgImage: SampleArtwork.make(), size: .zero)
        XCTAssertTrue(pasteboard.writeObjects([image]))
        workspace.importClipboard(pasteboard)
        while workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.input?.image.width, 720)
        pasteboard.clearContents()
    }

    func testImportProcessReprocessCancelAndExport() async throws {
        try TestModelFixtures.require(.ncnn)
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        workspace.options = ProcessingOptions(model: .cunet, backend: .metal, tileSize: 384)
        workspace.openSample()
        while workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.input?.image.width, 720)
        workspace.process()
        while workspace.isProcessing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(workspace.errorMessage)
        let result = try XCTUnwrap(workspace.result)
        XCTAssertEqual(result.asset.image.width, 1440)
        XCTAssertNil(workspace.tileProgress)
        XCTAssertEqual(workspace.preview, .result)
        let inputDimensions = L("%d × %d", 720, 480)
        let resultDimensions = L("%d × %d", 1440, 960)
        workspace.preview = .original
        XCTAssertEqual(workspace.displayedAsset?.dimensions, inputDimensions)
        workspace.preview = .result
        XCTAssertEqual(workspace.displayedAsset?.dimensions, resultDimensions)
        workspace.preview = .compare
        XCTAssertEqual(workspace.displayedAsset?.dimensions, resultDimensions)
        workspace.options.scale = 4
        XCTAssertEqual(workspace.displayedAsset?.dimensions, resultDimensions, "Unsaved options must not change the displayed result's resolution")
        workspace.preview = .original
        XCTAssertEqual(workspace.displayedAsset?.dimensions, inputDimensions)
        workspace.preview = .result
        XCTAssertTrue(workspace.hasChangedOptions)
        // The old result stays exportable with its original dimensions/options.
        let export = workspace.directory.appendingPathComponent("export 中文.png")
        try workspace.writeExport(result, to: export)
        XCTAssertEqual(try Data(contentsOf: export), try Data(contentsOf: result.asset.url))
        try Data("old contents".utf8).write(to: export)
        try workspace.writeExport(result, to: export)
        XCTAssertEqual(try ImageCodec.readPNG(export).width, 1440)
        workspace.process()
        XCTAssertTrue(workspace.isProcessing)
        workspace.cancel()
        while workspace.isProcessing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(workspace.errorMessage)
        XCTAssertEqual(workspace.result?.options.scale, 2)
        XCTAssertNil(workspace.tileProgress)
        XCTAssertEqual(workspace.notice, L("已取消处理"))
    }
}
