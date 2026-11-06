import Foundation

// MARK: - Real Light Source Presets

/// Category of real-world light source preset.
public enum LightSourceCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case incandescent = "Incandescent & Flame"
    case daylight = "Daylight & Sky"
    case discharge = "Arc & Discharge"
    case fluorescent = "Fluorescent & LED"
}

/// Real-world physical light source preset (cinema, architectural, natural, and discharge lamps)
/// with correlated color temperature, green/magenta tint (`-1` = full green / `+Duv`, `+1` = full magenta / `-Duv`),
/// and approximate CIE 1931 `(x, y)` chromaticity.
public struct LightSourcePreset: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var category: LightSourceCategory
    public var kelvin: Double
    /// Tint on `[-1, +1]`, where negative is Green (`+Duv`) and positive is Magenta (`-Duv`).
    public var tint: Double
    public var description: String

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        category: LightSourceCategory,
        kelvin: Double,
        tint: Double = 0,
        description: String = ""
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.category = category
        self.kelvin = clamp(kelvin.finiteOr(5600), 1700, 20000)
        self.tint = clamp(tint.finiteOr(0), -1, 1)
        self.description = description
    }

    /// Approximate Duv offset (`+` = green / above Planckian locus, `-` = magenta / below).
    public var duv: Double {
        ColorMath.tintToDuv(tint)
    }

    /// Aputure / Sidus Link G/M value (`-100...+100`, where `+` is Plus Green and `-` is Minus Green).
    public var sidusGM: Double {
        ColorMath.tintToSidusGM(tint)
    }

    /// CIE 1931 `(x, y)` chromaticity coordinates.
    public var xy: (x: Double, y: Double) {
        ColorMath.kelvinToXY(kelvin: kelvin, tint: tint)
    }

    /// Equivalent `LightColor` representation (`.kelvin(kelvin, tint: tint)`).
    public var lightColor: LightColor {
        .kelvin(kelvin, tint: tint)
    }

    /// Alias for `lightColor`.
    public var color: LightColor {
        lightColor
    }

    /// Display sRGB approximation.
    public var rgb: RGB {
        ColorMath.kelvinToRGB(kelvin: kelvin, tint: tint)
    }
}

public typealias RealSourcePreset = LightSourcePreset
public typealias SourcePreset = LightSourcePreset

// MARK: - Named Color Model

/// Category of named color entry.
public enum NamedColorCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case studio = "Studio & Stage"
    case white = "White & CCT"
    case realSource = "Real Sources"
    case css = "CSS & Standard"
}

/// A named color entry supporting both RGB swatches and Kelvin+tint white/source definitions.
public struct NamedColor: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var color: LightColor
    public var category: NamedColorCategory
    public var description: String?

    public init(
        id: String,
        name: String,
        aliases: [String] = [],
        color: LightColor,
        category: NamedColorCategory,
        description: String? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.color = color
        self.category = category
        self.description = description
    }

    /// Display sRGB approximation.
    public var rgb: RGB {
        color.sRGB
    }

    /// Uppercase `#RRGGBB` hex string.
    public var hex: String {
        color.hex
    }

    /// CIE 1931 `(x, y)` chromaticity.
    public var xy: (x: Double, y: Double) {
        color.xy
    }
}

// MARK: - NamedColors Catalog

/// Catalog of studio/stage swatches, white points, real-world light source presets, and all standard CSS named colors.
public enum NamedColors {

