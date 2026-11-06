import Foundation

/// A device-independent description of the color a light should emit.
///
/// Users think in hex codes, Kelvin + green/magenta tint, or hue/saturation.
/// Prism stores exactly what the user asked for (so a Kelvin value stays a Kelvin value and
/// can be sent natively to fixtures with CCT channels) and converts at render time for
/// fixtures that can't do that natively.
public enum LightColor: Hashable, Sendable {
    /// sRGB color, exactly as typed in a hex code.
    case rgb(RGB)
    /// Correlated color temperature in Kelvin, plus tint: -1 = full green … 0 = neutral … +1 = full magenta.
    case kelvin(Double, tint: Double)
    /// Hue in degrees (0..<360) and saturation (0 = white at 5600K … 1 = fully saturated).
    case hsi(hue: Double, saturation: Double)
    /// CIE 1931 xy chromaticity.
    case xy(x: Double, y: Double)

    public static let white: LightColor = .kelvin(5600, tint: 0)
    public static let daylight: LightColor = .kelvin(5600, tint: 0)
    public static let tungsten: LightColor = .kelvin(3200, tint: 0)

    public static func hex(_ string: String) -> LightColor? {
        RGB(hex: string).map { LightColor.rgb($0) }
    }

    /// Normalized linear-light RGB at full brightness (max component = 1), sRGB primaries.
    /// This is the chromaticity the light should produce; brightness is carried separately
    /// by the fixture intensity.
    public var linearRGB: LinearRGB {
        switch self {
        case .rgb(let c):
            return c.linear.normalized
        case .kelvin(let k, let tint):
            let (x, y) = ColorMath.kelvinToXY(k, tint: tint)
            return ColorMath.xyToLinearSRGB(x: x, y: y).normalized
        case .hsi(let hue, let sat):
            // Saturation blends from 5600K white to the fully saturated hue (in linear light).
            let pure = RGB(hue: hue, saturation: 1, value: 1).linear
            let white = LightColor.kelvin(5600, tint: 0).linearRGB
            let s = clamp01(sat)
            return LinearRGB(
                r: lerp(white.r, pure.r, s),
                g: lerp(white.g, pure.g, s),
                b: lerp(white.b, pure.b, s)
            ).normalized
        case .xy(let x, let y):
            return ColorMath.xyToLinearSRGB(x: x, y: y).normalized
        }
    }

    /// A display color for UI swatches and the stage visualizer (full brightness).
    public var displayRGB: RGB {
        switch self {
        case .rgb(let c):
            // Show the hue at full value so dim colors still read correctly on screen.
            let m = max(c.r, c.g, c.b)
            guard m > 1e-6 else { return .black }
            return RGB(r: c.r / m, g: c.g / m, b: c.b / m)
        default:
            return RGB(linear: linearRGB)
        }
    }

    /// Hex code of `displayRGB` (for `.rgb` colors this is the exact stored hex).
    public var hex: String {
        if case .rgb(let c) = self { return c.hex }
        return displayRGB.hex
    }

    /// CIE xy chromaticity of this color.
    public var xy: (x: Double, y: Double) {
        switch self {
        case .xy(let x, let y): return (x, y)
        case .kelvin(let k, let tint): return ColorMath.kelvinToXY(k, tint: tint)
        default: return ColorMath.linearSRGBToXY(linearRGB)
        }
    }

    /// Approximate correlated color temperature (Kelvin) and Duv-based tint of this color.
    public var approximateKelvin: (kelvin: Double, tint: Double) {
        if case .kelvin(let k, let t) = self { return (k, t) }
        let (x, y) = xy
        return ColorMath.xyToKelvinAndTint(x: x, y: y)
    }

    /// True when the color is essentially a white (near the Planckian locus and desaturated).
    public var isWhiteish: Bool {
        switch self {
        case .kelvin: return true
        case .hsi(_, let s): return s < 0.12
        default:
            let (_, tint) = approximateKelvin
            let hsv = displayRGB.hsv
            return hsv.s < 0.18 && abs(tint) < 0.6
        }
    }

