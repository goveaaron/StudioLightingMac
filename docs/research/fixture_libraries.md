# Fixture libraries for Prism: sources, licensing, and a normalized schema

*Research date: 2026-11-06. Data snapshots: OFL commit `82ef706d` (schema 12.6.0), QLC+ commit `87b988ac`.*
*Working copies and scripts are outside the repo in `/home/antigravity/fixture-sources/`. See §10.*

---

## 0. Summary and recommendation

| Source | License / terms | Can Prism bundle it? | Size | Film/TV coverage (Aputure, amaran, Nanlite, Godox, …) |
|---|---|---|---|---|
| **Open Fixture Library (OFL)** | **MIT** (all data and code) | **Yes.** Ship `LICENSE-OFL.txt` and keep author credit | 653 fixtures, 138 brands, 2,904 modes | Aputure 7, ARRI 8, Astera 5, Kino Flo 3, LiteGear 13, Lupo 10, Hive 7, DMG 3, Kelvin, Fiilex, etc. **No amaran, Nanlite, Godox, Litepanels, Quasar or Creamsource** |
| **QLC+ fixture library** | **Apache-2.0** (whole repo, `COPYING`) | **Yes.** Ship the license text, keep attribution, say we modified it | 1,781 fixtures, 147 brands, 5,234 modes | Astera 3 only. **No Aputure, amaran, Nanlite, Godox, ARRI, Litepanels, Quasar, Kino Flo or Creamsource** |
| **GDTF Share** (DIN SPEC 15800) | Free account required. Rights stay with each file's owner. No blanket redistribution licence | **No bundling.** Allowed route: the user signs in and downloads in the app (official REST API), or imports a local `.gdtf` file | Thousands of files, many authored by manufacturers | Manufacturer files exist for several film brands. Aputure's Sidus Link Pro imports GDTF |
| **Carallon Fixture Database** | Commercial subscription for control-product makers | Yes, if we pay for a licence | 40,000+ personalities | Broad |
| **Capture**, **Lightkey**, Avolites, MA, ETC libraries | Proprietary | **No** | — | — |
| **Manufacturer DMX charts (PDF)** | Copyrighted documents, but the DMX facts in them are not | **Yes, if we write our own definitions from the facts** without copying the documents | Per model | **The only practical route today for amaran, Nanlite, Godox and newer Aputure models** |

**Recommendation**

1. **Bundle OFL now.** It converts cleanly; the prototype converter turns all 653 fixtures into the proposed Prism schema in about 1.5 s with 0 errors.
2. **Add QLC+ as a second importer.** It roughly triples the fixture count: the union of the two libraries is about 2,286 fixtures, with only 148 exact overlaps. It needs extra name heuristics, and Apache-2.0 attribution must ship with it.
3. **Write a curated "Film & TV pack" in Prism JSON from manufacturer DMX charts.** Targets: Aputure (current models), amaran, Nanlite, Godox/KNOWLED, Litepanels, Quasar Science, Creamsource, and newer ARRI/Astera models. None of the open libraries covers these brands, and they are Prism's core audience.
4. **Offer a GDTF import** (local file, plus optional sign-in to GDTF Share) instead of bundling GDTF files.
5. Keep **Generic** templates (Dimmer, CCT/bi-colour, RGB, RGBW, RGBWW, RGBA, RGBAW+UV, HSI, pixel bars) as the fallback for any light not in the library.

> [!IMPORTANT]
> Decisions needed from the team are listed in §11. The main ones: add a `cob` category for point-source monolights; extend the semantic kind list; adopt the tint sign convention (−100 % = full minus green / magenta, +100 % = full plus green); keep a curated category-override file.

---

## 1. Open Fixture Library (OFL)

### 1.1 Repository and licence

- Repo: <https://github.com/OpenLightingProject/open-fixture-library>. Cloned with `git clone --depth 1`.
- Licence: MIT, `Copyright (c) 2017 Florian & Felix Edelmann`. It covers the whole repo, including `fixtures/`.
- Layout:
  - `fixtures/<manufacturer-key>/<fixture-key>.json`: one fixture per file.
  - `fixtures/manufacturers.json`: name, website, `rdmId` per manufacturer.
  - JSON Schemas in `schemas/`: `fixture.json`, `channel.json`, `capability.json`, `matrix.json`, `wheel-slot.json`, `definitions.json`, `fixture-redirect.json`, `manufacturers.json`.
  - Prose docs: `docs/fixture-format.md`, `docs/capability-types.md`.
  - The JS model in `lib/model/*.js` holds the reference semantics, e.g. matrix expansion in `Matrix.js` and `Mode.js`, and resolution scaling in `lib/scale-dmx-values.js`.
- Snapshot: **653 fixtures + 13 redirects**, 138 manufacturers, about 7.5 MB of raw JSON.

### 1.2 Fixture file: top level

| Field | Req. | Notes |
|---|---|---|
| `$schema` | ✓ | URL of the schema version (12.6.0 here) |
| `name` | ✓ | Model name, unique per manufacturer. The manufacturer comes from the directory name |
| `shortName` | | Must be unique across the whole library |
| `categories` | ✓ | Ordered; **the first entry is the most important** (enum in §1.3) |
| `meta` | ✓ | `authors[]`, `createDate`, `lastModifyDate`, optional `importPlugin {plugin, date, comment}` |
| `comment`, `helpWanted` | | Free text; `helpWanted` marks unverified data |
| `links` | | `manual`, `productPage`, `video`, `other` (arrays of URLs) |
| `rdm` | | `modelId`, `softwareVersion`. The RDM manufacturer ID is in `manufacturers.json` |
| `physical` | | See §1.4 |
| `matrix` | | Pixel layout (§1.8). Requires `templateChannels` |
| `wheels` | | Colour, gobo and prism wheels (§1.7) |
| `availableChannels` | ✓* | Map of channel key → channel (§1.5) |
| `templateChannels` | ✓* | Map of template key containing `$pixelKey` → channel (§1.8). *At least one of the two channel maps is required |
| `modes` | ✓ | Ordered list of DMX personalities (§1.9) |

Redirect files (`{name, redirectTo, reason}`) record a fixture that was renamed (`FixtureRenamed`, 10) or a rebrand of another fixture (`SameAsDifferentBrand`, 3). Prism keeps these as **alias rows** in the index.

### 1.3 Categories (17)

`Barrel Scanner, Blinder, Color Changer, Dimmer, Effect, Fan, Flower, Hazer, Laser, Matrix, Moving Head, Pixel Bar, Scanner, Smoke, Stand, Strobe, Other`

The list is ordered and the first entry is the primary category. OFL categories describe **function**, not **form factor**. OFL has no tube, panel, fresnel or COB category, so Prism has to work out its form-factor category (§4.2, §6.7).

### 1.4 Physical

| Property | Notes |
|---|---|
| `dimensions` | `[width, height, depth]` in mm |
| `weight`, `power` | kg; W |
| `DMXconnector` | `3-pin`, `5-pin`, `3-pin and 5-pin`, `RJ45`, … |
| `powerConnectors` | Map of connector name to `input only`, `output only` or `input and output` |
| `bulb` | `type` (e.g. `LED`), `colorTemperature` (K), `lumens` |
| `lens` | `name`, `degreesMinMax` `[min, max]` beam angle |
| `matrixPixels` | `dimensions` `[w, h, d]` mm, `spacing` `[x, y, z]` mm |

A mode may have its own `physical`, which overrides the fixture-level values. `bulb`, `lens` and `matrixPixels` are merged key by key.

### 1.5 Channels

| Property | Notes |
|---|---|
| `name` | Defaults to the channel key |
| `fineChannelAliases` | e.g. `["Dimmer fine"]` gives 16-bit; two aliases give 24-bit. Aliases are separate keys that modes can reference |
| `dmxValueResolution` | `8bit`, `16bit` or `24bit`. The resolution the capability `dmxRange` values are written in. Defaults to the highest the channel supports |
| `defaultValue` | DMX value (int at that resolution) or `"x%"`. Required on channels that switch other channels |
| `highlightValue` | Value used for "highlight / locate" |
| `constant` | Channel should hold one value (e.g. a fixed "mode" channel) |
| `precedence` | `LTP` or `HTP` |
| `capability` / `capabilities` | Exactly one of the two. `capability` covers the whole range with no `dmxRange`. `capabilities` is a list of at least 2 entries with `dmxRange [start, end]` that must cover the full range without gaps |

**Switching channels.** On a trigger channel, every capability can carry `switchChannels: {aliasKey: targetChannelKey or null}`. A mode references `aliasKey`. What that DMX slot means depends on the trigger channel's current value. The default case comes from the trigger's `defaultValue`. Used by 170 trigger channels in 142 fixtures.

**Resolution scaling** (`lib/scale-dmx-values.js`). If a mode uses fewer bytes than the values were written in, drop the low bytes. If it uses more, repeat the last byte, e.g. 8-bit `0xAB` becomes 16-bit `0xABAB`.

### 1.6 Capabilities

Common properties:
- `dmxRange`
- `comment`, `helpWanted`
- `menuClick` (`start`, `center`, `end`, `hidden`): the value a UI sends when the range is clicked
- `switchChannels`

A capability is either **stepped**, with one value such as `speed`, or **proportional**, with `xStart`/`xEnd` pairs such as `speedStart`/`speedEnd`, interpolated linearly across `dmxRange`.

**43 capability types** and their type-specific properties (req = required, opt = optional). Usage counts are from the snapshot; template channels are counted once.

