import XCTest
@testable import PrismCore

/// Locates repo resources from the test file location (works on Linux and macOS).
enum TestResources {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PrismCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo
    }
    static var fixtureLibrary: URL { repoRoot.appendingPathComponent("Resources/FixtureLibrary") }

    static func library() -> FixtureLibrary {
        let lib = FixtureLibrary()
        lib.load(roots: [fixtureLibrary])
        return lib
    }
}

final class DemoRigTests: XCTestCase {
    func testGenericLibraryLoads() throws {
        let lib = TestResources.library()
        XCTAssertTrue(lib.problems.isEmpty, "Library problems: \(lib.problems)")
        let tube = try XCTUnwrap(lib.definition(DemoRig.pixelTubeID))
        let mode = try XCTUnwrap(tube.modes.first { $0.name == DemoRig.pixelTubeMode })
        XCTAssertEqual(mode.channelCount, 49)
        XCTAssertEqual(mode.cellCount, 16)
        XCTAssertTrue(mode.capabilities.hasRGB)
        XCTAssertNotNil(lib.definition(DemoRig.panelID))
        XCTAssertNotNil(lib.definition(DemoRig.dimmerID))
        XCTAssertGreaterThanOrEqual(lib.count, 8)
    }

    func testDemoRigPatchIsValid() {
        let lib = TestResources.library()
        let project = DemoRig.londonStudio()
        let resolved = project.resolvedFixtures(library: lib.definition)
        XCTAssertEqual(resolved.count, 10)
        XCTAssertTrue(PatchMath.conflicts(resolved).isEmpty)
        XCTAssertTrue(PatchMath.overflowing(resolved).isEmpty)
    }

    func testDemoRenderProducesExpectedDMX() throws {
        let lib = TestResources.library()
        let project = DemoRig.londonStudio()
        let chill = try XCTUnwrap(project.looks.first { $0.name == "Chill Vibes 4" })
        var live = LiveState()
        live.base = chill.states
        let doc = ShowDocument(project: project, live: live)
        let snap = ShowSnapshot(document: doc, library: lib.definition)
        let frame = EngineCore.renderFrame(snap, time: 100)
        let u1 = try XCTUnwrap(frame.universes[1])
        XCTAssertEqual(u1.count, 512)
        XCTAssertEqual(u1[0], 255, "P1 dimmer at full")
        // B1 starts at address 2: dimmer then 16 × RGB. Cyan → low red, high green+blue.
        XCTAssertEqual(u1[1], 255, "B1 master dimmer")
        XCTAssertLessThan(u1[2], 60, "B1 pixel 1 red should be low for cyan")
        XCTAssertGreaterThan(u1[3], 150, "B1 pixel 1 green")
        XCTAssertGreaterThan(u1[4], 200, "B1 pixel 1 blue")
    }

    func testProjectRoundTrip() throws {
        let lib = TestResources.library()
        let project = DemoRig.londonStudio()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).prismlights")
        defer { try? FileManager.default.removeItem(at: url) }
        try ProjectIO.write(project, to: url, library: lib.definition)
        let back = try ProjectIO.read(from: url)
        XCTAssertEqual(back.fixtures.count, project.fixtures.count)
        XCTAssertEqual(back.looks.map(\.name), project.looks.map(\.name))
        // Shared files carry their own fixture definitions so they open anywhere.
        XCTAssertTrue(back.definitions.contains { $0.id == DemoRig.pixelTubeID })
        XCTAssertEqual(back.fixtures.first?.transform, project.fixtures.first?.transform)
    }

    func testRoleCommandTargetsBackgroundTubes() {
        let lib = TestResources.library()
        var doc = ShowDocument(project: DemoRig.londonStudio())
        let exec = CommandExecutor(library: lib.definition, now: { 10 })
        let result = exec.apply([.setColor(.role(.background), .hex("#00C2A8")!)], to: &doc)
        XCTAssertEqual(result.affectedFixtureIDs.count, 5)
        XCTAssertEqual(doc.live.base[DemoRig.IDs.tube(1)]?.color.hex, "#00C2A8")
    }
}
