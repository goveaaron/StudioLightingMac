import Foundation

// MARK: - Fixture library schema
//
// A FixtureDefinition describes a *model* of light (e.g. "amaran PT4c") and all of its DMX
// modes. Definitions are loaded from JSON (Resources/FixtureLibrary) and are embedded into
// project files so a project opens on any Mac, even without the library entry.
//
// JSON authoring format (see docs/FIXTURE_SCHEMA.md):
// {
//   "id": "amaran.pt4c", "manufacturer": "amaran", "model": "PT4c", "category": "tube",
//   "cctRange": [2500, 7500], "physical": {"lengthMM": 1200},
//   "modes": [{
//      "name": "CCT&RGB", "recommended": true, "summary": "Full color + white balance",
//      "channels": [{"kind":"intensity"}, {"kind":"cct","physical":[2500,7500]}, ...],
//      "pixels": {"count": 16, "channels": [{"kind":"red"},{"kind":"green"},{"kind":"blue"}]}
//   }]
// }

public enum FixtureCategory: String, Codable, CaseIterable, Sendable {
    case tube, panel, spot, fresnel, par, bulb, strip, bar, wash, movingHead, dimmer, effect, other

    public var displayName: String {
        switch self {
        case .tube: return "Tube"
        case .panel: return "Panel"
        case .spot: return "Spot / COB"
        case .fresnel: return "Fresnel"
        case .par: return "PAR"
        case .bulb: return "Bulb"
        case .strip: return "LED Strip"
        case .bar: return "Bar / Batten"
        case .wash: return "Wash"
        case .movingHead: return "Moving Head"
        case .dimmer: return "Dimmer"
        case .effect: return "Effect"
        case .other: return "Other"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "cob" { self = .spot; return }
        self = FixtureCategory(rawValue: raw) ?? .other
    }
}

/// Semantic meaning of a DMX channel. Renderers look at kinds, never at channel names.
public enum ChannelKind: String, Codable, CaseIterable, Sendable {
    // Intensity
    case intensity
    // Color emitters
    case red, green, blue, white, warmWhite, coolWhite, amber, lime, cyan, magenta, yellow, uv, indigo
    // White / color models
    case cct            // color temperature, use `physical` for Kelvin mapping
    case tint           // green/magenta, use `physical` mapping where -1 = minus green (magenta), +1 = plus green
    case hue            // physical degrees
    case saturation     // physical 0...1 (or %)
    case cieX, cieY     // physical 0...1 chromaticity
    case crossfade      // blend between native white (CCT, physical 0) and color (RGB/HSI, physical 1)
    case colorMode      // mode-select channel; see capability tags ("cct", "hsi", "rgb", "xy", "gel", "effect")
    case colorMacro     // color presets / wheel
    case gel            // gel selection
    // Beam / shutter
    case strobe
    case shutter
    // Effects
    case effect
    case effectSpeed
    case effectParameter
    // Movement & optics
    case pan, tilt, zoom, focus, gobo, prism, iris
    // Misc
    case fan
    case control        // reset, lamp control, dimmer curve, etc.
    case dimmerCurve
    case generic
    case nothing        // reserved / no function

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChannelKind.parse(raw)
    }

    /// Parses a channel kind string, mapping `prism-fixture/1` aliases and `<kind>Fine` names.
    public static func parse(_ raw: String) -> ChannelKind {
        let base = raw.hasSuffix("Fine") ? String(raw.dropLast(4)) : raw
        if let k = ChannelKind(rawValue: base) { return k }
        switch base {
        case "none", "reserved": return .nothing
        case "colorWheel": return .colorMacro
        case "goboRotation": return .gobo
        case "prismRotation": return .prism
        case "panTiltSpeed", "speed", "rotation": return .effectSpeed
        case "frost", "blade", "fog": return .generic
        default: return .generic
        }
    }

    /// Kinds that represent an emitter color (participate in color mixing).
    public var isEmitter: Bool {
        switch self {
        case .red, .green, .blue, .white, .warmWhite, .coolWhite, .amber, .lime, .cyan, .magenta, .yellow, .uv, .indigo:
            return true
        default:
            return false
        }
    }

    /// Kinds a fixture (or one pixel cell) has at most once per mode: a second coarse channel of
    /// the same kind and cell would overlap the first. Service kinds (generic, effect, control,
    /// reserved...) may legitimately repeat.
    public var isUniqueRole: Bool {
        switch self {
        case .intensity, .cct, .tint, .hue, .saturation, .cieX, .cieY, .crossfade, .pan, .tilt, .zoom, .focus, .iris:
            return true
        default:
            return isEmitter
        }
    }

    /// True if this channel kind is an advanced/service channel by default.
    public var isAdvancedByDefault: Bool {
        switch self {
        case .effect, .effectSpeed, .effectParameter, .control, .dimmerCurve, .fan, .nothing:
            return true
        default:
            return false
        }
    }
}

/// Photometric chromaticity (CIE 1931 xy) and relative luminous output for a single LED emitter.
/// Used by `EmitterMixer` to solve for accurate multi-emitter color reproduction.
public struct EmitterSpec: Codable, Hashable, Sendable {
    /// CIE 1931 chromaticity x coordinate (typically 0.0…0.8).
    public var x: Double
    /// CIE 1931 chromaticity y coordinate (typically 0.0…0.8).
    public var y: Double
    /// Relative luminous flux (Y weight, default 1.0) at 100% drive.
    public var lumens: Double
    /// Nominal correlated color temperature in Kelvin (for white emitters).
    public var cctKelvin: Double?
    /// Nominal dominant wavelength in nanometers (for narrowband emitters).
    public var wavelengthNM: Double?

    public var relativeLumens: Double {
        get { lumens }
        set { lumens = newValue }
    }

    public var xy: (x: Double, y: Double) { (x, y) }

    public init(x: Double, y: Double, lumens: Double = 1.0, cctKelvin: Double? = nil, wavelengthNM: Double? = nil) {
        self.x = x; self.y = y; self.lumens = lumens
        self.cctKelvin = cctKelvin; self.wavelengthNM = wavelengthNM
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, xy, lumens, relativeLumens, cctKelvin = "cct", wavelengthNM = "wavelength"
    }

