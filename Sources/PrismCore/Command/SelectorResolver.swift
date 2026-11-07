import Foundation

/// Which way "left" and "right" are read on the stage plan.
public enum SpatialOrientation: String, Codable, CaseIterable, Sendable {
    /// The camera's (viewer's) left — the plan exactly as drawn. Default.
    case viewer
    /// The subject's left — a mirror image of the viewer's.
    case subject

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpatialOrientation(rawValue: raw) ?? .viewer
    }

    /// Short label for settings.
    public var displayName: String {
        switch self {
        case .viewer: return "Camera’s left"
        case .subject: return "Subject’s left"
        }
    }

    /// One-line explanation for settings.
    public var explanation: String {
        switch self {
        case .viewer: return "“Left” means the left of the picture, as the camera sees it."
        case .subject: return "“Left” means the left of the person on camera (mirror image)."
        }
    }
}

/// A fixture's position relative to the subject, normalized to half the stage size.
/// `x < 0` is left (per orientation), `y < 0` is the top of the plan (behind/above the subject).
public struct SpatialPoint: Hashable, Sendable {
    /// Horizontal offset from the subject in half-stage-widths (negative = left).
    public var x: Double
    /// Vertical offset on the plan in half-stage-heights (negative = top/back, positive = toward the camera).
    public var y: Double
    /// Depth 0 (front) … 1 (back) when known.
    public var depth: Double?

    public init(x: Double, y: Double, depth: Double? = nil) {
        self.x = x; self.y = y; self.depth = depth
    }
}

/// Natural-language areas of the room, relative to the subject (a superset of `StageRegion`).
/// Compound areas ("back left") are the intersection of their components.
public enum SpatialArea: String, Codable, CaseIterable, Sendable {
    case left, right, center, top, bottom, front, back, sides
    case topLeft, topRight, bottomLeft, bottomRight
    case backLeft, backRight, backCenter, frontLeft, frontRight, frontCenter

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpatialArea(rawValue: raw) ?? .center
    }

    /// The equivalent area for a `StageRegion`.
    public init(region: StageRegion) {
        switch region {
        case .left: self = .left
        case .right: self = .right
        case .top: self = .top
        case .bottom: self = .bottom
        case .center: self = .center
        case .front: self = .front
        case .back: self = .back
        case .topLeft: self = .topLeft
        case .topRight: self = .topRight
        case .bottomLeft: self = .bottomLeft
        case .bottomRight: self = .bottomRight
        }
    }

    /// The `StageRegion` with the same meaning, when one exists.
    public var stageRegion: StageRegion? {
        switch self {
        case .left: return .left
        case .right: return .right
        case .top: return .top
        case .bottom: return .bottom
        case .center: return .center
        case .front: return .front
        case .back: return .back
        case .topLeft: return .topLeft
        case .topRight: return .topRight
        case .bottomLeft: return .bottomLeft
        case .bottomRight: return .bottomRight
        case .sides, .backLeft, .backRight, .backCenter, .frontLeft, .frontRight, .frontCenter: return nil
        }
    }

    /// Plain-English name ("back left").
    public var displayName: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .center: return "centre"
        case .top: return "top"
        case .bottom: return "bottom"
        case .front: return "front"
        case .back: return "back"
        case .sides: return "sides"
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomRight: return "bottom right"
        case .backLeft: return "back left"
        case .backRight: return "back right"
        case .backCenter: return "back centre"
        case .frontLeft: return "front left"
        case .frontRight: return "front right"
        case .frontCenter: return "front centre"
        }
    }

    /// Left/right swapped ("the other side").
    public var mirrored: SpatialArea {
        switch self {
        case .left: return .right
        case .right: return .left
        case .topLeft: return .topRight
        case .topRight: return .topLeft
        case .bottomLeft: return .bottomRight
        case .bottomRight: return .bottomLeft
        case .backLeft: return .backRight
        case .backRight: return .backLeft
        case .frontLeft: return .frontRight
        case .frontRight: return .frontLeft
        case .top: return .bottom
        case .bottom: return .top
        case .front: return .back
        case .back: return .front
        case .center, .sides, .backCenter, .frontCenter: return self
        }
    }

    /// True when the area has a left/right component (so "the other side" mirrors horizontally).
    public var hasHorizontalSide: Bool {
        components.contains(.left) || components.contains(.right)
    }

    /// The basic areas this one is the intersection of.
    public var components: [SpatialArea] {
        switch self {
        case .topLeft: return [.top, .left]
        case .topRight: return [.top, .right]
        case .bottomLeft: return [.bottom, .left]
        case .bottomRight: return [.bottom, .right]
        case .backLeft: return [.back, .left]
        case .backRight: return [.back, .right]
        case .backCenter: return [.back, .center]
        case .frontLeft: return [.front, .left]
        case .frontRight: return [.front, .right]
        case .frontCenter: return [.front, .center]
        case .left, .right, .center, .top, .bottom, .front, .back, .sides: return [self]
        }
    }

    /// Combines basic areas spoken together ("back" + "left") into one area, if that combination exists.
    public static func combine(_ parts: [SpatialArea]) -> SpatialArea? {
        var set = Set(parts.flatMap(\.components))
        if set.count > 1 { set.remove(.sides) }
        if set.count == 1, let only = set.first { return only }
        if set.count == 2 {
            for area in SpatialArea.allCases where area.components.count == 2 && Set(area.components) == set {
                return area
            }
            // "top centre" / "bottom centre": the vertical word carries the meaning.
            if set.contains(.center) {
                if set.contains(.top) { return .backCenter }
                if set.contains(.bottom) { return .frontCenter }
            }
        }
        return nil
    }
}

