import Foundation
import Combine

@MainActor
final class QueueImage: ObservableObject, Identifiable {
    let id = UUID()
    let input: ImageAsset
    @Published var result: ProcessingResult?
    @Published var state: State = .ready
    @Published var failure: String?

    enum State { case ready, waiting, processing, completed, failed, cancelled }
    init(input: ImageAsset) { self.input = input }
    var status: String {
        switch state {
        case .ready: L("待处理")
        case .waiting: L("排队中")
        case .processing: L("正在增强")
        case .completed: result.map { L("完成 · %@", $0.asset.dimensions) } ?? L("完成")
        case .failed: L("处理失败")
        case .cancelled: result == nil ? L("已取消") : L("已取消 · 保留上次结果")
        }
    }
}
