import Foundation

// MARK: - PatchMath & Patching Services
//
// Portable DMX addressing math, conflict detection and auto-resolution, universe map modeling,
// stage role auto-placement, fixture replacement (preserving color intent), setup cards,
// CSV/TSV import/export, channel tester patterns, and address scan planning.

public enum AddressingStyle: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Beginner-friendly round addresses (1, 101, 201, 301, 401…) with room to switch modes later.
    case easyNumbers
    /// Tightly packed consecutive addresses (1, 1 + N, …) to fit the maximum number of lights per universe.
    case packed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .easyNumbers: return "Easy numbers (1, 101, 201…)"
        case .packed: return "Compact / packed"
        }
    }

    public var subtitle: String {
        switch self {
        case .easyNumbers:
            return "Starts each light on a clean round number so it's easy to set on the screen."
        case .packed:
            return "Places lights back-to-back with no gaps to fit more pixel lights in one universe."
        }
    }
}

/// DMX address bookkeeping, auto-addressing, universe map layout, and conflict resolution.
public enum PatchMath {

    public struct Conflict: Hashable, Sendable, Identifiable {
        public var id: String { "\(universe)-\(a.uuidString)-\(b.uuidString)" }
        public var universe: Int
        public var a: UUID
        public var b: UUID
        public var overlap: ClosedRange<Int>

        public init(universe: Int, a: UUID, b: UUID, overlap: ClosedRange<Int>) {
            self.universe = universe
            self.a = a
            self.b = b
            self.overlap = overlap
        }
    }

    public struct AddressAssignment: Hashable, Sendable {
        public var universe: Int
        public var address: Int

        public init(universe: Int, address: Int) {
            self.universe = universe
            self.address = address
        }

        /// Formatted 3-digit DMX address for physical fixture displays (e.g. "001", "101").
        public var displayAddress: String {
            String(format: "%03d", clamp(address, 1, 512))
        }
    }

    public struct AddressAllocationResult: Hashable, Sendable {
        public var assignments: [AddressAssignment]
        public var didOverflowUniverse: Bool
        public var overflowMessage: String?

        public init(assignments: [AddressAssignment], didOverflowUniverse: Bool = false, overflowMessage: String? = nil) {
            self.assignments = assignments
            self.didOverflowUniverse = didOverflowUniverse
            self.overflowMessage = overflowMessage
        }
    }

    // MARK: Conflicts & Overflow

    /// All pairs of fixtures whose address ranges overlap (excluding fixtures explicitly tagged `"linked"` at the exact same address).
    public static func conflicts(_ fixtures: [ResolvedFixture]) -> [Conflict] {
        var out: [Conflict] = []
        let patched = fixtures.filter { $0.addressRange != nil }
        for i in patched.indices {
            for j in patched.indices where j > i {
                let a = patched[i], b = patched[j]
                guard a.fixture.universe == b.fixture.universe,
                      let ra = a.addressRange, let rb = b.addressRange else { continue }
                let bothLinked = a.fixture.tags.contains("linked") && b.fixture.tags.contains("linked") && ra == rb
                if bothLinked { continue }
                let lo = max(ra.lowerBound, rb.lowerBound), hi = min(ra.upperBound, rb.upperBound)
                if lo <= hi {
                    out.append(Conflict(universe: a.fixture.universe, a: a.id, b: b.id, overlap: lo...hi))
                }
            }
        }
        return out
    }

    /// First address in `universe` where `channelCount` consecutive channels are free.
    public static func nextFreeAddress(
        channelCount: Int,
        universe: Int,
        fixtures: [ResolvedFixture],
        startingAt: Int = 1
    ) -> Int? {
        let n = clamp(channelCount, 1, 512)
        let used = occupiedTable(universe: universe, fixtures: fixtures)
        var a = max(1, startingAt)
        while a + n - 1 <= 512 {
            if (a..<(a + n)).allSatisfy({ !used[$0] }) { return a }
            a += 1
        }
        return nil
    }

    /// Next free "easy" address in `universe` (`1, 101, 201, 301, 401`, or 50/20/10-step round numbers when 100-steps are full).
    public static func nextEasyAddress(
        channelCount: Int,
        universe: Int,
        fixtures: [ResolvedFixture],
        startingAt: Int = 1
    ) -> Int? {
        let n = clamp(channelCount, 1, 512)
        let used = occupiedTable(universe: universe, fixtures: fixtures)
        let minAddr = max(1, startingAt)

        func isFree(_ start: Int) -> Bool {
            guard start >= minAddr, start + n - 1 <= 512 else { return false }
            return (start..<(start + n)).allSatisfy { !used[$0] }
        }

        // Tier 1: Classic 100-step easy numbers (1, 101, 201, 301, 401, 501)
        let hundredSteps = [1, 101, 201, 301, 401, 501]
        for candidate in hundredSteps where isFree(candidate) {
            return candidate
        }

        // Tier 2: 50-step easy numbers (1, 51, 101, 151, 201, 251, 301, 351, 401, 451, 501)
        for candidate in stride(from: 1, through: 501, by: 50) where isFree(candidate) {
            return candidate
        }

        // Tier 3: 10-step round numbers (1, 11, 21, 31, …)
        for candidate in stride(from: 1, through: 501, by: 10) where isFree(candidate) {
            return candidate
        }

        // Tier 4: Any remaining free slot in this universe
        return nextFreeAddress(channelCount: n, universe: universe, fixtures: fixtures, startingAt: minAddr)
    }

