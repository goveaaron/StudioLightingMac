import Foundation

/// Applies `LightingCommand`s to a `ShowDocument`. Pure value-type logic (testable anywhere).
public struct CommandExecutor {
    /// External library lookup for definitions not embedded in the project.
    public var library: ((String) -> FixtureDefinition?)?
    /// Clock (overridable in tests).
    public var now: () -> Double
    /// Fade used for changes when no `.fadeTime` command precedes them.
    public var defaultFade: Double
    /// Default curve used for command fades.
    public var defaultCurve: FadeCurve

    public init(library: ((String) -> FixtureDefinition?)? = nil, now: @escaping () -> Double = PrismClock.now,
                defaultFade: Double = 0, defaultCurve: FadeCurve = .easeInOut) {
        self.library = library
        self.now = now
        self.defaultFade = defaultFade
        self.defaultCurve = defaultCurve
    }

    /// Default intensity when turning on a light that was off.
    public static let defaultOnIntensity = 0.8
    /// Amber/blue references for warming/cooling colored lights.
    static let warmReference = LightColor.rgb(RGB(hex: "#FF8A3D")!)
    static let coolReference = LightColor.rgb(RGB(hex: "#8FB8FF")!)

    /// True when `selector` explicitly targets specific fixtures, roles, or groups rather than broad wildcards.
    public static func isExplicitSelector(_ selector: FixtureSelector) -> Bool {
        switch selector {
        case .fixtures(let ids): return !ids.isEmpty
        case .selection, .role, .group: return true
        case .named(let raw):
            let q = SelectorResolver.normalize(raw)
            if ["all", "everything", "all lights", "every light", "lights", "the lights", "whole room", "room"].contains(q) {
                return false
            }
            return !q.isEmpty
        case .union(let items), .intersection(let items):
            return !items.isEmpty && items.allSatisfy { isExplicitSelector($0) }
        case .excluding(let base, _):
            return isExplicitSelector(base)
        case .all, .none, .category, .region:
            return false
        }
    }

    /// Applies a single command.
    @discardableResult
    public func apply(_ command: LightingCommand, to doc: inout ShowDocument, selection: [UUID] = [],
                      currentRendered: [UUID: FixtureState] = [:], origin: CommandOrigin = .ui) -> CommandResult {
        apply([command], to: &doc, selection: selection, currentRendered: currentRendered, origin: origin)
    }

    /// Applies commands in order.
    /// - Parameters:
    ///   - currentRendered: the states currently visible (from the engine's latest frame), used as
    ///     the starting point of fades so changes never jump.
    ///   - origin: who issued the commands (enforces remote/recording guardrails and protection).
    @discardableResult
    public func apply(_ commands: [LightingCommand], to doc: inout ShowDocument, selection: [UUID] = [],
                      currentRendered: [UUID: FixtureState] = [:], origin: CommandOrigin = .ui) -> CommandResult {
        var result = CommandResult()
        var fade = clamp(defaultFade.finiteOr(0), 0, 600)
        var sawFadeTime = false
        for command in commands {
            if case .fadeTime(let f) = command {
                fade = clamp(f.finiteOr(0), 0, 600)
                sawFadeTime = true
                continue
            }
            result.merge(apply(command, to: &doc, selection: selection, fade: fade,
                               currentRendered: currentRendered, origin: origin))
        }
        if sawFadeTime && result.messages.isEmpty && result.warnings.isEmpty {
            result.messages.append(String(format: "Fade time %.1fs.", fade))
        }
        return result
    }

    func resolver(_ doc: ShowDocument, selection: [UUID]) -> SelectorResolver {
        SelectorResolver(project: doc.project, selection: selection, library: library)
    }

    func cctRange(for id: UUID, _ doc: ShowDocument) -> ClosedRange<Double> {
        var lo = 1700.0
        var hi = 12000.0
        if let f = doc.project.fixture(id) {
            if let def = doc.project.definition(f.definitionID) ?? library?(f.definitionID),
               let r = def.cctRange, r.count == 2, r[0] < r[1] {
                lo = r[0]
                hi = r[1]
            }
            if let minK = f.limits.minKelvin { lo = max(lo, minK.finiteOr(lo)) }
            if let maxK = f.limits.maxKelvin { hi = min(hi, maxK.finiteOr(hi)) }
            if hi < lo { hi = lo }
        }
        return lo...hi
    }

