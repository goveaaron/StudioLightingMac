# Brief: effects — the effects engine and catalog

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/competitors.md` §5 (Sidus effects: exact parameters and behaviours), §1.4 and
  §2.4
- `docs/research/music_reactive.md` §4 (flash safety rules, which also apply to effects)

## Goal

A gorgeous and safe effects catalog:
- everything Aputure's Sidus Link offers, re-implemented as software effects that work on
  **any** fixture;
- pixel effects for the tubes;
- calm ambient looks you can leave running all evening.

Every effect looks great with its default settings and has a live animated preview.

## You own

`Sources/PrismCore/Effects/**` (except `MusicEngine`/`MusicMoodLibrary`, which move to the
music team — they will remove them from `EffectEngine.swift`; don't fight over it),
`Sources/PrismApp/Effects/**`, and the effects tests.

## Deliverables (priority order)

### 1. The catalog (`EffectKind` + implementations)

- **Sidus system FX:** candle, fire, TV flicker, lightning, cop car, paparazzi, fireworks,
  party, pulse, strobe (capped), explosion, welding, faulty bulb, club lights. Use the parameter
  vocabulary in §5.1.
- **Pixel FX** (cell-level, for tubes and bars): chase, rainbow, sweep, comet, twinkle/sparkle,
  wave, marquee, color fade, pixel fire, gradient scroll, ping-pong, meteor, breathing pixels.
- **Calm ambient:** breathe, drift (slow hue drift), aurora, ocean, sunset, subtle neon hum,
  lava lamp, cloud shadows, candle-lit room, starfield.

### 2. Spatial effects

Effects travel across the **room** using stage positions (`snap.geometry`), not fixture order:
left→right waves, radial from the centre, top→bottom.

### 3. Tempo sync

- Speed can be set in BPM.
- When music mode is on, effects sync to the music engine's beat clock (subdivisions 1/4 beat to
  4 bars). Otherwise they run free.
- Provide a tap-tempo hook.

### 4. Safety

- Every effect declares whether it `flashes`, and its maximum flash rate.
- The engine caps strobe, lightning, paparazzi and similar effects at `safety.maxStrobeHz`, and
  at 3 Hz in photosensitive mode.
- Protected (key/fill) fixtures are excluded unless the user explicitly targets them.

### 5. Blending

- Effects layer over the base look according to `EffectBlend`.
- They crossfade in and out together with looks.
- When effects overlap, resolution is deterministic: the last one added wins per attribute.

### 6. Metadata (`EffectKind.info` → `EffectInfo`)

- Fields: title, SF Symbol, category, one-line summary, parameter specs (name, range, default,
  unit, display style), `isCalm`, `flashes`.
- Used by the browser, the assistant ("flicker like a candle") and the web remote.

### 7. `EffectsBrowser` (`PrismApp/Effects/`)

- A grid of effect cards with **live animated previews**: render a tiny tube/strip using the
  real effect function at about 15 fps, paused when off-screen.
- Categories: Calm, Nature, Film FX, Party, Pixels. Plus search.
- One-click apply to the current selection.
- A parameter editor using `Components` sliders and color controls, and "Stop all effects".
- The inspector embeds `EffectsBrowser(fixtureIDs:)`. The shell may embed a compact variant on
  the Live page; offer a `compact` style.

### 8. Determinism

- Effects are pure functions of (time, params, fixture index/position, seed). This keeps
  previews, the web remote and screenshots reproducible.
- Random effects use a seeded PRNG.

## Acceptance

- **Linux tests:**
  - Every effect produces finite, in-range values for 0–60 s on 1-, 8- and 16-cell fixtures.
  - Flash-rate caps hold (count luminance peaks per second).
  - Determinism, blending rules, and tempo-sync phase alignment.
- **Tour scenes:** the browser grid, the parameter editor, candle on P1, a rainbow chase on the
  tubes, aurora across the room (stage).