    /// Allocates non-overlapping addresses for `count` fixtures of `channelCount` channels.
    /// Automatically spills into the next universe (`startingUniverse + 1`, etc.) when a universe fills up.
    public static func allocateAddresses(
        channelCount: Int,
        count: Int,
        style: AddressingStyle = .easyNumbers,
        startingUniverse: Int = 1,
        startingAt: Int = 1,
        existing: [ResolvedFixture]
    ) -> AddressAllocationResult {
        let qty = clamp(count, 0, 256)
        guard qty > 0 else { return AddressAllocationResult(assignments: []) }
        let footprint = clamp(channelCount, 1, 512)

        var simulated = existing
        let synthDef = FixtureDefinition(
            id: "_alloc.temp",
            manufacturer: "Temp",
            model: "Temp",
            category: .other,
            modes: [FixtureMode(name: "Temp", channels: Array(repeating: ChannelDefinition(kind: .intensity), count: footprint))]
        )
        let synthMode = synthDef.modes[0]

        var assignments: [AddressAssignment] = []
        var currentUniverse = max(1, startingUniverse)
        var cursorAddress = max(1, startingAt)

        for _ in 0..<qty {
            var placed: AddressAssignment?
            var searchUniverse = currentUniverse
            var searchStart = cursorAddress

            while searchUniverse <= 64 {
                let candidate: Int?
                switch style {
                case .easyNumbers:
                    // First try strictly increasing 100-steps from searchStart so sequential fixtures get 1, 101, 201, 301, 401
                    candidate = nextSequentialEasyAddress(
                        channelCount: footprint,
                        universe: searchUniverse,
                        fixtures: simulated,
                        startingAt: searchStart
                    )
                case .packed:
                    candidate = nextFreeAddress(
                        channelCount: footprint,
                        universe: searchUniverse,
                        fixtures: simulated,
                        startingAt: searchStart
                    )
                }

                if let addr = candidate {
                    let assignment = AddressAssignment(universe: searchUniverse, address: addr)
                    placed = assignment
                    let dummy = PatchedFixture(
                        name: "Temp",
                        definitionID: synthDef.id,
                        modeName: synthMode.name,
                        universe: searchUniverse,
                        address: addr
                    )
                    simulated.append(ResolvedFixture(fixture: dummy, definition: synthDef, mode: synthMode))
                    currentUniverse = searchUniverse
                    cursorAddress = addr + footprint
                    break
                } else {
                    searchUniverse += 1
                    searchStart = 1
                }
            }

            let finalAssignment = placed ?? AddressAssignment(universe: min(currentUniverse + 1, 64), address: 1)
            assignments.append(finalAssignment)
        }

        let overflowed = assignments.filter { $0.universe > startingUniverse }
        let didOverflow = !overflowed.isEmpty
        let message: String?
        if didOverflow {
            let targetUniverses = Array(Set(overflowed.map(\.universe))).sorted()
            let uList = targetUniverses.map { "Universe \($0)" }.joined(separator: ", ")
            if overflowed.count == 1 {
                message = "Universe \(startingUniverse) didn't have enough free channels, so 1 light was placed on \(uList) at address 001."
            } else {
                message = "Universe \(startingUniverse) didn't have enough free channels, so \(overflowed.count) lights were placed on \(uList) starting at address 001."
            }
        } else {
            message = nil
        }

        return AddressAllocationResult(
            assignments: assignments,
            didOverflowUniverse: didOverflow,
            overflowMessage: message
        )
    }

    private static func nextSequentialEasyAddress(
        channelCount: Int,
        universe: Int,
        fixtures: [ResolvedFixture],
        startingAt: Int
    ) -> Int? {
        let n = clamp(channelCount, 1, 512)
        let used = occupiedTable(universe: universe, fixtures: fixtures)
        let minAddr = max(1, startingAt)

        func isFree(_ start: Int) -> Bool {
            guard start >= minAddr, start + n - 1 <= 512 else { return false }
            return (start..<(start + n)).allSatisfy { !used[$0] }
        }

        // Prefer 100-step anchors >= startingAt (1, 101, 201, 301, 401, 501)
        for anchor in [1, 101, 201, 301, 401, 501] where isFree(anchor) {
            return anchor
        }
        // If startingAt > 1 and no 100-step >= startingAt fits, check earlier free 100-steps in the same universe
        for anchor in [1, 101, 201, 301, 401, 501] {
            if anchor + n - 1 <= 512 && (anchor..<(anchor + n)).allSatisfy({ !used[$0] }) {
                return anchor
            }
        }
        // Next try 50-step or 10-step anchors >= startingAt
        for anchor in stride(from: 1, through: 501, by: 50) where isFree(anchor) {
            return anchor
        }
        for anchor in stride(from: 1, through: 501, by: 10) where isFree(anchor) {
            return anchor
        }
        // Fallback to any free slot in this universe
        return nextFreeAddress(channelCount: n, universe: universe, fixtures: fixtures, startingAt: 1)
    }

    /// Fixtures whose range extends past channel 512.
    public static func overflowing(_ fixtures: [ResolvedFixture]) -> [UUID] {
        fixtures.filter { ($0.addressRange?.upperBound ?? 0) > 512 }.map(\.id)
    }

    private static func occupiedTable(
        universe: Int,
        fixtures: [ResolvedFixture],
        excluding excludedID: UUID? = nil
    ) -> [Bool] {
        var used = [Bool](repeating: false, count: 513)
        for f in fixtures where f.fixture.universe == universe && f.id != excludedID {
            guard let r = f.addressRange else { continue }
            for a in r where a >= 1 && a <= 512 {
                used[a] = true
            }
        }
        return used
    }

    // MARK: - Automatic Conflict Resolution

    public struct ConflictResolutionResult: Sendable, Hashable {
        public var fixtures: [PatchedFixture]
        public var changes: [String]

        public init(fixtures: [PatchedFixture], changes: [String]) {
            self.fixtures = fixtures
            self.changes = changes
        }
    }

