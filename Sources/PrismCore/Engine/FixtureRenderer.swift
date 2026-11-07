import Foundation

/// Renders a device-independent `FixtureState` into DMX channel values for a fixture's mode.
///
/// One pass over the mode's channels per call. Colour analysis (linear target, xy, CCT, Duv) is
/// memoised by quantised colour, emitter levels are solved once per distinct cell colour, and
/// `render(_:fixture:safety:time:into:)` writes into a caller-owned buffer without allocating.
public enum FixtureRenderer {

    // MARK: - Hysteresis State Tracking (fixtures that must switch engines)

    private struct HysteresisKey: Hashable, Sendable {
        var fixtureID: UUID
        var cell: Int
    }

    private static let nativeWhiteHistory = Locked<[HysteresisKey: Bool]>([:])

    /// Clears any cached native-white hysteresis state (useful for deterministic testing).
    public static func resetHysteresisState() {
        nativeWhiteHistory.value = [:]
    }

    private static func previousNativeWhite(fixtureID: UUID, cell: Int) -> Bool {
        nativeWhiteHistory.mutate { $0[HysteresisKey(fixtureID: fixtureID, cell: cell)] ?? false }
    }

    private static func recordNativeWhite(_ isNativeWhite: Bool, fixtureID: UUID, cell: Int) {
        let key = HysteresisKey(fixtureID: fixtureID, cell: cell)
        nativeWhiteHistory.mutate { dict in
            if dict[key] != isNativeWhite {
                if dict.count >= 16_384 { dict.removeAll(keepingCapacity: true) }
                dict[key] = isNativeWhite
            }
        }
    }

    // MARK: - Per-render plan

    /// Channel-layout facts gathered in one pass over the mode.
    private struct Topology {
        var globalEmitters = EmitterMask()
        var cellEmitters = EmitterMask()
        var hasGlobalIntensity = false
        var hasCellIntensity = false
        var hasCells = false
        var hasCCT = false
        var hasTint = false
        var hasCrossfade = false
        var hasHue = false
        var hasCIEX = false
        var hasCIEY = false
        /// A non-cell channel needs the fixture-level colour (emitters, CCT, tint, HSI, xy, mode…).
        var globalNeedsColor = false
        /// Some emitter channel carries its own `emitter` spec override.
        var hasChannelSpecs = false
        var firstCCTPhysical: PhysicalRange?
    }

    /// Everything about one colour in one scope (whole fixture or one cell) the channels need.
    private struct Scope {
        var color: LightColor
        var analysis: ColorAnalysis
        var cellIntensity: Double
        /// Share of output from the native CCT engine: 0 = all RGB/colour … 1 = all CCT white.
        var share: Double
        var levels: EmitterLevels
        /// Kelvin and Prism tint (+ = magenta) for CCT/tint channels, white-point trim applied.
        var kelvin: Double
        var tint: Double

        static let placeholder = Scope(
            color: .kelvin(5600, tint: 0), analysis: .placeholder, cellIntensity: 1,
            share: 0, levels: EmitterLevels(), kelvin: 5600, tint: 0
        )
    }

    /// Per-render constants shared by every channel of the fixture.
    private struct Frame {
        var topo: Topology
        var plan: MixPlan
        var limits: FixtureLimits
        var calibration: ColorCalibration
        var fixtureID: UUID
        var rawMaster: Double
        var master: Double
        var hasRGB: Bool
        var canDoColor: Bool
        /// Has a CCT channel and can make colour but no crossfade channel: switches engines
        /// discretely, with hysteresis.
        var discrete: Bool
        var needCCT: Bool
        var cctRange: ClosedRange<Double>
        var strobeHz: Double