    public init(from decoder: Decoder) throws {
        if var arr = try? decoder.unkeyedContainer() {
            x = (try? arr.decode(Double.self)) ?? 0.33
            y = (try? arr.decode(Double.self)) ?? 0.33
            lumens = (try? arr.decode(Double.self)) ?? 1.0
            cctKelvin = nil
            wavelengthNM = nil
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let pair = try c.decodeIfPresent([Double].self, forKey: .xy), pair.count >= 2 {
            x = pair[0]
            y = pair[1]
        } else {
            x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.33
            y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.33
        }
        lumens = try c.decodeIfPresent(Double.self, forKey: .lumens)
            ?? (try c.decodeIfPresent(Double.self, forKey: .relativeLumens))
            ?? 1.0
        cctKelvin = try c.decodeIfPresent(Double.self, forKey: .cctKelvin)
        wavelengthNM = try c.decodeIfPresent(Double.self, forKey: .wavelengthNM)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        if lumens != 1.0 { try c.encode(lumens, forKey: .lumens) }
        try c.encodeIfPresent(cctKelvin, forKey: .cctKelvin)
        try c.encodeIfPresent(wavelengthNM, forKey: .wavelengthNM)
    }

    /// Standard LED emitter chromaticity and relative lumen defaults when a fixture does not specify custom measurements.
    public static func standard(for kind: ChannelKind) -> EmitterSpec? {
        switch kind {
        case .red:       return EmitterSpec(x: 0.690, y: 0.308, lumens: 0.25, wavelengthNM: 625)
        case .green:     return EmitterSpec(x: 0.170, y: 0.715, lumens: 0.65, wavelengthNM: 525)
        case .blue:      return EmitterSpec(x: 0.140, y: 0.045, lumens: 0.10, wavelengthNM: 460)
        case .white:     return EmitterSpec(x: 0.330, y: 0.340, lumens: 1.00, cctKelvin: 5600)
        case .warmWhite: return EmitterSpec(x: 0.460, y: 0.411, lumens: 0.90, cctKelvin: 2700)
        case .coolWhite: return EmitterSpec(x: 0.313, y: 0.329, lumens: 1.00, cctKelvin: 6500)
        case .amber:     return EmitterSpec(x: 0.580, y: 0.415, lumens: 0.55, wavelengthNM: 590)
        case .lime:      return EmitterSpec(x: 0.380, y: 0.560, lumens: 1.10, wavelengthNM: 555)
        case .cyan:      return EmitterSpec(x: 0.080, y: 0.480, lumens: 0.45, wavelengthNM: 500)
        case .magenta:   return EmitterSpec(x: 0.380, y: 0.180, lumens: 0.35)
        case .yellow:    return EmitterSpec(x: 0.460, y: 0.520, lumens: 0.80, wavelengthNM: 580)
        case .uv:        return EmitterSpec(x: 0.170, y: 0.015, lumens: 0.03, wavelengthNM: 395)
        case .indigo:    return EmitterSpec(x: 0.155, y: 0.025, lumens: 0.06, wavelengthNM: 440)
        default:         return nil
        }
    }
}

/// Linear mapping between DMX values and a physical quantity (Kelvin, degrees, -1…1 tint…).
public struct PhysicalRange: Codable, Hashable, Sendable {
    /// Physical value at `dmxFrom`.
    public var from: Double
    /// Physical value at `dmxTo`.
    public var to: Double
    /// DMX range (coarse 0…255 units) over which the mapping applies.
    public var dmxFrom: Int
    public var dmxTo: Int
    public var unit: String?

    public init(from: Double, to: Double, dmxFrom: Int = 0, dmxTo: Int = 255, unit: String? = nil) {
        self.from = from; self.to = to; self.dmxFrom = dmxFrom; self.dmxTo = dmxTo; self.unit = unit
    }

    /// Fraction (0…1 across the DMX range) for a physical value, clamped.
    public func fraction(for physicalValue: Double) -> Double {
        guard to != from else { return 0 }
        return clamp01((physicalValue - from) / (to - from))
    }

    /// Physical value for a fraction (0…1) of the DMX range.
    public func physical(atFraction f: Double) -> Double { lerp(from, to, clamp01(f)) }

    private enum CodingKeys: String, CodingKey { case from, to, dmx, unit }

    public init(from decoder: Decoder) throws {
        // Shorthand: [from, to]
        if var arr = try? decoder.unkeyedContainer() {
            let a = try arr.decode(Double.self)
            let b = try arr.decode(Double.self)
            self.init(from: a, to: b)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let f = try c.decode(Double.self, forKey: .from)
        let t = try c.decode(Double.self, forKey: .to)
        let dmx = try c.decodeIfPresent([Int].self, forKey: .dmx) ?? [0, 255]
        let unit = try c.decodeIfPresent(String.self, forKey: .unit)
        self.init(from: f, to: t, dmxFrom: dmx.first ?? 0, dmxTo: dmx.count > 1 ? dmx[1] : 255, unit: unit)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(from, forKey: .from)
        try c.encode(to, forKey: .to)
        if dmxFrom != 0 || dmxTo != 255 { try c.encode([dmxFrom, dmxTo], forKey: .dmx) }
        try c.encodeIfPresent(unit, forKey: .unit)
    }
}

/// A labelled DMX value range of a channel (e.g. strobe 0–9 "Off", 10–255 "Slow → fast").
public struct ChannelCapability: Codable, Hashable, Sendable {
    public var from: Int
    public var to: Int
    public var label: String
    /// Machine-readable meaning. Known tags: "off", "open", "closed", "strobe", "pulse", "random",
    /// "cct", "rgb", "rgbw", "hsi", "xy", "gel", "source", "effect", "none", "reset", "default", "neutral".
    public var tag: String?
    /// Physical values across this range, when continuous (e.g. strobe Hz) or stepped (single value).
    public var physical: [Double]?

    public init(from: Int, to: Int, label: String, tag: String? = nil, physical: [Double]? = nil) {
        self.from = from; self.to = to; self.label = label; self.tag = tag; self.physical = physical
    }

    private enum CodingKeys: String, CodingKey {
        case range, dmx, label, name, tag, kind, physical, value, from, to
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let range = (try? c.decode([Int].self, forKey: .range))
            ?? (try? c.decode([Int].self, forKey: .dmx))
            ?? [0, 255]
        from = clamp(range.first ?? 0, 0, 255)
        to = clamp(range.count > 1 ? range[1] : from, from, 255)
        label = (try? c.decodeIfPresent(String.self, forKey: .label))
            ?? (try? c.decodeIfPresent(String.self, forKey: .name))
            ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
            ?? (try c.decodeIfPresent(String.self, forKey: .kind))
        if let p = try c.decodeIfPresent([Double].self, forKey: .physical) {
            physical = p
        } else if let pf = try c.decodeIfPresent(Double.self, forKey: .from),
                  let pt = try c.decodeIfPresent(Double.self, forKey: .to) {
            physical = [pf, pt]
        } else if let pv = try c.decodeIfPresent(Double.self, forKey: .value) {
            physical = [pv]
        } else {
            physical = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode([from, to], forKey: .range)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(tag, forKey: .tag)
        try c.encodeIfPresent(physical, forKey: .physical)
    }

    /// Representative DMX value for this capability (middle of the range).
    public var centerValue: UInt8 { UInt8(clamp((from + to) / 2, 0, 255)) }
}

/// One DMX channel within a mode.
public struct ChannelDefinition: Codable, Hashable, Sendable {
    public var kind: ChannelKind
    /// True if this is the least-significant byte of a 16-bit pair; the coarse (MSB) channel
    /// of the same kind and cell precedes it in the mode.
    public var fine: Bool
    /// Pixel / cell index (0-based) for per-pixel channels; nil for whole-fixture channels.
    public var cell: Int?
    public var label: String?
    /// Value sent when nothing else drives this channel.
    public var defaultValue: UInt8
    /// Value used when identifying/highlighting the fixture (optional).
    public var highlightValue: UInt8?
    public var physical: PhysicalRange?
    public var capabilities: [ChannelCapability]?
    /// Marks effect/service/control channels as advanced in the UI.
    public var advanced: Bool
    /// Optional per-channel emitter chromaticity override.
    public var emitter: EmitterSpec?

