import Foundation

/// Who drives one DMX channel — shown by the Hardware Test's channel monitor.
public struct ChannelOwner: Equatable, Sendable {
    public var fixtureID: UUID
    public var fixtureName: String
    public var shortName: String
    /// e.g. "Red (pixel 3)".
    public var channelName: String
    /// 0-based channel offset within the fixture.
    public var channelIndex: Int
    /// The fixture's position in address order (for alternating tints).
    public var colorIndex: Int

    public init(fixtureID: UUID, fixtureName: String, shortName: String, channelName: String,
                channelIndex: Int, colorIndex: Int) {
        self.fixtureID = fixtureID
        self.fixtureName = fixtureName
        self.shortName = shortName
        self.channelName = channelName
        self.channelIndex = channelIndex
        self.colorIndex = colorIndex
    }
}

/// Which fixture owns each of the 512 channels of a universe, and where patches overlap.
public struct ChannelMap: Sendable {
    public let universe: Int
    /// Index 0 = DMX address 1. When fixtures overlap, the later address wins here and the
    /// address is listed in `conflicts`.
    public private(set) var owners: [ChannelOwner?]
    /// 1-based addresses claimed by more than one fixture.
    public private(set) var conflicts: Set<Int>
    /// Fixtures in this universe, in address order.
    public private(set) var fixtureIDs: [UUID]

    public init(universe: Int, fixtures: [ResolvedFixture]) {
        self.universe = universe
        var owners = [ChannelOwner?](repeating: nil, count: 512)
        var conflicts = Set<Int>()
        let inUniverse = HardwareTestPlan.order(fixtures).filter { $0.fixture.universe == universe }
        for (index, rf) in inUniverse.enumerated() {
            guard let range = rf.addressRange else { continue }
            let channels = rf.mode.channels
            for address in range where address >= 1 && address <= 512 {
                let offset = address - range.lowerBound
                let name = offset < channels.count ? channels[offset].displayName : "Channel \(offset + 1)"
                if owners[address - 1] != nil { conflicts.insert(address) }
                owners[address - 1] = ChannelOwner(
                    fixtureID: rf.id, fixtureName: rf.fixture.name, shortName: rf.fixture.shortName,
                    channelName: name, channelIndex: offset, colorIndex: index)
            }
        }
        self.owners = owners
        self.conflicts = conflicts
        fixtureIDs = inUniverse.map(\.id)
    }

    /// The owner of a 1-based address, or nil when no fixture uses it.
    public func owner(at address: Int) -> ChannelOwner? {
        guard address >= 1, address <= owners.count else { return nil }
        return owners[address - 1]
    }

    /// Number of channels used by patched fixtures.
    public var usedChannelCount: Int { owners.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }
}

/// The logic behind the guided Hardware Test (pure; unit-tested).
public enum HardwareTestPlan {
    /// Patched fixtures in test order: universe, then address, then name.
    public static func order(_ fixtures: [ResolvedFixture]) -> [ResolvedFixture] {
        fixtures.filter { $0.fixture.address != nil }.sorted { a, b in
            if a.fixture.universe != b.fixture.universe { return a.fixture.universe < b.fixture.universe }
            let aa = a.fixture.address ?? 0, ba = b.fixture.address ?? 0
            if aa != ba { return aa < ba }
            return a.fixture.name < b.fixture.name
        }
    }

    /// Universes that have patched fixtures (always includes universe 1).
    public static func universes(_ fixtures: [ResolvedFixture]) -> [Int] {
        Array(Set(fixtures.filter { $0.fixture.address != nil }.map(\.fixture.universe)).union([1])).sorted()
    }

    /// Raw overrides that light only `target` (at `level`, neutral white) and hold every other
    /// patched fixture dark — so the user can see exactly which light answers. With no target,
    /// every fixture is held dark.
    public static func soloOverrides(target: UUID?, fixtures: [ResolvedFixture], level: Double = 0.3) -> [RawOverride] {
        var values: [Int: RawOverride] = [:]
        let ordered = order(fixtures)
        // Others first, the target last so it wins where patches overlap.
        let sequence = ordered.filter { $0.id != target } + ordered.filter { $0.id == target }
        for rf in sequence {
            guard let start = rf.fixture.address else { continue }
            let state = rf.id == target ? FixtureState(intensity: clamp01(level), color: .white) : .off
            let dmx = FixtureRenderer.render(state, fixture: rf)
            for (i, v) in dmx.enumerated() {
                let address = start + i
                guard address >= 1, address <= 512 else { continue }
                let key = rf.fixture.universe * 1000 + address
                values[key] = RawOverride(universe: rf.fixture.universe, address: address, value: v)
            }
        }
        return values.keys.sorted().compactMap { values[$0] }
    }
}
