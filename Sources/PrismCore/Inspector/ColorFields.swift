import Foundation

/// Which kind of control is driving a light's colour right now.
public enum ColorModeKind: String, Sendable, Hashable, CaseIterable {
    /// RGB or hue/saturation — "a colour".
    case color
    /// Kelvin + green/magenta tint — "a white".
    case white
    /// CIE xy chromaticity (advanced).
    case xy

    public init(_ color: LightColor) {
        switch color {
        case .rgb, .hsi: self = .color
        case .kelvin: self = .white
        case .xy: self = .xy
        }
    }

    /// Plain-English name for UI copy.
    public var displayName: String {
        switch self {
        case .color: return "Color"
        case .white: return "White"
        case .xy: return "CIE xy"
        }
    }
}

/// Every number the inspector's colour fields show for one colour, computed once per render.
///
/// The hex/RGB values are the exact stored values for `.rgb` colours (so typing `#00C2B8`
/// reads back `#00C2B8`, never a normalised variant). Kelvin/tint are exact for whites and are
/// only *derived* for colours that are close to white; for saturated colours they are `nil`
/// so the UI never shows a meaningless "12000 K" for a teal.
public struct ColorFieldValues: Sendable, Hashable {
    public var mode: ColorModeKind
    public var red: Int
    public var green: Int
    public var blue: Int
    /// `#RRGGBB`.
    public var hex: String
    /// True when `hex` is exactly what's stored (an `.rgb` colour); otherwise it's the screen equivalent.
    public var isHexExact: Bool
    /// Hue 0..<360.
    public var hue: Double
    /// Saturation 0…1.
    public var saturation: Double
    /// HSV value of the stored RGB (1 for non-RGB colours).
    public var value: Double
    /// Colour temperature: exact for whites, approximate for near-whites, `nil` for colours.
    public var kelvin: Double?
    /// Tint −1 (green) … +1 (magenta), same rules as `kelvin`.
    public var tint: Double?
    /// True when `kelvin`/`tint` are the stored values rather than an estimate.
    public var isKelvinExact: Bool
    /// CIE 1931 chromaticity.
    public var x: Double
    public var y: Double

    public init(_ color: LightColor) {
        let c = color.sanitized
        mode = ColorModeKind(c)
        let rgb = c.sRGB
        red = rgb.r255
        green = rgb.g255
        blue = rgb.b255
        hex = rgb.hex
        if case .rgb = c { isHexExact = true } else { isHexExact = false }
        switch c {
        case .hsi(let h, let s):
            hue = wrapDegrees(h)
            saturation = clamp01(s)
            value = 1
        default:
            let hsv = rgb.hsv
            hue = hsv.h
            saturation = hsv.s
            value = hsv.v
        }
        if case .kelvin(let k, let t) = c {
            kelvin = k
            tint = t
            isKelvinExact = true
        } else if c.isWhiteish {
            let estimate = c.approximateKelvin
            kelvin = clamp(estimate.kelvin.finiteOr(5600), 1000, 20000)
            tint = clamp(estimate.tint.finiteOr(0), -1, 1)
            isKelvinExact = false
        } else {
            kelvin = nil
            tint = nil
            isKelvinExact = false
        }
        let xy = c.xy
        x = xy.x.finiteOr(0.3127)
        y = xy.y.finiteOr(0.3290)
    }

    /// True when an `.rgb` colour is stored clearly darker than full value (V < 0.6, more than
    /// about 1½ stops). The engine always plays a colour's chroma at the light's brightness, so a
    /// dark hex looks like its bright version; the inspector offers to move that darkness into
    /// the brightness slider. Everyday colours such as `#00C2B8` (V 0.76) don't trigger it.
    public var isDarkStoredColor: Bool { isHexExact && value < 0.6 && value > 0.0005 }

    /// For a dark stored RGB colour, the brightness that reproduces the hex's darkness on a
    /// light, else `nil`. With accurate (photometric) colour — the default — that's the hex's
    /// value in linear light (`#007A73` → about 19.6%); in direct "console" mode the bytes are
    /// sent as-is, so it's the plain value (≈ 47.8%).
    public func matchingIntensity(accurateColor: Bool = true) -> Double? {
        guard isDarkStoredColor else { return nil }
        return clamp01(accurateColor ? ColorMath.srgbToLinear(value) : value)
    }
}

/// Pure colour edits used by the inspector's controls.
public enum ColorEdit {
    /// An RGB channel.
    public enum Channel: String, Sendable, Hashable, CaseIterable {
        case red, green, blue
    }

    /// New colour from the wheel's hue/saturation, keeping the stored value (V) of an RGB colour
    /// so a custom dark colour keeps its hex brightness; a black (V≈0) becomes full value.
    public static func hueSaturation(_ hue: Double, _ saturation: Double, from current: LightColor) -> LightColor {
        .rgb(RGB(hue: wrapDegrees(hue.finiteOr(0)), saturation: clamp01(saturation.finiteOr(0)), value: storedValue(current)))
    }

