import AppKit

/// Preserve the bright turquoise in both appearances; use dark ink rather than
/// darkening the accent to accommodate white text.
enum ToolbarActionPalette {
    static let neutralInk = NSColor.labelColor
    static func prominentInk(for appearance: NSAppearance) -> NSColor {
        .init(srgbRed: 0.045, green: 0.13, blue: 0.12, alpha: 1)
    }
    static let prominentInk = NSColor(name: nil) { appearance in prominentInk(for: appearance) }
}
