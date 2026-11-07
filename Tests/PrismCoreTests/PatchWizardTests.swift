import XCTest
import Foundation
@testable import PrismCore

/// Tests for the beginner "I plugged in a new light" flow: mode/address planning and the
/// button-by-button setup walkthrough.
final class PatchWizardTests: XCTestCase {

    // MARK: Fixtures

    /// A PT4c-like tube: 10-ch whole-tube color (recommended only when `recommendWhole`),
    /// 28-ch 4-zone, 56-ch 8-zone (recommended by default), 7-ch System FX.
    private func tube(recommend56: Bool = true, guide: FixtureSetupGuide? = nil,
                      manufacturer: String = "amaran", model: String = "PT4c") -> FixtureDefinition {
        func pixelChannels(_ cells: Int) -> [ChannelDefinition] {
            var ch: [ChannelDefinition] = []
            for c in 0..<cells {
                ch += [ChannelDefinition(kind: .intensity, cell: c), ChannelDefinition(kind: .cct, cell: c),
                       ChannelDefinition(kind: .tint, cell: c), ChannelDefinition(kind: .red, cell: c),
                       ChannelDefinition(kind: .green, cell: c), ChannelDefinition(kind: .blue, cell: c),
                       ChannelDefinition(kind: .crossfade, cell: c)]
            }
            return ch
        }
        let whole = FixtureMode(name: "CCT & RGB", channels: [
            ChannelDefinition(kind: .intensity), ChannelDefinition(kind: .cct), ChannelDefinition(kind: .tint),
            ChannelDefinition(kind: .crossfade), ChannelDefinition(kind: .red), ChannelDefinition(kind: .green),
            ChannelDefinition(kind: .blue), ChannelDefinition(kind: .strobe), ChannelDefinition(kind: .generic),
            ChannelDefinition(kind: .generic)])
        let fx = FixtureMode(name: "System FX", channels: Array(repeating: ChannelDefinition(kind: .generic), count: 7))
        let four = FixtureMode(name: "LE CCT & RGB 4 Pixels", channels: pixelChannels(4))
        let eight = FixtureMode(name: "LE CCT & RGB 8 Pixels", recommended: recommend56, channels: pixelChannels(8))
        return FixtureDefinition(id: "test.\(model.lowercased())", manufacturer: manufacturer, model: model,
                                 category: .tube, modes: [whole, fx, four, eight], setupGuide: guide)
    }

    private func occupied(_ channels: Int, universe: Int = 1, at address: Int = 1) -> ResolvedFixture {
        let def = FixtureDefinition(id: "test.block\(channels)", manufacturer: "Generic", model: "Block",
                                    category: .other,
                                    modes: [FixtureMode(name: "Block", channels: Array(repeating: ChannelDefinition(kind: .intensity), count: channels))])
        let fx = PatchedFixture(name: "Block", definitionID: def.id, modeName: "Block", universe: universe, address: address)
        return ResolvedFixture(fixture: fx, definition: def, mode: def.modes[0])
    }

    // MARK: NewLightPlanner