| Type | Type-specific properties | Capabilities / fixtures using it |
|---|---|---|
| `NoFunction` | none | 2,303 / 520 |
| `ShutterStrobe` | `shutterEffect` (req): `Open, Closed, Strobe, Pulse, RampUp, RampDown, RampUpDown, Lightning, Spikes, Burst`; `soundControlled`, `speed`, `duration`, `randomTiming` | 2,653 / 524 |
| `StrobeSpeed` / `StrobeDuration` | `speed` / `duration` (global; does not start the strobe itself) | 23 / 14, 30 / 23 |
| `Intensity` | `brightness` (default `off`→`bright`) | 683 / 572 |
| `ColorIntensity` | `color` (req, one of 13: `Red, Green, Blue, Cyan, Magenta, Yellow, Amber, White, Warm White, Cold White, UV, Lime, Indigo`); `brightness` | 1,973 / 434 |
| `ColorPreset` | `colors` (hex list, one per beam), or `colorsStart`/`colorsEnd`; `colorTemperature` | 8,077 / 286 |
| `ColorTemperature` | `colorTemperature` (req): K, %, or keywords `warm`/`CTO`, `default`, `cold`/`CTB` | 388 / 144 |
| `Pan`, `Tilt` | `angle` (deg or %) | 176 / 175, 190 / 184 |
| `PanContinuous`, `TiltContinuous` | `speed` (rotation speed) | 24 / 8, 20 / 7 |
| `PanTiltSpeed` | `speed` **or** `duration` | 335 / 144 |
| `WheelSlot` | `wheel` (defaults to the channel name), `slotNumber` (1-based; fractional = between slots) | 3,378 / 109 |
| `WheelShake` | `isShaking` (`wheel` or `slot`), `wheel`, `slotNumber`, `shakeSpeed`, `shakeAngle` | 882 / 82 |
| `WheelSlotRotation` | `wheel`, `slotNumber`, `speed` **or** `angle` | 288 / 58 |
| `WheelRotation` | `wheel` (or a list), `speed` **or** `angle` | 563 / 104 |
| `Effect` | `effectName` (free text) **or** `effectPreset` (`ColorJump`, `ColorFade`); `speed`, `duration`, `parameter`, `soundControlled`, `soundSensitivity` | 7,217 / 444 |
| `EffectSpeed`, `EffectDuration`, `EffectParameter` | `speed`, `duration`, `parameter` | 400 / 291, 84 / 27, 106 / 27 |
| `SoundSensitivity` | `soundSensitivity` (%) | 119 / 84 |
| `BeamAngle`, `Zoom` | `angle` (beam angle, deg or `closed/narrow/wide`) | 10 / 5, 103 / 92 |
| `BeamPosition` | `horizontalAngle` and/or `verticalAngle` | 36 / 11 |
| `Focus` | `distance` (m or `near/far`) | 107 / 59 |
| `Iris`, `IrisEffect` | `openPercent`; `effectName`, `speed` | 42 / 19, 60 / 14 |
| `Frost`, `FrostEffect` | `frostIntensity`; `effectName`, `speed` | 64 / 36, 31 / 7 |
| `Prism`, `PrismRotation` | `speed` or `angle` (`Prism` switches the prism in; `PrismRotation` does not) | 206 / 54, 195 / 38 |
| `BladeInsertion`, `BladeRotation`, `BladeSystemRotation` | `blade` (`Top/Right/Bottom/Left` or a number), `insertion`, `angle` | 40 / 8, 29 / 4, 19 / 7 |
| `Fog`, `FogOutput`, `FogType` | `fogType` (`Fog`/`Haze`), `fogOutput` | 43 / 30, 20 / 7, 2 / 1 |
| `Rotation` | `speed` or `angle` | 272 / 59 |
| `Speed`, `Time` | `speed`, `time` | 105 / 43, 471 / 26 |
| `Maintenance` | `parameter`, `hold` (how long to hold, e.g. reset) | 3,244 / 298 |
| `Generic` | none | 1,146 / 105 |

**Entities and units.** Every physical property is an "entity": a number with a unit, or a keyword. Keywords map to percent.

| Entity | Units | Keywords |
|---|---|---|
| Speed | `Hz`, `bpm`, `%` | `fast`=100, `slow`=1, `stop`=0, `slow reverse`=−1, `fast reverse`=−100 |
| RotationSpeed | `Hz`, `rpm`, `%` | `fast CW`, `slow CW`, `stop`, `slow CCW`, `fast CCW` |
| Time | `s`, `ms`, `%` | `instant`, `short`, `long` |
| Distance | `m`, `%` | `near`, `far` |
| Brightness | `lm`, `%` | `off`, `dark`, `bright` |
| ColorTemperature | `K`, `%` | `warm`/`CTO`=−100 %, `default`=0, `cold`/`CTB`=+100 % |
| FogOutput | `m^3/min`, `%` | `off`, `weak`, `strong` |
| RotationAngle | `deg`, `%` | |
| BeamAngle | `deg`, `%` | `closed`, `narrow`, `wide` |
| Horizontal / VerticalAngle | `deg`, `%` | `left`/`center`/`right`, `top`/`center`/`bottom` |
| SwingAngle | `deg`, `%` | `closed`, `narrow`, `wide` |
| Parameter | number | `off`, `low`, `high`, `slow`, `fast`, `small`, `big`, `instant`, `short`, `long` |
| Percent / Insertion / IrisPercent | `%` | `off`/`low`/`high`; `out`/`in`; `closed`/`open` |
| SlotNumber | number | |

> [!WARNING]
> **OFL has no native types for hue, saturation, tint (green–magenta), CCT↔RGB crossfade, or CIE x/y.** Authors encode them as `Generic`, sometimes as `Intensity` or `Maintenance`, and put the meaning in the channel name and `comment`.
>
> In the snapshot: hue 66 channels, saturation 63, tint 52, crossfade 30, CIE x/y 4+4. All are recovered by **channel-name heuristics** (§6.3).
>
> These are exactly the controls film lights rely on (SkyPanel, Nova, Celeb, Kelvin Epos), so Prism needs them as first-class kinds.

### 1.7 Wheels

`wheels: {"Color Wheel": {direction?, slots: [...]}}`.

Slot types:
- `Open`, `Closed`
- `Color` (`name`, `colors[]`, `colorTemperature`)
- `Gobo` (`resource`, `name`)
- `Prism` (`name`, `facets`)
- `Iris`, `Frost`
- `AnimationGoboStart` / `AnimationGoboEnd`

`WheelSlot` capabilities point at slots by 1-based `slotNumber`. 109 fixtures (16.7 %) have wheels, almost all moving heads.

### 1.8 Matrix, template channels and `$pixelKey` expansion

- **`matrix.pixelCount: [x, y, z]`** produces default pixel keys:
  - 1-D: `"1"`, `"2"`, …
  - 2-D: `"(x, y)"`
  - 3-D: `"(x, y, z)"`
- **`matrix.pixelKeys: [z][y][x]`** gives explicit names, with `null` for holes. Used for odd layouts, e.g. a ring or a bar with a centre head.
- **`matrix.pixelGroups`**: `{groupKey: "all" | [pixelKeys] | {x:[…], y:[…], z:[…], name:[regex]}}`.
  - Constraints: `<=n`, `>=n`, `=n`, `kn`, `kn+r`, `even`, `odd`.
  - Groups are used for "zones", e.g. Astera Titan `1/4 … 4/4`, or a `Master` group = all pixels.
- **`templateChannels`**: keys and contents contain `$pixelKey`, e.g. `"Red $pixelKey"`. Each template is instantiated for **every pixel key and every group key** by plain text substitution, including inside `fineChannelAliases` and `switchChannels`. An `availableChannels` entry whose key equals a resolved template key overrides the template.
- In a mode, the channel list may contain an **insert block**:

  ```json
  {"insert": "matrixChannels",
   "repeatFor": "eachPixelABC",
   "channelOrder": "perPixel",
   "templateChannels": ["Red $pixelKey", "Green $pixelKey", "Blue $pixelKey", null]}
  ```

  - `repeatFor` options:
    - `eachPixelABC`: natural sort of the keys.
    - `eachPixelXYZ`, `eachPixelXZY`, `eachPixelYXZ`, `eachPixelYZX`, `eachPixelZXY`, `eachPixelZYX`: the first letter is the fastest-changing axis.
    - `eachPixelGroup`.
    - An explicit list of pixel or group keys.
  - `channelOrder` options: `perPixel` (R1 G1 B1 R2 G2 B2 …) or `perChannel` (R1 R2 … G1 G2 …).
  - `null` marks an unused slot, e.g. Astera "RGB.RGB." modes.
- **Snapshot statistics:**
  - **119 fixtures (18.2 %)** have a matrix: 62 use `pixelKeys`, 57 use `pixelCount`; 95 have `pixelGroups`.
  - Pixel counts run from 2 to 96, median 8. Buckets: 2–8 = 64, 9–16 = 30, 17–64 = 23, >64 = 2 (TMB Solaris Flare 96).
  - `repeatFor` usage: explicit list 505, `eachPixelABC` 194, `eachPixelXYZ` 37, `eachPixelGroup` 7, `eachPixelYXZ` 1.
  - `channelOrder` is **always `perPixel`** (744 times) in practice.
- 44 older fixtures repeat channels by name (`Red 1`, `Red 2`, …) without a `matrix`. Prism treats them as single-cell fixtures unless they are curated.

### 1.9 Modes

- `{name, shortName?, rdmPersonalityIndex?, physical?, channels: [channelKey | null | insertBlock]}`.
- Mode names must not contain the word "mode"; UIs add it.
- Statistics:
  - **2,904 modes** (4.45 per fixture on average; max 181, Chroma-Q Color Force II 72).
  - Footprint: median 8, mean 14.4, max 256. 257 modes are over 32 channels; 38 are over 100.
  - 58 modes carry an RDM personality index.

### 1.10 Channel-level feature usage

7,112 channel definitions, including templates:

| Feature | Channels | Fixtures |
|---|---|---|
| `fineChannelAliases` (16-bit / 24-bit) | 1,087 / 41 | 255 |
| `defaultValue` | 2,588 | 431 |
| `highlightValue` | 252 | 84 |
| `switchChannels` (trigger channels) | 170 | 142 |
| `dmxValueResolution` | 154 | 73 |
| `precedence` | 83 | 14 |
| `constant` | 6 | 4 |
| single `capability` (no ranges) | 4,297 | — |
| capability `helpWanted` | — | 224 (fixture-level `helpWanted`: 18) |

### 1.11 Statistics

**Categories** (primary = listed first):

| OFL category | primary | any position |
|---|---|---|
| Color Changer | 205 | 517 |
| Moving Head | 148 | 157 |
| Dimmer | 97 | 114 |
| Pixel Bar | 40 | 44 |
| Strobe | 18 | 66 |
| Effect | 17 | 36 |
| Laser | 17 | 24 |
| Hazer | 17 | 17 |
| Smoke | 16 | 18 |
| Scanner | 16 | 17 |
| Flower | 15 | 20 |
| Blinder | 14 | 34 |
| Other | 11 | 12 |
| Stand | 10 | 10 |
| Matrix | 6 | 12 |
| Fan | 5 | 5 |
| Barrel Scanner | 1 | 1 |

**Prism category** from the converter heuristics in §4.2:

| Prism category | Fixtures |
|---|---|
| movingHead | 186 |
| wash | 110 |
| effect | 87 |
| panel | 63 |
| par | 60 |
| bar | 49 |
| cob | 35 |
| spot | 26 |
| other | 17 |
| dimmer | 8 |
| tube | 5 |
| fresnel | 4 |
| bulb | 2 |
| strip | 1 |

How the category was decided: name rules 434, OFL category 212, fallback 7.

**Simple vs complex.** Definitions as used by the converter:
- *simple*: only intensity, colour emitters, CCT, tint, hue, saturation, CIE xy, crossfade, or unused slots.
- *complex*: any pan, tilt, gobo, prism, iris, frost, blade, zoom, focus, colour wheel or fog channel, or the fixture is a laser.
- *standard*: everything else, typically simple plus strobe, effect or macro channels.

| Level | Fixtures (by most complex mode) | Modes |
|---|---|---|
| simple | 58 (8.9 %) | 925 (31.9 %) |
| standard | 335 (51.3 %) | 1,377 (47.4 %) |
| complex | 260 (39.8 %) | 602 (20.7 %) |

