import CoreGraphics

struct TileProgress: @unchecked Sendable {
    let completed: Int
    let total: Int
    /// Output pixels, with top-left origin (matches CGImage cropping).
    let activeRect: CGRect?
    /// Contains true model output for completed blocks; other pixels stay transparent.
    let preview: CGImage?
    var patches: [ProcessedPatch] = []
    var completedRects: [CGRect] = []
    var fraction: Double { Double(completed) / Double(max(total, 1)) }
}

struct ProcessedPatch: @unchecked Sendable { let image: CGImage; let rect: CGRect }
