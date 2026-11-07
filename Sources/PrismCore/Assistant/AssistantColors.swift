import Foundation

/// A colour the user asked for, with the words they used ("teal", "deep blue", "3200K").
public struct ColorSpec: Hashable, Sendable, Codable {
    /// Friendly name for summaries ("teal", "warm white", "#FF00AA").
    public var name: String
    public var color: LightColor

    public init(name: String, color: LightColor) {
        self.name = name; self.color = color
    }

    /// True for white-light colours (Kelvin-based).
    public var isWhite: Bool {
        if case .kelvin = color { return true }
        return false
    }

    /// The Kelvin value for white colours.
    public var kelvin: Double? {
        if case .kelvin(let k, _) = color { return k }
        return nil
    }
}

/// Saturated, light-friendly colour names for the assistant ("pink" means neon pink on an LED,
/// not CSS's pale pink), with modifiers ("deep", "pale", "hot") and fall-backs to `NamedColors`
/// (CSS, studio swatches, real light sources, gels) and Kelvin/hex literals.
public enum AssistantColors {
    /// Base lighting colours (sRGB hex, full value). Shared studio swatches use the same values.
    static let base: [(String, String)] = [
        ("red", "#FF1E1E"), ("crimson", "#FF0A3C"), ("scarlet", "#FF2A12"), ("orange", "#FF7A1A"),
        ("amber", "#FFBF00"), ("yellow", "#FFE81A"), ("gold", "#FFC233"), ("golden", "#FFC233"),
        ("lime", "#B8FF1F"), ("green", "#00FF3C"), ("emerald", "#00E676"), ("mint", "#3DFFB0"),
        ("teal", "#00C2A8"), ("turquoise", "#1AE5D0"), ("aqua", "#14E0F0"), ("cyan", "#14D8F0"),
        ("sky blue", "#4FB8FF"), ("ice blue", "#A6D8FF"), ("blue", "#1F4BFF"), ("royal blue", "#2B3BFF"),
        ("navy", "#0A2AFF"), ("cobalt", "#1A47FF"), ("indigo", "#4B00D1"), ("violet", "#8A2BFF"),
        ("purple", "#9B30FF"), ("lavender", "#B48CFF"), ("lilac", "#C8A2FF"), ("magenta", "#FF00FF"),
        ("fuchsia", "#FF1FD2"), ("pink", "#FF2FB4"), ("hot pink", "#FF1493"), ("neon pink", "#FF2FB4"),
        ("rose", "#FF3D7F"), ("salmon", "#FF8C7A"), ("peach", "#FFAA80"), ("coral", "#FF6F4F"),
        ("blush", "#FF8FB1"), ("ruby", "#E0115F"), ("cherry", "#FF1744"), ("blood red", "#C80000"),
        ("ultraviolet", "#4A00D1"), ("uv", "#4A00D1"), ("congo blue", "#2A00B8"), ("steel blue", "#A6DBFF"),
        ("neon green", "#00FF3C"), ("chartreuse", "#B8FF1F"), ("seafoam", "#5CFFC8"), ("ocean blue", "#0077FF"),
        ("electric blue", "#3D5CFF"), ("baby blue", "#8CC8FF"), ("light blue", "#7FC4FF"), ("dark blue", "#0A1FD0"),
        ("deep blue", "#0A2AFF"), ("deep red", "#C8000A"), ("deep purple", "#5A00C8"), ("light pink", "#FF8FCB"),
        ("baby pink", "#FF9FD0"), ("light green", "#7DFF9A"), ("dark green", "#00A030"), ("forest green", "#008C2A"),
        ("burnt orange", "#E8590C"), ("tangerine", "#FF8A00"), ("sunflower", "#FFD000"), ("lemon", "#FFF23D"),
        ("plum", "#A020C8"), ("mauve", "#C873FF"), ("orchid", "#E060FF"), ("raspberry", "#FF1A75")
    ]

