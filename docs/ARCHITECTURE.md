# Prism — Architecture

Prism is a native macOS app (SwiftUI, macOS 14+) that controls DMX studio lights through
an Enttec DMX USB Pro (and Art-Net/sACN). It aims to be **more capable than Lightkey and
far more intuitive** for people who are not lighting professionals. This document is the
technical map every contributor (human or agent) must follow.

## 1. Targets

| Target | Platforms | What lives there |
|---|---|---|
| `PrismCore` | macOS + Linux | Everything that is not UI or OS-specific: models, color science, fixture library, DMX rendering, effects, music DSP, command language + natural-language parser, patch math, Lightkey import, remote protocol + guardrails, image analysis for the camera features, packet builders for Enttec/Art-Net/sACN. **Pure Swift + Foundation only.** Fully unit tested on Linux. |
| `PrismServer` | macOS + Linux | SwiftNIO HTTP + WebSocket server for the phone/web remote and REST API. |
| `PrismDevServer` | macOS + Linux | Headless engine + server + demo rig, for developing/testing the web remote (Playwright) on Linux. |
| `PrismApp` (product `Prism`) | macOS only | SwiftUI app + OS services: IOKit/serial output, Core Audio capture, AVFoundation camera, Speech, Foundation Models, CoreMIDI, App Intents, QR codes, menu bar. |

Rules:
- If code can be written portably, it goes in `PrismCore` (and gets Linux tests). The app
  layer should be thin glue + UI.
- Never use `Bundle.module`. Bundled data lives in `Resources/` and is found through
  `AppResources.url(_:)` (copied into `Prism.app/Contents/Resources` by `scripts/build_app.sh`).
- Language mode: Swift 5 (tools 5.10). CI compilers: Swift 6.3.3 (macOS, Xcode 26.6) and
  Swift 6.3 (Linux). Do not use features newer than Swift 6.3.
- macOS 26-only APIs (Liquid Glass `glassEffect`, Foundation Models, SpeechAnalyzer) must be
  behind `if #available(macOS 26, *)` with a good fallback. The app must launch and work on
  macOS 14 and 15.
- `RGB` is our sRGB color type (`RGBColor` clashes with QuickDraw on macOS — never reintroduce it).

## 2. Data model (PrismCore/Model, Fixtures)

- `Project` (saved as a `.prismlights` JSON file, UTI `com.goveaaron.prism.project`):
  fixtures (`PatchedFixture`), groups, looks (`Look`) in folders (`LookFolder`), stage
  (`StageSettings` with props, size in meters), embedded `FixtureDefinition`s used by the
  patch (so files open anywhere), music defaults, last live snapshot. **Never** contains
  machine settings, device bindings, API keys, remote links or tokens.
- `FixtureDefinition` (schema `prism-fixture/1`, see `docs/FIXTURE_SCHEMA.md` once written):
  manufacturer, model, category, physical size, modes → channels with semantic
  `ChannelKind`s, pixel cells, physical ranges (Kelvin, tint), capabilities.
- `PatchedFixture`: definition + mode, universe/address (1-based; `nil` = unpatched),
  `FixtureRole` (key, fill, back, background, practical…), `StageTransform`
  (meters, x→right, y→down/toward camera, rotation degrees clockwise), limits
  (protect faces: `allowEffects=false`), calibration, reversePixels.
- `FixtureState`: intensity 0…1, `LightColor` (rgb / hsb / kelvin+tint / …), optional
  per-cell states, strobe. `Look.states` is a `FixtureStateMap`.
- `LiveState` (not saved except as `lastLive`): base states, active look, effects, music
  settings, grand master, blackout, fades, identify flashes, raw overrides.
- `ShowDocument` = project + live. `ShowSnapshot` = immutable resolved view for the engine.

## 3. Command language — the only way to change the show

Every input — UI, assistant (typed/voice), phone remote, MIDI/OSC/HTTP, Shortcuts — produces
`LightingCommand`s (JSON-codable) that are applied by `CommandExecutor` through
`ShowController.apply(_:origin:undoName:)` on the main actor. Benefits: identical behavior
for every input, one undo history, one place for guardrails (remote, recording mode,
protect-faces, photosensitive safety).

