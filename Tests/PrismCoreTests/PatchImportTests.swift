import XCTest
import Foundation
@testable import PrismCore

final class PatchImportTests: XCTestCase {

    // MARK: - LightkeyImporter: London Studio Synthetic Archive

    func testImportLondonStudioLightkeyArchive() throws {
        let lib = TestResources.library()
        let data = try LightkeyArchiveBuilder.londonStudioArchiveData()
        let result = try LightkeyImporter.importProject(from: data, projectName: "London Studio", library: lib.definition)

        let project = result.project
        XCTAssertEqual(project.name, "London Studio")
        XCTAssertEqual(project.fixtures.count, 10)

        let resolvedAll = project.resolvedFixtures(library: lib.definition)
        XCTAssertEqual(resolvedAll.count, 10)

        // Verify B1..B8 are mapped to amaran PT4c with 56 channels (8 pixels)
        let b1 = try XCTUnwrap(project.fixtures.first { $0.shortName == "B1" })
        XCTAssertEqual(b1.universe, 1)
        XCTAssertEqual(b1.address, 1)
        XCTAssertTrue(b1.definitionID == "amaran.pt4c" || b1.definitionID.contains("amaran"))

        let resolvedB1 = try XCTUnwrap(resolvedAll.first { $0.id == b1.id })
        XCTAssertEqual(resolvedB1.mode.channelCount, 56)
        XCTAssertEqual(resolvedB1.mode.cellCount, 8)
        XCTAssertEqual(resolvedB1.addressRange, 1...56)

        // Verify B3 address = 113
        let b3 = try XCTUnwrap(project.fixtures.first { $0.shortName == "B3" })
        XCTAssertEqual(b3.address, 113)

        // Verify B8 address = 393..448
        let b8 = try XCTUnwrap(project.fixtures.first { $0.shortName == "B8" })
        XCTAssertEqual(b8.address, 393)

        // Verify PN1 (Panel) at 449
        let pn1 = try XCTUnwrap(project.fixtures.first { $0.shortName == "PN1" })
        XCTAssertEqual(pn1.address, 449)
        let resolvedPN1 = try XCTUnwrap(resolvedAll.first { $0.id == pn1.id })
        XCTAssertGreaterThanOrEqual(resolvedPN1.mode.channelCount, 6)

        // Verify P1 (Dimmer) at 455
        let p1 = try XCTUnwrap(project.fixtures.first { $0.shortName == "P1" })
        XCTAssertEqual(p1.address, 455)
        let resolvedP1 = try XCTUnwrap(resolvedAll.first { $0.id == p1.id })
        XCTAssertEqual(resolvedP1.mode.channelCount, 1)

        // Verify stage positions were normalized into project.stage bounds and rotation preserved
        for fx in project.fixtures {
            XCTAssertGreaterThanOrEqual(fx.transform.x, 0.0)
            XCTAssertLessThanOrEqual(fx.transform.x, project.stage.width)
            XCTAssertGreaterThanOrEqual(fx.transform.y, 0.0)
            XCTAssertLessThanOrEqual(fx.transform.y, project.stage.height)
        }
        // B1 had angleCCW = 90 in London Studio archive -> 270° clockwise in Prism
        XCTAssertEqual(b1.transform.rotation, 270.0, accuracy: 0.1)

        // Verify folders and looks
        XCTAssertTrue(project.folders.map(\.name).contains("Random"))
        XCTAssertTrue(project.folders.map(\.name).contains("Cool Setups"))
        XCTAssertGreaterThanOrEqual(project.looks.count, 3)

        let chill = try XCTUnwrap(project.looks.first { $0.name == "Chill Vibes 4" })
        XCTAssertEqual(chill.fadeTime, 1.5, accuracy: 0.01)

        // Verify 64-bit packed B-G-R-A color unpacking on B1 in Chill Vibes 4 (cyan #14D8F0)
        let b1State = try XCTUnwrap(chill.states[b1.id])
        XCTAssertEqual(b1State.intensity, 1.0, accuracy: 0.02)
        let expectedCyan = try XCTUnwrap(RGB(hex: "#14D8F0"))
        if case .rgb(let rgb) = b1State.color {
            XCTAssertEqual(rgb.r, expectedCyan.r, accuracy: 0.01)
            XCTAssertEqual(rgb.g, expectedCyan.g, accuracy: 0.01)
            XCTAssertEqual(rgb.b, expectedCyan.b, accuracy: 0.01)
        } else {
            XCTFail("Expected RGB color from Lightkey fpStore")
        }

        // Verify Blackout look has 0 intensity and is inside the "Random" folder
        let randomFolder = try XCTUnwrap(project.folders.first { $0.name == "Random" })
        let coolFolder = try XCTUnwrap(project.folders.first { $0.name == "Cool Setups" })
        let blackout = try XCTUnwrap(project.looks.first { $0.name == "Blackout" })
        XCTAssertEqual(blackout.folderID, randomFolder.id)
        let b1Blackout = try XCTUnwrap(blackout.states[b1.id])
        XCTAssertEqual(b1Blackout.intensity, 0.0, accuracy: 0.001)

        // Verify WNDT look with native Lightkey effect was imported and noted in report
        let wndt = try XCTUnwrap(project.looks.first { $0.name == "WNDT" })
        XCTAssertEqual(wndt.folderID, coolFolder.id)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertFalse(result.unmappedItems.isEmpty)

        // Verify the imported show has zero conflicts
        XCTAssertTrue(PatchMath.conflicts(resolvedAll).isEmpty)
        XCTAssertTrue(PatchMath.overflowing(resolvedAll).isEmpty)
    }

