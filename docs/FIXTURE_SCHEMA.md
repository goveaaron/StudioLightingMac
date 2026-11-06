# Prism Fixture Schema (`prism-fixture/1`)

`FixtureDefinition` (`Sources/PrismCore/Fixtures/FixtureDefinition.swift`) describes a physical lighting fixture model, its DMX personalities (`FixtureMode`), its setup instructions (`FixtureSetupGuide`), provenance (`FixtureSource`, `FixtureVerification`), and emitter photometrics (`EmitterSpec`).

Definitions are stored as JSON in `Resources/FixtureLibrary/{curated,generic,ofl,qlcplus}/`, in user profiles under `~/Library/Application Support/Prism/Fixtures/`, and embedded inside `.prismlights` project files so projects open on any Mac without external dependencies.

All fields introduced after the initial baseline are **optional** and decode defensively with sensible fallbacks. Both single-fixture (`prism-fixture/1` with shared `definitions` or inline channels) and multi-fixture pack files (`FixtureDefinitionFile` with `"schemaVersion": 1, "fixtures": [...]`) are supported.

---

## 1. Top-Level `FixtureDefinition` Fields

| Field | Swift Type | Required | Description |
|---|---|---|---|
| `id` | `String` | Yes (auto-derived if omitted) | Stable lowercase ID (`"amaran.pt4c"`, `"aputure/nova-p300c"`). |
| `manufacturer` | `String` | Yes | Display brand name (`"amaran"`, `"Aputure"`, `"ARRI"`). |
| `model` | `String` | Yes | Display model name (`"PT4c"`, `"Nova P300c"`). |
| `category` | `FixtureCategory` | Yes | Form factor: `tube`, `panel`, `spot` (also accepts `"cob"`), `fresnel`, `par`, `bulb`, `strip`, `bar`, `wash`, `movingHead`, `dimmer`, `effect`, `other`. |
| `aliases` | `[String]` | No | Search aliases and common shorthand names (`["PT4c", "Pixel Tube 4c", "Amaran PT"]`). |
| `physical` | `PhysicalSpec?` | No | Dimensions (`lengthMM`, `widthMM`, `heightMM`, `diameterMM`, or `dimensionsMm: [w, h, d]`), `weightKG`, `powerW`. |
| `cctRange` | `[Double]?` | No | Native white Kelvin range `[minK, maxK]`, e.g. `[2700, 10000]`. |
| `setupGuide` | `FixtureSetupGuide?` | No | Plain-English hardware setup instructions for Setup Cards and the Add Light wizard (§2). |
| `verification` | `FixtureVerification?` | No | `manufacturerChart`, `community`, or `unverified` (`effectiveVerification` derives a fallback from `source`). |
| `source` | `String?` | No | Origin tag (`"curated"`, `"ofl"`, `"qlc"`, `"user"`, `"generic"`). Also accepts a `FixtureSource` object in JSON. |
| `sourceInfo` | `FixtureSource?` | No | Structured provenance (`kind`, `url`, `license`, `authors`, `commit`). |
| `emitters` | `[ChannelKind: EmitterSpec]?` | No | Optional per-emitter CIE 1931 `(x, y)` chromaticity and relative `lumens` (§5). |
| `modes` | `[FixtureMode]` | Yes | Ordered list of DMX personalities (§3). |
| `notes` | `String?` | No | Human-readable notes (accepts `String` or `[String]` in JSON). |
| `addressHelp` | `String?` | No | Legacy one-line address setup hint. |
| `links` | `[String]?` | No | Manual / spec URLs (accepts `[String]` or OFL `{manual: [...], productPage: [...]}`). |
| `revision` | `Int?` | No | Schema/profile revision counter. |

---

## 2. `FixtureSetupGuide` (Hardware Setup Instructions)

Used by the Patch workstream (`SetupCardsSheet`, `AddFixtureSheet`, `TroubleshooterSheet`) to show exact on-device button paths and screen formatting.

```json
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
  "manualURL": "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf"
}
```

### Swift Helpers on `FixtureSetupGuide`
- `setupGuide.formatAddress(17)` (or `formattedAddress(17)`): formats a 1-based DMX address using `addressDisplayFormat` (e.g. `"A001"` → `"A017"`, `"001"` → `"017"`, `"d001"` → `"d017"`).
- `setupGuide.addressMenuBreadcrumb`: `"MENU → DMX Settings → DMX Address"`.
- `setupGuide.modeMenuBreadcrumb`: `"MENU → DMX Settings → DMX Profiles"`.

---

## 3. `FixtureMode` (Per-Mode Fields)

