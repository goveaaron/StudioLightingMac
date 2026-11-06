# Brief: engine — show engine, commands, persistence

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md` (all of it)
- `docs/research/competitors.md` §2.5, §2.11, §2.12, and §3 (perceptual crossfades, resume
  after crash, recording mode, protect faces)

## Goal

A rock-solid core:
- 40+ fps DMX with zero glitches;
- beautiful crossfades;
- undo for everything;
- files that are never lost or corrupted;
- a command language rich enough for the UI, assistant, remote and integrations.

## You own

`Engine/EngineCore.swift`, `Engine/ShowSnapshot.swift`, `Engine/DMXOutput.swift`,
`Command/LightingCommand.swift`, `Command/CommandExecutor.swift`, `Model/**` (except the
`FixtureState` mix helpers), `Persistence/**`, `Util/**`, `Fixtures/PatchedFixture.swift`,
`Sources/PrismApp/Show/**`, and the matching tests.

## Deliverables (priority order)

### 1. Thread safety

- Fix the `EngineCore.tick()` race:
  - `frameNumber` and the fps fields are mutated from the main thread (shutdown, self-test)
    while the timer ticks on the engine queue.
  - Confine engine state to the engine queue, or guard it with `PrismLock`.
- `shutdown()` performs its final hold/blackout frame on the engine queue, with a bounded wait.
- Add a stress test: concurrent snapshot updates plus ticks plus `stop`/`start`.
- `scripts/linux-swift.sh test --sanitize=thread --filter Engine` must be clean (core-only works:
  `PRISM_CORE_ONLY=1`).

### 2. Crossfade engine

- **Look recall:**
  - per-look fade time;
  - per-fixture delay ("wave across the room" by stage position);
  - presets: Snap 0 s, Quick 0.4 s, Smooth 1.5 s, Slow 4 s, Cinematic 10 s;
  - curves: linear, ease-in-out, S-curve.
- **Interruption:** a new fade mid-fade starts from the **currently rendered** state, never jumps.
- Effects and music transitions also fade in and out.
- Expose fade progress for the UI (a progress ring in the bottom bar).

### 3. Commands (`LightingCommand` + `CommandExecutor`)

**New commands:**
- `setCells` / `paintCells` (per-cell colors for pixel fixtures)
- `setEffectParameters`, `setFixtureProtection`
- `setRecordingMode(Bool)` — locks key/fill, no flashing, remote becomes read-only
- `freeze(Bool)` — holds output
- `swapColors`, `copyLook`
- Relative **nudge** constants shared by the assistant and keyboard shortcuts:
  "a little" = 5%, "a bit" = 10%, "a lot" = 25%, and Kelvin/tint equivalents.

**Every command:**
- validates and clamps its input;
- returns a `CommandResult` with a human description ("Back tubes → teal") and the affected IDs;
- keeps its JSON coding backward compatible (tests).

### 4. Protection and limits

- Fixtures with role key/fill, or `limits.protected`, are excluded from effects, music and
  remote changes unless explicitly targeted from the UI.
- Recording mode enforces this globally.
- `FixtureLimits` (min/max intensity, Kelvin range) are enforced in the executor for **every**
  origin.

### 5. History

- An attributed timeline: who or what changed it (UI, assistant, remote guest name, MIDI…), with
  timestamps.
- `ShowController` exposes it for a History popover, which the shell renders.
- Slider drags coalesce (as today).
- An assistant plan is a single undo step.

### 6. Persistence

- **Atomic writes:** write to a temp file, then rename.
- **Rolling backups:** the last 10 saves, plus hourly snapshots for 24 h, in
  `~/Library/Application Support/Prism/Backups/<project-id>/`.
- **Autosave** when dirty (verify the existing one).
- **"Resume where you left off"** after a crash.
- **Schema `version` + migrations.** Decoding is tolerant: corrupt sections are repaired and
  reported through `openReport`.
- **Single-look sharing:** a `.prismlook` file.
- **Import/merge looks from another project:** match fixtures by role, then label, then name.

### 7. Performance and soak

- A frame with 16 universes, 200 fixtures and 20 effects renders in < 2 ms (release).
- `--soak <seconds>` launch option: randomly applies commands and looks, and asserts:
  - no frame takes > 25 ms;
  - memory stays flat.
- The orchestrator will wire the soak into a CI job.

### 8. Keep `ShowController` lean

It is the single mutation path. Help other teams put their helpers in extensions in their own
folders.

## Acceptance (Linux tests)

- Crossfade math, including continuity when a fade is interrupted mid-way.
- JSON round trip and execution for every command.
- Limits and protection enforced for every origin.
- v1 → v2 migration.
- Atomic save and backup rotation.
- Fuzz test: random command sequences never crash and never produce NaN or out-of-range DMX.
- TSan clean. The `engine.*` self-tests pass on CI.