    func testImportLightkeyFromSingleFileAndPackageDirectory() throws {
        let lib = TestResources.library()
        let data = try LightkeyArchiveBuilder.londonStudioArchiveData()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prism-lk-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Single-file .lightkeyproj
        let singleFileURL = tempDir.appendingPathComponent("SingleShow.lightkeyproj")
        try data.write(to: singleFileURL)
        let singleResult = try LightkeyImporter.importProject(at: singleFileURL, library: lib.definition)
        XCTAssertEqual(singleResult.project.name, "SingleShow")
        XCTAssertEqual(singleResult.project.fixtures.count, 10)

        // 2. Package directory .lightkeyproj containing Contents.plist
        let pkgURL = tempDir.appendingPathComponent("PackageShow.lightkeyproj", isDirectory: true)
        try FileManager.default.createDirectory(at: pkgURL, withIntermediateDirectories: true)
        try data.write(to: pkgURL.appendingPathComponent("Contents.plist"))
        let pkgResult = try LightkeyImporter.importProject(at: pkgURL, library: lib.definition)
        XCTAssertEqual(pkgResult.project.name, "PackageShow")
        XCTAssertEqual(pkgResult.project.fixtures.count, 10)
    }

    func testImportLightkeyMultiSegmentPixelCells() throws {
        let lib = TestResources.library()
        let b = LightkeyArchiveBuilder()

        let u1UUID = UUID()
        let profUUID = UUID()
        let fxUUID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!

        // Build 28-channel 4-pixel personality for Amaran PT
        var caps: [[String: Int]] = []
        for px in 0..<4 {
            let base = px * 7
            let beams = [px]
            caps.append(b.capability(className: "LXIntensityCapability", channel: base + 0, beamIndexes: beams))
            caps.append(b.capability(className: "LXColorFilterCapability", channel: base + 1, beamIndexes: beams))
            caps.append(b.capability(className: "LXGreenSaturationCapability", channel: base + 2, beamIndexes: beams))
            caps.append(b.capability(className: "LXXfadeToColorCapability", channel: base + 3, beamIndexes: beams))
            caps.append(b.capability(className: "LXColorComponentCapability", channel: base + 4, colorComponent: "Red", beamIndexes: beams))
            caps.append(b.capability(className: "LXColorComponentCapability", channel: base + 5, colorComponent: "Green", beamIndexes: beams))
            caps.append(b.capability(className: "LXColorComponentCapability", channel: base + 6, colorComponent: "Blue", beamIndexes: beams))
        }
        let pers = b.personality(name: "Light Engine CCT & RGB 4 Pixels", capabilities: caps)
        let profile = b.fixtureProfile(uuid: profUUID, manufacturer: "Aputure", name: "Amaran PT", personalities: [pers])
        let fx = b.fixture(uuid: fxUUID, shortName: "PT1", name: "Pixel Tube", address: 1, universeUUID: u1UUID, profileUUID: profUUID)
        let u1 = b.universe(uuid: u1UUID, number: 1, fixtures: [fx])

        let segments: [(intensity: Double, rgb: RGB)] = (0..<4).map { idx in
            let frac = Double(idx) / 3.0
            return (intensity: 0.25 * Double(idx + 1), rgb: RGB(r: frac, g: 1.0 - frac, b: 0.5))
        }
        let fpData = try b.fpStoreData(fixtureStates: [fxUUID: segments])
        let preset = b.preset(name: "Rainbow Pixels", fpStore: fpData)
        let rootGroup = b.presetGroup(name: "Root", children: [preset], isRoot: true)

        let archiveData = try b.finalizeArchive(top: [
            "universes": b.nsArray([u1]),
            "fixtureProfiles": b.nsArray([profile]),
            "rootPresetGroup": rootGroup,
        ])

        let result = try LightkeyImporter.importProject(from: archiveData, projectName: "PixelTest", library: lib.definition)
        let importedFx = try XCTUnwrap(result.project.fixtures.first)
        let look = try XCTUnwrap(result.project.looks.first)
        let state = try XCTUnwrap(look.states[importedFx.id])
        let cells = try XCTUnwrap(state.cells)
        XCTAssertEqual(cells.count, 4)
        if case .rgb(let firstRGB) = cells[0].color, case .rgb(let lastRGB) = cells[3].color {
            XCTAssertEqual(firstRGB.r, 0.0, accuracy: 0.01)
            XCTAssertEqual(firstRGB.g, 1.0, accuracy: 0.01)
            XCTAssertEqual(lastRGB.r, 1.0, accuracy: 0.01)
            XCTAssertEqual(lastRGB.g, 0.0, accuracy: 0.01)
        } else {
            XCTFail("Expected per-pixel RGB cells")
        }
    }

