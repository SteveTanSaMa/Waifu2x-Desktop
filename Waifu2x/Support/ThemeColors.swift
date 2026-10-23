import SwiftUI
import AppKit

/// Turquoise marks actions; panel tints adapt independently to each appearance.
enum ThemeColors {
    static let panel = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 29.0 / 255, green: 33.0 / 255, blue: 32.0 / 255, alpha: 0.95)
            : NSColor(srgbRed: 218.0 / 255, green: 248.0 / 255, blue: 243.0 / 255, alpha: 0.50)
    }
    static let canvasTint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? .clear
            : NSColor(srgbRed: 240.0 / 255, green: 252.0 / 255, blue: 250.0 / 255, alpha: 0.15)
    }
    static let textAccent = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.325, green: 0.788, blue: 0.741, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.39, blue: 0.37, alpha: 1)
    }
}