    /// Automatically resolves any address overlaps and >512 overflows across the rig.
    /// Keeps the first fixture occupying a channel range in place and moves later conflicting fixtures.
    public static func resolveConflicts(
        in fixtures: [PatchedFixture],
        library: (String) -> FixtureDefinition?,
        style: AddressingStyle = .packed
    ) -> ConflictResolutionResult {
        var updated = fixtures
        var changes: [String] = []

        // Pass 1: every light that doesn't clash with an earlier one stays exactly where it is.
        var kept: [ResolvedFixture] = []
        var toMove: [(index: Int, definition: FixtureDefinition, mode: FixtureMode)] = []
        for idx in updated.indices {
            let f = updated[idx]
            guard let def = library(f.definitionID),
                  let mode = def.mode(named: f.modeName) ?? def.recommendedMode else { continue }
            guard let currentAddr = f.address else {
                kept.append(ResolvedFixture(fixture: f, definition: def, mode: mode))
                continue
            }
            let currentEnd = currentAddr + max(1, mode.channelCount) - 1
            let isOverflow = currentEnd > 512
            let isLinked = f.tags.contains("linked")
            let hasOverlap = !isLinked && kept.contains { other in
                guard other.fixture.universe == f.universe, let otherRange = other.addressRange else { return false }
                return max(currentAddr, otherRange.lowerBound) <= min(currentEnd, otherRange.upperBound)
            }
            if !isOverflow && !hasOverlap {
                kept.append(ResolvedFixture(fixture: f, definition: def, mode: mode))
            } else {
                toMove.append((idx, def, mode))
            }
        }

        // Pass 2: only the clashing lights move, into space free of *all* kept lights (so nothing
        // else has to be re-addressed on the physical lights).
        var accepted = kept
        for item in toMove {
            let f = updated[item.index]
            let currentAddr = f.address ?? 1
            let footprint = max(1, item.mode.channelCount)
            // Prefer the nearest gap after where the light is now, then any gap in the same
            // universe, and only then the next universe (most studios have just one).
            var placement = allocateAddresses(
                channelCount: footprint, count: 1, style: style,
                startingUniverse: f.universe, startingAt: currentAddr, existing: accepted
            ).assignments.first
            if let first = placement, first.universe != f.universe, currentAddr > 1 {
                let fromStart = allocateAddresses(
                    channelCount: footprint, count: 1, style: style,
                    startingUniverse: f.universe, startingAt: 1, existing: accepted
                ).assignments.first
                if let fromStart, fromStart.universe == f.universe { placement = fromStart }
            }
            guard let assigned = placement else { continue }
            let oldU = f.universe
            updated[item.index].universe = assigned.universe
            updated[item.index].address = assigned.address
            accepted.append(ResolvedFixture(fixture: updated[item.index], definition: item.definition, mode: item.mode))
            if assigned.universe != oldU {
                changes.append("Moved \(f.name) from universe \(oldU) address \(String(format: "%03d", currentAddr)) to universe \(assigned.universe) address \(assigned.displayAddress).")
            } else {
                changes.append("Moved \(f.name) from \(String(format: "%03d", currentAddr)) to \(assigned.displayAddress).")
            }
        }

        return ConflictResolutionResult(fixtures: updated, changes: changes)
    }

    // MARK: - 512-Cell Universe Map & Budget

    public struct UniverseBlock: Hashable, Sendable, Identifiable {
        public var id: UUID { fixtureID }
        public var fixtureID: UUID
        public var name: String
        public var shortName: String
        public var modelName: String
        public var modeName: String
        public var role: FixtureRole
        public var universe: Int
        public var range: ClosedRange<Int>
        public var isConflicting: Bool
        public var isOverflowing: Bool

        public var startAddress: Int { range.lowerBound }
        public var endAddress: Int { range.upperBound }
        public var channelCount: Int { range.count }
    }

    public struct UniverseSummary: Hashable, Sendable {
        public var universe: Int
        public var usedChannelCount: Int
        public var freeChannelCount: Int
        public var blocks: [UniverseBlock]
        public var conflicts: [Conflict]
        public var conflictChannels: Set<Int>
        public var gaps: [ClosedRange<Int>]
        /// For each channel 1…512 (indexed 0…511), the fixture ID occupying it, if any.
        public var channelOwners: [UUID?]

        public var utilization: Double {
            Double(usedChannelCount) / 512.0
        }
    }

    /// Computes a full 512-channel map summary for `universe`.
    public static func universeSummary(universe: Int, fixtures: [ResolvedFixture]) -> UniverseSummary {
        let inUniverse = fixtures.filter { $0.fixture.universe == universe && $0.addressRange != nil }
        let uConflicts = conflicts(inUniverse)
        let conflictingIDs = Set(uConflicts.flatMap { [$0.a, $0.b] })
        let overflowingIDs = Set(overflowing(inUniverse))

        var conflictChannels = Set<Int>()
        for c in uConflicts {
            for ch in c.overlap where (1...512).contains(ch) {
                conflictChannels.insert(ch)
            }
        }

        var owners = [UUID?](repeating: nil, count: 512)
        var blocks: [UniverseBlock] = []

        for rf in inUniverse.sorted(by: { ($0.fixture.address ?? 999) < ($1.fixture.address ?? 999) }) {
            guard let range = rf.addressRange else { continue }
            for ch in range where (1...512).contains(ch) {
                owners[ch - 1] = rf.id
            }
            blocks.append(UniverseBlock(
                fixtureID: rf.id,
                name: rf.fixture.name,
                shortName: rf.fixture.stageLabel,
                modelName: rf.definition.displayName,
                modeName: rf.mode.name,
                role: rf.fixture.role,
                universe: universe,
                range: range,
                isConflicting: conflictingIDs.contains(rf.id),
                isOverflowing: overflowingIDs.contains(rf.id)
            ))
        }

        let usedCount = owners.compactMap { $0 }.count
        var gaps: [ClosedRange<Int>] = []
        var gapStart: Int?
        for ch in 1...512 {
            if owners[ch - 1] == nil {
                if gapStart == nil { gapStart = ch }
            } else if let s = gapStart {
                gaps.append(s...(ch - 1))
                gapStart = nil
            }
        }
        if let s = gapStart {
            gaps.append(s...512)
        }

        return UniverseSummary(
            universe: universe,
            usedChannelCount: usedCount,
            freeChannelCount: 512 - usedCount,
            blocks: blocks,
            conflicts: uConflicts,
            conflictChannels: conflictChannels,
            gaps: gaps,
            channelOwners: owners
        )
    }

    /// Snaps a dragged address on the universe map to nearby clean boundaries (`1, 101, 201…` or adjacent fixture edges)
    /// while avoiding overlaps when a nearby conflict-free slot is within `snapTolerance` channels.
    public static func snapAddress(
        proposed: Int,
        channelCount: Int,
        universe: Int,
        movingFixtureID: UUID,
        fixtures: [ResolvedFixture],
        snapTolerance: Int = 4
    ) -> Int {
        let n = clamp(channelCount, 1, 512)
        let maxStart = max(1, 512 - n + 1)
        let raw = clamp(proposed, 1, maxStart)
        let used = occupiedTable(universe: universe, fixtures: fixtures, excluding: movingFixtureID)

        func isFree(_ start: Int) -> Bool {
            guard start >= 1, start <= maxStart else { return false }
            return (start..<(start + n)).allSatisfy { !used[$0] }
        }

        // Collect magnetic snap points: 1, easy numbers, and edges of other fixtures
        var snapPoints: [Int] = [1, 101, 201, 301, 401, 501]
        for f in fixtures where f.fixture.universe == universe && f.id != movingFixtureID {
            if let r = f.addressRange {
                snapPoints.append(r.upperBound + 1)
                snapPoints.append(r.lowerBound - n)
            }
        }
        let validSnaps = snapPoints.filter { isFree($0) }
        if let nearest = validSnaps.min(by: { abs($0 - raw) < abs($1 - raw) }),
           abs(nearest - raw) <= snapTolerance {
            return nearest
        }

        if isFree(raw) { return raw }

        // Search outward for nearest non-overlapping slot
        for delta in 1...512 {
            if isFree(raw + delta) { return raw + delta }
            if isFree(raw - delta) { return raw - delta }
        }
        return raw
    }

