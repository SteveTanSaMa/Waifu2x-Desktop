import Foundation
import CoreGraphics

/// The same cumulative, order-independent 16 px seam blending as the web client.
final class ONNXCompositor {
    let width: Int, height: Int
    let filter: [Float]
    let tile: Int
    private var rgb: [Float]
    private var alpha: [Float]
    private var weights: [Float]
    private var rgba: [UInt8]
    init(width: Int, height: Int, filter: W2XTensor, keepAlpha: Bool) {
        self.width = width; self.height = height
        self.filter = filter.floats; tile = filter.dimensions.last!
        rgb = [Float](repeating: 0, count: width * height * 3)
        alpha = keepAlpha ? [Float](repeating: 0, count: width * height) : []
        weights = [Float](repeating: 0, count: width * height)
        rgba = [UInt8](repeating: 0, count: width * height * 4)
    }
    func update(rgb output: W2XTensor, alpha alphaOutput: W2XTensor?, x: Int, y: Int) throws -> CGImage {
        let pixels = output.floats, opacity = alphaOutput?.floats
        let area = tile * tile
        guard pixels.count == area * 3, filter.count == area * 3 else { throw AppFailure.message(L("模型输出尺寸与分块配置不匹配。")) }
        for row in 0..<min(tile, height - y) {
            for column in 0..<min(tile, width - x) {
                let source = row * tile + column, target = (y + row) * width + x + column
                let weight = filter[source]
                let next = weights[target] + weight
                guard next > 0 else { continue }
                for c in 0..<3 {
                    rgb[target * 3 + c] = (rgb[target * 3 + c] * weights[target] + pixels[c * area + source] * weight) / next
                    rgba[target * 4 + c] = UInt8(clamping: Int((min(1, max(0, rgb[target * 3 + c])) * 255 + 0.49999)))
                }
                if let opacity {
                    let a = (opacity[source] + opacity[area + source] + opacity[area * 2 + source]) / 3
                    alpha[target] = (alpha[target] * weights[target] + a * weight) / next
                    rgba[target * 4 + 3] = UInt8(clamping: Int(min(1, max(0, alpha[target])) * 255 + 0.49999))
                } else { rgba[target * 4 + 3] = 255 }
                weights[target] = next
            }
        }
        let patchWidth = min(tile, width - x), patchHeight = min(tile, height - y)
        var patch = [UInt8](repeating: 0, count: patchWidth * patchHeight * 4)
        for row in 0..<patchHeight {
            let source = ((y + row) * width + x) * 4
            patch.replaceSubrange((row * patchWidth * 4)..<((row + 1) * patchWidth * 4), with: rgba[source..<(source + patchWidth * 4)])
        }
        return try makeImage(patch, width: patchWidth, height: patchHeight)
    }
    func snapshot() throws -> CGImage { try makeImage(rgba, width: width, height: height) }
    private func makeImage(_ rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data), let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                          bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                          decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw AppFailure.message(L("无法合成处理结果。"))
        }
        return image
    }
}
