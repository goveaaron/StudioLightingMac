# Brief: library — fixture library for any kind of light

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/fixture_libraries.md` (all of it)
- `docs/research/aputure_profiles.md` §0, §1, §2, §14
- `docs/research/competitors.md` §2.2 and §4

## Goal

Prism ships with the best fixture library of any Mac lighting app:
- Every Aputure/amaran light is exact and verified.
- Common film/TV brands are curated.
- The entire Open Fixture Library and QLC+ library (thousands of lights) is searchable.

"Add Light" should always find the user's light. Each profile also carries plain-English setup
instructions: how to set the address and mode on the light itself.

## You own

`Resources/FixtureLibrary/**`, `tools/fixtures/**`, `Sources/PrismCore/Library/**`,
`Sources/PrismCore/Fixtures/FixtureDefinition.swift`, `Sources/PrismApp/Library/**`,
`docs/FIXTURE_SCHEMA.md`, `docs/THIRD_PARTY.md`, and the library tests.

## Deliverables (priority order)

### 1. Schema additions — land these first, other teams wait on them

Add to `FixtureDefinition.swift`. All new fields are optional, and existing `prism-fixture/1`
files must still decode.
- **`setupGuide: FixtureSetupGuide?`**
  - `addressMenuPath: [String]` (e.g. `["MENU", "DMX", "Address"]`) and `modeMenuPath`
  - `factoryDefaults` (address, mode)
  - `connector` (e.g. "5-pin XLR in/out", "USB-C → DMX adapter (sold separately)")
  - `addressDisplayFormat` (e.g. "A001"), `usesDipSwitches`, `signalLossBehavior`
  - `notes: [String]`, `manualURL`
- **Per mode:**
  - `friendlyName` ("Full color · 8 zones")
  - `fixtureMenuName` (the exact text shown on the light, e.g. "CCT&RGB 8PX")
  - `recommended: Bool`, `summary`
- **Per definition:**
  - `aliases: [String]` ("PT4c", "Pixel Tube 4c")
  - `verification` (manufacturerChart / community / unverified)
  - `source` (URL + license), `revision`
  - Optional per-emitter chromaticity (xy) and relative lumens, which the color team uses.

Document everything in `docs/FIXTURE_SCHEMA.md`. Land it in your **first** milestone and
message the orchestrator when it's on main.

### 2. Curated Aputure/amaran pack

- Cover every fixture in `aputure_profiles.md`, with every mode.
- Use exact channel maps and value mappings: CCT ranges, G/M neutral at 128, CCT↔RGB crossfade
  (0 = CCT, 255 = RGB), strobe "off" ranges.
- Mark effect channels as "advanced".
- Include setup guides from §2.2 and the other sections.
- The amaran PT1c/PT2c/PT4c **"LE CCT&RGB 2/4/8/16 px"** modes (14/28/56/112 ch) must be
  perfect. Mark "CCT&RGB 8 px" as recommended for multi-tube rigs.

### 3. Film/TV pack

Use official DMX charts and be honest about the verification level. Brands:
- **Nanlite:** PavoTube II (6C/15C/30C/60C, X variants), PavoSlim, Forza 60C/150B, FS series
- **Godox:** TL30/TL60, SL/SZ series, KNOWLED MG/F
- **Astera:** Titan, Helios, Hyperion, AX1, PixelBrick
- **Litepanels:** Gemini, Astra
- **ARRI:** SkyPanel S30/S60/S120/S360 (main modes), Orbiter (main modes)
- **Kino Flo:** FreeStyle, Celeb, Diva-Lite LED, Select
- **Quasar Science:** Rainbow 2, Double Rainbow
- **Others:** Creamsource Vortex, Rotolight
- **Generic:** LED pars, bars, strips, fog/haze, a dimmer pack

### 4. Bundled OFL + QLC+ libraries

- **Converters** go in `tools/fixtures/` (Python, reproducible, documented).
  - Start from `/home/antigravity/fixture-sources/convert_ofl.py` and its `prism-out/`.
  - OFL clone: `/home/antigravity/fixture-sources/ofl`. Fetch QLC+ fixtures the same way.
- **Output:**
  - `Resources/FixtureLibrary/{curated,ofl,qlcplus}/…`
  - A compact `index.json` (id, brand, model, aliases, category, a short modes summary, file).
- **Loading:** the app loads only the index at launch and full definitions lazily.
- **Deduplication:** curated > OFL > QLC+.
- **Size:** keep the repo reasonable (target < 30 MB; minify; one file per brand is fine).
- **Licenses:** OFL (MIT) and QLC+ (Apache-2.0) go in `docs/THIRD_PARTY.md`. Also send the
  About-box credit text to the orchestrator.

### 5. Search

- Fuzzy, typo-tolerant and alias-aware: "pt4c", "amaran pt 4", "pavo tube", "skypanel",
  "rgb par".
- Ranking: curated first, then popularity.
- Category filters and "recently used".
- Under 30 ms on 10k entries.
- Fix the O(n²) "covered" check in `FixtureLibrary`.
- `LibraryStore` exposes async search for the Add Light wizard (patch team).

### 6. User profiles

- User-created or edited definitions are saved in Application Support.
- They are embedded in project files that use them (verify this works).
- Importer APIs for `.prismfixture`, OFL JSON and QLC+ `.qxf`. The patch team builds the
  drag-and-drop UI.

### 7. DemoRig

- Switch the tubes to the curated amaran PT4c "LE CCT&RGB 8 px" profile
  (8 × 56 ch + panel + dimmer still fits one universe).
- Switch the panel to the most likely Aputure/amaran panel profile (see §13).
- Keep `DemoRig.IDs`, names and labels stable, because other teams' tests use them.
- `Model/DemoRig.swift` belongs to the engine team: make this a small additive edit and mention
  it in your report.

## Acceptance

- A Linux test iterates the **whole** library. Every definition must:
  - decode and validate (no overlapping channels, footprint = channel count);
  - render a frame in every mode through `EngineCore.renderFrame`.
- PT4c golden tests check channel order, footprint and DMX values for "3200 K warm white 50%",
  "pure red" and "teal" (agree on the values with the color team).
- The `library.loaded` self-test reports thousands of definitions, and loading adds less than
  300 ms to launch.
- Search finds: "amaran pt4c", "PT4c", "pavotube", "skypanel", "Chauvet SlimPAR",
  "generic dimmer".