    /// Real-world light source presets (Tungsten, HMI, Candle, Sodium/Mercury vapor, Fluorescent, Daylight, etc.).
    public static let sourcePresets: [LightSourcePreset] = [
        LightSourcePreset(
            id: "candle",
            name: "Candle Flame",
            aliases: ["candle", "candlelight", "match", "flame", "firelight"],
            category: .incandescent,
            kelvin: 1900,
            tint: 0.0,
            description: "Open candle flame or firelight (1900 K)."
        ),
        LightSourcePreset(
            id: "sunrise-sunset",
            name: "Sunrise / Sunset",
            aliases: ["sunrise", "sunset", "dusk", "dawn"],
            category: .daylight,
            kelvin: 2000,
            tint: 0.05,
            description: "Low-angle horizon sun at sunrise or sunset (2000 K)."
        ),
        LightSourcePreset(
            id: "warm-dim-incandescent",
            name: "Household Tungsten (40W)",
            aliases: ["household bulb", "40w bulb", "dim tungsten", "practical bulb"],
            category: .incandescent,
            kelvin: 2650,
            tint: 0.0,
            description: "Domestic 40–60W incandescent practical lamp (2650 K)."
        ),
        LightSourcePreset(
            id: "warm-white-halogen",
            name: "Warm White / Domestic Halogen",
            aliases: ["warm white", "soft white", "halogen", "2700k"],
            category: .incandescent,
            kelvin: 2700,
            tint: 0.0,
            description: "Standard architectural warm white / domestic halogen (2700 K)."
        ),
        LightSourcePreset(
            id: "quartz-halogen",
            name: "Quartz Halogen (3000K)",
            aliases: ["quartz", "theatrical tungsten", "stage tungsten", "3000k"],
            category: .incandescent,
            kelvin: 3000,
            tint: 0.0,
            description: "Theatrical quartz-halogen stage fixture at full (3000 K)."
        ),
        LightSourcePreset(
            id: "tungsten",
            name: "Tungsten Studio (3200K)",
            aliases: ["tungsten", "studio tungsten", " tungsten 3200k", "3200k", "incandescent"],
            category: .incandescent,
            kelvin: 3200,
            tint: 0.0,
            description: "Motion-picture standard 3200 K tungsten halogen key light."
        ),
        LightSourcePreset(
            id: "studio-cp",
            name: "Studio CP Lamp (3350K)",
            aliases: ["cp lamp", "studio cp", "photoflood"],
            category: .incandescent,
            kelvin: 3350,
            tint: 0.0,
            description: "High-output studio CP / photoflood tungsten lamp (3350 K)."
        ),
        LightSourcePreset(
            id: "golden-hour",
            name: "Golden Hour",
            aliases: ["golden hour", "magic hour", "late afternoon sun"],
            category: .daylight,
            kelvin: 3500,
            tint: 0.0,
            description: "Warm golden-hour sunlight shortly after sunrise or before sunset (3500 K)."
        ),
        LightSourcePreset(
            id: "warm-fluorescent",
            name: "Warm White Fluorescent",
            aliases: ["warm fluorescent", "warm tube", "ww fluorescent"],
            category: .fluorescent,
            kelvin: 3000,
            tint: -0.25,
            description: "Warm-white office/commercial fluorescent tube with green spike (3000 K, +G)."
        ),
        LightSourcePreset(
            id: "cool-white-fluorescent",
            name: "Cool-White Fluorescent (+G)",
            aliases: ["cool-white fluorescent", "cool white fluorescent", "fluorescent", "office fluorescent", "cw fluorescent"],
            category: .fluorescent,
            kelvin: 4200,
            tint: -0.35,
            description: "Classic cool-white T8/T12 fluorescent tube with prominent green mercury spike (4200 K, +G)."
        ),
        LightSourcePreset(
            id: "daylight-fluorescent",
            name: "Daylight Fluorescent (+G)",
            aliases: ["daylight fluorescent", "hospital fluorescent", "supermarket fluorescent"],
            category: .fluorescent,
            kelvin: 5000,
            tint: -0.28,
            description: "5000 K commercial fluorescent tube with moderate green shift."
        ),
        LightSourcePreset(
            id: "sodium-vapor",
            name: "Sodium Vapor (Streetlight)",
            aliases: ["sodium vapor", "sodium", "hps", "high pressure sodium", "streetlight", "sodium lamp"],
            category: .discharge,
            kelvin: 2100,
            tint: 0.15,
            description: "High-pressure sodium vapor urban streetlight (2100 K amber-orange)."
        ),
        LightSourcePreset(
            id: "low-pressure-sodium",
            name: "Low-Pressure Sodium (SOX)",
            aliases: ["low pressure sodium", "lps", "sox", "monochromatic sodium"],
            category: .discharge,
            kelvin: 1800,
            tint: 0.20,
            description: "589 nm monochromatic low-pressure sodium tunnel/highway lamp (1800 K)."
        ),
        LightSourcePreset(
            id: "mercury-vapor",
            name: "Mercury Vapor",
            aliases: ["mercury vapor", "mercury", "mercury lamp", "industrial vapor"],
            category: .discharge,
            kelvin: 4100,
            tint: -0.45,
            description: "Industrial high-pressure mercury-vapor discharge lamp with strong cyan-green spike (4100 K, +G)."
        ),
        LightSourcePreset(
            id: "metal-halide",
            name: "Metal Halide (Stadium / Warehouse)",
            aliases: ["metal halide", "mh", "stadium light", "warehouse light"],
            category: .discharge,
            kelvin: 4300,
            tint: -0.18,
            description: "Commercial/stadium metal-halide HID lamp (4300 K, slight +G)."
        ),
        LightSourcePreset(
            id: "horizon-daylight",
            name: "Horizon Daylight (D50)",
            aliases: ["horizon daylight", "d50", "direct sun", "morning sun"],
            category: .daylight,
            kelvin: 5000,
            tint: 0.0,
            description: "CIE D50 horizon daylight / direct mid-morning sunlight (5000 K)."
        ),
        LightSourcePreset(
            id: "hmi",
            name: "HMI / Daylight Studio (5600K)",
            aliases: ["hmi", "daylight", "daylight 5600k", "5600k", "sunlight", "noon sun"],
            category: .discharge,
            kelvin: 5600,
            tint: 0.0,
            description: "Motion-picture standard 5600 K HMI / photographic daylight."
        ),
        LightSourcePreset(
            id: "xenon-arc",
            name: "Xenon Short-Arc",
            aliases: ["xenon", "xenon arc", "searchlight", "followspot"],
            category: .discharge,
            kelvin: 6200,
            tint: -0.04,
            description: "High-intensity xenon short-arc followspot / projector lamp (6200 K)."
        ),
        LightSourcePreset(
            id: "overcast",
            name: "Overcast Sky (6500K / D65)",
            aliases: ["overcast", "cloudy", "d65", "cool white", "6500k", "crt", "monitor white"],
            category: .daylight,
            kelvin: 6500,
            tint: 0.0,
            description: "CIE D65 overcast sky and sRGB reference white point (6500 K)."
        ),
        LightSourcePreset(
            id: "shade",
            name: "Open Shade (7500K)",
            aliases: ["shade", "open shade", "north light", "7500k"],
            category: .daylight,
            kelvin: 7500,
            tint: 0.0,
            description: "Outdoor open shade illuminated by skylight away from direct sun (7500 K)."
        ),
        LightSourcePreset(
            id: "moonlight",
            name: "Moonlight (8000K)",
            aliases: ["moonlight", "moon", "night", "night exterior"],
            category: .daylight,
            kelvin: 8000,
            tint: 0.0,
            description: "Cinema night-exterior moonlight convention (8000 K cool blue-white)."
        ),
        LightSourcePreset(
            id: "blue-sky",
            name: "Clear North Blue Sky (10000K)",
            aliases: ["blue sky", "north sky", "clear sky", "10000k", "blue hour"],
            category: .daylight,
            kelvin: 10000,
            tint: 0.0,
            description: "Deep blue zenith sky / twilight blue hour (10000 K)."
        )
    ]

