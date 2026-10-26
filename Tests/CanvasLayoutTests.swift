import XCTest
import SwiftUI
@testable import Waifu2x

@MainActor
final class CanvasLayoutTests: XCTestCase {
    func testPanningCanRevealImageBehindPanelsAtFit() {
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        canvas.original = SampleArtwork.make()
        let fitted = canvas.imageRect
        canvas.openPanels = Set(CanvasPanel.allCases)
        XCTAssertEqual(canvas.imageRect.midX, 500, accuracy: 0.001)
        XCTAssertEqual(canvas.imageRect.midY, fitted.midY, accuracy: 0.001)
        let centered = canvas.imageRect
        canvas.pan = CGSize(width: 100, height: 0)
        XCTAssertEqual(canvas.imageRect.minX, centered.minX + 100, accuracy: 0.001)
        canvas.pan = CGSize(width: -100, height: 0)
        XCTAssertEqual(canvas.imageRect.minX, centered.minX - 100, accuracy: 0.001)
        XCTAssertEqual(canvas.imageRect.size, fitted.size)
        canvas.openPanels = []
        XCTAssertEqual(canvas.imageRect, fitted.offsetBy(dx: -100, dy: 0), "Panel closure must preserve the user pan instead of recentering the image")
        canvas.zoom = 2
        canvas.pan = CGSize(width: 100, height: 80)
        let panned = canvas.imageRect
        canvas.pan = .zero
        XCTAssertEqual(panned.minX - canvas.imageRect.minX, 100, accuracy: 0.001)
        XCTAssertEqual(panned.minY - canvas.imageRect.minY, 80, accuracy: 0.001)
    }

    func testTransientZeroSizeDuringViewAttachment() {
        let layout = CanvasPanelLayout(size: .zero)
        XCTAssertEqual(layout.centerX(for: [.images, .options]), 0)
        XCTAssertGreaterThan(layout.frame(for: .images).width, 0)
        XCTAssertGreaterThan(layout.frame(for: .options).width, 0)
        let canvas = CanvasView(frame: .zero)
        canvas.original = SampleArtwork.make()
        canvas.openPanels = [.images, .options]
        XCTAssertTrue(canvas.imageRect.midX.isFinite)
    }

    func testPanelsOnlyChangeHorizontalCenterAtEveryWindowSize() {
        for size in [CGSize(width: 640, height: 440), CGSize(width: 1100, height: 760), CGSize(width: 800, height: 1000)] {
            let canvas = CanvasView(frame: CGRect(origin: .zero, size: size))
            canvas.original = SampleArtwork.make()
            canvas.zoom = 2
            canvas.pan = CGSize(width: 0, height: 70)
            let original = canvas.imageRect
            let layout = CanvasPanelLayout(size: size)
            for panels: Set<CanvasPanel> in [[.images], [.options], [.images, .options], []] {
                canvas.openPanels = panels
                XCTAssertEqual(canvas.imageRect.midX, layout.presentationCenterX(for: panels), accuracy: 0.001)
                XCTAssertEqual(canvas.imageRect.midY, original.midY, accuracy: 0.001)
                XCTAssertEqual(canvas.imageRect.size, original.size)
                XCTAssertEqual(canvas.zoom, 2)
                XCTAssertEqual(canvas.pan.height, 70)
            }
        }
    }

    func testCanvasCenterMovesThroughIntermediatePositionsAndCanReverse() async throws {
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        canvas.original = SampleArtwork.make()
        let original = canvas.imageRect
        canvas.setOpenPanels([.images, .options], animated: true)
        XCTAssertEqual(canvas.imageRect.midX, original.midX, accuracy: 0.1)
        try await Task.sleep(for: .milliseconds(100))
        let intermediate = canvas.imageRect.midX
        XCTAssertGreaterThan(intermediate, 500)
        XCTAssertLessThan(intermediate, 550)
        XCTAssertEqual(canvas.imageRect.midY, original.midY, accuracy: 0.01)
        XCTAssertEqual(canvas.imageRect.size, original.size)
        canvas.setOpenPanels([], animated: true)
        XCTAssertEqual(canvas.imageRect.midX, intermediate, accuracy: 1)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(canvas.imageRect.midX, 550, accuracy: 0.1)
        canvas.setOpenPanels([.options], animated: false)
        XCTAssertEqual(canvas.imageRect.midX, 356, accuracy: 0.1)
    }

