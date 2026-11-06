import Foundation

/// Applies `LightingCommand`s to a `ShowDocument`. Pure value-type logic (testable anywhere).
public struct CommandExecutor {
    /// External library lookup for definitions not embedded in the project.
    public var library: ((String) -> FixtureDefinition?)?
    /// Clock (overridable in tests).
    public var now: () -> Double
    /// Fade used for changes when no `.fadeTime` command precedes them.
    public var defaultFade: Double

    public init(library: ((String) -> FixtureDefinition?)? = nil, now: @escaping () -> Double = PrismClock.now, defaultFade: Double = 0) {
        self.library = library
        self.now = now
        self.defaultFade = defaultFade
    }

    /// Default intensity when turning on a light that was off.
    public static let defaultOnIntensity = 0.8
    /// Amber/blue references for warming/cooling colored lights.
    static let warmReference = LightColor.rgb(RGB(hex: "#FF8A3D")!)
    static let coolReference = LightColor.rgb(RGB(hex: "#8FB8FF")!)

    /// Applies commands in order.
    /// - Parameters:
    ///   - currentRendered: the states currently visible (from the engine's latest frame), used as
    ///     the starting point of fades so changes never jump.
    @discardableResult
    public func apply(_ commands: [LightingCommand], to doc: inout ShowDocument, selection: [UUID] = [],
                      currentRendered: [UUID: FixtureState] = [:]) -> CommandResult {
        var result = CommandResult()
        var fade = defaultFade
        for command in commands {
            if case .fadeTime(let f) = command { fade = clamp(f.finiteOr(0), 0, 600); continue }
            result.merge(apply(command, to: &doc, selection: selection, fade: fade, currentRendered: currentRendered))
        }
        return result
    }

    func resolver(_ doc: ShowDocument, selection: [UUID]) -> SelectorResolver {
        SelectorResolver(project: doc.project, selection: selection, library: library)
    }