    /// Alias for `sourcePresets`.
    public static var realSources: [LightSourcePreset] { sourcePresets }

    /// Curated studio and stage color swatches (aligned with `DemoRig.Swatch` and film/stage conventions).
    public static let studioSwatches: [NamedColor] = [
        NamedColor(id: "studio-teal", name: "Teal", aliases: ["studio teal", "cyber teal", "aqua teal"], color: .rgb(RGB(r: 0.0, g: 194.0 / 255.0, b: 168.0 / 255.0)), category: .studio, description: "Cinema teal accent (#00C2A8), ideal complement to warm tungsten skin tones."),
        NamedColor(id: "studio-cyan", name: "Cyan", aliases: ["studio cyan", "electric cyan"], color: .rgb(RGB(r: 20.0 / 255.0, g: 216.0 / 255.0, b: 240.0 / 255.0)), category: .studio, description: "High-punch studio cyan (#14D8F0)."),
        NamedColor(id: "studio-pink", name: "Neon Pink", aliases: ["studio pink", "hot neon pink", "neon magenta"], color: .rgb(RGB(r: 1.0, g: 47.0 / 255.0, b: 180.0 / 255.0)), category: .studio, description: "Vibrant studio pink/magenta (#FF2FB4)."),
        NamedColor(id: "studio-magenta", name: "Magenta", aliases: ["primary magenta", "fuchsia"], color: .rgb(RGB(r: 1.0, g: 0.0, b: 1.0)), category: .studio, description: "Full saturated magenta (#FF00FF)."),
        NamedColor(id: "studio-blue", name: "Studio Blue", aliases: ["primary blue"], color: .rgb(RGB(r: 31.0 / 255.0, g: 75.0 / 255.0, b: 1.0)), category: .studio, description: "Rich stage wash blue (#1F4BFF)."),
        NamedColor(id: "studio-deep-blue", name: "Deep Blue", aliases: ["congo", "royal wash"], color: .rgb(RGB(r: 10.0 / 255.0, g: 42.0 / 255.0, b: 1.0)), category: .studio, description: "Deep saturated backlight blue (#0A2AFF)."),
        NamedColor(id: "studio-orange", name: "Amber Orange", aliases: ["studio orange", "warm amber", "sodium orange"], color: .rgb(RGB(r: 1.0, g: 122.0 / 255.0, b: 26.0 / 255.0)), category: .studio, description: "Warm amber-orange accent (#FF7A1A)."),
        NamedColor(id: "studio-amber", name: "Amber", aliases: ["bastard amber", "gold amber", "warm gold"], color: .rgb(RGB(r: 1.0, g: 0.75, b: 0.0)), category: .studio, description: "Classic theatrical amber (#FFBF00)."),
        NamedColor(id: "studio-salmon", name: "Salmon", aliases: ["warm peach", "skin key"], color: .rgb(RGB(r: 1.0, g: 140.0 / 255.0, b: 122.0 / 255.0)), category: .studio, description: "Soft flattering salmon/peach fill (#FF8C7A)."),
        NamedColor(id: "studio-green", name: "Neon Green", aliases: ["studio green", "laser green", "chroma green"], color: .rgb(RGB(r: 0.0, g: 1.0, b: 60.0 / 255.0)), category: .studio, description: "Vibrant saturated green (#00FF3C)."),
        NamedColor(id: "studio-lime", name: "Lime", aliases: ["chartreuse", "acid lime"], color: .rgb(RGB(r: 0.72, g: 1.0, b: 0.12)), category: .studio, description: "High-lumen yellow-green lime (#B8FF1F)."),
        NamedColor(id: "studio-uv", name: "UV / Indigo", aliases: ["uv", "ultraviolet", "blacklight", "congo blue"], color: .rgb(RGB(r: 0.29, g: 0.0, b: 0.82)), category: .studio, description: "Deep ultraviolet / Congo Blue stage wash (#4A00D1)."),
        NamedColor(id: "studio-steel-blue", name: "Steel Blue", aliases: ["steel", "cool moonlight"], color: .rgb(RGB(r: 0.65, g: 0.86, b: 1.0)), category: .studio, description: "Crisp theatrical steel blue (#A6DCFF)."),
        NamedColor(id: "studio-surprise-pink", name: "Surprise Pink", aliases: ["special lavender", "theatrical lavender"], color: .rgb(RGB(r: 0.84, g: 0.72, b: 1.0)), category: .studio, description: "Classic flattering theatrical lavender-pink (#D6B8FF).")
    ]