    public var isAdvanced: Bool { advanced || kind.isAdvancedByDefault }

    public init(kind: ChannelKind, fine: Bool = false, cell: Int? = nil, label: String? = nil,
                defaultValue: UInt8 = 0, highlightValue: UInt8? = nil,
                physical: PhysicalRange? = nil, capabilities: [ChannelCapability]? = nil,
                advanced: Bool = false, emitter: EmitterSpec? = nil) {
        self.kind = kind; self.fine = fine; self.cell = cell; self.label = label
        self.defaultValue = defaultValue; self.highlightValue = highlightValue
        self.physical = physical; self.capabilities = capabilities
        self.advanced = advanced; self.emitter = emitter
    }

    private enum CodingKeys: String, CodingKey {
        case kind, fine, coarse, cell, label, name, def
        case defaultValue = "default", highlightValue = "highlight"
        /// Long spelling accepted on input only (some converters and hand-written files use it).
        case defaultValueLong = "defaultValue"
        case physical, range, capabilities, advanced, emitter
    }

    public init(from decoder: Decoder) throws {
        // Shorthand: "red" == {"kind": "red"}. Unknown strings become a labelled generic channel.
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            if let k = ChannelKind(rawValue: s) {
                self.init(kind: k, advanced: k.isAdvancedByDefault)
            } else {
                let parsed = ChannelKind.parse(s)
                self.init(kind: parsed, fine: s.hasSuffix("Fine"), label: parsed == .generic ? s : nil, advanced: parsed.isAdvancedByDefault)
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil
        let parsedKind = rawKind.map(ChannelKind.parse) ?? .generic
        let isFineBool = (try? c.decodeIfPresent(Bool.self, forKey: .fine)) ?? false
        let hasCoarse = (try? c.decodeIfPresent(Int.self, forKey: .coarse)) != nil
        let isFine = isFineBool || hasCoarse || (rawKind?.hasSuffix("Fine") ?? false)
        let decodedCell = try? c.decodeIfPresent(Int.self, forKey: .cell)
        let decodedLabel = (try? c.decodeIfPresent(String.self, forKey: .label))
            ?? (try? c.decodeIfPresent(String.self, forKey: .name))
            ?? (try? c.decodeIfPresent(String.self, forKey: .def))
        let phys = (try? c.decodeIfPresent(PhysicalRange.self, forKey: .physical))
            ?? (try? c.decodeIfPresent(PhysicalRange.self, forKey: .range))
        let caps = try? c.decodeIfPresent([ChannelCapability].self, forKey: .capabilities)
        let adv = (try? c.decodeIfPresent(Bool.self, forKey: .advanced)) ?? parsedKind.isAdvancedByDefault
        let em = try? c.decodeIfPresent(EmitterSpec.self, forKey: .emitter)
        self.init(
            kind: parsedKind,
            fine: isFine,
            cell: decodedCell,
            label: decodedLabel,
            defaultValue: UInt8(clamp(
                (try? c.decodeIfPresent(Int.self, forKey: .defaultValue))
                    ?? (try? c.decodeIfPresent(Int.self, forKey: .defaultValueLong))
                    ?? 0,
                0, 255)),
            highlightValue: (try? c.decodeIfPresent(Int.self, forKey: .highlightValue)).map { UInt8(clamp($0, 0, 255)) },
            physical: phys,
            capabilities: caps,
            advanced: adv,
            emitter: em)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        if fine { try c.encode(true, forKey: .fine) }
        try c.encodeIfPresent(cell, forKey: .cell)
        try c.encodeIfPresent(label, forKey: .label)
        if defaultValue != 0 { try c.encode(Int(defaultValue), forKey: .defaultValue) }
        try c.encodeIfPresent(highlightValue.map(Int.init), forKey: .highlightValue)
        try c.encodeIfPresent(physical, forKey: .physical)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        if advanced && !kind.isAdvancedByDefault { try c.encode(true, forKey: .advanced) }
        try c.encodeIfPresent(emitter, forKey: .emitter)
    }

    /// Human readable name, e.g. "Red (pixel 3)", "Dimmer fine".
    public var displayName: String {
        var name = label ?? kind.defaultLabel
        if fine { name += " fine" }
        if let cell { name += " (pixel \(cell + 1))" }
        return name
    }

    /// First capability whose tag matches.
    public func capability(tagged tag: String) -> ChannelCapability? {
        capabilities?.first { $0.tag == tag }
    }

    /// Maps a physical value (Kelvin, tint, Hz, etc.) to an 8-bit DMX value using piecewise
    /// `capabilities` if available, falling back to `physical` range.
    public func dmxValue(forPhysical value: Double) -> UInt8 {
        if let caps = capabilities, !caps.isEmpty {
            // Stepped capabilities first for an exact match (e.g. neutral tint = 0). When the same
            // meaning appears in several ranges (amaran G/M has "Neutral" at 0–10 and 120–145),
            // prefer the range holding the channel's default so neutral renders as documented (128).
            var firstExact: ChannelCapability?
            for cap in caps {
                guard let p = cap.physical, p.count == 1, abs(p[0] - value) < 1e-6 else { continue }
                if Int(cap.from) <= Int(defaultValue), Int(defaultValue) <= Int(cap.to) { return defaultValue }
                if firstExact == nil { firstExact = cap }
            }
            if let exact = firstExact { return exact.centerValue }
            for cap in caps {
                if let p = cap.physical, p.count >= 2 {
                    let lo = min(p[0], p[1]), hi = max(p[0], p[1])
                    if value >= lo && value <= hi && p[1] != p[0] {
                        let f = clamp01((value - p[0]) / (p[1] - p[0]))
                        let dmx = Double(cap.from) + f * Double(cap.to - cap.from)
                        return UInt8(clamp(Int(dmx.rounded()), 0, 255))
                    }
                }
            }
        }
        if let p = physical {
            let f = p.fraction(for: value)
            let dmx = Double(p.dmxFrom) + f * Double(p.dmxTo - p.dmxFrom)
            return UInt8(clamp(Int(dmx.rounded()), 0, 255))
        }
        return defaultValue
    }
}

extension ChannelKind {
    public var defaultLabel: String {
        switch self {
        case .intensity: return "Dimmer"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .white: return "White"
        case .warmWhite: return "Warm White"
        case .coolWhite: return "Cool White"
        case .amber: return "Amber"
        case .lime: return "Lime"
        case .cyan: return "Cyan"
        case .magenta: return "Magenta"
        case .yellow: return "Yellow"
        case .uv: return "UV"
        case .indigo: return "Indigo"
        case .cct: return "CCT"
        case .tint: return "G/M Tint"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .cieX: return "CIE x"
        case .cieY: return "CIE y"
        case .crossfade: return "Crossfade"
        case .colorMode: return "Color Mode"
        case .colorMacro: return "Color Macro"
        case .gel: return "Gel"
        case .strobe: return "Strobe"
        case .shutter: return "Shutter"
        case .effect: return "Effect"
        case .effectSpeed: return "Effect Speed"
        case .effectParameter: return "Effect Parameter"
        case .pan: return "Pan"
        case .tilt: return "Tilt"
        case .zoom: return "Zoom"
        case .focus: return "Focus"
        case .gobo: return "Gobo"
        case .prism: return "Prism"
        case .iris: return "Iris"
        case .fan: return "Fan"
        case .control: return "Control"
        case .dimmerCurve: return "Dimmer Curve"
        case .generic: return "Generic"
        case .nothing: return "Reserved"
        }
    }
}

/// How pixels are arranged physically.
public enum CellLayout: Codable, Hashable, Sendable {
    /// Pixels in a line along the fixture's length (tubes, bars, strips). Cell 0 is at the
    /// fixture's "start" end (left when rotation = 0).
    case linear
    /// A grid (panels/matrices), row-major from top-left.
    case grid(columns: Int, rows: Int)

