import Foundation

/// Renders a device-independent `FixtureState` into DMX channel values for a fixture's mode.
public enum FixtureRenderer {

    // MARK: - Hysteresis State Tracking

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
        nativeWhiteHistory.value[HysteresisKey(fixtureID: fixtureID, cell: cell)] ?? false
    }

    private static func recordNativeWhite(_ isNativeWhite: Bool, fixtureID: UUID, cell: Int) {
        let key = HysteresisKey(fixtureID: fixtureID, cell: cell)
        nativeWhiteHistory.mutate { dict in
            if dict[key] != isNativeWhite {
                dict[key] = isNativeWhite
            }
        }
    }

    // MARK: - Precomputed Context per Scope (Global or Cell)

    private struct ScopeContext {
        var color: LightColor
        var cellIntensity: Double
        var useNativeWhite: Bool
        var levels: EmitterLevels
        var kelvin: Double
        var tint: Double
    }

    // MARK: - Main Render Entry Point

    /// Returns `mode.channelCount` DMX values.
    public static func render(
        _ state: FixtureState,
        fixture rf: ResolvedFixture,
        safety: SafetySettings = SafetySettings(),
        time: Double = 0
    ) -> [UInt8] {
        let mode = rf.mode
        let channels = mode.channels
        let count = channels.count
        guard count > 0 else { return [] }

        var values = [UInt8](repeating: 0, count: count)

        let limits = rf.fixture.limits
        let calibration = rf.fixture.calibration
        let customEmitters = rf.definition.emitters

        // Single zero-allocation scan over channels to initialize defaults and inspect topology.
        var globalEmitterMask = EmitterMask()
        var cellEmitterMask = EmitterMask()
        var hasGlobalIntensityChannel = false
        var hasCellIntensityChannel = false
        var hasCCT = false
        var hasTint = false
        var hasCrossfade = false
        var hasHSI = false
        var hasCIEX = false
        var hasCIEY = false
        var firstCCTPhysical: PhysicalRange? = nil

        for idx in 0..<count {
            let ch = channels[idx]
            values[idx] = ch.defaultValue
            switch ch.kind {
            case .cct:
                hasCCT = true
                if firstCCTPhysical == nil { firstCCTPhysical = ch.physical }
            case .tint:
                hasTint = true
            case .crossfade:
                hasCrossfade = true
            case .hue:
                hasHSI = true
            case .cieX:
                hasCIEX = true
            case .cieY:
                hasCIEY = true
            default:
                break
            }
            if ch.cell == nil {
                if ch.kind == .intensity {
                    hasGlobalIntensityChannel = true
                } else if ch.kind.isEmitter {
                    globalEmitterMask.insert(EmitterMask.bit(for: ch.kind))
                }
            } else {
                if ch.kind == .intensity {
                    hasCellIntensityChannel = true
                } else if ch.kind.isEmitter {
                    cellEmitterMask.insert(EmitterMask.bit(for: ch.kind))
                }
            }
        }

        let allEmitters = globalEmitterMask.union(cellEmitterMask)
        let hasRGB = allEmitters.isSuperset(of: .rgb)
        let hasXY = hasCIEX && hasCIEY
        let canDoColor = hasRGB || hasHSI || hasXY || allEmitters.isSuperset(of: .cmy)

        let defaultCCTRange: ClosedRange<Double> = {
            if let r = rf.definition.cctRange, r.count >= 2 {
                let lo = min(r[0], r[1]), hi = max(r[0], r[1])
                if hi > lo { return lo...hi }
            }
            if let p = firstCCTPhysical {
                let lo = min(p.from, p.to), hi = max(p.from, p.to)
                if hi > lo { return lo...hi }
            }
            return 2700...6500
        }()

        // Master intensity with dimmer curve, min/max limits, and key-light keep-alive option.
        let rawMaster = clamp01(state.intensity.finiteOr(0))
        let master = applyDimmerAndLimits(raw: rawMaster, limits: limits, calibration: calibration)

        let needsCCTMath = hasCCT || hasTint

        // Helper to build a `ScopeContext` for either the whole fixture or a single cell.
        @inline(__always)
        func buildScopeContext(
            color: LightColor,
            cellIntensity: Double,
            emitterMask: EmitterMask,
            cellKey: Int
        ) -> ScopeContext {
            let prevNW = hasCCT ? previousNativeWhite(fixtureID: rf.id, cell: cellKey) : false
            let useNW = hasCCT
                ? EmitterMixer.shouldUseNativeWhiteFast(
                    for: color,
                    hasCCT: hasCCT,
                    canDoColor: canDoColor,
                    cctRange: defaultCCTRange,
                    previouslyNativeWhite: prevNW
                )
                : false
            if hasCCT && useNW != prevNW {
                recordNativeWhite(useNW, fixtureID: rf.id, cell: cellKey)
            }

            let levels: EmitterLevels
            if useNW || emitterMask.isEmpty {
                levels = EmitterLevels()
            } else {
                levels = EmitterMixer.mixFast(
                    color,
                    emitters: emitterMask,
                    emitterSpecs: customEmitters,
                    calibration: calibration
                )
            }

            var k = 5600.0
            var t = 0.0
            if needsCCTMath {
                if case .kelvin(let ck, let ct) = color {
                    k = ck
                    t = ct
                } else if useNW || !hasCrossfade {
                    let approx = color.approximateKelvin
                    k = approx.kelvin
                    t = approx.tint
                }
            }

            return ScopeContext(
                color: color,
                cellIntensity: clamp01(cellIntensity.finiteOr(1)),
                useNativeWhite: useNW,
                levels: levels,
                kelvin: k,
                tint: t
            )
        }

        // Precompute global context (when global color/emitter channels exist or when pixels are uniform).
        let globalContext = buildScopeContext(
            color: state.color,
            cellIntensity: 1.0,
            emitterMask: globalEmitterMask,
            cellKey: -1
        )

        // When a pixel fixture has uniform color (`!state.hasPixelData`), compute the cell context ONCE
        // and reuse it across all cells!
        let uniformCellContext: ScopeContext? = (!state.hasPixelData && mode.cellCount > 0)
            ? buildScopeContext(
                color: state.color,
                cellIntensity: 1.0,
                emitterMask: cellEmitterMask,
                cellKey: 0
            )
            : nil

        // Per-cell cache when `state.hasPixelData` is true.
        var cachedCellIndex: Int = -999
        var cachedCellContext: ScopeContext = globalContext

        var i = 0
        while i < count {
            let ch = channels[i]
            if ch.fine {
                i += 1
                continue // written together with its preceding coarse channel
            }
            let fineIndex: Int? = (
                i + 1 < count &&
                channels[i + 1].fine &&
                channels[i + 1].kind == ch.kind &&
                channels[i + 1].cell == ch.cell
            ) ? (i + 1) : nil

            let isCellChannel = (ch.cell != nil)
            let ctx: ScopeContext
            if let cell = ch.cell {
                if let uniform = uniformCellContext {
                    ctx = uniform
                } else if cell == cachedCellIndex {
                    ctx = cachedCellContext
                } else {
                    let logicalCell = rf.fixture.reversePixels ? max(0, mode.cellCount - 1 - cell) : cell
                    let cs = state.cell(logicalCell)
                    let built = buildScopeContext(
                        color: cs.color,
                        cellIntensity: cs.intensity,
                        emitterMask: cellEmitterMask,
                        cellKey: logicalCell
                    )
                    cachedCellIndex = cell
                    cachedCellContext = built
                    ctx = built
                }
            } else {
                ctx = globalContext
            }

            var fraction: Double? = nil

            switch ch.kind {
            case .intensity:
                if isCellChannel {
                    if hasGlobalIntensityChannel {
                        fraction = calibration.dimmerCurve?.apply(ctx.cellIntensity)
                            ?? limits.dimmerCurve.apply(ctx.cellIntensity)
                    } else {
                        fraction = applyDimmerAndLimits(
                            raw: rawMaster * ctx.cellIntensity,
                            limits: limits,
                            calibration: calibration
                        )
                    }
                } else {
                    fraction = master
                }

            case let k where k.isEmitter:
                if ctx.useNativeWhite {
                    fraction = 0
                } else if isCellChannel {
                    let scale: Double
                    if hasCellIntensityChannel {
                        // Cell has its own dedicated intensity channel (e.g. PT4c Light Engine).
                        scale = 1.0
                    } else if hasGlobalIntensityChannel {
                        // Fixture has a global intensity channel (e.g. B1 pixel tube); scale by cell intensity.
                        scale = ctx.cellIntensity
                    } else {
                        // Raw emitter-only pixel strip (no dimmer channel at all).
                        scale = ctx.cellIntensity * master
                    }
                    fraction = ctx.levels[k] * scale
                } else {
                    let scale = hasGlobalIntensityChannel ? 1.0 : master
                    fraction = ctx.levels[k] * scale
                }

            case .cct:
                if !ctx.useNativeWhite && hasCrossfade {
                    // When crossfade selects 100% RGB (`crossfade = 255`), leave CCT at 0.
                    fraction = 0
                } else {
                    let rawK = ctx.useNativeWhite ? ctx.kelvin : (ctx.color.isWhiteish ? ctx.kelvin : 5600)
                    let trimmedK = clamp(rawK + calibration.whitePointKelvinTrim.finiteOr(0), 1700, 20000)
                    if let p = ch.physical {
                        fraction = p.fraction(for: trimmedK)
                    } else {
                        fraction = PhysicalRange(
                            from: defaultCCTRange.lowerBound,
                            to: defaultCCTRange.upperBound
                        ).fraction(for: trimmedK)
                    }
                }

            case .tint:
                let rawT = ctx.useNativeWhite
                    ? clamp(ctx.tint + calibration.whitePointTintTrim.finiteOr(0), -1, 1)
                    : 0
                if let capList = ch.capabilities, !capList.isEmpty {
                    values[i] = ch.dmxValue(forPhysical: rawT)
                } else {
                    fraction = (ch.physical ?? PhysicalRange(from: -1, to: 1)).fraction(for: rawT)
                }

            case .crossfade:
                // 0 = native white (CCT), 1 = color (RGB/HSI).
                let p = ch.physical ?? PhysicalRange(from: 0, to: 1)
                fraction = p.fraction(for: ctx.useNativeWhite ? 0 : 1)

            case .hue:
                let hsv = ctx.color.displayRGB.hsv
                fraction = (ch.physical ?? PhysicalRange(from: 0, to: 360)).fraction(for: hsv.h)

            case .saturation:
                let sat: Double = {
                    if case .hsi(_, let s) = ctx.color { return s }
                    return ctx.color.displayRGB.hsv.s
                }()
                fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: sat)

            case .cieX:
                let xy = ctx.color.xy
                fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: xy.x)

            case .cieY:
                let xy = ctx.color.xy
                fraction = (ch.physical ?? PhysicalRange(from: 0, to: 1)).fraction(for: xy.y)

            case .colorMode:
                let wanted: [String] = ctx.useNativeWhite
                    ? ["cct"]
                    : (hasRGB ? ["rgb", "rgbw", "hsi"] : ["hsi", "xy"])
                if let cap = wanted.lazy.compactMap({ ch.capability(tagged: $0) }).first {
                    values[i] = cap.centerValue
                }

            case .strobe, .shutter:
                let maxHz = max(0, safety.effectiveMaxStrobeHz.finiteOr(0))
                let hz = limits.allowStrobe ? min(max(0, state.strobeHz.finiteOr(0)), maxHz) : 0
                if hz > 0.05 {
                    if let cap = ch.capability(tagged: "strobe") {
                        if let ph = cap.physical, ph.count >= 2, ph[1] != ph[0] {
                            let f = clamp01((hz - ph[0]) / (ph[1] - ph[0]))
                            values[i] = UInt8(clamp(Int((Double(cap.from) + f * Double(cap.to - cap.from)).rounded()), 0, 255))
                        } else {
                            let f = clamp01(hz / 20.0)
                            values[i] = UInt8(clamp(Int((Double(cap.from) + f * Double(cap.to - cap.from)).rounded()), 0, 255))
                        }
                    } else if let p = ch.physical {
                        fraction = p.fraction(for: hz)
                    } else {
                        fraction = clamp01(hz / 20.0)
                    }
                } else if ch.kind == .shutter {
                    if let open = ch.capability(tagged: "open") ?? ch.capability(tagged: "off") {
                        values[i] = UInt8(open.from)
                    }
                } else {
                    if let off = ch.capability(tagged: "off") ?? ch.capability(tagged: "open") {
                        values[i] = UInt8(off.from)
                    } else {
                        values[i] = 0
                    }
                }

            case .effect, .effectSpeed, .effectParameter:
                // Effect channels are zeroed by default (or set to their "off"/"none" capability).
                if let offCap = ch.capability(tagged: "off") ?? ch.capability(tagged: "none") {
                    values[i] = UInt8(offCap.from)
                } else {
                    values[i] = 0
                }

            default:
                break
            }

            if let f = fraction {
                write(fraction: f, channel: ch, coarseIndex: i, fineIndex: fineIndex, into: &values)
            }
            i += 1
        }

        // Raw overrides last.
        if let raw = state.raw {
            for (idx, v) in raw where idx >= 0 && idx < values.count {
                values[idx] = v
            }
        }
        return values
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

    /// Writes a 0…1 fraction into a channel (and its fine partner) honouring the channel's DMX range.
    @inline(__always)
    static func write(
        fraction: Double,
        channel ch: ChannelDefinition,
        coarseIndex: Int,
        fineIndex: Int?,
        into values: inout [UInt8]
    ) {
        let f = clamp01(fraction.finiteOr(0))
        let lo = Double(ch.physical?.dmxFrom ?? 0)
        let hi = Double(ch.physical?.dmxTo ?? 255)
        if let fi = fineIndex {
            let lo16 = lo * 257.0
            let hi16 = hi * 257.0
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
