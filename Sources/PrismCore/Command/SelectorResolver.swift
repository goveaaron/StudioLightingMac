import Foundation

/// Resolves `FixtureSelector`s to concrete fixture ids, using roles, groups, names and the
/// stage plan (regions are relative to the subject — the first "person" prop).
public struct SelectorResolver: Sendable {
    public var fixtures: [PatchedFixture]
    public var groups: [FixtureGroup]
    public var stage: StageSettings
    /// Current UI selection (for `.selection`).
    public var selection: [UUID]
    /// Optional category lookup (definition category per fixture id).
    public var categories: [UUID: FixtureCategory]

    public init(fixtures: [PatchedFixture], groups: [FixtureGroup], stage: StageSettings,
                selection: [UUID] = [], categories: [UUID: FixtureCategory] = [:]) {
        self.fixtures = fixtures; self.groups = groups; self.stage = stage
        self.selection = selection; self.categories = categories
    }

    public init(project: Project, selection: [UUID] = [], library: ((String) -> FixtureDefinition?)? = nil) {
        var cats: [UUID: FixtureCategory] = [:]
        for f in project.fixtures {
            if let d = project.definition(f.definitionID) ?? library?(f.definitionID) { cats[f.id] = d.category }
        }
        self.init(fixtures: project.fixtures, groups: project.groups, stage: project.stage, selection: selection, categories: cats)
    }

    public init(snapshot: ShowSnapshot, selection: [UUID] = []) {
        var cats: [UUID: FixtureCategory] = [:]
        for rf in snapshot.fixtures { cats[rf.id] = rf.definition.category }
        self.init(fixtures: snapshot.fixtures.map(\.fixture), groups: snapshot.groups, stage: snapshot.stage,
                  selection: selection, categories: cats)
    }

    /// Resolved ids, ordered left→right then top→bottom on the stage (stable for gradients).
    public func resolve(_ selector: FixtureSelector) -> [UUID] {
        let set = resolveSet(selector)
        return fixtures
            .filter { set.contains($0.id) }
            .sorted { a, b in
                if abs(a.transform.x - b.transform.x) > 1e-6 { return a.transform.x < b.transform.x }
                if abs(a.transform.y - b.transform.y) > 1e-6 { return a.transform.y < b.transform.y }
                return a.name < b.name
            }
            .map(\.id)
    }

    public func resolveSet(_ selector: FixtureSelector) -> Set<UUID> {
        let all = Set(fixtures.map(\.id))
        switch selector {
        case .all: return all
        case .none: return []
        case .fixtures(let ids): return all.intersection(ids)
        case .group(let gid): return all.intersection(groups.first { $0.id == gid }?.fixtureIDs ?? [])
        case .role(let role): return Set(fixtures.filter { $0.role == role }.map(\.id))
        case .category(let cat): return Set(fixtures.filter { categories[$0.id] == cat }.map(\.id))
        case .region(let region): return Set(fixtures.filter { inRegion($0, region) }.map(\.id))
        case .named(let name): return resolveName(name)
        case .selection: return all.intersection(selection)
        case .union(let items): return items.reduce(into: Set<UUID>()) { $0.formUnion(resolveSet($1)) }
        case .intersection(let items):
            guard let first = items.first else { return [] }
            return items.dropFirst().reduce(resolveSet(first)) { $0.intersection(resolveSet($1)) }
        case .excluding(let a, let b): return resolveSet(a).subtracting(resolveSet(b))
        }
    }

    // MARK: Regions

    func inRegion(_ f: PatchedFixture, _ region: StageRegion) -> Bool {
        let (sx, sy) = stage.subjectPoint
        let marginX = max(stage.width * 0.06, 0.2)
        let marginY = max(stage.height * 0.08, 0.2)
        let x = f.transform.x, y = f.transform.y
        let isLeft = x < sx - marginX
        let isRight = x > sx + marginX
        let isTop = y < sy - marginY * 2.5
        let isBottom = y > sy + marginY
        switch region {
        case .left: return isLeft
        case .right: return isRight
        case .top: return isTop
        case .bottom: return isBottom
        case .center: return abs(x - sx) <= marginX * 2
        case .topLeft: return isTop && isLeft
        case .topRight: return isTop && isRight
        case .bottomLeft: return isBottom && isLeft
        case .bottomRight: return isBottom && isRight
        case .back:
            if let d = f.transform.depth { return d >= 0.6 }
            return [.background, .back, .hair, .practical].contains(f.role)
        case .front:
            if let d = f.transform.depth { return d <= 0.4 }
            return [.key, .fill].contains(f.role)
        }
    }