    /// Named white & CCT presets.
    public static let whitePresets: [NamedColor] = [
        NamedColor(id: "white-candle", name: "Candle (1900K)", aliases: ["candle", "candlelight", "1900k"], color: .kelvin(1900), category: .white, description: "1900 K candle flame white."),
        NamedColor(id: "white-sunset", name: "Sunset (2000K)", aliases: ["sunset", "sunrise", "2000k"], color: .kelvin(2000, tint: 0.05), category: .white, description: "2000 K horizon sunset white."),
        NamedColor(id: "white-warm", name: "Warm White (2700K)", aliases: ["warm white", "warm", "soft white", "2700k"], color: .kelvin(2700), category: .white, description: "2700 K domestic warm white."),
        NamedColor(id: "white-halogen", name: "Quartz Halogen (3000K)", aliases: ["halogen", "quartz", "3000k"], color: .kelvin(3000), category: .white, description: "3000 K theatrical halogen white."),
        NamedColor(id: "white-tungsten", name: "Tungsten (3200K)", aliases: ["tungsten", "tungsten white", "3200k", "incandescent"], color: .kelvin(3200), category: .white, description: "3200 K cinema tungsten balance."),
        NamedColor(id: "white-golden-hour", name: "Golden Hour (3500K)", aliases: ["golden hour", "magic hour", "3500k"], color: .kelvin(3500), category: .white, description: "3500 K golden-hour sunlight."),
        NamedColor(id: "white-neutral", name: "Neutral White (4000K)", aliases: ["neutral white", "neutral", "natural white", "4000k", "4300k"], color: .kelvin(4000), category: .white, description: "4000 K neutral architectural white."),
        NamedColor(id: "white-horizon", name: "Horizon Daylight (5000K)", aliases: ["horizon", "d50", "5000k"], color: .kelvin(5000), category: .white, description: "5000 K D50 horizon daylight."),
        NamedColor(id: "white-daylight", name: "Daylight / HMI (5600K)", aliases: ["daylight", "hmi", "day white", "sunlight", "5600k", "white"], color: .kelvin(5600), category: .white, description: "5600 K cinema daylight / HMI balance."),
        NamedColor(id: "white-overcast", name: "Overcast / Cool White (6500K)", aliases: ["overcast", "cool white", "cool", "cloudy", "d65", "6500k"], color: .kelvin(6500), category: .white, description: "6500 K D65 overcast / cool white."),
        NamedColor(id: "white-shade", name: "Open Shade (7500K)", aliases: ["shade", "open shade", "7500k"], color: .kelvin(7500), category: .white, description: "7500 K open shade sky light."),
        NamedColor(id: "white-moonlight", name: "Moonlight (8000K)", aliases: ["moonlight", "moon", "8000k"], color: .kelvin(8000), category: .white, description: "8000 K cinema moonlight white."),
        NamedColor(id: "white-blue-sky", name: "Blue Sky (10000K)", aliases: ["blue sky", "north sky", "blue hour", "10000k"], color: .kelvin(10000), category: .white, description: "10000 K clear blue north sky.")
    ]

