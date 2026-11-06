import XCTest
@testable import PrismCore

final class LibraryTests: XCTestCase {
    func testSchemaAdditionsDecodeAndRoundTrip() throws {
        let json = """
        {
          "id": "amaran.pt4c",
          "manufacturer": "amaran",
          "model": "PT4c",
          "category": "tube",
          "aliases": ["PT4c", "Pixel Tube 4c", "Amaran PT"],
          "physical": { "lengthMM": 1200, "diameterMM": 42, "weightKG": 1.375, "powerW": 70 },
          "cctRange": [2700, 10000],
          "verification": "manufacturerChart",
          "source": {
            "kind": "curated",
            "url": "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf",
            "license": "Proprietary-Facts"
          },
          "revision": 2,
          "emitters": {
            "red": { "x": 0.692, "y": 0.306, "lumens": 0.26, "wavelength": 625 },
            "green": { "x": 0.168, "y": 0.718, "lumens": 0.66, "wavelength": 525 },
            "blue": { "x": 0.138, "y": 0.046, "lumens": 0.11, "wavelength": 460 },
            "warmWhite": { "x": 0.459, "y": 0.411, "lumens": 0.92, "cct": 2700 },
            "coolWhite": { "x": 0.312, "y": 0.329, "lumens": 1.00, "cct": 6500 }
          },
          "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profiles"],
            "factoryDefaults": {
              "address": 1,
              "mode": "CCT & RGB",
              "signalLossBehavior": "Hold Last Setting"
            },
            "connector": "USB-C → amaran Type-C to DMX Adapter (sold separately)",
            "addressDisplayFormat": "001",
            "usesDipSwitches": false,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black (60s) / Hold 2m & Fade",
            "notes": [
              "Press and hold OK for 2s on the DMX Address screen to lock/unlock the address.",
              "Leave the DMX Address screen visible while controlling over wired DMX."
            ],
            "manualURL": "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-Product-Manual-V1.2-0207.pdf"
          },
          "modes": [
            {
              "name": "Light Engine CCT & RGB 8 Pixels",
              "shortName": "56ch",
              "friendlyName": "Full color · 8 zones",
              "fixtureMenuName": "9: LE CCT&RGB 8PX",
              "summary": "8 independent zones with white balance and RGB color",
              "recommended": true,
              "pixels": {
                "count": 8,
                "channels": [
                  { "kind": "intensity", "label": "Intensity" },
                  { "kind": "cct", "label": "CCT", "physical": [2700, 10000] },
                  { "kind": "tint", "label": "G/M", "default": 128, "physical": [-1, 1] },
                  { "kind": "crossfade", "label": "CCT <-> RGB", "physical": [0, 1] },
                  { "kind": "red", "label": "Red" },
                  { "kind": "green", "label": "Green" },
                  { "kind": "blue", "label": "Blue" }
                ]
              }
            }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let def = try JSONDecoder().decode(FixtureDefinition.self, from: data)
        XCTAssertEqual(def.id, "amaran.pt4c")
        XCTAssertEqual(def.source, "curated")
        XCTAssertEqual(def.verification, .manufacturerChart)
        XCTAssertEqual(def.effectiveVerification, .manufacturerChart)
        XCTAssertEqual(def.sourceInfo?.license, "Proprietary-Facts")
        XCTAssertEqual(def.revision, 2)

        let guide = try XCTUnwrap(def.setupGuide)
        XCTAssertEqual(guide.addressMenuPath, ["MENU", "DMX Settings", "DMX Address"])
        XCTAssertEqual(guide.modeMenuPath, ["MENU", "DMX Settings", "DMX Profiles"])
        XCTAssertEqual(guide.factoryDefaults?.address, 1)
        XCTAssertEqual(guide.factoryDefaults?.mode, "CCT & RGB")
        XCTAssertEqual(guide.formatAddress(17), "017")
        XCTAssertFalse(guide.usesDipSwitches)
        XCTAssertEqual(guide.notes.count, 2)

        let redSpec = try XCTUnwrap(def.emitterSpec(for: .red))
        XCTAssertEqual(redSpec.x, 0.692, accuracy: 1e-4)
        XCTAssertEqual(redSpec.y, 0.306, accuracy: 1e-4)
        XCTAssertEqual(redSpec.relativeLumens, 0.26, accuracy: 1e-4)
        // Standard fallback for emitter not in JSON:
        XCTAssertNotNil(def.emitterSpec(for: .amber))

        let mode = try XCTUnwrap(def.recommendedMode)
        XCTAssertEqual(mode.friendlyName, "Full color · 8 zones")
        XCTAssertEqual(mode.fixtureMenuName, "9: LE CCT&RGB 8PX")
        XCTAssertEqual(mode.displayFriendlyName, "Full color · 8 zones")
        XCTAssertEqual(mode.displayMenuName, "9: LE CCT&RGB 8PX")
        XCTAssertEqual(mode.channelCount, 56)
        XCTAssertEqual(mode.cellCount, 8)
        XCTAssertNotNil(def.mode(named: "9: LE CCT&RGB 8PX"))
        XCTAssertNotNil(def.mode(named: "Full color · 8 zones"))

        // Round-trip encode/decode
        let encoded = try JSONEncoder().encode(def)
        let roundTripped = try JSONDecoder().decode(FixtureDefinition.self, from: encoded)
        XCTAssertEqual(roundTripped, def)
    }

    func testAddressFormatPatterns() {
        var guide = FixtureSetupGuide(addressDisplayFormat: "A001")
        XCTAssertEqual(guide.formatAddress(1), "A001")
        XCTAssertEqual(guide.formatAddress(113), "A113")
        guide.addressDisplayFormat = "d001"
        XCTAssertEqual(guide.formatAddress(5), "d005")
        guide.addressDisplayFormat = "001"
        XCTAssertEqual(guide.formatAddress(42), "042")
    }
}
