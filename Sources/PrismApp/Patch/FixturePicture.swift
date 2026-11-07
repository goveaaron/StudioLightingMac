import SwiftUI
import PrismCore

/// A small drawn picture of a light (tube, panel, par, spot, bulb…) so people can recognise
/// their fixture by its shape instead of its DMX profile.
struct FixturePicture: View {
    let category: FixtureCategory
    /// Pixel zones to draw on tubes and bars (0 = draw a sensible default).
    var cells: Int = 0
    /// Glowing (true) or dark (false).
    var lit: Bool = true

    var body: some View {
        GeometryReader { geo in
            let s = geo.size
            ZStack {
                switch category {
                case .tube, .bar, .strip: tube(s)
                case .panel, .wash: panel(s)
                case .par: par(s)
                case .spot, .fresnel, .movingHead: spot(s)
                case .bulb, .dimmer: bulb(s)
                case .effect, .other: other(s)
                }
            }
            .frame(width: s.width, height: s.height)
        }
        .accessibilityHidden(true)
    }

    // MARK: Shapes

    private func tube(_ s: CGSize) -> some View {
        let n = clamp(cells > 0 ? cells : 8, 1, 16)
        let w = s.width * 0.9
        let h = max(6, min(s.height * 0.26, w / 7))
        return ZStack {
            Capsule()
                .fill(Color(hex: 0x2A2F3A))
                .frame(width: w, height: h)
            HStack(spacing: max(1, h * 0.08)) {
                ForEach(0..<n, id: \.self) { i in
                    RoundedRectangle(cornerRadius: h * 0.18, style: .continuous)
                        .fill(lit ? pixelColor(i, of: n) : Color(hex: 0x3A3F4A))
                }
            }
            .padding(.horizontal, h * 0.55)
            .padding(.vertical, h * 0.2)
            .frame(width: w, height: h)
            .clipShape(Capsule())
            .shadow(color: lit ? pixelColor(n / 2, of: n).opacity(0.65) : .clear, radius: h * 0.7)
        }
    }

    private func panel(_ s: CGSize) -> some View {
        let side = min(s.width * 0.62, s.height * 0.86)
        let warm = Color(hex: 0xFFE4BF)
        return ZStack {
            RoundedRectangle(cornerRadius: side * 0.1, style: .continuous)
                .fill(Color(hex: 0x2A2F3A))
                .frame(width: side, height: side * 0.82)
            RoundedRectangle(cornerRadius: side * 0.07, style: .continuous)
                .fill(lit ? AnyShapeStyle(RadialGradient(colors: [Color.white, warm, warm.opacity(0.75)],
                                                          center: .center, startRadius: 0, endRadius: side * 0.55))
                          : AnyShapeStyle(Color(hex: 0x3A3F4A)))
                .frame(width: side * 0.84, height: side * 0.66)
                .shadow(color: lit ? warm.opacity(0.55) : .clear, radius: side * 0.18)
        }
    }

    private func par(_ s: CGSize) -> some View {
        let d = min(s.width, s.height) * 0.82
        let dot = d * 0.17
        let offsets: [CGSize] = [.zero] + (0..<6).map { k in
            let a = Double(k) * .pi / 3
            return CGSize(width: cos(a) * Double(d) * 0.26, height: sin(a) * Double(d) * 0.26)
        }
        return ZStack {
            Circle().fill(Color(hex: 0x2A2F3A)).frame(width: d, height: d)
            ForEach(Array(offsets.enumerated()), id: \.offset) { i, o in
                Circle()
                    .fill(lit ? pixelColor(i, of: offsets.count) : Color(hex: 0x3A3F4A))
                    .frame(width: dot, height: dot)
                    .offset(o)
            }
        }
        .shadow(color: lit ? Theme.accent.opacity(0.5) : .clear, radius: d * 0.2)
    }

    private func spot(_ s: CGSize) -> some View {
        let d = min(s.width, s.height) * 0.7
        let warm = Color(hex: 0xFFD9A0)
        return ZStack {
            RoundedRectangle(cornerRadius: d * 0.16, style: .continuous)
                .fill(Color(hex: 0x2A2F3A))
                .frame(width: d * 1.15, height: d * 1.15)
            Circle()
                .fill(lit ? AnyShapeStyle(RadialGradient(colors: [Color.white, warm, warm.opacity(0.4)],
                                                          center: .center, startRadius: 0, endRadius: d * 0.5))
                          : AnyShapeStyle(Color(hex: 0x3A3F4A)))
                .frame(width: d, height: d)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: max(1, d * 0.04)))
                .shadow(color: lit ? warm.opacity(0.6) : .clear, radius: d * 0.25)
        }
    }

    private func bulb(_ s: CGSize) -> some View {
        let d = min(s.width, s.height) * 0.62
        let warm = Color(hex: 0xFFC978)
        return VStack(spacing: -d * 0.08) {
            Circle()
                .fill(lit ? AnyShapeStyle(RadialGradient(colors: [Color.white, warm, warm.opacity(0.6)],
                                                          center: .center, startRadius: 0, endRadius: d * 0.55))
                          : AnyShapeStyle(Color(hex: 0x3A3F4A)))
                .frame(width: d, height: d)
                .shadow(color: lit ? warm.opacity(0.7) : .clear, radius: d * 0.3)
            RoundedRectangle(cornerRadius: d * 0.06, style: .continuous)
                .fill(Color(hex: 0x4A505C))
                .frame(width: d * 0.42, height: d * 0.3)
        }
    }

    private func other(_ s: CGSize) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: min(s.width, s.height) * 0.5, weight: .semibold))
            .foregroundStyle(lit ? AnyShapeStyle(Theme.spectrum) : AnyShapeStyle(Color(hex: 0x3A3F4A)))
    }

    /// Calm spectrum across the pixels: magenta → violet → blue → teal.
    private func pixelColor(_ i: Int, of n: Int) -> Color {
        let t = n <= 1 ? 0.5 : Double(i) / Double(n - 1)
        return Color(hue: 0.88 - 0.42 * t, saturation: 0.62, brightness: 1.0)
    }
}

extension FixturePicture {
    /// Pixel zones parsed from a library badge such as `"CCT + RGBWW · 16 px"`.
    static func cells(fromBadge badge: String) -> Int {
        guard let range = badge.range(of: #"(\d+)\s*px"#, options: .regularExpression) else { return 0 }
        let digits = badge[range].prefix { $0.isNumber }
        return Int(digits) ?? 0
    }
}