    private enum CodingKeys: String, CodingKey { case type, columns, rows }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = s == "grid" ? .grid(columns: 1, rows: 1) : .linear
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "linear"
        if type == "grid" {
            self = .grid(columns: max(1, try c.decodeIfPresent(Int.self, forKey: .columns) ?? 1),
                         rows: max(1, try c.decodeIfPresent(Int.self, forKey: .rows) ?? 1))
        } else {
            self = .linear
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linear:
            try c.encode("linear", forKey: .type)
        case .grid(let cols, let rows):
            try c.encode("grid", forKey: .type)
            try c.encode(cols, forKey: .columns)
            try c.encode(rows, forKey: .rows)
        }
    }
}

/// A DMX personality/mode of a fixture.
public struct FixtureMode: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var shortName: String?
    /// Friendly plain-English name shown in the Add Light wizard ("Full color · 8 zones").
    public var friendlyName: String?
    /// Exact text shown on the physical fixture's own menu screen (e.g. "CCT&RGB 8PX", "9: LE CCT&RGB 8px").
    public var fixtureMenuName: String?
    /// Plain-language explanation for non-lighting people ("Full color + white balance").
    public var summary: String?
    /// Prism suggests this mode by default.
    public var recommended: Bool
    /// Flattened channel list in DMX order (pixel templates already expanded).
    public var channels: [ChannelDefinition]
    /// Number of individually controllable pixels (0 = none).
    public var cellCount: Int
    public var cellLayout: CellLayout

    public var channelCount: Int { channels.count }

    /// Best human-friendly title for UI display (falls back to summary or mode name).
    public var displayFriendlyName: String { friendlyName ?? summary ?? name }
    /// Exact menu string to set on the fixture (falls back to shortName or mode name).
    public var displayMenuName: String { fixtureMenuName ?? shortName ?? name }

    public init(name: String, shortName: String? = nil, summary: String? = nil, recommended: Bool = false,
                channels: [ChannelDefinition], cellLayout: CellLayout = .linear,
                friendlyName: String? = nil, fixtureMenuName: String? = nil) {
        self.name = name
        self.shortName = shortName
        self.friendlyName = friendlyName
        self.fixtureMenuName = fixtureMenuName
        self.summary = summary
        self.recommended = recommended
        self.channels = channels
        self.cellLayout = cellLayout
        let cells = channels.compactMap { $0.cell }
        self.cellCount = (cells.max().map { $0 + 1 }) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case name, key, shortName, friendlyName, fixtureMenuName, summary, recommended, channels, pixels, cellLayout
    }

    /// Pixel template used in authoring JSON.
    private struct PixelTemplate: Codable {
        var count: Int
        var channels: [ChannelDefinition]
        /// Insert position in the global channel list (default: after all global channels).
        var insertAt: Int?
        /// "pixel" (default: R1 G1 B1 R2 G2 B2…) or "channel" (R1 R2 … G1 G2 …).
        var order: String?
        var layout: CellLayout?
    }

    /// Raw channel entry used when decoding `prism-fixture/1` files that have string cell keys.
    private struct RawStringCellProbe: Decodable {
        var cellString: String?
        var defKey: String?
        private enum CodingKeys: String, CodingKey { case cell, def }
        init(from decoder: Decoder) throws {
            guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            if let s = try? c.decode(String.self, forKey: .cell) { cellString = s }
            defKey = try? c.decode(String.self, forKey: .def)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        shortName = (try? c.decodeIfPresent(String.self, forKey: .shortName))
            ?? (try? c.decodeIfPresent(String.self, forKey: .key))
        friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName)
        fixtureMenuName = try c.decodeIfPresent(String.self, forKey: .fixtureMenuName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        var list = try c.decodeIfPresent([ChannelDefinition].self, forKey: .channels) ?? []
        if let probes = try? c.decodeIfPresent([RawStringCellProbe].self, forKey: .channels),
           probes.count == list.count,
           probes.contains(where: { $0.cellString != nil }) {
            var keyToIndex: [String: Int] = [:]
            for idx in list.indices {
                if list[idx].cell == nil, let key = probes[idx].cellString {
                    let mapped = keyToIndex[key] ?? {
                        let next = keyToIndex.count
                        keyToIndex[key] = next
                        return next
                    }()
                    list[idx].cell = mapped
                }
            }
        }
        var layout = try c.decodeIfPresent(CellLayout.self, forKey: .cellLayout) ?? .linear
        if let px = try c.decodeIfPresent(PixelTemplate.self, forKey: .pixels), px.count > 0, px.count <= 1024 {
            var expanded: [ChannelDefinition] = []
            if px.order == "channel" {
                for template in px.channels {
                    for i in 0..<px.count {
                        var ch = template; ch.cell = i; expanded.append(ch)
                    }
                }
            } else {
                for i in 0..<px.count {
                    for template in px.channels {
                        var ch = template; ch.cell = i; expanded.append(ch)
                    }
                }
            }
            let at = clamp(px.insertAt ?? list.count, 0, list.count)
            list.insert(contentsOf: expanded, at: at)
            if let l = px.layout { layout = l }
        }
        channels = list
        cellLayout = layout
        let cells = list.compactMap { $0.cell }
        cellCount = (cells.max().map { $0 + 1 }) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(shortName, forKey: .shortName)
        try c.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try c.encodeIfPresent(fixtureMenuName, forKey: .fixtureMenuName)
        try c.encodeIfPresent(summary, forKey: .summary)
        if recommended { try c.encode(true, forKey: .recommended) }
        try c.encode(channels, forKey: .channels)
        if cellCount > 0 { try c.encode(cellLayout, forKey: .cellLayout) }
    }

    /// Index of the first channel matching kind/cell/fine.
    public func channelIndex(_ kind: ChannelKind, cell: Int? = nil, fine: Bool = false) -> Int? {
        channels.firstIndex { $0.kind == kind && $0.cell == cell && $0.fine == fine }
    }

