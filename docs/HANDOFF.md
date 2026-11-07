# Prism — handoff to the local agent on the studio Mac

You are picking up **Prism**, a native macOS (SwiftUI, macOS 14+) DMX studio-lighting app. It
was built so far by a team of cloud agents on a Linux VM. They had **no access to the lights, the
ENTTEC box or the webcam**; macOS was only compiled and tested in GitHub Actions. You are running
on the Mac that *is* connected to all of that. Closing that gap is your job: test on the real
rig, look at it through the webcam, and fix what's wrong.

Read in this order:
1. [`docs/REQUIREMENTS.md`](REQUIREMENTS.md): the user's request, verbatim, and the
   acceptance checklist. This is the definition of done.
2. This file.
3. [`docs/AGENTS.md`](AGENTS.md): the working agreement (building, CI, landing, ownership).
4. [`docs/ARCHITECTURE.md`](ARCHITECTURE.md), and the brief for whatever area you touch
   (`docs/briefs/NN-*.md`). The research behind each brief is in `docs/research/`.

The user is not a lighting person. Explain things in plain words, keep the app intuitive, and
never make them do DMX maths.

---

## 1. Where everything is

**Repo:** <https://github.com/goveaaron/StudioLightingMac> (public).
- `main` must stay green.
- Each workstream has a branch `agent/<name>`.
- Releases are tags `vX.Y.Z` with a universal, signed `Prism.zip`.

**Installed app:** v0.9.36 is the current "latest" release. Install or update it with:
```
curl -fsSL https://raw.githubusercontent.com/goveaaron/StudioLightingMac/main/scripts/install.sh | bash
```

### Status by workstream (2026-11-07, ~14:40 PT)

| Area (brief) | On `main` | Only on its branch | Still to do |
|---|---|---|---|
| **engine** (03) | **Complete.** Thread-safe engine and bounded shutdown; cinematic crossfades (interruptible mid-fade); all commands; limits/protection for every origin; attributed undo history; `applyPlan`; atomic saves, backups in `~/Library/Application Support/Prism/Backups/`, migration, autosave and crash-resume; `.prismlook` share/import; fuzz and perf tests; `--soak` | — | Hooks for other teams: inspector sliders → `beginInteractiveChange`/`endInteractiveChange`; assistant → `applyPlan`; shell → history/backups UI |
| **color** (02) | ColorMath, 235 gels, named colours, NNLS emitter mixer v1, perceptual fades, FixtureRenderer v1 (dimmer curves, 16-bit, strobe caps ≤ 3 Hz) | Profile-based mixer, Accurate/Direct modes, calibration, Duv-based CCT↔RGB crossfade for Aputure, PT4c tint-sign fix | Land those; 16-universe perf in release; acceptance review |
| **patch** (10) | Lightkey importer, PatchMath (auto-address, conflicts, CSV), first Patch UI (universe map, patch table, channel tester, troubleshooter, address scan, profile editor, Lightkey import) | **Add Light** wizard, adaptive Patch workspace, "Fix it for me" conflict banner, multi-select (landing soon) | "Find my lights" rewrite and camera hook, plain-English import warnings, setup cards with "Test it", Blink-to-check, tour/self-tests |
| **library** (01) | Schema, setup guides, verification levels | **2,342 profiles** (curated amaran/Aputure + OFL + QLC+), lazy index, typo-tolerant search, importers (.prismfixture / OFL / QLC+ .qxf), DemoRig on real profiles (landing soon) | Library browser UI, self-tests/tour, docs |
| **music** (05) | Portable DSP (beat-tracking PLL, onsets, bands, loudness AGC, key/harmony, sections, drops), `AudioFeatures` + `BeatClock`, 16 moods + Auto, settings | Mood render kit (palettes and shaders) | **System-audio capture** + MusicController, render session, flash/slew/red safety guard, Music workspace UI, tests |
| **hardware** (06) | Older placeholder output code only | **ENTTEC Pro driver** (serial-number and parameter queries, newest-frame sending, exclusive port, reconnect), Mk2/DMXking/Open DMX/Art-Net/sACN, IOKit hot-plug, Hardware Test sheet, Outputs settings | Self-tests/tour, first macOS build, landing (ETA ~2 h) |
| **assistant** (12) | Stubs | Parser: wake phrases ("All right, light app"), colours, spatial targets (back-left…), self-corrections, scenes | Tests and landing, planner (→ `applyPlan`), voice (push-to-talk ⇧⌘K, wake phrase), camera verify, ⌘K overlay, settings |
| **inspector** (09) | Old placeholder | Exact-entry engine: hex, rgb(), HSB, "3200K +12M", CIE xy, gels; stops; pixel operations; 25 tests | All app views (Colour/White/Gel/Source tabs, pixel editor, multi-select…) |
| **stage** (08) | Old portrait stage | Geometry core: fit/zoom/pan, hit-testing, snapping and smart guides, align/distribute, label layout (fixes the B6–B8 overlap); 22 tests | Renderer, input and toolbars rewrite; tour |
| **shell** (07), **effects** (04), **camera** (11), **remote** (13), **integrations** (14), **qa** (15) | Some scaffolding | — | **Not started.** Briefs are ready in `docs/briefs/` |