    /// Mutates base state of the given fixtures, recording fades.
    func modify(_ ids: [UUID], in doc: inout ShowDocument, fade: Double, currentRendered: [UUID: FixtureState],
                _ body: (UUID, inout FixtureState) -> Void) {
        let t = now()
        for id in ids {
            let old = doc.live.base[id] ?? FixtureState(intensity: 0, color: .white)
            var new = old
            body(id, &new)
            new.intensity = clamp01(new.intensity.finiteOr(0))
            new.color = new.color.sanitized
            guard new != old else { continue }
            if fade > 0 {
                let from = currentRendered[id] ?? old
                doc.live.fades[id] = FixtureFade(from: from, startTime: t, duration: fade)
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

    func cctRange(for id: UUID, _ doc: ShowDocument) -> ClosedRange<Double> {
        if let f = doc.project.fixture(id),
           let def = doc.project.definition(f.definitionID) ?? library?(f.definitionID),
           let r = def.cctRange, r.count == 2, r[0] < r[1] {
            return r[0]...r[1]
        }
        return 1700...12000
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    func apply(_ command: LightingCommand, to doc: inout ShowDocument, selection: [UUID], fade: Double,
               currentRendered: [UUID: FixtureState]) -> CommandResult {
        let r = resolver(doc, selection: selection)
        var result = CommandResult()

        func targets(_ s: FixtureSelector) -> [UUID] {
            let ids = r.resolve(s)
            if ids.isEmpty { result.warnings.append("No lights matched.") }
            result.affectedFixtureIDs.formUnion(ids)
            return ids
        }

        switch command {
        case .setIntensity(let sel, let v):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in s.intensity = clamp01(v) }
            if !ids.isEmpty { result.messages.append("Set \(describe(ids, doc)) to \(Int((clamp01(v) * 100).rounded()))%.") }

        case .adjustIntensity(let sel, let delta):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in s.intensity = clamp01(s.intensity + delta) }
            if !ids.isEmpty { result.messages.append("\(delta >= 0 ? "Brightened" : "Dimmed") \(describe(ids, doc)).") }

        case .setColor(let sel, let color):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                s.color = color; s.cells = nil
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Set \(describe(ids, doc)) to \(color.label).") }

        case .setKelvin(let sel, let k):
            let ids = targets(sel)
            let ranges = Dictionary(ids.map { ($0, cctRange(for: $0, doc)) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { id, s in
                var tint = 0.0
                if case .kelvin(_, let t) = s.color { tint = t }
                let range = ranges[id] ?? 1000...20000
                s.color = .kelvin(clamp(k, range.lowerBound, range.upperBound), tint: tint)
                s.cells = nil
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Set \(describe(ids, doc)) to \(Int(k.rounded()))K.") }

        case .adjustKelvin(let sel, let delta):
            let ids = targets(sel)
            let ranges = Dictionary(ids.map { ($0, cctRange(for: $0, doc)) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { id, s in
                switch s.color {
                case .kelvin(let k, let t):
                    let range = ranges[id] ?? 1000...20000
                    s.color = .kelvin(clamp(k + delta, range.lowerBound, range.upperBound), tint: t)
                default:
                    let amount = min(abs(delta) / 2500, 1) * 0.6
                    s.color = LightColor.mix(s.color, delta < 0 ? CommandExecutor.warmReference : CommandExecutor.coolReference, amount)
                }
                if let cells = s.cells {
                    let amount = min(abs(delta) / 2500, 1) * 0.6
                    s.cells = cells.map { CellState(intensity: $0.intensity, color: LightColor.mix($0.color, delta < 0 ? CommandExecutor.warmReference : CommandExecutor.coolReference, amount)) }
                }
            }
            if !ids.isEmpty { result.messages.append("\(delta < 0 ? "Warmed" : "Cooled") \(describe(ids, doc)).") }

        case .setTint(let sel, let tint):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                let k = s.color.approximateKelvin.kelvin
                s.color = .kelvin(k, tint: clamp(tint, -1, 1)); s.cells = nil
            }
            if !ids.isEmpty { result.messages.append("Set tint on \(describe(ids, doc)).") }

        case .adjustTint(let sel, let delta):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                switch s.color {
                case .kelvin(let k, let t): s.color = .kelvin(k, tint: clamp(t + delta, -1, 1))
                default:
                    let ref = delta > 0 ? LightColor.rgb(RGB(hex: "#FF4FD8")!) : LightColor.rgb(RGB(hex: "#5CFF7A")!)
                    s.color = LightColor.mix(s.color, ref, min(abs(delta), 1) * 0.3)
                }
            }
            if !ids.isEmpty { result.messages.append("Adjusted \(delta > 0 ? "magenta" : "green") tint on \(describe(ids, doc)).") }

        case .shiftColor(let sel, let toward, let amount):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                s.color = LightColor.mix(s.color, toward, amount)
                if let cells = s.cells { s.cells = cells.map { CellState(intensity: $0.intensity, color: LightColor.mix($0.color, toward, amount)) } }
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Shifted \(describe(ids, doc)) toward \(toward.label).") }

        case .adjustSaturation(let sel, let delta):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                let hsv = s.color.displayRGB.hsv
                s.color = .rgb(RGB(hue: hsv.h, saturation: clamp01(hsv.s + delta), value: 1))
                s.cells = nil
            }
            if !ids.isEmpty { result.messages.append("\(delta >= 0 ? "Richer" : "Softer") color on \(describe(ids, doc)).") }

        case .gradient(let sel, let colors, let axis):
            let ids = targets(sel)
            guard !colors.isEmpty, !ids.isEmpty else { break }
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
                guard colors.count > 1 else { return colors[0] }
                let x = clamp01(u) * Double(colors.count - 1)
                let i = min(Int(x), colors.count - 2)
                return LightColor.mix(colors[i], colors[i + 1], x - Double(i))
            }
            let geoByID = geo
            let cellCounts = Dictionary(resolved.map { ($0.id, $0.cellCount) }, uniquingKeysWith: { a, _ in a })
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { id, s in
                guard let g = geoByID[id] else { return }
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
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            result.messages.append("Painted a gradient across \(describe(ids, doc)).")

        case .turnOn(let sel):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in
                if s.intensity <= 0.001 { s.intensity = CommandExecutor.defaultOnIntensity }
            }
            if !ids.isEmpty { result.messages.append("Turned on \(describe(ids, doc)).") }

        case .turnOff(let sel):
            let ids = targets(sel)
            modify(ids, in: &doc, fade: fade, currentRendered: currentRendered) { _, s in s.intensity = 0 }
            if !ids.isEmpty { result.messages.append("Turned off \(describe(ids, doc)).") }

        case .recallLook(let ref, let fadeOverride):
            guard let look = findLook(ref, in: doc.project) else {
                result.warnings.append("Couldn't find that look.")
                break
            }
            let f = fadeOverride ?? look.fadeTime
            let t = now()
            let validIDs = Set(doc.project.fixtures.map(\.id))
            for (id, state) in look.states where validIDs.contains(id) {
                let old = doc.live.base[id] ?? .off
                if f > 0 { doc.live.fades[id] = FixtureFade(from: currentRendered[id] ?? old, startTime: t, duration: f) }
                doc.live.base[id] = state
                result.affectedFixtureIDs.insert(id)
            }
            let coversAll = validIDs.isSubset(of: Set(look.states.keys))
            if !look.effects.isEmpty || coversAll { doc.live.effects = look.effects }
            if let m = look.music { doc.live.music = m }
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

        case .startEffect(let effect):
            var e = effect
            e.params = e.params.sanitized
            doc.live.effects.removeAll { $0.id == e.id }
            doc.live.effects.append(e)
            if doc.live.effects.count > 32 { doc.live.effects.removeFirst(doc.live.effects.count - 32) }
            result.affectedFixtureIDs.formUnion(r.resolve(e.targets))
            result.messages.append("Started \(e.displayName).")

        case .stopEffects(let sel):
            let ids = Set(r.resolve(sel))
            let before = doc.live.effects.count
            doc.live.effects.removeAll { !Set(r.resolve($0.targets)).isDisjoint(with: ids) }
            result.messages.append(before == doc.live.effects.count ? "No effects were running there." : "Stopped effects.")

        case .stopAllEffects:
            doc.live.effects.removeAll()
            result.messages.append("Stopped all effects.")

        case .setMusicMode(let enabled, let mood):
            doc.live.music.enabled = enabled
            if let mood { doc.live.music.mood = mood }
            result.messages.append(enabled ? "Music mode on (\(doc.live.music.mood.displayName))." : "Music mode off.")

        case .setGrandMaster(let v):
            doc.live.grandMaster = clamp01(v)
            result.messages.append("Master at \(Int((clamp01(v) * 100).rounded()))%.")

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