`FixtureSelector` describes targets semantically (`.role(.background)`, `.region(.left)`,
`.named("tubes")`, `.group(id)`, `.selection`, unions/intersections) and is resolved by
`SelectorResolver` against the current patch and stage geometry.

## 4. Real-time engine

`EngineCore` renders frames at 40 fps (configurable 30–44) on its own high-priority queue:
base look + fades → effects → music layer → masters (grand master, blackout) → identify
flashes → `FixtureRenderer` (state → DMX bytes per mode, using `EmitterMixer` for color
science) → raw overrides → outputs (`DMXOutput.send`, must never block).
The UI never blocks the engine: input arrives as immutable `ShowSnapshot`s
(`engine.update`), audio as `AudioFeatures` (`engine.setAudioFeatures`), output leaves as
`RenderedFrame`s (`engine.latestFrame`, used by the visualizer at 30 fps).
Frame budget: < 2 ms for 50 fixtures × 16 cells.

## 5. App layer

- `AppModel.shared` (main actor, `@Observable`) owns: `LaunchOptions`, `AppPreferences`
  (UserDefaults `prism.*`), `LibraryStore`, `EngineCore`, `ShowController` (single source
  of truth for the document, selection, undo/redo, autosave), `UIState` (tabs, sheets,
  toasts), and services implementing `AppService { start(app:); shutdown() }`:
  `OutputManager`, `MusicController`, `AssistantController`, `VoiceController`,
  `CameraController`, `RemoteController`, `IntegrationsController`.
- Each feature lives in its own folder under `Sources/PrismApp/<Feature>/` with its
  workspace view, sheets, settings pane, `…Tour.swift` (screenshot scenes) and
  `…SelfTest.swift` (automated checks).
- Main window: toolbar (project title, workspace picker Stage/Live/Patch/Music/Camera/Remote,
  output status, music toggle, assistant, blackout), Looks sidebar (left), workspace
  (center) + bottom bar (master, fade time, status), Inspector (right).
- The app keeps running with its window closed (menu bar extra) and lights **hold their
  state on quit** by default.

## 6. Automation hooks (used by CI and by you)

- `Prism --self-test` runs every registered `SelfTest.Check` and exits 0/1 (prints
  `PASS`/`FAIL` lines). Add checks for your feature in `<Feature>/<Feature>SelfTest.swift`.
- `Prism --screenshot-tour DIR` runs every `ScreenshotTour.Scene` (setup → settle →
  capture window + sheet to `DIR/NN-name.png`) then quits. Add scenes for every screen you
  build in `<Feature>/<Feature>Tour.swift`. CI uploads them as the `screenshots` artifact —
  this is how we *look* at the UI, since we develop on Linux.
- Automated runs force `--demo` (London Studio demo rig) and `--no-hardware`. Never request
  camera/microphone/speech/screen permissions when `app.launch.isAutomated` is true.
- Other flags: `--demo`, `--safe-mode`, `--no-hardware`, `--project PATH`, `--reset`.

## 7. Reliability rules (non-negotiable)

- No crashes: no force unwraps on external data, no `fatalError`, no unchecked array
  indexing on data from files/network/devices, no `try!`. Decode defensively (see
  `ProjectIO`, `PatchedFixture.init(from:)`).
- Never block the main thread or the engine queue on I/O. Hardware and network I/O run on
  their own queues and drop frames rather than wait.
- All external input (files, remote messages, AI output, MIDI/OSC) is validated and clamped
  before it reaches the show.
- Hardware unplug/replug, sleep/wake, permission denial and missing devices are normal
  situations with friendly UI, never errors that stop the app.
- Every feature degrades gracefully when its OS capability is unavailable (older macOS, no
  camera, permission denied).

## 8. UX principles

1. Show lights, not channels. Addresses are an implementation detail Prism picks and then
   teaches (setup cards). 1-based numbers only.
2. Prism decides, the user confirms (auto-address, recommended modes, suggested roles).
3. Plain language; jargon behind "Show DMX details".
4. Everything precise is one click away: exact hex, Kelvin, tint, %, stops; arrow keys,
   ⌥-drag fine control, type-to-enter on every slider.
5. Every change is undoable and fades smoothly; nothing flashes unless asked.
6. Beautiful by default: dark, glowing, calm; Liquid Glass on macOS 26; 60 fps UI.
