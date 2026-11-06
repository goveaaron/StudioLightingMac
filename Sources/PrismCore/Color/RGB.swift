import Foundation

/// An sRGB color with gamma-encoded components in 0...1 — exactly what a hex code like
/// `#00CED1` describes. This is the user-facing color representation.
public struct RGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = clamp01(r)
        self.g = clamp01(g)
        self.b = clamp01(b)
    }

    public init(r255: Int, g255: Int, b255: Int) {
        self.init(r: Double(r255) / 255, g: Double(g255) / 255, b: Double(b255) / 255)
    }

    public static let white = RGB(r: 1, g: 1, b: 1)
    public static let black = RGB(r: 0, g: 0, b: 0)
    public static let red = RGB(r: 1, g: 0, b: 0)
    public static let green = RGB(r: 0, g: 1, b: 0)
    public static let blue = RGB(r: 0, g: 0, b: 1)

    // MARK: Hex

    /// Parses `#RGB`, `#RRGGBB`, `RRGGBB`, `0xRRGGBB` (case-insensitive, whitespace tolerant).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0x") { s.removeFirst(2) }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(
            r255: Int((value >> 16) & 0xFF),
            g255: Int((value >> 8) & 0xFF),
            b255: Int(value & 0xFF)
        )
    }

    /// `#RRGGBB` uppercase.
    public var hex: String {
        String(format: "#%02X%02X%02X", r255, g255, b255)
    }

    public var r255: Int { Int((r * 255).rounded()) }
    public var g255: Int { Int((g * 255).rounded()) }
    public var b255: Int { Int((b * 255).rounded()) }

    // MARK: Linear light

    /// Linear-light (photometric) components, sRGB primaries.
    public var linear: LinearRGB {
        LinearRGB(r: ColorMath.srgbToLinear(r), g: ColorMath.srgbToLinear(g), b: ColorMath.srgbToLinear(b))
    }

    public init(linear: LinearRGB) {
        self.init(r: ColorMath.linearToSRGB(linear.r), g: ColorMath.linearToSRGB(linear.g), b: ColorMath.linearToSRGB(linear.b))
    }

    // MARK: HSV

    /// Hue in degrees 0..<360, saturation and value 0...1.
    public var hsv: (h: Double, s: Double, v: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        var h = 0.0
        if delta > 1e-9 {
            if maxC == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
            else if maxC == g { h = 60 * (((b - r) / delta) + 2) }
            else { h = 60 * (((r - g) / delta) + 4) }
        }
        let s = maxC <= 1e-9 ? 0 : delta / maxC
        return (wrapDegrees(h), s, maxC)
    }

    public init(hue: Double, saturation: Double, value: Double) {
        let h = wrapDegrees(hue) / 60
        let s = clamp01(saturation), v = clamp01(value)
        let c = v * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        let (r1, g1, b1): (Double, Double, Double)
        switch h {
        case 0..<1: (r1, g1, b1) = (c, x, 0)
        case 1..<2: (r1, g1, b1) = (x, c, 0)
        case 2..<3: (r1, g1, b1) = (0, c, x)
        case 3..<4: (r1, g1, b1) = (0, x, c)
        case 4..<5: (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        self.init(r: r1 + m, g: g1 + m, b: b1 + m)
    }
}

/// Linear-light RGB (sRGB/Rec.709 primaries). Components are nominally 0...1 but may exceed
/// that range transiently during math.
public struct LinearRGB: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    public static let black = LinearRGB(r: 0, g: 0, b: 0)

    public var maxComponent: Double { max(r, g, b) }

    /// Scales so the largest component is 1 (keeps chromaticity). Black stays black.
    public var normalized: LinearRGB {
        let m = maxComponent
        guard m > 1e-9 else { return .black }
        return LinearRGB(r: r / m, g: g / m, b: b / m)
    }

    public var clamped: LinearRGB {
        LinearRGB(r: clamp01(r), g: clamp01(g), b: clamp01(b))
    }

    public static func * (lhs: LinearRGB, rhs: Double) -> LinearRGB {
        LinearRGB(r: lhs.r * rhs, g: lhs.g * rhs, b: lhs.b * rhs)
    }

    public static func + (lhs: LinearRGB, rhs: LinearRGB) -> LinearRGB {
        LinearRGB(r: lhs.r + rhs.r, g: lhs.g + rhs.g, b: lhs.b + rhs.b)
    }

    /// Relative luminance (Y) for sRGB primaries.
    public var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
}
