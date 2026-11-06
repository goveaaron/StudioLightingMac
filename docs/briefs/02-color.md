# Brief: color — color science and emitter mixing

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/competitors.md` §2.3 and §5.5 (Sidus color tools)
- `docs/research/aputure_profiles.md` §1.2 and §2.5
- `docs/research/music_reactive.md` §5 (RGBWW mapping, gamut)
- `docs/research/fixture_libraries.md` §5–6

## Goal

The color you pick is the color you get, on every kind of fixture.
- Film-native controls (Kelvin + green/magenta, gels, real-source presets) sit next to exact
  hex/RGB/HSB.
- Fades are perceptually smooth.

## You own

`Sources/PrismCore/Color/**`, `Engine/EmitterMixer.swift`, `Engine/FixtureRenderer.swift`,
the `mix`/interpolation helpers in `Model/FixtureState.swift`, `Resources/Gels/**`, and the
color tests.

## Deliverables (priority order)

### 1. Emitter mixing (`EmitterMixer`)

- **Fixture types to solve for:**
  - RGB, RGBW, RGBA, RGBWW, RGBACL, RGB+lime
  - CCT-only (warm/cool)
  - dimmer-only
  - HSI-native, xy-native
  - Aputure "CCT↔RGB crossfade" fixtures
- **Method:** non-negative least squares on emitter chromaticities, using per-emitter xy and
  lumens from the definition, with good defaults per emitter type.
- **Two modes**, with a project default and a per-fixture override:
  - **Accurate:** match chromaticity, and prefer W/WW/A for whites and pastels for quality.
  - **Direct:** hex goes straight to the R/G/B channels, for people who want exactly `#FF00AA`.

### 2. Native white path

- When the target is near the Planckian locus, fixtures with CCT channels use CCT + G/M
  (Aputure: crossfade 0 = CCT mode) instead of RGB.
- Add hysteresis so fades never flicker between the two paths.

### 3. Color spaces (`ColorMath`)

- **Conversions:** sRGB ↔ linear ↔ XYZ ↔ xyY ↔ OKLab/OKLCh ↔ HSB/HSL.
- **White:** Kelvin + tint ↔ xy (the existing Planckian inverse), with tint mapped to the
  Aputure/Sidus G/M scale.
- **Color difference:** ΔE2000 and ΔE in OKLab.
- **Gamut mapping:** keep the hue and reduce chroma in OKLCh.
- Keep the existing public API source-compatible; many teams use it.

### 4. Perceptual fades

- Colors interpolate through OKLab (no grey dip), whites through mired, intensity on a
  perceptual curve.
- Pixel arrays fade cell by cell.
- `FixtureState.mix` uses all of this.

### 5. Dimmer curves and resolution

- Per-fixture curves: linear, square law, S-curve, LED smoothing.
- 16-bit fine channels.
- Minimum-level handling, so LEDs don't pop on at 1%.
- A "never fully off unless turned off" option for key lights.

### 6. Calibration

- `ColorCalibration` per fixture: per-emitter gain and white-point trim.
- Provide the API plus tests. The camera team will drive auto-calibration later.

### 7. Gels, named colors and real sources

- **`GelLibrary`:** about 200 common Rosco and LEE gels, each with name, number, xy or
  approximate RGB, and transmission. Include:
  - the full CTO/CTB family (1/8 to Full), Plus/Minus Green;
  - Bastard Amber, Steel Blue, Congo Blue, Surprise Pink, and so on.
- **`NamedColors`:** CSS names plus film words, each with RGB or Kelvin + tint. Examples:
  "teal", "magenta", "warm white", "tungsten", "daylight", "moonlight", "golden hour",
  "sodium vapor". The assistant and inspector both use this.
- **Real-source presets:**
  - Tungsten 3200 K, HMI 5600 K, Candle 1900 K
  - Sodium vapor, Mercury vapor, Cool-white fluorescent (+G)
  - Overcast 6500 K, Shade 7500 K, Golden hour 3500 K

### 8. Strobe and shutter mapping

- Apply safety caps: `SafetySettings.maxStrobeHz`, and ≤ 3 Hz in photosensitive mode.
- Effect channels are zeroed by default.

### 9. Performance

- `FixtureRenderer` renders 16 universes in < 1 ms (release build).
- No per-frame allocations in the hot path.

## Acceptance (Linux tests)

- **Round trips:** hex ↔ RGB ↔ HSB ↔ OKLab ↔ XYZ.
- **White accuracy:** Kelvin + tint → xy → Kelvin + tint stays within 20 K / 0.002 Duv over
  1700–20000 K.
- **Mixer accuracy:** in-gamut targets come out within ΔE2000 < 2 for RGBW, RGBWW and RGBA.
- **Mixer behaviour:**
  - On RGBWW, whites use the W/WW emitters.
  - Direct mode passes hex through exactly.
  - The OKLab midpoint of red→cyan is not grey.
- **Golden DMX values** for the PT4c pixel mode (teal, 3200 K, pure red), agreed with the
  library team.
