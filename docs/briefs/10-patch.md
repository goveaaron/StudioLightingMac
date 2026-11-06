# Brief: patch — effortless patching (and import from Lightkey)

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/competitors.md` §4 (beginner-proof patching: follow the §4.3 wizard closely),
  §1.1, §2.1, §2.2 and §3
- `docs/research/aputure_profiles.md` §0, §2 (exact PT tube menus) and §13
- Lightkey format notes in
  `/home/antigravity/.gemini/jetski/brain/e2057cc3728b4b861c63ab365a0d6ed2/scratch/lkformat/`
  (`class-schemas.md`, `fpstore-format.md`, `pitfalls.md`, `CHANGELOG.md`). Copy what you use
  into `docs/research/lightkey_format.md`.
- Public reference: GitHub `jimhoggey/Lightkey-Skill`.

## Goal

The user says DMX patching baffles them. Make it a non-issue:
- They add lights by picking **what** they are.
- Prism picks the addresses and tells them exactly what to set on each light, using the light's
  own menu names.
- Prism checks that it worked and helps find lights they're unsure about.
- Their whole Lightkey setup imports in one click.

## You own

`Sources/PrismApp/Patch/**`, `Sources/PrismCore/Patch/**` (new; move `PatchMath` here from
`ProjectIO.swift`, coordinating with the engine team), `Sources/PrismCore/Import/**` (new), and
the patch/import tests.

## Deliverables (priority order)

### 1. Lightkey import (top priority — the user has an existing Lightkey project)

- **`PrismCore/Import/LightkeyImporter`** parses `.lightkeyproj`, an NSKeyedArchiver binary
  plist; check the notes for package vs. file. Extract:
  - fixtures (name, label, profile, mode, universe, address);
  - canvas positions and rotation, mapped to stage coordinates;
  - looks/presets with colors and intensities;
  - folders.
- **Decoding:** write a portable keyed-archive object-graph decoder. Use
  `PropertyListSerialization`, which works on Linux, and resolve `$objects` and UID references
  manually. No NSKeyedUnarchiver class mapping.
- **Profile mapping:** map Lightkey profiles to our library, e.g. "Amaran PT" → amaran PT4c
  "LE CCT&RGB n px" by channel count. Fall back to a generated definition from the channel
  layout, and report anything unmapped in plain English.
- **Tests:** build a synthetic `.lightkeyproj` generator from the schemas in the notes.
- **UI** (`ImportLightkeySheet`): drag & drop or Open…, a preview (fixtures on a mini stage,
  looks, warnings), then Import.

### 2. Add Light wizard (rework `AddFixtureSheet`, per §4.3)

- **Finding the light:**
  - brand-first browsing, popular brands first (Aputure/amaran, Nanlite, Godox, Astera,
    generic);
  - search through the library team's fuzzy search.
- **Choices:**
  - quantity;
  - mode in plain language, e.g. "Full color · 8 zones (recommended)", with the channel count
    shown secondary;
  - role (Key/Fill/Back/Background).
- **Auto-address:** "easy numbers" (1, 101, 201…) or packed.
- **Universe budget bar:** how much of 512 is used, colored per fixture.
- **Auto-placement** on the stage, with sensible default positions per role.

### 3. Setup cards (`AppSheet.setupCards`)

- One card per light, e.g. "Set **Tube B3** to address **A113**, mode **CCT&RGB 8PX**".
- The exact menu path comes from the library `setupGuide`, with simple diagrams.
- A done-checkbox and a **"Test it"** button that blinks the light.
- Print or export as PDF; optional "send to my phone" via the remote team's server (falls back to
  PDF).

### 4. Patch workspace (`PatchWorkspace`)

- **Universe map:** a 512-cell grid with fixtures as colored blocks and conflicts in red. Drag a
  block to re-address it (with snapping); gaps are visible.
- **Patch table:**
  - editable name, label, address, mode, role;
  - multi-select, sort.
- **Fixture actions:**
  - unpatch (undoable);
  - **replace fixture:** swap the profile while keeping position and looks, so the color intent
    is preserved;
  - duplicate.
- **Patch-wide tools:** "Fix conflicts" button, CSV export/import, "Copy patch summary".

### 5. Channel tester

- Raw channel sliders per fixture with real names ("Pixel 3 · Red").
- A test sequence: R/G/B/W per pixel, plus a **pixel walk**. PT tubes don't document which end is
  pixel 1, so add a "flip pixel order" toggle on the fixture.

### 6. Troubleshooter (`AppSheet.troubleshooter`)

A "this light isn't responding" decision tree:
1. power;
2. DMX box status (the hardware team's `OutputManager`);
3. cable direction (IN/OUT), terminator;
4. address match (show what the light's display should read);
5. mode/channel-count match;
6. the PT tube DMX-screen lock tip;
7. then offer an address scan.

### 7. Find my lights (`AppSheet.addressScan`)

- Flash patched fixtures, or raw address ranges, one at a time.
- The user clicks which light lit up on the stage, or "none". Prism builds a corrected patch.
- **"Let the camera do it":** sets `app.camera.lightFinderRequest = .scanAddresses(…)` and
  presents the Light Finder.

### 8. Profile editor (`AppSheet.profileEditor`)

- Create or edit a fixture definition visually: channel list with type pickers, pixel grouping,
  modes.
- Validate, then save to the user library (the library team's API).

## Acceptance

- **Import tests:** synthetic archives (fixtures, positions, looks, folders) import correctly.
  Malformed input never crashes (fuzz test), and unmapped items are reported.
- **Auto-address tests:**
  - no overlaps;
  - easy numbers;
  - overflow to the next universe with a clear message.
- **Tour scenes:**
  - each wizard step;
  - setup cards;
  - universe map with a conflict;
  - channel tester;
  - troubleshooter;
  - address scan;
  - Lightkey import preview.
- If the NSTableView reentrancy warning comes from the patch table, fix it (coordinate with the
  shell team).
