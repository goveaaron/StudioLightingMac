# Prism — the brief every agent shares

## The user and their studio

A creator studio ("London Studio") runs a Mac mini wired to an **Enttec DMX USB Pro** that
drives about eight **Aputure/amaran pixel tubes** (probably amaran PT-series), one square
**LED panel**, and one round **dimmer-only** fixture. A **webcam** looks at the set. The user is
not a lighting professional. They find Lightkey clunky and DMX patching baffling.

Reference: `docs/reference/lightkey-screenshot.png` shows their current Lightkey layout,
mirrored by `DemoRig.londonStudio()`:
- Tubes B1 (left) and B5 (right) stand vertically.
- B2 and B3 hang horizontally above them, with B4 below them in the centre.
- B6, B7 and B8 lie diagonally near the subject's feet.
- PN1 is the panel; P1 is the round dimmer.
- Looks include "Chill Vibes 4", "Blackout", "WNDT", and folders "Random" and "Cool Setups".

## What they asked for (verbatim intent)

- A **fully featured, beautiful, ultra-reliable native macOS app**, better than Lightkey in
  every way (Blackout is another reference), and much more intuitive.
- **Visualize** the lights, **move** them around, **change color** precisely: exact **hex codes**,
  RGB/HSB, **white balance** (Kelvin plus green/magenta tint).
- **Patching** must become dramatically easier. They should be able to patch and unpatch, and
  plugging something in should feel intuitive. Help them find patched lights they're unsure of.
- **Libraries** for any kind of light.
- **Shareable project files**, so they can send projects to other Prism users.
- **Music mode**: play Spotify or YouTube on the Mac and the lights respond to the music
  beautifully. Synth-like and cinematic, never annoying strobes. They want to leave it
  running in the room.
- **Talk to it**, e.g. "All right, light app, warm up the background a bit. Bit more blue to
  the back left. Bring the tubes down a little. Brighten up the key a little. Bring down the
  fill a little." Scene requests like **"teal on the left, blue on the right, pink above"**
  must work: understand the rig and positions, set it up, then **check it with the webcam**.
- Use the **live camera feed** to test that lights work and to find unknown lights. Camera
  input is guidance, but they mainly want to click, adjust and move things themselves.
- **Phone control by QR code**, plus a **shareable URL** for remote people. Guests must never be
  able to break the lighting or cause hiccups.
- Research every major lighting app, then build better versions with more features that are
  also far more intuitive.
- "Make it beautiful, stunning, quick to use, intuitive. Test it so that it doesn't crash."

## Non-negotiables

1. **Reliability.** No crashes or hangs. The lights never glitch because of the UI, the network
   or the assistant. Read `docs/ARCHITECTURE.md` §7.
2. **Intuitive.** Use plain language and show lights, not channels. Every precise control is
   one click away.
3. **Beautiful.** Dark, glowing, calm and polished. Liquid Glass on macOS 26, with graceful
   fallbacks on macOS 14 and 15.
4. **Honest hardware handling.** We develop on Linux and CI, never on the user's Mac. Every
   hardware or camera feature therefore needs:
   - a simulated/virtual path that is testable in CI;
   - in-app self-tests and guided checks the user can run.

## Where things are

- Architecture: `docs/ARCHITECTURE.md`.
- Working agreement: `docs/AGENTS.md`.
- Research (read what's relevant to you; it's long, so skim the TL;DRs first):
  - `docs/research/competitors.md`:
    - 44 products;
    - §2 feature checklist with P0/P1/P2;
    - §3 top 30 UX ideas;
    - §4 beginner-proof patching;
    - §5 Sidus effects.
  - `docs/research/aputure_profiles.md`: exact Aputure/amaran DMX channel maps.
  - `docs/research/fixture_libraries.md`: OFL/QLC+/GDTF and our schema.
  - `docs/research/macos_systems.md`: IOKit/serial, audio capture, Local Network, signing, etc.
  - `docs/research/macos_media_ai.md`: camera, Speech, Foundation Models.
  - `docs/research/music_reactive.md`: DSP, moods, safety.

## Team map (phase 1)

Each agent has a brief at `docs/briefs/NN-<name>.md`. **Own** means you may change these
freely. Everything else follows the shared-file rules in `docs/AGENTS.md` §4.

