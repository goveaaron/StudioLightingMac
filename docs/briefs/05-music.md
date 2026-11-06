# Brief: music — "play Spotify and the room comes alive"

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- **`docs/research/music_reactive.md`** (the full spec: pipeline, features, 16 moods, safety,
  tests, plus a Python reference beat tracker)
- `docs/research/macos_media_ai.md` §1 (capture code: Core Audio process tap,
  ScreenCaptureKit audio, microphone)
- `docs/research/macos_systems.md` §4.7 (TCC permissions)
- `docs/research/competitors.md` §1.29 and §2.7

## Goal

The user turns on Music Mode while Spotify or YouTube plays, and the lights move beautifully with
the song:
- flowing color, phrase-aware changes, breathing with the dynamics;
- cinematic and synth-like, **never** cheap strobing;
- zero setup, and safe to leave running for hours.

## You own

`Sources/PrismCore/Music/**` (move `MusicEngine` and `MusicMoodLibrary` out of
`Effects/EffectEngine.swift` into `Music/MusicEngine.swift`, as a small coordinated removal),
`Sources/PrismApp/Music/**`, and the music tests.

## Deliverables (priority order)

### 1. Capture (`PrismApp/Music/`)

- **Primary:** a Core Audio process tap (macOS 14.2+/14.4+ behind `#available`). Sources: the
  whole Mac, or one app (Spotify, Music, Chrome, Safari…).
- **Fallbacks:** ScreenCaptureKit audio, then microphone/line-in, then loopback devices
  (BlackHole) if present.
- **Permission flow** with a plain-English explanation and a live test meter.
- **Must survive:** device changes, sleep/wake, the source app quitting, and silence.
- **Threading:** capture → lock-free ring buffer → analysis thread. Never block the main thread
  or the engine.

### 2. DSP (`PrismCore/Music/`)

Portable code: vDSP via `#if canImport(Accelerate)`, with a portable FFT fallback so the Linux
tests run. Implement as specified in §1–2:
- multi-resolution FFT;
- bands, loudness, auto-gain;
- spectral-flux onsets;
- tempo with octave handling, beat PLL, downbeats/bars;
- chroma/key → hue;
- novelty, drops and sections;
- silence detection;
- latency compensation.

### 3. Moods (§3)

- **All 16 moods**, each a palette plus motion grammar with spatial flow across the stage and
  pixel animation on the tubes.
- Changes are bar-quantized, with phrase-level palette shifts, downbeat accents and smooth
  intensity breathing.
- **Auto mood** picks from tempo, energy and key.
- Background tubes dance. Key and fill stay steady unless the user opts in.

### 4. The Music workspace (`MusicWorkspace`) — make it stunning

- **Live visual:** a spectrum/beat ring, BPM with confidence, and the current section.
- A grid of mood cards with animated previews.
- **Controls:**
  - "wildness" slider (calm ↔ lively) and a palette override;
  - participating lights (role chips);
  - half/double tempo, sync offset in ms, tap tempo;
  - silence fallback (fade to a chosen look after N seconds);
  - **"Leave it running"** (auto-resume when music starts again).
- **Settings pane** (`MusicSettingsPane`): source selection, sensitivity, latency, safety.

### 5. Safety (§4)

- Photosensitive-safe mode is on by default.
- No strobe unless explicitly enabled.
- Flash and pulse rate limits, per-frame change limits, intensity floors, the saturated-red rule.

### 6. Engine integration

- Feed `AudioFeatures` through `EngineCore.setAudioFeatures`.
- Expose a beat clock that effects can use for tempo sync (coordinate the API with the effects
  team).

### 7. Synthetic-audio tests (Linux)

- **Signals:** click tracks at known BPMs, tempo ramps, sweeps, pink noise, silence, a synthetic
  build-and-drop.
- **Assertions:**
  - tempo within ±1 BPM, beat phase error < 30 ms;
  - silence detected, auto-gain stable;
  - 60 s of every mood stays finite, in range and under the flash caps.

### 8. Self-test and tour

- **Self-test:** inject a synthetic signal into the analyzer inside the app and check the BPM.
- **Tour scenes:** idle workspace, "playing" (synthetic features driving the visuals), mood grid,
  settings pane.

## Acceptance

- All the tests above pass.
- The capture code compiles with macOS 14 as the deployment target.
- The user flow works: Spotify playing → **Music** tab → toggle on → the lights dance within 2 s.
