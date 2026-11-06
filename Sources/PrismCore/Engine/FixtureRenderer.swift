import Foundation

/// Renders a device-independent `FixtureState` into DMX channel values for a fixture's mode.
public enum FixtureRenderer {

    /// Returns `mode.channelCount` DMX values.
    public static func render(_ state: FixtureState, fixture rf: ResolvedFixture, safety: SafetySettings = SafetySettings(),
                              time: Double = 0) -> [UInt8] {
        let mode = rf.mode
        let channels = mode.channels
        var values = channels.map { $0.defaultValue }
        guard !channels.isEmpty else { return values }

        let caps = mode.capabilities
        let limits = rf.fixture.limits
        let calibration = rf.fixture.calibration

        // Master intensity with limits.
        var master = clamp01(state.intensity.finiteOr(0))
        if master > 0 {
            master = lerp(clamp01(limits.minIntensity), clamp01(limits.maxIntensity), master)
        }

        // Decide whether the fixture's whole-fixture color should be produced by native white (CCT)
        // channels or by color emitters.
        let globalEmitters = Set(channels.filter { $0.cell == nil && $0.kind.isEmitter }.map(\.kind))
        let useNativeWhite: Bool = {
            guard caps.hasCCT else { return false }
            if case .kelvin = state.color { return true }
            // CCT-only fixtures: always native white.
            return globalEmitters.isEmpty && !caps.hasHSI && !caps.hasXY && !state.hasPixelData
        }()

        let hasDimmer = caps.hasIntensity
        let emitterScale = hasDimmer ? 1.0 : master

        // --- Whole-fixture channels ---
        let globalLevels: [ChannelKind: Double] = useNativeWhite
            ? [:]
            : EmitterMixer.mix(state.color, emitters: globalEmitters, calibration: calibration)

        let (kelvin, tint) = state.color.approximateKelvin
        let hsv = state.color.displayRGB.hsv
        let xy = state.color.xy

        var i = 0
        while i < channels.count {
            let ch = channels[i]
            if ch.fine { i += 1; continue } // written together with its coarse channel
            let fineIndex = (i + 1 < channels.count && channels[i + 1].fine && channels[i + 1].kind == ch.kind && channels[i + 1].cell == ch.cell) ? i + 1 : nil

            var fraction: Double? = nil
            if let cell = ch.cell {
                // Per-pixel channel.
                let cellIndex = rf.fixture.reversePixels ? max(0, mode.cellCount - 1 - cell) : cell
                let cs = state.cell(cellIndex)
                if ch.kind.isEmitter {
                    let cellEmitters = mode.emitterKinds(forCell: cell)
                    let levels = EmitterMixer.mix(cs.color, emitters: cellEmitters, calibration: calibration)
                    fraction = (levels[ch.kind] ?? 0) * clamp01(cs.intensity) * emitterScale
                } else if ch.kind == .intensity {
                    fraction = clamp01(cs.intensity) * (hasGlobalIntensity(mode) ? 1 : master)
                }
            } else {
                switch ch.kind {
                case .intensity:
                    fraction = master
                case let k where k.isEmitter:
                    fraction = (globalLevels[k] ?? 0) * emitterScale
                    if useNativeWhite { fraction = 0 }
                case .cct:
                    let k = useNativeWhite ? kelvin : (state.color.isWhiteish ? kelvin : 5600)
                    if let p = ch.physical {
                        fraction = p.fraction(for: k)
                    } else if let range = rf.definition.cctRange, range.count == 2 {
                        fraction = PhysicalRange(from: range[0], to: range[1]).fraction(for: k)
                    } else {
                        fraction = PhysicalRange(from: 2700, to: 6500).fraction(for: k)
                    }
                case .tint:
                    let t = useNativeWhite ? tint : 0
                    fraction = (ch.physical ?? PhysicalRange(from: -1, to: 1)).fraction(for: t)
                case .crossfade:
                    // 0 = native white (CCT), 1 = color.
                    let p = ch.physical ?? PhysicalRange(from: 0, to: 1)
                    fraction = p.fraction(for: useNativeWhite ? 0 : 1)
                case .hue:
                    fraction = (ch.physical ?? PhysicalRange(from: 0, to: 360)).fraction(for: hsv.h)
                case .saturation:
                    let sat: Double = {
                        if case .hsi(_, let s) = state.color { return s }
                        return hsv.s
                    }()
                    fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: sat)
                case .cieX:
                    fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: xy.x)
                case .cieY:
                    fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: xy.y)
                case .colorMode:
                    let wanted: [String] = useNativeWhite ? ["cct"] : (caps.hasRGB ? ["rgb", "rgbw", "hsi"] : ["hsi", "xy"])
                    if let cap = wanted.lazy.compactMap({ ch.capability(tagged: $0) }).first {
                        values[i] = cap.centerValue
                    }
                case .strobe, .shutter:
                    let hz = limits.allowStrobe ? min(state.strobeHz, safety.effectiveMaxStrobeHz) : 0
                    if hz > 0.05, let cap = ch.capability(tagged: "strobe") {
                        if let ph = cap.physical, ph.count == 2, ph[1] != ph[0] {
                            let f = clamp01((hz - ph[0]) / (ph[1] - ph[0]))
                            values[i] = UInt8(clamp(Int((Double(cap.from) + f * Double(cap.to - cap.from)).rounded()), 0, 255))
                        } else {
                            values[i] = cap.centerValue
                        }
                    } else if let open = ch.capability(tagged: "open") ?? ch.capability(tagged: "off") {
                        values[i] = UInt8(open.from)
                    }
                default:
                    break
                }
            }

            if let f = fraction {
                write(fraction: f, channel: ch, coarseIndex: i, fineIndex: fineIndex, into: &values)
            }
            i += 1
        }

        // Raw overrides last.
        if let raw = state.raw {
            for (idx, v) in raw where idx >= 0 && idx < values.count { values[idx] = v }
        }
        return values
    }

    /// Writes a 0…1 fraction into a channel (and its fine partner) honouring the channel's DMX range.
    @inline(__always)
    static func write(fraction: Double, channel ch: ChannelDefinition, coarseIndex: Int, fineIndex: Int?, into values: inout [UInt8]) {
        let f = clamp01(fraction.finiteOr(0))
        let lo = Double(ch.physical?.dmxFrom ?? 0), hi = Double(ch.physical?.dmxTo ?? 255)
        if let fi = fineIndex {
            let lo16 = lo * 257, hi16 = hi * 257
            let v = Int((lo16 + f * (hi16 - lo16)).rounded())
            let c = clamp(v, 0, 65535)
            values[coarseIndex] = UInt8(c >> 8)
            values[fi] = UInt8(c & 0xFF)
        } else {
            values[coarseIndex] = UInt8(clamp(Int((lo + f * (hi - lo)).rounded()), 0, 255))
        }
    }

    static func hasGlobalIntensity(_ mode: FixtureMode) -> Bool {
        mode.channels.contains { $0.kind == .intensity && $0.cell == nil }
    }
}

extension FixtureMode {
    /// Emitter kinds available for a given cell.
    public func emitterKinds(forCell cell: Int) -> Set<ChannelKind> {
        Set(channels.filter { $0.cell == cell && $0.kind.isEmitter }.map(\.kind))
    }
}