**Infrastructure that works:**
- **CI** (`.github/workflows/ci.yml`) on every push:
  - Linux core tests;
  - macOS 26 build, unit tests, in-app `--self-test` and a screenshot tour of every screen;
  - a launch test on macOS 15.
- **Nightly** (`nightly.yml`): Thread and Address Sanitizer runs on Linux and macOS.
- **Release pipeline**, run with `gh workflow run ci.yml --ref main -f release=true [-f version=1.0.0]`:
  1. tag the commit;
  2. build the universal app, signed with the stable "Prism Code Signing" identity from repo secrets;
  3. install it with the real one-liner on Apple silicon and Intel;
  4. only then make it the release the installer downloads.

> [!NOTE]
> Is the cloud team still running? Ask the user. While it is, its agents keep pushing to
> `agent/*` and landing on `main`. Pull often, and don't rewrite files in an area whose agent
> is active. Instead, report what you find as a **GitHub issue labelled `field-test`** (see §5)
> and the cloud orchestrator will route it. If the team has been stopped, you own everything.
> Work the "Still to do" column in the order given in §4.

---

## 2. One-time setup on the Mac

The user does these steps; the rest is yours.
1. **Xcode**, the current version, from the App Store. Open it once to accept the license, then
   run `sudo xcode-select -s /Applications/Xcode.app`. CI uses Xcode 26.6 / Swift 6.3.
