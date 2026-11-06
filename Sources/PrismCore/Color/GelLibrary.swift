import Foundation

/// Manufacturer of a lighting gel filter.
public enum GelManufacturer: String, Codable, CaseIterable, Hashable, Sendable {
    case lee = "LEE"
    case rosco = "Rosco"

    public var displayName: String { rawValue }

    /// Standard single-letter prefix used in gel codes (`L` or `R`).
    public var prefix: String {
        switch self {
        case .lee: return "L"
        case .rosco: return "R"
        }
    }
}

public typealias GelBrand = GelManufacturer

/// Functional category of a lighting gel.
public enum GelCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case cto
    case ctb
    case plusMinusGreen
    case colorCorrection
    case theatrical
    case cosmetic
    case calColor
    case storaro

    public var displayName: String {
        switch self {
        case .cto: return "CTO (Warm)"
        case .ctb: return "CTB (Cool)"
        case .plusMinusGreen: return "Plus / Minus Green"
        case .colorCorrection: return "Color Correction"
        case .theatrical: return "Color Effect"
        case .cosmetic: return "Cosmetic / Diffusion Tint"
        case .calColor: return "CalColor"
        case .storaro: return "Storaro Selection"
        }
    }
}

/// A lighting gel filter (LEE Filters or Rosco Roscolux / Cinegel).
public struct Gel: Codable, Hashable, Sendable, Identifiable {
    /// Canonical code, e.g. `"L201"`, `"R02"`, `"L204"`.
    public var id: String
    /// Filter number without manufacturer prefix, e.g. `"201"`, `"02"`, `"3407"`.
    public var number: String
    /// Official filter name, e.g. `"Full CTB"`, `"Bastard Amber"`, `"Congo Blue"`.
    public var name: String
    public var manufacturer: GelManufacturer
    public var category: GelCategory
    /// CIE 1931 x chromaticity (under standard C/D65 or 3200K reference).
    public var cieX: Double
    /// CIE 1931 y chromaticity.
    public var cieY: Double
    /// Representative sRGB color for swatches and RGB mixing.
    public var rgb: RGB
    /// Photopic luminous transmission Y% as a fraction in `0...1` (e.g. `0.36` = 36%).
    public var transmission: Double
    /// Optional mired shift for CTO (+mireds) and CTB (-mireds) correction gels.
    public var miredShift: Double?
    /// Optional Prism tint shift (-1 = full Plus Green, +1 = full Minus Green).
    public var tintShift: Double?

    public init(
        id: String,
        number: String,
        name: String,
        manufacturer: GelManufacturer,
        category: GelCategory,
        cieX: Double? = nil,
        cieY: Double? = nil,
        rgb: RGB,
        transmission: Double,
        miredShift: Double? = nil,
        tintShift: Double? = nil
    ) {
        self.id = id
        self.number = number
        self.name = name
        self.manufacturer = manufacturer
        self.category = category
        let derivedXY = ColorMath.linearSRGBToXY(rgb.linear)
        self.cieX = cieX ?? derivedXY.x
        self.cieY = cieY ?? derivedXY.y
        self.rgb = rgb
        self.transmission = clamp01(transmission)
        self.miredShift = miredShift
        self.tintShift = tintShift
    }

    /// Code alias (`"L201"`, `"R02"`).
    public var code: String { id }

    /// Brand alias.
    public var brand: GelManufacturer { manufacturer }

    /// CIE 1931 xy tuple.
    public var xy: (x: Double, y: Double) { (cieX, cieY) }

    /// Hex string of the gel's swatch color.
    public var hex: String { rgb.hex }

    /// Transmission percentage (0...100).
    public var transmissionPercent: Double { transmission * 100.0 }

    /// Formatted title, e.g. `"L201 Full CTB"`.
    public var displayName: String { "\(id) \(name)" }

    /// Default `LightColor` when this gel is applied to a standard source (5600K for CTO,
    /// 3200K for CTB, 5600K for Plus/Minus Green, or the gel's chromaticity for color gels).
    public var lightColor: LightColor {
        switch category {
        case .cto:
            return color(baseKelvin: 5600, baseTint: 0)
        case .ctb:
            return color(baseKelvin: 3200, baseTint: 0)
        case .plusMinusGreen:
            return color(baseKelvin: 5600, baseTint: 0)
        default:
            return .rgb(rgb)
        }
    }

    /// Computes the `LightColor` produced by placing this gel in front of a white source at
    /// `baseKelvin` and `baseTint`.
    public func color(baseKelvin: Double = 5600, baseTint: Double = 0) -> LightColor {
        if miredShift != nil || tintShift != nil {
            let baseMired = 1_000_000.0 / clamp(baseKelvin.finiteOr(5600), 1000, 25000)
            let targetMired = clamp(baseMired + (miredShift ?? 0), 40, 1000)
            let targetKelvin = clamp(1_000_000.0 / targetMired, 1000, 20000)
            let targetTint = clamp(baseTint.finiteOr(0) + (tintShift ?? 0), -1, 1)
            return .kelvin(targetKelvin, tint: targetTint)
        }
        // For theatrical/effect gels, adapt slightly for warmer/cooler base sources if different from 5600K.
        let k = clamp(baseKelvin.finiteOr(5600), 1700, 20000)
        if abs(k - 5600) < 150 && abs(baseTint) < 0.01 {
            return .rgb(rgb)
        }
        let sourceLinear = LightColor.kelvin(k, tint: baseTint).linearRGB
        let d65Source = LightColor.kelvin(5600, tint: 0).linearRGB
        let gLinear = rgb.linear
        let adapted = LinearRGB(
            r: gLinear.r * (sourceLinear.r / max(d65Source.r, 0.1)),
            g: gLinear.g * (sourceLinear.g / max(d65Source.g, 0.1)),
            b: gLinear.b * (sourceLinear.b / max(d65Source.b, 0.1))
        ).clamped.normalized
        return .rgb(RGB(linear: adapted))
    }
}

public typealias GelFilter = Gel
public typealias GelEntry = Gel

/// Built-in library of ~230 industry-standard LEE and Rosco lighting gels.
public enum GelLibrary {
    /// All bundled gels (LEE and Rosco).
    public static let all: [Gel] = buildCatalog()

    /// Alias for `all`.
    public static var gels: [Gel] { all }

    /// All LEE Filters gels.
    public static let lee: [Gel] = all.filter { $0.manufacturer == .lee }

    /// All Rosco gels.
    public static let rosco: [Gel] = all.filter { $0.manufacturer == .rosco }

    /// All CTO (warm color temperature orange) correction gels.
    public static let cto: [Gel] = all.filter { $0.category == .cto }

    /// All CTB (cool color temperature blue) correction gels.
    public static let ctb: [Gel] = all.filter { $0.category == .ctb }

    /// All Plus / Minus Green fluorescent correction gels.
    public static let plusMinusGreen: [Gel] = all.filter { $0.category == .plusMinusGreen }