/// Spatial words people use for areas of the room ("left-hand side", "overhead", "rear").
public enum SpatialVocabulary {
    /// Single words (already lowercased) that name a basic area.
    public static let words: [String: SpatialArea] = [
        "left": .left, "lefthand": .left, "leftmost": .left,
        "right": .right, "righthand": .right, "rightmost": .right,
        "center": .center, "centre": .center, "middle": .center, "central": .center, "centered": .center, "centred": .center,
        "top": .top, "above": .top, "overhead": .top, "upper": .top, "ceiling": .top, "topmost": .top,
        "bottom": .bottom, "below": .bottom, "beneath": .bottom, "underneath": .bottom, "ground": .bottom, "floor": .bottom,
        "back": .back, "rear": .back, "behind": .back,
        "front": .front, "foreground": .front,
        "sides": .sides
    ]

    /// Multi-word phrases (normalized, single-spaced) that name an area.
    public static let phrases: [String: SpatialArea] = [
        "left hand side": .left, "left hand": .left, "left side": .left, "far left": .left,
        "right hand side": .right, "right hand": .right, "right side": .right, "far right": .right,
        "both sides": .sides, "either side": .sides, "each side": .sides, "the sides": .sides, "left and right": .sides,
        "up top": .top, "up high": .top, "top of the frame": .top, "top of frame": .top, "back wall": .back,
        "down low": .bottom, "on the floor": .bottom, "bottom of the frame": .bottom,
        "in the middle": .center, "dead center": .center
    ]

    /// Parses a whole phrase ("back left", "left-hand side", "overhead") into an area.
    public static func area(forPhrase raw: String) -> SpatialArea? {
        let q = SelectorResolver.normalize(raw)
        guard !q.isEmpty else { return nil }
        if let a = phrases[q] { return a }
        var parts: [SpatialArea] = []
        for word in q.split(separator: " ").map(String.init) {
            if ["the", "on", "to", "at", "in", "far", "hand", "side", "of", "lights", "light", "area", "corner", "wall"].contains(word) { continue }
            guard let a = words[word] else { return nil }
            parts.append(a)
        }
        guard !parts.isEmpty else { return nil }
        return SpatialArea.combine(parts)
    }

