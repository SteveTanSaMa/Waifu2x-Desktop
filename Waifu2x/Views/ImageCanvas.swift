import SwiftUI
import AppKit

/// AppKit is limited to precise pixel rendering and desktop scroll / magnify input.
struct ImageCanvas: NSViewRepresentable {
    @ObservedObject var workspace: Workspace
    var presentation: CanvasPresentation? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeNSView(context: Context) -> CanvasView { CanvasView() }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.isInteractionEnabled = isEnabled
        presentation?.connect(view)
        view.original = workspace.input?.image
        view.enhanced = workspace.isSelectedProcessing ? nil : workspace.result?.asset.image
        view.partial = workspace.isSelectedProcessing ? workspace.tileProgress : nil
        view.outputScale = (workspace.activeOptions ?? workspace.options).scale
        view.mode = workspace.preview
        view.split = workspace.split
        view.zoom = workspace.zoom
        view.setOpenPanels(workspace.activePanels, animated: !reduceMotion && view.window != nil)
        view.onZoom = { workspace.zoom = $0; workspace.actualSizeRequested = false }
        view.onSplit = { workspace.split = $0 }
        view.onReset = { workspace.resetView() }
        view.onPixelScale = { scale in
            DispatchQueue.main.async {
                if abs(workspace.pixelScale - scale) > 0.0001 { workspace.pixelScale = scale }
            }
        }
        view.updateAccessibility()
        if view.assetID != workspace.input?.id { view.assetID = workspace.input?.id; view.pan = .zero }
        if view.resetID != workspace.viewResetID { view.resetID = workspace.viewResetID; view.pan = .zero }
        if workspace.actualSizeRequested {
            let actual = 1 / max(view.fitPixelScale, 0.001)
            DispatchQueue.main.async { workspace.zoom = actual; workspace.actualSizeRequested = false }
        }
        view.window?.invalidateCursorRects(for: view)
        view.needsDisplay = true
    }
}

