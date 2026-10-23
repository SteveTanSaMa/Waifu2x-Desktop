import Foundation
import CoreGraphics

final class ONNXRenderer: @unchecked Sendable {
    let runtime: ONNXRuntime
    init(threadCount: Int = 1) { runtime = ONNXRuntime(threadCount: threadCount) }
    func cancel() { runtime.cancel() }
    func run(input: ImageAsset, options: ProcessingOptions, directory: URL,
             progress: @escaping @Sendable (TileProgress) -> Void,
             stage: @escaping @Sendable (String) -> Void) throws -> URL {
        let passes = options.repeatsScale2 ? 2 : 1
        var image = input.image
        var completedOffset = 0
        var earlierPatches: [ProcessedPatch] = []
        let first = ONNXConfiguration(model: options.model, scale: passes == 2 ? 2 : options.scale, requestedTile: options.tileSize)
        let firstCount = first.blocks(length: image.width) * first.blocks(length: image.height)
        let secondCount = passes == 2 ? first.blocks(length: image.width * 2) * first.blocks(length: image.height * 2) : 0
        let total = firstCount + secondCount
        for pass in 0..<passes {
            try runtime.check()
            let multiplier = passes == 2 && pass == 0 ? 2 : 1
            var passPatches: [ProcessedPatch] = []
            image = try render(image, options: options, scale: passes == 2 ? 2 : options.scale, noise: pass == 0 ? options.noise : -1,
                               pass: pass, stage: stage) { update in
                let mapped = update.completedRects.map { CGRect(x: $0.minX * CGFloat(multiplier), y: $0.minY * CGFloat(multiplier), width: $0.width * CGFloat(multiplier), height: $0.height * CGFloat(multiplier)) }
                let active = update.activeRect.map { CGRect(x: $0.minX * CGFloat(multiplier), y: $0.minY * CGFloat(multiplier), width: $0.width * CGFloat(multiplier), height: $0.height * CGFloat(multiplier)) }
                passPatches = update.patches.map { patch in
                    ProcessedPatch(image: patch.image, rect: CGRect(x: patch.rect.minX * CGFloat(multiplier), y: patch.rect.minY * CGFloat(multiplier),
                                       width: patch.rect.width * CGFloat(multiplier), height: patch.rect.height * CGFloat(multiplier)))
                }
                progress(TileProgress(completed: completedOffset + update.completed, total: total, activeRect: active,
                                      preview: update.preview, patches: earlierPatches + passPatches, completedRects: mapped))
            }
            earlierPatches += passPatches
            completedOffset += firstCount
        }
        try runtime.check()
        stage(L("正在生成无损 PNG"))
        let output = directory.appendingPathComponent("result-\(UUID().uuidString).png")
        try ImageCodec.writePNG(image, to: output)
        return output
    }
    private func render(_ image: CGImage, options: ProcessingOptions, scale: Int, noise: Int, pass: Int,
                        stage: @escaping @Sendable (String) -> Void,
                        progress: (TileProgress) -> Void) throws -> CGImage {
        let config = ONNXConfiguration(model: options.model, scale: scale, requestedTile: options.tileSize)
        stage(L("正在准备 %@ · %@", options.model.title, options.resolvedBackend.title))
        let input = try ONNXImageTensors(image: image, alpha: options.alpha)
        let columns = config.blocks(length: image.width), rows = config.blocks(length: image.height)
        let total = columns * rows
        let paddedWidth = (columns - 1) * config.inputStep + config.tile
        let paddedHeight = (rows - 1) * config.inputStep + config.tile
        let padding: [String: W2XTensor] = ["left": .scalar(config.inputOffset), "right": .scalar(paddedWidth - image.width - config.inputOffset),
                                          "top": .scalar(config.inputOffset), "bottom": .scalar(paddedHeight - image.height - config.inputOffset)]
        func pad(_ tensor: W2XTensor) throws -> W2XTensor {
            try runtime.helper(config.reflection ? "reflection_pad" : "replication_pad", padding.merging(["x": tensor]) { _, new in new })
        }
        var rgb = input.rgb
        if let alpha = input.alpha1 {
            rgb = try runtime.helper("alpha_border_padding", ["rgb": rgb.reshaped(Array(rgb.dimensions.dropFirst())),
                         "alpha": alpha.reshaped(Array(alpha.dimensions.dropFirst())), "offset": .scalar(config.offset)])
            rgb = rgb.reshaped([1] + rgb.dimensions)
        }
        rgb = try pad(rgb)
        let alpha = try input.alpha3.map(pad)
        let filter = try runtime.helper("create_seam_blending_filter", ["scale": .scalar(scale), "offset": .scalar(config.offset), "tile_size": .scalar(config.tile)])
        let compositor = ONNXCompositor(width: image.width * scale, height: image.height * scale, filter: filter, keepAlpha: alpha != nil)
        var positions = (0..<rows).flatMap { row in (0..<columns).map { (row, $0) } }
        if options.shuffle { positions.shuffle() }
        var completedRects: [CGRect] = []
        var patches: [ProcessedPatch] = []
        var backend = options.resolvedBackend
        for (index, position) in positions.enumerated() {
            try runtime.check()
            let (row, column) = position
            let rect = CGRect(x: column * config.outputStep, y: row * config.outputStep,
                              width: min(config.tile * scale - config.offset * 2, image.width * scale - column * config.outputStep),
                              height: min(config.tile * scale - config.offset * 2, image.height * scale - row * config.outputStep))
            progress(TileProgress(completed: index, total: total, activeRect: rect, preview: nil, patches: patches, completedRects: completedRects))
            stage(pass > 0 ? L("第 2 轮 · 分块 %d / %d · %@", index + 1, total, backend.title) : L("分块 %d / %d · %@", index + 1, total, backend.title))
            var tile = ONNXImageTensors.crop(rgb, x: column * config.inputStep, y: row * config.inputStep, size: config.tile)
            let tileAlpha = alpha.map { ONNXImageTensors.crop($0, x: column * config.inputStep, y: row * config.inputStep, size: config.tile) }
            var output: W2XTensor
            var alphaOutput: W2XTensor?
            if config.preservesFlatColors, let flat = ONNXImageTensors.flatOutput(tile, alpha: tileAlpha, size: config.tile * scale - config.offset * 2) {
                (output, alphaOutput) = flat
            } else {
                if options.tta > 0 { tile = try runtime.helper("tta_split", ["x": tile, "tta_level": .scalar(options.tta)]) }
                do { output = try runtime.run(config.modelPath(noise: noise), inputs: ["x": tile], backend: backend) }
                catch {
                    try runtime.check()
                    guard options.backend == .automatic, backend == .webGPU else { throw error }
                    backend = .cpu
                    stage(L("WebGPU 不可用，正在使用 CPU"))
                    output = try runtime.run(config.modelPath(noise: noise), inputs: ["x": tile], backend: .cpu)
                }
                if options.tta > 0 { output = try runtime.helper("tta_merge", ["x": output, "tta_level": .scalar(options.tta)]) }
                if let tileAlpha { alphaOutput = try runtime.run(config.modelPath(noise: -1), inputs: ["x": tileAlpha], backend: backend) }
            }
            let patch = try compositor.update(rgb: output, alpha: alphaOutput, x: column * config.outputStep, y: row * config.outputStep)
            patches.append(ProcessedPatch(image: patch, rect: rect))
            completedRects.append(rect)
            progress(TileProgress(completed: index + 1, total: total, activeRect: nil, preview: nil, patches: patches, completedRects: completedRects))
        }
        return try compositor.snapshot()
    }
}