    /// Short human-readable description, e.g. "#00CED1", "5600K", "5600K +0.3 M".
    public var label: String {
        switch self {
        case .rgb(let c): return c.hex
        case .kelvin(let k, let tint):
            let kStr = "\(Int(k.rounded()))K"
            if abs(tint) < 0.005 { return kStr }
            return tint > 0 ? "\(kStr) +\(String(format: "%.2f", tint)) M" : "\(kStr) \(String(format: "%.2f", tint)) G"
        case .hsi(let h, let s): return "H\(Int(h.rounded()))° S\(Int((s * 100).rounded()))%"
        case .xy(let x, let y): return String(format: "x %.4f y %.4f", x, y)
        }
    }

    /// Returns a copy with all numeric fields sanitized (finite, in valid ranges).
    public var sanitized: LightColor {
        switch self {
        case .rgb(let c): return .rgb(RGB(r: c.r.finiteOr(1), g: c.g.finiteOr(1), b: c.b.finiteOr(1)))
        case .kelvin(let k, let t): return .kelvin(clamp(k.finiteOr(5600), 1000, 20000), tint: clamp(t.finiteOr(0), -1, 1))
        case .hsi(let h, let s): return .hsi(hue: wrapDegrees(h.finiteOr(0)), saturation: clamp01(s.finiteOr(1)))
        case .xy(let x, let y): return .xy(x: clamp(x.finiteOr(0.3127), 0.0, 0.8), y: clamp(y.finiteOr(0.329), 0.01, 0.9))
        }
    }

    /// Perceptually smooth interpolation between two colors.
    /// Kelvin↔Kelvin interpolates in mireds (so it stays on the white line); everything else in OKLab.
    public static func mix(_ a: LightColor, _ b: LightColor, _ t: Double) -> LightColor {
        let t = clamp01(t)
        if t <= 0 { return a }
        if t >= 1 { return b }
        if case .kelvin(let k1, let t1) = a, case .kelvin(let k2, let t2) = b {
            let m = lerp(1e6 / max(k1, 1), 1e6 / max(k2, 1), t)
            return .kelvin(1e6 / max(m, 1), tint: lerp(t1, t2, t))
        }
        let la = ColorMath.linearToOKLab(a.linearRGB)
        let lb = ColorMath.linearToOKLab(b.linearRGB)
        let mixed = ColorMath.okLabToLinear(L: lerp(la.L, lb.L, t), a: lerp(la.a, lb.a, t), b: lerp(la.b, lb.b, t))
        return .rgb(RGB(linear: mixed.clamped.normalized))
    }
}

// MARK: - Codable (stable, human-readable JSON)

extension LightColor: Codable {
    private enum CodingKeys: String, CodingKey { case type, hex, kelvin, tint, hue, saturation, x, y }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "rgb"
        switch type {
        case "kelvin", "cct":
            let k = try c.decodeIfPresent(Double.self, forKey: .kelvin) ?? 5600
            let t = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
            self = LightColor.kelvin(k, tint: t).sanitized
        case "hsi", "hsv":
            let h = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
            let s = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
            self = LightColor.hsi(hue: h, saturation: s).sanitized
        case "xy":
            let x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.3127
            let y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.329
            self = LightColor.xy(x: x, y: y).sanitized
        default:
            let hex = try c.decodeIfPresent(String.self, forKey: .hex) ?? "#FFFFFF"
            self = .rgb(RGB(hex: hex) ?? .white)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .rgb(let rgb):
            try c.encode("rgb", forKey: .type)
            try c.encode(rgb.hex, forKey: .hex)
        case .kelvin(let k, let t):
            try c.encode("kelvin", forKey: .type)
            try c.encode(k, forKey: .kelvin)
            try c.encode(t, forKey: .tint)
        case .hsi(let h, let s):
            try c.encode("hsi", forKey: .type)
            try c.encode(h, forKey: .hue)
            try c.encode(s, forKey: .saturation)
        case .xy(let x, let y):
            try c.encode("xy", forKey: .type)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
    }
}
