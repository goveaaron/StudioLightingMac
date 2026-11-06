import Foundation
import PrismCore

@MainActor
extension ShowController {

    /// Adds one or more fixtures using `PatchMath.allocateAddresses` (supporting `.easyNumbers` `1, 101, 201…`
    /// or `.packed`), auto-generating short stage labels and role-based stage positions.
    @discardableResult
    func addFixturesWithOptions(
        definitionID: String,
        modeName: String,
        count: Int = 1,
        baseName: String? = nil,
        role: FixtureRole = .other,
        universe: Int = 1,
        startAddress: Int? = nil,
        style: AddressingStyle = .easyNumbers
    ) -> (ids: [UUID], allocation: PatchMath.AddressAllocationResult) {
        guard let def = library.definition(definitionID) ?? project.definition(definitionID),
              let mode = def.mode(named: modeName) ?? def.recommendedMode else {
            return ([], PatchMath.AddressAllocationResult(assignments: []))
        }
        let n = clamp(count, 1, 64)
        let existingResolved = resolvedFixtures
        let allocation = PatchMath.allocateAddresses(
            channelCount: mode.channelCount,
            count: n,
            style: style,
            startingUniverse: max(1, universe),
            startingAt: max(1, startAddress ?? 1),
            existing: existingResolved
        )

        let stage = project.stage
        let cleanBase = (baseName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? def.model
        var currentFixtures = project.fixtures
        var newFixtures: [PatchedFixture] = []

        for i in 0..<n {
            let assign = i < allocation.assignments.count
                ? allocation.assignments[i]
                : PatchMath.AddressAssignment(universe: universe, address: 1)
            let short = PatchMath.suggestShortName(for: def, role: role, existing: currentFixtures)
            let existingInRole = currentFixtures.filter { $0.role == role }.count
            let transform = PatchMath.suggestTransform(
                role: role,
                index: existingInRole,
                count: max(existingInRole + (n - i), n),
                stage: stage
            )
            let fName = n > 1 ? "\(cleanBase) \(i + 1)" : cleanBase
            let fx = PatchedFixture(
                name: fName,
                shortName: short,
                definitionID: def.id,
                modeName: mode.name,
                universe: assign.universe,
                address: assign.address,
                role: role,
                transform: transform
            )
            newFixtures.append(fx)
            currentFixtures.append(fx)
        }

        let ids = newFixtures.map(\.id)
        editProject(n > 1 ? "Add \(n) Lights" : "Add Light") { p in
            p.fixtures.append(contentsOf: newFixtures)
            if !p.definitions.contains(where: { $0.id == def.id }) {
                p.definitions.append(def)
            }
        }
        selection = Set(ids)
        return (ids, allocation)
    }

    /// Unpatches fixtures (sets `address = nil`) without deleting them from the project or stage.
    func unpatchFixtures(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        editProject(ids.count > 1 ? "Unpatch \(ids.count) Lights" : "Unpatch Light") { p in
            for i in p.fixtures.indices where ids.contains(p.fixtures[i].id) {
                p.fixtures[i].address = nil
            }
        }
    }

    /// Duplicates the given fixtures with fresh non-overlapping DMX addresses and slightly offset stage positions.
    @discardableResult
    func duplicateFixtures(_ ids: Set<UUID>, style: AddressingStyle = .packed) -> [UUID] {
        let targets = project.fixtures.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return [] }

        var simResolved = resolvedFixtures
        var currentFixtures = project.fixtures
        var clones: [PatchedFixture] = []
        let stage = project.stage

        for src in targets {
            guard let def = library.definition(src.definitionID) ?? project.definition(src.definitionID),
                  let mode = def.mode(named: src.modeName) ?? def.recommendedMode else { continue }
            let alloc = PatchMath.allocateAddresses(
                channelCount: mode.channelCount,
                count: 1,
                style: style,
                startingUniverse: src.universe,
                startingAt: (src.address ?? 1) + mode.channelCount,
                existing: simResolved
            )
            let assign = alloc.assignments.first ?? PatchMath.AddressAssignment(universe: src.universe, address: 1)
            let short = PatchMath.suggestShortName(for: def, role: src.role, existing: currentFixtures)
            var t = src.transform
            t.x = clamp(t.x + 0.35, 0.3, max(0.3, stage.width - 0.3))
            t.y = clamp(t.y + 0.25, 0.3, max(0.3, stage.height - 0.3))
            let clone = PatchedFixture(
                name: "\(src.name) Copy",
                shortName: short,
                definitionID: src.definitionID,
                modeName: src.modeName,
                universe: assign.universe,
                address: assign.address,
                role: src.role,
                transform: t,
                reversePixels: src.reversePixels,
                notes: src.notes,
                tags: src.tags
            )
            clones.append(clone)
            currentFixtures.append(clone)
            simResolved.append(ResolvedFixture(fixture: clone, definition: def, mode: mode))
        }

        let newIDs = clones.map(\.id)
        editProject(clones.count > 1 ? "Duplicate \(clones.count) Lights" : "Duplicate Light") { p in
            p.fixtures.append(contentsOf: clones)
        }
        selection = Set(newIDs)
        return newIDs
    }

    /// Replaces a fixture's model and/or mode while preserving its stage position, role, and look color states.
    @discardableResult
    func replaceFixtureType(
        _ id: UUID,
        newDefinition: FixtureDefinition,
        newModeName: String
    ) -> String? {
        var tempDoc = document
        let lookup: (String) -> FixtureDefinition? = { [library, project] defID in
            library.definition(defID) ?? project.definition(defID)
        }
        guard let summary = PatchMath.replaceFixture(
            fixtureID: id,
            newDefinition: newDefinition,
            newModeName: newModeName,
            in: &tempDoc,
            library: lookup
        ) else {
            return nil
        }
        library.registerEmbedded([newDefinition])
        editProject("Replace Light Type", change: [.patch, .looks, .live]) { p in
            p = tempDoc.project
        }
        editLive { live in
            live.base = tempDoc.live.base
        }
        return summary
    }

    /// Automatically resolves all overlapping or overflowing DMX addresses in the project.
    @discardableResult
    func fixPatchConflicts(style: AddressingStyle = .packed) -> [String] {
        let lookup: (String) -> FixtureDefinition? = { [library, project] defID in
            library.definition(defID) ?? project.definition(defID)
        }
        let result = PatchMath.resolveConflicts(in: project.fixtures, library: lookup, style: style)
        guard !result.changes.isEmpty else { return [] }
        editProject("Fix Address Conflicts") { p in
            p.fixtures = result.fixtures
        }
        return result.changes
    }

    /// Applies a corrected fixture list from the Address Scan / Find My Lights flow.
    func applyCorrectedPatch(_ updatedFixtures: [PatchedFixture], summary: [String]) {
        guard updatedFixtures != project.fixtures else { return }
        editProject("Apply Address Scan") { p in
            p.fixtures = updatedFixtures
        }
    }

    /// Imports a decoded Lightkey project into the active show.
    func importLightkeyResult(_ result: LightkeyImportResult, fileURL: URL? = nil) {
        library.registerEmbedded(result.project.definitions)
        load(result.project, fileURL: nil, restoreLive: true)
        isDirty = true
    }

    /// Sets raw DMX channel overrides for the Channel Tester or Address Scan sheet.
    func setRawOverrides(_ overrides: [RawOverride]) {
        editLive { live in
            live.rawOverrides = overrides
        }
    }

    /// Clears all raw DMX channel overrides.
    func clearRawOverrides() {
        guard !document.live.rawOverrides.isEmpty else { return }
        editLive { live in
            live.rawOverrides = []
        }
    }
}