    func testHeaderPixelBoundsRemainConstantAcrossAllPanelCombinations() async throws {
        let workspace = Workspace(persistOptions: false)
        defer { workspace.shutdown() }
        let host = NSHostingView(rootView: ContentView(workspace: workspace))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func probe(_ identifier: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { probe(identifier, in: $0) }.first
        }
        var actionsFrame: CGRect?
        var queueY: CGFloat?
        var nativeFrames: [CGRect]?
        let kinds: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let nativeButtons = try kinds.map { try XCTUnwrap(window.standardWindowButton($0)) }
        for panels: Set<CanvasPanel> in [[], [.images], [.options], [.images, .options], []] {
            workspace.activePanels = panels
            try await Task.sleep(for: .milliseconds(420))
            host.layoutSubtreeIfNeeded()
            let queue = try XCTUnwrap(probe("queueToggleBounds", in: host))
            let options = try XCTUnwrap(probe("optionsToggleBounds", in: host))
            let rect = queue.convert(queue.bounds, to: nil)
            let optionsRect = options.convert(options.bounds, to: nil)
            let actions = try XCTUnwrap(probe("actionsBounds", in: host))
            let rectOfActions = actions.convert(actions.bounds, to: nil)
            if let actionsFrame { XCTAssertEqual(rectOfActions, actionsFrame) }
            else { actionsFrame = rectOfActions }
            XCTAssertEqual(rect.width, 44, accuracy: 0.01)
            XCTAssertEqual(rect.height, 32, accuracy: 0.01)
            XCTAssertEqual(rect.width * window.backingScaleFactor, 44 * window.backingScaleFactor, accuracy: 0.01)
            XCTAssertEqual(rect.midY, optionsRect.midY, accuracy: 0.01)
            if let queueY { XCTAssertEqual(rect.midY, queueY, accuracy: 0.01) }
            else { queueY = rect.midY }
            let currentNativeFrames = nativeButtons.map { $0.convert($0.bounds, to: nil) }
            let closeRect = try XCTUnwrap(currentNativeFrames.first)
            XCTAssertEqual(closeRect.midX, 26, accuracy: 0.1)
            XCTAssertEqual(window.frame.height - closeRect.midY, 26, accuracy: 0.1)
            let queueSurface = CanvasPanelLayout(size: window.frame.size).frame(for: .images)
            for nativeRect in currentNativeFrames {
                let fromTop = CGRect(x: nativeRect.minX, y: window.frame.height - nativeRect.maxY,
                                     width: nativeRect.width, height: nativeRect.height)
                XCTAssertTrue(queueSurface.contains(fromTop))
            }
            if let nativeFrames { XCTAssertEqual(currentNativeFrames, nativeFrames) }
            else { nativeFrames = currentNativeFrames }
            for (index, button) in nativeButtons.enumerated() {
                XCTAssertTrue(window.standardWindowButton(kinds[index]) === button)
            }
            print("HEADER PIXELS panels=\(panels) frame=\(rect) backing=\(window.backingScaleFactor) options=\(optionsRect)")
        }
        workspace.activePanels = [.images, .options]
        try await Task.sleep(for: .milliseconds(100))
        let movingQueue = try XCTUnwrap(probe("queueToggleBounds", in: host))
        let intermediateX = movingQueue.convert(movingQueue.bounds, to: nil).minX
        let targetX = WorkspaceHeaderLayout(size: host.bounds.size, panels: [.images, .options], actionsWidth: 125).queueX
        // Task.sleep guarantees a minimum delay, not an exact animation frame.
        // A shared runner can resume after completion; reduced motion can also
        // place the control at its endpoint immediately. Keep checking bounds
        // here; the dedicated motion tests cover animation and reversal.
        XCTAssertGreaterThanOrEqual(intermediateX, 92)
        XCTAssertLessThanOrEqual(intermediateX, targetX)
        let currentQueueRect = movingQueue.convert(movingQueue.bounds, to: nil)
        XCTAssertEqual(currentQueueRect.midY, try XCTUnwrap(queueY), accuracy: 0.01)
        workspace.toggleMultiSelection()
        try await Task.sleep(for: .milliseconds(420))
        let settledQueue = try XCTUnwrap(probe("queueToggleBounds", in: host))
        XCTAssertEqual(settledQueue.convert(settledQueue.bounds, to: nil).minX, targetX, accuracy: 0.01)
        let actionsAfterMultiSelect = try XCTUnwrap(probe("actionsBounds", in: host))
        XCTAssertEqual(actionsAfterMultiSelect.convert(actionsAfterMultiSelect.bounds, to: nil), actionsFrame)
        print("HEADER intermediate x=\(intermediateX)")
        window.setContentSize(CanvasPanelLayout.minimumWindowSize)
        try await Task.sleep(for: .milliseconds(120))
        let resizedClose = nativeButtons[0].convert(nativeButtons[0].bounds, to: nil)
        XCTAssertEqual(resizedClose.midX, 26, accuracy: 0.1)
        XCTAssertEqual(window.frame.height - resizedClose.midY, 26, accuracy: 0.1)
    }