    public func has(_ kind: ChannelKind) -> Bool { channels.contains { $0.kind == kind } }

    /// Summary of what this mode can do, for UI and renderers.
    public var capabilities: ColorCapabilities { ColorCapabilities(mode: self) }
}

/// What a mode can do, derived from its channel kinds.
public struct ColorCapabilities: Hashable, Sendable {
    public var hasIntensity: Bool
    public var emitters: Set<ChannelKind>
    public var hasCCT: Bool
    public var hasTint: Bool
    public var hasHSI: Bool
    public var hasXY: Bool
    public var hasCrossfade: Bool
    public var hasColorModeSelect: Bool
    public var hasStrobe: Bool
    public var cellCount: Int

    public init(mode: FixtureMode) {
        let kinds = Set(mode.channels.map(\.kind))
        hasIntensity = kinds.contains(.intensity)
        emitters = kinds.filter { $0.isEmitter }
        hasCCT = kinds.contains(.cct)
        hasTint = kinds.contains(.tint)
        hasHSI = kinds.contains(.hue)
        hasXY = kinds.contains(.cieX) && kinds.contains(.cieY)
        hasCrossfade = kinds.contains(.crossfade)
        hasColorModeSelect = kinds.contains(.colorMode)
        hasStrobe = kinds.contains(.strobe) || kinds.contains(.shutter)
        cellCount = mode.cellCount
    }

    public var hasRGB: Bool { emitters.isSuperset(of: [.red, .green, .blue]) }
    /// Can produce saturated colors (RGB emitters, HSI or XY).
    public var canDoColor: Bool { hasRGB || hasHSI || hasXY || emitters.isSuperset(of: [.cyan, .magenta, .yellow]) }
    /// Can produce adjustable white balance.
    public var canDoWhiteBalance: Bool { hasCCT || canDoColor || emitters.isSuperset(of: [.warmWhite, .coolWhite]) }
    public var isDimmerOnly: Bool { !canDoColor && !canDoWhiteBalance }

    /// Short badge like "RGBWW", "CCT", "Dimmer", "RGB · 16 px".
    public var badge: String {
        var s: String
        if hasRGB {
            s = "RGB"
            if emitters.contains(.white) { s += "W" }
            if emitters.contains(.warmWhite) || emitters.contains(.coolWhite) { s += "WW" }
            if emitters.contains(.amber) { s += "A" }
            if emitters.contains(.lime) { s += "L" }
            if emitters.contains(.uv) { s += "+UV" }
            if hasCCT { s = "CCT + " + s }
        } else if hasHSI {
            s = hasCCT ? "CCT + HSI" : "HSI"
        } else if hasCCT || emitters.isSuperset(of: [.warmWhite, .coolWhite]) {
            s = "Bi-color"
        } else {
            s = "Dimmer"
        }
        if cellCount > 0 { s += " · \(cellCount) px" }
        return s
    }
}

public struct PhysicalSpec: Codable, Hashable, Sendable {
    public var lengthMM: Double?
    public var widthMM: Double?
    public var heightMM: Double?
    public var diameterMM: Double?
    public var weightKG: Double?
    public var powerW: Double?

    public init(lengthMM: Double? = nil, widthMM: Double? = nil, heightMM: Double? = nil,
                diameterMM: Double? = nil, weightKG: Double? = nil, powerW: Double? = nil) {
        self.lengthMM = lengthMM; self.widthMM = widthMM; self.heightMM = heightMM
        self.diameterMM = diameterMM; self.weightKG = weightKG; self.powerW = powerW
    }

    private enum CodingKeys: String, CodingKey {
        case lengthMM, widthMM, heightMM, diameterMM, weightKG, powerW
        case dimensionsMm, weightKg
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var len = try c.decodeIfPresent(Double.self, forKey: .lengthMM)
        var wid = try c.decodeIfPresent(Double.self, forKey: .widthMM)
        var hgt = try c.decodeIfPresent(Double.self, forKey: .heightMM)
        let dia = try c.decodeIfPresent(Double.self, forKey: .diameterMM)
        let wt = try c.decodeIfPresent(Double.self, forKey: .weightKG)
            ?? (try c.decodeIfPresent(Double.self, forKey: .weightKg))
        let pwr = try c.decodeIfPresent(Double.self, forKey: .powerW)
        if let dims = try c.decodeIfPresent([Double].self, forKey: .dimensionsMm), !dims.isEmpty {
            if wid == nil { wid = dims[0] }
            if hgt == nil && dims.count > 1 { hgt = dims[1] }
            if len == nil { len = dims.max() }
        }
        self.init(lengthMM: len, widthMM: wid, heightMM: hgt, diameterMM: dia, weightKG: wt, powerW: pwr)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(lengthMM, forKey: .lengthMM)
        try c.encodeIfPresent(widthMM, forKey: .widthMM)
        try c.encodeIfPresent(heightMM, forKey: .heightMM)
        try c.encodeIfPresent(diameterMM, forKey: .diameterMM)
        try c.encodeIfPresent(weightKG, forKey: .weightKG)
        try c.encodeIfPresent(powerW, forKey: .powerW)
    }
}

/// Out-of-the-box factory DMX settings for a fixture.
public struct FixtureFactoryDefaults: Codable, Hashable, Sendable {
    public var address: Int?
    public var mode: String?
    public var signalLossBehavior: String?

    public init(address: Int? = 1, mode: String? = nil, signalLossBehavior: String? = nil) {
        self.address = address
        self.mode = mode
        self.signalLossBehavior = signalLossBehavior
    }
}

/// Plain-English setup instructions for configuring DMX address and mode on the physical fixture.
public struct FixtureSetupGuide: Codable, Hashable, Sendable {
    public typealias FactoryDefaults = FixtureFactoryDefaults

    /// Menu/button steps to set the DMX start address (e.g. `["MENU", "DMX Settings", "DMX Address"]`).
    public var addressMenuPath: [String]
    /// Menu/button steps to set the DMX mode/profile (e.g. `["MENU", "DMX Settings", "DMX Profiles"]`).
    public var modeMenuPath: [String]
    /// Factory default address, mode and signal-loss setting.
    public var factoryDefaults: FixtureFactoryDefaults?
    /// Physical DMX connector or required adapter (e.g. `"5-pin XLR in/out"`, `"USB-C → DMX adapter (sold separately)"`).
    public var connector: String?
    /// How the fixture displays address 1 on its screen (e.g. `"A001"`, `"001"`, `"d001"`).
    public var addressDisplayFormat: String?
    /// True when the fixture uses physical DIP switches instead of an on-screen menu.
    public var usesDipSwitches: Bool
    /// Default or recommended DMX signal-loss behavior (e.g. `"Hold Last Setting"`).
    public var signalLossBehavior: String?
    /// Important setup tips or hardware quirks (e.g. `"Keep the DMX Address screen visible"`).
    public var notes: [String]
    /// URL to the official user manual or DMX profile specification PDF.
    public var manualURL: String?