        func scope(color raw: LightColor, cellIntensity: Double, emitters: EmitterMask, cellKey: Int) -> Scope {
            let color = plan.trimmed(raw)
            let a = ColorAnalysis.of(color, includeCCT: needCCT)
            var kelvin = 5600.0
            var tint = 0.0
            if case .kelvin(let k, let t) = color {
                kelvin = clamp(k.finiteOr(5600), 1000, 25000)
                tint = clamp(t.finiteOr(0), -1, 1)
            } else if a.hasCCT && !a.isBlack {
                kelvin = clamp(a.kelvin + plan.kelvinTrim, 1000, 25000)
                tint = clamp(ColorMath.duvToTint(a.duv) + plan.tintTrim, -1, 1)
            }

            var share = 0.0
            if topo.hasCCT {
                if !canDoColor {
                    share = 1
                } else if a.isBlack {
                    share = 0
                } else if topo.hasCrossfade {
                    share = EmitterMixer.nativeWhiteShare(kelvin: kelvin, duv: a.duv, cctRange: cctRange)
                } else {
                    let previous = FixtureRenderer.previousNativeWhite(fixtureID: fixtureID, cell: cellKey)
                    let native = EmitterMixer.shouldUseNativeWhiteFast(
                        for: color, hasCCT: true, canDoColor: true,
                        cctRange: cctRange, previouslyNativeWhite: previous
                    )
                    if native != previous {
                        FixtureRenderer.recordNativeWhite(native, fixtureID: fixtureID, cell: cellKey)
                    }
                    share = native ? 1 : 0
                }
            }

            let levels = (share >= 1 || emitters.isEmpty)
                ? EmitterLevels()
                : plan.levels(for: color, analysis: a, emitters: emitters)
            return Scope(
                color: color, analysis: a, cellIntensity: clamp01(cellIntensity.finiteOr(1)),
                share: share, levels: levels, kelvin: kelvin, tint: tint
            )
        }
    }

    // MARK: - Main Render Entry Points

    /// Returns `mode.channelCount` DMX values.
    public static func render(
        _ state: FixtureState,
        fixture rf: ResolvedFixture,
        safety: SafetySettings = SafetySettings(),
        time: Double = 0
    ) -> [UInt8] {
        let count = rf.mode.channels.count
        guard count > 0 else { return [] }
        var values = [UInt8](repeating: 0, count: count)
        values.withUnsafeMutableBufferPointer { buffer in
            _ = render(state, fixture: rf, safety: safety, time: time, into: buffer)
        }
        return values
    }

