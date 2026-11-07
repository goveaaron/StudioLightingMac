import Foundation

/// A number shown for a selection of lights: nothing, one shared value, or a spread.
public enum MixedNumber: Sendable, Hashable {
    /// No lights (or no finite values).
    case none
    /// Every light has (within tolerance) the same value.
    case uniform(Double)
    /// Lights differ; the inspector shows "Mixed" with the range.
    case mixed(min: Double, max: Double)

    public init<S: Sequence>(_ values: S, tolerance: Double = 1e-6) where S.Element == Double {
        var lo = Double.infinity
        var hi = -Double.infinity
        var first: Double?
        for v in values where v.isFinite {
            if first == nil { first = v }
            lo = Swift.min(lo, v)
            hi = Swift.max(hi, v)
        }
        guard let first else {
            self = .none
            return
        }
        self = (hi - lo) <= Swift.max(0, tolerance) ? .uniform(first) : .mixed(min: lo, max: hi)
    }

    /// The shared value, or `nil` when mixed/empty.
    public var value: Double? {
        if case .uniform(let v) = self { return v }
        return nil
    }

    /// True when the lights differ.
    public var isMixed: Bool {
        if case .mixed = self { return true }
        return false
    }

    /// A single value to position a control at: the shared value or the middle of the range.
    public var representative: Double? {
        switch self {
        case .none: return nil
        case .uniform(let v): return v
        case .mixed(let lo, let hi): return (lo + hi) / 2
        }
    }

    /// The span of values (a single point when uniform).
    public var range: ClosedRange<Double>? {
        switch self {
        case .none: return nil
        case .uniform(let v): return v...v
        case .mixed(let lo, let hi): return lo...hi
        }
    }
}

/// A non-numeric property of a selection: nothing, one shared value, or mixed.
public enum MixedValue<T: Hashable & Sendable>: Sendable, Hashable {
    case none
    case uniform(T)
    case mixed

    public init<S: Sequence>(_ values: S) where S.Element == T {
        var first: T?
        for v in values {
            guard let f = first else {
                first = v
                continue
            }
            if f != v {
                self = .mixed
                return
            }
        }
        if let first { self = .uniform(first) } else { self = .none }
    }

    /// The shared value, or `nil` when mixed/empty.
    public var value: T? {
        if case .uniform(let v) = self { return v }
        return nil
    }

    /// True when the lights differ.
    public var isMixed: Bool {
        if case .mixed = self { return true }
        return false
    }
}

/// What the inspector shows for the current selection, aggregated once per render.
public struct InspectorSelectionSummary: Sendable, Hashable {
    /// Number of selected lights.
    public var count: Int
    /// Master intensity 0…1.
    public var intensity: MixedNumber
    /// Colour vs white vs xy.
    public var mode: MixedValue<ColorModeKind>
    /// Whole-light colour.
    public var color: MixedValue<LightColor>
    /// Exact hex of the whole-light colour.
    public var hex: MixedValue<String>
    /// Kelvin of the lights — only when every light is in white mode, otherwise `.none`.
    public var kelvin: MixedNumber
    /// Tint of the lights — same rule as `kelvin`.
    public var tint: MixedNumber
    /// Up to 12 distinct whole-light colours in selection order (for the swatch strip).
    public var distinctColors: [LightColor]
    /// Lights carrying a per-pixel pattern.
    public var pixelPatternCount: Int
    /// Lights that are on (intensity > 0).
    public var lightsOn: Int

    /// Most swatches `distinctColors` keeps.
    public static let maxSwatches = 12

    public init(states: [FixtureState]) {
        count = states.count
        intensity = MixedNumber(states.map(\.intensity), tolerance: 0.0005)
        mode = MixedValue(states.map { ColorModeKind($0.color) })
        color = MixedValue(states.map(\.color))
        hex = MixedValue(states.map { $0.color.sRGB.hex })
        var kelvins: [Double] = []
        var tints: [Double] = []
        var allWhite = !states.isEmpty
        for s in states {
            if case .kelvin(let k, let t) = s.color {
                kelvins.append(k)
                tints.append(t)
            } else {
                allWhite = false
            }
        }
        kelvin = allWhite ? MixedNumber(kelvins, tolerance: 0.5) : .none
        tint = allWhite ? MixedNumber(tints, tolerance: 0.0005) : .none
        var seen = Set<String>()
        var swatches: [LightColor] = []
        for s in states where swatches.count < Self.maxSwatches {
            let key = s.color.label
            if seen.insert(key).inserted { swatches.append(s.color) }
        }
        distinctColors = swatches
        pixelPatternCount = states.filter { ($0.cells?.isEmpty == false) }.count
        lightsOn = states.filter { $0.intensity > 0.0005 }.count
    }

    /// Text for the brightness readout: "72.4%", "Mixed · 35–100%", or "—".
    public var intensityText: String {
        switch intensity {
        case .none: return "—"
        case .uniform(let v): return InspectorFormat.percent(v)
        case .mixed(let lo, let hi):
            return "Mixed · " + InspectorFormat.percent(lo).replacingOccurrences(of: "%", with: "")
                + "–" + InspectorFormat.percent(hi)
        }
    }
}

/// A one-glance summary of the whole rig for the inspector's "nothing selected" page.
public struct RigSummary: Sendable, Hashable {
    /// Lights in the project (hidden ones excluded).
    public var total: Int
    /// Lights with intensity above zero.
    public var lightsOn: Int
    /// Lights without a DMX address.
    public var unpatched: Int
    /// Lights protected from effects/music/remote.
    public var protectedCount: Int
    /// Average brightness of the lights that are on.
    public var averageOnIntensity: Double?
    /// Up to 8 distinct colours of lights that are on, in fixture order.
    public var colors: [LightColor]

    public init(fixtures: [PatchedFixture], states: [UUID: FixtureState]) {
        let visible = fixtures.filter { !$0.hidden }
        total = visible.count
        var on = 0
        var sum = 0.0
        var seen = Set<String>()
        var palette: [LightColor] = []
        for f in visible {
            guard let s = states[f.id], s.intensity > 0.0005 else { continue }
            on += 1
            sum += s.intensity
            if palette.count < 8, seen.insert(s.color.label).inserted { palette.append(s.color) }
        }
        lightsOn = on
        averageOnIntensity = on > 0 ? sum / Double(on) : nil
        unpatched = visible.filter { $0.address == nil }.count
        protectedCount = visible.filter(\.isProtected).count
        colors = palette
    }

    /// "9 lights · 8 on" style headline.
    public var headline: String {
        let lights = total == 1 ? "1 light" : "\(total) lights"
        if total == 0 { return "No lights yet" }
        if lightsOn == 0 { return "\(lights) · all off" }
        if lightsOn == total { return "\(lights) · all on" }
        return "\(lights) · \(lightsOn) on"
    }
}