    /// All color-correction gels (CTO, CTB, Plus/Minus Green, and specialty arc/fluorescent correction).
    public static let colorCorrection: [Gel] = all.filter {
        switch $0.category {
        case .cto, .ctb, .plusMinusGreen, .colorCorrection: return true
        default: return false
        }
    }

    private static let byID: [String: Gel] = {
        var map: [String: Gel] = [:]
        for g in all {
            map[g.id.lowercased()] = g
        }
        return map
    }()

    /// Looks up a single gel by code (`"L201"`, `"R02"`, `"LEE 201"`, `"Rosco 02"`),
    /// bare number (`"201"`, `"02"`), or name (`"Bastard Amber"`, `"Full CTO"`, `"Congo Blue"`).
    public static func gel(_ query: String) -> Gel? {
        find(query)
    }

    public static func gel(named query: String) -> Gel? {
        find(query)
    }

    /// Looks up a single gel by code, number, or name.
    public static func find(_ query: String) -> Gel? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if let exact = byID[lower] { return exact }

        // Normalize prefixes like "lee 201", "rosco 02", "r-02", "l-201", "roscolux 02"
        let collapsed = lower
            .replacingOccurrences(of: "roscolux", with: "r")
            .replacingOccurrences(of: "rosco", with: "r")
            .replacingOccurrences(of: "cinegel", with: "r")
            .replacingOccurrences(of: "lee filters", with: "l")
            .replacingOccurrences(of: "lee", with: "l")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let byCode = byID[collapsed] { return byCode }

        // Handle zero-padded or unpadded numbers with prefix: e.g. "R2" -> "R02", "L2" -> "L002"
        if collapsed.hasPrefix("r"), let num = Int(collapsed.dropFirst()) {
            for candidate in [String(format: "r%02d", num), String(format: "r%d", num), String(format: "r%04d", num)] {
                if let g = byID[candidate] { return g }
            }
        }
        if collapsed.hasPrefix("l"), let num = Int(collapsed.dropFirst()) {
            for candidate in [String(format: "l%03d", num), String(format: "l%02d", num), String(format: "l%d", num)] {
                if let g = byID[candidate] { return g }
            }
        }

        // Bare number match
        if let num = Int(raw) {
            let candidates = [
                String(format: "%03d", num),
                String(format: "%02d", num),
                String(format: "%d", num)
            ]
            if let match = all.first(where: { candidates.contains($0.number.lowercased()) }) {
                return match
            }
        }

        // Exact name match (normalized)
        let normQuery = normalize(raw)
        if let exactName = all.first(where: { normalize($0.name) == normQuery || normalize($0.displayName) == normQuery }) {
            return exactName
        }

        // Fraction aliases: e.g. "full cto", "1/2 cto", "half cto", "1/4 ctb", "quarter ctb", "plus green", "minus green"
        let aliasNorm = normalizeFractionWords(normQuery)
        if let match = all.first(where: { normalizeFractionWords(normalize($0.name)) == aliasNorm }) {
            return match
        }