- **311 fixtures (47.6 %) offer at least one *simple* mode.** These are clean dimmer, CCT, RGB(W) or pixel personalities that Prism's colour engine can drive without special handling.
- **393 fixtures (60.2 %) have no motion or optics** in any mode. 186 are moving heads or scanners.
- Simple modes by colour model:

  | Colour model | Simple modes |
  |---|---|
  | pixel (multi-cell) | 218 |
  | RGB | 176 |
  | RGB+ (RGBA/RGBWA/RGBWAUV/RGBACL…) | 129 |
  | CCT / bi-colour | 124 |
  | RGBW | 119 |
  | HSI or CIE-xy only | 86 |
  | dimmer only | 51 |
  | single colour (UV, warm white…) | 19 |
  | CMY | 3 |

- All modes by colour model: `rgb` 621, `rgbw` 545, `hsi` 291, `macro` (wheel or preset only) 245, `dimmer` 214, `cct` 203, `rgba` 186, `rgbwauv` 176, `none` 106, `rgbwa` 98, `cmy` 69, `rgbuv` 24, `xy` 15.
- Mode features: `strobe` 1,662, `effect` 796, `pixels` 749, `colorMacro` 531, `cct` 346, `tint` 206, `colorWheel` 196, `crossfade` 98.
- ColorIntensity colours: Red 455, Green 446, Blue 443, White 266, Amber 123, UV 76, Cyan 44, Yellow 32, Magenta 31, Lime 22, Warm White 14, Indigo 13, Cold White 8.
- ShutterStrobe effects: Strobe 1,029, Open 813, Closed 278, Pulse 163, RampUp 141, RampDown 138, RampUpDown 33, Burst 28, Spikes 19, Lightning 11.

**Data quality and coverage:**

| Field | Share of fixtures |
|---|---|
| dimensions | 95.9 % |
| weight | 94.8 % |
| power | 94.0 % |
| DMX connector | 91.0 % |
| bulb type | 87.3 % |
| manual link | 93.6 % |
| product page | 77.5 % |
| lens / beam angle | 64.2 % |
| lumens | 22.1 % |
| native CCT | 12.9 % |
| RDM model ID | 4.9 % |
| matrix pixel size | 2.6 % |

- Provenance: hand-written or OFL editor 595; imported from QLC+ 51; GDTF 6; e:cue 1.
- `lastModifyDate`: steady activity (2018: 137, 2019: 143, 2020–2024: 51–68 per year, 2026: 91).

### 1.12 Brand coverage

**Film, TV and studio brands:**

| Brand (key) | # | Fixtures (Prism category; modes; colour models) |
|---|---|---|
| **Aputure** (`aputure`) | 7 | LS C300d (cob; 1 mode; dimmer) · LS 1200D Pro (cob; 6; dimmer) · LS 300x (cob; 1; cct) · LS 600D (cob; 3; dimmer) · LS 600D Pro (cob; 1; dimmer) · LS 600X Pro (cob; 3; cct) · Nova P300c (panel; 9 modes; cct, hsi, rgb, **xy**) |
| amaran | **0** | — |
| Nanlite / NanGuang | **0** | — |
| Godox / KNOWLED | **0** | — |
| **ARRI** (`arri`) | 8 | SkyPanel S30C/S60C/S120C/S360C (panel; 15 modes each: CCT, CCT+RGBW, CCT+HSI, RGBW, HSI in 8/16-bit, **tint, crossfade**) · L5-C/L7-C/L10-C (fresnel; 15 modes) · Broadcaster 2 Plus (cob; cct) |
| **Astera** (`astera`) | 5 | FP1 Titan (tube; 68 modes; 16 px) · FP2 Helios (tube; 68; 8 px) · FP3 Hyperion (tube; 68; 32 px) · FP5 NYX bulb (bulb; 20; 5 px) · AX3 Lightdrop (bulb; 16) |
| Litepanels | **0** | — |
| Quasar Science | **0** | — |
| **Kino Flo** (`kino-flo`) | 3 | Celeb 250 / 450 LED DMX (panel; 30 modes; cct, hsi, rgb, xy) · Celeb LED 201 DMX (panel; cct) |
| Creamsource | **0** | — |
| LiteGear | 13 | LiteMat Plus 1/2/2L/3/4/8, LiteTile Plus 4/8, S2 LiteMat 1/2/2L/3/4 (panel; cct) |
| Lupo | 10 | Actionpanel/Superpanel/Ultrapanel Dual Color and Full Color (panel; cct, hsi, rgbw) |
| Hive Lighting | 7 | Bee, Bumble Bee, Hornet, Super Hornet, Wasp (C/CX) (cob; hsi, rgb) |
| DMG Lumière | 3 | MAXI MIX, MINI MIX, SL1 MIX (cob*; cct, hsi, rgbwal) |
| Others | | Kelvin Epos 300 (rgbalc, xy, hsi) · Fiilex P3 Color · Dedolight DLED4/7-BI · ikan Stryder SFB150 · Fovitec 600XB · SWIT PL-E60D/E90D · DeSisti SoftLED 4/8 VW · Chroma-Q Color Force II 12/48/72 (bar; up to 181 modes) · Skypix Ribalta Beam |
| ETC (`etc`) | 16 | ColorSource PAR/Spot (+Deep Blue), fos/4 Panel PD/PL 8/16/24, Source Four LED Series 2/3 (Lustr, Daylight HD, Tungsten HD…), Source 4WRD Color II |

\* SL1 MIX is really a panel and MINI/MAXI MIX are soft lights. This is the kind of case the curated category override file in §4.2 exists for.

**Stage and DJ brands:**

| Brand (key) | # | Prism categories | simple / standard / complex |
|---|---|---|---|
| Chauvet DJ (`chauvet-dj`) | 29 | par 10, effect 7, bar 3, wash 3, movingHead 3, other 2, dimmer 1 | 1 / 19 / 9 |
| Chauvet Professional | 10 | wash 5, movingHead 2, bar 1, par 1, effect 1 | 0 / 2 / 8 |
| ADJ (`american-dj`) | 43 | movingHead 12, effect 10, wash 5, bar 5, spot 4, par 3, panel 2, cob 1, tube 1 | 0 / 26 / 17 |
| Elation | 20 | wash 10, movingHead 6, par 2, bar 2 | 1 / 11 / 8 |
| Martin | 24 | movingHead 19, effect 2, bar 2, par 1 | 2 / 1 / 21 |
| Cameo | 43 | movingHead 11, effect 9, wash 9, panel 7, par 2, spot 2, bar 1, cob 1, other 1 | 0 / 23 / 20 |
| Stairville | 37 | wash 9, effect 8, movingHead 7, bar 6, par 4, cob 2, panel 1 | 0 / 22 / 15 |
| Eurolite | 43 | movingHead 11, wash 8, effect 6, bar 4, spot 4, other 4, tube 3, dimmer 1, par 1, cob 1 | 2 / 27 / 14 |
| Showtec | 26 | movingHead 10, par 4, effect 3, wash 2, bar 2, spot 1, dimmer 1, cob 1, other 1, tube 1 | 2 / 12 / 12 |
| Robe / Clay Paky / GLP / Ayrton | 11 / 7 / 8 / 3 | mostly movingHead | |
| **Generic** (`generic`) | 16 | see below | 14 / 1 / 1 |

**Generic fixtures in OFL** (16): 4-Channel Dimmer Pack; Desk Channel (8/16/24-bit); CW/WW Fader; Color Temperature Fader; RGB, RGBA, RGBW, GRBW, RGBD, DRGB, DRGBW, RGBWW and RGBWAUV Faders (8/16/24-bit variants); CMY Fader; Pan/Tilt Fader; Strobe.

These make good templates for unlisted fixtures, but Prism should add its own generic set, including **HSI**, **CCT+tint**, and **N-pixel RGB/RGBW bars with configurable pixel count**.

---

## 2. QLC+ fixture library

### 2.1 Repository and licence

- <https://github.com/mcallegari/qlcplus>, folder `resources/fixtures/<Manufacturer>/<Manufacturer>-<Model>.qxf`. Sparse-cloned.
- The whole repository is **Apache License 2.0** (`COPYING`). There is no `NOTICE` file. Each fixture records its authors in `<Creator><Author>`; there are 650 distinct author strings.
- Apache-2.0 obligations when bundling converted data:
  - Include the licence text.
  - Keep attribution (author names, "QLC+ fixture library").
  - State that the files were modified (converted).
  - No trademark use.
- Index files: `FixturesMap.xml` lists all 1,781 fixtures; `scripts/fixtures-tool.py` validates them.

### 2.2 Format (`.qxf`, XML namespace `http://www.qlcplus.org/FixtureDefinition`)

```xml
<FixtureDefinition xmlns="http://www.qlcplus.org/FixtureDefinition">
 <Creator><Name>Q Light Controller Plus</Name><Version>5.2.1 GIT</Version><Author>Andreas Reich</Author></Creator>
 <Manufacturer>Astera</Manufacturer>
 <Model>AX5</Model>
 <Type>Color Changer</Type>
 <Channel Name="Intensity Red" Preset="IntensityRed"/>
 <Channel Name="Dimmer" Preset="IntensityMasterDimmer"/>
 <Channel Name="Color Temperature (CCT)">
  <Group Byte="0">Colour</Group>
  <Capability Min="0" Max="3">No effect</Capability>
  <Capability Min="4" Max="255">Color Temperature (2000..7000K)</Capability>
 </Channel>
 <Channel Name="Strobe">
  <Group Byte="0">Shutter</Group>
  <Capability Min="0" Max="3" Preset="ShutterOpen">Off</Capability>
  <Capability Min="7" Max="255" Preset="StrobeFreqRange" Res1="0.4" Res2="25">Variable Strobe (0.4Hz..25Hz)</Capability>
 </Channel>
 <Mode Name="1: RGB (Pixel=1, Strobe=Off)">
  <Channel Number="0">Intensity Red</Channel> …
  <Head><Channel>0</Channel><Channel>1</Channel><Channel>2</Channel></Head>
 </Mode>
 <Physical>
  <Bulb Type="LED" Lumens="0" ColourTemperature="0"/>
  <Dimensions Weight="0.6" Width="96" Height="96" Depth="59"/>
  <Lens Name="Other" DegreesMin="0" DegreesMax="0"/>
  <Focus Type="Fixed" PanMax="0" TiltMax="0"/>
  <Layout Width="1" Height="1"/>
  <Technical PowerConsumption="15" DmxConnector="Wireless"/>
 </Physical>
</FixtureDefinition>
```

**Elements:**
- `Channel` has `Name`, an optional `Preset`, and `Default`. Its children are:
  - `Group Byte="0|1"`. Byte 1 = fine. Group values: `Intensity, Colour, Gobo, Speed, Pan, Tilt, Shutter, Prism, Beam, Effect, Maintenance, Nothing`.
  - `Colour` (`Red`, `Green`, `Blue`, `White`, `Amber`, `UV`, …) for Intensity-group channels.
  - `Capability` with `Min`, `Max`, `Preset`, `Res`/`Res1`/`Res2` (Hz values, image files), `Color`/`Color2` and `Alias`. `Alias` means the capability switches the meaning of another channel in that mode, like OFL `switchChannels`.