    /// Enforces `FixtureLimits` (min/max intensity, Kelvin range, strobe suppression) for every origin.
    public func enforceLimits(_ state: FixtureState, for id: UUID, in doc: ShowDocument) -> FixtureState {
        var s = state
        let fixture = doc.project.fixture(id)
        let limits = (fixture?.limits ?? .default).sanitized
        s.intensity = clamp(s.intensity.finiteOr(0), limits.minIntensity, limits.maxIntensity)
        s.color = s.color.sanitized
        let kRange = cctRange(for: id, doc)
        if case .kelvin(let k, let tint) = s.color {
            s.color = .kelvin(clamp(k.finiteOr(5600), kRange.lowerBound, kRange.upperBound),
                              tint: clamp(tint.finiteOr(0), -1, 1))
        }
        if let cells = s.cells {
            s.cells = cells.map { cell in
                var c = CellState(intensity: clamp01(cell.intensity.finiteOr(1)), color: cell.color.sanitized)
                if case .kelvin(let k, let tint) = c.color {
                    c.color = .kelvin(clamp(k.finiteOr(5600), kRange.lowerBound, kRange.upperBound),
                                      tint: clamp(tint.finiteOr(0), -1, 1))
                }
                return c
            }
        }
        if !limits.allowStrobe || doc.live.recordingMode {
            s.strobeHz = 0
        } else {
            s.strobeHz = clamp(s.strobeHz.finiteOr(0), 0, 30)
        }
        return s
    }

    /// Filters target fixture IDs according to protection rules, recording mode, and command origin.
    func filterProtected(_ ids: [UUID], selector: FixtureSelector, in doc: ShowDocument,
                         origin: CommandOrigin, forEffectsOrMusic: Bool = false,
                         warnings: inout [String]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        let explicitUI = (origin == .ui) && CommandExecutor.isExplicitSelector(selector)
        let filtered = ids.filter { id in
            guard let f = doc.project.fixture(id) else { return false }
            guard f.isProtected else { return true }
            // Protected fixtures (key/fill or limits.protected):
            // 1. Remote can never modify protected fixtures.
            if origin.isRemote { return false }
            // 2. Recording mode locks protected fixtures globally unless explicitly targeted from the UI (and not effects/music).
            if doc.live.recordingMode {
                return explicitUI && !forEffectsOrMusic && !f.limits.protected
            }
            // 3. Effects and music exclude key/fill and limits.protected unless explicitly targeted from the UI and allowed.
            if forEffectsOrMusic {
                return explicitUI && f.limits.allowEffects && !f.limits.protected
            }
            // 4. Non-UI origins (assistant, voice, MIDI, OSC...) exclude `limits.protected` fixtures,
            //    and exclude key/fill when using broad non-explicit selectors (like `.all`).
            if origin != .ui {
                if f.limits.protected { return false }
                if (f.role == .key || f.role == .fill) && !CommandExecutor.isExplicitSelector(selector) {
                    return false
                }
            } else if f.limits.protected && !explicitUI {
                return false
            }
            return true
        }
        if filtered.isEmpty && !ids.isEmpty {
            warnings.append("Protected lights were skipped.")
        }
        return filtered
    }

    /// Mutates base state of the given fixtures, recording fades from the currently rendered state.
    func modify(_ ids: [UUID], in doc: inout ShowDocument, fade: Double, curve: FadeCurve = .easeInOut,
                delays: [UUID: Double] = [:], currentRendered: [UUID: FixtureState],
                _ body: (UUID, inout FixtureState) -> Void) {
        let t = now()
        let dur = clamp(fade.finiteOr(0), 0, 600)
        for id in ids {
            let old = doc.live.base[id] ?? FixtureState(intensity: 0, color: .white)
            let current = doc.live.effectiveBaseState(of: id, at: t, currentRendered: currentRendered)
            // Start relative mutations from current target (or enforced state) and clamp to limits.
            var new = old
            body(id, &new)
            new = enforceLimits(new, for: id, in: doc)
            let delay = clamp((delays[id] ?? 0).finiteOr(0), 0, 60)
            let hadActiveFade = doc.live.fades[id].map { !$0.isFinished(at: t) } ?? false
            guard new != old || hadActiveFade else { continue }
            if dur > 0 || delay > 0 {
                doc.live.fades[id] = FixtureFade(from: current, startTime: t, duration: dur, delay: delay, curve: curve)
            } else {
                doc.live.fades[id] = nil
            }
            doc.live.base[id] = new
        }
    }