    /// White-light names (Kelvin).
    static let whites: [(String, Double)] = [
        ("candlelight", 1900), ("candle light", 1900), ("warm white", 2700), ("soft white", 2700),
        ("tungsten", 3200), ("incandescent", 3200), ("halogen", 3000), ("golden hour", 3500),
        ("neutral white", 4000), ("neutral", 4000), ("natural white", 4000), ("white", 5600), ("pure white", 5600),
        ("daylight", 5600), ("day light", 5600), ("hmi", 5600), ("sunlight", 5600), ("cool white", 6500),
        ("cold white", 7000), ("overcast", 6500), ("moonlight", 8000), ("blue sky", 10000), ("sunset", 2000),
        ("sunrise", 2000), ("fluorescent", 4100), ("office", 4100)
    ]

    /// Modifiers that change a base colour.
    enum Modifier: String, CaseIterable {
        case deep, dark, light, pale, soft, pastel, hot, neon, bright, vivid, rich, electric, dusty, muted
    }

    static let table: [String: ColorSpec] = {
        var map: [String: ColorSpec] = [:]
        for (name, hex) in base {
            if let rgb = RGB(hex: hex) { map[name] = ColorSpec(name: name, color: .rgb(rgb)) }
        }
        for (name, k) in whites {
            map[name] = ColorSpec(name: name, color: .kelvin(k, tint: 0))
        }
        // Spoken variants.
        for (alias, name) in [("blu", "blue"), ("purpley", "purple"), ("pinky", "pink"), ("bluey", "blue"),
                              ("greeny", "green"), ("redish", "red"), ("reddish", "red"), ("bluish", "blue"),
                              ("blueish", "blue"), ("greenish", "green"), ("pinkish", "pink"), ("purplish", "purple"),
                              ("orangey", "orange"), ("orangish", "orange"), ("yellowish", "yellow"), ("tealish", "teal")] {
            if let spec = map[name] { map[alias] = ColorSpec(name: name, color: spec.color) }
        }
        return map
    }()

    /// Every single word that can start or be part of a colour phrase (for typo correction).
    public static let vocabulary: Set<String> = {
        var words = Set<String>()
        for key in table.keys { for w in key.split(separator: " ") { words.insert(String(w)) } }
        for m in Modifier.allCases { words.insert(m.rawValue) }
        return words
    }()

    /// The longest phrase in `table`, in words.
    static let maxWords = 3

