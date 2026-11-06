# Brief: inspector — precise control of the selected lights

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/competitors.md` §2.3, §5.5 (Sidus color tools: HSI, CCT, gels, source match,
  xy, picker) and §3

## Goal

Exact, beautiful, fast control of one light, one pixel or a whole multi-selection:
- color as hex, RGB, HSB, Kelvin + green/magenta, gels and xy, all kept in sync;
- intensity in % or stops.

Everything is one click away and nothing is confusing.

## You own

`Sources/PrismApp/Inspector/**` and the inspector tests.

## Deliverables (priority order)

### 1. Color

- A large HS color wheel plus brightness.
- **Synced fields:**
  - **hex:** accepts "#00C2B8", "00c2b8" and "rgb(0,194,184)"; copy button;
  - RGB 0–255, HSB;
  - Kelvin + tint (G/M) with presets;
  - CIE xy (advanced).
- **Mode tabs:**
  - **Color**;
  - **White** (Kelvin/tint, real sources from the color team's presets);
  - **Gel** (searchable Rosco/LEE `GelLibrary` with swatches and numbers);
  - **Source** ("match tungsten / HMI / sodium vapor…").
- **Shortcuts:**
  - named colors;
  - project swatches (palette) and recent colors;
  - **eyedropper** from the stage, and from anywhere on screen (`NSColorSampler`);
  - **palette from image:** drop a photo → 5 colors → spread across the selection by stage
    position.

### 2. Intensity

- % with 0.1 precision, and stops (±⅓-stop nudges; 1 stop = half).
- Quick buttons, ⌥ fine drag, and typing an exact value.

### 3. Pixel editor (pixel fixtures)

- A strip of cells: select cells, color each cell.
- Gradient across cells, fill, reverse, mirror.

### 4. Multi-selection

- **Relative edits:** +10% to all, shift all hues.
- "Mixed" display for differing values.
- Apply one color to all.
- Spread a gradient across the selection by stage position.

### 5. Effects

Embed `EffectsBrowser(fixtureIDs:)`, built by the effects team.

### 6. Fixture section

- Name, label, role (Key/Fill/Back/Background/Practical/Accent…), group.
- **Limits:** min/max intensity, protect from effects/music/remote.
- **Calibration:** the color team's API.
- **DMX info:** universe/address/mode, with "Show in Patch".
- Notes.

### 7. Polish

- Fix the clipped preset chips (e.g. "2,700 K" wraps onto two lines).
- Consistent row heights and focus order, accessible labels.
- Live updates while the engine fades.

## Acceptance

- **Tour scenes:**
  - a tube selected (Color tab);
  - the White tab;
  - the Gel tab;
  - the pixel editor with a gradient;
  - multi-select with mixed values;
  - the effects section;
  - the fixture/limits section.
- **Self-tests:**
  - typing a hex value sets the exact state;
  - Kelvin + tint round-trips to the same numbers;
  - relative intensity on a multi-selection.