    /// Renders into `out` (index 0 = the fixture's first channel) without allocating.
    /// Writes `min(mode.channelCount, out.count)` channels and returns that count.
    @discardableResult
    public static func render(
        _ state: FixtureState,
        fixture rf: ResolvedFixture,
        safety: SafetySettings = SafetySettings(),
        time: Double = 0,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) -> Int {
        let mode = rf.mode
        let channels = mode.channels
        let count = min(channels.count, out.count)
        guard count > 0 else { return 0 }

        // 1. One scan: defaults + topology.
        var topo = Topology()
        var specHasher = Hasher()
        for idx in 0..<count {
            let ch = channels[idx]
            out[idx] = ch.defaultValue
            let kind = ch.kind
            if let spec = ch.emitter, kind.isEmitter {
                topo.hasChannelSpecs = true
                specHasher.combine(kind)
                specHasher.combine(spec)
            }
            switch kind {
            case .cct:
                topo.hasCCT = true
                if topo.firstCCTPhysical == nil { topo.firstCCTPhysical = ch.physical }
            case .tint: topo.hasTint = true
            case .crossfade: topo.hasCrossfade = true
            case .hue: topo.hasHue = true
            case .cieX: topo.hasCIEX = true
            case .cieY: topo.hasCIEY = true
            default: break
            }
            if ch.cell == nil {
                if kind == .intensity {
                    topo.hasGlobalIntensity = true
                } else if kind.isEmitter {
                    topo.globalEmitters.insert(EmitterMask.bit(for: kind))
                    topo.globalNeedsColor = true
                } else {
                    switch kind {
                    case .cct, .tint, .crossfade, .hue, .saturation, .cieX, .cieY, .colorMode:
                        topo.globalNeedsColor = true
                    default: break
                    }
                }
            } else {
                topo.hasCells = true
                if kind == .intensity {
                    topo.hasCellIntensity = true
                } else if kind.isEmitter {
                    topo.cellEmitters.insert(EmitterMask.bit(for: kind))
                }
            }
        }

        let allEmitters = topo.globalEmitters.union(topo.cellEmitters)
        let hasRGB = allEmitters.isSuperset(of: .rgb)
        let canDoColor = hasRGB || topo.hasHue || (topo.hasCIEX && topo.hasCIEY) || allEmitters.isSuperset(of: .cmy)
        let whitesOnly = !hasRGB && !allEmitters.isEmpty && allEmitters.isSubset(of: EmitterMixer.whiteEmitters)
        let limits = rf.fixture.limits
        let calibration = rf.fixture.calibration
        let rawMaster = clamp01(state.intensity.finiteOr(0))
        let profile: MixerProfile
        if topo.hasChannelSpecs {
            specHasher.combine(rf.definition.emitters)
            profile = MixerProfile.profile(definition: rf.definition, mode: mode, specHash: specHasher.finalize())
        } else {
            profile = MixerProfile.profile(for: rf.definition.emitters)
        }

        let frame = Frame(
            topo: topo,
            plan: MixPlan(profile: profile, calibration: calibration, mode: rf.mixingMode),
            limits: limits,
            calibration: calibration,
            fixtureID: rf.id,
            rawMaster: rawMaster,
            master: applyDimmerAndLimits(raw: rawMaster, limits: limits, calibration: calibration),
            hasRGB: hasRGB,
            canDoColor: canDoColor,
            discrete: topo.hasCCT && canDoColor && !topo.hasCrossfade,
            needCCT: topo.hasCCT || topo.hasTint || whitesOnly,
            cctRange: cctRange(definition: rf.definition, firstPhysical: topo.firstCCTPhysical),
            strobeHz: limits.allowStrobe
                ? min(max(0, state.strobeHz.finiteOr(0)), max(0, safety.effectiveMaxStrobeHz.finiteOr(0)))
                : 0
        )

        // 2. Scopes: the whole fixture, a uniform pixel colour, or per cell (reused for runs of
        // identical cell colours).
        let globalScope = topo.globalNeedsColor
            ? frame.scope(color: state.color, cellIntensity: 1, emitters: topo.globalEmitters, cellKey: -1)
            : Scope.placeholder
        let uniformCells = topo.hasCells && !state.hasPixelData
        var cellScope = uniformCells
            ? frame.scope(color: state.color, cellIntensity: 1, emitters: topo.cellEmitters, cellKey: 0)
            : Scope.placeholder
        var currentCell = Int.min
        var lastCellColor: LightColor?
        let cellCount = mode.cellCount
        let reverse = rf.fixture.reversePixels

        // 3. Channels.
        var i = 0
        while i < count {
            let ch = channels[i]
            if ch.fine {
                i += 1
                continue // written together with its preceding coarse channel
            }
            var fineIndex = -1
            if i + 1 < count {
                let next = channels[i + 1]
                if next.fine && next.kind == ch.kind && next.cell == ch.cell { fineIndex = i + 1 }
            }
            if let cell = ch.cell {
                if !uniformCells && cell != currentCell {
                    currentCell = cell
                    let logical = reverse ? max(0, cellCount - 1 - cell) : cell
                    let cs = state.cell(logical)
                    if !frame.discrete, let last = lastCellColor, last == cs.color {
                        cellScope.cellIntensity = clamp01(cs.intensity.finiteOr(1))
                    } else {
                        cellScope = frame.scope(
                            color: cs.color, cellIntensity: cs.intensity,
                            emitters: topo.cellEmitters, cellKey: logical
                        )
                        lastCellColor = cs.color
                    }
                }
                writeChannel(ch, at: i, fine: fineIndex, scope: cellScope, isCell: true, frame: frame, into: out)
            } else {
                writeChannel(ch, at: i, fine: fineIndex, scope: globalScope, isCell: false, frame: frame, into: out)
            }
            i += 1
        }

        // 4. Raw overrides last.
        if let raw = state.raw {
            for (idx, v) in raw where idx >= 0 && idx < count {
                out[idx] = v
            }
        }
        return count
    }

    // MARK: - Channel writers

