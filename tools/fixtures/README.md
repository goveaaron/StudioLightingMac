# Prism Fixture Library Build Tools

This directory contains reproducible Python 3 scripts (standard library only, no third-party dependencies) that build `Resources/FixtureLibrary/`.

## Scripts

- `build_curated.py` — Generates Prism's hand-curated Film/TV and generic fixture packs from manufacturer DMX specification charts:
  - `Resources/FixtureLibrary/curated/amaran.json` (16 amaran fixtures)
  - `Resources/FixtureLibrary/curated/aputure.json` (20 Aputure fixtures)
  - `Resources/FixtureLibrary/curated/film_tv.json` (58 Film/TV fixtures: Nanlite, Godox, Astera, Litepanels, ARRI, Kino Flo, Quasar Science, Creamsource, Rotolight)
  - `Resources/FixtureLibrary/generic/generic.json` (12 Generic fixtures)
- `convert_ofl.py` — Converts Open Fixture Library (MIT) JSON definitions into Prism's `$schema: "prism-fixture/1"` shared-definition format, preserving matrices/pixels, capabilities, physical ranges, and provenance.
- `build_library.py` — Runs the full pipeline:
  1. Executes `build_curated.py` and compacts the curated/generic JSON files.
  2. Converts Open Fixture Library (`--ofl`, default `/home/antigravity/fixture-sources/ofl`) into `Resources/FixtureLibrary/ofl/<brand>.json`.
  3. Converts QLC+ `.qxf` XML definitions (`--qlc`, default `/home/antigravity/fixture-sources/qlcplus/resources/fixtures`) into `Resources/FixtureLibrary/qlcplus/<brand>.json`.
  4. Deduplicates across libraries with strict priority: `curated > OFL > QLC+`.
  5. Validates that every mode has `1 <= channels.count <= 512`.
  6. Generates `Resources/FixtureLibrary/index.json` (`[FixtureLibraryEntry]`) for fast startup and on-demand lazy loading.

## Usage

```bash
python3 tools/fixtures/build_library.py \
  --ofl /home/antigravity/fixture-sources/ofl \
  --qlc /home/antigravity/fixture-sources/qlcplus/resources/fixtures \
  --out Resources/FixtureLibrary
```