    public init(addressMenuPath: [String] = [], modeMenuPath: [String] = [],
                factoryDefaults: FixtureFactoryDefaults? = nil, connector: String? = nil,
                addressDisplayFormat: String? = nil, usesDipSwitches: Bool = false,
                signalLossBehavior: String? = nil, notes: [String] = [], manualURL: String? = nil) {
        self.addressMenuPath = addressMenuPath
        self.modeMenuPath = modeMenuPath
        self.factoryDefaults = factoryDefaults
        self.connector = connector
        self.addressDisplayFormat = addressDisplayFormat
        self.usesDipSwitches = usesDipSwitches
        self.signalLossBehavior = signalLossBehavior
        self.notes = notes
        self.manualURL = manualURL
    }

    private enum CodingKeys: String, CodingKey {
        case addressMenuPath, modeMenuPath, factoryDefaults, connector, addressDisplayFormat
        case usesDipSwitches, signalLossBehavior, notes, manualURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        addressMenuPath = (try? c.decodeIfPresent([String].self, forKey: .addressMenuPath)) ?? []
        modeMenuPath = (try? c.decodeIfPresent([String].self, forKey: .modeMenuPath)) ?? []
        factoryDefaults = try? c.decodeIfPresent(FixtureFactoryDefaults.self, forKey: .factoryDefaults)
        connector = try? c.decodeIfPresent(String.self, forKey: .connector)
        addressDisplayFormat = try? c.decodeIfPresent(String.self, forKey: .addressDisplayFormat)
        usesDipSwitches = (try? c.decodeIfPresent(Bool.self, forKey: .usesDipSwitches)) ?? false
        if let s = try? c.decodeIfPresent(String.self, forKey: .signalLossBehavior) {
            signalLossBehavior = s
        } else if let arr = try? c.decodeIfPresent([String].self, forKey: .signalLossBehavior), !arr.isEmpty {
            signalLossBehavior = arr.joined(separator: " / ")
        } else {
            signalLossBehavior = nil
        }
        if let arr = try? c.decodeIfPresent([String].self, forKey: .notes) {
            notes = arr
        } else if let single = try? c.decodeIfPresent(String.self, forKey: .notes), !single.isEmpty {
            notes = [single]
        } else {
            notes = []
        }
        manualURL = try? c.decodeIfPresent(String.self, forKey: .manualURL)
    }

    /// Formats a 1-based DMX address (1…512) the way the fixture displays it on screen (e.g. `"A017"`, `"017"`).
    public func formatAddress(_ address: Int) -> String {
        let clamped = clamp(address, 1, 512)
        guard let fmt = addressDisplayFormat, !fmt.isEmpty else {
            return String(format: "%03d", clamped)
        }
        if fmt.contains("001") {
            return fmt.replacingOccurrences(of: "001", with: String(format: "%03d", clamped))
        }
        if fmt.contains("01") {
            return fmt.replacingOccurrences(of: "01", with: String(format: "%02d", clamped))
        }
        if fmt.contains("1") {
            return fmt.replacingOccurrences(of: "1", with: "\(clamped)")
        }
        return "\(fmt)\(String(format: "%03d", clamped))"
    }

    public func formattedAddress(_ address: Int) -> String { formatAddress(address) }

    public var addressMenuBreadcrumb: String { addressMenuPath.joined(separator: " → ") }
    public var modeMenuBreadcrumb: String { modeMenuPath.joined(separator: " → ") }
}

/// Confidence level in a fixture definition's DMX channel map.
public enum FixtureVerification: String, Codable, CaseIterable, Sendable {
    /// Verified directly against an official manufacturer DMX specification chart or manual.
    case manufacturerChart
    /// Converted from a community library (Open Fixture Library, QLC+) or community-contributed.
    case community
    /// Inferred or not yet verified against primary documentation.
    case unverified

    public var displayName: String {
        switch self {
        case .manufacturerChart: return "Manufacturer Verified"
        case .community: return "Community Library"
        case .unverified: return "Unverified"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        switch raw {
        case "manufacturerChart", "manufacturer_chart", "manufacturer", "verified", "official":
            self = .manufacturerChart
        case "community", "ofl", "qlc", "qlcplus":
            self = .community
        default:
            self = .unverified
        }
    }
}

/// Provenance and licensing metadata for a fixture definition.
public struct FixtureSource: Codable, Hashable, Sendable {
    /// Origin identifier: "curated", "ofl", "qlc", "user", "generic".
    public var kind: String?
    /// Source URL (manufacturer spec PDF, OFL fixture page, etc.).
    public var url: String?
    /// SPDX license identifier or license description (e.g. "MIT", "Apache-2.0").
    public var license: String?
    /// Author credits preserved from upstream libraries.
    public var authors: [String]?
    /// Upstream repository commit hash or specification version.
    public var commit: String?

    public init(kind: String? = nil, url: String? = nil, license: String? = nil,
                authors: [String]? = nil, commit: String? = nil) {
        self.kind = kind; self.url = url; self.license = license
        self.authors = authors; self.commit = commit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, library, url, license, authors, commit
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            self.init(kind: s)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let k = (try? c.decodeIfPresent(String.self, forKey: .kind))
            ?? (try? c.decodeIfPresent(String.self, forKey: .library))
        let u = try? c.decodeIfPresent(String.self, forKey: .url)
        let l = try? c.decodeIfPresent(String.self, forKey: .license)
        let a = try? c.decodeIfPresent([String].self, forKey: .authors)
        let cm = try? c.decodeIfPresent(String.self, forKey: .commit)
        self.init(kind: k, url: u, license: l, authors: a, commit: cm)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(license, forKey: .license)
        try c.encodeIfPresent(authors, forKey: .authors)
        try c.encodeIfPresent(commit, forKey: .commit)
    }
}

/// A model of light and all its DMX modes.
public struct FixtureDefinition: Codable, Hashable, Sendable, Identifiable {
    /// Stable identifier, lowercase "manufacturer.model" (e.g. "amaran.pt4c", "generic.rgbw").
    public var id: String
    public var manufacturer: String
    public var model: String
    public var category: FixtureCategory
    public var aliases: [String]
    public var physical: PhysicalSpec?
    /// Native white range in Kelvin [min, max], if the fixture has one.
    public var cctRange: [Double]?
    public var modes: [FixtureMode]
    /// "curated", "ofl", "qlc", "user", "generic".
    public var source: String?
    /// Structured provenance (URL, license, authors, commit).
    public var sourceInfo: FixtureSource?
    /// Verification level: `.manufacturerChart`, `.community`, or `.unverified`.
    public var verification: FixtureVerification?
    /// Plain-English setup guide (menu paths, connector, display format, defaults, notes, manual URL).
    public var setupGuide: FixtureSetupGuide?
    /// Optional per-emitter chromaticity (CIE 1931 xy) and relative lumens for `EmitterMixer`.
    public var emitters: [ChannelKind: EmitterSpec]?
    public var notes: String?
    /// Plain-language steps for setting the DMX address/mode on the physical light.
    public var addressHelp: String?
    public var links: [String]?
    public var revision: Int?

