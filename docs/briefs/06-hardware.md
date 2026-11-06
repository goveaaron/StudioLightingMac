# Brief: hardware — DMX interfaces (Enttec DMX USB Pro first)

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/macos_systems.md` §1–3 and §9. It contains verified Swift code for:
  - Enttec framing and parsing, IOKit enumeration, hot-plug, termios;
  - Art-Net and sACN, UDP sockets;
  - sleep prevention.
- `docs/research/competitors.md` §2.13 and §3 (hardware health panel)

## Goal

Plug in the Enttec and it just works, instantly, every time, with honest status. Prism recovers
by itself and explains in plain English when:
- the box is unplugged and replugged;
- the Mac sleeps and wakes;
- another app is holding the port.

The user's Enttec DMX USB Pro is connected to their Mac mini right now. Your code is what
will touch it.

## You own

`Sources/PrismCore/Output/**` (new: portable framing, parsers, packet builders, writer logic),
`Sources/PrismApp/Output/**` (IOKit, serial, sockets, UI), and the hardware tests.

## Deliverables (priority order)

### 1. Enttec DMX USB Pro driver

- **Discovery:** enumerate `/dev/cu.usbserial-*` and `/dev/cu.usbmodem*` through IOKit (FTDI
  VID 0x0403 / PID 0x6001, and others per §1.9).
- **Identification:** label 10 (serial number) and label 3 (parameters: break, MAB, rate).
- **Output:**
  - label 6 at the engine frame rate, via a newest-frame slot (never queue frames);
  - `O_NONBLOCK`, `TIOCEXCL`, bounded write waits.
- **Busy port:** say in plain English "Another app is using your DMX box", and suggest quitting
  Lightkey or QLC+.
- **Recovery:** reconnect with backoff.
- **Several boxes:** bind each universe to a widget serial.

### 2. Hot-plug

- IOKit add/remove notifications; status changes within 1 s.
- Friendly toasts, e.g. "DMX box connected — your lights are live".

### 3. More interfaces

- Enttec Pro Mk2 (2 universes)
- DMXking ultraDMX (labels 77/78)
- Enttec Open DMX USB (best effort: break timing per §1.8)
- Art-Net 4 (unicast/broadcast ArtDmx, ArtPoll discovery)
- sACN E1.31 (multicast and unicast, priority)

Route each universe to one or more devices.

### 4. `OutputManager`

- **Observable status:** per device, plus the overall `summary` that drives the toolbar pill.
  Also frame counters, last error, latency.
- **Simulation** (virtual output) when nothing is connected.
- **Power:** prevent sleep while outputting (IOPM assertion, App Nap off), and re-open devices
  after wake.

### 5. Hardware Test sheet (`AppSheet.hardwareTest`)

A guided, step-by-step check:
1. "Is the DMX box plugged in?" with live detection.
2. "Send test signal": step through each patched light at 30% white, one at a time, with
   Next/Back.
3. A live 512-cell **channel monitor**: values, plus which fixture owns each channel.
4. "Blink this light".
5. Tips:
   - terminator; cable direction (DMX IN vs OUT);
   - address and mode;
   - for amaran PT tubes, the note from `aputure_profiles.md` §2.2: "listens only while the DMX
     screen is shown — hold OK 2 s to lock".

### 6. Settings pane (`OutputSettingsPane`)

- Devices with status, serial, firmware and universe assignment.
- Refresh rate.
- Art-Net/sACN configuration.
- What happens on quit (hold last look / blackout); the preference already exists.

### 7. Tests (Linux)

- Golden packet tests: label 6 for 512 channels, partial universes, start code.
- Parser tests: label 3/10 replies, resync after garbage.
- Art-Net and sACN byte-level tests against the spec offsets.
- A **pty-based simulated widget** (`openpty`) that exercises the real writer end-to-end,
  including disconnect and reconnect.

## Acceptance

- All tests pass on Linux.
- **App self-test:**
  - the virtual output receives frames;
  - with no device, the status reads "Simulation";
  - no hardware code path ever blocks the main thread or the engine tick.
- **Tour scenes:** Hardware Test (each step, with simulated devices), channel monitor,
  Outputs settings.