        return search(raw).first
    }

    /// Searches gels by code, number, name, or category, returning ranked matches.
    public static func search(
        _ query: String = "",
        manufacturer: GelManufacturer? = nil,
        category: GelCategory? = nil
    ) -> [Gel] {
        let base = all.filter { g in
            if let manufacturer, g.manufacturer != manufacturer { return false }
            if let category, g.category != category { return false }
            return true
        }
        let q = normalize(query)
        guard !q.isEmpty else { return base }
        let qFrac = normalizeFractionWords(q)
        let words = qFrac.split(separator: " ").map(String.init)

        var scored: [(Gel, Int)] = []
        for g in base {
            let idNorm = g.id.lowercased()
            let numNorm = g.number.lowercased()
            let nameNorm = normalize(g.name)
            let nameFrac = normalizeFractionWords(nameNorm)
            let hay = "\(idNorm) \(numNorm) \(g.manufacturer.rawValue.lowercased()) \(nameFrac) \(g.category.displayName.lowercased())"

            var score = 0
            if idNorm == q || numNorm == q { score += 200 }
            else if idNorm.hasPrefix(q) || numNorm.hasPrefix(q) { score += 120 }
            if nameNorm == q || nameFrac == qFrac { score += 180 }
            else if nameNorm.hasPrefix(q) || nameFrac.hasPrefix(qFrac) { score += 100 }
            else if nameNorm.contains(q) || nameFrac.contains(qFrac) { score += 60 }

            var allWordsMatch = true
            for w in words {
                if hay.contains(w) {
                    score += 20
                } else {
                    allWordsMatch = false
                }
            }
            if score > 0 && (allWordsMatch || words.count == 1) {
                scored.append((g, score))
            }
        }

        return scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.id < b.0.id
        }.map(\.0)
    }

    /// Returns the closest gels to a target `LightColor` ranked by CIEDE2000 color difference.
    public static func closest(
        to color: LightColor,
        manufacturer: GelManufacturer? = nil,
        limit: Int = 5
    ) -> [Gel] {
        let targetRGB = color.displayRGB
        let pool = manufacturer == nil ? all : all.filter { $0.manufacturer == manufacturer }
        return pool
            .map { ($0, ColorMath.deltaE2000(targetRGB, $0.rgb)) }
            .sorted { $0.1 < $1.1 }
            .prefix(max(1, limit))
            .map(\.0)
    }

    /// Loads additional or custom gels from a JSON file (`[Gel]`).
    public static func load(from url: URL) -> [Gel] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Gel].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        var out = ""
        var lastSpace = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "/" || ch == "." || ch == "+" || ch == "-" {
                out.append(ch)
                lastSpace = false
            } else if !lastSpace {
                out.append(" ")
                lastSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizeFractionWords(_ s: String) -> String {
        s.replacingOccurrences(of: "three quarter", with: "3/4")
            .replacingOccurrences(of: "three-quarter", with: "3/4")
            .replacingOccurrences(of: "half", with: "1/2")
            .replacingOccurrences(of: "quarter", with: "1/4")
            .replacingOccurrences(of: "eighth", with: "1/8")
            .replacingOccurrences(of: "plusgreen", with: "plus green")
            .replacingOccurrences(of: "minusgreen", with: "minus green")
    }

    // MARK: - Catalog builder (~230 LEE & Rosco gels)

    // swiftlint:disable function_body_length
    private static func buildCatalog() -> [Gel] {
        func g(
            _ mfr: GelManufacturer,
            _ num: String,
            _ name: String,
            _ cat: GelCategory,
            _ hex: String,
            _ trans: Double,
            mired: Double? = nil,
            tint: Double? = nil,
            xy: (Double, Double)? = nil
        ) -> Gel {
            let rgb = RGB(hex: hex) ?? .white
            return Gel(
                id: "\(mfr.prefix)\(num)",
                number: num,
                name: name,
                manufacturer: mfr,
                category: cat,
                cieX: xy?.0,
                cieY: xy?.1,
                rgb: rgb,
                transmission: trans,
                miredShift: mired,
                tintShift: tint
            )
        }

        return [
            // =========================================================================
            // 1. LEE CTO / Warm Correction Family
            // =========================================================================
            g(.lee, "204", "Full C.T. Orange", .cto, "#FFA957", 0.55, mired: 131, xy: (0.459, 0.410)),
            g(.lee, "205", "1/2 C.T. Orange", .cto, "#FFC489", 0.71, mired: 81, xy: (0.398, 0.388)),
            g(.lee, "206", "1/4 C.T. Orange", .cto, "#FFD9B3", 0.79, mired: 42, xy: (0.358, 0.365)),
            g(.lee, "223", "1/8 C.T. Orange", .cto, "#FFEAD3", 0.85, mired: 26, xy: (0.336, 0.348)),
            g(.lee, "285", "3/4 C.T. Orange", .cto, "#FFB56B", 0.61, mired: 109, xy: (0.431, 0.401)),
            g(.lee, "287", "Double C.T. Orange", .cto, "#FF821E", 0.32, mired: 245, xy: (0.525, 0.415)),
            g(.lee, "208", "Full C.T. Orange + .6 ND", .cto, "#DF9046", 0.14, mired: 131, xy: (0.459, 0.410)),
            g(.lee, "441", "Full C.T. Straw", .cto, "#FFB65C", 0.57, mired: 131, xy: (0.456, 0.422)),
            g(.lee, "442", "1/2 C.T. Straw", .cto, "#FFCC8C", 0.71, mired: 81, xy: (0.396, 0.396)),
            g(.lee, "443", "1/4 C.T. Straw", .cto, "#FFDFB6", 0.79, mired: 42, xy: (0.357, 0.371)),
            g(.lee, "444", "1/8 C.T. Straw", .cto, "#FFEDD4", 0.85, mired: 26, xy: (0.335, 0.351)),

            // =========================================================================
            // 2. Rosco CTO / Warm Correction Family (Cinegel Sun)
            // =========================================================================
            g(.rosco, "3407", "Roscosun CTO", .cto, "#FFA854", 0.55, mired: 131, xy: (0.460, 0.410)),
            g(.rosco, "3408", "Roscosun 1/2 CTO", .cto, "#FFC58A", 0.73, mired: 81, xy: (0.398, 0.388)),
            g(.rosco, "3409", "Roscosun 1/4 CTO", .cto, "#FFDAB4", 0.81, mired: 42, xy: (0.358, 0.365)),
            g(.rosco, "3410", "Roscosun 1/8 CTO", .cto, "#FFEBD5", 0.92, mired: 20, xy: (0.333, 0.345)),
            g(.rosco, "3411", "Roscosun 3/4 CTO", .cto, "#FFB66C", 0.62, mired: 109, xy: (0.431, 0.401)),
            g(.rosco, "3420", "Roscosun Double CTO", .cto, "#FF801B", 0.30, mired: 250, xy: (0.528, 0.415)),
            g(.rosco, "3401", "Roscosun 85", .cto, "#FFA54F", 0.58, mired: 131, xy: (0.461, 0.411)),
            g(.rosco, "3441", "Full Straw (CTS)", .cto, "#FFB55A", 0.56, mired: 131, xy: (0.456, 0.422)),
            g(.rosco, "3442", "1/2 Straw (1/2 CTS)", .cto, "#FFCC8A", 0.72, mired: 81, xy: (0.396, 0.396)),
            g(.rosco, "3443", "1/4 Straw (1/4 CTS)", .cto, "#FFDFB4", 0.81, mired: 42, xy: (0.357, 0.371)),
            g(.rosco, "3444", "1/8 Straw (1/8 CTS)", .cto, "#FFEED6", 0.90, mired: 20, xy: (0.335, 0.351)),

            // =========================================================================
            // 3. LEE CTB / Cool Correction Family
            // =========================================================================
            g(.lee, "200", "Double C.T. Blue", .ctb, "#69A3FF", 0.14, mired: -274, xy: (0.232, 0.238)),
            g(.lee, "201", "Full C.T. Blue", .ctb, "#96C2FF", 0.36, mired: -137, xy: (0.273, 0.285)),
            g(.lee, "281", "3/4 C.T. Blue", .ctb, "#AACFFF", 0.44, mired: -103, xy: (0.285, 0.299)),
            g(.lee, "202", "1/2 C.T. Blue", .ctb, "#BEDBFF", 0.55, mired: -68, xy: (0.297, 0.313)),
            g(.lee, "203", "1/4 C.T. Blue", .ctb, "#D8EAFF", 0.69, mired: -35, xy: (0.308, 0.326)),
            g(.lee, "218", "1/8 C.T. Blue", .ctb, "#EAF3FF", 0.81, mired: -18, xy: (0.314, 0.333)),

            // =========================================================================
            // 4. Rosco CTB / Cool Correction Family (Cinegel Tough Blue)
            // =========================================================================
            g(.rosco, "3220", "Double Blue (2x CTB)", .ctb, "#68A1FF", 0.13, mired: -260, xy: (0.234, 0.240)),
            g(.rosco, "3202", "Full Blue (CTB)", .ctb, "#95C1FF", 0.36, mired: -131, xy: (0.274, 0.286)),
            g(.rosco, "3203", "3/4 Blue (3/4 CTB)", .ctb, "#A9CEFF", 0.42, mired: -100, xy: (0.286, 0.300)),
            g(.rosco, "3204", "1/2 Blue (1/2 CTB)", .ctb, "#BDDAFF", 0.52, mired: -68, xy: (0.297, 0.313)),
            g(.rosco, "3206", "1/3 Blue (1/3 CTB)", .ctb, "#CEE4FF", 0.64, mired: -49, xy: (0.303, 0.320)),
            g(.rosco, "3208", "1/4 Blue (1/4 CTB)", .ctb, "#D9EBFF", 0.74, mired: -35, xy: (0.308, 0.326)),
            g(.rosco, "3216", "1/8 Blue (1/8 CTB)", .ctb, "#EAF3FF", 0.84, mired: -18, xy: (0.314, 0.333)),

            // =========================================================================
            // 5. LEE & Rosco Plus / Minus Green Family
            // =========================================================================
            g(.lee, "244", "Full Plus Green", .plusMinusGreen, "#B3FF9E", 0.74, tint: -1.0, xy: (0.325, 0.415)),
            g(.lee, "245", "1/2 Plus Green", .plusMinusGreen, "#CEFFBF", 0.82, tint: -0.5, xy: (0.320, 0.375)),
            g(.lee, "246", "1/4 Plus Green", .plusMinusGreen, "#E4FFDC", 0.86, tint: -0.25, xy: (0.316, 0.352)),
            g(.lee, "278", "1/8 Plus Green", .plusMinusGreen, "#F1FFEC", 0.89, tint: -0.125, xy: (0.314, 0.340)),
            g(.lee, "247", "Full Minus Green", .plusMinusGreen, "#FFAAE2", 0.55, tint: 1.0, xy: (0.345, 0.268)),
            g(.lee, "248", "1/2 Minus Green", .plusMinusGreen, "#FFC9ED", 0.72, tint: 0.5, xy: (0.330, 0.298)),
            g(.lee, "249", "1/4 Minus Green", .plusMinusGreen, "#FFE2F5", 0.81, tint: 0.25, xy: (0.321, 0.314)),
            g(.lee, "279", "1/8 Minus Green", .plusMinusGreen, "#FFF1FA", 0.87, tint: 0.125, xy: (0.317, 0.321)),
            g(.lee, "219", "LEE Fluorescent Green", .plusMinusGreen, "#9AF0B0", 0.52, mired: -45, tint: -0.85),

            g(.rosco, "3304", "Tough Plusgreen (Full)", .plusMinusGreen, "#B2FF9C", 0.76, tint: -1.0, xy: (0.325, 0.415)),
            g(.rosco, "3315", "Tough 1/2 Plusgreen", .plusMinusGreen, "#CEFFBF", 0.82, tint: -0.5, xy: (0.320, 0.375)),
            g(.rosco, "3316", "Tough 1/4 Plusgreen", .plusMinusGreen, "#E4FFDC", 0.88, tint: -0.25, xy: (0.316, 0.352)),
            g(.rosco, "3317", "Tough 1/8 Plusgreen", .plusMinusGreen, "#F1FFEC", 0.91, tint: -0.125, xy: (0.314, 0.340)),
            g(.rosco, "3308", "Tough Minusgreen (Full)", .plusMinusGreen, "#FFA9E1", 0.55, tint: 1.0, xy: (0.345, 0.268)),
            g(.rosco, "3313", "Tough 1/2 Minusgreen", .plusMinusGreen, "#FFC9ED", 0.71, tint: 0.5, xy: (0.330, 0.298)),
            g(.rosco, "3314", "Tough 1/4 Minusgreen", .plusMinusGreen, "#FFE2F5", 0.81, tint: 0.25, xy: (0.321, 0.314)),
            g(.rosco, "3318", "Tough 1/8 Minusgreen", .plusMinusGreen, "#FFF1FA", 0.88, tint: 0.125, xy: (0.317, 0.321)),
            g(.rosco, "3306", "Tough Fluorofilter", .plusMinusGreen, "#FF99C8", 0.46, mired: 60, tint: 0.9),
            g(.rosco, "3310", "Fluorofilter", .plusMinusGreen, "#FF9ECA", 0.48, mired: 55, tint: 0.85),

            // =========================================================================
            // 6. Specialty Color Correction (Arc / Fluorescent / Sodium)
            // =========================================================================
            g(.lee, "212", "L.C.T. Yellow (Y1)", .colorCorrection, "#FFF0B8", 0.85, mired: 28),
            g(.lee, "213", "White Flame Green", .colorCorrection, "#D4FFDF", 0.80, tint: -0.35),
            g(.lee, "230", "Super Correction L.C.T. Yellow", .colorCorrection, "#FFDF9E", 0.72, mired: 55),
            g(.lee, "232", "Super Correction W.F. Green", .colorCorrection, "#FFB88C", 0.49, mired: 95, tint: 0.35),
            g(.lee, "236", "H.M.I. (to Tungsten)", .colorCorrection, "#FFAC63", 0.56, mired: 115),
            g(.lee, "237", "C.I.D. (to Tungsten)", .colorCorrection, "#FFA672", 0.49, mired: 110, tint: 0.25),
            g(.lee, "238", "C.S.I. (to Tungsten)", .colorCorrection, "#FFAC85", 0.56, mired: 80, tint: 0.30),
            g(.lee, "241", "LEE Fluorescent 5700K", .colorCorrection, "#9CD2FF", 0.45, mired: -95, tint: 0.45),
            g(.lee, "242", "LEE Fluorescent 4300K", .colorCorrection, "#B6DAFF", 0.52, mired: -55, tint: 0.45),
            g(.lee, "243", "LEE Fluorescent 3600K", .colorCorrection, "#D6E4FF", 0.60, mired: -25, tint: 0.45),
            g(.lee, "650", "Industry Sodium", .colorCorrection, "#FFB866", 0.42, mired: 120, tint: -0.15),
            g(.lee, "651", "HI Sodium", .colorCorrection, "#FFA452", 0.38, mired: 145, tint: 0.10),
            g(.lee, "652", "Urban Sodium", .colorCorrection, "#FF8C3B", 0.32, mired: 185, tint: 0.15),
            g(.lee, "653", "LO Sodium", .colorCorrection, "#FF9900", 0.22, mired: 240, tint: -0.20),

            // =========================================================================
            // 7. Roscolux Theatrical & Cinema Gels (R01 – R389)
            // =========================================================================
            g(.rosco, "01", "Light Bastard Amber", .theatrical, "#FFCFB3", 0.85),
            g(.rosco, "02", "Bastard Amber", .theatrical, "#FFC79E", 0.78),
            g(.rosco, "03", "Dark Bastard Amber", .theatrical, "#FFB585", 0.70),
            g(.rosco, "04", "Medium Bastard Amber", .theatrical, "#FFBF96", 0.74),
            g(.rosco, "05", "Rose Tint", .theatrical, "#FFD6DC", 0.83),
            g(.rosco, "06", "No Color Straw", .theatrical, "#FFF8D4", 0.90),
            g(.rosco, "07", "Pale Yellow", .theatrical, "#FFF4B0", 0.88),
            g(.rosco, "08", "Pale Gold", .theatrical, "#FFE3A6", 0.83),
            g(.rosco, "09", "Pale Amber Gold", .theatrical, "#FFD48C", 0.78),
            g(.rosco, "10", "Medium Yellow", .theatrical, "#FFEA3B", 0.85),
            g(.rosco, "11", "Light Straw", .theatrical, "#FFEC7A", 0.86),
            g(.rosco, "12", "Straw", .theatrical, "#FFE34D", 0.82),
            g(.rosco, "13", "Straw Tint", .theatrical, "#FFE8A8", 0.81),
            g(.rosco, "14", "Medium Straw", .theatrical, "#FFDA57", 0.76),
            g(.rosco, "15", "Deep Straw", .theatrical, "#FFC81F", 0.67),
            g(.rosco, "16", "Light Amber", .theatrical, "#FFC26B", 0.73),
            g(.rosco, "17", "Light Flame", .theatrical, "#FFAB6E", 0.58),
            g(.rosco, "18", "Flame", .theatrical, "#FF9B54", 0.50),
            g(.rosco, "19", "Fire", .theatrical, "#FF521B", 0.23),
            g(.rosco, "20", "Medium Amber", .theatrical, "#FFA52E", 0.52),
            g(.rosco, "21", "Golden Amber", .theatrical, "#FF8412", 0.43),
            g(.rosco, "22", "Deep Amber", .theatrical, "#FF5E0D", 0.28),
            g(.rosco, "23", "Orange", .theatrical, "#FF700A", 0.32),
            g(.rosco, "24", "Scarlet", .theatrical, "#FF3824", 0.19),
            g(.rosco, "25", "Orange Red", .theatrical, "#FF3D14", 0.16),
            g(.rosco, "26", "Light Red", .theatrical, "#F51929", 0.12),
            g(.rosco, "27", "Medium Red", .theatrical, "#D4081E", 0.06),
            g(.rosco, "30", "Light Salmon Pink", .theatrical, "#FFA391", 0.64),
            g(.rosco, "31", "Salmon Pink", .theatrical, "#FF9485", 0.56),
            g(.rosco, "32", "Medium Salmon Pink", .theatrical, "#FF756E", 0.42),
            g(.rosco, "33", "No Color Pink", .theatrical, "#FFD4DE", 0.80),
            g(.rosco, "34", "Flesh Pink", .theatrical, "#FFA6BC", 0.58),
            g(.rosco, "35", "Light Pink", .theatrical, "#FFB8CF", 0.69),
            g(.rosco, "36", "Medium Pink", .theatrical, "#FF8FB3", 0.50),
            g(.rosco, "37", "Pale Rose Pink", .theatrical, "#FFBAD4", 0.64),
            g(.rosco, "38", "Light Rose", .theatrical, "#FFADC7", 0.62),
            g(.rosco, "39", "Skelton Exotic Sangria", .theatrical, "#D9268A", 0.16),
            g(.rosco, "40", "Light Salmon", .theatrical, "#FF805E", 0.44),
            g(.rosco, "41", "Salmon", .theatrical, "#FF694A", 0.35),
            g(.rosco, "42", "Deep Salmon", .theatrical, "#F54538", 0.21),
            g(.rosco, "43", "Deep Pink", .theatrical, "#FF528C", 0.29),
            g(.rosco, "44", "Middle Rose", .theatrical, "#F7599E", 0.30),
            g(.rosco, "45", "Rose", .theatrical, "#E32973", 0.16),
            g(.rosco, "46", "Magenta", .theatrical, "#D4197A", 0.12),
            g(.rosco, "47", "Light Rose Purple", .theatrical, "#C45EAB", 0.25),
            g(.rosco, "48", "Rose Purple", .theatrical, "#AD3B9E", 0.15),
            g(.rosco, "49", "Medium Purple", .theatrical, "#8F218C", 0.08),
            g(.rosco, "50", "Mauve", .theatrical, "#9E2E6B", 0.12),
            g(.rosco, "51", "Surprise Pink", .theatrical, "#D49EFF", 0.45),
            g(.rosco, "52", "Light Lavender", .theatrical, "#DEC2FF", 0.56),
            g(.rosco, "53", "Pale Lavender", .theatrical, "#EAD9FF", 0.72),
            g(.rosco, "54", "Special Lavender", .theatrical, "#D9BDFF", 0.64),
            g(.rosco, "55", "Lilac", .theatrical, "#BA9EFF", 0.44),
            g(.rosco, "56", "Gypsy Lavender", .theatrical, "#8C52E3", 0.18),
            g(.rosco, "57", "Lavender", .theatrical, "#A87AFF", 0.32),
            g(.rosco, "58", "Deep Lavender", .theatrical, "#7D42D9", 0.13),
            g(.rosco, "59", "Indigo", .theatrical, "#4D17B8", 0.05),
            g(.rosco, "60", "No Color Blue", .theatrical, "#D9ECFF", 0.68),
            g(.rosco, "61", "Mist Blue", .theatrical, "#CFE8FF", 0.65),
            g(.rosco, "62", "Booster Blue", .theatrical, "#B5DBFF", 0.56),
            g(.rosco, "63", "Pale Blue", .theatrical, "#B8E3FF", 0.58),
            g(.rosco, "64", "Light Steel Blue", .theatrical, "#7DC8FF", 0.36),
            g(.rosco, "65", "Daylight Blue", .theatrical, "#5CBFFF", 0.30),
            g(.rosco, "66", "Cool Blue", .theatrical, "#78D4FF", 0.44),
            g(.rosco, "67", "Light Sky Blue", .theatrical, "#4FB8FF", 0.27),
            g(.rosco, "68", "Sky Blue", .theatrical, "#2B94F5", 0.16),
            g(.rosco, "69", "Brilliant Blue", .theatrical, "#1A8CEB", 0.14),
            g(.rosco, "70", "Nile Blue", .theatrical, "#70DEEB", 0.42),
            g(.rosco, "71", "Sea Blue", .theatrical, "#269EB8", 0.18),
            g(.rosco, "72", "Azure Blue", .theatrical, "#45B5DB", 0.28),
            g(.rosco, "73", "Peacock Blue", .theatrical, "#00A3AD", 0.20),
            g(.rosco, "74", "Night Blue", .theatrical, "#1F3BD4", 0.05),
            g(.rosco, "75", "Twilight Blue", .theatrical, "#196BB8", 0.12),
            g(.rosco, "76", "Light Green Blue", .theatrical, "#0087B5", 0.14),
            g(.rosco, "77", "Green Blue", .theatrical, "#006E9E", 0.10),
            g(.rosco, "78", "Trudy Blue", .theatrical, "#3B6BD9", 0.14),
            g(.rosco, "79", "Bright Blue", .theatrical, "#0F5CE6", 0.08),
            g(.rosco, "80", "Primary Blue", .theatrical, "#0A47DB", 0.07),
            g(.rosco, "81", "Urban Blue", .theatrical, "#2159C9", 0.09),
            g(.rosco, "82", "Surprise Blue", .theatrical, "#3347C4", 0.07),
            g(.rosco, "83", "Medium Blue", .theatrical, "#0830B8", 0.04),
            g(.rosco, "84", "Zephyr Blue", .theatrical, "#5982E3", 0.21),
            g(.rosco, "85", "Deep Blue", .theatrical, "#0526A6", 0.03),
            g(.rosco, "86", "Pea Green", .theatrical, "#A3EB52", 0.60),
            g(.rosco, "87", "Pale Yellow Green", .theatrical, "#D9F7A6", 0.78),
            g(.rosco, "88", "Light Green", .theatrical, "#B0EB82", 0.66),
            g(.rosco, "89", "Moss Green", .theatrical, "#59C45E", 0.38),
            g(.rosco, "90", "Dark Yellow Green", .theatrical, "#1EA638", 0.15),
            g(.rosco, "91", "Primary Green", .theatrical, "#0A8729", 0.09),
            g(.rosco, "92", "Turquoise", .theatrical, "#47DEC9", 0.52),
            g(.rosco, "93", "Blue Green", .theatrical, "#14AD9E", 0.26),
            g(.rosco, "94", "Kelly Green", .theatrical, "#0FB866", 0.22),
            g(.rosco, "95", "Medium Blue Green", .theatrical, "#00968F", 0.18),
            g(.rosco, "96", "Lime", .theatrical, "#C4F24B", 0.74),
            g(.rosco, "99", "Chocolate", .theatrical, "#B88A6E", 0.42),
            g(.rosco, "312", "Canary", .theatrical, "#FFE629", 0.84),
            g(.rosco, "316", "Gallo Gold", .theatrical, "#FFB057", 0.62),
            g(.rosco, "317", "Apricot", .theatrical, "#FF9E5E", 0.54),
            g(.rosco, "318", "Mayan Sun", .theatrical, "#FF8247", 0.45),
            g(.rosco, "321", "Soft Golden Amber", .theatrical, "#FF9942", 0.52),
            g(.rosco, "332", "Cherry Rose", .theatrical, "#FF4578", 0.24),
            g(.rosco, "342", "Rose Pink", .theatrical, "#FF4F94", 0.26),
            g(.rosco, "358", "Rose Indigo", .theatrical, "#6624A8", 0.07),
            g(.rosco, "364", "Blue Bell", .theatrical, "#8AB3F2", 0.42),
            g(.rosco, "370", "Italian Blue", .theatrical, "#1AD1EB", 0.35),
            g(.rosco, "382", "Congo Blue", .theatrical, "#2E0882", 0.01),
            g(.rosco, "385", "Royal Blue", .theatrical, "#1B249E", 0.03),
            g(.rosco, "389", "Chroma Green", .theatrical, "#29DE38", 0.38),

            // =========================================================================
            // 8. Rosco Storaro Selection (R2001 – R2010)
            // =========================================================================
            g(.rosco, "2001", "Storaro Red", .storaro, "#D90F1E", 0.08),
            g(.rosco, "2002", "Storaro Orange", .storaro, "#FF6E0D", 0.32),
            g(.rosco, "2003", "Storaro Yellow", .storaro, "#FFDE1A", 0.78),
            g(.rosco, "2004", "Storaro Green", .storaro, "#1FC438", 0.24),
            g(.rosco, "2005", "Storaro Cyan", .storaro, "#00B8D4", 0.28),
            g(.rosco, "2006", "Storaro Azure", .storaro, "#1478E0", 0.16),
            g(.rosco, "2007", "Storaro Blue", .storaro, "#0D38BF", 0.05),
            g(.rosco, "2008", "Storaro Indigo", .storaro, "#3D17A6", 0.03),
            g(.rosco, "2009", "Storaro Violet", .storaro, "#731FB8", 0.06),
            g(.rosco, "2010", "Storaro Magenta", .storaro, "#CC1985", 0.11),

            // =========================================================================
            // 9. Rosco CalColor Primary & Secondary Calibrated Series
            // =========================================================================
            g(.rosco, "4215", "CalColor 15 Blue", .calColor, "#CCE0FF", 0.68),
            g(.rosco, "4230", "CalColor 30 Blue", .calColor, "#99C2FF", 0.48),
            g(.rosco, "4260", "CalColor 60 Blue", .calColor, "#4D8FFF", 0.24),
            g(.rosco, "4290", "CalColor 90 Blue", .calColor, "#195CE6", 0.11),
            g(.rosco, "4315", "CalColor 15 Cyan", .calColor, "#CCF5FA", 0.74),
            g(.rosco, "4330", "CalColor 30 Cyan", .calColor, "#99EBF5", 0.58),
            g(.rosco, "4360", "CalColor 60 Cyan", .calColor, "#3BD6EB", 0.38),
            g(.rosco, "4390", "CalColor 90 Cyan", .calColor, "#00B8D4", 0.24),
            g(.rosco, "4415", "CalColor 15 Green", .calColor, "#D6FAD6", 0.78),
            g(.rosco, "4430", "CalColor 30 Green", .calColor, "#A8F0A8", 0.62),
            g(.rosco, "4460", "CalColor 60 Green", .calColor, "#57DB57", 0.42),
            g(.rosco, "4490", "CalColor 90 Green", .calColor, "#1FB829", 0.24),
            g(.rosco, "4515", "CalColor 15 Yellow", .calColor, "#FFFACC", 0.90),
            g(.rosco, "4530", "CalColor 30 Yellow", .calColor, "#FFF299", 0.86),
            g(.rosco, "4560", "CalColor 60 Yellow", .calColor, "#FFE64D", 0.82),
            g(.rosco, "4590", "CalColor 90 Yellow", .calColor, "#FFD919", 0.78),
            g(.rosco, "4615", "CalColor 15 Red", .calColor, "#FFCCCC", 0.68),
            g(.rosco, "4630", "CalColor 30 Red", .calColor, "#FF9999", 0.46),
            g(.rosco, "4660", "CalColor 60 Red", .calColor, "#FF4D4D", 0.24),
            g(.rosco, "4690", "CalColor 90 Red", .calColor, "#E61919", 0.13),
            g(.rosco, "4715", "CalColor 15 Magenta", .calColor, "#FFCCEB", 0.70),
            g(.rosco, "4730", "CalColor 30 Magenta", .calColor, "#FF99D6", 0.50),
            g(.rosco, "4760", "CalColor 60 Magenta", .calColor, "#F547B3", 0.27),
            g(.rosco, "4790", "CalColor 90 Magenta", .calColor, "#D9198F", 0.15),
            g(.rosco, "4815", "CalColor 15 Pink", .calColor, "#FFD4DD", 0.74),
            g(.rosco, "4830", "CalColor 30 Pink", .calColor, "#FFA8BA", 0.56),
            g(.rosco, "4860", "CalColor 60 Pink", .calColor, "#FF6182", 0.34),
            g(.rosco, "4890", "CalColor 90 Pink", .calColor, "#EB2952", 0.20),
            g(.rosco, "4915", "CalColor 15 Lavender", .calColor, "#E6D6FF", 0.70),
            g(.rosco, "4930", "CalColor 30 Lavender", .calColor, "#C7ADFF", 0.50),
            g(.rosco, "4960", "CalColor 60 Lavender", .calColor, "#9466F5", 0.26),
            g(.rosco, "4990", "CalColor 90 Lavender", .calColor, "#6B38DB", 0.14),

            // =========================================================================
            // 10. LEE Filters Theatrical, 600, 700 & Cosmetic Series
            // =========================================================================
            g(.lee, "002", "Rose Pink", .theatrical, "#FF599E", 0.35),
            g(.lee, "003", "Lavender Tint", .theatrical, "#EDE0FF", 0.78),
            g(.lee, "004", "Medium Bastard Amber", .theatrical, "#FFC49C", 0.73),
            g(.lee, "007", "Pale Yellow", .theatrical, "#FFF5B8", 0.89),
            g(.lee, "008", "Dark Salmon", .theatrical, "#FF7A61", 0.43),
            g(.lee, "009", "Pale Amber Gold", .theatrical, "#FFD494", 0.78),
            g(.lee, "010", "Medium Yellow", .theatrical, "#FFEB29", 0.85),
            g(.lee, "013", "Straw Tint", .theatrical, "#FFE8A6", 0.80),
            g(.lee, "015", "Deep Straw", .theatrical, "#FFC71A", 0.66),
            g(.lee, "017", "Surprise Peach", .theatrical, "#FF9E73", 0.52),
            g(.lee, "019", "Fire", .theatrical, "#FF4D1A", 0.21),
            g(.lee, "020", "Medium Amber", .theatrical, "#FFA329", 0.52),
            g(.lee, "021", "Gold Amber", .theatrical, "#FF8014", 0.40),
            g(.lee, "022", "Dark Amber", .theatrical, "#FF5E0D", 0.26),
            g(.lee, "024", "Scarlet", .theatrical, "#FF3B29", 0.20),
            g(.lee, "025", "Sunset Red", .theatrical, "#FF522E", 0.25),
            g(.lee, "026", "Bright Red", .theatrical, "#EB1224", 0.09),
            g(.lee, "027", "Medium Red", .theatrical, "#C90819", 0.04),
            g(.lee, "035", "Light Pink", .theatrical, "#FFC2D4", 0.70),
            g(.lee, "036", "Medium Pink", .theatrical, "#FF94B5", 0.54),
            g(.lee, "046", "Dark Magenta", .theatrical, "#C4126B", 0.08),
            g(.lee, "048", "Rose Purple", .theatrical, "#A83899", 0.15),
            g(.lee, "049", "Medium Purple", .theatrical, "#991F94", 0.09),
            g(.lee, "052", "Light Lavender", .theatrical, "#DEC2FF", 0.56),
            g(.lee, "053", "Paler Lavender", .theatrical, "#EDE0FF", 0.75),
            g(.lee, "058", "Lavender", .theatrical, "#9C61F2", 0.24),
            g(.lee, "061", "Mist Blue", .theatrical, "#D4EBFF", 0.68),
            g(.lee, "063", "Pale Blue", .theatrical, "#BDE0FF", 0.59),
            g(.lee, "068", "Sky Blue", .theatrical, "#2B94F0", 0.15),
            g(.lee, "071", "Tokyo Blue", .theatrical, "#051999", 0.01),
            g(.lee, "075", "Evening Blue", .theatrical, "#2457C7", 0.10),
            g(.lee, "079", "Just Blue", .theatrical, "#0F52DB", 0.07),
            g(.lee, "085", "Deeper Blue", .theatrical, "#0830AD", 0.03),
            g(.lee, "088", "Lime Green", .theatrical, "#C7F04D", 0.72),
            g(.lee, "089", "Moss Green", .theatrical, "#57C259", 0.36),
            g(.lee, "090", "Dark Yellow Green", .theatrical, "#1CA336", 0.13),
            g(.lee, "101", "Yellow", .theatrical, "#FFE81F", 0.82),
            g(.lee, "102", "Light Amber", .theatrical, "#FFCC59", 0.75),
            g(.lee, "103", "Straw", .theatrical, "#FFE89E", 0.82),
            g(.lee, "104", "Deep Amber", .theatrical, "#FFB524", 0.66),
            g(.lee, "105", "Orange", .theatrical, "#FF800F", 0.41),
            g(.lee, "106", "Primary Red", .theatrical, "#DE0D1C", 0.09),
            g(.lee, "107", "Light Rose", .theatrical, "#FFA3B8", 0.55),
            g(.lee, "108", "English Rose", .theatrical, "#FFA894", 0.57),
            g(.lee, "109", "Light Salmon", .theatrical, "#FF9985", 0.55),
            g(.lee, "110", "Middle Rose", .theatrical, "#FF80A8", 0.46),
            g(.lee, "111", "Dark Pink", .theatrical, "#FF5E94", 0.33),
            g(.lee, "113", "Magenta", .theatrical, "#DE1C6B", 0.12),
            g(.lee, "115", "Peacock Blue", .theatrical, "#00ADAD", 0.25),
            g(.lee, "116", "Medium Blue Green", .theatrical, "#009994", 0.17),
            g(.lee, "117", "Steel Blue", .theatrical, "#A3DEFF", 0.55),
            g(.lee, "118", "Light Blue", .theatrical, "#42B5EB", 0.25),
            g(.lee, "119", "Dark Blue", .theatrical, "#0A42C2", 0.04),
            g(.lee, "120", "Deep Blue", .theatrical, "#0829A6", 0.02),
            g(.lee, "121", "LEE Green", .theatrical, "#78E04D", 0.56),
            g(.lee, "122", "Fern Green", .theatrical, "#52D152", 0.45),
            g(.lee, "124", "Dark Green", .theatrical, "#19B347", 0.21),
            g(.lee, "126", "Mauve", .theatrical, "#9E2478", 0.08),
            g(.lee, "127", "Smokey Pink", .theatrical, "#C96E85", 0.28),
            g(.lee, "128", "Bright Pink", .theatrical, "#F5298C", 0.18),
            g(.lee, "130", "Clear", .theatrical, "#FFFFFF", 0.92),
            g(.lee, "131", "Marine Blue", .theatrical, "#57CFCC", 0.42),
            g(.lee, "132", "Medium Blue", .theatrical, "#0D69DB", 0.09),
            g(.lee, "134", "Golden Amber", .theatrical, "#FF9442", 0.48),
            g(.lee, "135", "Deep Golden Amber", .theatrical, "#FF610D", 0.22),
            g(.lee, "136", "Pale Lavender", .theatrical, "#E0C9F7", 0.64),
            g(.lee, "137", "Special Lavender", .theatrical, "#BA9EEB", 0.44),
            g(.lee, "138", "Pale Green", .theatrical, "#CFF7B0", 0.76),
            g(.lee, "139", "Primary Green", .theatrical, "#0F9424", 0.10),
            g(.lee, "140", "Summer Blue", .theatrical, "#85DBEB", 0.52),
            g(.lee, "141", "Bright Blue", .theatrical, "#1494E0", 0.19),
            g(.lee, "142", "Pale Violet", .theatrical, "#9E8CEB", 0.34),
            g(.lee, "147", "Apricot", .theatrical, "#FFA657", 0.55),
            g(.lee, "148", "Bright Rose", .theatrical, "#F22E73", 0.18),
            g(.lee, "151", "Gold Tint", .theatrical, "#FFCFB8", 0.76),
            g(.lee, "152", "Pale Gold", .theatrical, "#FFCCA3", 0.72),
            g(.lee, "153", "Pale Salmon", .theatrical, "#FFB5AB", 0.65),
            g(.lee, "154", "Pale Rose", .theatrical, "#FFC7BD", 0.72),
            g(.lee, "156", "Chocolate", .theatrical, "#BA8F70", 0.40),
            g(.lee, "157", "Pink", .theatrical, "#FF7394", 0.38),
            g(.lee, "158", "Deep Orange", .theatrical, "#FF6E0D", 0.31),
            g(.lee, "159", "No Color Straw", .theatrical, "#FFF7D6", 0.89),
            g(.lee, "161", "Slate Blue", .theatrical, "#6EAAD9", 0.32),
            g(.lee, "162", "Bastard Amber", .theatrical, "#FFD4B2", 0.79),
            g(.lee, "164", "Flame Red", .theatrical, "#F5291F", 0.14),
            g(.lee, "165", "Daylight Blue", .theatrical, "#61B8EB", 0.31),
            g(.lee, "170", "Deep Lavender", .theatrical, "#AD78DE", 0.31),
            g(.lee, "172", "Lagoon Blue", .theatrical, "#1FB8CC", 0.28),
            g(.lee, "174", "Dark Steel Blue", .theatrical, "#78ADD9", 0.36),
            g(.lee, "176", "Loving Amber", .theatrical, "#FFA378", 0.54),
            g(.lee, "179", "Chrome Orange", .theatrical, "#FF8F0A", 0.46),
            g(.lee, "180", "Dark Lavender", .theatrical, "#783BD4", 0.11),
            g(.lee, "181", "Congo Blue", .theatrical, "#2B087D", 0.01),
            g(.lee, "182", "Light Red", .theatrical, "#EB1924", 0.11),
            g(.lee, "183", "Moonlight Blue", .theatrical, "#198CE0", 0.17),
            g(.lee, "184", "Cosmetic Peach", .cosmetic, "#FFD9C4", 0.76),
            g(.lee, "186", "Cosmetic Silver Rose", .cosmetic, "#FAD4DF", 0.74),
            g(.lee, "187", "Cosmetic Rouge", .cosmetic, "#FCC7C2", 0.70),
            g(.lee, "188", "Cosmetic Highlight", .cosmetic, "#FFE3C9", 0.80),
            g(.lee, "189", "Cosmetic Silver Moss", .cosmetic, "#E6F5E0", 0.78),
            g(.lee, "191", "Cosmetic Aqua Blue", .cosmetic, "#D9F0FA", 0.76),
            g(.lee, "192", "Flesh Pink", .theatrical, "#FF789E", 0.42),
            g(.lee, "194", "Surprise Pink", .theatrical, "#C98FFF", 0.41),
            g(.lee, "195", "Zenith Blue", .theatrical, "#0F45C7", 0.05),
            g(.lee, "196", "True Blue", .theatrical, "#57A6E6", 0.29),
            g(.lee, "197", "Alice Blue", .theatrical, "#4A78D4", 0.16),
            g(.lee, "198", "Palace Blue", .theatrical, "#2447AD", 0.06),
            g(.lee, "199", "Regal Blue", .theatrical, "#1F30A6", 0.04),
            g(.lee, "600", "Arctic White", .colorCorrection, "#EEF5FF", 0.84, mired: -12),
            g(.lee, "601", "Silver", .theatrical, "#DCE6F2", 0.68),
            g(.lee, "602", "Platinum", .theatrical, "#D9D4E6", 0.65),
            g(.lee, "603", "Moonlight White", .theatrical, "#D4E8F5", 0.72),
            g(.lee, "642", "Half Mustard Yellow", .theatrical, "#DEC247", 0.52),
            g(.lee, "701", "Provence", .theatrical, "#7D38BA", 0.10),
            g(.lee, "702", "Special Pale Lavender", .theatrical, "#E3D1FA", 0.66),
            g(.lee, "704", "Lily", .theatrical, "#CFADF5", 0.49),
            g(.lee, "707", "Ultimate Violet", .theatrical, "#470D9E", 0.02),
            g(.lee, "711", "Cold Blue", .theatrical, "#8FB8EB", 0.38),
            g(.lee, "712", "Bedford Blue", .theatrical, "#7DA6DE", 0.34),
            g(.lee, "713", "J.Winter Blue", .theatrical, "#24429E", 0.05),
            g(.lee, "715", "Cabana Blue", .theatrical, "#2E66D4", 0.12),
            g(.lee, "716", "Mikkel Blue", .theatrical, "#1438AB", 0.04),
            g(.lee, "721", "Berry Blue", .theatrical, "#174FD4", 0.08),
            g(.lee, "722", "Bray Blue", .theatrical, "#1961C9", 0.11),
            g(.lee, "724", "Ocean Blue", .theatrical, "#2999D9", 0.24),
            g(.lee, "725", "Old Steel Blue", .theatrical, "#8CCFE6", 0.48),
            g(.lee, "728", "Steel Green", .theatrical, "#8AD4BA", 0.50),
            g(.lee, "730", "Liberty Green", .theatrical, "#A8E6BA", 0.62),
            g(.lee, "735", "Velvet Green", .theatrical, "#0F8C42", 0.11),
            g(.lee, "738", "JAS Green", .theatrical, "#4DD42E", 0.38),
            g(.lee, "742", "Bram Brown", .theatrical, "#9E6E47", 0.22),
            g(.lee, "744", "Dirty White", .colorCorrection, "#F5DEC2", 0.72, mired: 48, tint: -0.08),
            g(.lee, "746", "Brown", .theatrical, "#784D29", 0.10),
            g(.lee, "747", "Easy White", .colorCorrection, "#FAD9BD", 0.68, mired: 65),
            g(.lee, "763", "Wheat", .colorCorrection, "#FFEBB8", 0.82, mired: 30),
            g(.lee, "764", "Sun Colour Straw", .colorCorrection, "#FFE099", 0.76, mired: 45),
            g(.lee, "765", "LEE Yellow", .colorCorrection, "#FFD47A", 0.68, mired: 62),
            g(.lee, "777", "Rust", .theatrical, "#D95219", 0.20),
            g(.lee, "778", "Millennium Gold", .theatrical, "#FA7814", 0.34),
            g(.lee, "787", "Marius Red", .theatrical, "#B80A29", 0.04),
            g(.lee, "793", "Vanity Fair", .theatrical, "#EB2E94", 0.17),
            g(.lee, "795", "Magical Magenta", .theatrical, "#C91F8C", 0.12),
            g(.lee, "797", "Deep Purple", .theatrical, "#6B0F8C", 0.03),
            g(.lee, "798", "Chrysalis Pink", .theatrical, "#8C21AD", 0.07)
        ]
    }
    // swiftlint:enable function_body_length
}