    /// Real-source presets exposed as `NamedColor` entries.
    public static let realSourceColors: [NamedColor] = sourcePresets.map { preset in
        NamedColor(
            id: "source-\(preset.id)",
            name: preset.name,
            aliases: preset.aliases,
            color: preset.lightColor,
            category: .realSource,
            description: preset.description
        )
    }

    /// Standard CSS Color Module Level 4 named colors.
    public static let cssColors: [NamedColor] = {
        let raw: [(String, Int, Int, Int)] = [
            ("aliceblue", 240, 248, 255),
            ("antiquewhite", 250, 235, 215),
            ("aqua", 0, 255, 255),
            ("aquamarine", 127, 255, 212),
            ("azure", 240, 255, 255),
            ("beige", 245, 245, 220),
            ("bisque", 255, 228, 196),
            ("black", 0, 0, 0),
            ("blanchedalmond", 255, 235, 205),
            ("blue", 0, 0, 255),
            ("blueviolet", 138, 43, 226),
            ("brown", 165, 42, 42),
            ("burlywood", 222, 184, 135),
            ("cadetblue", 95, 158, 160),
            ("chartreuse", 127, 255, 0),
            ("chocolate", 210, 105, 30),
            ("coral", 255, 127, 80),
            ("cornflowerblue", 100, 149, 237),
            ("cornsilk", 255, 248, 220),
            ("crimson", 220, 20, 60),
            ("cyan", 0, 255, 255),
            ("darkblue", 0, 0, 139),
            ("darkcyan", 0, 139, 139),
            ("darkgoldenrod", 184, 134, 11),
            ("darkgray", 169, 169, 169),
            ("darkgreen", 0, 100, 0),
            ("darkgrey", 169, 169, 169),
            ("darkkhaki", 189, 183, 107),
            ("darkmagenta", 139, 0, 139),
            ("darkolivegreen", 85, 107, 47),
            ("darkorange", 255, 140, 0),
            ("darkorchid", 153, 50, 204),
            ("darkred", 139, 0, 0),
            ("darksalmon", 233, 150, 122),
            ("darkseagreen", 143, 188, 143),
            ("darkslateblue", 72, 61, 139),
            ("darkslategray", 47, 79, 79),
            ("darkslategrey", 47, 79, 79),
            ("darkturquoise", 0, 206, 209),
            ("darkviolet", 148, 0, 211),
            ("deeppink", 255, 20, 147),
            ("deepskyblue", 0, 191, 255),
            ("dimgray", 105, 105, 105),
            ("dimgrey", 105, 105, 105),
            ("dodgerblue", 30, 144, 255),
            ("firebrick", 178, 34, 34),
            ("floralwhite", 255, 250, 240),
            ("forestgreen", 34, 139, 34),
            ("fuchsia", 255, 0, 255),
            ("gainsboro", 220, 220, 220),
            ("ghostwhite", 248, 248, 255),
            ("gold", 255, 215, 0),
            ("goldenrod", 218, 165, 32),
            ("gray", 128, 128, 128),
            ("green", 0, 255, 0),
            ("greenyellow", 173, 255, 47),
            ("grey", 128, 128, 128),
            ("honeydew", 240, 255, 240),
            ("hotpink", 255, 105, 180),
            ("indianred", 205, 92, 92),
            ("indigo", 75, 0, 130),
            ("ivory", 255, 255, 240),
            ("khaki", 240, 230, 140),
            ("lavender", 230, 230, 250),
            ("lavenderblush", 255, 240, 245),
            ("lawngreen", 124, 252, 0),
            ("lemonchiffon", 255, 250, 205),
            ("lightblue", 173, 216, 230),
            ("lightcoral", 240, 128, 128),
            ("lightcyan", 224, 255, 255),
            ("lightgoldenrodyellow", 250, 250, 210),
            ("lightgray", 211, 211, 211),
            ("lightgreen", 144, 238, 144),
            ("lightgrey", 211, 211, 211),
            ("lightpink", 255, 182, 193),
            ("lightsalmon", 255, 160, 122),
            ("lightseagreen", 32, 178, 170),
            ("lightskyblue", 135, 206, 250),
            ("lightslategray", 119, 136, 153),
            ("lightslategrey", 119, 136, 153),
            ("lightsteelblue", 176, 196, 222),
            ("lightyellow", 255, 255, 224),
            ("lime", 0, 255, 0),
            ("limegreen", 50, 205, 50),
            ("linen", 250, 240, 230),
            ("magenta", 255, 0, 255),
            ("maroon", 128, 0, 0),
            ("mediumaquamarine", 102, 205, 170),
            ("mediumblue", 0, 0, 205),
            ("mediumorchid", 186, 85, 211),
            ("mediumpurple", 147, 112, 219),
            ("mediumseagreen", 60, 179, 113),
            ("mediumslateblue", 123, 104, 238),
            ("mediumspringgreen", 0, 250, 154),
            ("mediumturquoise", 72, 209, 204),
            ("mediumvioletred", 199, 21, 133),
            ("midnightblue", 25, 25, 112),
            ("mintcream", 245, 255, 250),
            ("mistyrose", 255, 228, 225),
            ("moccasin", 255, 228, 181),
            ("navajowhite", 255, 222, 173),
            ("navy", 0, 0, 128),
            ("oldlace", 253, 245, 230),
            ("olive", 128, 128, 0),
            ("olivedrab", 107, 142, 35),
            ("orange", 255, 165, 0),
            ("orangered", 255, 69, 0),
            ("orchid", 218, 112, 214),
            ("palegoldenrod", 238, 232, 170),
            ("palegreen", 152, 251, 152),
            ("paleturquoise", 175, 238, 238),
            ("palevioletred", 219, 112, 147),
            ("papayawhip", 255, 239, 213),
            ("peachpuff", 255, 218, 185),
            ("peru", 205, 133, 63),
            ("pink", 255, 192, 203),
            ("plum", 221, 160, 221),
            ("powderblue", 176, 224, 230),
            ("purple", 160, 32, 240),
            ("rebeccapurple", 102, 51, 153),
            ("red", 255, 0, 0),
            ("rosybrown", 188, 143, 143),
            ("royalblue", 65, 105, 225),
            ("saddlebrown", 139, 69, 19),
            ("salmon", 250, 128, 114),
            ("sandybrown", 244, 164, 96),
            ("seagreen", 46, 139, 87),
            ("seashell", 255, 245, 238),
            ("sienna", 160, 82, 45),
            ("silver", 192, 192, 192),
            ("skyblue", 135, 206, 235),
            ("slateblue", 106, 90, 205),
            ("slategray", 112, 128, 144),
            ("slategrey", 112, 128, 144),
            ("snow", 255, 250, 250),
            ("springgreen", 0, 255, 127),
            ("steelblue", 70, 130, 180),
            ("tan", 210, 180, 140),
            ("teal", 0, 194, 168),
            ("thistle", 216, 191, 216),
            ("tomato", 255, 99, 71),
            ("turquoise", 64, 224, 208),
            ("violet", 238, 130, 238),
            ("wheat", 245, 222, 179),
            ("white", 255, 255, 255),
            ("whitesmoke", 245, 245, 245),
            ("yellow", 255, 255, 0),
            ("yellowgreen", 154, 205, 50)
        ]

        return raw.map { name, r, g, b in
            NamedColor(
                id: "css-\(name)",
                name: name.capitalized,
                aliases: [name],
                color: .rgb(RGB(r: Double(r) / 255.0, g: Double(g) / 255.0, b: Double(b) / 255.0)),
                category: .css
            )
        }
    }()