    // MARK: Names

    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased()
        let mapped = lowered.map { $0.isLetter || $0.isNumber ? $0 : " " }
        return String(mapped).split(separator: " ").joined(separator: " ")
    }

    static func singular(_ word: String) -> String {
        if word.hasSuffix("ies"), word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count > 3 { return String(word.dropLast()) }
        return word
    }

    func resolveName(_ raw: String) -> Set<UUID> {
        let q = SelectorResolver.normalize(raw)
        guard !q.isEmpty else { return [] }
        if ["all", "everything", "all lights", "every light", "lights", "the lights", "whole room", "room"].contains(q) {
            return Set(fixtures.map(\.id))
        }
        // Exact fixture name / short name.
        let exact = fixtures.filter { SelectorResolver.normalize($0.name) == q || SelectorResolver.normalize($0.shortName) == q }
        if !exact.isEmpty { return Set(exact.map(\.id)) }
        // Group names.
        if let g = groups.first(where: { SelectorResolver.normalize($0.name) == q || SelectorResolver.singular(SelectorResolver.normalize($0.name)) == SelectorResolver.singular(q) }) {
            return Set(fixtures.map(\.id)).intersection(g.fixtureIDs)
        }
        let words = q.split(separator: " ").map { SelectorResolver.singular(String($0)) }
        // Roles.
        for role in FixtureRole.allCases {
            let names = [role.rawValue, SelectorResolver.normalize(role.displayName)] + SelectorResolver.roleSynonyms(role)
            if names.contains(where: { words.contains(SelectorResolver.singular($0)) || q == $0 }) {
                let ids = fixtures.filter { $0.role == role }.map(\.id)
                if !ids.isEmpty { return Set(ids) }
            }
        }
        // Categories ("tubes", "panels").
        for cat in FixtureCategory.allCases {
            let names = [cat.rawValue.lowercased(), SelectorResolver.normalize(cat.displayName)] + SelectorResolver.categorySynonyms(cat)
            if names.contains(where: { words.contains(SelectorResolver.singular($0)) }) {
                let ids = fixtures.filter { categories[$0.id] == cat }.map(\.id)
                if !ids.isEmpty { return Set(ids) }
            }
        }
        // Partial name contains.
        let partial = fixtures.filter {
            let n = SelectorResolver.normalize($0.name)
            return n.contains(q) || (q.count >= 2 && SelectorResolver.normalize($0.shortName).hasPrefix(q))
        }
        return Set(partial.map(\.id))
    }

    static func roleSynonyms(_ role: FixtureRole) -> [String] {
        switch role {
        case .key: return ["key light", "main light", "main"]
        case .fill: return ["fill light"]
        case .back: return ["backlight", "back light", "rim", "rim light", "edge"]
        case .hair: return ["hair light", "top light"]
        case .kicker: return ["kick", "kicker light"]
        case .background: return ["background", "backdrop", "bg", "wall", "set", "background light"]
        case .accent: return ["accent light"]
        case .practical: return ["practicals", "practical light"]
        case .ambient: return ["ambient light", "room light"]
        case .effect: return ["effect light", "fx"]
        case .other: return []
        }
    }

    static func categorySynonyms(_ cat: FixtureCategory) -> [String] {
        switch cat {
        case .tube: return ["tube", "tube light", "stick", "pixel tube", "bar light", "saber"]
        case .panel: return ["panel", "softbox", "soft panel", "light panel"]
        case .spot: return ["spot", "cob", "monolight"]
        case .fresnel: return ["fresnel"]
        case .par: return ["par", "par can", "can"]
        case .bulb: return ["bulb", "lamp"]
        case .strip: return ["strip", "led strip", "tape"]
        case .bar: return ["batten", "bar"]
        case .wash: return ["wash"]
        case .movingHead: return ["moving head", "mover"]
        case .dimmer: return ["dimmer"]
        case .effect, .other: return []
        }
    }
}