| Agent | Owns |
|---|---|
| library | `Resources/FixtureLibrary/**`, `tools/fixtures/**`, `Sources/PrismCore/Library/**`, `Sources/PrismCore/Fixtures/FixtureDefinition.swift`, `Sources/PrismApp/Library/**`, `docs/FIXTURE_SCHEMA.md`, `docs/THIRD_PARTY.md` |
| color | `Sources/PrismCore/Color/**`, `Engine/EmitterMixer.swift`, `Engine/FixtureRenderer.swift`, `FixtureState.mix…` helpers, `Resources/Gels/**` |
| engine | `Engine/EngineCore.swift`, `Engine/ShowSnapshot.swift`, `Engine/DMXOutput.swift`, `Command/LightingCommand.swift`, `Command/CommandExecutor.swift`, `Model/**`, `Persistence/**`, `Util/**`, `Fixtures/PatchedFixture.swift`, `Sources/PrismApp/Show/**` |
| effects | `Sources/PrismCore/Effects/**` (minus `MusicEngine`), `Sources/PrismApp/Effects/**` |
| music | `Sources/PrismCore/Music/**` (incl. `MusicEngine`, moved out of `EffectEngine.swift`), `Sources/PrismApp/Music/**` |
| hardware | `Sources/PrismCore/Output/**` (new), `Sources/PrismApp/Output/**` |
| shell | `Sources/PrismApp/App/**` (shared infra), `Main/**`, `Looks/**`, `Settings/**` (General/Safety panes and the tab list), `Design/**`, `Onboarding/**`, `Support/**` |
| stage | `Sources/PrismApp/Stage/**` |
| inspector | `Sources/PrismApp/Inspector/**` |
| patch | `Sources/PrismApp/Patch/**`, `Sources/PrismCore/Patch/**` (new), `Sources/PrismCore/Import/**` (new) |
| camera | `Sources/PrismApp/Camera/**`, `Sources/PrismCore/Vision/**` (new) |
| assistant | `Sources/PrismCore/Assistant/**` (new), `Command/FixtureSelector.swift`, `Command/SelectorResolver.swift`, `Sources/PrismApp/Assistant/**`, `Sources/PrismApp/Voice/**` |
| remote | `Sources/PrismCore/Remote/**` (new), `Sources/PrismServer/**`, `Sources/PrismDevServer/**`, `Resources/WebRemote/**`, `tools/web-test/**`, `Sources/PrismApp/Remote/**`, `Tests/PrismServerTests/**` |
| orchestrator | `.github/**`, `scripts/**`, `docs/AGENTS.md`, `docs/briefs/**` (ask for changes) |

Tests go in `Tests/PrismCoreTests/<Area>Tests.swift` and `Tests/PrismAppTests/<Area>Tests.swift`.
The owner of an area owns its test files.

## Cross-team contracts (build against these now, don't wait for each other)

1. **All changes go through `ShowController`.** Use `apply(_:)`, `updateStates`, `editProject` or
   `editLive`. Never mutate the engine directly. Add feature helpers as
   `extension ShowController` in a file in *your* folder (e.g. `Patch/ShowController+Patch.swift`),
   not in `Show/ShowController.swift`.
2. **Selectors.** The assistant team owns `FixtureSelector` and `SelectorResolver`: roles, groups,
   spatial words (left/right/top/back/floor…), fuzzy names and labels like "B3". Everyone resolves
   targets through `SelectorResolver`; nobody re-implements it.
3. **Identify/blink.** Call `app.show.identify(ids)`. The engine team implements it as a
   temporary overlay that never touches saved state.
4. **Camera API.** The camera team owns `PrismCore/Vision` and `CameraController`:
   - `ColorExpectation` (a fixture, a stage region or a camera region, plus an expected `RGB`
     and a tolerance) → `func verify(_:) async -> VerificationReport`, giving each expectation
     its measured color, ΔE, pass/fail and a plain-English hint.
   - `func snapshotJPEG(maxDimension:) async -> Data?` for cloud vision models.
   - Light Finder: set `app.camera.lightFinderRequest` to `.locate(fixtureIDs)` or
     `.scanAddresses(universe:range:)`, then present `AppSheet.lightFinder`.
   - Everything works with **no camera** (CI): methods return a clear "no camera" result
     instead of hanging.
5. **Library schema.** The library team adds `FixtureDefinition.setupGuide` plus per-mode
   `friendlyName`, `fixtureMenuName` and `recommended`. The patch team renders them and falls
   back to generic wording until they land.
6. **Effects catalog.** The effects team adds `EffectKind.info` → `EffectInfo` (title,
   systemImage, category, summary, parameter specs, `isCalm`, `flashes`) and the
   `EffectsBrowser(fixtureIDs:)` view. The inspector and the Live page embed that view.
7. **Music → engine.** The music team feeds `AudioFeatures` through `EngineCore.setAudioFeatures`
   and renders moods in `MusicEngine`. Key and fill lights are never driven by music unless the
   user opts in.
8. **Hardware → UI.** `OutputManager.summary` drives the toolbar status pill. The shell renders
   it; hardware fills it in.
9. **Remote → show.** The remote team defines `RemoteHost` in `PrismCore/Remote`, implemented by
   `RemoteController` in the app and by `PrismDevServer` on Linux. Every remote change passes
   permission checks there before reaching `ShowController`.
10. **Color API.** The color team keeps `ColorMath` and `LightColor` source-compatible and adds
    `GelLibrary` and `NamedColors`, which the inspector and assistant use.
11. **Settings, sheets, self-tests, tour.** Each team owns its pre-wired settings pane
    (`<Feature>SettingsPane`), its sheets (see `AppSheet` comments) and its
    `<Feature>SelfTest.swift` / `<Feature>Tour.swift` lists.

## Definition of done (every agent)

- Your features work end-to-end in the app, inside your ownership and contracts.
- Unit tests cover the logic; self-tests cover the app wiring; tour scenes show every screen
  and state.
- You have reviewed your screenshots and they look beautiful: no clipped text, no misalignment,
  useful empty states.
- Builds compile on macOS 14+, with newer APIs behind `#available`.
- Main CI is green with your work landed.
- You have sent a final report to the orchestrator.