    public var effectiveVerification: FixtureVerification {
        if let verification { return verification }
        switch source {
        case "curated": return .manufacturerChart
        case "ofl", "qlc", "qlcplus": return .community
        default: return .unverified
        }
    }

    public var sourceURL: String? { sourceInfo?.url ?? setupGuide?.manualURL ?? links?.first }
    public var license: String? { sourceInfo?.license }

    public func emitterSpec(for kind: ChannelKind) -> EmitterSpec? {
        emitters?[kind] ?? EmitterSpec.standard(for: kind)
    }

    public init(id: String, manufacturer: String, model: String, category: FixtureCategory,
                aliases: [String] = [], physical: PhysicalSpec? = nil, cctRange: [Double]? = nil,
                modes: [FixtureMode], source: String? = nil, notes: String? = nil,
                addressHelp: String? = nil, links: [String]? = nil, revision: Int? = nil,
                setupGuide: FixtureSetupGuide? = nil, verification: FixtureVerification? = nil,
                sourceInfo: FixtureSource? = nil, emitters: [ChannelKind: EmitterSpec]? = nil) {
        self.id = id; self.manufacturer = manufacturer; self.model = model; self.category = category
        self.aliases = aliases; self.physical = physical; self.cctRange = cctRange; self.modes = modes
        self.source = source ?? sourceInfo?.kind
        self.sourceInfo = sourceInfo ?? source.map { FixtureSource(kind: $0) }
        self.verification = verification
        self.setupGuide = setupGuide
        self.emitters = emitters
        self.notes = notes; self.addressHelp = addressHelp; self.links = links
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, manufacturer, model, shortName, category, aliases, physical, cctRange, modes
        case source, sourceInfo, verification, setupGuide, emitters
        case notes, addressHelp, links, revision, definitions
    }

    /// Top-level shared channel definition used in `$schema: "prism-fixture/1"` files.
    private struct SharedChannelDef: Decodable {
        var kind: ChannelKind?
        var name: String?
        var res: Int?
        var `default`: Int?
        var highlight: Int?
        var range: PhysicalRange?
        var capabilities: [RawSharedCapability]?
    }

    private struct RawSharedCapability: Decodable {
        var dmx: [Int]?
        var range: [Int]?
        var kind: String?
        var tag: String?
        var label: String?
        var value: Double?
        var from: Double?
        var to: Double?
        var physical: [Double]?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? "Generic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "Unknown"
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? FixtureDefinition.makeID(manufacturer: manufacturer, model: model)
        category = try c.decodeIfPresent(FixtureCategory.self, forKey: .category) ?? .other
        var decodedAliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        if let short = try? c.decodeIfPresent(String.self, forKey: .shortName),
           !short.isEmpty, !decodedAliases.contains(short), short != model {
            decodedAliases.append(short)
        }
        aliases = decodedAliases
        physical = try c.decodeIfPresent(PhysicalSpec.self, forKey: .physical)
        cctRange = try c.decodeIfPresent([Double].self, forKey: .cctRange)

        var decodedModes = try c.decodeIfPresent([FixtureMode].self, forKey: .modes) ?? []
        // Resolve top-level `definitions` references when decoding `prism-fixture/1` files from OFL/QLC+.
        if let sharedDefs = try? c.decodeIfPresent([String: SharedChannelDef].self, forKey: .definitions),
           !sharedDefs.isEmpty {
            var detectedCCT: [Double]? = cctRange
            for mIdx in decodedModes.indices {
                for chIdx in decodedModes[mIdx].channels.indices {
                    let ch = decodedModes[mIdx].channels[chIdx]
                    guard let defKey = ch.label,
                          let shared = sharedDefs[defKey] else { continue }
                    let scale = max(1, (shared.res ?? 8) == 16 ? 257 : ((shared.res ?? 8) == 24 ? 65793 : 1))
                    if let d = shared.default, ch.defaultValue == 0 {
                        decodedModes[mIdx].channels[chIdx].defaultValue = UInt8(clamp(d / scale, 0, 255))
                    }
                    if let h = shared.highlight, ch.highlightValue == nil {
                        decodedModes[mIdx].channels[chIdx].highlightValue = UInt8(clamp(h / scale, 0, 255))
                    }
                    if let r = shared.range, ch.physical == nil {
                        decodedModes[mIdx].channels[chIdx].physical = r
                        if ch.kind == .cct && detectedCCT == nil && r.from >= 1000 && r.to >= r.from {
                            detectedCCT = [r.from, r.to]
                        }
                    }
                    if let rawCaps = shared.capabilities, ch.capabilities == nil {
                        decodedModes[mIdx].channels[chIdx].capabilities = rawCaps.map { rc in
                            let r = rc.range ?? rc.dmx ?? [0, 255]
                            let f = clamp((r.first ?? 0) / scale, 0, 255)
                            let t = clamp((r.count > 1 ? r[1] : (r.first ?? 0)) / scale, f, 255)
                            var phys: [Double]? = rc.physical
                            if phys == nil, let from = rc.from, let to = rc.to { phys = [from, to] }
                            if phys == nil, let v = rc.value { phys = [v] }
                            var tag = rc.tag ?? rc.kind
                            if tag == "none", let lbl = rc.label?.lowercased(), lbl.contains("off") || lbl.contains("no ") {
                                tag = "off"
                            }
                            return ChannelCapability(from: f, to: t, label: rc.label ?? "", tag: tag, physical: phys)
                        }
                    }
                    if let cleanName = shared.name, !cleanName.isEmpty {
                        decodedModes[mIdx].channels[chIdx].label = cleanName
                    }
                }
            }
            if cctRange == nil { cctRange = detectedCCT }
        }
        modes = decodedModes

        if let s = try? c.decodeIfPresent(String.self, forKey: .source) {
            source = s
            sourceInfo = (try? c.decodeIfPresent(FixtureSource.self, forKey: .sourceInfo)) ?? FixtureSource(kind: s)
        } else if let si = try? c.decodeIfPresent(FixtureSource.self, forKey: .source) {
            sourceInfo = si
            source = si.kind == "prism" ? "curated" : si.kind
        } else if let si = try? c.decodeIfPresent(FixtureSource.self, forKey: .sourceInfo) {
            sourceInfo = si
            source = si.kind
        } else {
            source = nil
            sourceInfo = nil
        }

        verification = try? c.decodeIfPresent(FixtureVerification.self, forKey: .verification)
        setupGuide = try? c.decodeIfPresent(FixtureSetupGuide.self, forKey: .setupGuide)

        if let rawEmitters = try? c.decodeIfPresent([String: EmitterSpec].self, forKey: .emitters) {
            var mapped: [ChannelKind: EmitterSpec] = [:]
            for (k, v) in rawEmitters {
                let kind = ChannelKind.parse(k)
                if kind.isEmitter { mapped[kind] = v }
            }
            emitters = mapped.isEmpty ? nil : mapped
        } else {
            emitters = nil
        }

        if let s = try? c.decodeIfPresent(String.self, forKey: .notes) {
            notes = s
        } else if let arr = try? c.decodeIfPresent([String].self, forKey: .notes), !arr.isEmpty {
            notes = arr.joined(separator: " ")
        } else {
            notes = nil
        }