- `Mode` is an ordered list of `<Channel Number>` entries, plus `<Head>` groups that define pixels/heads. A channel may carry `ActsOn` (e.g. a fine channel that acts on its coarse channel).
- **Fixture types (14):** `Color Changer, Dimmer, Effect, Fan, Flower, Hazer, Laser, LED Bar (Beams), LED Bar (Pixels), Moving Head, Other, Scanner, Smoke, Strobe`.
- **Channel presets** (engine `QLCChannel::Preset`):
  - Intensity: `IntensityMasterDimmer`, `IntensityDimmer` (+`Fine`); `IntensityRed/Green/Blue/Cyan/Magenta/Yellow/Amber/White/UV/Indigo/Lime` (+`Fine`); `IntensityHue/Saturation/Lightness/Value` (+`Fine`).
  - Position: `PositionPan/Tilt` (+`Fine`), `PositionXAxis/YAxis`.
  - Speed: `SpeedPan…/SpeedTilt…/SpeedPanTilt…` with `SlowFast`/`FastSlow` variants.
  - Colour: `ColorMacro`, `ColorWheel` (+`Fine`), `ColorRGBMixer`, `ColorCTOMixer`, `ColorCTCMixer`, `ColorCTBMixer`.
  - Gobo: `GoboWheel`/`GoboIndex` (+`Fine`).
  - Shutter and beam: `ShutterStrobeSlowFast/FastSlow`, `ShutterIrisMinToMax/MaxToMin/Fine`, `BeamFocusNearFar/FarNear/Fine`, `BeamZoomSmallBig/BigSmall/Fine`, `PrismRotationSlowFast/FastSlow`.
  - Other: `NoFunction`, `Custom`.
- **Capability presets:**
  - Shutter: `ShutterOpen/Close`.
  - Strobe family: `Strobe…`, `StrobeRandom…`, `Pulse…`, `RampUp…`, `RampDown…`, each with `SlowToFast`, `FastToSlow`, `Frequency`, `FreqRange` variants.
  - Rotation: `RotationStop/Indexed/Clockwise…/CounterClockwise…`.
  - Colour and gobo: `ColorMacro`, `ColorDoubleMacro`, `ColorWheelIndex`, `GoboMacro`, `GoboShakeMacro`, `GenericPicture`.
  - Prism and lamp: `PrismEffectOn/Off`, `LampOn/Off`.
  - Maintenance: `Reset{All,PanTilt,Pan,Tilt,Motors,Gobo,Color,CMY,CTO,Effects,Prism,Blades,Iris,Frost,Zoom}`, `SilentModeOn/Off/Automatic`.
  - Other: `Alias`, `SlowToFast/FastToSlow/NearToFar/FarToNear/BigToSmall/SmallToBig`.
- The QLC+ colour list has **no warm-white / cold-white distinction**. Hue and saturation have presets, but **tint, crossfade and CIE xy do not**.

### 2.3 Statistics

- **1,781 fixtures**, 147 manufacturer strings, **5,234 modes** (2.94 per fixture; footprint median 8, mean 13.3, max 480). Raw size 15.4 MB.
- Types:

  | Type | Fixtures |
  |---|---|
  | Color Changer | 613 |
  | Moving Head | 582 |
  | Scanner | 112 |
  | Flower | 88 |
  | LED Bar (Beams) | 73 |
  | LED Bar (Pixels) | 67 |
  | Strobe | 55 |
  | Laser | 54 |
  | Smoke | 42 |
  | Effect | 32 |
  | Dimmer | 26 |
  | Other | 20 |
  | Hazer | 16 |
  | Fan | 1 |

- Top manufacturers: Chauvet 186, American DJ 162, Eurolite 126, Stairville 102, Showtec 83, Cameo 74, Martin 73, Pro-Lights 47, Robe 47, Clay Paky 46, Varytec 46, Futurelight 40, beamZ 37, Briteq 34, GLP 24, Elation 23.
- **Channels:** 36,029. **68.1 % use a channel `Preset`**, which maps directly to a Prism kind. The rest are `Custom` with a `Group`: Effect 2,464, Colour 1,802, Shutter 1,623, Speed 1,470, Intensity 1,011, Gobo 1,007, Maintenance 944, Beam 504, Prism 421, Nothing 83, Pan 75, Tilt 74.
- **Capabilities:** 103,950; 34.1 % have a capability preset. 354 `Alias` capabilities in 63 fixtures.
- Channels named like hue 73, saturation 62, CCT 126, tint 30, crossfade 25. QLC+ needs the same name heuristics as OFL.
- **Heads/pixels:** 380 fixtures (21.3 %) define `<Head>`s, max 160 heads; 316 have a `<Layout>`.
- **Physical:** dimensions, weight and power are almost always filled in. Lens 65.7 %, colour temperature 23.8 %, lumens 35.5 %.

### 2.4 Brand coverage

**No Aputure, amaran, Nanlite/NanGuang, Godox, ARRI, Litepanels, Quasar, Kino Flo, Creamsource, LiteGear, Dedolight, Fiilex, Lupo or Chroma-Q fixtures.** Earlier grep hits were false positives such as Chauvet "Intimidator".

Film-adjacent content that does exist:
- Astera: AX3 Lightdrop, AX5, Titan Tube FP1.
- ETC: ColorSource PAR/Spot/Fresnel V/Fresnel V MAX, Desire D22/D40, Source Four LED S2 Lustr.
- Elation: TVL CYC RGBW, DW Fresnel, KL PAR FC.
- Briteq: BT-Theatre series.
- Prolights: EclFresnel, EclPar, EclCyclorama.
- Generic: RGB, RGBW, Smoke.

QLC+'s real strength is **stage and DJ breadth**: Chauvet, ADJ, Eurolite, Stairville, Showtec, Cameo, Martin, Robe and Clay Paky.

### 2.5 Overlap with OFL

Normalized "manufacturer + model" exact matches: **148**. The union is **2,286** fixture identities. 71 manufacturers are shared; 212 manufacturers are in the union. Spelling differences (e.g. "COLORado 1 Solo" vs "COLORado 1-Solo") mean the true overlap is somewhat higher, probably around 2,100–2,200 unique fixtures after fuzzy de-duplication. OFL itself imported 51 fixtures from QLC+.

**De-duplication rule:**
1. Prefer OFL. It has richer semantics: units, physical values, fine aliases, switching.
2. Keep QLC+ only if it has modes OFL lacks.
3. Record both sources in `source`.

---

## 3. GDTF Share and other sources

### 3.1 GDTF / GDTF Share

- **Format.** GDTF (General Device Type Format) is standardized as **DIN SPEC 15800:2022-02 (GDTF 1.2)**; the companion scene format MVR is DIN SPEC 15801. It is maintained by MA Lighting, Robe and Vectorworks, and the share is hosted by VPLT. Spec: <https://github.com/mvrdevelopment/spec>, <https://www.gdtf.eu/gdtf/>.
- **File content.** A `.gdtf` file is a zip containing `description.xml`, 3D models, gobo images and thumbnails.
- **Semantics are attribute-based** and *richer than OFL's* for film lights. It has native attributes for:
  - additive emitters: `ColorAdd_R/G/B/W/WW/CW/RY/GY/UV/…`
  - subtractive filters: `ColorSub_C/M/Y`
  - colour temperature: `CTC`, `CTO`, `CTB`
  - `Tint`
  - `HSB_Hue/Saturation/Brightness`
  - `CIE_X/CIE_Y/CIE_Brightness`
  - colour-mix modes, `Shutter1Strobe…`, `Fan`, `Control1`, and more.

  The mapping to Prism kinds is almost one-to-one (§6.8).
