import Foundation

/// Mirrors unlimited.waifu2x.net/js/models.js and seam_blending.js.
struct ONNXConfiguration {
    let scale: Int
    let model: WaifuModel
    let tile: Int
    let offset: Int
    let inputOffset: Int
    let inputStep: Int
    let outputStep: Int
    var reflection: Bool { model == .swinPhoto }
    var preservesFlatColors: Bool { model != .swinScan && model != .swinPhoto }
    init(model: WaifuModel, scale: Int, requestedTile: Int) {
        self.scale = scale; self.model = model
        switch model {
        case .cunet:
            offset = scale == 1 ? 28 : 36
            let adjusted = (requestedTile * scale + offset * 2 - (scale == 1 ? 16 : 32)) / scale
            tile = adjusted - adjusted % 4
        case .swinV3:
            offset = 8 * scale
            tile = max(64, ((requestedTile + 31) / 32) * 32)
        default:
            offset = 8 * scale
            var adjusted = requestedTile
            while (adjusted - 16) % 12 != 0 || (adjusted - 16) % 16 != 0 { adjusted += 1 }
            tile = adjusted
        }
        inputOffset = Int(ceil(Double(offset) / Double(scale)))
        inputStep = tile - (inputOffset * 2 + Int(ceil(16.0 / Double(scale))))
        outputStep = inputStep * scale
    }
    func modelPath(noise: Int) -> String {
        "\(model.architecture)/\(model.domain)/\(ProcessingOptions.method(scale: scale, noise: noise)).onnx"
    }
    func blocks(length: Int) -> Int {
        var count = 1
        while (count - 1) * inputStep + tile < length + inputOffset * 2 { count += 1 }
        return count
    }
}
