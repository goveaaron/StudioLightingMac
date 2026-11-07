# Lightkey `.lightkeyproj` Format Summary

See `docs/research/lightkey_format/` (`class-schemas.md`, `fpstore-format.md`, `pitfalls.md`, `CHANGELOG.md`) for the complete field-by-field binary plist tables.

## Key Takeaways for `LightkeyImporter`

1. **Container**: A `.lightkeyproj` file is an `NSKeyedArchiver` binary plist (`$archiver = "NSKeyedArchiver"`, `$version = 100000`, `$objects`, `$top`) or a package directory containing `Contents.plist` / `Project.plist`.
2. **Portable Decoding**: Never use `NSKeyedUnarchiver` class mapping (`LX*` classes do not exist in Prism and `NSKeyedUnarchiver` behaves differently on Linux). Decode with `PropertyListSerialization.propertyList(from:options:format:)` and resolve `CF$UID` / `$uid` / `_CFKeyedArchiverUID` indices into `$objects`.
3. **Top-Level Graph (`$top`)**:
   - `universes`: `NSArray` of `LXDMXUniverse` (`universeNumber`, `UUID`, `fixtures`).
   - `fixtureProfiles`: `NSArray` of `LXFixtureProfile` (`UUID`, `manufacturer`, `name`, `personalities` → `LXPersonality` → `capabilities`).
   - `stages`: `NSArray` of `LXStage` (`items` → `LXFixtureCanvasItem` with `fixtureUUID`, `center` / `rect` strings, and `angleCCW`).
   - `rootPresetGroup`: `LXRootPresetGroup` tree of `LXPresetGroup` folders and `LXPreset` looks.
   - `cues`: `NSArray` of `LXCue` (`name`, `fadeInDuration`, `fadeOutDuration`, `presets`).
4. **Preset `fpStore` Inner Binary Plist**:
   - Each `LXPreset.fpStore` is an embedded binary plist (`PropertyListSerialization`).
   - Fixture states are keyed by **UPPERCASE** fixture UUID strings under `umbrellaContainers` (or `containers` → `subcontainers` in newer schemas).
   - `segmentContainers` holds per-pixel or whole-fixture values: `intensity` (`0.0…1.0`), `xfadeToColor` (`0.0…1.0`), and `color` (`[Int64]`).
5. **64-Bit Packed Color (`B-G-R-A`)**:
   - `color[0]` packs four 16-bit unsigned channels (`0…65535`):
     - Bits `0…15`: **Blue**
     - Bits `16…31`: **Green**
     - Bits `32…47`: **Red**
     - Bits `48…63`: **Alpha** (`0xFFFF`)
6. **Amaran PT Profile Mapping**:
   - Lightkey's `"Amaran PT"` profile maps to `amaran.pt4c` by channel count (`6, 7, 10, 14, 28, 56, 112`). In 8-pixel mode (56ch), each pixel uses 7 channels (`Intensity, CCT, G/M, Crossfade, R, G, B`) with `beamIndexes = [2*p, 2*p+1]`.