    func testImportLightkeyMalformedAndFuzzInputsNeverCrash() {
        let lib = TestResources.library()

        // 1. Empty data
        XCTAssertThrowsError(try LightkeyImporter.importProject(from: Data(), library: lib.definition))

        // 2. Random non-plist bytes
        let garbage = Data((0..<256).map { UInt8(($0 * 73 + 19) & 0xFF) })
        XCTAssertThrowsError(try LightkeyImporter.importProject(from: garbage, library: lib.definition))

        // 3. Valid plist dictionary but not an NSKeyedArchiver archive
        if let plainPlist = try? PropertyListSerialization.data(fromPropertyList: ["hello": "world"], format: .binary, options: 0) {
            XCTAssertThrowsError(try LightkeyImporter.importProject(from: plainPlist, library: lib.definition))
        }

        // 4. Archive with out-of-bounds UIDs, unknown profile, and invalid address -> synthesizes profile & clamps address
        let b = LightkeyArchiveBuilder()
        let bogusUID = b.uid(99999)
        let uUUID = UUID()
        let pUUID = UUID()
        let caps = (0..<5).map { b.capability(className: "LXCustomCapability", channel: $0, customName: "Custom \($0 + 1)") }
        let pers = b.personality(name: "5ch Custom", capabilities: caps)
        let prof = b.fixtureProfile(uuid: pUUID, manufacturer: "UnknownBrandXYZ", name: "SuperBeam 9000", personalities: [pers])
        let fx = b.fixture(shortName: "W1", name: "Weird Light", address: -50, universeUUID: uUUID, profileUUID: pUUID)
        let u1 = b.universe(uuid: uUUID, number: 1, fixtures: [fx, bogusUID])
        let group = b.presetGroup(name: "Group", children: [bogusUID], isRoot: true)

        if let weirdData = try? b.finalizeArchive(top: [
            "universes": b.nsArray([u1]),
            "fixtureProfiles": b.nsArray([prof]),
            "rootPresetGroup": group,
        ]) {
            let res = try? LightkeyImporter.importProject(from: weirdData, library: lib.definition)
            XCTAssertNotNil(res)
            XCTAssertEqual(res?.project.fixtures.count, 1)
            XCTAssertNil(res?.project.fixtures.first?.address)
            XCTAssertEqual(res?.synthesizedProfiles.count, 1)
        }
    }

    // MARK: - PatchMath: Auto-Addressing, Easy Numbers, Packed, Overflow & Conflicts

