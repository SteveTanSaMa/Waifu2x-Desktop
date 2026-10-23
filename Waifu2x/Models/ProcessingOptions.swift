import Foundation
import CoreGraphics

struct ProcessingOptions: Equatable, Codable, Sendable {
    var scale: Int { didSet { if scale > 1 { enlargement = scale } } }
    var noise: Int { didSet { if noise >= 0 { denoiseLevel = noise } } }
    private(set) var enlargement: Int = 2
    private(set) var denoiseLevel: Int = 0
    var upscaleEnabled: Bool {
        get { scale > 1 }
        set { scale = newValue ? enlargement : 1 }
    }
    var denoiseEnabled: Bool {
        get { noise >= 0 }
        set { noise = newValue ? denoiseLevel : -1 }
    }
    var model: WaifuModel
    var backend: InferenceBackend
    var tileSize: Int
    var multithreading: Bool
    var inferenceThreads: Int { multithreading ? max(1, min(8, ProcessInfo.processInfo.activeProcessorCount)) : 1 }
    var shuffle: Bool
    var tta: Int
    var alpha: AlphaMode

    init(scale: Int = 2, noise: Int = 0, style: ImageStyle? = nil, model: WaifuModel = .swinV3,
         backend: InferenceBackend = .automatic, tileSize: Int = 256, shuffle: Bool = false,
         tta: Int = 0, alpha: AlphaMode = .auto, multithreading: Bool = false) {
        self.scale = scale; self.noise = noise; self.multithreading = multithreading
        enlargement = scale > 1 ? scale : 2; denoiseLevel = max(0, noise)
        self.model = style.map { $0 == .photo ? .upconvPhoto : .cunet } ?? model
        self.backend = backend; self.tileSize = tileSize; self.shuffle = shuffle; self.tta = tta; self.alpha = alpha
    }
    private enum CodingKeys: String, CodingKey {
        case scale, noise, enlargement, denoiseLevel, model, backend, tileSize, shuffle, tta, alpha, multithreading
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scale: try c.decode(Int.self, forKey: .scale), noise: try c.decode(Int.self, forKey: .noise),
                  model: try c.decode(WaifuModel.self, forKey: .model), backend: try c.decode(InferenceBackend.self, forKey: .backend),
                  tileSize: try c.decode(Int.self, forKey: .tileSize), shuffle: try c.decode(Bool.self, forKey: .shuffle),
                  tta: try c.decode(Int.self, forKey: .tta), alpha: try c.decode(AlphaMode.self, forKey: .alpha),
                  multithreading: try c.decodeIfPresent(Bool.self, forKey: .multithreading) ?? false)
        if let saved = try c.decodeIfPresent(Int.self, forKey: .enlargement), [2, 4].contains(saved) { enlargement = saved }
        if let saved = try c.decodeIfPresent(Int.self, forKey: .denoiseLevel), (0...3).contains(saved) { denoiseLevel = saved }
    }
    // Remembered inactive controls do not change the pixels produced by a task.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scale == rhs.scale && lhs.noise == rhs.noise && lhs.model == rhs.model && lhs.backend == rhs.backend &&
        lhs.tileSize == rhs.tileSize && lhs.shuffle == rhs.shuffle && lhs.tta == rhs.tta && lhs.alpha == rhs.alpha &&
        lhs.multithreading == rhs.multithreading
    }
    var modelDirectory: String { model.ncnnDirectory ?? "models-cunet" }
    var resolvedBackend: InferenceBackend {
        backend == .automatic ? (model == .upconvPhoto ? .metal : .webGPU) : backend
    }
    var validationMessage: String? {
        if ![1, 2, 4].contains(scale) || !(-1...3).contains(noise) || tileSize < 64 || ![0, 2, 4].contains(tta) { return L("参数超出支持范围") }
        if scale == 1 && noise == -1 { return L("请选择降噪强度，或选择 2×／4× 放大") }
        if resolvedBackend == .metal && model.ncnnDirectory == nil { return L("此模型使用 ONNX 格式，请选择自动、CPU 或 Core ML 后端") }
        if resolvedBackend == .metal && tta > 0 { return L("TTA 2／4 请使用自动、CPU 或 Core ML 后端") }
        if model == .upconvPhoto && resolvedBackend != .metal { return L("经典照片模型使用 Metal / ncnn 后端") }
        if model == .upconvPhoto && scale == 1 { return L("经典照片模型没有 1× 权重，请选择 Swin / photo 进行仅降噪") }
        return nil
    }
    var isValid: Bool { validationMessage == nil }
    var summary: String { L("%@ · %@", scale == 1 ? L("原尺寸") : L("%d×", scale), Self.noiseName(noise)) }
    var repeatsScale2: Bool { scale == 4 && model.architecture != "swin_unet" }
    var method: String { Self.method(scale: repeatsScale2 ? 2 : scale, noise: noise) }
    static func method(scale: Int, noise: Int) -> String {
        noise == -1 ? "scale\(scale)x" : (scale == 1 ? "noise\(noise)" : "noise\(noise)_scale\(scale)x")
    }
    static func noiseName(_ value: Int) -> String {
        switch value { case -1: L("不降噪"); case 0: L("轻度降噪"); case 1: L("适中降噪"); case 2: L("较强降噪"); default: L("强力降噪") }
    }
}

enum WaifuModel: String, Codable, CaseIterable, Sendable {
    case swinV3, swinArt, swinScan, swinPhoto, cunet, upconvPhoto
    var title: String {
        switch self {
        case .swinV3: L("Swin UNet v3 · 插画")
        case .swinArt: L("Swin UNet · 插画")
        case .swinScan: L("Swin UNet · 扫描插画")
        case .swinPhoto: L("Swin UNet · 照片")
        case .cunet: L("CUNet · 插画")
        case .upconvPhoto: L("Upconv · 照片")
        }
    }
    var architecture: String { self == .upconvPhoto ? "upconv_7_photo" : (self == .swinV3 ? "swin_unet_v3" : (self == .cunet ? "cunet" : "swin_unet")) }
    var domain: String { self == .swinScan ? "art_scan" : (self == .swinPhoto ? "photo" : "art") }
    var ncnnDirectory: String? {
        switch self { case .cunet: "models-cunet"; case .upconvPhoto: "models-upconv_7_photo"; default: nil }
    }
}
enum InferenceBackend: String, Codable, CaseIterable, Sendable {
    case automatic, webGPU, cpu, coreML, metal
    var title: String {
        switch self { case .automatic: L("自动"); case .webGPU: L("WebGPU · Metal"); case .cpu: L("CPU · ONNX Runtime"); case .coreML: L("Core ML · GPU + CPU"); case .metal: L("Metal · ncnn") }
    }
}
enum AlphaMode: String, Codable, CaseIterable, Sendable {
    case auto, disabled
    var title: String { self == .auto ? L("自动保留") : L("白色背景") }
}
enum ImageStyle: String, CaseIterable, Sendable { case illustration = "插画"; case photo = "照片" }
enum PreviewMode: String, CaseIterable { case original = "原图"; case result = "结果"; case compare = "比较" }
struct ImageAsset: Identifiable {
    let id = UUID()
    let url: URL
    let image: CGImage
    let name: String
    var dimensions: String { L("%d × %d", image.width, image.height) }
}
struct ProcessingResult { let asset: ImageAsset; let options: ProcessingOptions; let duration: TimeInterval }
enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}
