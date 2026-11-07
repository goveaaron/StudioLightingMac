import Foundation

/// Display formatting and forgiving parsing for the inspector's exact-entry fields.
///
/// Display strings use a typographic minus (−) and non-breaking spaces before units so chips and
/// labels never wrap ("3,200 K", "−1⅓ st"). Parsers accept what people actually type ("72.4",
/// "72,4 %", "3.2k", "-1 1/3", "30 g", "184/255") and return `nil` for anything they can't read
/// with confidence, so the UI can beep and revert instead of guessing.
public enum InspectorFormat {
    /// Non-breaking space used between numbers and units.
    public static let nbsp = "\u{00A0}"
    /// Typographic minus sign used in display strings.
    public static let minus = "\u{2212}"

    // MARK: - Numbers

    /// Trims and maps typographic minus / en-dash and non-breaking spaces to plain ASCII.
    static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: minus, with: "-")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: nbsp, with: " ")
            .lowercased()
    }

    /// Parses a plain decimal number. A single comma with no dot is read as a decimal separator
    /// ("72,4" → 72.4); otherwise commas are thousands separators ("3,200" → 3200 when
    /// `commaIsDecimal` is false).
    public static func parseNumber(_ raw: String, commaIsDecimal: Bool = true) -> Double? {
        var s = clean(raw).replacingOccurrences(of: " ", with: "")
        if s.hasPrefix("+") { s.removeFirst() }
        if commaIsDecimal, !s.contains("."), s.filter({ $0 == "," }).count == 1 {
            s = s.replacingOccurrences(of: ",", with: ".")
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        guard !s.isEmpty, s.count <= 32, let v = Double(s), v.isFinite else { return nil }
        return v
    }

    /// Groups thousands with commas, independent of locale: 3200 → "3,200".
    public static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? minus : "") + out
    }

    // MARK: - Intensity (%)

    /// Intensity 0…1 as a percentage with 0.1 precision: "72.4%", "100%", "0%".
    public static func percent(_ fraction: Double) -> String {
        let p = (clamp01(fraction.finiteOr(0)) * 1000).rounded() / 10
        if p == p.rounded() { return "\(Int(p))%" }
        return String(format: "%.1f%%", p)
    }

    /// Parses an intensity typed as a percentage ("72.4", "72.4%", "72,4 %"), a word ("full",
    /// "half", "off") or a DMX value ("184/255", "dmx 184"). Returns 0…1.
    public static func parsePercent(_ text: String) -> Double? {
        let s = clean(text)
        switch s {
        case "full", "max", "on", "all": return 1
        case "off", "zero", "none", "dark": return 0
        case "half": return 0.5
        default: break
        }
        if let slash = s.firstIndex(of: "/") {
            guard let a = parseNumber(String(s[..<slash])),
                  let b = parseNumber(String(s[s.index(after: slash)...])), b > 0, a >= 0 else { return nil }
            return clamp01(a / b)
        }
        if s.hasPrefix("dmx") {
            guard let v = parseNumber(String(s.dropFirst(3))), v >= 0 else { return nil }
            return clamp01(v / 255)
        }
        guard let v = parseNumber(s.replacingOccurrences(of: "%", with: "")), v >= 0 else { return nil }
        return clamp01(v / 100)
    }

    /// The 8-bit DMX level for an intensity (0…255).
    public static func dmx(_ fraction: Double) -> Int {
        Int((clamp01(fraction.finiteOr(0)) * 255).rounded())
    }

    // MARK: - Stops

    /// Darkest level the stops scale shows (below this the light is effectively off).
    public static let minStops = -10.0

    /// Photographic stops relative to full output: 100% = 0, 50% = −1, 25% = −2.
    public static func stops(fromIntensity intensity: Double) -> Double {
        let v = clamp01(intensity.finiteOr(0))
        guard v > 0 else { return minStops }
        return max(minStops, log2(v))
    }

    /// Intensity for a stops value (2^stops, capped at full).
    public static func intensity(fromStops stops: Double) -> Double {
        guard stops.isFinite else { return stops > 0 ? 1 : 0 }
        return clamp01(pow(2, min(stops, 0)))
    }

    /// Nudges an intensity by `deltaStops` photographic stops (+⅓ = brighter). Turning an off
    /// light up starts it at 1% so the button never looks dead.
    public static func nudge(_ intensity: Double, stops deltaStops: Double) -> Double {
        let v = clamp01(intensity.finiteOr(0))
        guard deltaStops.isFinite else { return v }
        if v <= 0.0005 { return deltaStops > 0 ? 0.01 : 0 }
        return clamp01(v * pow(2, deltaStops))
    }

    /// Stops label for an intensity: "0 st", "−1 st", "−1⅓ st", "−2.4 st", or "Off".
    public static func stopsLabel(_ intensity: Double) -> String {
        let v = clamp01(intensity.finiteOr(0))
        guard v > 0 else { return "Off" }
        return stopsText(log2(v))
    }

    /// Formats a stops value, using ⅓ / ⅔ when it lands on a third.
    public static func stopsText(_ stops: Double) -> String {
        let s = stops.finiteOr(0)
        let thirds = (s * 3).rounded()
        if abs(s * 3 - thirds) < 0.03 {
            let t = Int(thirds.magnitude)
            let whole = t / 3, frac = t % 3
            var body = whole > 0 ? "\(whole)" : ""
            if frac == 1 { body += "⅓" } else if frac == 2 { body += "⅔" }
            if body.isEmpty { return "0\(nbsp)st" }
            return (thirds < 0 ? minus : "+") + body + nbsp + "st"
        }
        let r = (s * 10).rounded() / 10
        return (r < 0 ? minus : "+") + String(format: "%.1f", r.magnitude) + nbsp + "st"
    }

    /// Parses stops typed as "-1", "−1.5", "-1 1/3", "-1⅓", "−⅔", "-2 stops" or "+⅓".
    public static func parseStops(_ text: String) -> Double? {
        var s = clean(text)
        for suffix in ["stops", "stop", "st", "ev"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        s = s.trimmingCharacters(in: .whitespaces)
        var sign = 1.0
        if s.hasPrefix("-") { sign = -1; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespaces)
        var frac = 0.0
        if s.hasSuffix("⅓") { frac = 1.0 / 3; s.removeLast() }
        else if s.hasSuffix("⅔") { frac = 2.0 / 3; s.removeLast() }
        else if s.hasSuffix("1/3") { frac = 1.0 / 3; s = String(s.dropLast(3)) }
        else if s.hasSuffix("2/3") { frac = 2.0 / 3; s = String(s.dropLast(3)) }
        s = s.trimmingCharacters(in: .whitespaces)
        var whole = 0.0
        if s.isEmpty {
            guard frac > 0 else { return nil }
        } else {
            guard let w = parseNumber(s), w >= 0 else { return nil }
            whole = w
        }
        let value = sign * (whole + frac)
        return value.isFinite ? value : nil
    }

    // MARK: - Kelvin

    /// "3,200 K" (non-breaking space, so it never wraps).
    public static func kelvin(_ k: Double) -> String {
        "\(grouped(Int(k.finiteOr(0).rounded())))\(nbsp)K"
    }

    /// Compact "3200K" for tight spots.
    public static func kelvinCompact(_ k: Double) -> String {
        "\(Int(k.finiteOr(0).rounded()))K"
    }

    /// Parses "3200", "3200k", "3,200 K", "3.2k", "5.6" (thousands), "4300 kelvin" → 1000…20000 K.
    public static func parseKelvin(_ text: String) -> Double? {
        var s = clean(text)
        for suffix in ["kelvin", "k"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        guard var k = parseNumber(s, commaIsDecimal: false), k > 0 else { return nil }
        if k < 100 { k *= 1000 }
        guard k >= 1000, k <= 20000 else { return nil }
        return k
    }

    // MARK: - Tint

    /// Tint (−1 green … +1 magenta) on a ±100 scale with a letter: "0", "12 M", "30 G".
    public static func tint(_ t: Double) -> String {
        let v = Int((clamp(t.finiteOr(0), -1, 1) * 100).rounded())
        if v == 0 { return "0" }
        return v > 0 ? "\(v)\(nbsp)M" : "\(-v)\(nbsp)G"
    }

    /// Parses tint on the ±100 scale: "12m", "m12", "+12" (magenta), "-30", "30g", "g30"
    /// (green), "0" or "neutral". Returns −1…+1.
    public static func parseTint(_ text: String) -> Double? {
        var s = clean(text).replacingOccurrences(of: " ", with: "")
        if s == "neutral" || s == "none" { return 0 }
        var letterSign: Double?
        for (word, sign) in [("magenta", 1.0), ("green", -1.0), ("m", 1.0), ("g", -1.0)] {
            if s.hasSuffix(word) { s = String(s.dropLast(word.count)); letterSign = sign; break }
            if s.hasPrefix(word) { s = String(s.dropFirst(word.count)); letterSign = sign; break }
        }
        guard !s.isEmpty, let v = parseNumber(s) else { return nil }
        guard v.magnitude <= 100.0001 else { return nil }
        if let letterSign { return clamp(letterSign * v.magnitude / 100, -1, 1) }
        return clamp(v / 100, -1, 1)
    }

    // MARK: - Hue, bytes, chromaticity

    /// "186°".
    public static func degrees(_ d: Double) -> String {
        "\(Int(wrapDegrees(d.finiteOr(0)).rounded()) % 360)°"
    }

    /// Parses "186", "186°", "186 deg" → 0..<360.
    public static func parseDegrees(_ text: String) -> Double? {
        let s = clean(text).replacingOccurrences(of: "°", with: "").replacingOccurrences(of: "deg", with: "")
        guard let v = parseNumber(s) else { return nil }
        return wrapDegrees(v)
    }

    /// Parses an 8-bit channel value ("194"), clamped to 0…255.
    public static func parseByte(_ text: String) -> Int? {
        guard let v = parseNumber(text) else { return nil }
        return clamp(Int(v.rounded()), 0, 255)
    }

    /// CIE xy coordinate with 4 decimals: "0.3127".
    public static func chromaticity(_ v: Double) -> String {
        String(format: "%.4f", v.finiteOr(0))
    }

    /// Parses a chromaticity coordinate in 0…0.9.
    public static func parseChromaticity(_ text: String) -> Double? {
        guard let v = parseNumber(text), v >= 0, v <= 0.9 else { return nil }
        return v
    }
}