    func testEasyNumbersAndPackedAutoAddressing() {
        // Easy numbers for 4 x 5-channel fixtures should land on 1, 101, 201, 301
        let easyAlloc = PatchMath.allocateAddresses(
            channelCount: 5,
            count: 4,
            style: .easyNumbers,
            startingUniverse: 1,
            existing: []
        )
        XCTAssertEqual(easyAlloc.assignments.map(\.address), [1, 101, 201, 301])
        XCTAssertEqual(easyAlloc.assignments.map(\.universe), [1, 1, 1, 1])
        XCTAssertFalse(easyAlloc.didOverflowUniverse)

        // Packed for 4 x 56-channel tubes should land on 1, 57, 113, 169
        let packedAlloc = PatchMath.allocateAddresses(
            channelCount: 56,
            count: 4,
            style: .packed,
            startingUniverse: 1,
            existing: []
        )
        XCTAssertEqual(packedAlloc.assignments.map(\.address), [1, 57, 113, 169])
        XCTAssertFalse(packedAlloc.didOverflowUniverse)

        // Adding 10 x 56-channel tubes (560 channels total) must spill the 10th tube into Universe 2 with a clear message
        let overflowAlloc = PatchMath.allocateAddresses(
            channelCount: 56,
            count: 10,
            style: .packed,
            startingUniverse: 1,
            existing: []
        )
        XCTAssertEqual(overflowAlloc.assignments.count, 10)
        XCTAssertEqual(overflowAlloc.assignments[8], PatchMath.AddressAssignment(universe: 1, address: 449))
        XCTAssertEqual(overflowAlloc.assignments[9], PatchMath.AddressAssignment(universe: 2, address: 1))
        XCTAssertTrue(overflowAlloc.didOverflowUniverse)
        XCTAssertNotNil(overflowAlloc.overflowMessage)
    }