    func describe(_ ids: [UUID], _ doc: ShowDocument) -> String {
        if ids.count == doc.project.fixtures.count && ids.count > 1 { return "all lights" }
        let names = ids.compactMap { id in doc.project.fixture(id)?.name }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) lights"
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func apply(_ command: LightingCommand, to doc: inout ShowDocument, selection: [UUID], fade: Double,
               currentRendered: [UUID: FixtureState], origin: CommandOrigin) -> CommandResult {
        var result = CommandResult()

        // In recording mode, remote origins are completely read-only.
        if doc.live.recordingMode && origin.isRemote {
            result.warnings.append("Recording mode is active — remote is read-only.")
            return result
        }

        let r = resolver(doc, selection: selection)

        func targets(_ s: FixtureSelector, forEffectsOrMusic: Bool = false) -> [UUID] {
            let rawIDs = r.resolve(s)
            if rawIDs.isEmpty {
                result.warnings.append("No lights matched.")
                return []
            }
            let ids = filterProtected(rawIDs, selector: s, in: doc, origin: origin,
                                      forEffectsOrMusic: forEffectsOrMusic, warnings: &result.warnings)
            result.affectedFixtureIDs.formUnion(ids)
            return ids
        }

        switch command {
        case .setIntensity(let sel, let v):
            let ids = targets(sel)
            let clamped = clamp01(v.finiteOr(0))
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                s.intensity = clamped
            }
            if !ids.isEmpty {
                let actual = ids.first.flatMap { doc.live.base[$0]?.intensity } ?? clamped
                result.messages.append("Set \(describe(ids, doc)) to \(Int((actual * 100).rounded()))%.")
            }

        case .adjustIntensity(let sel, let delta):
            let ids = targets(sel)
            let d = clamp(delta.finiteOr(0), -1, 1)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                s.intensity = clamp01(s.intensity + d)
            }
            if !ids.isEmpty { result.messages.append("\(d >= 0 ? "Brightened" : "Dimmed") \(describe(ids, doc)).") }

        case .setColor(let sel, let color):
            let ids = targets(sel)
            let col = color.sanitized
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                s.color = col; s.cells = nil
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Set \(describe(ids, doc)) to \(col.label).") }