| Field | Swift Type | Description |
|---|---|---|
| `name` | `String` | Canonical mode name from the DMX specification (e.g. `"Light Engine CCT & RGB 8 Pixels"`). |
| `shortName` | `String?` | Compact label (e.g. `"56ch"`, `"M9"`). |
| `friendlyName` | `String?` | Plain-English description for the Add Light wizard (e.g. `"Full color · 8 zones"`). `mode.displayFriendlyName` falls back to `summary ?? name`. |
| `fixtureMenuName` | `String?` | Exact text shown on the physical fixture's screen (e.g. `"9: LE CCT&RGB 8PX"`). `mode.displayMenuName` falls back to `shortName ?? name`. |
| `recommended` | `Bool` | `true` for the mode Prism recommends by default (`definition.recommendedMode`). |
| `summary` | `String?` | Additional plain-language explanation of what this mode unlocks. |
| `channels` | `[ChannelDefinition]` | Flattened DMX channel list (0-indexed offset = position in array). |
| `pixels` | `PixelTemplate?` | Authoring shorthand (`{"count": 8, "channels": [...]}`) automatically expanded into `channels` with 0-based `cell` indices on decode. |
| `cellCount` | `Int` | Computed number of pixel cells (`0` for single-zone modes). |
| `cellLayout` | `CellLayout` | `.linear` or `.grid(columns: Int, rows: Int)`. |

---

## 4. `ChannelDefinition`, `ChannelKind`, `PhysicalRange`, and `ChannelCapability`

### `ChannelKind`
- **Intensity:** `intensity`
- **Additive Emitters (`kind.isEmitter == true`):** `red`, `green`, `blue`, `white`, `warmWhite`, `coolWhite`, `amber`, `lime`, `cyan`, `magenta`, `yellow`, `uv`, `indigo`
- **White & Color Spaces:** `cct`, `tint` (`-1` = full minus green / magenta, `0` = neutral, `+1` = full plus green), `hue` (`0…360` deg), `saturation` (`0…1`), `cieX`, `cieY` (`0…0.8`), `crossfade` (`0` = CCT white, `1` = RGB/HSI color), `colorMode`, `colorMacro`, `gel`
- **Shutter / Strobe:** `strobe`, `shutter`
- **Effects & Motion:** `effect`, `effectSpeed`, `effectParameter`, `pan`, `tilt`, `zoom`, `focus`, `gobo`, `prism`, `iris`
- **Service / Misc:** `fan`, `control`, `dimmerCurve`, `generic`, `nothing`

### `ChannelDefinition` Fields
- `kind: ChannelKind`
- `fine: Bool` (`true` for the LSB of a 16-bit channel pair)
- `cell: Int?` (0-based pixel index, `nil` for whole-fixture channels)
- `label: String?`
- `defaultValue: UInt8` (home DMX value sent when idle, e.g. `128` for Aputure G/M tint)
- `highlightValue: UInt8?`
- `physical: PhysicalRange?` (`{"from": 2700, "to": 10000}` or `[2700, 10000]`)
- `capabilities: [ChannelCapability]?` (`[{"range": [0, 19], "label": "Off", "tag": "off"}, {"range": [20, 255], "label": "Strobe 1–25 Hz", "tag": "strobe", "physical": [1, 25]}]`)
- `advanced: Bool` (`true` for effect/control channels; `ch.isAdvanced` is true when `advanced` is set or `kind.isAdvancedByDefault` is true)
- `emitter: EmitterSpec?` (optional per-channel emitter spec override)

---

## 5. `EmitterSpec` (Per-Emitter Photometrics for `EmitterMixer`)

Used by the Color workstream (`EmitterMixer`) for chromaticity-accurate color mixing across RGB, RGBW, RGBWW, RGBA, and RGBACL fixtures.

```json
"emitters": {
  "red":       { "x": 0.690, "y": 0.308, "lumens": 0.25, "wavelength": 625 },
  "green":     { "x": 0.170, "y": 0.715, "lumens": 0.65, "wavelength": 525 },
  "blue":      { "x": 0.140, "y": 0.045, "lumens": 0.10, "wavelength": 460 },
  "warmWhite": { "x": 0.460, "y": 0.411, "lumens": 0.90, "cct": 2700 },
  "coolWhite": { "x": 0.313, "y": 0.329, "lumens": 1.00, "cct": 6500 }
}
```

- `definition.emitterSpec(for: kind)` returns the fixture's custom `EmitterSpec` if present, or falls back to `EmitterSpec.standard(for: kind)`.