- **Licensing and terms.** The GDTF Share requires a free account. Its Terms of Use say that "title and intellectual property rights in and to any content … belongs to the respective content owner", and they prohibit copying or creating derivative works except as expressly permitted. There is **no blanket licence to redistribute files** in a product. → **Prism must not bundle GDTF Share files.**
- **Sanctioned integration.** The official **GDTF Share REST API** (<https://www.gdtf.eu/gdtf/share_api/share-api/>):
  - `login.php`, `getList.php` (rid, manufacturer, fixture, revision, uploader `Manuf.`/`User`, rating, modes with footprints), `downloadFile.php?rid=`.
  - Each **end user needs their own account**. The docs say to direct customers to create one.
  - Precedents: grandMA3, ChamSys, ETC Eos and Aputure's Sidus Link Pro import GDTF files; LightBuddy downloads them in the app.
- **Feasibility for Prism:**
  - (a) A local `.gdtf` import, mapped to Prism JSON on the user's machine.
  - (b) An optional "Sign in to GDTF Share" browser that downloads and converts on demand.
  - OFL's own GDTF import plugin (v0.2.2) is a reference implementation.
  - Prefer files whose uploader is `Manuf.` (manufacturer-authored).

### 3.2 Carallon

Carallon licenses its **Fixture Database** (40,000+ personalities, standardized fixture model, gobo and colour swatch catalogues) to control-product makers on **paid subscriptions**, including writing personalities on request (<https://www.carallon.com/fixture-database/>).

This is the only realistic way to get near-complete coverage quickly. It costs money, needs a contract, and the data cannot be shared outside Prism. It is a business decision.

### 3.3 Capture, Lightkey and other proprietary libraries

- **Capture** (visualizer). Its library ships inside the product and is maintained by Capture (`library@capture.se`). It is proprietary, not redistributable, and has no open export.
- **Lightkey** (macOS). Its library and profile format (`.lightkeyfxt`, binary per OFL issue #526) are proprietary. Lightkey can import some formats, but its library is closed. Not usable.
- **Avolites** (`.d4` personalities), **MA** fixture share, **ETC Eos** library, **HitLight** (10,000+), **Sidus Link** profiles: all proprietary or app-specific. Do not bundle. They are fine for manual cross-checking of facts.

### 3.4 Manufacturer DMX charts: how to cover Aputure, amaran, Nanlite and Godox

- **Aputure / amaran** publish a per-model "DMX Profile Specification" PDF. Example: *LS 600c Pro & LS 600c Pro II DMX Profile Specification V1.6*, on docs.aputure.com and help.amarancreators.com.
  - Aputure also publishes console profile bundles (ETC Eos `.esf3d`/`.esf2`, Hog4, grandMA) at <https://help.aputure.com/en/lighting-console-profiles-download>.
  - Those bundles are vendor formats with no redistribution licence. Use them for checking only.
- **Nanlite** publishes "DMX Reference Guide" PDFs per model (Forza 60C/300B/500B II/720, FC-300B, …) on cdn-aliyun.nanlite.com. Typical modes:
  - Ultimate DMX (8/16-bit), with CCT, HSI, RGBW, XY, Gel and Effect sub-modes chosen through a mode channel. This is a **switching-channel** design.
  - Separate CCT and effect personalities.
- **Godox (KNOWLED)** publishes "DMX Mode Specification" / "DMX Practical Table" documents per model (MG1200Bi, M200D/M300D, P600R Hard, MS60R, AM1600R, …) at <https://godox.com/user-guides-knowled/>.
- **Legal position.** A list of DMX channel functions and ranges is factual, functional data. Prism can write its *own* JSON definitions from these facts. It must not copy the PDFs or reproduce their text and layout. This is how OFL and QLC+ contributors work. (General guidance, not legal advice; have counsel confirm.)
- **Effort.** About 15–45 minutes per model family with a good editor, plus validation on real hardware.
  - First wave, about 60 families: Aputure (LS 60/300/600/1200 series, Nova II, INFINIBAR, MT/MC Pro, Electro Storm/STORM), amaran (100/200/300 series, Ray, PT/T tubes, F21/F22 flexibles, P60/SM5), Nanlite (Forza, FS, PavoTube II, PavoSlim, MixPanel, FC), Godox (SL, MS, ML, M-series, TL tubes, KNOWLED MG/F/P), Litepanels (Gemini, Astra), Quasar (Rainbow 2, Double Rainbow, Crossfade X), Creamsource (Vortex, Slyce), Kino Flo (FreeStyle, Diva-Lite LED, Select), Astera (Hyperion/Titan/Helios via AsteraApp modes), ARRI (Orbiter, S-series updates).

### 3.5 Other open data worth using

- **Open Lighting RDM index** (<http://rdm.openlighting.org>): manufacturer IDs, device model IDs and personalities. Use it to **match a fixture discovered over RDM to a library entry**. OFL `rdm.modelId` is only filled for 4.9 % of fixtures.
- **OFL Generic fixtures** plus Prism's own generic templates as the fallback.

---

## 4. Proposed Prism fixture schema: `prism-fixture/1`

**Design goals**
1. Semantic: every DMX slot has a **kind** the colour and FX engine understands.
2. Lossless enough to round-trip the important OFL and QLC+ semantics.
3. Fast to load: **expanded** per-mode channel lists, plus precomputed per-cell offsets.
4. Swift `Codable`-friendly.
5. Source and licence provenance on every fixture.

The prototype converter emits exactly this format (§10).

### 4.1 Top level

| Field | Type | Notes |
|---|---|---|
| `$schema` | string | `"prism-fixture/1"` |
| `id` | string | `"<manufacturerKey>/<modelKey>"`, stable |
| `manufacturer`, `manufacturerKey` | string | Display name; slug |
| `model`, `shortName?` | string | |
| `category` | enum | §4.2 |
| `categorySource` | string | Provenance of the category: `rule:name`, `rule:shape`, `ofl:<Category>`, `curated`, `fallback` |
| `tags` | [string] | Original function categories, camel-cased (`colorChanger`, `pixelBar`, `strobe`, …) |
| `physical?` | object | `dimensionsMm [w,h,d]`, `weightKg`, `powerW`, `dmxConnector`, `lightSource`, `nativeCctK` (number or `[min,max]`), `lumens`, `beamAngleDeg [min,max]`, `lens` |
| `pixels?` | object | §4.3 |
| `wheels?` | object | Same shape as OFL wheels |
| `definitions` | {key: ChannelDefinition} | Shared channel definitions (§4.4). Template channels are stored **once** under their template key, e.g. `"Red $pixelKey"` |
| `modes` | [Mode] | §4.5 |
| `source` | object | `library` (`ofl`, `qlcplus`, `gdtf`, `prism`), `license`, `path`, `commit`, `url`, `authors[]`, `lastModified`, `importedFrom?` |
| `links?`, `rdm?` | object | `rdm: {manufacturerId, modelId}` |
| `notes?` | [string] | `helpWanted`, `switchingChannels`, converter warnings |

### 4.2 Category enum

`tube, panel, spot, fresnel, par, bulb, strip, bar, wash, movingHead, dimmer, effect, other`, **plus the proposed `cob`**. A `cob` is a point-source monolight with a Bowens or other modifier mount: Aputure LS, amaran COB and 100/200/300, Nanlite Forza and FS, Godox SL/ML/MS, Hive, DMG.

These fixtures are the single most common film light. They are not pars or spots: they take softboxes, fresnels and reflectors.

**Converter heuristics**, applied in order:
1. Pan/tilt present, or OFL `Moving Head` / `Scanner` / `Barrel Scanner` → `movingHead`.
2. Smoke, hazer, fan, laser, flower, or fog channels → `effect`.
3. Name rules: tube → bulb → fresnel → panel → cob → par → strip → bar → spot → wash → dimmer. `dimmer` is used only if the OFL primary category is `Dimmer`.
4. Shape from `physical.dimensions`:
   - longest side ≥ 6× middle side, with a round-ish cross-section ≤ 70 mm → `tube`
   - longest side ≥ 4× middle side → `bar`
5. OFL primary category:
   - Pixel Bar / Stand → `bar`
   - Matrix → `panel`
   - Blinder / Color Changer → `wash`
   - Strobe / Effect → `effect`
   - Dimmer → `dimmer` if the fixture has intensity only, else `other`
6. Otherwise → `other`.

Accuracy on the film brands is good but not perfect, e.g. DMG MIX and Chroma-Q battens. **Keep a small curated `category-overrides.json`** (id → category) that the build step applies.

### 4.3 Pixels

```json
"pixels": {
  "count": 16, "grid": [16, 1, 1], "orientation": "horizontal",
  "cells": [{"key": "1", "x": 0, "y": 0, "z": 0}, {"key": "2", "x": 1, "y": 0, "z": 0}],
  "groups": {"1/4": ["1", "2", "3", "4"], "2/4": ["5", "6", "7", "8"]},
  "cellSizeMm": [64, 42, 42], "spacingMm": [0, 0, 0]
}
```

- `orientation` is one of `horizontal`, `vertical`, `grid`, `3d`, `custom`. `custom` means there are holes, from `pixelKeys`.
- Positions are 0-based.
- `groups` excludes "all pixels" groups. Channels addressed to an all-pixels group become `scope: "master"`.
- QLC+ `<Head>` and `<Layout Width/Height>` map to `cells` in row-major order.

### 4.4 ChannelDefinition and Capability

```json
"Green-Magenta Point 8bit": {
  "kind": "tint", "name": "Green-Magenta Point", "kindFrom": "name",
  "res": 8, "default": 0,
  "range": {"from": -100, "to": 100, "unit": "%"},
  "capabilities": [
    {"dmx": [0, 10],    "kind": "tint", "value": 0,    "unit": "%", "label": "Neutral"},
    {"dmx": [11, 20],   "kind": "tint", "value": -100, "unit": "%", "label": "Full minus green"},
    {"dmx": [21, 119],  "kind": "tint", "from": -99, "to": -1, "unit": "%"},
    {"dmx": [120, 145], "kind": "tint", "value": 0,    "unit": "%", "label": "Neutral"},
    {"dmx": [146, 244], "kind": "tint", "from": 1,   "to": 99, "unit": "%"},
    {"dmx": [245, 255], "kind": "tint", "value": 100,  "unit": "%", "label": "Full plus green"}
  ]
}
```

| Field | Notes |
|---|---|
| `kind` | Semantic kind (§4.6) |
| `name` | Display name, with `$pixelKey` removed |
| `kindFrom` | `"name"` when the kind came from channel-name heuristics rather than a typed source. Useful for QA |
| `res` | Bit depth the `dmx` numbers are written in: 8, 16 or 24 |
| `default` | DMX home value, at `res`. From the source if given; otherwise derived (§5.1) |
| `highlight?`, `precedence?` (`HTP`/`LTP`), `constant?` | |
| `range?` | `{from, to, unit}`: overall physical span, oriented in DMX order. A shortcut for the colour engine |
| `capabilities?` | Omitted when the channel is a plain 0–100 % fader over the full range |
| `helpWanted?` | |

**Capability fields:**
- `dmx [a, b]` (inclusive, at `res`) and `kind`. `kind` is a channel kind, or `none`, `open` or `closed`.
- A value: either `value` (stepped) or `from`/`to` (linear across `[a, b]`), with `unit` ∈ `% K deg Hz bpm rpm s ms m lm m3/min xy`.
- Optional:
  - `label`
  - `colors[]` / `colorsTo[]` (hex)
  - `slot` (wheel slot number or `[from, to]`)
  - `pattern` (`pulse`, `rampUp`, `rampDown`, `rampUpDown`, `lightning`, `spikes`, `burst`)
  - `random`, `sound`, `continuous`, `hold {value, unit}`, `blade`, `menuClick`
  - `assumed: true`: the converter inferred the physical range, e.g. hue 0–360°
  - `helpWanted`

### 4.5 Mode and channel entries

```json
{
  "key": "P03", "name": "P03: CCT & HSI 8bit", "footprint": 10,
  "colorModel": "hsi", "features": ["cct", "tint", "crossfade", "colorMacro", "strobe"],
  "complexity": "standard",
  "channels": [
    {"kind": "intensity",  "def": "Dimmer"},
    {"kind": "cct",        "def": "Color Temperature"},
    {"kind": "tint",       "def": "Green-Magenta Point 8bit"},
    {"kind": "crossfade",  "def": "Cross Fade to Color"},
    {"kind": "hue",        "def": "Hue"},
    {"kind": "saturation", "def": "Saturation"},
    {"kind": "fan",        "def": "Fan Control"},
    {"kind": "colorMacro", "def": "Presets"},
    {"kind": "strobe",     "def": "Strobe"},
    {"kind": "none",       "def": "Reserved for future use"}
  ]
}
```

Channel entries, by **position** (offset = array index, 0-based):

| Entry | Meaning |
|---|---|
| `{kind, def, fine: [o1, o2?]}` | Coarse byte; `fine` lists offsets of the 2nd (and 3rd) byte in this mode |
| `{kind: "<base>Fine", def, coarse: o, byte?: 2}` | Fine byte of the coarse channel at offset `o`. `byte` is set only when it is the 3rd byte of 24-bit |
| `{kind: "none"}` | Unused slot (OFL `null`) |
| `cell: "<pixelKey or groupKey>"` | The channel belongs to one cell or group |
| `scope: "master"` | Fixture-wide channel inside a pixel fixture |
| `switch: {trigger: o, cases: [{when: [a,b], def, byte?}]}` | Switching slot: its meaning depends on the DMX value of the trigger slot. `kind`/`def` describe the default case. Adjacent identical cases are merged |

Per-mode `cells` holds precomputed lookups so the engine never scans the channel list. Example: `{"key": "1", "offsets": {"red": 0, "green": 1, "blue": 2}}`. Repeated kinds in a cell become a list of offsets; group cells add `pixels: [...]`.

**Example: pixel tube** (Astera FP1 Titan, mode `41: RGB.RGB. 16pix`, footprint 63, abridged):

```json
"channels": [
  {"kind": "red", "def": "Red $pixelKey", "cell": "1"},
  {"kind": "green", "def": "Green $pixelKey", "cell": "1"},
  {"kind": "blue", "def": "Blue $pixelKey", "cell": "1"},
  {"kind": "none"},
  {"kind": "red", "def": "Red $pixelKey", "cell": "2"}
],
"cells": [
  {"key": "1", "offsets": {"red": 0, "green": 1, "blue": 2}},
  {"key": "2", "offsets": {"red": 4, "green": 5, "blue": 6}}
]
```

**Example: switching slot** (Eurolite LED KLS-801, "15-channel"). Slot 3 is "Red 1" while channel 0 is 0–9, and "Running Speed" when channel 0 is 10–255:

```json
{"kind": "red", "def": "Red $pixelKey", "cell": "1",
 "switch": {"trigger": 0, "cases": [{"when": [0, 9], "def": "Red $pixelKey"},
                                    {"when": [10, 255], "def": "Running Speed"}]}}
```

**Derived mode fields:**
- **`colorModel`**:
  - `rgb` followed by any of `w ww cw a l c m y uv i`, in that order (e.g. `rgbw`, `rgbwauv`, `rgbalci`)
  - `cmy` (subtractive: C+M+Y without RGB)
  - `hsi`, `xy`, `cct` (CCT channel, or warm+cool white only)
  - `single:<colors>`, `macro` (wheel or presets only), `dimmer`, `none`
- **`features`**: `cct`, `tint`, `crossfade`, `colorMacro`, `colorWheel`, `strobe`, `effect`, `hsi`, `xy`, `pixels`.
- **`complexity`**: `simple`, `standard` or `complex` (§1.11).

### 4.6 Semantic kind vocabulary

| Group | Kinds | Unit / typical range | Default (home) |
|---|---|---|---|
| Intensity | `intensity` | % (0–100), lm | 0 |
| Additive emitters | `red green blue white warmWhite coolWhite amber lime cyan magenta yellow uv indigo` | % | 0 |
| White point | `cct` | K, e.g. 2700–10000. Keyword % −100 = warm/CTO … +100 = cold/CTB | source default, else DMX 0 |
| | `tint` | % −100 (full minus green = magenta) … 0 neutral … +100 (full plus green) | **neutral band** |
| | `crossfade` | % 0 = white/CCT engine … 100 = colour engine (ARRI "Cross Fade to Color", "CCT ↔ RGB") | 0 |
| Colour spaces | `hue` | deg 0–360 | 0 |
| | `saturation` | % 0–100 | 0 |
| | `cieX`, `cieY` | `xy` (CIE 1931, typically 0–0.8) | 0 |
| Selection | `colorMacro` | presets, gels (`colors[]`, `label`) | "off" / no function |
| | `colorWheel` | slots | open |
| Shutter | `strobe` | Hz, % (+ `pattern`, `random`, `sound`) | open / off |
| | `shutter` | open / closed | open |
| Effects | `effect`, `effectSpeed` | names; speed % / Hz / s | off / stop |
| Motion | `pan`, `tilt` | deg, % | centre |
| | `panTiltSpeed` | %, s | 0 |
| Beam | `zoom` | beam deg | 0 / source |
| | `focus` | m, % | 0 / source |
| | `iris` | % open | open |
| | `frost` | % | 0 |
| | `gobo`, `goboRotation` | slots; rpm / deg | open / stop |
| | `prism`, `prismRotation` | slots; rpm / deg | out / stop |
| | `blade` | % insertion, deg | 0 |
| Other | `fan` (fan mode), `fog` (output), `rotation` (generic motor), `speed` (generic speed/time) | | off / auto |
| | `control` (reset, lamp, curves, modes; **never sent automatically**) | `hold` | safe value |
| | `generic` (unknown), `none` (unused/reserved) | | 0 |
| Fine bytes | `<kind>Fine` for any continuous kind: `intensityFine`, `redFine`…, `cctFine`, `tintFine`, `hueFine`, `panFine`, `tiltFine`, `zoomFine`, … | | follows coarse |
| Capability-only | `open`, `closed`, `none` | | |

**Additions to the original list:** `colorWheel`, `goboRotation`, `prismRotation`, `iris`, `frost`, `blade`, `panTiltSpeed`, `fog`, `rotation`, `speed`, `none`. Without these, moving heads, fog machines and unused slots cannot be represented without losing information.

### 4.7 Value semantics (engine contract)

- **Forward (physical → DMX):**
  1. Choose the capability of the requested kind and unit whose `[from, to]` contains *v*. If several contain it, e.g. ARRI tint "Neutral" appears twice, prefer the widest proportional one; otherwise take the nearest.
  2. Interpolate: \(\text{dmx} = a + \frac{v - from}{to - from}(b - a)\), then round.
  3. Scale from `res` to the number of bytes the mode actually uses (OFL rules: drop low bytes, or repeat the last byte).
  4. Split into coarse and fine bytes: big-endian, coarse first.
- **Plain faders** (no `capabilities`): \(\text{dmx} = \text{round}(\frac{v}{100}(256^{n}-1))\), where *n* is the byte count in this mode.
- **Inverse (DMX → physical)** for display: find the capability containing the value, then interpolate. Stepped capabilities return `value` or `label`.
- **Partial-range intensity:** e.g. "Dimmer" at 0–200 plus "Strobe" at 201–255 on one channel. The kind is `intensity` because intensity covers more of the range. The engine maps 0–100 % onto the **intensity capability's DMX sub-range only**.
- **Switching:** when the trigger value changes, re-resolve the slot through `switch.cases`. Effects and UI must treat the slot as the current case's kind.

### 4.8 Swift sketch

```swift
struct PrismFixture: Codable {
  let id, manufacturer, manufacturerKey, model: String
  let shortName: String?
  let category: Category          // enum incl. .cob
  let tags: [String]
  let physical: Physical?
  let pixels: Pixels?
  let definitions: [String: ChannelDefinition]
  let modes: [Mode]
  let source: Source
}
struct ChannelDefinition: Codable {
  let kind: Kind; let name: String; let res: Int; let `default`: Int
  let highlight: Int?; let range: PhysRange?; let capabilities: [Capability]?
}
struct Capability: Codable {
  let dmx: [Int]; let kind: Kind; let value: Double?; let from: Double?; let to: Double?
  let unit: String?; let label: String?; let colors: [String]?; let pattern: String?
}
struct Mode: Codable {
  let key, name: String; let footprint: Int; let colorModel: String
  let features: [String]?; let complexity: String
  let channels: [ChannelEntry]; let cells: [Cell]?
}
struct ChannelEntry: Codable {
  let kind: String; let def: String?; let fine: [Int]?; let coarse: Int?; let byte: Int?
  let cell: String?; let scope: String?; let `switch`: Switch?
}
```

### 4.9 Search index row

```json
{"id": "arri/skypanel-s60c", "mfr": "arri", "model": "Skypanel S60C", "cat": "panel",
 "tags": ["dimmer", "colorChanger", "strobe"],
 "modes": [["P01", 12, "rgbw"], ["P02", 7, "cct"], ["P03", 10, "hsi"]],
 "px": 0, "cx": 1}
```

- `cx` is the fixture's most complex mode: 0 = simple, 1 = standard, 2 = complex.
- Alias rows: `{"id": "<old>", "aliasOf": "<new>", "model", "mfr", "reason"}`.
- The index is enough to filter by brand, category, footprint, colour model and pixel count without opening any fixture file.

---

## 5. Defaults, neutral values and safety

### 5.1 Default ("home") value algorithm

The converter computes `default` as follows:
1. The source `defaultValue`.
2. Pan/tilt → centre.
3. Strobe, shutter, effect, control, macro, wheel, fan, fog, zoom and similar kinds:
   1. the first `open` capability;
   2. otherwise the first capability labelled off, stop, no function, none, disabled, manual, normal, neutral or default, **skipping any label containing reset, lamp on/off, calibrate, firmware, store or record**;
   3. otherwise a `none` range, preferring one that starts at 0;
   4. otherwise the first safe capability.
4. Tint → the neutral capability or the interpolated 0 %.
5. Otherwise 0.

Example: Aputure LS 600X "Effects" defaults to 160, the "Reserved" range, so no effect is selected. "Explosion" defaults to 0, "Stop".

### 5.2 Tint sign convention

**Proposed:** −100 % = full minus green (magenta), +100 % = full plus green. ARRI follows this. Other sources differ: some fixtures run the channel "magenta → green", others "green → magenta". Converters must use labels and direction, not assume. Curated packs should record any fixture whose convention is uncertain.

### 5.3 Control channels

Prism should never send `control` capabilities automatically. Expose them only behind an explicit "Fixture functions" UI, honour `hold` (e.g. "hold 3 s to reset"), and default them to the safe value from §5.1.

---

## 6. Mapping tables

### 6.1 OFL capability type → Prism kind

| OFL type | Prism capability kind | Extra fields |
|---|---|---|
| `NoFunction` | `none` | |
| `ShutterStrobe` Open / Closed | `open` / `closed` (channel kind `shutter` or `strobe`) | |
| `ShutterStrobe` Strobe, Pulse, RampUp, RampDown, RampUpDown, Lightning, Spikes, Burst | `strobe` | `pattern`, `random`, `sound`; speed → Hz or % |
| `StrobeSpeed`, `StrobeDuration` | `strobe` | |
| `Intensity` | `intensity` (or `hue`/`saturation`/`cct` per channel name) | brightness → % or lm |
| `ColorIntensity` | colour kind (§6.2) | |
| `ColorPreset` | `colorMacro` | `colors`, `colorsTo`, CCT |
| `ColorTemperature` | `cct` | K or % keyword |
| `Pan` / `PanContinuous` | `pan` (`continuous: true`) | deg / rpm |
| `Tilt` / `TiltContinuous` | `tilt` | |
| `PanTiltSpeed` | `panTiltSpeed` | |
| `WheelSlot`, `WheelShake` | by the wheel's dominant slot type: `colorWheel`, `gobo`, `prism`, `iris`, `frost` | `slot`, `colors` |
| `WheelSlotRotation`, `WheelRotation` | `goboRotation`, `prismRotation`, `colorWheel` | |
| `Effect`, `EffectParameter`, `SoundSensitivity` | `effect` | `label` = effectName/Preset; `sound` |
| `EffectSpeed`, `EffectDuration` | `effectSpeed` | |
| `BeamAngle`, `Zoom` | `zoom` | deg |
| `BeamPosition` | `generic` | |
| `Focus` | `focus` | |
| `Iris`, `IrisEffect` | `iris` | |
| `Frost`, `FrostEffect` | `frost` | |
| `Prism` / `PrismRotation` | `prism` / `prismRotation` | |
| `BladeInsertion`, `BladeRotation`, `BladeSystemRotation` | `blade` | `blade` |
| `Fog`, `FogOutput`, `FogType` | `fog` | |
| `Rotation` | `rotation` | |
| `Speed`, `Time` | `speed` | |
| `Maintenance` | `control` | `hold` |
| `Generic` | `generic`, refined by name (§6.3) | ranges parsed from `comment`, e.g. "0…360°", "-99%…-1%", "0 … 0.8" |

**Channel kind from mixed capabilities.** Each kind is weighted by the DMX width of its capabilities.
- A combined "Dimmer/Strobe" or "Dimmer/Shutter" channel becomes `intensity` if intensity covers more of the range, otherwise `strobe` or `shutter`.
- A single colour plus strobe or effect becomes that colour.
- Otherwise the kind with the most DMX width wins.

### 6.2 Colour mapping

| OFL `ColorIntensity` | QLC+ preset / `<Colour>` | GDTF attribute | Prism |
|---|---|---|---|
| Red / Green / Blue | `IntensityRed/Green/Blue` | `ColorAdd_R/G/B` | `red` / `green` / `blue` |
| White | `IntensityWhite` | `ColorAdd_W` | `white` |
| Warm White | — (named "WW"/"Warm White") | `ColorAdd_WW` | `warmWhite` |
| Cold White | — (named "CW"/"Cool White") | `ColorAdd_CW` | `coolWhite` |
| Amber | `IntensityAmber` (#FF7E00) | `ColorAdd_RY` | `amber` |
| Lime | `IntensityLime` | `ColorAdd_GY` | `lime` |
| Cyan / Magenta / Yellow | `IntensityCyan/Magenta/Yellow` | `ColorAdd_C/M/Y` (additive) or `ColorSub_C/M/Y` (subtractive) | `cyan` / `magenta` / `yellow` (colour model `cmy` when subtractive) |
| UV | `IntensityUV` (#9400D3) | `ColorAdd_UV` | `uv` |
| Indigo | `IntensityIndigo` | `ColorAdd_BM`/indigo emitters | `indigo` |

### 6.3 Name heuristics for `Generic` and weakly typed channels

These run in order and are restricted by base kind, so a typed Pan channel is never renamed.

```text
tint        \btint\b | green[-/]?magenta | magenta[-/]?green | \bg/m\b | \bgm\b | ±green | minus green | plus green
crossfade   cross-?fade | x-?fade | (cct|white) (<->|/|↔|to) (rgb|colou?r|hsi) | (rgb|colour) (<->|/|to) (cct|white) | \bblend\b | ^mix$
hue         \bhue\b
saturation  \bsat(uration|\.)?\b
cieX/cieY   \bcie ?x\b | ^x$ | x coord | chromaticity x      (only when base kind is generic)
fan         \bfan\b
cct         \bcct\b | kelvin | colou?r temp | white point | \bctc\b | ^ct$
control     curve | reset | control | function | \bmode\b | setting | response | smooth | special | lamp | fade time | calibrat | priority | auto
effectSpeed (speed|rate|tempo) … (effect|fx|program|auto|chase|macro|show) and the reverse order
effect      effect | \bfx\b | program | macro | chase | pattern | show | scene | sound | music
strobe      strobe | flash
shutter     shutter
intensity   dimmer | intensity | brightness | \bdim\b | master | level       (only when base kind is generic)
colorMacro  colou?r (macro|preset|select|filter|gel) | \bgel\b | \blee\b | rosco
```

Snapshot results (kinds derived from names): effect 66, hue 66, saturation 63, tint 52, control 42, fan 31, crossfade 30, colorMacro 9, shutter 9, effectSpeed 6, cieX 4, cieY 4.

Assumed ranges are used when nothing is stated: hue 0–360°, saturation and crossfade 0–100 %, CIE 0–0.8. These carry `assumed: true`.

### 6.4 QLC+ channel `Preset` → Prism kind

| QLC+ preset | Prism kind | Notes |
|---|---|---|
| `IntensityMasterDimmer` / `…Fine` | `intensity` / `intensityFine` (`scope: master` in pixel modes) | |
| `IntensityDimmer` / `…Fine` | `intensity` (per head/cell) | |
| `IntensityRed…Lime` (+`Fine`) | colour kind (+`Fine`) | per §6.2 |
| `IntensityHue` / `IntensitySaturation` (+`Fine`) | `hue` / `saturation` | assumed 0–360° / 0–100 % |
| `IntensityLightness` / `IntensityValue` (+`Fine`) | `intensity` | HSL/HSV L/V; flag as `colorModel: hsi` |
| `ColorRGBMixer` | `hue` | OFL treats it like hue |
| `PositionPan` / `PositionTilt` (+`Fine`) | `pan` / `tilt` (+`Fine`) | `Physical/Focus PanMax/TiltMax` → deg |
| `PositionXAxis` / `PositionYAxis` | `pan` / `tilt` | scanners/lasers; mark `kindFrom` |
| `SpeedPan…`, `SpeedTilt…` | `pan` / `tilt` with `continuous: true` | |
| `SpeedPanTiltSlowFast` / `FastSlow` | `panTiltSpeed` | direction from preset name |
| `ColorMacro` | `colorMacro` (or `colorWheel` if the capabilities are wheel slots) | |
| `ColorWheel` (+`Fine`) | `colorWheel` (continuous rotation) | |
| `ColorCTOMixer` / `ColorCTBMixer` / `ColorCTCMixer` | `cct` | CTO: default→warm; CTB: default→cold; CTC: warm→cold |
| `GoboWheel` (+`Fine`) | `goboRotation` (wheel rotation) | |
| `GoboIndex` (+`Fine`) | `goboRotation` (index angle 0–360°) | |
| `ShutterStrobeSlowFast` / `FastSlow` | `strobe` | |
| `ShutterIrisMinToMax` / `MaxToMin` / `Fine` | `iris` | direction |
| `BeamFocusNearFar` / `FarNear` / `Fine` | `focus` | |
| `BeamZoomSmallBig` / `BigSmall` / `Fine` | `zoom` | |
| `PrismRotationSlowFast` / `FastSlow` | `prismRotation` | |
| `NoFunction` | `none` | |
| *(no preset)* `Group` = Intensity + `<Colour>` | colour kind | |
| Group Intensity (no colour) | `intensity` | |
| Group Colour | `colorMacro`, `colorWheel` or `cct` | by name |
| Group Gobo | `gobo` / `goboRotation` | |
| Group Prism | `prism` / `prismRotation` | |
| Group Beam | `zoom`, `focus`, `iris` or `frost` | by name |
| Group Shutter | `strobe` / `shutter` | by capability presets |
| Group Speed | `effectSpeed` / `panTiltSpeed` | by name |
| Group Effect | `effect` | |
| Group Maintenance | `control` (or `fan` by name) | |
| Group Pan / Tilt | `pan` / `tilt` | |
| Group Nothing | `none` | |
| `Group Byte="1"` | `<kind>Fine` | pair with the preceding coarse channel of the same group and name stem |

Apply the §6.3 name heuristics after the Group mapping. This is needed for hue, saturation, CCT, tint and crossfade.

### 6.5 QLC+ capability `Preset` → Prism capability

| QLC+ capability preset | Prism capability |
|---|---|
| `ShutterOpen` / `ShutterClose` | `open` / `closed` |
| `StrobeSlowToFast`, `StrobeFastToSlow`, `StrobeFrequency`, `StrobeFreqRange` | `strobe` with `from`/`to` in Hz (`Res1`/`Res2`) or % |
| `StrobeRandom…` | `strobe`, `random: true` |
| `Pulse…`, `RampUp…`, `RampDown…` | `strobe`, `pattern: pulse/rampUp/rampDown` |
| `ColorMacro`, `ColorDoubleMacro` | `colorMacro`, `colors: [Color, Color2]` |
| `ColorWheelIndex` | `colorWheel` |
| `GoboMacro`, `GoboShakeMacro` | `gobo` (shake → label/flag; `Res` = gobo image file) |
| `GenericPicture` | `generic` with image reference |
| `PrismEffectOn` / `PrismEffectOff` | `prism` / `none` |
| `RotationStop`, `RotationIndexed`, `RotationClockwise…`, `RotationCounterClockwise…` | the channel's rotation kind (`goboRotation`, `prismRotation`, `rotation`) with `value: 0` (stop), an angle, or a signed speed (CW +, CCW −) |
| `LampOn`, `LampOff`, `Reset*` | `control` (unsafe; never automatic) |
| `SilentModeOn/Off/Automatic` | `fan` |
| `Alias` | switching (`switch.cases`) for the aliased channel in that mode |
| `SlowToFast`, `FastToSlow`, `NearToFar`, `FarToNear`, `BigToSmall`, `SmallToBig` | proportional `from`/`to` in % with direction |

### 6.6 Prism engine roles

How the engine uses each kind. This doubles as a checklist for the UI.

| Role | Kinds |
|---|---|
| Colour engine (RGB/RGBW/… mixing, CCT+tint, HSI, xy) | colour emitters, `cct`, `tint`, `hue`, `saturation`, `cieX`, `cieY`, `crossfade`, `intensity` (+ `Fine`) |
| Effects engine | `strobe`, `shutter`, `effect`, `effectSpeed` |
| Motion/beam (moving heads) | `pan`, `tilt`, `panTiltSpeed`, `zoom`, `focus`, `iris`, `frost`, `gobo*`, `prism*`, `blade`, `colorWheel` |
| Selection UI | `colorMacro`, `colorWheel`, `gobo` (labels and `colors`) |
| Hidden / guarded | `control`, `fan`, `generic`, `none` |

### 6.7 Category mapping

| Source | Prism category |
|---|---|
| OFL Moving Head / Scanner / Barrel Scanner; QLC+ Moving Head / Scanner | `movingHead` |
| OFL Smoke / Hazer / Fan / Laser / Flower; QLC+ Smoke / Hazer / Fan / Laser / Flower / Effect | `effect` |
| OFL Pixel Bar / Stand; QLC+ LED Bar (Beams) / LED Bar (Pixels) | `bar` (or `tube` / `strip` by name or shape) |
| OFL Matrix | `panel` |
| OFL Blinder / Color Changer; QLC+ Color Changer | `wash`, unless a name or shape rule matches (par, panel, fresnel, cob, spot, tube, bulb) |
| OFL / QLC+ Strobe | `effect` |
| OFL / QLC+ Dimmer | `dimmer` if intensity only (dimmer packs), else name rules / `other` |
| OFL / QLC+ Other | name rules, else `other` |

### 6.8 GDTF attribute → Prism kind (for a future importer)

| GDTF attribute | Prism kind |
|---|---|
| `Dimmer` | `intensity` |
| `ColorAdd_*` | colour kinds (§6.2) |
| `ColorSub_C/M/Y` | `cyan`/`magenta`/`yellow` (cmy) |
| `CTC` / `CTO` / `CTB` | `cct` |
| `Tint` | `tint` |
| `HSB_Hue` / `HSB_Saturation` / `HSB_Brightness` | `hue` / `saturation` / `intensity` |
| `CIE_X` / `CIE_Y` / `CIE_Brightness` | `cieX` / `cieY` / `intensity` |
| `ColorMixMode` / colour-mode switching | `crossfade` or `control` |
| `ColorMacro1` / `Color1` (wheel) | `colorMacro` / `colorWheel` |
| `Shutter1`, `Shutter1Strobe…` | `shutter` / `strobe` |
| `Pan`, `Tilt`, `PanRotate`, `TiltRotate` | `pan` / `tilt` (continuous) |
| `Zoom`, `Focus1`, `Iris`, `Frost1`, `Prism1`, `Gobo1` | `zoom`, `focus`, `iris`, `frost`, `prism`, `gobo` |
| `Effects1`, `EffectsRate` | `effect`, `effectSpeed` |
| `Fan…` | `fan` |
| `Fog…` / `Haze…` | `fog` |
| `Control1`, `DimmerCurve`, `Function` | `control` |

Verify the full list against Annex A/B of DIN SPEC 15800:2022-02 when building the importer.

---

## 7. Edge cases the engine and converters must handle

1. **Switching channels.** The meaning of a slot depends on another slot (OFL `switchChannels`, QLC+ `Alias`). The UI shows the current meaning. The converter stores the default case's kind for indexing, plus all cases. Aliases without a template pixel inherit the cell of their default target.
2. **Combined channels.** For example dimmer 0–200 plus strobe 201–255, or "Mode select" that changes the meaning of the next channels. Map 0–100 % onto the sub-range. Treat mode selectors as `control` with `constant`.
3. **Piecewise and segmented ranges.** ARRI tint has two neutral bands and full minus/plus at both ends. Colour-temperature tables are sometimes non-linear. Do the forward and inverse lookup per capability.
4. **Resolution mismatch.** Values are written at `res` but the mode uses fewer or more bytes, e.g. a 16-bit CCT definition in an 8-bit mode. Use the OFL scaling rules (§1.5). Fine bytes may be missing in some modes.
5. **24-bit channels.** 41 channels: generic faders and some CCT/dimmer. `fine` holds two offsets; the fine entries carry `byte: 2`/`3` (only `byte: 3` is written).
6. **C/M/Y meaning.** Additive LED emitters vs subtractive CMY flags. For subtractive, 0 % means no filter (white). Detect it with the `cmy` colour model, or the name or GDTF `ColorSub`.
7. **White channels.** "Emulated White" (Astera) is a mix of RGB, encoded as White. Warm/cold whites may be named "WW"/"CW", and QLC+ has no WW/CW preset. RGBWW vs RGBCW naming varies.
8. **Hue, saturation, tint, crossfade and CIE xy** have no native OFL type. Use name heuristics plus ranges parsed from comments. When a range is inferred, set `assumed: true`.
9. **Keyword percentages.** Speeds like `fast`→`slow` become 100 %→1 %. CCT keywords become −100 %…+100 % rather than Kelvin. Show them as relative, not absolute.
10. **Pixel groups.** A group that equals all pixels is a master. Groups can overlap pixel cells (zones plus pixels in one mode). `repeatFor` order can be X-fastest, Y-fastest or an explicit list. Holes in `pixelKeys` mean non-rectangular layouts, i.e. `orientation: custom`.
11. **Legacy multi-head fixtures** without a matrix ("Red 1", "Red 2", …). There are 44 in OFL. The curated pass can promote them to `pixels`.
12. **Unsafe defaults.** Never choose reset, lamp-off or calibration ranges as defaults (§5.1). Respect `hold`.
13. **Data quality.** 224 fixtures have `helpWanted` on some capability. Surface "unverified" in the UI and let users report problems.
14. **Naming.** OFL `shortName` must be unique. Mode names exclude the word "mode". Mode keys use `shortName` (e.g. `P03`), else the name. Fixture IDs must be stable across library updates; redirects provide aliases.
15. **Very large footprints.** Up to 256 channels in OFL and 480 in QLC+, and up to 181 modes (Chroma-Q). Expanded channel lists make these files large (§8).
16. **Direction ambiguity in QLC+.** `…FastSlow` vs `…SlowFast`, `CTO` vs `CTB`. Encode it as signed `from`/`to`.
17. **Physical overrides per mode.** Some modes change pixel count or beam, so the mode-level `physical` wins.

---

## 8. Library size and loading strategy

**Measured** with the prototype converter on all 653 OFL fixtures:

| Artifact | Size |
|---|---|
| OFL raw JSON | 7.47 MB |
| Prism JSON, minified, one file per fixture | **6.74 MB** (mean 10.3 KB, median 6.2 KB, p90 17.2 KB, max 373 KB for Astera FP3 Hyperion: 68 modes × 32 px) |
| Per-file gzip (sum) | 1.22 MB |
| **One compressed blob (gzip -9)** | **0.64 MB** |
| `index.json` | **159 KB raw / 24.5 KB gzip** |

**Estimates** for a combined library: OFL + QLC+ after de-duplication is about 2,100–2,300 fixtures.

| Artifact | Estimate |
|---|---|
| Prism JSON | about 15–20 MB raw (QLC+ files are smaller on average than OFL's pixel-heavy ones) |
| Compressed | about 1.5–2.5 MB |
| Index | about 0.5–0.6 MB raw / 80–100 KB gzip |
| Curated film pack (~300 fixtures) | about 3 MB raw / 0.3 MB compressed |

Even an extreme case of 10,000 fixtures stays under about 10 MB compressed in the app bundle.

**Recommended layout** (index plus lazy load):

```text
Prism.app/Contents/Resources/FixtureLibrary/
  library.sqlite            # or: index.json + fixtures.pack
    table fixtures(id TEXT PRIMARY KEY, mfr, model, cat, cx, px, colorModels, footprints, source, json BLOB /* zlib/LZFSE */)
    table aliases(id, aliasOf, reason)
    virtual table fts USING fts5(model, mfr, tags, aliases)   # instant search
  LICENSES/LICENSE-OFL.txt, LICENSES/LICENSE-QLCPLUS-APACHE-2.0.txt, ATTRIBUTION.md
~/Library/Application Support/Prism/Fixtures/
  user/…json                # user-created / imported (GDTF, edited copies); these override bundled ones by id
  updates/library-<date>.sqlite   # optional downloadable library updates
```

- **At launch:** load only the index (or open SQLite). This takes milliseconds and about 1 MB of memory.
- **On patch or preview:** decompress one fixture's JSON blob (10 KB typical) and decode it with `Codable`. Cache in memory with an LRU.
- **If file size matters,** store mode channel lists compactly as repeat blocks (`{repeat: cells, pattern: [...]}`) and expand them at load time. Pixel-heavy files shrink by about 70–90 %. Not needed at current sizes.
- **Build pipeline** (CI script): fetch the pinned OFL/QLC+ commits → convert → apply `category-overrides.json` and the curated film pack → validate against the Prism JSON Schema → write `library.sqlite` → record source commits and the licence manifest.

---

## 9. Licensing obligations checklist

- **OFL (MIT):**
  - Include `LICENSE-OFL.txt` ("Copyright (c) 2017 Florian & Felix Edelmann", with the full permission notice) in the app and its about/credits screen.
  - Keep per-fixture `source.authors`.
  - Optional but polite: link back to <https://open-fixture-library.org/>.
- **QLC+ (Apache-2.0):**
  - Include the full Apache-2.0 text.
  - Keep per-fixture authors from `<Creator><Author>`.
  - State that the definitions were converted or modified from the QLC+ fixture library.
  - Do not imply endorsement by QLC+.
  - There is no NOTICE file to carry today; re-check on each update.
- **GDTF:** do not redistribute. User-initiated download and import only, following the GDTF Share Terms of Use and the API requirement that each user has an account.
- **Manufacturer charts:** write definitions from facts; never ship the PDFs or copied text. Keep `source.library = "prism"` and a `links.manual` URL to the official document.
- **Carallon, Capture, Lightkey and similar:** only under a written licence.

---

## 10. Prototype converter (OFL → Prism)

All files are outside the repo, as instructed:

| Path | What it is |
|---|---|
| `/home/antigravity/fixture-sources/convert_ofl.py` | Converter, about 1,140 lines, Python 3 standard library only |
| `/home/antigravity/fixture-sources/prism-out/` | Output: `index.json`, `manufacturers.json`, `fixtures/<mfr>/<key>.json`, `stats.json`, `LICENSE-OFL.txt` |
| `/home/antigravity/fixture-sources/analyze_ofl.py` → `analysis_ofl.md` | OFL statistics used in this document |
| `/home/antigravity/fixture-sources/analyze_qlc.py` → `analysis_qlc.md` | QLC+ statistics used in this document |
| `/home/antigravity/fixture-sources/summarize.py` | Per-fixture debug view (modes, kinds, cells) |
| `/home/antigravity/fixture-sources/ofl`, `/home/antigravity/fixture-sources/qlcplus` | Source checkouts |

```bash
cd /home/antigravity/fixture-sources
python3 convert_ofl.py --ofl ./ofl --out ./prism-out           # all 653 fixtures, ~1.5 s, 0 errors
python3 convert_ofl.py --only aputure,arri --pretty --out /tmp/prism-subset   # subset, indented (--out is wiped first!)
python3 analyze_ofl.py > analysis_ofl.md; python3 analyze_qlc.py > analysis_qlc.md
(cd prism-out/fixtures && python3 ../../summarize.py +arri/skypanel-s60c.json)  # '+' prefix also prints channel definitions
```

**What it does:**
- Ports OFL's matrix model: pixelKeys/pixelCount, groups with constraints, all `repeatFor` orders, `perPixel`/`perChannel`.
- Resolves template channels, fine aliases and switching aliases.
- Classifies kinds from capability types plus name heuristics.
- Parses entities and units, including keywords → % and ranges from comments.
- Computes safe defaults, physical ranges, per-mode colour model, features, complexity and cells.
- Applies the category heuristics.
- Writes the index with alias rows, and size statistics.

**Spot-checked fixtures:** ARRI SkyPanel and L-series (CCT, tint, crossfade, HSI, RGBW, 8/16-bit pairs); Aputure Nova P300c (CIE x/y 0–0.8); Astera Titan/Helios/Hyperion (16/8/32 px, zone groups, master scope); Cameo Hydrabeam (multi-head pan/tilt cells); TMB Solaris Flare (96 px grid); Eurolite KLS-801 (switching).

**Known limitations and next steps:**
- (a) Category heuristics need the curated override file.
- (b) The name heuristics are English-only.
- (c) Only one physical quantity is kept per capability, the primary one. Secondary ones such as an `Effect` speed are left in the label.
- (d) Wheel slot images and resources are not copied.
- (e) No QLC+ or GDTF importer yet; the mappings in §6.4–6.8 are their spec.
- (f) No JSON Schema file for `prism-fixture/1` yet. Write one and validate in CI.
- (g) Move the scripts into the repo (e.g. `tools/fixtures/`) once the team approves.

---

## 11. Open decisions

1. **`cob` category:** add it to the enum? Recommended: yes.
2. **Kind vocabulary additions:** `colorWheel`, `goboRotation`, `prismRotation`, `iris`, `frost`, `blade`, `panTiltSpeed`, `fog`, `rotation`, `speed`, `none`.
3. **Tint convention:** −100 % = full minus green (magenta) … +100 % = full plus green.
4. **QLC+ import:** ship in v1, which roughly triples the fixture count but brings more heuristic noise, or in v1.x after the curated film pack?
5. **Storage:** SQLite with FTS5 (recommended) or `index.json` plus a pack file.
6. **Curated film pack:** scope and priority list (§3.4), and who validates it on hardware.
7. **GDTF Share sign-in import:** in scope for v1? It needs a UI for the user's own account.
8. **Carallon licence:** worth evaluating if commercial breadth becomes a requirement.
