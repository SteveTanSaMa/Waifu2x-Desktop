import SwiftUI

/// StartupState owns the two-second clock and decides when this surface leaves.
/// Keeping the view passive avoids duplicate launch work when SwiftUI remounts it.
struct LaunchSplashView: View {
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { progress.isFinite ? min(1, max(0, progress)) : 0 }
    private var reveal: Double { reduceMotion ? 1 : min(1, fraction / 0.72) }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                let haloSize = min(geometry.size.width * 0.7, 920)
                RadialGradient(colors: [Color.accentColor.opacity(0.13), Color.accentColor.opacity(0.035), .clear],
                               center: .center, startRadius: 0, endRadius: haloSize / 2)
                    .frame(width: haloSize, height: haloSize)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    SplashMountainMark(light: reveal)
                        .frame(width: 232, height: 232)
                        .blur(radius: reduceMotion ? 0 : (1 - reveal) * 8)
                        .scaleEffect(reduceMotion ? 1 : 0.96 + 0.04 * reveal)
                        .opacity(reduceMotion ? 1 : min(1, fraction / 0.2))
                        .padding(.bottom, 28)
                        .accessibilityHidden(true)
                    Text("Waifu2x")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .tracking(-0.8)
                    Text(L("让每一处细节，慢慢清晰"))
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .opacity(reduceMotion ? 1 : min(1, max(0, (fraction - 0.18) / 0.3)))
                }
                .padding(40)
                .frame(maxWidth: 640)
                .accessibilityElement(children: .combine)
            }
            .overlay(alignment: .top) {
                Color.clear.frame(height: 64).contentShape(Rectangle())
                    .gesture(WindowDragGesture()).allowsWindowActivationEvents(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("launchSplash")
    }
}

/// A code-native extension of the app's mountain motif, sharpening as launch
/// progresses. Its quiet water highlight makes one pass rather than looping.
private struct SplashMountainMark: View {
    let light: Double

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 232
            var canvas = context
            canvas.scaleBy(x: scale, y: scale)
            let square = Path(roundedRect: CGRect(x: 5, y: 5, width: 222, height: 222), cornerRadius: 50)
            canvas.fill(square, with: .linearGradient(
                Gradient(colors: [Color(red: 0.51, green: 0.93, blue: 0.84), Color.accentColor, Color(red: 0.08, green: 0.57, blue: 0.54)]),
                startPoint: CGPoint(x: 20, y: 10), endPoint: CGPoint(x: 215, y: 232)))
            var mountain = Path()
            mountain.addLines([CGPoint(x: 26, y: 169), CGPoint(x: 80, y: 99), CGPoint(x: 106, y: 126), CGPoint(x: 139, y: 60), CGPoint(x: 204, y: 169)])
            mountain.closeSubpath()
            canvas.fill(mountain, with: .color(Color(red: 0.9, green: 0.99, blue: 0.94)))
            var shade = Path()
            shade.addLines([CGPoint(x: 139, y: 60), CGPoint(x: 154, y: 118), CGPoint(x: 149, y: 129), CGPoint(x: 178, y: 169), CGPoint(x: 204, y: 169)])
            shade.closeSubpath()
            canvas.fill(shade, with: .color(Color(red: 0.05, green: 0.29, blue: 0.28)))
            var cut = Path()
            cut.addLines([CGPoint(x: 139, y: 60), CGPoint(x: 135, y: 103), CGPoint(x: 121, y: 124), CGPoint(x: 127, y: 142), CGPoint(x: 106, y: 169), CGPoint(x: 159, y: 169), CGPoint(x: 143, y: 122)])
            cut.closeSubpath()
            canvas.fill(cut, with: .color(Color(red: 0.52, green: 0.84, blue: 0.76).opacity(0.8)))
            for index in 0..<5 {
                let y = CGFloat(179 + index * 7)
                let width = CGFloat(88 - index * 12)
                var ripple = Path()
                ripple.move(to: CGPoint(x: 145 - width / 2, y: y))
                ripple.addLine(to: CGPoint(x: 145 + width / 2, y: y))
                canvas.stroke(ripple, with: .color(.white.opacity(0.18 + light * 0.12)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
            var glimmer = Path()
            let x = 50 + light * 132
            glimmer.move(to: CGPoint(x: x - 12, y: 187))
            glimmer.addLine(to: CGPoint(x: x + 12, y: 187))
            canvas.stroke(glimmer, with: .color(.white.opacity(0.5 * sin(light * .pi))), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            canvas.stroke(square, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
        .shadow(color: Color.accentColor.opacity(0.16), radius: 32, y: 12)
        .transaction { $0.animation = nil }
    }
}