    /// All named colors across studio swatches, white presets, real-world sources, and CSS colors.
    public static let all: [NamedColor] = studioSwatches + whitePresets + realSourceColors + cssColors

    // MARK: - Fast Lookup Tables

    private static let normalizedColorTable: [String: NamedColor] = {
        var map: [String: NamedColor] = [:]
        // Insert CSS first, then real sources, then white presets, then studio swatches so studio/white take priority on collisions.
        for entry in cssColors {
            map[normalizeKey(entry.name)] = entry
            for alias in entry.aliases {
                map[normalizeKey(alias)] = entry
            }
        }
        for entry in realSourceColors {
            map[normalizeKey(entry.name)] = entry
            for alias in entry.aliases {
                map[normalizeKey(alias)] = entry
            }
        }
        for entry in whitePresets {
            map[normalizeKey(entry.name)] = entry
            for alias in entry.aliases {
                map[normalizeKey(alias)] = entry
            }
        }
        for entry in studioSwatches {
            map[normalizeKey(entry.name)] = entry
            for alias in entry.aliases {
                map[normalizeKey(alias)] = entry
            }
        }
        return map
    }()

    private static let normalizedSourceTable: [String: LightSourcePreset] = {
        var map: [String: LightSourcePreset] = [:]
        for preset in sourcePresets {
            map[normalizeKey(preset.id)] = preset
            map[normalizeKey(preset.name)] = preset
            for alias in preset.aliases {
                map[normalizeKey(alias)] = preset
            }
        }
        return map
    }()

