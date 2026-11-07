import Foundation

/// Reads whatever a person types or pastes into the inspector's smart colour field.
///
/// Accepted, in this order (first confident match wins):
/// - hex: `#00C2B8`, `00c2b8`, `#0CB`, `0x00C2B8`, `#00C2B8FF`, `rgb(0, 194, 184)`, `rgba(…)`
/// - a bare RGB triple: `0, 194, 184` / `0 194 184` (each 0…255)
/// - `hsl(180, 100%, 50%)`, `hsb(…)` / `hsv(…)`, and the inspector's own `H186° S100%` label
/// - white: `3200K`, `3,200 K`, `3.2k`, `5600K +10M`, `5600k 20 g`, or a bare `3200`…`20000`
/// - CIE xy: `0.3127, 0.3290`, `x 0.3127 y 0.3290`, `xy(0.3127, 0.329)`
/// - gel codes with a brand prefix: `L201`, `LEE 201`, `R02`, `Rosco 02`
/// - colour names (`teal`, `warm white`, CSS names), real sources (`tungsten`, `sodium vapor`)
/// - gel names (`Bastard Amber`, `Full CTO`, `Congo Blue`)
///
/// Anything else returns `nil` so the field can shake and revert instead of guessing.
public enum ColorInput {
    /// What kind of text produced a match.
    public enum Source: String, Sendable, Hashable, CaseIterable {
        case hex, rgbTriple, hsl, hsb, kelvin, xy, gel, lightSource, named
    }

    /// A parsed colour plus a short, friendly description of what was understood.
    public struct Match: Sendable, Hashable {
        /// The colour to apply.
        public var color: LightColor
        /// How the text was read.
        public var source: Source
        /// Human description shown under the field, e.g. "LEE 201 Full C.T. Blue" or "3,200 K".
        public var label: String

        public init(color: LightColor, source: Source, label: String) {
            self.color = color
            self.source = source
            self.label = label
        }
    }

    /// Longest input considered (protects against pasting a whole document).
    public static let maxLength = 64