    // MARK: - Role-Based Stage Auto-Placement

    /// Suggests a sensible stage position and rotation for a newly added fixture based on its `FixtureRole`.
    public static func suggestTransform(
        role: FixtureRole,
        index: Int,
        count: Int,
        stage: StageSettings,
        existingCount: Int = 0
    ) -> StageTransform {
        let w = max(stage.width, 2.0)
        let h = max(stage.height, 2.0)
        let subj = stage.subjectPoint
        let n = max(count, 1)
        let frac = Double(index + 1) / Double(n + 1)
        let spread = (Double(index) - Double(n - 1) / 2.0)

        switch role {
        case .key:
            return StageTransform(
                x: clamp(subj.x - w * 0.18 + spread * 0.45, 0.4, w - 0.4),
                y: clamp(subj.y + h * 0.22, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.1
            )
        case .fill:
            return StageTransform(
                x: clamp(subj.x + w * 0.20 + spread * 0.45, 0.4, w - 0.4),
                y: clamp(subj.y + h * 0.20, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.15
            )
        case .back, .hair:
            return StageTransform(
                x: clamp(subj.x + spread * 0.65, 0.4, w - 0.4),
                y: clamp(subj.y - h * 0.22, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.75
            )
        case .kicker:
            let side: Double = (index % 2 == 0) ? -1.0 : 1.0
            return StageTransform(
                x: clamp(subj.x + side * w * 0.26, 0.4, w - 0.4),
                y: clamp(subj.y - h * 0.10, 0.4, h - 0.4),
                rotation: side < 0 ? 45 : 315,
                scale: 1,
                depth: 0.65
            )
        case .background:
            return StageTransform(
                x: clamp(w * frac, 0.5, w - 0.5),
                y: clamp(h * 0.22, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.9
            )
        case .accent, .practical:
            return StageTransform(
                x: clamp(w * frac, 0.5, w - 0.5),
                y: clamp(subj.y + h * 0.12, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.35
            )
        case .ambient, .effect, .other:
            let rowOffset = Double((existingCount + index) % 3) * 0.35
            return StageTransform(
                x: clamp(w * frac, 0.5, w - 0.5),
                y: clamp(h * 0.32 + rowOffset, 0.4, h - 0.4),
                rotation: 0,
                scale: 1,
                depth: 0.6
            )
        }
    }

    /// Suggests a concise stage label (e.g. `"B9"`, `"KEY"`, `"FL1"`, `"L1"`).
    public static func suggestShortName(
        role: FixtureRole,
        category: FixtureCategory,
        existingFixtures: [PatchedFixture]
    ) -> String {
        let existingLabels = Set(existingFixtures.map { $0.stageLabel.uppercased() })
        let prefix: String
        if category == .tube || category == .bar {
            prefix = "B"
        } else if category == .panel {
            prefix = "PN"
        } else {
            switch role {
            case .key: prefix = "K"
            case .fill: prefix = "F"
            case .back, .hair: prefix = "BK"
            case .background: prefix = "BG"
            case .practical: prefix = "P"
            default: prefix = "L"
            }
        }
        var n = 1
        while existingLabels.contains("\(prefix)\(n)") {
            n += 1
        }
        return "\(prefix)\(n)"
    }

    // MARK: - Replace Fixture Preserving Looks

    /// Replaces a fixture's definition and mode in `document`, preserving its position, role, and
    /// color intent across all saved looks and the live state. Resamples pixel cell states if pixel
    /// counts differ.
    public static func replaceFixture(
        fixtureID: UUID,
        newDefinition: FixtureDefinition,
        newModeName: String,
        in document: inout ShowDocument,
        library: (String) -> FixtureDefinition?
    ) -> String? {
        guard let idx = document.project.fixtures.firstIndex(where: { $0.id == fixtureID }) else {
            return nil
        }
        guard let newMode = newDefinition.mode(named: newModeName) ?? newDefinition.recommendedMode else {
            return nil
        }

        let oldFixture = document.project.fixtures[idx]
        var updated = oldFixture
        updated.definitionID = newDefinition.id
        updated.modeName = newMode.name

        // Ensure definition is embedded if needed
        if let existingDefIdx = document.project.definitions.firstIndex(where: { $0.id == newDefinition.id }) {
            document.project.definitions[existingDefIdx] = newDefinition
        } else {
            document.project.definitions.append(newDefinition)
        }

        // Adapt cell states in all looks and live state
        let newCellCount = newMode.cellCount
        for lookIdx in document.project.looks.indices {
            if let oldState = document.project.looks[lookIdx].states[fixtureID] {
                document.project.looks[lookIdx].states[fixtureID] = adaptStateForMode(oldState, newCellCount: newCellCount)
            }
        }
        if let liveState = document.live.base[fixtureID] {
            document.live.base[fixtureID] = adaptStateForMode(liveState, newCellCount: newCellCount)
        }

        // Check if the new channel count causes an address overflow or overlap
        if let addr = updated.address {
            let newEnd = addr + max(newMode.channelCount, 1) - 1
            let otherResolved: [ResolvedFixture] = document.project.fixtures.compactMap { fx in
                guard fx.id != fixtureID else { return nil }
                guard let def = document.project.definitions.first(where: { $0.id == fx.definitionID }) ?? library(fx.definitionID),
                      let mode = def.mode(named: fx.modeName) ?? def.recommendedMode else { return nil }
                return ResolvedFixture(fixture: fx, definition: def, mode: mode)
            }
            let overlapsOther = otherResolved.contains { other in
                guard other.fixture.universe == updated.universe, let r = other.addressRange else { return false }
                return max(addr, r.lowerBound) <= min(newEnd, r.upperBound)
            }
            if newEnd > 512 || overlapsOther {
                let alloc = allocateAddresses(
                    channelCount: newMode.channelCount,
                    count: 1,
                    style: .easyNumbers,
                    startingUniverse: updated.universe,
                    startingAt: addr,
                    existing: otherResolved
                )
                if let assigned = alloc.assignments.first {
                    updated.universe = assigned.universe
                    updated.address = assigned.address
                }
            }
        }

        document.project.fixtures[idx] = updated
        return "Replaced \(oldFixture.name) with \(newDefinition.displayName) (\(newMode.name))."
    }

    private static func adaptStateForMode(_ state: FixtureState, newCellCount: Int) -> FixtureState {
        var adapted = state
        guard let cells = state.cells, !cells.isEmpty else { return adapted }
        if newCellCount <= 0 {
            // Collapse pixel cells into whole-fixture color
            adapted.color = cells[cells.count / 2].color
            adapted.cells = nil
        } else if cells.count != newCellCount {
            if cells.count == 1 {
                adapted.cells = Array(repeating: cells[0], count: newCellCount)
            } else {
                adapted.cells = (0..<newCellCount).map { i in
                    let pos = Double(i) / Double(max(newCellCount - 1, 1)) * Double(cells.count - 1)
                    let lo = clamp(Int(floor(pos)), 0, cells.count - 1)
                    let hi = clamp(Int(ceil(pos)), 0, cells.count - 1)
                    return CellState.mix(cells[lo], cells[hi], pos - Double(lo))
                }
            }
        }
        return adapted
    }

    // MARK: - DIP Switch Helper

    /// Returns the 9 binary DIP switch states (switches 1…9, where switch 1 = +1, switch 9 = +256)
    /// for a 1-based DMX address (1…511).
    public static func dipSwitches(for address: Int) -> [Bool] {
        let clamped = clamp(address, 1, 511)
        return (0..<9).map { bit in
            ((clamped >> bit) & 1) == 1
        }
    }
}

// MARK: - Setup Cards Generator

public struct SetupCard: Hashable, Sendable, Identifiable {
    public var id: UUID { fixtureID }
    public var fixtureID: UUID
    public var fixtureName: String
    public var shortName: String
    public var modelDisplayName: String
    public var universe: Int
    public var address: Int
    /// Zero-padded 3-digit display string, e.g. `"001"`, `"113"`, matching physical fixture screens.
    public var formattedAddress: String
    /// Exact mode name shown on the fixture's own menu screen (e.g. `"9: LE CCT&RGB 8px"` or `"CCT&RGB"`).
    public var fixtureMenuModeName: String
    public var modeSummary: String
    public var channelCount: Int
    /// Headline instruction, e.g. `"Set Tube B3 to address A113, mode CCT&RGB 8PX"`.
    public var headline: String
    /// Numbered steps tailored to this fixture model.
    public var steps: [String]
    /// Important model-specific callout (e.g. amaran PT screen-lock tip).
    public var importantTip: String?
    /// 9-switch DIP states for DIP-switch fixtures.
    public var dipSwitches: [Bool]
    /// True if the fixture uses physical DIP switches by default.
    public var usesDipSwitches: Bool
    /// Optional connector note (e.g. "USB-C → DMX adapter (sold separately)").
    public var connector: String?
    /// Optional manual URL.
    public var manualURL: String?

    public init(
        fixtureID: UUID,
        fixtureName: String,
        shortName: String,
        modelDisplayName: String,
        universe: Int,
        address: Int,
        formattedAddress: String,
        fixtureMenuModeName: String,
        modeSummary: String,
        channelCount: Int,
        headline: String,
        steps: [String],
        importantTip: String?,
        dipSwitches: [Bool],
        usesDipSwitches: Bool = false,
        connector: String? = nil,
        manualURL: String? = nil
    ) {
        self.fixtureID = fixtureID
        self.fixtureName = fixtureName
        self.shortName = shortName
        self.modelDisplayName = modelDisplayName
        self.universe = universe
        self.address = address
        self.formattedAddress = formattedAddress
        self.fixtureMenuModeName = fixtureMenuModeName
        self.modeSummary = modeSummary
        self.channelCount = channelCount
        self.headline = headline
        self.steps = steps
        self.importantTip = importantTip
        self.dipSwitches = dipSwitches
        self.usesDipSwitches = usesDipSwitches
        self.connector = connector
        self.manualURL = manualURL
    }
}

public enum SetupCardGenerator {

    public static func cards(for fixtures: [ResolvedFixture]) -> [SetupCard] {
        fixtures.compactMap { rf in
            guard let addr = rf.fixture.address else { return nil }
            return makeCard(for: rf, address: addr)
        }
    }

    public static func makeCard(for rf: ResolvedFixture, address: Int) -> SetupCard {
        let clamped = clamp(address, 1, 512)
        let padded = rf.definition.setupGuide?.formatAddress(clamped) ?? String(format: "%03d", clamped)
        let headlineAddr = padded.first?.isLetter == true ? padded : "A\(String(format: "%03d", clamped))"
        let menuMode = fixtureMenuName(for: rf.definition, mode: rf.mode)
        let label = rf.fixture.shortName.isEmpty ? rf.fixture.name : "\(rf.fixture.name) (\(rf.fixture.shortName))"
        let headline = "Set \(label) to address \(headlineAddr), mode \(menuMode)"
        let (steps, tip) = buildInstructions(for: rf.definition, mode: rf.mode, paddedAddress: padded, menuMode: menuMode, rawAddress: clamped)

        return SetupCard(
            fixtureID: rf.id,
            fixtureName: rf.fixture.name,
            shortName: rf.fixture.stageLabel,
            modelDisplayName: rf.definition.displayName,
            universe: rf.fixture.universe,
            address: clamped,
            formattedAddress: padded,
            fixtureMenuModeName: menuMode,
            modeSummary: rf.mode.friendlyName ?? rf.mode.summary ?? rf.mode.capabilities.badge,
            channelCount: rf.mode.channelCount,
            headline: headline,
            steps: steps,
            importantTip: tip,
            dipSwitches: PatchMath.dipSwitches(for: clamped),
            usesDipSwitches: rf.definition.setupGuide?.usesDipSwitches ?? (rf.definition.category == .dimmer || rf.definition.category == .par),
            connector: rf.definition.setupGuide?.connector,
            manualURL: rf.definition.sourceURL
        )
    }

    /// Maps a Prism mode to the exact menu text shown on the physical fixture screen.
    public static func fixtureMenuName(for def: FixtureDefinition, mode: FixtureMode) -> String {
        if let explicit = mode.fixtureMenuName, !explicit.isEmpty {
            return explicit
        }
        let mfg = def.manufacturer.lowercased()
        let model = def.model.lowercased()
        let name = mode.name

        if (mfg.contains("amaran") || mfg.contains("aputure")) && model.contains("pt") {
            switch mode.channelCount {
            case 10: return "1: CCT&RGB 8-bit"
            case 6 where name.lowercased().contains("cct"): return "2: CCT 8-bit"
            case 9: return "3: CCT&HSI 8-bit"
            case 7 where !name.lowercased().contains("fx"): return "4: RGB 8-bit"
            case 6: return "5: HSI 8-bit"
            case 7: return "6: System FX"
            case 14: return "7: LE CCT&RGB 2PX"
            case 28: return "8: LE CCT&RGB 4PX"
            case 56: return "9: LE CCT&RGB 8PX"
            case 112: return "10: LE CCT&RGB 16PX"
            case 12: return "12: LE HSI 4PX"
            case 24: return "13: LE HSI 8PX"
            case 48: return "14: LE HSI 16PX"
            default: break
            }
        }
        return mode.shortName.map { "\(mode.name) (\($0))" } ?? mode.name
    }

    private static func buildInstructions(
        for def: FixtureDefinition,
        mode: FixtureMode,
        paddedAddress: String,
        menuMode: String,
        rawAddress: Int
    ) -> (steps: [String], tip: String?) {
        if let guide = def.setupGuide, (!guide.addressMenuPath.isEmpty || !guide.modeMenuPath.isEmpty || guide.usesDipSwitches) {
            var steps: [String] = []
            if let conn = guide.connector, !conn.isEmpty {
                steps.append("Connect DMX cable via \(conn).")
            }
            if guide.usesDipSwitches {
                let onSwitches = PatchMath.dipSwitches(for: rawAddress).enumerated().compactMap { $0.element ? "\($0.offset + 1)" : nil }
                steps.append("Flip DIP switches ON: \(onSwitches.isEmpty ? "None" : onSwitches.joined(separator: ", ")) (all others OFF) for address \(rawAddress).")
            } else {
                if !guide.addressMenuPath.isEmpty {
                    steps.append("Open \(guide.addressMenuBreadcrumb) → set to \(paddedAddress).")
                } else {
                    steps.append("Set DMX Address to \(paddedAddress).")
                }
                if !guide.modeMenuPath.isEmpty {
                    steps.append("Open \(guide.modeMenuBreadcrumb) → choose \(menuMode) (\(mode.channelCount) ch).")
                } else {
                    steps.append("Select DMX Mode \(menuMode) (\(mode.channelCount) ch).")
                }
            }
            if let loss = guide.signalLossBehavior, !loss.isEmpty {
                steps.append("Set DMX Loss Behavior to \(loss).")
            }
            let tip = guide.notes.isEmpty ? def.notes : guide.notes.joined(separator: " ")
            return (steps, tip)
        }

        let mfg = def.manufacturer.lowercased()
        let model = def.model.lowercased()

        if (mfg.contains("amaran") || mfg.contains("aputure")) && (model.contains("pt") || model.contains("tube")) {
            let steps = [
                "Plug the amaran USB-C to DMX adapter into the tube's USB-C port and connect your DMX cable.",
                "Press MENU on the back of the tube, then use ▲/▼ and OK to open DMX Settings.",
                "Select DMX Address → set to \(paddedAddress).",
                "Select DMX Profiles → choose \(menuMode).",
                "Select DMX Loss Behavior → choose Hold Last Setting (keeps lights steady if the Mac sleeps).",
                "Return to the DMX Address screen (\(paddedAddress)) and hold OK for 2 seconds to lock the screen."
            ]
            let tip = "Crucial for amaran PT tubes: the tube ONLY listens to DMX while the DMX Address screen stays open on its display. Hold OK for 2s to lock it."
            return (steps, tip)
        }

        if mfg.contains("aputure") || mfg.contains("amaran") {
            let steps = [
                "Connect the DMX cable to DMX IN (using the USB-C to DMX adapter if required by your model).",
                "Press MENU → DMX Settings.",
                "Set DMX Address to \(paddedAddress).",
                "Set DMX Profile / Mode to \(menuMode).",
                "Set DMX Loss Behavior to Hold Last Setting."
            ]
            return (steps, def.notes)
        }

        if let help = def.addressHelp, !help.isEmpty {
            let lines = help.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            var steps = lines
            steps.append("Set DMX Address to \(paddedAddress) and Mode to \(menuMode) (\(mode.channelCount) ch).")
            return (steps, def.notes)
        }

        let genericSteps = [
            "Connect a DMX cable from your DMX interface (or previous light's DMX OUT) to this light's DMX IN.",
            "Open the DMX Address menu on the light and set it to A\(paddedAddress) (or d\(paddedAddress)).",
            "Select the \(menuMode) (\(mode.channelCount)-channel) mode.",
            "Click 'Test Light' in Prism to blink the light and confirm it responds."
        ]
        return (genericSteps, def.notes)
    }

    /// Renders a clean printable HTML document for exporting or printing Setup Cards.
    public static func renderPrintableHTML(projectTitle: String, cards: [SetupCard]) -> String {
        var html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(projectTitle)) — Prism Setup Cards</title>
        <style>
        body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #0B0D12; color: #F3F4F6; padding: 24px; }
        h1 { font-size: 22px; margin-bottom: 4px; }
        .sub { color: #9CA3AF; font-size: 13px; margin-bottom: 20px; }
        .card { background: #12151C; border: 1px solid #2A3040; border-radius: 12px; padding: 16px; margin-bottom: 14px; page-break-inside: avoid; }
        .header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 10px; }
        .title { font-size: 16px; font-weight: 600; }
        .badge { font-family: ui-monospace, monospace; font-size: 18px; font-weight: 700; color: #7C8CFF; }
        ol { margin: 8px 0 8px 20px; padding: 0; font-size: 13px; line-height: 1.5; }
        .tip { background: rgba(251, 191, 36, 0.12); border-left: 3px solid #FBBF24; padding: 8px 12px; font-size: 12px; margin-top: 8px; border-radius: 4px; }
        </style>
        </head>
        <body>
        <h1>\(escapeHTML(projectTitle)) — Light Setup Cards</h1>
        <div class="sub">Generated by Prism · \(cards.count) light\(cards.count == 1 ? "" : "s")</div>
        """
        for card in cards {
            html += """
            <div class="card">
              <div class="header">
                <div class="title">\(escapeHTML(card.fixtureName)) (\(escapeHTML(card.shortName))) — \(escapeHTML(card.modelDisplayName))</div>
                <div class="badge">U\(card.universe) · A\(escapeHTML(card.formattedAddress)) · \(escapeHTML(card.fixtureMenuModeName))</div>
              </div>
              <ol>
            """
            for step in card.steps {
                html += "    <li>\(escapeHTML(step))</li>\n"
            }
            html += "  </ol>\n"
            if let tip = card.importantTip {
                html += "  <div class=\"tip\">\(escapeHTML(tip))</div>\n"
            }
            html += "</div>\n"
        }
        html += "</body></html>"
        return html
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - CSV / TSV Patch Import & Export

public enum PatchCSV {

    /// Exports the current patch to CSV format.
    public static func exportCSV(fixtures: [ResolvedFixture]) -> String {
        var lines = ["Name,Label,Manufacturer,Model,Mode,Channels,Universe,Address,Role"]
        for rf in fixtures {
            let fields = [
                escapeCSV(rf.fixture.name),
                escapeCSV(rf.fixture.shortName),
                escapeCSV(rf.definition.manufacturer),
                escapeCSV(rf.definition.model),
                escapeCSV(rf.mode.name),
                "\(rf.channelCount)",
                "\(rf.fixture.universe)",
                rf.fixture.address.map { "\($0)" } ?? "",
                rf.fixture.role.rawValue,
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Plain-English patch summary suitable for copying to the clipboard or sharing in production notes.
    public static func patchSummaryText(projectName: String, fixtures: [ResolvedFixture]) -> String {
        var lines: [String] = ["\(projectName) — Patch Summary (\(fixtures.count) lights)"]
        lines.append(String(repeating: "─", count: 56))
        for rf in fixtures.sorted(by: { ($0.fixture.universe, $0.fixture.address ?? 999) < ($1.fixture.universe, $1.fixture.address ?? 999) }) {
            let addrStr = rf.addressRange.map { String(format: "U%d · %03d–%03d", rf.fixture.universe, $0.lowerBound, $0.upperBound) } ?? "Unpatched"
            let label = rf.fixture.shortName.isEmpty ? rf.fixture.name : "\(rf.fixture.shortName) (\(rf.fixture.name))"
            lines.append("\(addrStr.padding(toLength: 15, withPad: " ", startingAt: 0))  \(label) — \(rf.definition.displayName) [\(rf.mode.name), \(rf.channelCount) ch]")
        }
        return lines.joined(separator: "\n")
    }

    /// Imports fixtures from a Prism or Lightkey CSV/TSV patch export.
    public static func importCSV(
        _ text: String,
        stage: StageSettings = StageSettings(),
        library: ((String) -> FixtureDefinition?)? = nil
    ) -> (fixtures: [PatchedFixture], definitions: [FixtureDefinition], warnings: [String]) {
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rawLines.isEmpty else { return ([], [], ["CSV file is empty."]) }

        let delimiter: Character = rawLines[0].contains("\t") ? "\t" : ","
        let header = parseRow(rawLines[0], delimiter: delimiter).map { $0.lowercased() }

        let hasHeader = header.contains(where: { ["name", "label", "short name", "address", "universe", "model", "fixture"].contains($0) })
        let dataLines = hasHeader ? Array(rawLines.dropFirst()) : rawLines

        func colIndex(_ candidates: [String]) -> Int? {
            guard hasHeader else { return nil }
            return header.firstIndex { h in candidates.contains { h == $0 || h.contains($0) } }
        }

        let nameCol = colIndex(["name", "fixture name", "description"]) ?? 0
        let labelCol = colIndex(["label", "short name", "shortname", "id"])
        let mfgCol = colIndex(["manufacturer", "brand", "make"])
        let modelCol = colIndex(["model", "fixture", "type"])
        let modeCol = colIndex(["mode", "personality"])
        let chCol = colIndex(["channels", "footprint", "ch"])
        let univCol = colIndex(["universe", "univ"])
        let addrCol = colIndex(["address", "start address", "dmx address", "dmx", "start"])
        let roleCol = colIndex(["role"])

        var fixtures: [PatchedFixture] = []
        var embedded: [String: FixtureDefinition] = [:]
        var warnings: [String] = []

        for (idx, line) in dataLines.enumerated() {
            let cols = parseRow(line, delimiter: delimiter)
            guard !cols.isEmpty else { continue }

            func field(_ c: Int?) -> String {
                guard let c, c >= 0, c < cols.count else { return "" }
                return cols[c].trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let rawName = field(nameCol)
            let shortName = field(labelCol)
            let mfg = field(mfgCol).isEmpty ? "Generic" : field(mfgCol)
            let model = field(modelCol).isEmpty ? (rawName.isEmpty ? "Light" : rawName) : field(modelCol)
            let modeStr = field(modeCol)
            let chCount = Int(field(chCol).filter { $0.isNumber }) ?? 1
            let universe = max(1, Int(field(univCol).filter { $0.isNumber }) ?? 1)
            let addrText = field(addrCol)
            let parsedAddr = parseAddressField(addrText)
            let role = FixtureRole(rawValue: field(roleCol).lowercased()) ?? .other

            let (def, mode) = matchOrBuildCSVDefinition(
                manufacturer: mfg,
                model: model,
                modeName: modeStr,
                channelCount: chCount,
                library: library,
                warnings: &warnings
            )
            embedded[def.id] = def

            let transform = PatchMath.suggestTransform(role: role, index: idx, count: max(dataLines.count, 1), stage: stage)
            let name = rawName.isEmpty ? "\(def.model) \(idx + 1)" : rawName
            fixtures.append(PatchedFixture(
                name: name,
                shortName: shortName,
                definitionID: def.id,
                modeName: mode.name,
                universe: universe,
                address: parsedAddr,
                role: role,
                transform: transform
            ))
        }

        return (fixtures, Array(embedded.values), warnings)
    }

    private static func parseAddressField(_ raw: String) -> Int? {
        guard !raw.isEmpty else { return nil }
        // Handle "1", "001", "1–49", "U1.017", "1/17"
        let parts = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
        if parts.count >= 2 && (raw.contains("/") || raw.contains(".") || raw.lowercased().hasPrefix("u")) {
            if let a = Int(parts[1]), (1...512).contains(a) { return a }
        }
        if let first = parts.first, let a = Int(first), (1...512).contains(a) {
            return a
        }
        return nil
    }

    private static func matchOrBuildCSVDefinition(
        manufacturer: String,
        model: String,
        modeName: String,
        channelCount: Int,
        library: ((String) -> FixtureDefinition?)?,
        warnings: inout [String]
    ) -> (FixtureDefinition, FixtureMode) {
        let candID = FixtureDefinition.makeID(manufacturer: manufacturer, model: model)
        if let def = library?(candID) {
            if let mode = def.mode(named: modeName) ?? def.modes.first(where: { $0.channelCount == channelCount }) ?? def.recommendedMode {
                return (def, mode)
            }
        }
        if model.lowercased().contains("pt") && (manufacturer.lowercased().contains("amaran") || manufacturer.lowercased().contains("aputure")) {
            let pt = library?("amaran.pt4c") ?? BuiltinImportDefinitions.amaranPT4c
            let mode = pt.mode(named: modeName) ?? pt.modes.first(where: { $0.channelCount == channelCount }) ?? pt.recommendedMode ?? pt.modes[0]
            return (pt, mode)
        }
        if channelCount == 1 {
            let dim = library?("generic.dimmer") ?? BuiltinImportDefinitions.genericDimmer
            return (dim, dim.modes[0])
        }
        let channels = (0..<max(channelCount, 1)).map { idx -> ChannelDefinition in
            switch idx {
            case 0: return ChannelDefinition(kind: .intensity)
            case 1: return ChannelDefinition(kind: .red)
            case 2: return ChannelDefinition(kind: .green)
            case 3: return ChannelDefinition(kind: .blue)
            default: return ChannelDefinition(kind: .generic, label: "Ch \(idx + 1)")
            }
        }
        let mName = modeName.isEmpty ? "\(channelCount)ch" : modeName
        let mode = FixtureMode(name: mName, shortName: "\(channelCount)ch", channels: channels)
        let synth = FixtureDefinition(
            id: "csv.\(candID)",
            manufacturer: manufacturer,
            model: model,
            category: .other,
            modes: [mode],
            source: "user"
        )
        warnings.append("Created \(channelCount)-channel profile for \(manufacturer) \(model).")
        return (synth, mode)
    }

    private static func escapeCSV(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func parseRow(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()
        while let ch = iterator.next() {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == delimiter && !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        result.append(current)
        return result
    }
}

// MARK: - Channel Tester & Address Scan Planner

public enum ChannelTestPattern: String, CaseIterable, Sendable, Identifiable {
    case manual = "Manual Sliders"
    case red = "Test Red"
    case green = "Test Green"
    case blue = "Test Blue"
    case white = "Test White"
    case pixelWalk = "Pixel Walk"

    public var id: String { rawValue }
}

public enum AddressScanPlanner {

    /// Generates raw DMX overrides to flash a specific address window in `universe` so the user can see if a light responds.
    public static func rawOverridesForRange(
        universe: Int,
        range: ClosedRange<Int>,
        value: UInt8 = 255
    ) -> [RawOverride] {
        let clampedLo = clamp(range.lowerBound, 1, 512)
        let clampedHi = clamp(range.upperBound, clampedLo, 512)
        return (clampedLo...clampedHi).map { addr in
            RawOverride(universe: universe, address: addr, value: value)
        }
    }

    /// Generates raw DMX overrides for a single pixel (`pixelIndex`, 0-based) of a resolved fixture during a Pixel Walk test.
    /// Respects `fixture.reversePixels` so the user can immediately verify physical pixel 1 → N direction!
    public static func pixelWalkOverrides(
        for rf: ResolvedFixture,
        activePixel: Int,
        color: RGB = RGB(r: 1, g: 0.2, b: 0.6)
    ) -> [RawOverride] {
        guard let startAddr = rf.fixture.address else { return [] }
        let u = rf.fixture.universe
        let totalCells = max(rf.cellCount, 1)
        let logicalCell = clamp(activePixel, 0, totalCells - 1)
        let physicalCell = rf.fixture.reversePixels ? (totalCells - 1 - logicalCell) : logicalCell

        var overrides: [RawOverride] = []
        for (offset, ch) in rf.mode.channels.enumerated() {
            let dmxAddr = startAddr + offset
            guard (1...512).contains(dmxAddr) else { continue }

            if let cell = ch.cell {
                let isTarget = (cell == physicalCell)
                let val: UInt8
                switch ch.kind {
                case .intensity:
                    val = isTarget ? 255 : 0
                case .red:
                    val = isTarget ? UInt8(clamp(color.r255, 0, 255)) : 0
                case .green:
                    val = isTarget ? UInt8(clamp(color.g255, 0, 255)) : 0
                case .blue:
                    val = isTarget ? UInt8(clamp(color.b255, 0, 255)) : 0
                case .crossfade:
                    val = 255
                case .tint:
                    val = ch.defaultValue
                default:
                    val = ch.defaultValue
                }
                overrides.append(RawOverride(universe: u, address: dmxAddr, value: val))
            } else {
                // Global channel (e.g. master intensity)
                let val: UInt8 = (ch.kind == .intensity) ? 255 : ch.defaultValue
                overrides.append(RawOverride(universe: u, address: dmxAddr, value: val))
            }
        }
        return overrides
    }

    /// Builds a corrected address map when the user steps through candidate `(universe, address)` probes
    /// and identifies which stage fixture actually lit up for each probe.
    public static func buildCorrectedPatch(
        probes: [(universe: Int, address: Int, matchedFixtureID: UUID?)],
        fixtures: [PatchedFixture]
    ) -> (updated: [PatchedFixture], summary: [String]) {
        var out = fixtures
        var summary: [String] = []
        for probe in probes {
            guard let matchedID = probe.matchedFixtureID,
                  let idx = out.firstIndex(where: { $0.id == matchedID }) else { continue }
            let oldU = out[idx].universe
            let oldA = out[idx].address
            if oldU != probe.universe || oldA != probe.address {
                out[idx].universe = probe.universe
                out[idx].address = probe.address
                summary.append("\(out[idx].name) updated to U\(probe.universe)·\(String(format: "%03d", probe.address)).")
            }
        }
        return (out, summary)
    }
}