    // MARK: - Lookup API

    /// Looks up a `NamedColor` by name or alias (case-insensitive, whitespace/punctuation tolerant).
    public static func lookup(_ query: String) -> NamedColor? {
        let key = normalizeKey(query)
        guard !key.isEmpty else { return nil }
        if let exact = normalizedColorTable[key] {
            return exact
        }
        // Try matching without trailing "light" or "color"
        for suffix in ["light", "color", "gel", "wash"] {
            if key.hasSuffix(suffix) {
                let stripped = String(key.dropLast(suffix.count))
                if let match = normalizedColorTable[stripped] {
                    return match
                }
            }
        }
        return nil
    }

    /// Alias for `lookup(_:)`.
    public static func find(_ query: String) -> NamedColor? {
        lookup(query)
    }

    /// Looks up a real-world `LightSourcePreset` by name, ID, or alias.
    public static func sourcePreset(named query: String) -> LightSourcePreset? {
        let key = normalizeKey(query)
        guard !key.isEmpty else { return nil }
        if let exact = normalizedSourceTable[key] {
            return exact
        }
        return sourcePresets.first { preset in
            normalizeKey(preset.name).contains(key) ||
            preset.aliases.contains(where: { normalizeKey($0).contains(key) })
        }
    }

    /// Resolves a string query into a `LightColor`.
    /// Accepts:
    /// - Named studio colors, white points, real-world sources, and CSS colors (`"teal"`, `"tungsten"`, `"sodium vapor"`, `"warm white"`, `"magenta"`, etc.)
    /// - Hex strings (`"#FF00AA"`, `"FF00AA"`) and CSS `rgb(r,g,b)` strings
    /// - Kelvin strings (`"3200K"`, `"5600 K"`)
    /// - Gel codes and names (`"R02"`, `"L201"`, `"Full CTO"`, `"1/2 CTB"`, `"Plus Green"`, `"Congo Blue"`)
    public static func resolve(_ query: String) -> LightColor? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 1. Named color / preset table
        if let named = lookup(trimmed) {
            return named.color
        }