    func testConflictDetectionAndResolution() {
        let tubeDef = BuiltinImportDefinitions.amaranPT4c
        let mode56 = tubeDef.modes.first { $0.channelCount == 56 } ?? tubeDef.modes[0]

        let f1 = PatchedFixture(name: "Tube 1", shortName: "T1", definitionID: tubeDef.id, modeName: mode56.name, universe: 1, address: 1)
        // Intentionally overlapping at address 20 (overlaps 20...56)
        let f2 = PatchedFixture(name: "Tube 2", shortName: "T2", definitionID: tubeDef.id, modeName: mode56.name, universe: 1, address: 20)
        // Intentionally overflowing at address 490 (490 + 56 - 1 = 545 > 512)
        let f3 = PatchedFixture(name: "Tube 3", shortName: "T3", definitionID: tubeDef.id, modeName: mode56.name, universe: 1, address: 490)

        let list = [f1, f2, f3]
        let resolved = list.map { ResolvedFixture(fixture: $0, definition: tubeDef, mode: mode56) }

        let conflicts = PatchMath.conflicts(resolved)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].overlap, 20...56)
        XCTAssertEqual(PatchMath.overflowing(resolved), [f3.id])

        // Universe summary checks
        let summary = PatchMath.universeSummary(universe: 1, fixtures: resolved)
        XCTAssertTrue(summary.conflictChannels.contains(20))
        XCTAssertEqual(summary.blocks.count, 3)

        // Resolve conflicts automatically
        let resolution = PatchMath.resolveConflicts(
            in: list,
            library: { id in id == tubeDef.id ? tubeDef : nil },
            style: .packed
        )
        XCTAssertEqual(resolution.changes.count, 2) // f2 and f3 moved

        let resolvedAfter = resolution.fixtures.map { ResolvedFixture(fixture: $0, definition: tubeDef, mode: mode56) }
        XCTAssertTrue(PatchMath.conflicts(resolvedAfter).isEmpty)
        XCTAssertTrue(PatchMath.overflowing(resolvedAfter).isEmpty)
    }

    func testReplaceFixturePreservesPositionAndResamplesLookCells() throws {
        let pt4c = BuiltinImportDefinitions.amaranPT4c
        let mode8px = try XCTUnwrap(pt4c.modes.first { $0.cellCount == 8 })
        let mode1px = try XCTUnwrap(pt4c.modes.first { $0.cellCount == 0 })

        let fxID = UUID()
        let fx = PatchedFixture(
            id: fxID,
            name: "Back Tube 1",
            shortName: "B1",
            definitionID: pt4c.id,
            modeName: mode8px.name,
            universe: 1,
            address: 1,
            role: .background,
            transform: StageTransform(x: 0.25, y: 0.15, rotation: 45)
        )
        let cells = (0..<8).map { i in
            CellState(intensity: 1.0, color: .rgb(RGB(r: Double(i) / 7.0, g: 0.2, b: 0.8)))
        }
        let look = Look(name: "Gradient", states: FixtureStateMap([fxID: FixtureState(intensity: 0.9, color: .kelvin(5600, tint: 0), cells: cells)]))
        var doc = ShowDocument(project: Project(name: "Test", fixtures: [fx], looks: [look], definitions: [pt4c]))

        // Replace 8-pixel mode with 1-pixel mode -> preserves transform & collapses cells cleanly
        let msg = PatchMath.replaceFixture(
            fixtureID: fxID,
            newDefinition: pt4c,
            newModeName: mode1px.name,
            in: &doc,
            library: { id in id == pt4c.id ? pt4c : nil }
        )
        XCTAssertNotNil(msg)
        XCTAssertEqual(doc.project.fixtures[0].transform.x, 0.25, accuracy: 0.001)
        XCTAssertEqual(doc.project.fixtures[0].transform.rotation, 45, accuracy: 0.001)
        XCTAssertNil(doc.project.looks[0].states[fxID]?.cells)
    }

    // MARK: - CSV Export & Import, Setup Cards, and Address Scan Planner

    func testPatchCSVRoundTripAndSetupCards() throws {
        let lib = TestResources.library()
        let project = DemoRig.londonStudio()
        let resolved = project.resolvedFixtures(library: lib.definition)

        let csv = PatchCSV.exportCSV(fixtures: resolved)
        XCTAssertTrue(csv.contains("Name,Label,Manufacturer,Model,Mode,Channels,Universe,Address,Role"))

        let imported = PatchCSV.importCSV(csv, library: lib.definition)
        XCTAssertEqual(imported.fixtures.count, resolved.count)
        XCTAssertEqual(imported.fixtures.first?.name, resolved.first?.fixture.name)
        XCTAssertEqual(imported.fixtures.first?.address, resolved.first?.fixture.address)

        // Setup cards
        let cards = SetupCardGenerator.cards(for: resolved)
        XCTAssertEqual(cards.count, resolved.count)
        for card in cards {
            XCTAssertFalse(card.headline.isEmpty)
            XCTAssertFalse(card.steps.isEmpty)
            XCTAssertEqual(card.dipSwitches.count, 9)
        }
        let html = SetupCardGenerator.renderPrintableHTML(projectTitle: project.name, cards: cards)
        XCTAssertTrue(html.contains("<!DOCTYPE html>"))
        XCTAssertTrue(html.contains(project.name))

        // DIP switches for address 113 (64 + 32 + 16 + 1 = 0b001110001)
        let dips113 = PatchMath.dipSwitches(for: 113)
        XCTAssertEqual(dips113, [true, false, false, false, true, true, true, false, false])
    }

    func testPixelWalkRespectsReversePixelsAndAddressScanRebuildsPatch() throws {
        let pt4c = BuiltinImportDefinitions.amaranPT4c
        let mode8px = try XCTUnwrap(pt4c.modes.first { $0.cellCount == 8 })

        var fx = PatchedFixture(name: "Tube", shortName: "B1", definitionID: pt4c.id, modeName: mode8px.name, universe: 1, address: 1, reversePixels: false)
        let rfNormal = ResolvedFixture(fixture: fx, definition: pt4c, mode: mode8px)
        let walkNormal = AddressScanPlanner.pixelWalkOverrides(for: rfNormal, activePixel: 0)

        fx.reversePixels = true
        let rfReversed = ResolvedFixture(fixture: fx, definition: pt4c, mode: mode8px)
        let walkReversed = AddressScanPlanner.pixelWalkOverrides(for: rfReversed, activePixel: 0)

        // Cell 0 in normal order lights pixel 1 (address 1); in reversed order it lights pixel 8 (address 50)
        XCTAssertNotEqual(walkNormal, walkReversed)
        XCTAssertEqual(walkNormal.first { $0.address == 1 }?.value, 255)
        XCTAssertEqual(walkReversed.first { $0.address == 50 }?.value, 255)

        // AddressScanPlanner corrected patch
        let fA = PatchedFixture(name: "Left", shortName: "L", definitionID: pt4c.id, modeName: mode8px.name, universe: 1, address: 1)
        let fB = PatchedFixture(name: "Right", shortName: "R", definitionID: pt4c.id, modeName: mode8px.name, universe: 1, address: 57)
        let (corrected, summary) = AddressScanPlanner.buildCorrectedPatch(
            probes: [
                (universe: 1, address: 1, matchedFixtureID: fB.id),
                (universe: 1, address: 57, matchedFixtureID: fA.id)
            ],
            fixtures: [fA, fB]
        )
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(corrected.first { $0.id == fA.id }?.address, 57)
        XCTAssertEqual(corrected.first { $0.id == fB.id }?.address, 1)
    }
}