2. **GitHub access**, so you can push and use CI:
   - install Homebrew (<https://brew.sh>);
   - `brew install gh`, then `gh auth login` (pick HTTPS and log in with the browser).
3. **Clone:**
   ```
   git clone https://github.com/goveaaron/StudioLightingMac.git ~/StudioLightingMac
   ```
   Open the folder as a project in the Antigravity App.
4. **Helpers:** `brew install imagesnap ffmpeg` (webcam snapshots).
5. **Permissions:**
   - When macOS asks, allow Antigravity's terminal **Camera** access (for snapshots), and later
     Microphone.
   - Dev builds of Prism are ad-hoc signed, so macOS may ask again for Camera, Microphone and
     Screen & System Audio Recording after rebuilds.
   - The released app (one-liner) is signed with a stable identity and keeps its permissions.

---

## 3. Hardware in the loop: do this first

> [!IMPORTANT]
> The lights may be in use for a shoot. **Ask the user before taking over the rig**: blackouts,
> blinking, walking through lights. **Never strobe** (photosensitivity). Prism caps strobe at
> 3 Hz; keep any test tool within the same limit. Only one app can own the ENTTEC: quit
> Lightkey and QLC+ first.

### 3.1 Is the ENTTEC there?
```
ls /dev/cu.usbserial-*                      # one node expected; Apple's built-in FTDI driver, no install
system_profiler SPUSBDataType | grep -i -B2 -A8 -E "dmx|enttec|ft245|0403"
lsof /dev/cu.usbserial-*                    # who has the port open (should be nobody)
python3 tools/hw/enttec_smoke.py info       # serial number, firmware, break/MAB, refresh rate
```
[`tools/hw/enttec_smoke.py`](../tools/hw/enttec_smoke.py) talks to the box directly. It has no
dependencies and is tested against a simulated widget. Use it to prove the USB → DMX → light
path independently of the app:
- `set CH=V …` sends exact values;
- `blink ADDRESS v1,v2,…` blinks one fixture's channels;
- `blackout` zeroes everything.

The box keeps sending the last frame after the script exits.

If Lightkey is running with FTDI D2XX, the `/dev` node may disappear entirely; quit Lightkey and
replug the box.

### 3.2 Eyes: the webcam
```
imagesnap -l                                # list cameras
imagesnap -w 1.5 /tmp/prism-shot.jpg        # 1.5 s warm-up so exposure settles
```
Then open the image and look at it. This is the verification loop the user asked for: set the
lights, take a snapshot, check the result. Repeat.

Lock exposure and white balance if you can (UVC cameras auto-adjust and hide changes). At least
compare shots taken a few seconds apart. Take a "lights off" reference shot first.

### 3.3 What is actually plugged in: write `docs/rig.md`
1. Find the user's Lightkey project:
   ```
   mdfind -name .lightkeyproj
   find ~ -name "*.lightkeyproj" -maxdepth 6 2>/dev/null
   ```
   The format is documented in `docs/research/lightkey_format.md`. The importer is
   `Sources/PrismCore/Import/LightkeyImporter.swift`; in the app it's Patch → Tools → Import
   from Lightkey….
2. Write `docs/rig.md` with one row per light: label (P1, B1–B8, PN1), exact model, DMX mode and
   footprint, start address, position in the room, and pixel-1 end for the tubes.
3. Confirm each row on the real light: read the fixture's own menu if the user can, then check
   with `blink` and a webcam snapshot.
4. Note any light that's patched but unknown, or answers on an unexpected address. This is the
   user's "find lights that are patched that you're not sure of".

**The demo rig assumes the following — unconfirmed:**
- 8 × amaran PT4c in "9: LE CCT&RGB 8PX" (56 channels, 8 cells × 7);
- an amaran F22c panel in "CCT & RGB 8-bit" (10 channels);
- a dimmer;
- addresses P1 = 1, B1 = 2, B2 = 58, B3 = 114, B4 = 170, B5 = 226, B6 = 282, B7 = 338, B8 = 394,
  PN1 = 450;
- all on universe 1 (the ENTTEC Pro has one universe).

PT4c golden DMX for one cell (intensity, CCT, ±G, crossfade, R, G, B):

| Colour | DMX values |
|---|---|
| 3200 K at 50 % | `128,17,128,0,0,0,0` |
| red | `255,0,128,255,255,0,0` |
| teal #00C2A8 | `255,0,128,255,0,255,185` |

Prism's +tint means magenta, which is DMX tint below 128. Confirm that visually.

### 3.4 Build and run Prism here
```
swift build && swift test                        # PrismCore + app tests (macOS runs everything)
scripts/build_app.sh                             # → dist/Prism.app (debug, ad-hoc signed)
dist/Prism.app/Contents/MacOS/Prism --self-test  # must print SELFTEST PASSED
dist/Prism.app/Contents/MacOS/Prism --screenshot-tour /tmp/tour   # PNG of every screen (needs Screen Recording)
dist/Prism.app/Contents/MacOS/Prism --soak 600   # 10-minute stability run: SOAK PASSED|FAILED
```
- Other flags: `--demo`, `--no-hardware`, `--safe-mode`, `--project <file>`.
- `--reset` wipes Prism's saved state. **Never** use it on the user's real data without asking.
- `scripts/build_app.sh --release` builds an optimized app.
- To try a feature that isn't on `main` yet, check out its `agent/<name>` branch.

### 3.5 Real-rig checklists (from each workstream)
Run these as each area lands on `main`. File anything that fails as a `field-test` issue (§5).

**Hardware** (once `agent/hardware` lands):
1. Plug in the box → within ~1 s the toast "DMX box connected — your lights are live" appears and
   the toolbar pill turns green.
2. Help ▸ Hardware Test… shows "ENTTEC DMX USB Pro", the serial number from the sticker, the
   firmware and "Live".
3. Step 2 lights each patched light alone at 30 % white (Yes/No with tips). The channel monitor
   follows live.
4. Unplug → amber "DMX box unplugged" within ~1 s. Replug → live again, and the look comes back
   by itself.
5. Start Prism with Lightkey outputting → red "DMX box busy…". Quit Lightkey → it connects
   within ~2 s.
6. Settings › Outputs › Details: frames going up, ~0 skipped, ~40 fps.
7. `pmset -g assertions | grep -i prism` while live. It recovers after sleep/wake.
8. "When Prism quits": hold last look (default) or black out.

**Patch:**
- Import the real `.lightkeyproj` and compare each light's mode and address with its menu.
- Blink every row.
- Run Pixel Walk on the tubes: pixel 1 should be at the power end; otherwise use "Flip pixel order".
- Look for "Prism made a profile" warnings.

**Library:** confirm the models and modes match (the panel really is an F22c?). Use Add Light
search with the exact model names.

**Colour and inspector:**
- Type `#00C2B8`: the field keeps that exact hex, and brightness stays separate.
- White↔colour fades never flash or step; there's no pop at 1 %.
- 3200 K / +12 M on the panel versus a meter or grey card.
- A ⅓-stop nudge looks like ⅓ stop on camera.
- "Direct" `#FF00AA` gives exact R/G/B.
- Kelvin is clamped to each fixture's range.

**Stage:**
- Positions match the room and the Lightkey reference (`docs/reference/lightkey-screenshot.png`):
  P1 top-left; B1/B5 vertical; B2/B3 above them; B4 centre; B6–B8 diagonal near the feet; PN1.
- Paint a single pixel to find each tube's pixel-1 end.

**Engine:**
- Recall a look, then another mid-fade: no jump.
- Quitting blacks out or holds as set.
- Force-quit mid-edit and relaunch: the show restores.
- Protected/key/fill lights ignore effects, music and remote.
- `--soak 600` with the ENTTEC attached: PASSED, no frame over 25 ms, memory flat.

**Music** (once capture lands):
- Play Spotify or YouTube → Music → on → allow "System Audio Recording".
- Lights move within 2 s and the BPM locks within ~10 s.
- Pulses land on the kick (use Sync offset if needed).
- No strobe or harsh flashes; key/fill untouched.
- About 25 s after the music stops, the lights hand back to the look.

**Assistant** (once landed):
- ⇧⌘K, allow Microphone and Speech Recognition.
- Say: "All right, light app, warm up the background a bit. Bit more blue to the back left.
  Bring the tubes down a little. Brighten up the key a little. Bring down the fill a little."
- Every change has an Undo chip.
- "Teal on the left, blue on the right, pink above" → check with the webcam. The in-app verify
  needs the camera workstream.

---

## 4. Order of work

1. §3.1–3.3: prove the path, see the room, write `docs/rig.md`. Make the demo rig and the
   defaults match the real rig.
2. Land the in-flight branches (if their agents have stopped). Order:
   1. hardware
   2. patch
   3. library
   4. color
   5. inspector
   6. stage
   7. music
   8. assistant

   Merge `origin/main` into each one first, build, test, and push to its branch. When CI is
   green, merge it into `main`.
3. Run §3.5 on the real rig and fix what fails. A bug seen on real lights beats new features.
4. Not-started briefs, in this order:
   1. **shell** (07): onboarding, menu bar, settings, history/backups UI, app icon,
      accessibility, and graceful quit on SIGTERM (the installer relies on it). Also fix the
      known "NSTableView reentrant operation" warning in `Sources/PrismApp/Looks/LooksSidebar.swift`.
   2. **camera** (11): Light Finder, "Check my lights", the `verify` API the assistant calls,
      white-balance helper. Here you can test it for real.
   3. **effects** (04)
   4. **remote** (13): phone control via QR code and an internet URL, with guest guardrails.
   5. **integrations** (14)
   6. **qa** (15): soak, fuzz, user guide.
5. Cut a release (`gh workflow run ci.yml --ref main -f release=true`), confirm the install
   test passes, then install it on this Mac with the one-liner.

---

## 5. How to work here

- **Follow `docs/AGENTS.md`.** Small green increments; `main` always green; never force-push
  `main`.
- **CI is still the source of truth** for the screenshot tour and the clean-machine checks.
  `scripts/ci-wait.sh <branch> <sha>` waits for a run (exit 4 = still running, re-run it).
- **Don't change `.github/workflows/*` while a release run is starting.** GitHub won't let
  Actions tag a commit whose workflows differ from `main`'s.
- **Reporting real-rig findings:**
  ```
  gh issue create -l field-test -t "patch: B6 answers on 290 not 282" -b "<what you did, what you saw, snapshot path or attached photo>"
  ```
  One issue per problem, with steps to reproduce, expected vs actual, and webcam evidence.
- **Keep `docs/rig.md` and this file current** so the next agent (or the cloud team) can
  continue from here.

## 6. Known issues

- **NSTableView reentrancy warning** from the Looks sidebar list; Apple says it will become an
  assert. Fix first (shell).
- **GitHub's Intel runners** can't run Metal (`Target device architecture is nil`). That is an
  environment limit; real Intel Macs are fine. On that runner the GUI install checks are
  informational.
- **Old screenshots** show a narrow portrait stage, overlapping B6–B8 labels, an empty "No
  Selection" panel and channel-tester overflow. These are being replaced by the stage, inspector
  and patch branches. Re-check after they land.
- **Not yet built:** music capture, voice, camera, remote. See §1.