        // 2. Real light source preset
        if let source = normalizedSourceTable[normalizeKey(trimmed)] {
            return source.lightColor
        }

        // 3. Explicit Kelvin string (e.g. "3200K", "5600 k")
        if let k = parseKelvinLiteral(trimmed) {
            return .kelvin(k)
        }

        // 4. Hex or rgb(...) literal
        if trimmed.hasPrefix("#") || trimmed.lowercased().hasPrefix("rgb") || isLikelyHexLiteral(trimmed) {
            if let rgb = RGB(hex: trimmed) {
                return .rgb(rgb)
            }
        }

        // 5. Gel library fallback (e.g. "Full CTO", "1/2 CTB", "R02", "L201", "Bastard Amber")
        if let gel = GelLibrary.gel(named: trimmed) {
            return gel.lightColor
        }

        return nil
    }

    /// Alias for `resolve(_:)`.
    public static func color(named query: String) -> LightColor? {
        resolve(query)
    }

    /// Resolves a query string directly to an `RGB` value.
    public static func rgb(named query: String) -> RGB? {
        resolve(query)?.sRGB
    }

    /// Searches named colors by substring across name, aliases, category, and description.
    public static func search(_ query: String, limit: Int = 25) -> [NamedColor] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            return Array((studioSwatches + whitePresets + realSourceColors).prefix(max(1, limit)))
        }
        let norm = normalizeKey(trimmed)
        var scored: [(score: Int, color: NamedColor)] = []
        for entry in all {
            let entryNorm = normalizeKey(entry.name)
            var bestScore = 0
            if entryNorm == norm {
                bestScore = 100
            } else if entry.aliases.contains(where: { normalizeKey($0) == norm }) {
                bestScore = 95
            } else if entryNorm.hasPrefix(norm) {
                bestScore = 80
            } else if entry.aliases.contains(where: { normalizeKey($0).hasPrefix(norm) }) {
                bestScore = 75
            } else if entryNorm.contains(norm) {
                bestScore = 60
            } else if entry.aliases.contains(where: { normalizeKey($0).contains(norm) }) {
                bestScore = 50
            } else if let desc = entry.description?.lowercased(), desc.contains(trimmed) {
                bestScore = 30
            }
            if bestScore > 0 {
                // Slight boost for studio/white/realSource over generic CSS
                if entry.category != .css {
                    bestScore += 3
                }
                scored.append((bestScore, entry))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.color.name < b.color.name
        }
        return Array(scored.prefix(max(1, limit)).map(\.color))
    }

    /// Finds the perceptually closest `NamedColor` to a given `LightColor` using ΔE OKLab.
    public static func closest(to color: LightColor, includeCSS: Bool = true) -> NamedColor {
        let pool = includeCSS ? all : (studioSwatches + whitePresets + realSourceColors)
        let targetRGB = color.sRGB
        var best = studioSwatches[0]
        var bestDist = Double.greatestFiniteMagnitude
        for candidate in pool {
            let d = ColorMath.deltaEOKLab(targetRGB, candidate.rgb)
            if d < bestDist {
                bestDist = d
                best = candidate
            }
        }
        return best
    }

    /// Returns the human-readable name of the closest `NamedColor` to `color`.
    public static func closestName(to color: LightColor) -> String {
        closest(to: color).name
    }

    // MARK: - Helpers

    private static func normalizeKey(_ s: String) -> String {
        s.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "+" || $0 == "-" }
    }

    private static func parseKelvinLiteral(_ s: String) -> Double? {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard lower.hasSuffix("k") else { return nil }
        let numberPart = lower.dropLast().trimmingCharacters(in: .whitespaces)
        guard let value = Double(numberPart), value >= 1000, value <= 30000 else { return nil }
        return clamp(value, 1700, 20000)
    }

    private static func isLikelyHexLiteral(_ s: String) -> Bool {
        let count = s.count
        guard count == 6 || count == 8 else { return false }
        return s.allSatisfy(\.isHexDigit)
    }
}