    func testBottomControlsKeepSizeAcrossDimensionsAndPreviewModes() async throws {
        let workspace = Workspace(persistOptions: false)
        workspace.openSample()
        while workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        defer { workspace.shutdown() }
        let host = NSHostingView(rootView: ContentView(workspace: workspace))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        func probe(_ identifier: String, _ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { probe(identifier, $0) }.first
        }
        try await Task.sleep(for: .milliseconds(100))
        let original = try XCTUnwrap(probe("canvasControlsBounds", host))
        let bounds = original.convert(original.bounds, to: nil)
        let context = try XCTUnwrap(CGContext(data: nil, width: 12000, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let result = ImageAsset(url: workspace.directory.appendingPathComponent("result.png"), image: try XCTUnwrap(context.makeImage()), name: "result")
        workspace.selectedImage?.result = ProcessingResult(asset: result, options: workspace.options, duration: 1)
        for preview in PreviewMode.allCases {
            workspace.preview = preview
            workspace.pixelScale = preview == .original ? 0.1 : 12.345
            try await Task.sleep(for: .milliseconds(100))
            let controls = try XCTUnwrap(probe("canvasControlsBounds", host))
            XCTAssertEqual(controls.convert(controls.bounds, to: nil), bounds)
        }
        let enhance = try XCTUnwrap(probe("enhanceBounds", host))
        XCTAssertEqual(enhance.bounds.size, CGSize(width: 112, height: 44))
        window.setContentSize(CanvasPanelLayout.minimumWindowSize)
        try await Task.sleep(for: .milliseconds(100))
        let compactControls = try XCTUnwrap(probe("canvasControlsBounds", host))
        let controlsRect = compactControls.convert(compactControls.bounds, to: nil)
        let enhanceRect = enhance.convert(enhance.bounds, to: nil)
        XCTAssertFalse(controlsRect.intersects(enhanceRect))
    }

    func testPanelSymbolsStayAttachedDuringMotionAndReversal() async throws {
        let workspace = Workspace(persistOptions: false)
        workspace.activePanels = []
        let host = NSHostingView(rootView: ContentView(workspace: workspace))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); workspace.shutdown() }
        func probe(_ identifier: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap { probe(identifier, in: $0) }.first
        }
        func frames() throws -> [CGRect] {
            try [("queueToggleBounds", "queueSymbolBounds"), ("optionsToggleBounds", "optionsSymbolBounds")].map { controlID, symbolID in
                let control = try XCTUnwrap(probe(controlID, in: host))
                let symbol = try XCTUnwrap(probe(symbolID, in: host))
                let controlRect = control.convert(control.bounds, to: nil)
                let symbolRect = symbol.convert(symbol.bounds, to: nil)
                XCTAssertEqual(symbolRect.midX, controlRect.midX, accuracy: 0.1)
                XCTAssertEqual(symbolRect.midY, controlRect.midY, accuracy: 0.1)
                XCTAssertEqual(symbolRect.size, controlRect.size)
                return controlRect
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let closed = try frames()
        workspace.activePanels = [.images, .options]
        try await Task.sleep(for: .milliseconds(100))
        let opening = try frames()
        XCTAssertGreaterThan(opening[0].minX, closed[0].minX)
        XCTAssertLessThan(opening[1].minX, closed[1].minX)
        // Reverse before completion, then sample several presentation frames.
        workspace.activePanels = []
        for _ in 0..<4 {
            try await Task.sleep(for: .milliseconds(40))
            _ = try frames()
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try frames(), closed)
        workspace.activePanels = [.images, .options]
        try await Task.sleep(for: .milliseconds(350))
        let open = try frames()
        workspace.activePanels = []
        try await Task.sleep(for: .milliseconds(100))
        let closing = try frames()
        XCTAssertLessThan(closing[0].minX, open[0].minX)
        XCTAssertGreaterThan(closing[1].minX, open[1].minX)
        XCTAssertEqual(closing[0].midY, closed[0].midY, accuracy: 0.1)
        XCTAssertEqual(closing[1].midY, closed[1].midY, accuracy: 0.1)
    }

    func testCanvasAndBottomControlsShareEveryPresentationFrame() async throws {
        for (size, imageSize) in [(CanvasPanelLayout.minimumWindowSize, CGSize(width: 720, height: 480)),
                                  (CGSize(width: 1360, height: 760), CGSize(width: 400, height: 1000)),
                                  (CGSize(width: 1400, height: 800), CGSize(width: 1600, height: 400))] {
            let workspace = Workspace(persistOptions: false)
            workspace.activePanels = []
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: Int(imageSize.width), height: Int(imageSize.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let asset = ImageAsset(url: workspace.directory.appendingPathComponent("fixture.png"),
                                   image: try XCTUnwrap(bitmap.makeImage()), name: "fixture.png")
            let item = QueueImage(input: asset)
            workspace.images = [item]
            workspace.select(item)
            let host = NSHostingView(rootView: ContentView(workspace: workspace))
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
                if let found = view as? T { return found }
                return view.subviews.lazy.compactMap { find(type, in: $0) }.first
            }
            func probe(_ name: String, in view: NSView) -> NSView? {
                if view.identifier?.rawValue == name { return view }
                return view.subviews.lazy.compactMap { probe(name, in: $0) }.first
            }
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let canvas = try XCTUnwrap(find(CanvasView.self, in: host))
            let controls = try XCTUnwrap(probe("canvasControlsBounds", in: host))
            workspace.zoom = 2
            try await Task.sleep(for: .milliseconds(50))
            canvas.pan = CGSize(width: 80, height: 30)
            let imageY = canvas.imageRect.midY
            let imageSizeBefore = canvas.imageRect.size
            func check() {
                host.layoutSubtreeIfNeeded()
                let image = canvas.convert(canvas.imageRect, to: nil)
                let bar = controls.convert(controls.bounds, to: nil)
                XCTAssertEqual(image.midX - bar.midX, 80, accuracy: 0.01,
                    "Image/control relative offset must be invariant in \(size), panels \(workspace.activePanels)")
                XCTAssertEqual(canvas.imageRect.midY, imageY, accuracy: 0.01)
                XCTAssertEqual(canvas.imageRect.size, imageSizeBefore)
                XCTAssertGreaterThanOrEqual(bar.minX, -0.01)
                XCTAssertLessThanOrEqual(bar.maxX, window.frame.width + 0.01)
            }
            check()
            // Interrupt each movement before its 0.30-second completion, sampling
            // actual native control bounds alongside the drawn image rectangle.
            for panels: Set<CanvasPanel> in [[.images, .options], [.options], [.images], [], [.images, .options]] {
                workspace.activePanels = panels
                for _ in 0..<5 {
                    try await Task.sleep(for: .milliseconds(30))
                    check()
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            check()
            let controlsHost = try XCTUnwrap(find(CanvasControlsHostView.self, in: host))
            XCTAssertEqual(controlsHost.host.fittingSize.width, CanvasPanelLayout.controlsWidth, accuracy: 0.1)
            workspace.isProcessing = true
            try await Task.sleep(for: .milliseconds(250))
            check()
            XCTAssertEqual(controlsHost.host.frame.height, controlsHost.host.fittingSize.height, accuracy: 0.1)
            workspace.isProcessing = false
            window.close()
            workspace.shutdown()
        }
    }

    func testMinimumWindowKeepsMovingPanelsClearOfBottomControls() async throws {
        let workspace = Workspace(persistOptions: false)
        workspace.activePanels = []
        workspace.openSample()
        while workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        // This test covers the tightest logical content area. Native titlebar
        // sizing is covered separately and varies between macOS versions.
        let minimumContentSize = CanvasPanelLayout.minimumWindowSize
        let host = NSHostingView(rootView: ContentView(workspace: workspace, configuresWindow: false))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: minimumContentSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); workspace.shutdown() }
        func probe(_ name: String, in view: NSView) -> NSView? {
            if view.identifier?.rawValue == name { return view }
            return view.subviews.lazy.compactMap { probe(name, in: $0) }.first
        }
        let deadline = Date().addingTimeInterval(4)
        var stableSince = Date()
        var settled = false
        while Date() < deadline {
            window.setContentSize(minimumContentSize)
            host.frame = CGRect(origin: .zero, size: minimumContentSize)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let exact = window.contentLayoutRect.size == minimumContentSize && host.bounds.size == minimumContentSize
            if !exact { stableSince = Date() }
            if exact, probe("canvasControlsBounds", in: host) != nil,
               Date().timeIntervalSince(stableSince) >= 0.15 { settled = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard settled else {
            XCTFail("The minimum content fixture must settle before sampling panel motion: layout=\(window.contentLayoutRect), host=\(host.bounds)")
            return
        }
        XCTAssertEqual(window.contentLayoutRect.size, minimumContentSize)
        XCTAssertEqual(host.bounds.size, minimumContentSize)
        for processing in [false, true] {
            workspace.isProcessing = processing
            for panels: Set<CanvasPanel> in [[.images, .options], [.images], [.options], [], [.images, .options]] {
                workspace.activePanels = panels
                for _ in 0..<12 {
                    try await Task.sleep(for: .milliseconds(30))
                    XCTAssertEqual(window.contentLayoutRect.size, minimumContentSize,
                                   "Panel motion must use the exact minimum content area")
                    XCTAssertEqual(host.bounds.size, minimumContentSize)
                    let controls = try XCTUnwrap(probe("canvasControlsBounds", in: host))
                    let bar = controls.convert(controls.bounds, to: nil)
                    for name in ["imagesPanelBounds", "optionsPanelBounds"] {
                        let panel = try XCTUnwrap(probe(name, in: host))
                        XCTAssertFalse(bar.intersects(panel.convert(panel.bounds, to: nil)),
                                       "Controls must not overlap either panel during motion")
                    }
                }
            }
        }
        workspace.isProcessing = false
    }

    func testToolbarInkContrastsWithBothAppearances() throws {
        func luminance(_ color: NSColor) throws -> CGFloat {
            let color = try XCTUnwrap(color.usingColorSpace(.sRGB))
            func linear(_ channel: CGFloat) -> CGFloat {
                channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
        }
        let accent = try XCTUnwrap(NSColor(named: "AccentColor", bundle: .main))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var surface: NSColor?
            appearance.performAsCurrentDrawingAppearance { surface = accent.usingColorSpace(.sRGB) }
            let foreground = try luminance(ToolbarActionPalette.prominentInk(for: appearance))
            let background = try luminance(XCTUnwrap(surface))
            let contrast = (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "Normal toolbar text must meet contrast in \(name)")
            var neutralForeground: NSColor?
            var neutralBackground: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                neutralForeground = ToolbarActionPalette.neutralInk.usingColorSpace(.sRGB)
                neutralBackground = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)
            }
            let ink = try XCTUnwrap(neutralForeground)
            let paper = try XCTUnwrap(neutralBackground)
            let alpha = ink.alphaComponent
            let composed = NSColor(srgbRed: ink.redComponent * alpha + paper.redComponent * (1 - alpha),
                                   green: ink.greenComponent * alpha + paper.greenComponent * (1 - alpha),
                                   blue: ink.blueComponent * alpha + paper.blueComponent * (1 - alpha), alpha: 1)
            let inkLuminance = try luminance(composed), paperLuminance = try luminance(paper)
            let neutralContrast = (max(inkLuminance, paperLuminance) + 0.05) / (min(inkLuminance, paperLuminance) + 0.05)
            XCTAssertGreaterThanOrEqual(neutralContrast, 4.5, "Neutral action symbols must remain legible in \(name)")
        }
    }

    func testQueueGeometryStaysStableWhenOtherPanelToggles() {
        for size in [CGSize(width: 640, height: 440), CGSize(width: 865, height: 1084), CGSize(width: 1100, height: 760)] {
            let layout = CanvasPanelLayout(size: size)
            XCTAssertEqual(layout.frame(for: .images, openPanels: [.images]),
                           layout.frame(for: .images, openPanels: [.images, .options]))
        }
    }

    func testNativePopupKeepsRightAlignmentAndSelectionBinding() throws {
        var value = 640
        let host = NSHostingView(rootView: TrailingOptionPicker(title: "分块尺寸",
            selection: Binding(get: { value }, set: { value = $0 }),
            choices: [64, 256, 400, 640].map { ($0, "\($0) px") }))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 190, height: 28),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func findPopup(_ view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton { return popup }
            return view.subviews.lazy.compactMap { findPopup($0) }.first
        }
        let popup = try XCTUnwrap(findPopup(host))
        XCTAssertEqual(popup.alignment, .right)
        XCTAssertEqual(popup.font?.pointSize, 12)
        XCTAssertEqual(popup.itemTitles, ["64 px", "256 px", "400 px", "640 px"])
        XCTAssertEqual(popup.titleOfSelectedItem, "640 px")
        popup.selectItem(withTitle: "256 px")
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(value, 256, "Native menu actions must update the bound processing option")
    }

    func testOpenPanelsPassExposedCanvasInputThrough() async throws {
        let workspace = Workspace(persistOptions: false)
        workspace.openSample()
        while workspace.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        workspace.showsImages = true
        workspace.showsOptions = true
        let host = NSHostingView(rootView: ContentView(workspace: workspace))
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 1280, height: 760),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Canvas input regression"
        window.contentView = host
        defer { window.close(); workspace.shutdown() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        func findCanvas(in view: NSView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
        }
        let canvas = try XCTUnwrap(findCanvas(in: host))
        let point = host.convert(CGPoint(x: canvas.imageCenterX, y: 300), from: canvas)
        XCTAssertTrue(host.hitTest(point) === canvas, "Floating panels must not intercept the exposed canvas")
    }

    func testAspectFitAcrossWindowAndImageShapes() throws {
        for windowSize in [CGSize(width: 640, height: 440), CGSize(width: 1100, height: 760), CGSize(width: 800, height: 1000)] {
            for imageSize in [CGSize(width: 1600, height: 400), CGSize(width: 400, height: 1600), CGSize(width: 720, height: 480)] {
                let context = CGContext(data: nil, width: Int(imageSize.width), height: Int(imageSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                let canvas = CanvasView(frame: CGRect(origin: .zero, size: windowSize))
                canvas.original = context.makeImage()
                XCTAssertTrue(canvas.viewport.insetBy(dx: -0.01, dy: -0.01).contains(canvas.imageRect))
                XCTAssertEqual(canvas.imageRect.width / canvas.imageRect.height, imageSize.width / imageSize.height, accuracy: 0.0001)
            }
        }
    }

    func testFloatingPanelsExtendBehindTitlebarWithEqualWindowInsets() {
        for size in [CGSize(width: 640, height: 440), CGSize(width: 1100, height: 760), CGSize(width: 800, height: 1000)] {
            let layout = CanvasPanelLayout(size: size)
            for panel in [CanvasPanel.images, .options] {
                let frame = layout.frame(for: panel)
                XCTAssertGreaterThanOrEqual(frame.minX, 8)
                XCTAssertLessThanOrEqual(frame.maxX, size.width - 8)
                XCTAssertEqual(frame.minY, 8)
                XCTAssertEqual(frame.maxY, size.height - 8)
                XCTAssertEqual(panel == .images ? frame.minX : size.width - frame.maxX, 8)
                XCTAssertGreaterThan(frame.height - CanvasPanelLayout.titlebarClearance - CanvasPanelLayout.bottomClearance, 200)
                for controlsWidth: CGFloat in [260, 460] {
                    let offset = layout.presentationCenterX(for: [panel], controlsWidth: controlsWidth) - size.width / 2
                    let controls = CGRect(x: (size.width - controlsWidth) / 2 + offset,
                                          y: size.height - 60, width: controlsWidth, height: 40)
                    XCTAssertGreaterThanOrEqual(controls.minX, 0)
                    XCTAssertLessThanOrEqual(controls.maxX, size.width)
                    if (layout.exposedRange(for: [panel]).upperBound - layout.exposedRange(for: [panel]).lowerBound) >= controlsWidth + 16 { XCTAssertFalse(controls.intersects(frame)) }
                }
            }
            let both = Set(CanvasPanel.allCases)
            let queue = layout.frame(for: .images, openPanels: both)
            let settings = layout.frame(for: .options, openPanels: both)
            XCTAssertGreaterThanOrEqual(settings.minX - queue.maxX, 8)
            XCTAssertGreaterThanOrEqual(queue.width, 220)
            XCTAssertEqual(settings.width, 380)
            let offset = layout.presentationCenterX(for: both, controlsWidth: 260) - size.width / 2
            if settings.minX - queue.maxX >= 276 {
                let controls = CGRect(x: (size.width - 260) / 2 + offset, y: size.height - 60, width: 260, height: 40)
                XCTAssertFalse(controls.intersects(queue))
                XCTAssertFalse(controls.intersects(settings))
            }
        }
    }

    func testOriginalPixelBasisAndImageComparisonAccessibility() throws {
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        canvas.original = SampleArtwork.make()
        let output = try XCTUnwrap(CGContext(data: nil, width: 1440, height: 960, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.enhanced = output.makeImage()
        canvas.mode = .original
        XCTAssertEqual(canvas.base?.width, 720)
        let originalFit = canvas.fitPixelScale
        canvas.mode = .result
        XCTAssertEqual(canvas.base?.width, 1440)
        XCTAssertEqual(canvas.fitPixelScale, originalFit / 2, accuracy: 0.0001)
        canvas.zoom = 1 / canvas.fitPixelScale
        XCTAssertEqual(canvas.fitPixelScale * canvas.zoom, 1, accuracy: 0.0001)
        canvas.mode = .compare
        canvas.updateAccessibility()
        XCTAssertEqual(canvas.accessibilityRole(), .slider)
        XCTAssertEqual((canvas.accessibilityMinValue() as? NSNumber)?.doubleValue, 2)
        XCTAssertEqual((canvas.accessibilityMaxValue() as? NSNumber)?.doubleValue, 98)
        var changedSplit = 0.0
        canvas.onSplit = { changedSplit = $0 }
        XCTAssertTrue(canvas.accessibilityPerformIncrement())
        XCTAssertEqual(changedSplit, 0.55, accuracy: 0.0001)
        XCTAssertTrue(canvas.accessibilityPerformDecrement())
        XCTAssertEqual(changedSplit, 0.5, accuracy: 0.0001)
        canvas.setAccessibilityValue(NSNumber(value: 70))
        XCTAssertEqual(canvas.split, 0.7, accuracy: 0.0001)
        canvas.mode = .original
        canvas.updateAccessibility()
        XCTAssertFalse(canvas.accessibilityPerformIncrement())
        XCTAssertEqual(canvas.accessibilityRole(), .image)
    }

    func testNativeWindowStructureAndCanvasRendering() throws {
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == "Waifu2x" })
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.styleMask.contains(.miniaturizable))
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.zoomButton))
        // The actual AppKit controls must sit inside the floating queue's top
        // surface. The alignment bridge keeps the native button instances.
        let queueFrame = CanvasPanelLayout(size: window.frame.size).frame(for: .images)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let rect = button.convert(button.bounds, to: nil)
            let fromTop = CGRect(x: rect.minX, y: window.frame.height - rect.maxY,
                                 width: rect.width, height: rect.height)
            XCTAssertTrue(queueFrame.contains(fromTop), "Native window button must be inside the inset surface: \(fromTop)")
            XCTAssertLessThanOrEqual(fromTop.maxY, CanvasPanelLayout.inset + CanvasPanelLayout.titlebarClearance)
        }
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1100, height: 760))
        canvas.original = SampleArtwork.make()
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let image = NSImage(size: canvas.bounds.size)
        image.addRepresentation(rep)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Canvas 1100×760"
        attachment.lifetime = .keepAlways
        add(attachment)
        let path = URL(fileURLWithPath: "/tmp/Waifu2x-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: path.appendingPathComponent("canvas.png"))
        // Render this app's own view hierarchy, without screen recording services.
        if let content = window.contentView, let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: path.appendingPathComponent("window-content.png"))
        }
    }
}
