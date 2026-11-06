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
    case tint           // green/magenta, use `physical` mapping where -1 = green, +1 = magenta
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
        self = ChannelKind(rawValue: raw) ?? .generic
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
    /// "cct", "rgb", "rgbw", "hsi", "xy", "gel", "source", "effect", "none", "reset", "default".
    public var tag: String?
    /// Physical values across this range, when continuous (e.g. strobe Hz).
    public var physical: [Double]?

    public init(from: Int, to: Int, label: String, tag: String? = nil, physical: [Double]? = nil) {
        self.from = from; self.to = to; self.label = label; self.tag = tag; self.physical = physical
    }

    private enum CodingKeys: String, CodingKey { case range, label, tag, physical }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let range = try c.decode([Int].self, forKey: .range)
        from = clamp(range.first ?? 0, 0, 255)
        to = clamp(range.count > 1 ? range[1] : from, from, 255)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag)
        physical = try c.decodeIfPresent([Double].self, forKey: .physical)
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

    public init(kind: ChannelKind, fine: Bool = false, cell: Int? = nil, label: String? = nil,
                defaultValue: UInt8 = 0, highlightValue: UInt8? = nil,
                physical: PhysicalRange? = nil, capabilities: [ChannelCapability]? = nil) {
        self.kind = kind; self.fine = fine; self.cell = cell; self.label = label
        self.defaultValue = defaultValue; self.highlightValue = highlightValue
        self.physical = physical; self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case kind, fine, cell, label, defaultValue = "default", highlightValue = "highlight", physical, capabilities
    }

    public init(from decoder: Decoder) throws {
        // Shorthand: "red" == {"kind": "red"}. Unknown strings become a labelled generic channel.
        if let single = try? decoder.singleValueContainer(), let s = try? single.decode(String.self) {
            if let k = ChannelKind(rawValue: s) {
                self.init(kind: k)
            } else {
                self.init(kind: .generic, label: s)
            }
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try c.decodeIfPresent(ChannelKind.self, forKey: .kind) ?? .generic,
            fine: try c.decodeIfPresent(Bool.self, forKey: .fine) ?? false,
            cell: try c.decodeIfPresent(Int.self, forKey: .cell),
            label: try c.decodeIfPresent(String.self, forKey: .label),
            defaultValue: UInt8(clamp(try c.decodeIfPresent(Int.self, forKey: .defaultValue) ?? 0, 0, 255)),
            highlightValue: try c.decodeIfPresent(Int.self, forKey: .highlightValue).map { UInt8(clamp($0, 0, 255)) },
            physical: try c.decodeIfPresent(PhysicalRange.self, forKey: .physical),
            capabilities: try c.decodeIfPresent([ChannelCapability].self, forKey: .capabilities))
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

    public init(name: String, shortName: String? = nil, summary: String? = nil, recommended: Bool = false,
                channels: [ChannelDefinition], cellLayout: CellLayout = .linear) {
        self.name = name
        self.shortName = shortName
        self.summary = summary
        self.recommended = recommended
        self.channels = channels
        self.cellLayout = cellLayout
        let cells = channels.compactMap { $0.cell }
        self.cellCount = (cells.max().map { $0 + 1 }) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case name, shortName, summary, recommended, channels, pixels, cellLayout
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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        shortName = try c.decodeIfPresent(String.self, forKey: .shortName)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
        var list = try c.decodeIfPresent([ChannelDefinition].self, forKey: .channels) ?? []
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
    public var notes: String?
    /// Plain-language steps for setting the DMX address/mode on the physical light.
    public var addressHelp: String?
    public var links: [String]?
    public var revision: Int?

    public init(id: String, manufacturer: String, model: String, category: FixtureCategory,
                aliases: [String] = [], physical: PhysicalSpec? = nil, cctRange: [Double]? = nil,
                modes: [FixtureMode], source: String? = nil, notes: String? = nil,
                addressHelp: String? = nil, links: [String]? = nil, revision: Int? = nil) {
        self.id = id; self.manufacturer = manufacturer; self.model = model; self.category = category
        self.aliases = aliases; self.physical = physical; self.cctRange = cctRange; self.modes = modes
        self.source = source; self.notes = notes; self.addressHelp = addressHelp; self.links = links
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case id, manufacturer, model, category, aliases, physical, cctRange, modes, source, notes, addressHelp, links, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? "Generic"
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "Unknown"
        id = try c.decodeIfPresent(String.self, forKey: .id)
            ?? FixtureDefinition.makeID(manufacturer: manufacturer, model: model)
        category = try c.decodeIfPresent(FixtureCategory.self, forKey: .category) ?? .other
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        physical = try c.decodeIfPresent(PhysicalSpec.self, forKey: .physical)
        cctRange = try c.decodeIfPresent([Double].self, forKey: .cctRange)
        modes = try c.decodeIfPresent([FixtureMode].self, forKey: .modes) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        addressHelp = try c.decodeIfPresent(String.self, forKey: .addressHelp)
        links = try c.decodeIfPresent([String].self, forKey: .links)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
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
        modes.first { $0.name == name } ?? modes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
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