        case .setKelvin(let sel, let k):
            let ids = targets(sel)
            let cleanK = clamp(k.finiteOr(5600), 1000, 20000)
            let ranges = Dictionary(ids.map { ($0, cctRange(for: $0, doc)) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                var tint = 0.0
                if case .kelvin(_, let t) = s.color { tint = t }
                let range = ranges[id] ?? 1000...20000
                s.color = .kelvin(clamp(cleanK, range.lowerBound, range.upperBound), tint: tint)
                s.cells = nil
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Set \(describe(ids, doc)) to \(Int(cleanK.rounded()))K.") }

        case .adjustKelvin(let sel, let delta):
            let ids = targets(sel)
            let d = clamp(delta.finiteOr(0), -10000, 10000)
            let ranges = Dictionary(ids.map { ($0, cctRange(for: $0, doc)) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                switch s.color {
                case .kelvin(let k, let t):
                    let range = ranges[id] ?? 1000...20000
                    s.color = .kelvin(clamp(k + d, range.lowerBound, range.upperBound), tint: t)
                default:
                    let amount = min(abs(d) / 2500, 1) * 0.6
                    s.color = LightColor.mix(s.color, d < 0 ? CommandExecutor.warmReference : CommandExecutor.coolReference, amount)
                }
                if let cells = s.cells {
                    let amount = min(abs(d) / 2500, 1) * 0.6
                    s.cells = cells.map { CellState(intensity: $0.intensity, color: LightColor.mix($0.color, d < 0 ? CommandExecutor.warmReference : CommandExecutor.coolReference, amount)) }
                }
            }
            if !ids.isEmpty { result.messages.append("\(d < 0 ? "Warmed" : "Cooled") \(describe(ids, doc)).") }

        case .setTint(let sel, let tint):
            let ids = targets(sel)
            let cleanTint = clamp(tint.finiteOr(0), -1, 1)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                let k = s.color.approximateKelvin.kelvin
                s.color = .kelvin(k, tint: cleanTint); s.cells = nil
            }
            if !ids.isEmpty { result.messages.append("Set tint on \(describe(ids, doc)).") }

        case .adjustTint(let sel, let delta):
            let ids = targets(sel)
            let d = clamp(delta.finiteOr(0), -2, 2)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                switch s.color {
                case .kelvin(let k, let t): s.color = .kelvin(k, tint: clamp(t + d, -1, 1))
                default:
                    let ref = d > 0 ? LightColor.rgb(RGB(hex: "#FF4FD8")!) : LightColor.rgb(RGB(hex: "#5CFF7A")!)
                    s.color = LightColor.mix(s.color, ref, min(abs(d), 1) * 0.3)
                }
            }
            if !ids.isEmpty { result.messages.append("Adjusted \(d > 0 ? "magenta" : "green") tint on \(describe(ids, doc)).") }

        case .shiftColor(let sel, let toward, let amount):
            let ids = targets(sel)
            let col = toward.sanitized
            let amt = clamp01(amount.finiteOr(0.25))
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                s.color = LightColor.mix(s.color, col, amt)
                if let cells = s.cells { s.cells = cells.map { CellState(intensity: $0.intensity, color: LightColor.mix($0.color, col, amt)) } }
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Shifted \(describe(ids, doc)) toward \(col.label).") }

        case .adjustSaturation(let sel, let delta):
            let ids = targets(sel)
            let d = clamp(delta.finiteOr(0), -1, 1)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                let hsv = s.color.displayRGB.hsv
                s.color = .rgb(RGB(hue: hsv.h, saturation: clamp01(hsv.s + d), value: 1))
                s.cells = nil
            }
            if !ids.isEmpty { result.messages.append("\(d >= 0 ? "Richer" : "Softer") color on \(describe(ids, doc)).") }

