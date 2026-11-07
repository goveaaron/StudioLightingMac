import XCTest
@testable import PrismCore

final class LibraryTests: XCTestCase {

    // MARK: - 1. Schema & Setup Guide Tests

    func testDecodeExtendedFixtureSchemaInlineAndShared() throws {
        let inlineJSON = """
        {
          "schemaVersion": 1,
          "fixtures": [{
            "id": "amaran.pt4c.test",
            "manufacturer": "amaran",
            "model": "PT4c",
            "category": "tube",
            "aliases": ["Aputure amaran PT4c", "PT 4c"],
            "cctRange": [2700, 10000],
            "source": "curated",
            "verification": "manufacturer_chart",
            "sourceInfo": {
              "kind": "curated",
              "url": "https://help.amarancreators.com",
              "license": "Proprietary-Facts",
              "authors": ["Prism Team"]
            },
            "setupGuide": {
              "addressMenuPath": ["MENU", "DMX", "DMX Address"],
              "modeMenuPath": ["MENU", "DMX", "DMX Profile"],
              "connector": "USB-C to 5-pin XLR adapter (or Sidus/CRMX)",
              "addressDisplayFormat": "001",
              "factoryDefaults": {
                "address": 1,
                "mode": "CCT&RGB",
                "signalLossBehavior": "Hold last look",
                "fanMode": "Smart"
              },
              "signalLossBehavior": ["Hold last look", "Blackout"],
              "notes": "Requires USB-C to DMX adapter for wired DMX.",
              "manualURL": "https://cdn.shopify.com/s/files/1/0645/6482/2249/files/amaran_PT4c_DMX_Profile_Specification_V1.1.pdf"
            },
            "emitters": {
              "red": {"x": 0.692, "y": 0.307, "relativeLumens": 0.25},
              "green": [0.165, 0.715, 0.60],
              "blue": [0.134, 0.052]
            },
            "modes": [{
              "name": "Light Engine CCT & RGB 8 Pixels",
              "shortName": "LE CCT&RGB 8px",
              "friendlyName": "Full color + white balance · 8 zones",
              "fixtureMenuName": "9: LE CCT&RGB 8px",
              "summary": "8 independent pixel zones with CCT, G/M, crossfade & RGB",
              "recommended": true,
              "channels": [],
              "pixels": {
                "count": 8,
                "channels": [
                  {"name": "Dimmer", "kind": "intensity"},
                  {"name": "CCT", "kind": "cct", "physical": [2700, 10000]},
                  {"name": "G/M", "kind": "tint", "default": 128, "physical": [-1, 1]},
                  {"name": "Crossfade", "kind": "crossfade", "physical": [0, 1]},
                  {"name": "Red", "kind": "red"},
                  {"name": "Green", "kind": "green"},
                  {"name": "Blue", "kind": "blue"}
                ]
              }
            }]
          }]
        }
        """.data(using: .utf8)!

        let file = try JSONDecoder().decode(FixtureDefinitionFile.self, from: inlineJSON)
        let fx = try XCTUnwrap(file.fixtures.first)
        XCTAssertEqual(fx.id, "amaran.pt4c.test")
        XCTAssertEqual(fx.effectiveVerification, .manufacturerChart)
        let guide = try XCTUnwrap(fx.setupGuide)
        XCTAssertEqual(guide.addressMenuBreadcrumb, "MENU → DMX → DMX Address")
        XCTAssertEqual(guide.modeMenuBreadcrumb, "MENU → DMX → DMX Profile")
        XCTAssertEqual(guide.factoryDefaults?.address, 1)
        XCTAssertEqual(guide.factoryDefaults?.signalLossBehavior, "Hold last look")
        XCTAssertEqual(guide.signalLossBehavior, "Hold last look / Blackout", "Array form is joined")
        XCTAssertEqual(guide.notes, ["Requires USB-C to DMX adapter for wired DMX."], "String form becomes one note")
        XCTAssertEqual(guide.formatAddress(17), "017")
        XCTAssertEqual(guide.formatAddress(900), "512", "Addresses are clamped to 1…512")
        XCTAssertEqual(fx.emitterSpec(for: .red)?.x, 0.692)
        XCTAssertEqual(fx.emitterSpec(for: .green)?.relativeLumens, 0.60)
        XCTAssertEqual(fx.emitterSpec(for: .blue)?.relativeLumens, 1.0)

        let mode = try XCTUnwrap(fx.recommendedMode)
        XCTAssertEqual(mode.channelCount, 56)
        XCTAssertEqual(mode.cellCount, 8)
        XCTAssertEqual(mode.displayFriendlyName, "Full color + white balance · 8 zones")
        XCTAssertEqual(mode.displayMenuName, "9: LE CCT&RGB 8px")
        XCTAssertNotNil(fx.mode(named: "9: LE CCT&RGB 8px"))
        XCTAssertNotNil(fx.mode(named: "LE CCT&RGB 8 px"))
        XCTAssertNotNil(fx.mode(named: "Full color + white balance · 8 zones"))

        let cctCh = try XCTUnwrap(mode.channels.first { $0.kind == .cct })
        XCTAssertEqual(cctCh.dmxValue(forPhysical: 2700), 0)
        XCTAssertEqual(cctCh.dmxValue(forPhysical: 10000), 255)
    }

