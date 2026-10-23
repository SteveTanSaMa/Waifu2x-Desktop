import Foundation

/// Short, selection-specific guidance for the inspector. Detailed engine
/// information stays out of the image workspace.
extension ProcessingOptions {
    var noiseHint: String {
        switch noise {
        case -1: L("不额外降噪，让原有纹理与颗粒自然留存")
        case 0: L("轻拂细小噪点，尽量留住原有纹理")
        case 1: L("平衡噪点与纹理，让画面更显清爽")
        case 2: L("抚平明显噪点，细小纹理也会更柔和")
        default: L("着重清理重噪点，细小纹理可能一同淡去")
        }
    }
    var modelHint: String {
        switch model {
        case .swinV3: L("照顾插画的线条与色彩，4× 分两步完成")
        case .swinArt: L("面向插画的线条与色块，支持原生 4×")
        case .swinScan: L("适合扫描插画，支持原生 4× 放大")
        case .swinPhoto: L("适合照片画面，支持原生 4× 放大")
        case .cunet: L("经典插画之选，4× 分两步完成")
        case .upconvPhoto: L("经典照片之选，可放大至 2× 或 4×")
        }
    }
    var backendHint: String {
        switch backend {
        case .automatic: resolvedBackend == .metal ? L("自动选用 Metal，交给本机 GPU 处理") : L("自动选用 WebGPU，交给本机 GPU 处理")
        case .webGPU: L("通过 Metal，让本机 GPU 参与处理")
        case .cpu: L("交给 CPU 处理，为 GPU 留些余量")
        case .coreML: L("由 Core ML 协调 GPU 与 CPU 处理")
        case .metal: L("为经典模型搭配 Metal GPU 加速")
        }
    }
    var tileHint: String {
        switch tileSize {
        case 64: L("小块轻装处理，更省内存，也可能多些等待")
        case 256: L("在内存与分块开销之间，取一个平衡")
        case 400: L("减少分块，适合内存较充裕时使用")
        default: L("以更少分块完成画面，需留足可用内存")
        }
    }
    var alphaHint: String {
        if alpha == .disabled { return L("为透明处铺上白底，输出不带透明度") }
        return L("保留透明背景，方便继续创作")
    }
}