        addressHelp = try? c.decodeIfPresent(String.self, forKey: .addressHelp)

        if let arr = try? c.decodeIfPresent([String].self, forKey: .links) {
            links = arr
        } else if let dict = try? c.decodeIfPresent([String: [String]].self, forKey: .links) {
            var all: [String] = []
            for key in ["manual", "productPage", "other", "video"] {
                if let urls = dict[key] { all.append(contentsOf: urls) }
            }
            links = all.isEmpty ? nil : all
        } else {
            links = nil
        }

        revision = try? c.decodeIfPresent(Int.self, forKey: .revision)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(manufacturer, forKey: .manufacturer)
        try c.encode(model, forKey: .model)
        try c.encode(category, forKey: .category)
        if !aliases.isEmpty { try c.encode(aliases, forKey: .aliases) }
        try c.encodeIfPresent(physical, forKey: .physical)
        try c.encodeIfPresent(cctRange, forKey: .cctRange)
        try c.encode(modes, forKey: .modes)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(sourceInfo, forKey: .sourceInfo)
        try c.encodeIfPresent(verification, forKey: .verification)
        try c.encodeIfPresent(setupGuide, forKey: .setupGuide)
        if let emitters, !emitters.isEmpty {
            let raw = Dictionary(uniqueKeysWithValues: emitters.map { ($0.key.rawValue, $0.value) })
            try c.encode(raw, forKey: .emitters)
        }
        try c.encodeIfPresent(notes, forKey: .notes)
        try c.encodeIfPresent(addressHelp, forKey: .addressHelp)
        try c.encodeIfPresent(links, forKey: .links)
        try c.encodeIfPresent(revision, forKey: .revision)
    }

    public static func makeID(manufacturer: String, model: String) -> String {
        func slug(_ s: String) -> String {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
            let lowered = s.lowercased().replacingOccurrences(of: " ", with: "-")
            return String(lowered.filter { allowed.contains($0) })
        }
        return "\(slug(manufacturer)).\(slug(model))"
    }

    public func mode(named name: String) -> FixtureMode? {
        if let exact = modes.first(where: { $0.name == name })
            ?? modes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
            ?? modes.first(where: { $0.shortName?.caseInsensitiveCompare(name) == .orderedSame })
            ?? modes.first(where: { $0.fixtureMenuName?.caseInsensitiveCompare(name) == .orderedSame })
            ?? modes.first(where: { $0.friendlyName?.caseInsensitiveCompare(name) == .orderedSame }) {
            return exact
        }
        func canonical(_ s: String) -> String {
            var out = s.lowercased()
            // Strip leading menu numbering like "9: "
            if let colon = out.firstIndex(of: ":"), out.distance(from: out.startIndex, to: colon) <= 3 {
                let prefix = out[..<colon]
                if prefix.allSatisfy({ $0.isNumber || $0 == " " }) {
                    out = String(out[out.index(after: colon)...])
                }
            }
            out = out.replacingOccurrences(of: "light engine", with: "le")
            out = out.replacingOccurrences(of: "pixels", with: "px")
            out = out.replacingOccurrences(of: "pixel", with: "px")
            return String(out.filter { $0.isLetter || $0.isNumber })
        }
        let target = canonical(name)
        guard !target.isEmpty else { return nil }
        return modes.first { m in
            canonical(m.name) == target
                || (m.shortName.map { canonical($0) == target } ?? false)
                || (m.fixtureMenuName.map { canonical($0) == target } ?? false)
        }
    }

    public var recommendedMode: FixtureMode? {
        modes.first { $0.recommended } ?? modes.first
    }

    public var displayName: String { "\(manufacturer) \(model)" }
}

/// A JSON file containing one or more definitions.
public struct FixtureDefinitionFile: Codable, Sendable {
    public var schemaVersion: Int
    public var fixtures: [FixtureDefinition]

    public init(schemaVersion: Int = 1, fixtures: [FixtureDefinition]) {
        self.schemaVersion = schemaVersion
        self.fixtures = fixtures
    }
}

// MARK: - Validation

extension FixtureDefinition {
    /// Result of `validate()`: `issues` make a profile unusable or wrong (must be fixed);
    /// `warnings` are legal but unusual layouts worth knowing about.
    public struct Validation: Sendable {
        public var issues: [String] = []
        public var warnings: [String] = []
        public var isValid: Bool { issues.isEmpty }
    }

    /// Structural problems that would make a profile misbehave when patched; empty when valid.
    public var validationIssues: [String] { validate().issues }

    /// Checks every mode.
    ///
    /// Issues: no modes; 0 or more than 512 channels (the footprint is exactly the channel
    /// list); duplicate mode names; a fine (LSB) channel with no coarse channel of the same
    /// kind and cell anywhere in the mode (it would never be driven).
    ///
    /// Warnings:
    /// - a fine channel that does not directly follow its coarse channel (or the previous
    ///   precision byte of a 24-bit control). The renderer only writes a fine byte right after
    ///   its coarse partner, so such a channel stays at its default and the control is 8-bit.
    /// - a role claimed twice for the same cell (two "pan" channels, a second "red" without a
    ///   pixel number). Both channels then follow the same control, which is what multi-zone
    ///   fixtures without pixel numbering expect, but a hand-made profile with this is usually
    ///   a mistake.
    public func validate() -> Validation {
        struct Role: Hashable { let kind: ChannelKind; let cell: Int? }
        var result = Validation()
        if modes.isEmpty { result.issues.append("\(id): no modes") }
        var names = Set<String>()
        for mode in modes {
            let place = "\(id) · \(mode.name)"
            if !names.insert(mode.name).inserted { result.issues.append("\(place): duplicate mode name") }
            if mode.channelCount < 1 || mode.channelCount > 512 {
                result.issues.append("\(place): \(mode.channelCount) channels (must be 1–512)")
            }
            let channels = mode.channels
            let coarseRoles = Set(channels.filter { !$0.fine }.map { Role(kind: $0.kind, cell: $0.cell) })
            var coarseCount: [Role: Int] = [:]
            for (index, channel) in channels.enumerated() {
                let role = Role(kind: channel.kind, cell: channel.cell)
                let cellText = channel.cell.map { " (cell \($0 + 1))" } ?? ""
                if channel.fine {
                    if !coarseRoles.contains(role) {
                        result.issues.append("\(place): fine channel \(index + 1) (\(channel.kind.rawValue)\(cellText)) has no coarse channel")
                    } else if index == 0
                                || channels[index - 1].kind != channel.kind
                                || channels[index - 1].cell != channel.cell {
                        result.warnings.append("\(place): fine channel \(index + 1) (\(channel.kind.rawValue)\(cellText)) is not next to its coarse channel")
                    }
                } else {
                    let count = coarseCount[role, default: 0] + 1
                    coarseCount[role] = count
                    if count > 1, channel.kind.isUniqueRole {
                        result.warnings.append("\(place): channel \(index + 1) repeats \(channel.kind.rawValue)\(cellText)")
                    }
                }
            }
        }
        return result
    }
}