    private static func writeChannel(
        _ ch: ChannelDefinition,
        at i: Int,
        fine: Int,
        scope sc: Scope,
        isCell: Bool,
        frame f: Frame,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) {
        var fraction: Double?

        switch ch.kind {
        case .intensity:
            if isCell {
                if f.topo.hasGlobalIntensity {
                    fraction = (f.calibration.dimmerCurve ?? f.limits.dimmerCurve).apply(sc.cellIntensity)
                } else {
                    fraction = applyDimmerAndLimits(
                        raw: f.rawMaster * sc.cellIntensity,
                        limits: f.limits,
                        calibration: f.calibration
                    )
                }
            } else {
                fraction = f.master
            }

        case let k where k.isEmitter:
            if sc.share >= 1 {
                fraction = 0
            } else if isCell {
                let scale: Double
                if f.topo.hasCellIntensity {
                    // Cell has its own dedicated intensity channel (e.g. PT4c Light Engine).
                    scale = 1.0
                } else if f.topo.hasGlobalIntensity {
                    // Fixture has a global intensity channel (e.g. B1 pixel tube); scale by cell intensity.
                    scale = sc.cellIntensity
                } else {
                    // Raw emitter-only pixel strip (no dimmer channel at all).
                    scale = sc.cellIntensity * f.master
                }
                fraction = sc.levels[k] * scale
            } else {
                fraction = sc.levels[k] * (f.topo.hasGlobalIntensity ? 1.0 : f.master)
            }

        case .cct:
            if f.topo.hasCrossfade && sc.share <= 0 {
                // 100 % RGB (`crossfade = 255`): leave CCT at 0.
                fraction = 0
            } else {
                var k = sc.kelvin
                if f.discrete && sc.share < 0.5 && abs(sc.analysis.duv) > 0.03 {
                    k = 5600 // colour mode on a switching fixture: park CCT at daylight
                }
                let lo = f.limits.minKelvin ?? 1700
                let hi = max(lo, f.limits.maxKelvin ?? 20000)
                k = clamp(k, lo, hi)
                if let p = ch.physical {
                    fraction = p.fraction(for: k)
                } else {
                    fraction = PhysicalRange(from: f.cctRange.lowerBound, to: f.cctRange.upperBound).fraction(for: k)
                }
            }

        case .tint:
            // Channel convention: -1 = full minus green (magenta) … +1 = full plus green.
            let physical = sc.share > 0 ? ColorMath.tintToSidusGM(sc.tint) : 0
            if let caps = ch.capabilities, !caps.isEmpty {
                if i < out.count { out[i] = ch.dmxValue(forPhysical: physical) }
            } else {
                fraction = (ch.physical ?? PhysicalRange(from: -1, to: 1)).fraction(for: physical)
            }

        case .crossfade:
            // 0 = native white (CCT), 1 = color (RGB/HSI); blends smoothly in between.
            fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: 1 - sc.share)

        case .hue:
            let h: Double
            if case .hsi(let hue, _) = sc.color { h = wrapDegrees(hue.finiteOr(0)) } else { h = sc.analysis.display.hsv.h }
            fraction = (ch.physical ?? PhysicalRange(from: 0, to: 360)).fraction(for: h)

        case .saturation:
            let s: Double
            if case .hsi(_, let sat) = sc.color { s = clamp01(sat.finiteOr(1)) } else { s = sc.analysis.display.hsv.s }
            fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: s)