    /// Parses `raw`, returning `nil` when nothing matches with confidence.
    public static func parse(_ raw: String) -> Match? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        let lower = InspectorFormat.clean(trimmed)
        if let m = parseHex(lower) { return m }
        if let m = parseTriple(lower) { return m }
        if let m = parseHSLorHSB(lower) { return m }
        if let m = parseHSILabel(lower) { return m }
        if let m = parseKelvinTint(lower) { return m }
        if let m = parseXY(lower) { return m }
        if let m = parseGelCode(trimmed, lower: lower) { return m }
        if let named = NamedColors.lookup(trimmed) {
            return Match(color: named.color.sanitized, source: .named, label: named.name)
        }
        guard trimmed.count >= 3, trimmed.contains(where: { $0.isLetter }) else { return nil }
        if let preset = NamedColors.sourcePreset(named: trimmed) {
            return Match(color: preset.lightColor.sanitized, source: .lightSource, label: preset.name)
        }
        if let gel = GelLibrary.find(trimmed) {
            return Match(color: gel.lightColor.sanitized, source: .gel, label: gel.displayName)
        }
        return nil
    }

    // MARK: - Individual readers

    private static let hexDigits = Set("0123456789abcdef")

    /// `#…`, `0x…`, `rgb(…)`, or a bare 3/6/8-digit hex string.
    static func parseHex(_ s: String) -> Match? {
        let explicit = s.hasPrefix("#") || s.hasPrefix("0x") || s.hasPrefix("rgb(") || s.hasPrefix("rgba(")
        if !explicit {
            guard [3, 6, 8].contains(s.count), s.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        }
        guard let rgb = RGB(hex: s) else { return nil }
        return Match(color: .rgb(rgb), source: .hex, label: rgb.hex)
    }

    /// Three whole numbers 0…255 separated by commas, spaces or slashes.
    static func parseTriple(_ s: String) -> Match? {
        let tokens = s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == ";" })
        guard tokens.count == 3 else { return nil }
        var bytes: [Int] = []
        for t in tokens {
            guard t.count <= 3, t.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(t), (0...255).contains(v) else {
                return nil
            }
            bytes.append(v)
        }
        let rgb = RGB(r255: bytes[0], g255: bytes[1], b255: bytes[2])
        return Match(color: .rgb(rgb), source: .rgbTriple, label: rgb.hex)
    }

    /// `hsl(h, s%, l%)`, `hsb(h, s%, b%)`, `hsv(h, s%, v%)`.
    static func parseHSLorHSB(_ s: String) -> Match? {
        let kinds: [(prefix: String, isHSL: Bool)] = [("hsla(", true), ("hsl(", true), ("hsb(", false), ("hsv(", false)]
        guard let kind = kinds.first(where: { s.hasPrefix($0.prefix) }), s.hasSuffix(")") else { return nil }
        let body = s.dropFirst(kind.prefix.count).dropLast()
        let parts = body
            .replacingOccurrences(of: "/", with: ",")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map(String.init)
        guard parts.count >= 3 else { return nil }
        guard let hue = InspectorFormat.parseDegrees(parts[0]),
              let a = fraction(parts[1]), let b = fraction(parts[2]) else { return nil }
        let rgb = kind.isHSL ? RGB(hue: hue, saturation: a, lightness: b) : RGB(hue: hue, saturation: a, value: b)
        return Match(color: .rgb(rgb), source: kind.isHSL ? .hsl : .hsb, label: rgb.hex)
    }

    /// The inspector's own label for hue/saturation colours: `H186° S100%`.
    static func parseHSILabel(_ s: String) -> Match? {
        guard s.hasPrefix("h"), !s.hasPrefix("hs") else { return nil }
        let tokens = s.replacingOccurrences(of: "°", with: " ")
            .replacingOccurrences(of: "%", with: " ")
            .split(separator: " ")
            .map(String.init)
        guard tokens.count == 2, tokens[0].hasPrefix("h"), tokens[1].hasPrefix("s"),
              let h = InspectorFormat.parseNumber(String(tokens[0].dropFirst())),
              let sat = InspectorFormat.parseNumber(String(tokens[1].dropFirst())),
              (0...100).contains(sat) else { return nil }
        let color = LightColor.hsi(hue: wrapDegrees(h), saturation: sat / 100)
        return Match(color: color, source: .hsb, label: color.label)
    }

    /// `3200K`, `3,200 K`, `3.2k`, `5600K +10M`, `5600 kelvin 20 g`, or a bare 4–5 digit number.
    static func parseKelvinTint(_ s: String) -> Match? {
        var kelvinPart = s
        var tintPart = ""
        if let r = s.range(of: "kelvin") ?? s.range(of: "k") {
            kelvinPart = String(s[..<r.upperBound])
            tintPart = String(s[r.upperBound...])
        } else {
            let digits = s.replacingOccurrences(of: ",", with: "")
            guard (4...5).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        }
        guard let k = InspectorFormat.parseKelvin(kelvinPart) else { return nil }
        var tint = 0.0
        let t = tintPart.replacingOccurrences(of: "tint", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,;/·"))
        if !t.isEmpty {
            guard let parsed = InspectorFormat.parseTint(t) else { return nil }
            tint = parsed
        }
        let color = LightColor.kelvin(k, tint: tint)
        var label = InspectorFormat.kelvin(k)
        if abs(tint) >= 0.005 { label += " · " + InspectorFormat.tint(tint) }
        return Match(color: color, source: .kelvin, label: label)
    }

    /// Two decimals in 0…0.9: `0.3127, 0.3290`, `x 0.3127 y 0.3290`, `xy(0.3127 0.329)`.
    static func parseXY(_ s: String) -> Match? {
        var body = s
        for token in ["xy(", "xy", "(", ")", "x", "y", "=", ":"] {
            body = body.replacingOccurrences(of: token, with: " ")
        }
        let parts = body.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ $0.contains(".") }),
              let x = InspectorFormat.parseChromaticity(parts[0]),
              let y = InspectorFormat.parseChromaticity(parts[1]), y >= 0.01 else { return nil }
        let color = LightColor.xy(x: x, y: y).sanitized
        return Match(color: color, source: .xy, label: color.label)
    }

    /// A gel code with an explicit brand prefix (`L201`, `LEE 201`, `R02`, `Rosco 02`, `R-02`).
    static func parseGelCode(_ original: String, lower s: String) -> Match? {
        var rest = Substring(s)
        var brand: GelManufacturer?
        let prefixes: [(String, GelManufacturer)] = [
            ("roscolux", .rosco), ("rosco", .rosco), ("lee", .lee), ("l", .lee), ("r", .rosco),
        ]
        for (prefix, maker) in prefixes where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            brand = maker
            break
        }
        guard let brand else { return nil }
        let digits = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -#"))
        guard (1...4).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits) else { return nil }
        guard let gel = GelLibrary.find(original), gel.manufacturer == brand,
              let gelNumber = Int(gel.number.filter({ $0.isASCII && $0.isNumber })), gelNumber == number else { return nil }
        return Match(color: gel.lightColor.sanitized, source: .gel, label: gel.displayName)
    }

    /// A saturation/lightness token: `50%` → 0.5, `50` → 0.5, `0.5` → 0.5.
    private static func fraction(_ token: String) -> Double? {
        let hasPercent = token.hasSuffix("%")
        guard let v = InspectorFormat.parseNumber(token.replacingOccurrences(of: "%", with: ""), commaIsDecimal: false),
              v >= 0 else { return nil }
        if hasPercent || v > 1 { return v <= 100 ? v / 100 : nil }
        return v
    }
}