    // MARK: - 2. Full Library Validation & Render Test (Curated + Generic + OFL + QLC+)

    func testLaunchReadsOnlyTheIndexAndParsesProfilesLazily() async throws {
        let t0 = PrismClock.now()
        let lib = TestResources.library()
        let loadMs = (PrismClock.now() - t0) * 1000
        print("FixtureLibrary index load: \(String(format: "%.1f", loadMs)) ms for \(lib.count) entries")
        XCTAssertTrue(lib.problems.isEmpty, "\(lib.problems)")
        XCTAssertGreaterThan(lib.count, 2000)
        XCTAssertEqual(lib.parsedFileCount, 0, "Launch must read only index.json, never the profile files")
        XCTAssertEqual(lib.loadedDefinitionCount, 0)
        // Generous bound: this runs unoptimized on shared CI machines.
        XCTAssertLessThan(loadMs, 2000, "Index load took \(loadMs) ms")

        // Index-only queries never parse.
        XCTAssertTrue(lib.contains("amaran.pt4c"))
        XCTAssertEqual(lib.entry("amaran.pt4c")?.manufacturer, "amaran")
        XCTAssertNil(lib.cachedDefinition("amaran.pt4c"))
        XCTAssertFalse(lib.search("pt4c", limit: 5).isEmpty)
        XCTAssertEqual(lib.parsedFileCount, 0)

        // Concurrent lookups of definitions in the same brand file parse it exactly once.
        let ids = ["amaran.pt1c", "amaran.pt2c", "amaran.pt4c", "amaran.f22c"]
        let found = await withTaskGroup(of: Bool.self) { group -> Int in
            for id in ids + ids { group.addTask { await lib.definitionAsync(id) != nil } }
            var n = 0
            for await ok in group where ok { n += 1 }
            return n
        }
        XCTAssertEqual(found, ids.count * 2)
        XCTAssertEqual(lib.parsedFileCount, 1, "One brand file should have been parsed")
        XCTAssertNotNil(lib.cachedDefinition("amaran.pt4c"))

        // Prefetch warms other files in the background without blocking.
        lib.prefetch(["generic.dimmer"])
        for _ in 0..<200 where lib.cachedDefinition("generic.dimmer") == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(lib.cachedDefinition("generic.dimmer"))
        XCTAssertEqual(lib.parsedFileCount, 2)
    }

    func testSourcePrecedence() {
        func def(_ source: String, model: String) -> FixtureDefinition {
            FixtureDefinition(id: "acme.light", manufacturer: "Acme", model: model, category: .par,
                              modes: [FixtureMode(name: "1ch", channels: [ChannelDefinition(kind: .intensity)])],
                              source: source)
        }
        let lib = FixtureLibrary()
        lib.add([def("qlcplus", model: "Q")])
        lib.add([def("ofl", model: "O")])
        XCTAssertEqual(lib.definition("acme.light")?.model, "O", "OFL beats QLC+")
        lib.add([def("qlcplus", model: "Q2")])
        XCTAssertEqual(lib.definition("acme.light")?.model, "O", "QLC+ never replaces OFL")
        lib.add([def("curated", model: "C")])
        lib.add([def("ofl", model: "O2")])
        XCTAssertEqual(lib.definition("acme.light")?.model, "C", "Curated wins over converted")
        lib.add([def("user", model: "U")])
        XCTAssertEqual(lib.definition("acme.light")?.model, "U", "The user's own edit wins")
        XCTAssertEqual(lib.entry("acme.light")?.source, "user")
        XCTAssertEqual(lib.count, 1)
    }

