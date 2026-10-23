import Foundation
import CoreGraphics

struct ONNXImageTensors {
    let rgb: W2XTensor
    let alpha1: W2XTensor?
    let alpha3: W2XTensor?
    init(image: CGImage, alpha: AlphaMode) throws {
        let w = image.width, h = image.height, count = w * h
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message(L("无法准备图片张量。"))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        let keepAlpha = alpha == .auto && (0..<count).contains { bytes[$0 * 4 + 3] != 255 }
        var colors = [Float](repeating: 0, count: count * 3)
        var alphas = keepAlpha ? [Float](repeating: 0, count: count) : []
        for p in 0..<count {
            let a = Float(bytes[p * 4 + 3]) / 255
            if keepAlpha { alphas[p] = a }
            for c in 0..<3 {
                let premultiplied = Float(bytes[p * 4 + c]) / 255
                colors[c * count + p] = keepAlpha ? (a > 0 ? min(1, premultiplied / a) : 0) : premultiplied + 1 - a
            }
        }
        rgb = .floats(colors, shape: [1, 3, h, w])
        alpha1 = keepAlpha ? .floats(alphas, shape: [1, 1, h, w]) : nil
        alpha3 = keepAlpha ? .floats(alphas + alphas + alphas, shape: [1, 3, h, w]) : nil
    }
    static func flatOutput(_ rgb: W2XTensor, alpha: W2XTensor?, size: Int) -> (W2XTensor, W2XTensor?)? {
        let colors = rgb.floats, area = rgb.dimensions[2] * rgb.dimensions[3]
        let opacity = alpha?.floats
        for c in 0..<3 {
            let value = colors[c * area]
            if !(0..<area).allSatisfy({ colors[c * area + $0] == value }) { return nil }
        }
        if let opacity, !opacity.allSatisfy({ $0 == opacity[0] }) { return nil }
        let resultArea = size * size
        let result = (0..<3).flatMap { [Float](repeating: colors[$0 * area], count: resultArea) }
        let resultAlpha = opacity.map { W2XTensor.floats([Float](repeating: $0[0], count: resultArea * 3), shape: [1, 3, size, size]) }
        return (.floats(result, shape: [1, 3, size, size]), resultAlpha)
    }

    static func crop(_ tensor: W2XTensor, x: Int, y: Int, size: Int) -> W2XTensor {
        let dimensions = tensor.dimensions, h = dimensions[2], w = dimensions[3]
        var result = [Float](repeating: 0, count: 3 * size * size)
        tensor.data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            result.withUnsafeMutableBufferPointer { destination in
                for c in 0..<3 {
                    for row in 0..<size {
                        let offset = c * h * w + (y + row) * w + x
                        destination.baseAddress!.advanced(by: c * size * size + row * size)
                            .update(from: source.baseAddress!.advanced(by: offset), count: size)
                    }
                }
            }
        }
        return .floats(result, shape: [1, 3, size, size])
    }
}