        case .gradient(let sel, let colors, let axis):
            let ids = targets(sel)
            let cleanColors = colors.map { $0.sanitized }
            guard !cleanColors.isEmpty, !ids.isEmpty else { break }
            let resolved = doc.project.resolvedFixtures(library: library).filter { ids.contains($0.id) }
            let geo = SpatialLayout.compute(fixtures: resolved, stage: doc.project.stage)
            func coord(_ p: SIMDPoint) -> Double { axis == .vertical ? p.y : p.x }
            var points: [Double] = []
            for rf in resolved {
                guard let g = geo[rf.id] else { continue }
                if rf.cellCount > 0 && axis != .alongFixture { points += g.cellPositions.map(coord) } else { points.append(coord(g.center)) }
            }
            let lo = points.min() ?? 0, hi = points.max() ?? 1
            func colorAt(_ u: Double) -> LightColor {
                guard cleanColors.count > 1 else { return cleanColors[0] }
                let x = clamp01(u) * Double(cleanColors.count - 1)
                let i = min(Int(x), cleanColors.count - 2)
                return LightColor.mix(cleanColors[i], cleanColors[i + 1], x - Double(i))
            }
            let geoByID = geo
            let cellCounts = Dictionary(resolved.map { ($0.id, $0.cellCount) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                if let g = geoByID[id] {
                    let n = cellCounts[id] ?? 0
                    if n > 0 {
                        if axis == .alongFixture {
                            s.cells = (0..<n).map { CellState(intensity: 1, color: colorAt(n == 1 ? 0.5 : Double($0) / Double(n - 1))) }
                        } else {
                            s.cells = g.cellPositions.map { CellState(intensity: 1, color: colorAt(hi > lo ? (coord($0) - lo) / (hi - lo) : 0.5)) }
                        }
                        s.color = colorAt(hi > lo ? (coord(g.center) - lo) / (hi - lo) : 0.5)
                    } else {
                        s.color = colorAt(hi > lo ? (coord(g.center) - lo) / (hi - lo) : 0.5)
                        s.cells = nil
                    }
                } else {
                    s.color = colorAt(0.5)
                }
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            result.messages.append("Painted a gradient across \(describe(ids, doc)).")

        case .setCells(let sel, let rawCells):
            let ids = targets(sel)
            let sanitizedCells = Array(rawCells.prefix(1024)).map {
                CellState(intensity: clamp01($0.intensity.finiteOr(1)), color: $0.color.sanitized)
            }
            guard !ids.isEmpty else { break }
            let resolved = doc.project.resolvedFixtures(library: library)
            let cellCounts = Dictionary(resolved.map { ($0.id, $0.cellCount) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                if sanitizedCells.isEmpty {
                    s.cells = nil
                } else {
                    let expected = cellCounts[id] ?? sanitizedCells.count
                    if expected > 0 && sanitizedCells.count != expected {
                        s.cells = (0..<expected).map { idx in
                            sanitizedCells[min(idx, sanitizedCells.count - 1)]
                        }
                    } else {
                        s.cells = sanitizedCells
                    }
                    s.color = sanitizedCells[sanitizedCells.count / 2].color
                    if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
                }
            }
            result.messages.append("Set pixels on \(describe(ids, doc)).")

        case .paintCells(let sel, let indices, let color, let intensity):
            let ids = targets(sel)
            guard !ids.isEmpty else { break }
            let col = color.sanitized
            let cellInt = clamp01((intensity ?? 1.0).finiteOr(1.0))
            let cleanIndices = Set(indices.filter { $0 >= 0 && $0 < 1024 })
            let resolved = doc.project.resolvedFixtures(library: library)
            let cellCounts = Dictionary(resolved.map { ($0.id, $0.cellCount) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                let maxIdx = (cleanIndices.max() ?? -1) + 1
                let count = max(cellCounts[id] ?? 0, s.cells?.count ?? 0, maxIdx, 1)
                var cells = (0..<count).map { s.cell($0) }
                if cleanIndices.isEmpty {
                    for i in 0..<count { cells[i] = CellState(intensity: cellInt, color: col) }
                } else {
                    for i in cleanIndices where i < count {
                        cells[i] = CellState(intensity: cellInt, color: col)
                    }
                }
                s.cells = cells
                s.color = col
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            result.messages.append("Painted pixels on \(describe(ids, doc)) \(col.label).")

        case .turnOn(let sel):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Turned on \(describe(ids, doc)).") }

        case .turnOff(let sel):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in s.intensity = 0 }
            if !ids.isEmpty { result.messages.append("Turned off \(describe(ids, doc)).") }

        case .recallLook(let ref, let fadeOverride):
            guard let look = findLook(ref, in: doc.project) else {
                result.warnings.append("Couldn't find that look.")
                break
            }
            let f = clamp((fadeOverride ?? look.fadeTime).finiteOr(0), 0, 600)
            let t = now()
            let validIDs = Set(doc.project.fixtures.map(\.id))
            let candidateIDs = look.states.keys.filter { validIDs.contains($0) }
            let allowedIDs = Set(filterProtected(Array(candidateIDs), selector: .fixtures(Array(candidateIDs)),
                                                 in: doc, origin: origin, warnings: &result.warnings))
            let resolved = doc.project.resolvedFixtures(library: library)
            let delays = SpatialLayout.delays(for: Array(allowedIDs), fixtures: resolved, stage: doc.project.stage,
                                              totalDelay: look.spatialDelay, direction: look.delayDirection,
                                              explicitDelays: look.fixtureDelays)
            for (id, rawState) in look.states where allowedIDs.contains(id) {
                let state = enforceLimits(rawState, for: id, in: doc)
                let current = doc.live.effectiveBaseState(of: id, at: t, currentRendered: currentRendered)
                let d = delays[id] ?? 0
                if f > 0 || d > 0 {
                    doc.live.fades[id] = FixtureFade(from: current, startTime: t, duration: f, delay: d, curve: look.fadeCurve)
                } else {
                    doc.live.fades[id] = nil
                }
                doc.live.base[id] = state
                result.affectedFixtureIDs.insert(id)
            }
            let newEffects = doc.live.recordingMode ? look.effects.filter { !$0.kind.isFlashy } : look.effects
            if f > 0 {
                let newIDs = Set(newEffects.map(\.id))
                let oldIDs = Set(doc.live.effects.map(\.id))
                for old in doc.live.effects where !newIDs.contains(old.id) {
                    doc.live.effectFades[old.id] = EffectFade(effect: old, startTime: t, duration: f, fadingIn: false, curve: look.fadeCurve)
                }
                for ne in newEffects where !oldIDs.contains(ne.id) {
                    doc.live.effectFades[ne.id] = EffectFade(effect: ne, startTime: t, duration: f, fadingIn: true, curve: look.fadeCurve)
                }
            } else {
                doc.live.effectFades = [:]
            }
            doc.live.effects = newEffects

            if let m = look.music {
                if f > 0 && m.enabled != doc.live.music.enabled {
                    doc.live.musicFade = MusicFade(settings: m.enabled ? m : doc.live.music, startTime: t,
                                                   duration: f, fadingIn: m.enabled, curve: look.fadeCurve)
                } else if f <= 0 {
                    doc.live.musicFade = nil
                }
                doc.live.music = m
            } else if doc.live.music.enabled {
                let previousMusic = doc.live.music
                doc.live.music.enabled = false
                if f > 0 {
                    doc.live.musicFade = MusicFade(settings: previousMusic, startTime: t,
                                                   duration: f, fadingIn: false, curve: look.fadeCurve)
                } else {
                    doc.live.musicFade = nil
                }
            }
            doc.live.activeLookID = look.id
            result.messages.append("Recalled “\(look.name)”.")

        case .saveLook(let name, let sel):
            let ids = r.resolve(sel)
            var states = FixtureStateMap()
            for id in ids { states[id] = doc.live.base[id] ?? .off }
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let look = Look(name: cleanName.isEmpty ? "New Look" : String(cleanName.prefix(80)), states: states,
                            effects: doc.live.effects, sortIndex: (doc.project.looks.map(\.sortIndex).max() ?? 0) + 1)
            doc.project.looks.append(look)
            doc.live.activeLookID = look.id
            result.messages.append("Saved look “\(look.name)”.")

        case .copyLook(let ref, let newName):
            guard let source = findLook(ref, in: doc.project) else {
                result.warnings.append("Couldn't find that look to copy.")
                break
            }
            let trimmed = (newName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let baseCopyName = trimmed.isEmpty ? "\(source.name) Copy" : String(trimmed.prefix(80))
            var copy = source
            copy.id = UUID()
            copy.name = baseCopyName
            copy.sortIndex = (doc.project.looks.map(\.sortIndex).max() ?? 0) + 1
            copy.createdAt = Date()
            copy.modifiedAt = copy.createdAt
            doc.project.looks.append(copy)
            result.affectedFixtureIDs.formUnion(copy.states.keys)
            result.messages.append("Copied look “\(source.name)” as “\(copy.name)”.")

        case .startEffect(let effect):
            if (doc.live.recordingMode || origin.isRemote) && effect.kind.isFlashy {
                result.warnings.append("Flashing effects are disabled in \(doc.live.recordingMode ? "Recording Mode" : "remote control").")
                break
            }
            let allowedIDs = targets(effect.targets, forEffectsOrMusic: true)
            guard !allowedIDs.isEmpty else { break }
            var e = effect
            e.params = e.params.sanitized
            if Set(allowedIDs) != Set(r.resolve(e.targets)) {
                e.targets = .fixtures(allowedIDs)
            }
            doc.live.effects.removeAll { $0.id == e.id }
            doc.live.effects.append(e)
            if doc.live.effects.count > 32 { doc.live.effects.removeFirst(doc.live.effects.count - 32) }
            if fade > 0 {
                doc.live.effectFades[e.id] = EffectFade(effect: e, startTime: now(), duration: fade, fadingIn: true, curve: defaultCurve)
            } else {
                doc.live.effectFades[e.id] = nil
            }
            result.messages.append("Started \(e.displayName).")

        case .setEffectParameters(let effectID, let sel, let params):
            let cleanParams = params.sanitized
            let targetSet = Set(r.resolve(sel))
            var updated = 0
            for i in doc.live.effects.indices {
                let matchesID = effectID != nil && doc.live.effects[i].id == effectID
                let matchesSelector = effectID == nil && (sel == .all || !Set(r.resolve(doc.live.effects[i].targets)).isDisjoint(with: targetSet))
                if matchesID || matchesSelector {
                    doc.live.effects[i].params = cleanParams
                    result.affectedFixtureIDs.formUnion(r.resolve(doc.live.effects[i].targets))
                    updated += 1
                }
            }
            if updated > 0 {
                result.messages.append("Updated effect parameters.")
            } else {
                result.warnings.append("No matching running effects.")
            }

        case .stopEffects(let sel):
            let ids = Set(r.resolve(sel))
            let t = now()
            var stopped: [EffectInstance] = []
            doc.live.effects.removeAll { eff in
                let hits = !Set(r.resolve(eff.targets)).isDisjoint(with: ids)
                if hits { stopped.append(eff) }
                return hits
            }
            if fade > 0 {
                for eff in stopped {
                    doc.live.effectFades[eff.id] = EffectFade(effect: eff, startTime: t, duration: fade, fadingIn: false, curve: defaultCurve)
                }
            } else {
                for eff in stopped { doc.live.effectFades[eff.id] = nil }
            }
            for eff in stopped { result.affectedFixtureIDs.formUnion(r.resolve(eff.targets)) }
            result.messages.append(stopped.isEmpty ? "No effects were running there." : "Stopped effects.")

        case .stopAllEffects:
            let stopped = doc.live.effects
            let t = now()
            doc.live.effects.removeAll()
            if fade > 0 {
                for eff in stopped {
                    doc.live.effectFades[eff.id] = EffectFade(effect: eff, startTime: t, duration: fade, fadingIn: false, curve: defaultCurve)
                }
            } else {
                doc.live.effectFades.removeAll()
            }
            for eff in stopped { result.affectedFixtureIDs.formUnion(r.resolve(eff.targets)) }
            result.messages.append("Stopped all effects.")

        case .setMusicMode(let enabled, let mood):
            let wasEnabled = doc.live.music.enabled
            let previousSettings = doc.live.music
            doc.live.music.enabled = enabled
            if let mood { doc.live.music.mood = mood }
            let allowedTargets = filterProtected(r.resolve(doc.live.music.targets), selector: doc.live.music.targets,
                                                 in: doc, origin: origin, forEffectsOrMusic: true, warnings: &result.warnings)
            result.affectedFixtureIDs.formUnion(allowedTargets)
            if fade > 0 && wasEnabled != enabled {
                doc.live.musicFade = MusicFade(settings: enabled ? doc.live.music : previousSettings,
                                               startTime: now(), duration: fade, fadingIn: enabled, curve: defaultCurve)
            } else if fade <= 0 {
                doc.live.musicFade = nil
            }
            result.messages.append(enabled ? "Music mode on (\(doc.live.music.mood.displayName))." : "Music mode off.")

        case .setFixtureProtection(let sel, let protected):
            if origin.isRemote {
                result.warnings.append("Remote cannot change fixture protection.")
                break
            }
            let ids = r.resolve(sel)
            if ids.isEmpty {
                result.warnings.append("No lights matched.")
                break
            }
            let idSet = Set(ids)
            for i in doc.project.fixtures.indices where idSet.contains(doc.project.fixtures[i].id) {
                doc.project.fixtures[i].limits.protected = protected
                doc.project.fixtures[i].limits.allowEffects = !protected
            }
            result.affectedFixtureIDs.formUnion(ids)
            result.messages.append("\(protected ? "Protected" : "Unprotected") \(describe(ids, doc)).")

        case .setRecordingMode(let enabled):
            if origin.isRemote {
                result.warnings.append("Remote cannot change recording mode.")
                break
            }
            doc.live.recordingMode = enabled
            if enabled {
                doc.live.effects.removeAll { $0.kind.isFlashy }
                for (id, var state) in doc.live.base.storage where state.strobeHz > 0 {
                    state.strobeHz = 0
                    doc.live.base[id] = state
                    result.affectedFixtureIDs.insert(id)
                }
            }
            result.messages.append(enabled ? "Recording mode on (key/fill locked, flashing off, remote read-only)." : "Recording mode off.")

        case .freeze(let frozen):
            if origin.isRemote {
                result.warnings.append("Remote cannot freeze output.")
                break
            }
            doc.live.isFrozen = frozen
            if frozen {
                let t = now()
                var captured = FixtureStateMap()
                for f in doc.project.fixtures {
                    captured[f.id] = doc.live.effectiveBaseState(of: f.id, at: t, currentRendered: currentRendered)
                }
                doc.live.frozenStates = captured
            } else {
                doc.live.frozenStates = nil
            }
            result.messages.append(frozen ? "Output frozen." : "Output unfrozen.")

        case .swapColors(let selA, let selB):
            if let selB {
                let idsA = targets(selA)
                let idsB = targets(selB)
                guard !idsA.isEmpty, !idsB.isEmpty else { break }
                let colorA = idsA.compactMap { doc.live.base[$0]?.color }.first ?? .white
                let colorB = idsB.compactMap { doc.live.base[$0]?.color }.first ?? .white
                modify(idsA, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                    s.color = colorB; s.cells = nil
                }
                modify(idsB, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                    s.color = colorA; s.cells = nil
                }
                result.messages.append("Swapped colors between \(describe(idsA, doc)) and \(describe(idsB, doc)).")
            } else {
                let ids = targets(selA)
                guard !ids.isEmpty else { break }
                if ids.count == 1, let id = ids.first {
                    modify([id], in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { _, s in
                        if let cells = s.cells, cells.count > 1 {
                            s.cells = cells.reversed()
                            s.color = cells.first?.color ?? s.color
                        }
                    }
                    result.messages.append("Swapped pixel colors on \(describe(ids, doc)).")
                } else {
                    let currentColors = ids.map { doc.live.base[$0]?.color ?? .white }
                    var uniqueColors: [LightColor] = []
                    for c in currentColors where !uniqueColors.contains(c) { uniqueColors.append(c) }
                    var mappedColors: [UUID: LightColor] = [:]
                    if uniqueColors.count == 2 {
                        for (idx, id) in ids.enumerated() {
                            mappedColors[id] = currentColors[idx] == uniqueColors[0] ? uniqueColors[1] : uniqueColors[0]
                        }
                    } else {
                        let reversed = Array(currentColors.reversed())
                        for (idx, id) in ids.enumerated() {
                            mappedColors[id] = reversed[idx]
                        }
                    }
                    modify(ids, in: &doc, fade: fade, curve: defaultCurve, currentRendered: currentRendered) { id, s in
                        if let newColor = mappedColors[id] { s.color = newColor }
                        if let cells = s.cells, cells.count > 1 { s.cells = cells.reversed() }
                    }
                    result.messages.append("Swapped colors across \(describe(ids, doc)).")
                }
            }

        case .setGrandMaster(let v):
            doc.live.grandMaster = clamp01(v.finiteOr(1))
            result.messages.append("Master at \(Int((doc.live.grandMaster * 100).rounded()))%.")

        case .setBlackout(let b):
            doc.live.blackout = b
            result.messages.append(b ? "Blackout." : "Lights back on.")

        case .identify(let sel):
            let ids = targets(sel)
            let t = now()
            for id in ids { doc.live.identify[id] = t }
            if !ids.isEmpty { result.messages.append("Flashing \(describe(ids, doc)).") }

        case .fadeTime:
            break
        }
        return result
    }

    /// Finds a look by id or fuzzy name (exact → prefix → contains → word overlap).
    public func findLook(_ ref: LookReference, in project: Project) -> Look? {
        switch ref {
        case .id(let id): return project.look(id)
        case .name(let raw):
            let q = SelectorResolver.normalize(raw)
            guard !q.isEmpty else { return nil }
            let looks = project.looks
            if let l = looks.first(where: { SelectorResolver.normalize($0.name) == q }) { return l }
            if let l = looks.first(where: { SelectorResolver.normalize($0.name).hasPrefix(q) }) { return l }
            if let l = looks.first(where: { SelectorResolver.normalize($0.name).contains(q) }) { return l }
            let qWords = Set(q.split(separator: " "))
            let scored = looks.map { look -> (Look, Int) in
                let w = Set(SelectorResolver.normalize(look.name).split(separator: " "))
                return (look, w.intersection(qWords).count)
            }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            return scored.first?.0
        }
    }
}