final class CanvasView: NSView {
    // Covered canvases retain their drawing state while native input is suspended.
    var isInteractionEnabled = true {
        didSet {
            guard oldValue != isInteractionEnabled else { return }
            setAccessibilityEnabled(isInteractionEnabled)
            if !isInteractionEnabled {
                draggingSplit = false
                if pushedPanCursor { NSCursor.pop(); pushedPanCursor = false }
                if window?.firstResponder === self { window?.makeFirstResponder(nil) }
            }
            window?.invalidateCursorRects(for: self)
        }
    }
    var original: CGImage?
    var enhanced: CGImage?
    var partial: TileProgress?
    var outputScale = 2
    var assetID: UUID?
    var resetID: UUID?
    // A panel transition preserves the user's pan, including at its old limit.
    var openPanels: Set<CanvasPanel> = []
    var onPresentationChange: (() -> Void)?
    private var previousLayoutSize: CGSize = .zero
    private var centerAnimation: CanvasCenterAnimation?
    private var centerOffset: CGFloat = 0
    func setOpenPanels(_ panels: Set<CanvasPanel>, animated: Bool) {
        guard panels != openPanels else { return }
        let previousCenter = imageCenterX
        centerAnimation?.stop()
        centerAnimation = nil
        openPanels = panels
        centerOffset = previousCenter - CanvasPanelLayout(size: bounds.size).presentationCenterX(for: panels)
        guard animated, abs(centerOffset) > 0.1 else { centerOffset = 0; onPresentationChange?(); needsDisplay = true; return }
        let startOffset = centerOffset
        let animation = CanvasCenterAnimation(duration: PanelMotion.duration, animationCurve: .easeInOut)
        animation.animationBlockingMode = .nonblocking
        animation.frameRate = 60
        animation.update = { [weak self] value in
            self?.centerOffset = startOffset * (1 - value)
            self?.onPresentationChange?()
            self?.needsDisplay = true
        }
        centerAnimation = animation
        animation.start()
    }
    var mode: PreviewMode = .original
    var split = 0.5
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var onZoom: ((CGFloat) -> Void)?
    var onSplit: ((Double) -> Void)?
    var onReset: (() -> Void)?
    var onPixelScale: ((CGFloat) -> Void)?
    private var lastPixelScale: CGFloat = 0
    private var lastPoint = CGPoint.zero
    private var draggingSplit = false
    private var pushedPanCursor = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isInteractionEnabled }
    override var mouseDownCanMoveWindow: Bool { false }
    var base: CGImage? {
        if let partial { return partial.preview ?? original }
        return mode == .original ? original : (enhanced ?? original)
    }
    var viewport: CGRect { CGRect(x: 16, y: 58, width: max(1, bounds.width - 32), height: max(1, bounds.height - 134)) }
    var fitScale: CGFloat {
        guard let base else { return 1 }
        return max(0.001, min(viewport.width / CGFloat(base.width), viewport.height / CGFloat(base.height)))
    }
    var fitPixelScale: CGFloat {
        guard let base else { return 1 }
        let referenceWidth = partial != nil ? (original?.width ?? base.width) * outputScale : base.width
        return fitScale * CGFloat(base.width) / CGFloat(max(1, referenceWidth)) * (window?.backingScaleFactor ?? 2)
    }
    var imageCenterX: CGFloat { CanvasPanelLayout(size: bounds.size).presentationCenterX(for: openPanels) + centerOffset }
    var imageRect: CGRect {
        guard let base else { return .zero }
        let size = CGSize(width: CGFloat(base.width) * fitScale * zoom, height: CGFloat(base.height) * fitScale * zoom)
        let offsetX = pan.width
        let offsetY = min(max(pan.height, panLimits.y.lowerBound), panLimits.y.upperBound)
        return CGRect(x: imageCenterX - size.width / 2 + offsetX, y: viewport.midY - size.height / 2 + offsetY, width: size.width, height: size.height)
    }

    /// Fit uses the full canvas; only the horizontal origin follows panel visibility.
    private var panLimits: (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        guard let base else { return (0...0, 0...0) }
        let layout = CanvasPanelLayout(size: bounds.size)
        let visibleLeft = openPanels.contains(.images) ? max(viewport.minX, layout.frame(for: .images, openPanels: openPanels).maxX) : viewport.minX
        let visibleRight = openPanels.contains(.options) ? min(viewport.maxX, layout.frame(for: .options, openPanels: openPanels).minX) : viewport.maxX
        let width = CGFloat(base.width) * fitScale * zoom
        let height = CGFloat(base.height) * fitScale * zoom
        let x = min(0, visibleRight - imageCenterX - width / 2)...max(0, visibleLeft - imageCenterX + width / 2)
        let y = min(0, (viewport.height - height) / 2)...max(0, (height - viewport.height) / 2)
        return (x, y)
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(L("图片画布。双击适合窗口，触控板捏合缩放，拖动平移。"))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        reportPixelScale()
        guard let original else { return }
        let rect = imageRect
        guard rect.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect.intersection(bounds)).addClip()
        // Subtle checkerboard is visible only through transparent pixels.
        func checker() {
            NSColor(white: 0.86, alpha: 1).setFill(); rect.fill()
            let tile: CGFloat = 10
            let clipped = rect.intersection(bounds)
            for row in Int(clipped.minY / tile)...Int(clipped.maxY / tile) {
                for column in Int(clipped.minX / tile)...Int(clipped.maxX / tile) where (row + column) % 2 == 0 {
                    NSColor(white: 0.92, alpha: 1).setFill()
                    CGRect(x: CGFloat(column)*tile, y: CGFloat(row)*tile, width: tile, height: tile).fill()
                }
            }
        }
        checker()
        func drawImage(_ image: CGImage) {
            NSGraphicsContext.current?.imageInterpolation = .high
            NSImage(cgImage: image, size: rect.size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        if let partial {
            drawImage(original)
            let outputWidth = CGFloat(original.width * outputScale)
            let outputHeight = CGFloat(original.height * outputScale)
            func canvasRect(_ pixel: CGRect) -> CGRect {
                CGRect(x: rect.minX + pixel.minX / outputWidth * rect.width,
                       y: rect.minY + pixel.minY / outputHeight * rect.height,
                       width: pixel.width / outputWidth * rect.width, height: pixel.height / outputHeight * rect.height)
            }
            for patch in partial.patches {
                let destination = canvasRect(patch.rect)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: destination).addClip()
                checker()
                NSImage(cgImage: patch.image, size: destination.size).draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let preview = partial.preview, partial.completed > 0 {
                let path = NSBezierPath()
                for completed in partial.completedRects { path.appendRect(canvasRect(completed)) }
                NSGraphicsContext.saveGraphicsState()
                path.addClip(); checker(); drawImage(preview)
                NSGraphicsContext.restoreGraphicsState()
            }
            if let active = partial.activeRect {
                NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
                canvasRect(active).fill()
            }
        } else if mode == .original || enhanced == nil { drawImage(original) }
        else if let enhanced {
            drawImage(enhanced)
            if mode == .compare {
                NSGraphicsContext.saveGraphicsState()
                CGRect(x: rect.minX, y: rect.minY, width: rect.width * split, height: rect.height).clip()
                checker(); drawImage(original)
                NSGraphicsContext.restoreGraphicsState()
                let x = rect.minX + rect.width * split
                NSColor.white.withAlphaComponent(0.9).setFill()
                CGRect(x: x-0.5, y: rect.minY, width: 1, height: rect.height).fill()
                let handle = CGRect(x: x-14, y: min(max(rect.midY, 90), bounds.height-100)-14, width: 28, height: 28)
                NSColor.black.withAlphaComponent(0.45).setFill(); NSBezierPath(ovalIn: handle).fill()
                let symbol = NSImage(systemSymbolName: "arrow.left.and.right", accessibilityDescription: nil)!
                symbol.draw(in: handle.insetBy(dx: 7, dy: 7), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func layout() {
        super.layout()
        if previousLayoutSize != bounds.size {
            previousLayoutSize = bounds.size
            clampPan()
        }
        onPresentationChange?()
        reportPixelScale()
    }
    private func reportPixelScale() {
        guard base != nil else { return }
        let scale = fitPixelScale * zoom
        guard abs(lastPixelScale - scale) > 0.0001 else { return }
        lastPixelScale = scale
        onPixelScale?(scale)
    }
    func updateAccessibility() {
        let comparing = mode == .compare && enhanced != nil && partial == nil
        setAccessibilityRole(comparing ? .slider : .image)
        setAccessibilityLabel(comparing ? L("原图与结果比较分界线。左右方向键调整位置。") : L("图片画布。双击适合窗口，触控板捏合缩放，拖动平移。"))
        super.setAccessibilityValue(comparing ? NSNumber(value: split * 100) : nil)
        setAccessibilityMinValue(comparing ? NSNumber(value: 2) : nil)
        setAccessibilityMaxValue(comparing ? NSNumber(value: 98) : nil)
    }
    override func setAccessibilityValue(_ value: Any?) {
        guard isInteractionEnabled else { return }
        if mode == .compare, enhanced != nil, partial == nil, let number = value as? NSNumber {
            let next = min(0.98, max(0.02, number.doubleValue / 100))
            if abs(next - split) > 0.0001 { split = next; onSplit?(next); needsDisplay = true }
            super.setAccessibilityValue(NSNumber(value: split * 100))
        } else { super.setAccessibilityValue(value) }
    }
    override func accessibilityPerformIncrement() -> Bool { adjustComparison(by: 0.05) }
    override func accessibilityPerformDecrement() -> Bool { adjustComparison(by: -0.05) }
    @discardableResult
    private func adjustComparison(by amount: Double) -> Bool {
        guard isInteractionEnabled, mode == .compare, enhanced != nil, partial == nil else { return false }
        split = min(0.98, max(0.02, split + amount))
        onSplit?(split)
        updateAccessibility()
        needsDisplay = true
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if event.keyCode == 123 && adjustComparison(by: -0.02) { return }
        if event.keyCode == 124 && adjustComparison(by: 0.02) { return }
        super.keyDown(with: event)
    }
    override func resetCursorRects() {
        guard isInteractionEnabled else { return }
        let canPan = panLimits.x.lowerBound < panLimits.x.upperBound || panLimits.y.lowerBound < panLimits.y.upperBound
        addCursorRect(bounds, cursor: canPan ? .openHand : .arrow)
        if mode == .compare && enhanced != nil {
            let rect = imageRect
            addCursorRect(CGRect(x: rect.minX + rect.width * split-12, y: rect.minY, width: 24, height: rect.height), cursor: .resizeLeftRight)
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { pan = .zero; onReset?(); return }
        pushedPanCursor = false
        lastPoint = convert(event.locationInWindow, from: nil)
        draggingSplit = mode == .compare && abs(lastPoint.x - (imageRect.minX + imageRect.width * split)) < 24
        if !draggingSplit { NSCursor.closedHand.push(); pushedPanCursor = true }
    }
    override func mouseDragged(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if draggingSplit {
            split = min(0.98, max(0.02, (point.x - imageRect.minX) / imageRect.width)); onSplit?(split)
        } else {
            pan.width += point.x-lastPoint.x; pan.height += point.y-lastPoint.y
            clampPan()
        }
        lastPoint = point; needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if pushedPanCursor { NSCursor.pop(); pushedPanCursor = false }; window?.invalidateCursorRects(for: self) }
    override func magnify(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        zoom(to: zoom * (1 + event.magnification), at: convert(event.locationInWindow, from: nil))
    }
    override func scrollWheel(with event: NSEvent) {
        guard isInteractionEnabled else { return }
        if event.modifierFlags.contains(.command) { zoom(to: zoom * (1 + event.scrollingDeltaY * 0.01), at: convert(event.locationInWindow, from: nil)) }
        else { pan.width += event.scrollingDeltaX; pan.height += event.scrollingDeltaY; clampPan(); needsDisplay = true }
    }
    private func zoom(to value: CGFloat, at anchor: CGPoint) {
        let next = min(20, max(0.25, value))
        let old = imageRect
        guard old.width > 0, old.height > 0 else { return }
        let fx = (anchor.x - old.minX) / old.width, fy = (anchor.y - old.minY) / old.height
        pan.width = anchor.x - imageCenterX - (fx - 0.5) * old.width * next / zoom
        pan.height = anchor.y - viewport.midY - (fy - 0.5) * old.height * next / zoom
        zoom = next
        clampPan()
        onZoom?(next)
        needsDisplay = true
    }
    private func clampPan() {
        pan.width = min(max(pan.width, panLimits.x.lowerBound), panLimits.x.upperBound)
        pan.height = min(max(pan.height, panLimits.y.lowerBound), panLimits.y.upperBound)
    }
}

/// Redraw the pixel canvas at presentation positions, including interrupted moves.
private final class CanvasCenterAnimation: NSAnimation {
    var update: ((CGFloat) -> Void)?
    override var currentProgress: NSAnimation.Progress {
        get { super.currentProgress }
        set { super.currentProgress = newValue; update?(CGFloat(currentValue)) }
    }
}