    /// Looks up a colour phrase ("teal", "hot pink", "deep blue", "pale lavender", "#FF00AA", "3200k",
    /// "congo blue", "full cto"). Returns nil for anything that is not a colour.
    public static func lookup(_ phrase: String) -> ColorSpec? {
        let q = phrase.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return nil }
        if let spec = table[q] { return spec }
        if q.hasPrefix("#"), let rgb = RGB(hex: q) { return ColorSpec(name: rgb.hex, color: .rgb(rgb)) }
        if let k = kelvinLiteral(q) { return ColorSpec(name: "\(Int(k))K", color: .kelvin(k, tint: 0)) }
        let words = q.split(separator: " ").map(String.init)
        if words.count >= 2, let modifier = Modifier(rawValue: words[0]), let baseSpec = lookup(words.dropFirst().joined(separator: " ")),
           case .rgb(let rgb) = baseSpec.color {
            return ColorSpec(name: q, color: .rgb(apply(modifier, to: rgb)))
        }
        // Gels and named sources from the colour library ("full cto", "congo", "sodium vapor").
        if words.count <= 4, let named = NamedColors.lookup(q) {
            return ColorSpec(name: q, color: normalizedForLight(named.color))
        }
        if words.count >= 2, let gel = GelLibrary.gel(named: q) {
            return ColorSpec(name: q, color: normalizedForLight(gel.lightColor))
        }
        return nil
    }

    /// Finds the longest colour phrase starting at `index` in `tokens`.
    static func match(in tokens: [String], at index: Int) -> (spec: ColorSpec, consumed: Int)? {
        guard index < tokens.count else { return nil }
        let first = tokens[index]
        if first.hasPrefix("#"), let rgb = RGB(hex: first) { return (ColorSpec(name: rgb.hex, color: .rgb(rgb)), 1) }
        let maxLen = min(maxWords, tokens.count - index)
        guard maxLen >= 1 else { return nil }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let phrase = tokens[index..<(index + len)].joined(separator: " ")
            if len == 1 && !vocabulary.contains(phrase) { continue }
            if let spec = table[phrase] { return (spec, len) }
            if len >= 2, let modifier = Modifier(rawValue: tokens[index]),
               let baseSpec = table[tokens[(index + 1)..<(index + len)].joined(separator: " ")],
               case .rgb(let rgb) = baseSpec.color {
                return (ColorSpec(name: phrase, color: .rgb(apply(modifier, to: rgb))), len)
            }
        }
        return nil
    }

    /// Parses "3200k", "3200 k", "5600 kelvin".
    static func kelvinLiteral(_ q: String) -> Double? {
        var s = q.replacingOccurrences(of: " ", with: "")
        if s.hasSuffix("kelvin") { s = String(s.dropLast(6)) } else if s.hasSuffix("k") { s = String(s.dropLast()) } else { return nil }
        guard let v = Double(s), v.isFinite, v >= 1000, v <= 20000 else { return nil }
        return v
    }

    static func apply(_ modifier: Modifier, to rgb: RGB) -> RGB {
        let lch = ColorMath.rgbToOKLCh(rgb)
        var L = lch.L, C = lch.C
        switch modifier {
        case .deep, .dark, .rich: L *= 0.78; C *= 1.05
        case .light, .pale, .soft, .pastel: L = min(1, L * 1.12 + 0.08); C *= 0.45
        case .hot, .neon, .bright, .vivid, .electric: L = min(1, L * 1.04); C *= 1.12
        case .dusty, .muted: C *= 0.55
        }
        let lin = ColorMath.gamutMapOKLCh(L: L, C: C, h: lch.h)
        return RGB(linear: lin.normalized)
    }

    /// Lights carry brightness separately, so colours are normalized to full value.
    static func normalizedForLight(_ c: LightColor) -> LightColor {
        guard case .rgb(let rgb) = c else { return c }
        let m = max(rgb.r, rgb.g, rgb.b)
        guard m > 0.001, m < 0.999 else { return c }
        return .rgb(RGB(r: rgb.r / m, g: rgb.g / m, b: rgb.b / m))
    }

    /// A short friendly name for any colour ("teal", "warm white", "pink"), used when describing
    /// what the camera sees and what lights are doing.
    public static func friendlyName(for color: LightColor) -> String {
        if case .kelvin(let k, _) = color { return whiteName(k) }
        let rgb = color.displayRGB
        let lch = ColorMath.rgbToOKLCh(rgb)
        if lch.C < 0.035 {
            let k = color.approximateKelvin.kelvin
            return whiteName(k)
        }
        var best = "white"
        var bestD = Double.infinity
        for name in friendlyPalette {
            guard let spec = table[name], case .rgb(let ref) = spec.color else { continue }
            let r = ColorMath.rgbToOKLCh(ref)
            // Hue matters most; chroma and lightness only break ties.
            var dh = abs(r.h - lch.h).truncatingRemainder(dividingBy: 360)
            if dh > 180 { dh = 360 - dh }
            let d = dh / 30 + abs(r.C - lch.C) * 2 + abs(r.L - lch.L)
            if d < bestD { bestD = d; best = name }
        }
        return best
    }

    static let friendlyPalette = ["red", "orange", "amber", "yellow", "lime", "green", "mint", "teal", "cyan", "sky blue",
                                  "blue", "indigo", "violet", "purple", "magenta", "pink", "rose", "salmon", "peach"]

    static func whiteName(_ k: Double) -> String {
        switch k {
        case ..<2300: return "candle warm"
        case ..<3000: return "warm white"
        case ..<3600: return "tungsten"
        case ..<4600: return "neutral white"
        case ..<6000: return "daylight"
        case ..<7500: return "cool white"
        default: return "blue-white"
        }
    }

    /// The colour to mix toward to take some of a colour away ("less blue" → toward its opposite).
    public static func complement(of color: LightColor) -> LightColor {
        let lch = ColorMath.rgbToOKLCh(color.displayRGB)
        let lin = ColorMath.gamutMapOKLCh(L: max(lch.L, 0.75), C: min(max(lch.C, 0.08), 0.15), h: (lch.h + 180).truncatingRemainder(dividingBy: 360))
        return .rgb(RGB(linear: lin.normalized))
    }
}