    func testPlannerUsesRecommendedModeAndEasyAddressOnEmptyRig() {
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 1, existing: [])
        XCTAssertEqual(plan.modeName, "LE CCT & RGB 8 Pixels")
        XCTAssertEqual(plan.channelCount, 56)
        XCTAssertEqual(plan.assignments, [PatchMath.AddressAssignment(universe: 1, address: 1)])
        XCTAssertEqual(plan.style, .easyNumbers)
        XCTAssertFalse(plan.usedSmallerMode)
        XCTAssertFalse(plan.needsAnotherUniverse)
        XCTAssertTrue(plan.summary.contains("address 1"), plan.summary)
        XCTAssertTrue(plan.notes.isEmpty)
    }

    func testPlannerPicksNextEasyNumberAfterExistingLights() {
        // 1…399 used (like the London Studio demo): a 56-ch tube goes to 401 (401…456 is free).
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 1, existing: [occupied(399)])
        XCTAssertEqual(plan.assignments.first?.address, 401)
        XCTAssertEqual(plan.assignments.first?.universe, 1)
        XCTAssertTrue(plan.summary.contains("easy to dial in"), plan.summary)
    }

    func testPlannerFallsBackToSmallerModeInsteadOfASecondUniverse() {
        // Only 32 channels left (481…512): 56 ch doesn't fit, the 28-ch 4-zone mode does.
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 1, existing: [occupied(480)])
        XCTAssertEqual(plan.modeName, "LE CCT & RGB 4 Pixels")
        XCTAssertTrue(plan.usedSmallerMode)
        XCTAssertEqual(plan.recommendedModeName, "LE CCT & RGB 8 Pixels")
        XCTAssertFalse(plan.needsAnotherUniverse)
        XCTAssertEqual(plan.assignments.first?.universe, 1)
        XCTAssertEqual(plan.assignments.first?.address, 481)
        XCTAssertEqual(plan.notes.count, 1)
        // Never auto-picks an effects-only mode.
        XCTAssertNotEqual(plan.modeName, "System FX")
    }

    func testPlannerKeepsExplicitModeAndExplainsTheExtraUniverse() {
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 1,
                                        preferredModeName: "LE CCT & RGB 8 Pixels", existing: [occupied(480)])
        XCTAssertEqual(plan.modeName, "LE CCT & RGB 8 Pixels")
        XCTAssertFalse(plan.usedSmallerMode)
        XCTAssertTrue(plan.needsAnotherUniverse)
        XCTAssertEqual(plan.assignments.first, PatchMath.AddressAssignment(universe: 2, address: 1))
        XCTAssertTrue(plan.notes.joined().contains("universe 2"), plan.notes.joined())
    }

    func testPlannerPacksWhenEasyNumbersWouldOverflow() {
        // Seven 56-ch tubes (392 ch): easy numbers run out of round slots, packed fits them all in universe 1.
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 7, existing: [])
        XCTAssertEqual(plan.modeName, "LE CCT & RGB 8 Pixels")
        XCTAssertEqual(plan.style, .packed)
        XCTAssertEqual(plan.assignments.count, 7)
        XCTAssertTrue(plan.assignments.allSatisfy { $0.universe == 1 })
        let ranges = plan.assignments.map { $0.address...($0.address + 55) }
        for i in ranges.indices {
            XCTAssertLessThanOrEqual(ranges[i].upperBound, 512)
            for j in ranges.indices where j > i {
                XCTAssertFalse(ranges[i].overlaps(ranges[j]), "\(ranges[i]) overlaps \(ranges[j])")
            }
        }
        XCTAssertFalse(plan.needsAnotherUniverse)
    }

    func testPlannerRespectsLargerRigsAndHandlesEmptyDefinitions() {
        // Universes 1 and 2 both have only 12 channels left: the 10-ch whole-tube mode fits at 501.
        let plan = NewLightPlanner.plan(definition: tube(), quantity: 1,
                                        existing: [occupied(500), occupied(500, universe: 2)])
        XCTAssertEqual(plan.modeName, "CCT & RGB")
        XCTAssertTrue(plan.usedSmallerMode)
        XCTAssertFalse(plan.needsAnotherUniverse)
        XCTAssertEqual(plan.assignments.first, PatchMath.AddressAssignment(universe: 1, address: 501))
        // A rig that already uses universe 2 may place new lights there without a warning.
        let spill = NewLightPlanner.plan(definition: tube(), quantity: 1, preferredModeName: "LE CCT & RGB 8 Pixels",
                                         existing: [occupied(500), occupied(10, universe: 2)])
        XCTAssertEqual(spill.assignments.first?.universe, 2)
        XCTAssertFalse(spill.needsAnotherUniverse)

        let empty = FixtureDefinition(id: "test.empty", manufacturer: "X", model: "Y", category: .other, modes: [])
        let none = NewLightPlanner.plan(definition: empty, quantity: 3, existing: [])
        XCTAssertTrue(none.assignments.isEmpty)
        XCTAssertFalse(none.summary.isEmpty)
        // Quantity is clamped.
        XCTAssertEqual(NewLightPlanner.plan(definition: tube(), quantity: 0, existing: []).assignments.count, 1)
    }

    func testFriendlyModeTitles() {
        let def = tube()
        XCTAssertEqual(ModeNaming.friendlyTitle(for: def.modes[3]), "Full color + white balance · 8 zones")
        XCTAssertEqual(ModeNaming.friendlyTitle(for: def.modes[0]), "Full color + white balance")
        XCTAssertTrue(ModeNaming.isEffectMode(def.modes[1]))
        XCTAssertEqual(ModeNaming.richness(of: def.modes[1]), 0)
        let dimmer = FixtureMode(name: "1ch", channels: [ChannelDefinition(kind: .intensity)])
        XCTAssertEqual(ModeNaming.friendlyTitle(for: dimmer), "Brightness only")
        let named = FixtureMode(name: "X", channels: [ChannelDefinition(kind: .intensity)], friendlyName: "Simple dimmer")
        XCTAssertEqual(ModeNaming.friendlyTitle(for: named), "Simple dimmer")
    }

    // MARK: SetupWalkthrough

    private func resolved(_ def: FixtureDefinition, mode: String, address: Int?) -> ResolvedFixture {
        let m = def.mode(named: mode) ?? def.modes[0]
        let fx = PatchedFixture(name: "Tube Left", shortName: "B1", definitionID: def.id, modeName: m.name,
                                universe: 1, address: address)
        return ResolvedFixture(fixture: fx, definition: def, mode: m)
    }

    func testWalkthroughUsesLibrarySetupGuide() throws {
        let guide = FixtureSetupGuide(addressMenuPath: ["MENU", "DMX", "Address"], modeMenuPath: ["MENU", "DMX", "Mode"],
                                      connector: "5-pin XLR", addressDisplayFormat: "d001",
                                      signalLossBehavior: "Hold", notes: ["Keep the address screen open."])
        let def = tube(guide: guide, manufacturer: "Nanlite", model: "PavoTube II 30X")
        let w = try XCTUnwrap(SetupWalkthrough.make(for: resolved(def, mode: "LE CCT & RGB 8 Pixels", address: 113)))
        XCTAssertTrue(w.isModelSpecific)
        XCTAssertEqual(w.addressReadout, "d113")
        XCTAssertEqual(w.address, 113)
        XCTAssertEqual(w.steps.map(\.kind), [.connect, .address, .mode, .signalLoss, .test])
        XCTAssertEqual(w.steps[1].presses, ["MENU", "DMX", "Address"])
        XCTAssertEqual(w.steps[1].value, "d113")
        XCTAssertEqual(w.steps[2].presses, ["MENU", "DMX", "Mode"])
        XCTAssertTrue(w.steps[0].detail.contains("5-pin XLR"))
        XCTAssertEqual(w.tips, ["Keep the address screen open."])
        XCTAssertEqual(Set(w.steps.map(\.id)).count, w.steps.count, "step ids must be unique")
    }

    func testWalkthroughForAmaranPTTubeFromBuiltInKnowledge() throws {
        let w = try XCTUnwrap(SetupWalkthrough.make(for: resolved(tube(), mode: "LE CCT & RGB 8 Pixels", address: 401)))
        XCTAssertTrue(w.isModelSpecific)
        XCTAssertEqual(w.addressReadout, "401")
        XCTAssertEqual(w.modeReadout, "9: LE CCT&RGB 8PX")
        XCTAssertEqual(w.steps.first(where: { $0.kind == .address })?.presses, ["MENU", "DMX Settings", "DMX Address"])
        XCTAssertNotNil(w.steps.first(where: { $0.kind == .lock }))
        XCTAssertEqual(w.steps.last?.kind, .test)
        XCTAssertFalse(w.tips.isEmpty)
    }

    func testWalkthroughGenericFallbackAndDipSwitches() throws {
        let def = FixtureDefinition(id: "generic.dimmer", manufacturer: "Generic", model: "Dimmer", category: .dimmer,
                                    modes: [FixtureMode(name: "8-bit", channels: [ChannelDefinition(kind: .intensity)])])
        let w = try XCTUnwrap(SetupWalkthrough.make(for: resolved(def, mode: "8-bit", address: 81)))
        XCTAssertFalse(w.isModelSpecific)
        XCTAssertEqual(w.addressReadout, "081")
        // Single-mode lights don't get a "choose the mode" step.
        XCTAssertEqual(w.steps.map(\.kind), [.connect, .address, .test])
        // 81 = 1 + 16 + 64 → switches 1, 5, 7.
        XCTAssertEqual(w.dipSwitchesOn, [1, 5, 7])

        let dipGuide = FixtureSetupGuide(usesDipSwitches: true)
        let dipDef = FixtureDefinition(id: "x.dip", manufacturer: "X", model: "Par", category: .par,
                                       modes: def.modes, setupGuide: dipGuide)
        let dw = try XCTUnwrap(SetupWalkthrough.make(for: resolved(dipDef, mode: "8-bit", address: 81)))
        XCTAssertTrue(dw.usesDipSwitches)
        XCTAssertEqual(dw.steps.first(where: { $0.kind == .dipSwitches })?.value, "ON: 1, 5, 7")
        XCTAssertNil(dw.steps.first(where: { $0.kind == .address }))
    }

    func testWalkthroughNeedsAnAddressAndClampsOutOfRange() {
        XCTAssertNil(SetupWalkthrough.make(for: resolved(tube(), mode: "CCT & RGB", address: nil)))
        let w = SetupWalkthrough.make(for: resolved(tube(), mode: "CCT & RGB", address: nil), address: 9999)
        XCTAssertEqual(w.address, 512)
    }

    // MARK: Fix it for me (conflict resolution)

    private func block56() -> FixtureDefinition {
        FixtureDefinition(id: "test.block56", manufacturer: "Generic", model: "Block", category: .other,
                          modes: [FixtureMode(name: "Block", channels: Array(repeating: ChannelDefinition(kind: .intensity), count: 56))])
    }

    func testFixConflictsMovesOnlyTheClashingLightAndNeverOntoALaterLight() {
        let def = block56()
        let a = PatchedFixture(name: "A", definitionID: def.id, modeName: "Block", universe: 1, address: 1)
        let b = PatchedFixture(name: "B", definitionID: def.id, modeName: "Block", universe: 1, address: 40)   // clashes with A
        let c = PatchedFixture(name: "C", definitionID: def.id, modeName: "Block", universe: 1, address: 100)  // fine
        let result = PatchMath.resolveConflicts(in: [a, b, c], library: { $0 == def.id ? def : nil }, style: .packed)
        let byName = Dictionary(uniqueKeysWithValues: result.fixtures.map { ($0.name, $0) })
        XCTAssertEqual(byName["A"]?.address, 1)
        XCTAssertEqual(byName["C"]?.address, 100, "a light that was fine must not be re-addressed")
        XCTAssertEqual(byName["B"]?.address, 156, "B goes after C, not into 57…112 where it would hit C")
        XCTAssertEqual(result.changes, ["Moved B from 040 to 156."])
        let resolved = result.fixtures.map { ResolvedFixture(fixture: $0, definition: def, mode: def.modes[0]) }
        XCTAssertTrue(PatchMath.conflicts(resolved).isEmpty)
    }

    func testFixConflictsStaysInTheSameUniverseWhenThereIsAnyGap() {
        let def = block56()
        let a = PatchedFixture(name: "A", definitionID: def.id, modeName: "Block", universe: 1, address: 1)
        let b = PatchedFixture(name: "B", definitionID: def.id, modeName: "Block", universe: 1, address: 470)  // runs past 512
        let result = PatchMath.resolveConflicts(in: [a, b], library: { $0 == def.id ? def : nil }, style: .packed)
        let moved = result.fixtures.first { $0.name == "B" }
        XCTAssertEqual(moved?.universe, 1)
        XCTAssertEqual(moved?.address, 57)
        let resolved = result.fixtures.map { ResolvedFixture(fixture: $0, definition: def, mode: def.modes[0]) }
        XCTAssertTrue(PatchMath.overflowing(resolved).isEmpty)
        XCTAssertTrue(PatchMath.conflicts(resolved).isEmpty)
    }
}
