import AppKit

/// An original, deterministic illustration for trying the offline model.
/// Its fine contours, pine needles, and water lines also give the comparison view useful detail.
enum SampleArtwork {
    static func make() -> CGImage {
        let width = 720
        let height = 480
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
            CGColor(
                red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha
            )
        }
        func path(_ draw: (CGMutablePath) -> Void) -> CGPath {
            let result = CGMutablePath()
            draw(result)
            return result
        }
        func fill(_ shape: CGPath, _ hex: UInt32, alpha: CGFloat = 1) {
            context.addPath(shape)
            context.setFillColor(color(hex, alpha: alpha))
            context.fillPath()
        }
        func stroke(_ shape: CGPath, _ hex: UInt32, width: CGFloat = 1, alpha: CGFloat = 1) {
            context.addPath(shape)
            context.setStrokeColor(color(hex, alpha: alpha))
            context.setLineWidth(width)
            context.strokePath()
        }
        func gradient(_ colors: [UInt32], from start: CGPoint, to end: CGPoint) {
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: colors.map { color($0) } as CFArray, locations: nil
            )!
            context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                  _ hex: UInt32, width: CGFloat = 1, alpha: CGFloat = 1) {
            stroke(path { p in p.move(to: .init(x: x1, y: y1)); p.addLine(to: .init(x: x2, y: y2)) },
                   hex, width: width, alpha: alpha)
        }

        // Warm paper, mint light, and the same turquoise used by the app's accent color.
        gradient([0xFAF8EC, 0xE5F3E7], from: .zero, to: .init(x: 0, y: 340))
        let sun = CGRect(x: 488, y: 48, width: 130, height: 130)
        context.setFillColor(color(0xA3E3CF))
        context.fillEllipse(in: sun)
        context.setStrokeColor(color(0x68B5A2, alpha: 0.5))
        context.setLineWidth(0.7)
        context.strokeEllipse(in: sun.insetBy(dx: -7, dy: -7))
        context.saveGState()
        context.addEllipse(in: sun)
        context.clip()
        for index in 0..<17 {
            let y = CGFloat(64 + index * 7)
            line(480, y, 628, y, 0xF5F6E6, width: 0.65, alpha: 0.35)
        }
        context.restoreGState()

        // A few quiet cloud strokes keep the open sky airy.
        for (x, y, length) in [(52.0, 82.0, 100.0), (86.0, 89.0, 47.0),
                               (356.0, 61.0, 62.0), (384.0, 68.0, 81.0)] {
            line(x, y, x + length, y, 0xB0CEBA, width: 0.75, alpha: 0.65)
        }

        let distantRidge = path { p in
            p.move(to: .init(x: -20, y: 260))
            p.addCurve(to: .init(x: 141, y: 192), control1: .init(x: 49, y: 257), control2: .init(x: 97, y: 197))
            p.addCurve(to: .init(x: 280, y: 239), control1: .init(x: 183, y: 178), control2: .init(x: 233, y: 236))
            p.addCurve(to: .init(x: 430, y: 168), control1: .init(x: 327, y: 242), control2: .init(x: 382, y: 173))
            p.addCurve(to: .init(x: 586, y: 236), control1: .init(x: 470, y: 153), control2: .init(x: 546, y: 229))
            p.addCurve(to: .init(x: 740, y: 194), control1: .init(x: 644, y: 246), control2: .init(x: 696, y: 190))
            p.addLine(to: .init(x: 740, y: 350)); p.addLine(to: .init(x: -20, y: 350)); p.closeSubpath()
        }
        fill(distantRidge, 0xBEDCCA)
        context.saveGState()
        context.addPath(distantRidge); context.clip()
        for index in 0..<7 {
            let offset = CGFloat(index * 11)
            stroke(path { p in
                p.move(to: .init(x: 372, y: 200 + offset))
                p.addCurve(to: .init(x: 737, y: 230 + offset),
                           control1: .init(x: 457, y: 155 + offset), control2: .init(x: 539, y: 294 + offset))
            }, 0x8FBDA7, width: 0.65, alpha: 0.55)
        }
        context.restoreGState()

        let mountain = path { p in
            p.move(to: .init(x: 26, y: 328))
            p.addLine(to: .init(x: 158, y: 225)); p.addLine(to: .init(x: 214, y: 173))
            p.addLine(to: .init(x: 276, y: 112)); p.addLine(to: .init(x: 292, y: 116))
            p.addLine(to: .init(x: 343, y: 182)); p.addLine(to: .init(x: 404, y: 242))
            p.addLine(to: .init(x: 503, y: 319)); p.closeSubpath()
        }
        fill(mountain, 0x72AC96)
        fill(path { p in
            p.move(to: .init(x: 285, y: 119)); p.addLine(to: .init(x: 279, y: 187))
            p.addLine(to: .init(x: 322, y: 233)); p.addLine(to: .init(x: 337, y: 286))
            p.addLine(to: .init(x: 503, y: 319)); p.addLine(to: .init(x: 404, y: 242))
            p.addLine(to: .init(x: 343, y: 182)); p.closeSubpath()
        }, 0x4E8F7E)
        fill(path { p in
            p.move(to: .init(x: 214, y: 173)); p.addLine(to: .init(x: 276, y: 112))
            p.addLine(to: .init(x: 292, y: 116)); p.addLine(to: .init(x: 343, y: 182))
            p.addLine(to: .init(x: 311, y: 164)); p.addLine(to: .init(x: 299, y: 171))
            p.addLine(to: .init(x: 281, y: 147)); p.addLine(to: .init(x: 265, y: 168))
            p.addLine(to: .init(x: 252, y: 159)); p.closeSubpath()
        }, 0xEDF2DD)

        // Delicate, irregular elevation contours reveal the model's treatment of line art.
        context.saveGState()
        context.addPath(mountain); context.clip()
        for index in 0..<14 {
            let y = CGFloat(179 + index * 9)
            stroke(path { p in
                p.move(to: .init(x: 41, y: y + 70))
                p.addCurve(to: .init(x: 273, y: y), control1: .init(x: 132, y: y + 55), control2: .init(x: 204, y: y + 20))
                p.addCurve(to: .init(x: 410, y: y + 42), control1: .init(x: 322, y: y + 8), control2: .init(x: 326, y: y + 34))
            }, 0xD5E9CE, width: 0.7, alpha: 0.55)
        }
        for index in 0..<8 {
            let offset = CGFloat(index * 12)
            stroke(path { p in
                p.move(to: .init(x: 316 + offset * 0.3, y: 182 + offset))
                p.addQuadCurve(to: .init(x: 446 + offset, y: 321), control: .init(x: 344 + offset, y: 266))
            }, 0x2D7265, width: 0.7, alpha: 0.55)
        }
        context.restoreGState()

        let foothills = path { p in
            p.move(to: .init(x: -20, y: 296))
            p.addCurve(to: .init(x: 172, y: 266), control1: .init(x: 56, y: 295), control2: .init(x: 104, y: 247))
            p.addCurve(to: .init(x: 339, y: 299), control1: .init(x: 234, y: 282), control2: .init(x: 272, y: 310))
            p.addCurve(to: .init(x: 530, y: 263), control1: .init(x: 407, y: 293), control2: .init(x: 465, y: 252))
            p.addCurve(to: .init(x: 740, y: 281), control1: .init(x: 608, y: 276), control2: .init(x: 664, y: 257))
            p.addLine(to: .init(x: 740, y: 357)); p.addLine(to: .init(x: -20, y: 357)); p.closeSubpath()
        }
        fill(foothills, 0x2D7869)
        stroke(path { p in
            p.move(to: .init(x: -10, y: 310))
            p.addCurve(to: .init(x: 340, y: 309), control1: .init(x: 173, y: 276), control2: .init(x: 204, y: 323))
            p.addCurve(to: .init(x: 730, y: 291), control1: .init(x: 493, y: 279), control2: .init(x: 562, y: 286))
        }, 0x82C6AB, width: 0.9, alpha: 0.7)

        // A luminous lake opens up the lower half of the composition.
        let lake = path { p in
            p.move(to: .init(x: -20, y: 329))
            p.addCurve(to: .init(x: 244, y: 334), control1: .init(x: 82, y: 312), control2: .init(x: 154, y: 342))
            p.addCurve(to: .init(x: 740, y: 306), control1: .init(x: 413, y: 319), control2: .init(x: 594, y: 304))
            p.addLine(to: .init(x: 740, y: 500)); p.addLine(to: .init(x: -20, y: 500)); p.closeSubpath()
        }
        context.saveGState()
        context.addPath(lake); context.clip()
        gradient([0xA6DDC8, 0x53C9BD, 0x62BAAD], from: .init(x: 0, y: 302), to: .init(x: 0, y: 480))
        for index in 0..<42 {
            let row = CGFloat(index)
            let y = 318 + row * 3.8
            let center = 546 + sin(row * 0.79) * 10
            let halfWidth = 21 + row * 1.4
            line(center - halfWidth, y, center + halfWidth, y, 0xEFF3D9, width: 1, alpha: 0.6 - row * 0.006)
        }
        for index in 0..<70 {
            let x = CGFloat((index * 113 + 17) % 720)
            let y = CGFloat(331 + (index * 41) % 146)
            let length = CGFloat(10 + (index * 7) % 49)
            line(x, y, x + length, y, index % 3 == 0 ? 0xE5F3DA : 0x257F73,
                 width: index % 4 == 0 ? 1 : 0.65, alpha: 0.36)
        }
        context.restoreGState()
        stroke(lake, 0xE2EDCA, width: 1.5, alpha: 0.85)

        // The curved near shore anchors the landscape and frames the clear water.
        let shore = path { p in
            p.move(to: .init(x: -20, y: 336))
            p.addCurve(to: .init(x: 117, y: 360), control1: .init(x: 35, y: 327), control2: .init(x: 71, y: 347))
            p.addCurve(to: .init(x: 239, y: 411), control1: .init(x: 179, y: 377), control2: .init(x: 156, y: 402))
            p.addCurve(to: .init(x: 405, y: 492), control1: .init(x: 341, y: 423), control2: .init(x: 300, y: 477))
            p.addLine(to: .init(x: -20, y: 500)); p.closeSubpath()
        }
        stroke(shore, 0xDDE8C5, width: 12)
        fill(shore, 0x194F45)
        stroke(path { p in
            p.move(to: .init(x: -10, y: 357))
            p.addCurve(to: .init(x: 157, y: 392), control1: .init(x: 88, y: 341), control2: .init(x: 91, y: 383))
            p.addCurve(to: .init(x: 284, y: 455), control1: .init(x: 253, y: 415), control2: .init(x: 197, y: 433))
        }, 0x80B89D, width: 0.8, alpha: 0.7)

        func pine(x: CGFloat, base: CGFloat, height: CGFloat, tint: UInt32) {
            let top = base - height
            line(x, base, x, top, tint, width: max(1, height * 0.022))
            for tier in 0..<7 {
                let t = CGFloat(tier)
                let y = top + height * (0.08 + t * 0.105)
                let spread = height * (0.045 + t * 0.021)
                fill(path { p in
                    p.move(to: .init(x: x, y: y - height * 0.08))
                    p.addQuadCurve(to: .init(x: x - spread, y: y + height * 0.13), control: .init(x: x - spread * 0.3, y: y + height * 0.07))
                    p.addLine(to: .init(x: x - spread * 0.32, y: y + height * 0.1))
                    p.addLine(to: .init(x: x, y: y + height * 0.14))
                    p.addLine(to: .init(x: x + spread * 0.35, y: y + height * 0.1))
                    p.addLine(to: .init(x: x + spread, y: y + height * 0.13))
                    p.addQuadCurve(to: .init(x: x, y: y - height * 0.08), control: .init(x: x + spread * 0.3, y: y + height * 0.07))
                    p.closeSubpath()
                }, tint)
                if height > 80 {
                    line(x - spread * 0.7, y + height * 0.1, x, y + height * 0.02,
                         0x8CC5A4, width: 0.65, alpha: 0.48)
                    line(x, y + height * 0.02, x + spread * 0.65, y + height * 0.1,
                         0x8CC5A4, width: 0.65, alpha: 0.35)
                }
            }
        }
        for index in 0..<19 {
            let x = CGFloat(16 + index * 39)
            let base = 310 + sin(CGFloat(index) * 0.8) * 7
            pine(x: x, base: base, height: CGFloat(14 + (index * 7) % 17), tint: 0x225F52)
        }
        pine(x: 41, base: 375, height: 173, tint: 0x123F37)
        pine(x: 99, base: 388, height: 133, tint: 0x16473D)
        pine(x: 9, base: 365, height: 105, tint: 0x16473D)
        pine(x: 163, base: 414, height: 78, tint: 0x123F37)

        // Reeds and a tiny canoe provide fine features at a second, smaller scale.
        for index in 0..<19 {
            let x = CGFloat(26 + index * 13)
            let base = 421 + CGFloat(index % 5) * 11
            let h = CGFloat(9 + (index * 11) % 22)
            stroke(path { p in
                p.move(to: .init(x: x, y: base))
                p.addQuadCurve(to: .init(x: x - 4, y: base - h), control: .init(x: x + 1, y: base - h * 0.6))
            }, 0x90BA96, width: 0.75, alpha: 0.8)
        }
        fill(path { p in
            p.move(to: .init(x: 421, y: 379)); p.addLine(to: .init(x: 464, y: 379))
            p.addQuadCurve(to: .init(x: 451, y: 385), control: .init(x: 459, y: 385))
            p.addLine(to: .init(x: 433, y: 385)); p.closeSubpath()
        }, 0x205F52)
        line(427, 379, 459, 379, 0xF4EED3, width: 1)
        line(444, 374, 455, 389, 0x205F52, width: 1.1)
        context.setFillColor(color(0x205F52))
        context.fillEllipse(in: .init(x: 439.5, y: 369.5, width: 4, height: 4))
        line(441.5, 374, 440, 379, 0x205F52, width: 2.5)
        line(431, 390, 466, 390, 0xE1F0D1, width: 0.7, alpha: 0.8)

        for (x, y, size) in [(398.0, 120.0, 7.0), (429.0, 137.0, 5.0), (416.0, 109.0, 3.5)] {
            stroke(path { p in
                p.move(to: .init(x: x - size, y: y))
                p.addQuadCurve(to: .init(x: x, y: y + 2), control: .init(x: x - size * 0.3, y: y - 4))
                p.addQuadCurve(to: .init(x: x + size, y: y), control: .init(x: x + size * 0.3, y: y - 4))
            }, 0x397A69, width: 0.9, alpha: 0.85)
        }

        // Stable paper flecks prevent flat gradients without adding random input noise.
        context.setFillColor(color(0x173F32, alpha: 0.025))
        for index in 0..<1800 {
            let x = CGFloat((index * 127 + index / 7 * 43) % width)
            let y = CGFloat((index * 79 + index / 11 * 67) % height)
            context.fill(CGRect(x: x, y: y, width: 0.55, height: 0.55))
        }
        return context.makeImage()!
    }
}