        case .cieX:
            fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: sc.analysis.x)

        case .cieY:
            fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: sc.analysis.y)

        case .colorMode:
            let cap: ChannelCapability?
            if sc.share >= 0.5 {
                cap = ch.capability(tagged: "cct")
            } else if f.hasRGB {
                cap = ch.capability(tagged: "rgb") ?? ch.capability(tagged: "rgbw") ?? ch.capability(tagged: "hsi")
            } else {
                cap = ch.capability(tagged: "hsi") ?? ch.capability(tagged: "xy")
            }
            if let cap, i < out.count { out[i] = cap.centerValue }

        case .strobe, .shutter:
            let hz = f.strobeHz
            if hz > 0.05 {
                if let cap = ch.capability(tagged: "strobe") {
                    let fr: Double
                    if let ph = cap.physical, ph.count >= 2, ph[1] != ph[0] {
                        fr = clamp01((hz - ph[0]) / (ph[1] - ph[0]))
                    } else {
                        fr = clamp01(hz / 20.0)
                    }
                    let dmx = Double(cap.from) + fr.finiteOr(0) * Double(cap.to - cap.from)
                    if i < out.count { out[i] = UInt8(clamp(Int(dmx.rounded()), 0, 255)) }
                } else if let p = ch.physical {
                    fraction = p.fraction(for: hz)
                } else {
                    fraction = clamp01(hz / 20.0)
                }
            } else if ch.kind == .shutter {
                if let open = ch.capability(tagged: "open") ?? ch.capability(tagged: "off"), i < out.count {
                    out[i] = UInt8(clamp(open.from, 0, 255))
                }
            } else if i < out.count {
                if let off = ch.capability(tagged: "off") ?? ch.capability(tagged: "open") {
                    out[i] = UInt8(clamp(off.from, 0, 255))
                } else {
                    out[i] = 0
                }
            }

        case .effect, .effectSpeed, .effectParameter:
            // Effect channels are zeroed by default (or set to their "off"/"none" capability).
            if i < out.count {
                if let offCap = ch.capability(tagged: "off") ?? ch.capability(tagged: "none") {
                    out[i] = UInt8(clamp(offCap.from, 0, 255))
                } else {
                    out[i] = 0
                }
            }

        default:
            break
        }

        if let fr = fraction {
            write(fraction: fr, channel: ch, coarseIndex: i, fineIndex: fine, into: out)
        }
    }

    /// CCT range used when a CCT channel has no physical mapping and for the native-white share.
    private static func cctRange(definition: FixtureDefinition, firstPhysical: PhysicalRange?) -> ClosedRange<Double> {
        if let r = definition.cctRange, r.count >= 2, r[0].isFinite, r[1].isFinite {
            let lo = min(r[0], r[1]), hi = max(r[0], r[1])
            if hi > lo { return lo...hi }
        }
        if let p = firstPhysical, p.from.isFinite, p.to.isFinite {
            let lo = min(p.from, p.to), hi = max(p.from, p.to)
            if hi > lo { return lo...hi }
        }
        return 2700...6500
    }

    // MARK: - Dimmer Curve & Minimum-Level Helper

    @inline(__always)
    static func applyDimmerAndLimits(
        raw: Double,
        limits: FixtureLimits,
        calibration: ColorCalibration
    ) -> Double {
        let r = clamp01(raw.finiteOr(0))
        guard r > 0 else { return 0 }
        let curve = calibration.dimmerCurve ?? limits.dimmerCurve
        let curved = curve.apply(r)
        let minI = clamp01(limits.minIntensity.finiteOr(0))
        let maxI = max(minI, clamp01(limits.maxIntensity.finiteOr(1)))
        var out = lerp(minI, maxI, curved)
        if limits.neverFullyOffUnlessZero && maxI > 0 {
            out = max(out, max(minI, 1.0 / 255.0))
        }
        return clamp01(out)
    }

    /// Writes a 0…1 fraction into a channel (and its fine partner, `fineIndex >= 0`) honouring the
    /// channel's DMX range. Out-of-range indices are ignored.
    @inline(__always)
    static func write(
        fraction: Double,
        channel ch: ChannelDefinition,
        coarseIndex: Int,
        fineIndex: Int,
        into out: UnsafeMutableBufferPointer<UInt8>
    ) {
        guard coarseIndex >= 0, coarseIndex < out.count else { return }
        let f = clamp01(fraction.finiteOr(0))
        let lo = Double(clamp(ch.physical?.dmxFrom ?? 0, 0, 255))
        let hi = Double(clamp(ch.physical?.dmxTo ?? 255, 0, 255))
        if fineIndex >= 0, fineIndex < out.count {
            let lo16 = lo * 257.0
            let hi16 = hi * 257.0
            let c = clamp(Int((lo16 + f * (hi16 - lo16)).rounded()), 0, 65535)
            out[coarseIndex] = UInt8(c >> 8)
            out[fineIndex] = UInt8(c & 0xFF)
        } else {
            out[coarseIndex] = UInt8(clamp(Int((lo + f * (hi - lo)).rounded()), 0, 255))
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
