import Foundation
import CoreGraphics

/// A cancellable, isolated worker. No shell, network, or external installation.
final class NcnnEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    let root: URL
    let modelRoot: URL

    init(root: URL = Bundle.main.resourceURL!.appendingPathComponent("Engine"), modelRoot: URL = ModelPaths.current.engine) {
        self.root = root; self.modelRoot = modelRoot
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    private func checkCancellation() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }

    /// The outer tile boundary is owned by Swift, so every progress event represents
    /// completed inference rather than a timer. 64 px of context is discarded at
    /// tile edges (128 px for two-pass 4×), preserving model context across seams.
    func run(input original: ImageAsset, options: ProcessingOptions, directory: URL,
             progress: @escaping @Sendable (TileProgress) -> Void = { _ in },
             stage: @escaping @Sendable (String) -> Void) throws -> URL {
        guard options.isValid else { throw AppFailure.message(L("仅降噪模式需要选择降噪强度。")) }
        let input: ImageAsset
        if options.alpha == .disabled {
            let flattened = try ImageCodec.flattenToWhite(original.image)
            let url = directory.appendingPathComponent("opaque-\(UUID().uuidString).png")
            try ImageCodec.writePNG(flattened, to: url)
            input = ImageAsset(url: url, image: flattened, name: original.name)
        } else { input = original }
        defer { if input.url != original.url { try? FileManager.default.removeItem(at: input.url) } }
        let width = input.image.width, height = input.image.height, scale = options.scale
        try ImageCodec.validateOutputDimensions(width: width, height: height, scale: scale)
        let tile = options.tileSize
        let halo = scale == 4 ? 128 : 64
        let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        let total = columns * rows
        guard let composite = CGContext(data: nil, width: width * scale, height: height * scale,
                                        bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message(L("内存不足，无法创建输出画布。请降低放大倍数。"))
        }
        var completedRects: [CGRect] = []
        var positions = (0..<rows).flatMap { row in (0..<columns).map { (row, $0) } }
        if options.shuffle { positions.shuffle() }
        var completed = 0
        var snapshot: CGImage?
        for (row, column) in positions {
                try checkCancellation()
                let x = column * tile, y = row * tile
                let core = CGRect(x: x, y: y, width: min(tile, width - x), height: min(tile, height - y))
                let padded = core.insetBy(dx: -CGFloat(halo), dy: -CGFloat(halo))
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                let outputRect = CGRect(x: core.minX * CGFloat(scale), y: core.minY * CGFloat(scale),
                                        width: core.width * CGFloat(scale), height: core.height * CGFloat(scale))
                progress(TileProgress(completed: completed, total: total, activeRect: outputRect, preview: snapshot, completedRects: completedRects))
                guard let cropped = input.image.cropping(to: padded) else { throw AppFailure.message(L("无法读取图片分块。")) }
                let tileURL = directory.appendingPathComponent("tile-\(UUID().uuidString).png")
                try ImageCodec.writePNG(cropped, to: tileURL)
                let asset = ImageAsset(url: tileURL, image: cropped, name: input.name)
                let blockNumber = completed + 1
                let output: URL
                do {
                    output = try runPasses(input: asset, options: options, directory: directory) {
                        stage(L("分块 %d / %d · %@", blockNumber, total, $0))
                    }
                } catch { try? FileManager.default.removeItem(at: tileURL); throw error }
                defer { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: tileURL) }
                try checkCancellation()
                let processed = try ImageCodec.readPNG(output)
                let cropRect = CGRect(x: (core.minX - padded.minX) * CGFloat(scale),
                                      y: (core.minY - padded.minY) * CGFloat(scale),
                                      width: outputRect.width, height: outputRect.height)
                guard let center = processed.cropping(to: cropRect) else { throw AppFailure.message(L("无法合成图片分块。")) }
                // CGContext uses a bottom-left origin; tile coordinates use top-left.
                composite.setBlendMode(.copy)
                composite.draw(center, in: CGRect(x: outputRect.minX,
                               y: CGFloat(height * scale) - outputRect.maxY,
                               width: outputRect.width, height: outputRect.height))
                completedRects.append(outputRect)
                completed += 1
                snapshot = composite.makeImage()
                progress(TileProgress(completed: completed, total: total, activeRect: nil, preview: snapshot, completedRects: completedRects))
        }
        try checkCancellation()
        stage(L("正在生成无损 PNG"))
        let output = directory.appendingPathComponent("result-\(UUID().uuidString).png")
        guard let final = composite.makeImage() else { throw AppFailure.message(L("无法合成输出图片。")) }
        try ImageCodec.writePNG(final, to: output)
        return output
    }

    private func runPasses(input: ImageAsset, options: ProcessingOptions, directory: URL,
             stage: @escaping @Sendable (String) -> Void) throws -> URL {
        guard options.isValid else { throw AppFailure.message(L("仅降噪模式需要选择降噪强度。")) }
        try ImageCodec.validateOutputDimensions(width: input.image.width, height: input.image.height, scale: options.scale)
        let passCount = options.scale == 4 ? 2 : 1
        var source = input.url
        for pass in 0..<passCount {
            try checkCancellation()
            stage(passCount == 2 ? L("正在处理 · 第 %d / 2 轮", pass + 1) : (options.scale == 1 ? L("正在降噪") : L("正在增强细节")))
            let output = directory.appendingPathComponent("result-\(UUID().uuidString).png")
            let worker = Process()
            worker.executableURL = root.appendingPathComponent("waifu2x-ncnn-vulkan")
            worker.currentDirectoryURL = root
            worker.arguments = ["-i", source.path, "-o", output.path, "-m", modelRoot.appendingPathComponent(options.modelDirectory).path,
                                "-s", options.scale == 1 ? "1" : "2", "-n", String(pass == 0 ? options.noise : -1),
                                "-t", String(options.tileSize), "-j", "1:\(options.inferenceThreads):1"]
            let pipe = Pipe()
            worker.standardError = pipe
            worker.standardOutput = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            process = worker
            do { try worker.run() } catch {
                process = nil; lock.unlock()
                throw AppFailure.message(L("无法启动内置推理引擎：%@", error.localizedDescription))
            }
            lock.unlock()
            // Drain while running, so verbose driver diagnostics cannot fill the pipe.
            let diagnostic = pipe.fileHandleForReading.readDataToEndOfFile()
            worker.waitUntilExit()
            lock.lock(); process = nil; lock.unlock()
            try checkCancellation()
            guard worker.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
                let log = String(decoding: diagnostic.suffix(2500), as: UTF8.self)
                throw AppFailure.message(L("处理失败（引擎退出码 %d）。请检查图片或重新尝试。\n\n%@", worker.terminationStatus, log))
            }
            if source != input.url { try? FileManager.default.removeItem(at: source) }
            source = output
        }
        return source
    }
}