    func testEntireBundledLibraryLoadsValidatesAndRendersEveryMode() throws {
        let lib = TestResources.library()
        XCTAssertTrue(lib.problems.isEmpty, "Unexpected library load problems: \(lib.problems)")

        let entries = lib.allEntries
        XCTAssertGreaterThanOrEqual(entries.count, 2200, "Expected >= 2,200 bundled fixture entries, got \(entries.count)")

        // Footprints declared by the converters (OFL/QLC+ "footprint"), keyed by "id\u{1}mode".
        var declaredFootprints: [String: Int] = [:]
        let fm = FileManager.default
        for dir in ["curated", "generic", "ofl", "qlcplus"] {
            let folder = TestResources.fixtureLibrary.appendingPathComponent(dir)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasSuffix(".json") {
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                let root = try JSONSerialization.jsonObject(with: data)
                let fixtures = ((root as? [String: Any])?["fixtures"] as? [[String: Any]]) ?? (root as? [[String: Any]]) ?? []
                for fx in fixtures {
                    guard let id = fx["id"] as? String else { continue }
                    for mode in (fx["modes"] as? [[String: Any]]) ?? [] {
                        if let modeName = mode["name"] as? String, let footprint = mode["footprint"] as? Int {
                            declaredFootprints["\(id)\u{1}\(modeName)"] = footprint
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(declaredFootprints.count, 2000, "Converted modes should declare their footprint")

        var totalModesRendered = 0
        var footprintsChecked = 0
        var curatedCount = 0, oflCount = 0, qlcCount = 0
        var issues: [String] = []
        var curatedWarnings: [String] = []
        var convertedWarnings = 0
        let safety = SafetySettings()
        let states: [FixtureState] = [
            FixtureState(intensity: 0.75, color: .rgb(RGB(r: 0.2, g: 0.8, b: 0.9))),
            FixtureState(intensity: 0.5, color: .kelvin(3200, tint: 0)),
        ]

        for entry in entries {
            switch entry.source {
            case "curated": curatedCount += 1
            case "ofl": oflCount += 1
            case "qlcplus", "qlc": qlcCount += 1
            default: break
            }

            let def = try XCTUnwrap(lib.definition(entry.id), "Failed to load definition for \(entry.id) from \(entry.file)")
            XCTAssertEqual(def.id, entry.id)
            XCTAssertFalse(def.modes.isEmpty, "Fixture \(def.id) has no modes")
            let validation = def.validate()
            issues += validation.issues
            if entry.source == "curated" || entry.source == "generic" { curatedWarnings += validation.warnings }
            convertedWarnings += entry.source == "curated" || entry.source == "generic" ? 0 : validation.warnings.count

            // Every mode of this definition patched side by side (one universe each), rendered
            // through the real engine path.
            var fixtures: [PatchedFixture] = []
            var live = LiveState()
            for (index, mode) in def.modes.enumerated() {
                if let declared = declaredFootprints["\(def.id)\u{1}\(mode.name)"] {
                    XCTAssertEqual(mode.channelCount, declared, "Footprint mismatch for \(def.id) · \(mode.name)")
                    footprintsChecked += 1
                }
                let patched = PatchedFixture(name: def.displayName, shortName: "T\(index + 1)", definitionID: def.id,
                                             modeName: mode.name, universe: index + 1, address: 1)
                fixtures.append(patched)
                live.base[patched.id] = states[index % states.count]

                let resolved = ResolvedFixture(fixture: patched, definition: def, mode: mode)
                let dmx = FixtureRenderer.render(states[index % states.count], fixture: resolved, safety: safety, time: 1.0)
                XCTAssertEqual(dmx.count, mode.channelCount, "Rendered byte count mismatch for \(def.id) · \(mode.name)")
            }
            let doc = ShowDocument(project: Project(name: def.id, fixtures: fixtures), live: live)
            let frame = EngineCore.renderFrame(ShowSnapshot(document: doc, library: lib.definition), time: 1.0)
            for (index, mode) in def.modes.enumerated() {
                let universe = frame.universes[index + 1]
                XCTAssertNotNil(universe, "No DMX for \(def.id) · \(mode.name)")
                if let universe { XCTAssertGreaterThanOrEqual(universe.count, mode.channelCount) }
                totalModesRendered += 1
            }
        }

        XCTAssertTrue(issues.isEmpty, "\(issues.count) validation issues, e.g.:\n" + issues.prefix(25).joined(separator: "\n"))
        XCTAssertGreaterThanOrEqual(curatedCount, 90, "Expected >= 90 curated fixtures, got \(curatedCount)")
        XCTAssertGreaterThanOrEqual(oflCount, 600, "Expected >= 600 OFL fixtures, got \(oflCount)")
        XCTAssertGreaterThanOrEqual(qlcCount, 1500, "Expected >= 1500 QLC+ fixtures, got \(qlcCount)")
        XCTAssertGreaterThanOrEqual(totalModesRendered, 6000, "Expected >= 6000 total modes rendered, got \(totalModesRendered)")
        XCTAssertGreaterThan(footprintsChecked, 2000)
        print("Whole library: \(entries.count) fixtures, \(totalModesRendered) modes rendered, \(footprintsChecked) footprints checked")
    }

    // MARK: - 3. Curated Aputure / amaran & Film/TV Golden Tests

    func testAmaranPT4cGoldenDMXValues() throws {
        let lib = TestResources.library()
        let pt4c = try XCTUnwrap(lib.definition("amaran.pt4c"))
        XCTAssertEqual(pt4c.effectiveVerification, .manufacturerChart)
        XCTAssertFalse(pt4c.setupGuide?.addressMenuPath.isEmpty ?? true, "PT4c needs address menu steps")
        XCTAssertFalse(pt4c.setupGuide?.modeMenuPath.isEmpty ?? true, "PT4c needs mode menu steps")

        // Verify all required pixel modes exist ("LE CCT&RGB 2/4/8/16 px") and 8-pixel mode is recommended
        XCTAssertNotNil(pt4c.mode(named: "LE CCT&RGB 2 px"))
        XCTAssertNotNil(pt4c.mode(named: "LE CCT&RGB 4 px"))
        let mode8px = try XCTUnwrap(pt4c.mode(named: "LE CCT&RGB 8 px"))
        XCTAssertTrue(mode8px.recommended)
        XCTAssertEqual(mode8px.channelCount, 56)
        XCTAssertEqual(mode8px.cellCount, 8)
        XCTAssertNotNil(pt4c.mode(named: "LE CCT&RGB 16 px"))

        // Golden test on the PT4c "CCT & RGB" whole-tube mode (amaran chart, 10 channels):
        // [Intensity, CCT, G/M, Crossfade, R, G, B, Reserved, Reserved, Strobe]
        let mode = try XCTUnwrap(pt4c.mode(named: "CCT & RGB"))
        XCTAssertEqual(mode.channelCount, 10)
        XCTAssertEqual(pt4c.mode(named: "1: CCT&RGB 8-bit")?.name, mode.name, "Menu wording finds the same mode")

        func render(_ state: FixtureState, modeName: String) throws -> [UInt8] {
            let patched = PatchedFixture(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000999") ?? UUID(),
                name: "PT4c Test",
                shortName: "PT4",
                definitionID: "amaran.pt4c",
                modeName: modeName,
                universe: 1,
                address: 1
            )
            var live = LiveState()
            live.base[patched.id] = state
            let doc = ShowDocument(project: Project(name: "Golden", fixtures: [patched]), live: live)
            let snap = ShowSnapshot(document: doc, library: lib.definition)
            let frame = EngineCore.renderFrame(snap, time: 0)
            return try XCTUnwrap(frame.universes[1])
        }

        // Case 1: "3200 K warm white at 50%"
        // Intensity 50% -> 128; CCT 3200 K on 2700–10000 K -> round(500/7300*255) = 17;
        // G/M neutral -> 128 (documented neutral, inside the 120–145 neutral band);
        // crossfade 0 (CCT side); RGB 0; reserved 0; strobe 0 (0–19 = off).
        let uWarm = try render(FixtureState(intensity: 0.5, color: .kelvin(3200, tint: 0)), modeName: mode.name)
        XCTAssertEqual(Array(uWarm.prefix(10)), [128, 17, 128, 0, 0, 0, 0, 0, 0, 0], "3200 K @ 50%")

        // Case 2: "pure red" at 100%: crossfade flips to the RGB side.
        let uRed = try render(FixtureState(intensity: 1.0, color: .rgb(RGB(r: 1, g: 0, b: 0))), modeName: mode.name)
        XCTAssertEqual(uRed[0], 255, "Intensity at 100%")
        XCTAssertEqual(uRed[3], 255, "Crossfade should flip to 255 (RGB side) for pure red")
        XCTAssertEqual(uRed[4], 255, "Red byte should be 255")
        XCTAssertEqual(uRed[5], 0, "Green byte should be 0")
        XCTAssertEqual(uRed[6], 0, "Blue byte should be 0")
        XCTAssertEqual(Array(uRed[7...9]), [0, 0, 0], "Reserved + strobe stay at 0")

        // Case 3: "teal" (#00C2A8) at 100%. Exact bytes depend on the color team's emitter
        // mixer; the shape (no red, strong green, a bit less blue, RGB side) must hold.
        let teal = try XCTUnwrap(LightColor.hex("#00C2A8"))
        let uTeal = try render(FixtureState(intensity: 1.0, color: teal), modeName: mode.name)
        XCTAssertEqual(uTeal[0], 255)
        XCTAssertEqual(uTeal[3], 255, "Crossfade should be 255 (RGB side) for teal")
        XCTAssertLessThanOrEqual(uTeal[4], 8, "Teal has (almost) no red")
        XCTAssertGreaterThan(uTeal[5], 150, "Teal is mostly green")
        XCTAssertGreaterThan(uTeal[6], 100, "Teal has strong blue")
        XCTAssertGreaterThan(uTeal[5], uTeal[6], "Teal has more green than blue")
        XCTAssertEqual(uTeal[9], 0, "Strobe stays off")

        // The user's rig: "LE CCT&RGB 8 px" = 8 cells × [Intensity, CCT, G/M, Crossfade, R, G, B].
        let uPixels = try render(FixtureState(intensity: 0.5, color: .kelvin(3200, tint: 0)), modeName: mode8px.name)
        for cell in 0..<8 {
            XCTAssertEqual(Array(uPixels[(cell * 7)..<(cell * 7 + 7)]), [128, 17, 128, 0, 0, 0, 0], "cell \(cell + 1)")
        }
        XCTAssertTrue(uPixels[56...].allSatisfy { $0 == 0 }, "Nothing written past the 56-channel footprint")

        // amaran's "Neutral" tint band appears twice (0–10 and 120–145); neutral must use 128.
        let tint = try XCTUnwrap(mode.channels.first { $0.kind == .tint })
        XCTAssertEqual(tint.dmxValue(forPhysical: 0), 128)
        XCTAssertEqual(tint.dmxValue(forPhysical: -1), 15, "Full minus green = centre of 11–20")
    }

    func testCuratedPackCoverage() throws {
        let lib = TestResources.library()
        // Every wired-DMX light in docs/research/aputure_profiles.md, plus the Film/TV brands
        // the brief names. (amaran 100d S/200x S, 150c/300c, P60c, Accent B7c... have no wired
        // DMX at all, so they are deliberately absent.)
        let requiredIDs = [
            // amaran
            "amaran.pt1c", "amaran.pt2c", "amaran.pt4c", "amaran.t2c", "amaran.t4c",
            "amaran.f21c", "amaran.f22c", "amaran.f21x", "amaran.f22x",
            "amaran.ray-360c", "amaran.ray-660c",
            "amaran.halo-60x", "amaran.halo-100x", "amaran.halo-200x", "amaran.halo-300x", "amaran.halo-600x",
            // Aputure
            "aputure.infinibar-pb3", "aputure.infinibar-pb6", "aputure.infinibar-pb12", "aputure.mt-pro",
            "aputure.nova-p300c", "aputure.nova-p600c",
            "aputure.ls-600c-pro", "aputure.ls-600c-pro-ii", "aputure.ls-600x-pro", "aputure.ls-300x",
            "aputure.ls-600d-pro", "aputure.ls-300d-ii", "aputure.ls-600d", "aputure.ls-1200d-pro", "aputure.ls-c300d-ii",
            "aputure.storm-1000c", "aputure.storm-80c", "aputure.storm-1200x",
            "aputure.electro-storm-xt26", "aputure.electro-storm-cs15",
            // Film/TV brands
            "nanlite.pavotube-ii-6c", "nanlite.pavotube-ii-15c", "nanlite.pavotube-ii-30c", "nanlite.pavotube-ii-60c",
            "nanlite.pavotube-ii-30x", "nanlite.forza-60c", "nanlite.fs-300b",
            "godox.tl60", "godox.knowled-mg1200bi", "godox.sl60iibi",
            "astera.titan-tube-fp1", "astera.helios-tube-fp2", "astera.hyperion-tube-fp3", "astera.ax1-pixeltube",
            "litepanels.gemini-2x1-hard", "litepanels.astra-6x-bi-color",
            "arri.skypanel-s30-c", "arri.skypanel-s60-c", "arri.skypanel-s120-c", "arri.skypanel-s360-c", "arri.orbiter",
            "kino-flo.freestyle-31-led", "kino-flo.celeb-250-led-dmx",
            "quasar-science.rainbow-2-q50r2", "quasar-science.double-rainbow-rr50",
            "creamsource.vortex8", "rotolight.titan-x2",
        ]
        for id in requiredIDs {
            let def = try XCTUnwrap(lib.definition(id), "Missing curated fixture \(id)")
            XCTAssertEqual(def.source, "curated", "Expected \(id) to be curated, got \(def.source ?? "nil")")
        }

        // Quality bar for every curated fixture (not just the required ones).
        let curated = lib.allEntries.filter { $0.source == "curated" }
        XCTAssertGreaterThanOrEqual(curated.count, 90)
        for entry in curated {
            let def = try XCTUnwrap(lib.definition(entry.id), "Missing curated fixture \(entry.id)")
            XCTAssertEqual(def.id, def.id.lowercased(), "IDs are lowercase slugs: \(def.id)")
            XCTAssertNil(def.id.rangeOfCharacter(from: CharacterSet(charactersIn: "() /&")), "Clean ID: \(def.id)")
            XCTAssertNotNil(def.setupGuide, "\(def.id) missing setupGuide")
            XCTAssertFalse(def.setupGuide?.addressMenuPath.isEmpty ?? true, "\(def.id) missing address steps")
            XCTAssertNotNil(def.recommendedMode, "\(def.id) has no recommended mode")
            for mode in def.modes {
                XCTAssertNotNil(mode.friendlyName, "\(def.id) · \(mode.name) missing friendlyName")
                XCTAssertNotNil(mode.fixtureMenuName, "\(def.id) · \(mode.name) missing fixtureMenuName")
            }
        }

        // PT tubes only offer the pixel counts their hardware supports (research §2.3, §14).
        let pixelModes: [String: [Int]] = ["amaran.pt1c": [2, 4], "amaran.pt2c": [2, 4, 8], "amaran.pt4c": [2, 4, 8, 16]]
        for (id, counts) in pixelModes {
            let def = try XCTUnwrap(lib.definition(id))
            let found = def.modes.filter { $0.name.hasPrefix("Light Engine CCT & RGB") }.map(\.cellCount).sorted()
            XCTAssertEqual(found, counts, "\(id) LE CCT&RGB pixel counts")
            for n in counts {
                let mode = try XCTUnwrap(def.mode(named: "LE CCT&RGB \(n) px"), "\(id) LE CCT&RGB \(n) px")
                XCTAssertEqual(mode.channelCount, n * 7, "\(id) \(n) px footprint")
            }
        }
    }

    // MARK: - 4. Search Accuracy, Typo Tolerance & Benchmark (< 30 ms on 10k entries)

    func testSearchRankingAndAliases() {
        let lib = TestResources.library()

        let queriesAndExpectedPrefixes: [(String, String)] = [
            ("amaran pt4c", "amaran.pt4c"),
            ("PT4c", "amaran.pt4c"),
            ("pt 4c", "amaran.pt4c"),
            ("amaran pt 4", "amaran.pt4c"),
            ("amaran tube", "amaran.pt"),
            ("pixel tube", "amaran.pt"),
            ("pavotube", "nanlite.pavotube"),
            ("pavo tube", "nanlite.pavotube"),
            ("nanlight pavotube", "nanlite.pavotube"),
            ("skypanel", "arri.skypanel"),
            ("sky panel s60", "arri.skypanel-s60"),
            ("Nova", "aputure.nova"),
            ("nova p600c", "aputure.nova-p600c"),
            ("Titan", "astera.titan-tube"),
            ("infinibar", "aputure.infinibar"),
            ("ls600c", "aputure.ls-600c"),
            ("600c pro", "aputure.ls-600c-pro"),
            ("forza 60", "nanlite.forza-60"),
            ("gemini", "litepanels.gemini"),
            ("rgb par", "generic.rgb"),
            ("Chauvet SlimPAR", "chauvet"),
            ("generic dimmer", "generic.dimmer"),
            ("dimmer", "generic.dimmer"),
            ("hazer", "generic.fog-haze"),
            // Typos
            ("skypannel", "arri.skypanel"),
            ("pavotub", "nanlite.pavotube"),
            ("amarn pt4c", "amaran.pt4c"),
            ("aputre nova", "aputure.nova"),
            ("astra titan", "astera.titan-tube"),
        ]

        for (query, expectedPrefix) in queriesAndExpectedPrefixes {
            let top3 = lib.search(query, limit: 3)
            XCTAssertTrue(
                top3.contains { $0.id.lowercased().hasPrefix(expectedPrefix.lowercased()) },
                "Query '\(query)' did not return '\(expectedPrefix)*' in top 3: got \(top3.map(\.id))"
            )
        }

        // Curated first: the exact curated PT4c beats any community profile with the same name.
        XCTAssertEqual(lib.search("amaran pt4c", limit: 1).first?.id, "amaran.pt4c")
        XCTAssertEqual(lib.search("PT4c", limit: 1).first?.id, "amaran.pt4c")
        // Category filter.
        let tubes = lib.search("amaran", category: .tube, limit: 20)
        XCTAssertFalse(tubes.isEmpty)
        XCTAssertTrue(tubes.allSatisfy { $0.category == .tube }, "\(tubes.map(\.id))")
        // Garbage finds nothing rather than random fixtures.
        XCTAssertTrue(lib.search("zzqxj", limit: 5).isEmpty)
        // Empty query lists the curated packs first.
        XCTAssertEqual(lib.search("", limit: 10).first?.source, "curated")
    }

    func testSearchPerformanceUnder30msOn10kEntries() {
        let baseLib = TestResources.library()
        let baseEntries = baseLib.allEntries
        XCTAssertGreaterThan(baseEntries.count, 2000)

        // Build a synthetic 10,000-entry library to benchmark worst-case search speed
        let bigLib = FixtureLibrary()
        var synthDefs: [FixtureDefinition] = []
        synthDefs.reserveCapacity(10_000)
        let dummyMode = FixtureMode(name: "3ch", recommended: true, channels: [
            ChannelDefinition(kind: .red, label: "Red"),
            ChannelDefinition(kind: .green, label: "Green"),
            ChannelDefinition(kind: .blue, label: "Blue")
        ])
        for i in 0..<10_000 {
            let base = baseEntries[i % baseEntries.count]
            synthDefs.append(FixtureDefinition(
                id: "\(base.id).synth\(i)",
                manufacturer: base.manufacturer,
                model: "\(base.model) Mk\(i / baseEntries.count + 1)",
                category: base.category,
                aliases: base.aliases,
                modes: [dummyMode],
                source: i < 100 ? "curated" : "ofl"
            ))
        }
        bigLib.add(synthDefs)
        XCTAssertEqual(bigLib.count, 10_000)

        // The app builds the search index in the background right after launch.
        let tBuild = PrismClock.now()
        _ = bigLib.searchIndex()
        print("Search index build for 10k entries: \(String(format: "%.1f", (PrismClock.now() - tBuild) * 1000)) ms")
        XCTAssertTrue(bigLib.isSearchIndexWarm)

        let queries = ["amaran pt4c", "pavotube", "skypanel", "Chauvet SlimPAR", "generic dimmer",
                       "skypannel", "amarn pt4c", "pt 4c", "led", "a"]
        for q in queries {
            let t0 = PrismClock.now()
            let results = bigLib.search(q, limit: 50)
            let elapsedMs = (PrismClock.now() - t0) * 1000.0
            XCTAssertFalse(results.isEmpty, "Empty results for \(q)")
            XCTAssertLessThan(elapsedMs, 30.0, "Search for '\(q)' over 10k entries took \(String(format: "%.2f", elapsedMs)) ms (budget < 30 ms)")
        }
    }

    func testRecentlyUsedTracking() {
        let lib = TestResources.library()
        lib.recordRecent("amaran.f22c")
        lib.recordRecent("amaran.pt4c")
        XCTAssertEqual(lib.recentIDs.prefix(2), ["amaran.pt4c", "amaran.f22c"])
        XCTAssertEqual(lib.recentEntries.first?.id, "amaran.pt4c")
    }

    // MARK: - 5. User Profiles, Project Embedding Round-Trip & Importers

    func testUserProfileAndProjectEmbeddingRoundTrip() throws {
        let customDef = FixtureDefinition(
            id: "user.custom-key-light",
            manufacturer: "Custom Studio",
            model: "Key Light Pro",
            category: .panel,
            cctRange: [2800, 6500],
            modes: [
                FixtureMode(
                    name: "CCT 2ch",
                     summary: "White balance only",
                    recommended: true,
                    channels: [
                        ChannelDefinition(kind: .intensity, label: "Dimmer"),
                        ChannelDefinition(kind: .cct, label: "CCT", physical: PhysicalRange(from: 2800, to: 6500, unit: "K"))
                    ],
                    friendlyName: "White balance only",
                    fixtureMenuName: "M1: CCT"
                )
            ],
            source: "user"
        )

        // Export & re-import as .prismfixture
        let exportedData = try FixtureImporter.exportPrismFixture(customDef)
        let reimported = try FixtureImporter.importData(exportedData, filename: "custom-key-light.prismfixture")
        XCTAssertEqual(reimported.first?.id, "user.custom-key-light")

        // Create a project using this custom fixture, save to disk, and load with a library that lacks it
        let libWithCustom = TestResources.library()
        libWithCustom.add([customDef])

        let patched = PatchedFixture(
            name: "My Custom Key",
            shortName: "CK1",
            definitionID: customDef.id,
            modeName: "CCT 2ch",
            universe: 1,
            address: 1
        )
        let project = Project(name: "Custom Show", fixtures: [patched])
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString).prismlights")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try ProjectIO.write(project, to: tmpURL, library: libWithCustom.definition)
        let loaded = try ProjectIO.read(from: tmpURL)
        XCTAssertTrue(loaded.definitions.contains { $0.id == "user.custom-key-light" })

        let freshLib = FixtureLibrary()
        freshLib.add(loaded.definitions)
        let resolved = loaded.resolvedFixtures(library: freshLib.definition)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.definition.id, "user.custom-key-light")
    }

    func testImportRawOFLAndQLCPlusFormats() throws {
        let rawOFL = """
        {
          "$schema": "https://raw.githubusercontent.com/OpenLightingProject/open-fixture-library/master/schemas/fixture.json",
          "name": "Test Bar 4",
          "shortName": "TBar4",
          "categories": ["Pixel Bar", "Color Changer"],
          "meta": {"authors": ["Test Author"]},
          "matrix": {"pixelCount": [4, 1, 1]},
          "availableChannels": {
            "Master Dimmer": {"capability": {"type": "Intensity"}}
          },
          "templateChannels": {
            "Red $pixelKey": {"capability": {"type": "ColorIntensity", "color": "Red"}},
            "Green $pixelKey": {"capability": {"type": "ColorIntensity", "color": "Green"}},
            "Blue $pixelKey": {"capability": {"type": "ColorIntensity", "color": "Blue"}}
          },
          "modes": [{
            "name": "13-channel",
            "channels": [
              "Master Dimmer",
              {"insert": "matrixChannels", "repeatFor": "eachPixelABC", "channelOrder": "perPixel",
               "templateChannels": ["Red $pixelKey", "Green $pixelKey", "Blue $pixelKey"]}
            ]
          }]
        }
        """.data(using: .utf8)!

        let oflDefs = try FixtureImporter.importData(rawOFL, filename: "test-bar-4.json")
        let oflDef = try XCTUnwrap(oflDefs.first)
        XCTAssertEqual(oflDef.model, "Test Bar 4")
        XCTAssertEqual(oflDef.category, .bar)
        XCTAssertEqual(oflDef.modes.first?.channelCount, 13)
        XCTAssertEqual(oflDef.modes.first?.cellCount, 4)

        let rawQLC = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE FixtureDefinition>
        <FixtureDefinition xmlns="http://www.qlcplus.org/FixtureDefinition">
         <Creator><Name>Q Light Controller Plus</Name><Version>4.12.7</Version><Author>Jane Doe</Author></Creator>
         <Manufacturer>TestBrand</Manufacturer>
         <Model>SlimWash RGBW</Model>
         <Type>Color Changer</Type>
         <Channel Name="Dimmer" Preset="IntensityMasterDimmer"/>
         <Channel Name="Red" Preset="IntensityRed"/>
         <Channel Name="Green" Preset="IntensityGreen"/>
         <Channel Name="Blue" Preset="IntensityBlue"/>
         <Channel Name="White" Preset="IntensityWhite"/>
         <Mode Name="5 Channel">
          <Channel Number="0">Dimmer</Channel>
          <Channel Number="1">Red</Channel>
          <Channel Number="2">Green</Channel>
          <Channel Number="3">Blue</Channel>
          <Channel Number="4">White</Channel>
         </Mode>
        </FixtureDefinition>
        """.data(using: .utf8)!

        let qlcDefs = try FixtureImporter.importData(rawQLC, filename: "TestBrand-SlimWash.qxf")
        let qlcDef = try XCTUnwrap(qlcDefs.first)
        XCTAssertEqual(qlcDef.id, "testbrand.slimwash-rgbw")
        XCTAssertEqual(qlcDef.manufacturer, "TestBrand")
        XCTAssertEqual(qlcDef.modes.first?.channelCount, 5)
        XCTAssertTrue(qlcDef.modes.first?.capabilities.hasRGB ?? false)
        XCTAssertTrue(qlcDef.modes.first?.capabilities.emitters.contains(.white) ?? false)
        XCTAssertEqual(qlcDef.sourceInfo?.authors, ["Jane Doe"])
    }
}
