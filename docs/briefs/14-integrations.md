# Brief: integrations — MIDI, OSC, Shortcuts, Stream Deck, URL scheme

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/competitors.md`:
  - §1.1 (Lightkey: MIDI learn, OSC with name-based addresses on port 21600, "Copy OSC Address",
    about 15 Shortcuts actions);
  - §1.7 (Blackout: Stream Deck mappings saved in the show file, "Screen Lock — ignore external
    commands");
  - §1.30–1.33 (Companion, TouchOSC; protocols, Stream Deck and voice findings).
- `docs/briefs/13-remote.md`: the remote team builds the REST/WebSocket API and the guest
  permission model. You build on top of it; don't duplicate it.

## Goal

Prism fits into any studio's existing gear with zero fuss.
- Move a fader on a MIDI controller, press a Stream Deck key, run a Shortcut, or send OSC from
  TouchOSC/QLab/TouchDesigner: the right thing happens instantly and smoothly.
- Controllers show state back (LEDs, Stream Deck key titles and colours).
- Nothing external can ever cause a flash, a strobe or a jump. External input goes through the
  same safety rules as everything else.

## You own

`Sources/PrismCore/Integrations/**` (new), `Sources/PrismApp/Integrations/**`,
`Resources/Integrations/**` (new: controller profiles, TouchOSC layout, Companion config),
`docs/INTEGRATIONS.md`, and `Tests/PrismCoreTests/Integrations*Tests.swift`.
Minimal, additive edits to shared files: `Support/Info.plist` (URL scheme), the settings tab
list (an "Integrations" pane), and `PrismCommands.swift`.

## Deliverables (priority order)

### 1. Control model (`PrismCore/Integrations/`, fully tested on Linux)

- `ControlTarget`: master, blackout, look recall (by id, name or index), role/group intensity
  (Key, Fill, Back, Background, Practicals…), fixture intensity, colour (hex) and white balance
  (Kelvin) for a target, music mode on/off/mood, fade-time preset, "next/previous look".
- `ControlBinding`: input (MIDI CC/note/pitch-bend, 14-bit CC pairs, OSC address, hotkey) →
  target, with range, curve, invert, and button behaviour (toggle / momentary / trigger).
- **Soft takeover (pickup):** a physical fader only takes control after it passes the current
  value, so moving it never makes the lights jump.
- Every resulting change goes through `CommandExecutor`, so undo/history, protection, limits and
  minimum fades apply. External sources are attributed in history ("MIDI: nanoKONTROL2").
- A global **"Ignore external control"** lock (like Blackout's Screen Lock), also respected by
  recording mode for anything that would touch protected fixtures.

### 2. MIDI (CoreMIDI, app side)

- Device discovery and hot-plug; network MIDI (RTP) and Bluetooth MIDI devices appear too.
- **MIDI learn:** click "Learn", click any fader, button or look in the app, move a control → it
  is bound. Show a pulsing outline on the learnable control.
- **Feedback:** LEDs and motorised faders follow the app (look buttons lit, master position).
- **Profiles** for popular controllers, with automatic suggested layouts when one is plugged in:
  Korg nanoKONTROL2, Akai APC mini mk2, Akai MIDImix, Novation Launchpad (X / Mini mk3),
  Behringer X-Touch Mini, and a generic 8-fader layout.
- Bindings are per machine (app settings), and can optionally be saved into the project.

### 3. OSC (Network.framework UDP; TCP optional)

- Off by default. When on, it listens on port 21600 (Lightkey's default, configurable) and
  advertises over Bonjour (`_osc._udp`).
- **Name-based address space:**
  - `/prism/look/recall "Chill Vibes 4"` (or a slug path `/prism/look/chill-vibes-4`; the
    optional float argument is the fade time);
  - `/prism/master <0…1>`, `/prism/blackout <0|1>`;
  - `/prism/role/key/intensity <0…1>`, `/prism/fixture/<name>/intensity`;
  - `/prism/fixture/<name>/color "#14D8F0"`, `/prism/fixture/<name>/kelvin 5600`;
  - `/prism/music <0|1>`.
- Wildcards per the OSC 1.0 spec.
- Feedback to registered clients.
- "Copy OSC address" in the context menu of looks, fixtures and role faders.
- A ready-made TouchOSC layout in `Resources/Integrations/`.
- Rate limiting and validation: malformed packets are ignored, never crash. Fuzz test the
  parser.

### 4. Shortcuts and Siri (App Intents, macOS 14+)

- `RecallLookIntent` with a `LookEntity` query (name search).
- `SetBrightnessIntent` (target: all / role / group / fixture; percentage or relative
  "a bit brighter").
- `SetColorIntent` (target plus hex or colour name) and `SetWhiteBalanceIntent` (Kelvin).
- `BlackoutIntent`; `MusicModeIntent` (on/off/mood).
- `AskPrismIntent`: free text routed to the assistant team's command parser (coordinate with the
  assistant agent via the orchestrator; use their public API).
- An `AppShortcutsProvider` with natural phrases ("Recall a look in Prism", "Turn on music mode
  in Prism").
- Intents work while the window is closed (Prism keeps running in the menu bar).

### 5. URL scheme `prism://`

- `prism://look/<name-or-id>`, `prism://blackout`, `prism://master?value=0.6`,
  `prism://assistant?text=warm%20up%20the%20background`.
- Register the scheme in `Info.plist`.
- Treat URL input as external, guest-level control: no protected fixtures, minimum fade, no
  strobe. Settings has a toggle to disable it.

### 6. Stream Deck and Companion

- Bitfocus Companion: a Generic HTTP/OSC configuration plus presets (looks, master, blackout,
  music) in `Resources/Integrations/companion/`, using the remote team's REST API and live
  feedback over WebSocket.
- Stream Deck: document setup with Companion, or with an OSC/HTTP plugin.
- Write `docs/INTEGRATIONS.md` with step-by-step, screenshot-friendly instructions for
  non-lighting people.

### 7. Global hotkeys

- System-wide shortcuts that need no Accessibility permission (Carbon `RegisterEventHotKey`).
  Defaults: blackout ⌃⌥⌘B, next look ⌃⌥⌘→, previous look ⌃⌥⌘←, music ⌃⌥⌘M.
- Configurable in Settings.

### 8. Settings → Integrations pane

- MIDI devices with their status, each binding (with learn/delete), and controller profiles.
- OSC enable, port, clients and address cheat-sheet.
- URL scheme toggle, global hotkeys, the "Ignore external control" lock.
- Short help links.

## Acceptance

- Core tests on Linux cover:
  - binding maths: ranges, curves, 14-bit, soft takeover;
  - the OSC parser/encoder, including fuzzed input;
  - address matching and wildcards;
  - guardrails for URL/OSC input.
- **App tour:**
  - Integrations pane, with a simulated MIDI device and bindings;
  - MIDI learn state (pulsing outline);
  - OSC cheat-sheet.
- **SelfTest:**
  - OSC loopback, which sends to itself and checks that the look recalled;
  - intent resolution for a demo look.
- No external path can produce a jump: a fade ≥ the minimum, or soft takeover.
