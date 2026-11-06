import Foundation

/// Regions of the stage as seen from the camera/viewer.
public enum StageRegion: String, Codable, CaseIterable, Sendable {
    case left, right, top, bottom, center, front, back
    case topLeft, topRight, bottomLeft, bottomRight

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StageRegion(rawValue: raw) ?? .center
    }
}

/// Describes a set of fixtures without naming them explicitly. Used by effects, the command
/// language (assistant, remote, MIDI/OSC), and saved looks. Resolved by `SelectorResolver`.
public indirect enum FixtureSelector: Hashable, Sendable {
    case all
    case none
    case fixtures([UUID])
    case group(UUID)
    case role(FixtureRole)
    case category(FixtureCategory)
    case region(StageRegion)
    /// Fuzzy match on fixture name / short name / group name ("tubes", "left tube", "B3").
    case named(String)
    /// The current UI selection (resolved by the app; resolves to nothing in headless contexts).
    case selection
    case union([FixtureSelector])
    case intersection([FixtureSelector])
    case excluding(FixtureSelector, FixtureSelector)
}

extension FixtureSelector: Codable {
    private enum CodingKeys: String, CodingKey { case type, ids, id, role, category, region, name, items, base, minus }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .type) ?? "all"
        switch type {
        case "none": self = .none
        case "fixtures": self = .fixtures(try c.decodeIfPresent([UUID].self, forKey: .ids) ?? [])
        case "group":
            if let id = try c.decodeIfPresent(UUID.self, forKey: .id) { self = .group(id) } else { self = .none }
        case "role": self = .role(try c.decodeIfPresent(FixtureRole.self, forKey: .role) ?? .other)
        case "category": self = .category(try c.decodeIfPresent(FixtureCategory.self, forKey: .category) ?? .other)
        case "region": self = .region(try c.decodeIfPresent(StageRegion.self, forKey: .region) ?? .center)
        case "named": self = .named(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        case "selection": self = .selection
        case "union": self = .union(try c.decodeIfPresent([FixtureSelector].self, forKey: .items) ?? [])
        case "intersection": self = .intersection(try c.decodeIfPresent([FixtureSelector].self, forKey: .items) ?? [])
        case "excluding":
            let base = try c.decodeIfPresent(FixtureSelector.self, forKey: .base) ?? .all
            let minus = try c.decodeIfPresent(FixtureSelector.self, forKey: .minus) ?? .none
            self = .excluding(base, minus)
        default: self = .all
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all: try c.encode("all", forKey: .type)
        case .none: try c.encode("none", forKey: .type)
        case .fixtures(let ids): try c.encode("fixtures", forKey: .type); try c.encode(ids, forKey: .ids)
        case .group(let id): try c.encode("group", forKey: .type); try c.encode(id, forKey: .id)
        case .role(let r): try c.encode("role", forKey: .type); try c.encode(r, forKey: .role)
        case .category(let cat): try c.encode("category", forKey: .type); try c.encode(cat, forKey: .category)
        case .region(let r): try c.encode("region", forKey: .type); try c.encode(r, forKey: .region)
        case .named(let n): try c.encode("named", forKey: .type); try c.encode(n, forKey: .name)
        case .selection: try c.encode("selection", forKey: .type)
        case .union(let items): try c.encode("union", forKey: .type); try c.encode(items, forKey: .items)
        case .intersection(let items): try c.encode("intersection", forKey: .type); try c.encode(items, forKey: .items)
        case .excluding(let a, let b):
            try c.encode("excluding", forKey: .type); try c.encode(a, forKey: .base); try c.encode(b, forKey: .minus)
        }
    }
}