    /// Replaces only the hue.
    public static func withHue(_ hue: Double, from current: LightColor, saturationIfGrey: Double = 1) -> LightColor {
        let v = ColorFieldValues(current)
        let s = v.saturation < 0.001 ? clamp01(saturationIfGrey) : v.saturation
        return hueSaturation(hue, s, from: current)
    }

    /// Replaces only the saturation (`hue` supplies the remembered hue for greys).
    public static func withSaturation(_ saturation: Double, from current: LightColor, hue: Double? = nil) -> LightColor {
        let v = ColorFieldValues(current)
        return hueSaturation(hue ?? v.hue, saturation, from: current)
    }

    /// Replaces one 8-bit channel, keeping the other two exactly.
    public static func withChannel(_ channel: Channel, _ byte: Int, from current: LightColor) -> LightColor {
        let rgb = current.sanitized.sRGB
        var r = rgb.r255, g = rgb.g255, b = rgb.b255
        let value = clamp(byte, 0, 255)
        switch channel {
        case .red: r = value
        case .green: g = value
        case .blue: b = value
        }
        return .rgb(RGB(r255: r, g255: g, b255: b))
    }

    /// Rotates the hue of a colour by `degrees`. Whites and greys are left alone.
    public static func hueRotated(_ color: LightColor, by degrees: Double) -> LightColor {
        let d = degrees.finiteOr(0)
        guard abs(d) > 1e-9 else { return color }
        switch color {
        case .kelvin:
            return color
        case .hsi(let h, let s):
            return s < 0.001 ? color : .hsi(hue: wrapDegrees(h + d), saturation: s)
        case .rgb(let c):
            let hsv = c.hsv
            guard hsv.s > 0.001, hsv.v > 0.001 else { return color }
            return .rgb(RGB(hue: hsv.h + d, saturation: hsv.s, value: hsv.v))
        case .xy:
            let hsv = color.displayRGB.hsv
            guard hsv.s > 0.02 else { return color }
            return .rgb(RGB(hue: hsv.h + d, saturation: hsv.s, value: hsv.v))
        }
    }

    /// Rotates the hue of a light's colour and of every pixel cell.
    public static func hueRotated(_ state: FixtureState, by degrees: Double) -> FixtureState {
        var s = state
        s.color = hueRotated(state.color, by: degrees)
        if let cells = state.cells {
            s.cells = cells.map { CellState(intensity: $0.intensity, color: hueRotated($0.color, by: degrees)) }
        }
        return s
    }

    /// The colour with its stored RGB pushed to full value — what the light actually shows.
    public static func fullValue(_ color: LightColor) -> LightColor {
        guard case .rgb(let c) = color else { return color }
        let m = max(c.r, c.g, c.b)
        guard m > 1e-6, m < 1 else { return color }
        return .rgb(RGB(r: c.r / m, g: c.g / m, b: c.b / m))
    }

    /// HSV value of a stored RGB colour (1 for other kinds; 1 for black so the wheel never paints black).
    static func storedValue(_ color: LightColor) -> Double {
        guard case .rgb(let c) = color else { return 1 }
        let v = c.hsv.v
        return v < 0.02 ? 1 : v
    }
}

extension ResolvedFixture {
    /// The Kelvin range the inspector offers for this light: the definition's CCT range (or
    /// 1,700–12,000 K) narrowed by the fixture's own limits — the same rule the engine applies.
    public var inspectorKelvinRange: ClosedRange<Double> {
        var lo = 1700.0
        var hi = 12000.0
        if let r = definition.cctRange, r.count == 2, r[0].isFinite, r[1].isFinite, r[0] < r[1] {
            lo = r[0]
            hi = r[1]
        }
        if let minK = fixture.limits.minKelvin { lo = max(lo, minK.finiteOr(lo)) }
        if let maxK = fixture.limits.maxKelvin { hi = min(hi, maxK.finiteOr(hi)) }
        if hi < lo { hi = lo }
        return lo...hi
    }

    /// The kind of colour control this light supports, in plain English.
    public var inspectorKind: InspectorFixtureKind {
        let caps = capabilities
        if caps.isDimmerOnly { return .dimmerOnly }
        if !caps.canDoColor { return .whiteOnly }
        return cellCount > 1 ? .pixel : .color
    }
}

/// What a light can do, as far as the inspector's sections are concerned.
public enum InspectorFixtureKind: String, Sendable, Hashable {
    /// Brightness only (a dimmer or a single-colour light).
    case dimmerOnly
    /// Tunable white (Kelvin, maybe tint) but no colour.
    case whiteOnly
    /// Full colour.
    case color
    /// Full colour with individually controllable pixels.
    case pixel

    /// Short badge text.
    public var badge: String {
        switch self {
        case .dimmerOnly: return "Brightness only"
        case .whiteOnly: return "Tunable white"
        case .color: return "Color"
        case .pixel: return "Pixels"
        }
    }
}