    /// Normalizes a word for name matching ("rear" → "back", "centre" → "center").
    public static func canonicalNameWord(_ word: String) -> String {
        switch word {
        case "rear", "behind": return "back"
        case "centre", "middle", "central": return "center"
        case "upper", "above", "overhead": return "top"
        case "lower", "below": return "bottom"
        default: return SelectorResolver.singular(word)
        }
    }
}

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
    /// Which way "left"/"right" are read (default: the camera's view of the plan).
    public var orientation: SpatialOrientation

    public init(fixtures: [PatchedFixture], groups: [FixtureGroup], stage: StageSettings,
                selection: [UUID] = [], categories: [UUID: FixtureCategory] = [:],
                orientation: SpatialOrientation = .viewer) {
        self.fixtures = fixtures; self.groups = groups; self.stage = stage
        self.selection = selection; self.categories = categories
        self.orientation = orientation
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
        order(resolveSet(selector))
    }

    /// Orders ids left→right then top→bottom on the plan (as drawn), then by name.
    public func order(_ set: Set<UUID>) -> [UUID] {
        fixtures
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

    // MARK: Regions & spatial areas

    /// Horizontal distance (normalized) beyond which a fixture counts as left/right of the subject.
    public static let sideThreshold = 0.15
    /// Half-width (normalized) of the centre band.
    public static let centerHalfWidth = 0.22
    /// Plan offsets (normalized) for "top" (behind/above the subject) and "bottom" (toward the camera).
    public static let topThreshold = -0.2
    public static let bottomThreshold = 0.15
    /// Depth thresholds (0 front … 1 back) for "back" and "front" when depth is known.
    public static let backDepth = 0.7
    public static let frontDepth = 0.35
    /// Horizontal distance (normalized) for "both sides".
    public static let sidesThreshold = 0.3

    func inRegion(_ f: PatchedFixture, _ region: StageRegion) -> Bool {
        isIn(f, SpatialArea(region: region))
    }

    /// Where a fixture sits relative to the subject (normalized; honours `orientation`).
    public func spatialPoint(of f: PatchedFixture) -> SpatialPoint {
        let (sx, sy) = stage.subjectPoint
        let halfW = max(stage.width.finiteOr(10) / 2, 0.05)
        let halfH = max(stage.height.finiteOr(6) / 2, 0.05)
        var x = (f.transform.x.finiteOr(sx) - sx) / halfW
        let y = (f.transform.y.finiteOr(sy) - sy) / halfH
        if orientation == .subject { x = -x }
        return SpatialPoint(x: x, y: y, depth: f.transform.depth.map { clamp01($0.finiteOr(0.5)) })
    }

    /// True when the fixture lies in the given area of the room.
    public func isIn(_ f: PatchedFixture, _ area: SpatialArea) -> Bool {
        let p = spatialPoint(of: f)
        switch area {
        case .left: return p.x < -Self.sideThreshold
        case .right: return p.x > Self.sideThreshold
        case .center: return abs(p.x) <= Self.centerHalfWidth
        case .top: return p.y < Self.topThreshold
        case .bottom: return p.y > Self.bottomThreshold
        case .sides: return abs(p.x) > Self.sidesThreshold
        case .back:
            if let d = p.depth { return d >= Self.backDepth }
            return p.y < Self.topThreshold || [.background, .back, .hair, .practical].contains(f.role)
        case .front:
            if let d = p.depth { return d <= Self.frontDepth }
            return p.y > Self.bottomThreshold || [.key, .fill].contains(f.role)
        default:
            return area.components.allSatisfy { isIn(f, $0) }
        }
    }

    /// How strongly a fixture belongs to an area (higher = more; ≤ 0 = not in that direction).
    public func score(_ f: PatchedFixture, _ area: SpatialArea) -> Double {
        let p = spatialPoint(of: f)
        switch area {
        case .left: return -p.x
        case .right: return p.x
        case .center: return Self.centerHalfWidth - abs(p.x)
        case .top: return -p.y
        case .bottom: return p.y
        case .sides: return abs(p.x) - Self.sidesThreshold
        case .back: return p.depth.map { $0 - 0.5 } ?? -p.y
        case .front: return p.depth.map { 0.5 - $0 } ?? p.y
        default: return area.components.map { score(f, $0) }.min() ?? 0
        }
    }

    /// Fixtures in an area, ordered across the stage.
    public func resolve(area: SpatialArea) -> [UUID] {
        order(Set(fixtures.filter { isIn($0, area) }.map(\.id)))
    }

    /// Splits fixtures between several areas so each light gets exactly one ("teal left, blue right,
    /// pink above"): a light goes to the area it belongs to most strongly. Lights in none of the
    /// areas, or too close to call (score ≤ `deadZone`), are left out.
    public func partition(_ areas: [SpatialArea], among ids: [UUID], deadZone: Double = 0.05) -> [SpatialArea: [UUID]] {
        var unique: [SpatialArea] = []
        for a in areas where !unique.contains(a) { unique.append(a) }
        var out: [SpatialArea: [UUID]] = [:]
        for id in order(Set(ids)) {
            guard let f = fixtures.first(where: { $0.id == id }) else { continue }
            var best: (area: SpatialArea, score: Double)?
            for a in unique where isIn(f, a) {
                let s = score(f, a)
                if s > (best?.score ?? -Double.infinity) { best = (a, s) }
            }
            if let b = best, b.score > deadZone { out[b.area, default: []].append(id) }
        }
        return out
    }

    /// For each fixture, the closest fixture on the opposite side of the subject ("the other side").
    /// Fixtures near the centre line map to themselves.
    public func mirror(_ ids: [UUID]) -> [UUID] {
        var out: [UUID] = []
        for id in ids {
            guard let f = fixtures.first(where: { $0.id == id }) else { continue }
            let p = spatialPoint(of: f)
            if abs(p.x) <= Self.sideThreshold / 2 {
                if !out.contains(id) { out.append(id) }
                continue
            }
            var best: (id: UUID, d: Double)?
            for g in fixtures where g.id != id {
                let q = spatialPoint(of: g)
                guard (q.x > 0) != (p.x > 0) else { continue }
                var d = hypot(q.x + p.x, q.y - p.y)
                if g.role != f.role { d += 0.25 }
                if categories[g.id] != categories[f.id] { d += 0.25 }
                if d < (best?.d ?? .infinity) { best = (g.id, d) }
            }
            if let b = best, !out.contains(b.id) { out.append(b.id) }
        }
        return out
    }

    /// Fixtures whose name contains every word (synonyms folded, plurals ignored), preferring the
    /// names with the fewest extra words — "back left" → "Tube Back Left", "left tube" → "Tube Left".
    public func nameMatches(words raw: [String]) -> [UUID] {
        let q = Set(raw.map { SpatialVocabulary.canonicalNameWord(SelectorResolver.normalize($0)) }.filter { !$0.isEmpty })
        guard !q.isEmpty else { return [] }
        var best: [UUID] = []
        var bestExtra = Int.max
        for f in fixtures {
            let words = Set(SelectorResolver.normalize(f.name).split(separator: " ").map { SpatialVocabulary.canonicalNameWord(String($0)) })
            guard q.isSubset(of: words) else { continue }
            let extra = words.subtracting(q).count
            if extra < bestExtra { bestExtra = extra; best = [f.id] } else if extra == bestExtra { best.append(f.id) }
        }
        return order(Set(best))
    }

    /// Short human description of a set of fixtures ("Tube Left and Tube Back Left", "4 lights", "all lights").
    public func describe(_ ids: [UUID]) -> String {
        let names = order(Set(ids)).compactMap { id in fixtures.first { $0.id == id }?.name }
        if names.count > 1 && names.count == fixtures.count { return "all lights" }
        switch names.count {
        case 0: return "no lights"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names.count) lights"
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
        if !partial.isEmpty { return Set(partial.map(\.id)) }
        // Spatial phrases ("left-hand side", "overhead", "back left"): name words first, then the plan.
        // Spatial words never implicitly include the key or fill.
        if let area = SpatialVocabulary.area(forPhrase: q) {
            let named = area.components.count > 1 ? nameMatches(words: area.displayName.split(separator: " ").map(String.init)) : []
            let ids = named.isEmpty ? resolve(area: area) : named
            return Set(ids.filter { id in
                guard let f = fixtures.first(where: { $0.id == id }) else { return false }
                return f.role != .key && f.role != .fill
            })
        }
        return []
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
