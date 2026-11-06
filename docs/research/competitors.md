# Prism: Competitor Research for DMX and Studio Lighting Control

**Date:** 2026-11-06
**Prepared for:** Prism, a native macOS (SwiftUI) DMX lighting controller for non-lighting people. The reference user runs a YouTube/podcast studio with Aputure/amaran pixel tubes and an LED panel on an Enttec DMX USB Pro.
**Scope:** 40+ products across six groups:
- Mac-first controllers
- pro consoles
- music, pixel and VJ tools
- fixture-manufacturer apps
- smart/creator lighting
- control-surface and integration tools

**Method:**
- Web research by a lead researcher plus four parallel research agents (pro consoles; Mac and music apps; smart and manufacturer apps; integrations and remote control).
- Sources: vendor documentation, manuals, release notes, App Store listings, GitHub repositories, and community forums (Reddit, vendor forums), mostly through search snippets.
- Facts are cited inline with URLs, and Section 6 lists the key primary sources.

> [!IMPORTANT]
> **Confidence conventions.** Items marked **(unverified)**, **believed**, **from memory**, **inferred** or **?** were not confirmed against a primary source in this pass. Check them before relying on them. Prices, versions and feature sets are as of November 2026 and change often.

---

## Executive summary

1. **Few apps can actually drive the user's Enttec DMX USB Pro on a Mac.**
   - Can: Lightkey, QLC+, ENTTEC EMU, SoundSwitch, MadMapper, ShowBuddy Active (ex-DMXIS), DMXDesktop, HitLight, and Luminair's macOS build.
   - Can't: MagicQ dropped third-party USB-DMX in 1.9.5.0. ONYX supports no third-party USB-DMX and runs on Windows only. grandMA3 onPC outputs nothing without MA hardware. Eos needs a paid Nomad key plus ETC's Gadget II. Blackout, Photon 2 and Resolume are network-only.
   - ENTTEC's own macOS compatibility list (§1.19.2) is the practical competitive set.
2. **HitLight (public beta) is the closest competitor in concept** (§1.2).
   - It offers plain-English scenes, an "Auto Show" driven by a chosen app's system audio (macOS 14.4+), an MCP server, a watchdog, and hard-coded hazard exclusions.
   - It is cloud-dependent, venue/DJ-oriented, and has no film-style colour or camera features. That gap is Prism's positioning.
   - DMXDesktop's "Live Wire" plus web remote is similar prior art for music mode.
3. **Lightkey is strong on programming and weak on approachability** (§1.1).
   - Strengths: property-based programming, presets and cues, 70+ effects, OSC (port 21600, name-based)/MIDI/Ableton Link/Shortcuts.
   - Weaknesses:
     - no phone remote and no OSC feedback;
     - Live pages are built by hand ("an evening's work");
     - a yearly subscription;
     - lights going out on quit, plus startup-state confusion;
     - volunteers who find it intimidating.
4. **"Import from Lightkey" looks feasible as a read-only importer** (§1.1.1).
   - `.lightkeyproj` is a single **NSKeyedArchiver binary plist** with private `LX*` classes, reverse-engineered by the community project `jimhoggey/Lightkey-Skill`.
   - The patch, embedded profiles, stage layout, preset colours (16-bit, packed B-G-R-A), cue timings and folders can be read.
   - Effect parameters are opaque. The CSV/TSV patch export is a stable fallback.
5. **Patching is the #1 beginner failure** (§4).
   - Common causes: missing profiles for no-name lights, mode/address mismatches, every light left on 001, and fixture-side state. amaran tubes only listen while their DMX screen is shown and the address is locked.
   - Best precedents: ONYX Auto Patch, the Lightkey/Resolume DIP-switch helpers, the QLC+ RGB-panel wizard, and Sidus Fixture Locator.
   - **No product gives model-specific "set this on your light" instruction cards or camera verification.**
6. **Film-native colour control lives in manufacturer apps, not DMX controllers** (§1.4, §1.24–§1.28, §5).
   - Sidus Link, Astera, Nanlink and Godox offer Kelvin + green/magenta tint, gels by number on a tungsten/daylight base, real-source presets, camera colour matching and CIE xy.
   - Bringing this to deterministic wired DMX, across brands, is a clear differentiator.
7. **Music mode must use live analysis of system audio** (§1.29), because pre-analysed scripts can't see Spotify or YouTube.
   - Users call automatic shows "random" and "laggy". The fixes:
     - change looks only on bar boundaries and scale pulses by beat strength;
     - use energy tiers and offer half/double tempo;
     - lock to a palette, never auto-strobe, and provide a sync-offset slider.
   - Studio-safe default: **key and fill lights never react.**
   - aubio and BTrack are GPL and Essentia is AGPL, so Prism should write its own Swift/vDSP DSP.
8. **No one offers QR-code pairing for *control* with scoped guest permissions** (§1.32).
   - Blackout's QR is view-only, and MagicQ's QR only works on its hardware consoles.
   - Lightkey has no remote at all and points users to TouchOSC.
9. **State feedback sets integrations apart** (§1.30, §1.33).
   - ETC Eos is the gold standard; Lightkey sends none, so its Companion buttons can't show state.
   - Prism should ship a Stream Deck plugin with live keys, a Companion module, a local HTTP/WebSocket API, OSC with feedback, and App Intents.
10. **Reliability is a recurring complaint category.**
    - Examples: QLC+ lost projects and look-alike Open/Save dialogs; ONYX on PC with autosave reportedly off; Luminair's "blackout on load"; grandMA3 onPC crashes; Lightkey's quit behaviour.
    - Prism should autosave continuously, keep versioned backups, resume after a crash, offer explicit quit behaviour, and run a watchdog.
11. **The AI pattern to copy:** an LLM produces an *editable artefact* (a look or rule), a deterministic engine runs it, and safety rules bind the AI exactly as they bind the UI (HitLight, Hue Custom AI Behaviors, light-mcp-server). No lighting console has voice control.
12. **Pricing sentiment:** subscriptions and layered paywalls draw complaints (Lightkey, Luminair, Photon, Blackout add-ons, Resolume renewals). Perpetual licences and fully functional free tiers (Lightjams, ShowBuddy, Photon's free 16-channel tier) earn goodwill.

---

## Contents

1. [Per-product summaries](#1-per-product-summaries) (§1.1–§1.33, indexed below)
2. [Master feature checklist](#2-master-feature-checklist) (by area, with P0/P1/P2 priorities)
3. [Top 30 UX innovations for Prism](#3-top-30-ux-innovations-for-prism-to-be-more-intuitive-than-every-competitor-for-non-lighting-people)
4. [Why DMX patching confuses beginners, and a beginner-proof patch workflow](#4-why-dmx-patching-confuses-beginners-and-a-beginner-proof-patch-workflow-for-prism)
5. [Aputure Sidus Link effects and colour tools (reimplementation reference)](#5-aputure-sidus-link-effects-and-colour-tools-reference-for-reimplementation-as-prism-software-effects)
6. [Key sources](#6-key-sources)

### Product index

| § | Product | Category | Platforms | Drives an Enttec DMX USB Pro? |
|---|---|---|---|---|
| 1.1 | **Lightkey** (+ file format, §1.1.1) | Mac DMX controller | macOS | **Yes** |
| 1.2 | **HitLight** | AI-assisted controller (beta) | macOS 14+ / Windows | **Yes** |
| 1.3 | MaestroDMX, DMXDesktop, Audio Lights DMX, MaizeDMX, Simple DMX Controller, Chromateq, Nanoleaf/WLED MCP | Other simple or AI controllers | various | DMXDesktop yes; others vary |
| 1.4 | **Aputure Sidus Link / Sidus Link Pro** (+ amaran PT specifics) | Fixture-maker app | iOS/Android; iPad/Mac (Pro) | n/a (Bluetooth; Pro outputs DMX/CRMX) |
| 1.5 | **QLC+** | Open-source controller | Win/Mac/Linux/RPi | **Yes** |
| 1.6 | **ChamSys MagicQ** | Pro console software | Win/Mac/Linux | No (removed in 1.9.5.0) |
| 1.7 | **Blackout** | iPad console | iPadOS | No (network only) |
| 1.8 | **Luminair 4** | Apple-platform controller | iOS/iPadOS/macOS/watchOS | macOS only |
| 1.9 | **Photon 2** | Wireless DMX + Hue controller | iPadOS / Apple-silicon macOS / visionOS | No |
| 1.10 | **SoundSwitch** | DJ automated lighting | macOS/Windows | **Yes** |
| 1.11 | **LightJams** | Music-reactive lighting | Windows | Yes (Windows) |
| 1.12 | **MadMapper** | Video/LED mapping | macOS/Windows | **Yes** |
| 1.13 | **Resolume Arena** | VJ software with DMX pixel mapping | macOS/Windows | No (Art-Net only) |
| 1.14 | **Obsidian ONYX** | Pro console software | Windows only | No |
| 1.15 | **grandMA3 onPC** | Pro console software | Windows/macOS | No (MA hardware required) |
| 1.16 | **ETC Eos / ETCnomad** | Pro console software | Windows/macOS | No (Gadget II or network) |
| 1.17 | **Capture** | 3D visualizer / documentation | Windows/macOS | Input only |
| 1.18 | **Sunlite Suite 3 / Daslight**, **FreeStyler**, **LightShark** | Hardware-licensed, free and browser-UI controllers | Win/Mac; Windows; any browser | No (believed); Yes (Windows); n/a |
| 1.19 | **DMXIS → ShowBuddy Active**, **ENTTEC EMU**, DMXDesktop, others | Musician and Enttec-ecosystem tools | macOS/Windows | **Yes** |
| 1.20 | **WLED** (AudioReactive) | Pixel firmware | ESP32/ESP8266 | n/a |
| 1.21 | **LedFx** | Audio → pixel engine | Win/Mac/Linux | n/a (network output) |
| 1.22 | **Philips Hue Sync / Entertainment** | Smart lighting, music/screen sync | macOS/Windows/mobile | n/a |
| 1.23 | **Nanoleaf** (Rhythm, Orchestrator, MCP) | Smart lighting | mobile/desktop | n/a |
| 1.24 | **Astera App** | Fixture-maker app | iOS/Android | n/a |
| 1.25 | **Nanlink** | Fixture-maker app | iOS/Android/Apple-silicon Mac | n/a |
| 1.26 | **Govee** | Smart lighting | mobile/Windows | n/a |
| 1.27 | **Elgato Control Center** | Creator key lights | macOS/Windows/mobile | n/a |
| 1.28 | Godox Light, ZY Vega, Litepanels, Quasar starCTRL | Fixture-maker apps | mobile | n/a |
| 1.29 | *Audio-reactivity synthesis and recommended pipeline* | — | — | — |
| 1.30 | **Bitfocus Companion** | Control-surface hub | Win/Mac/Linux | n/a |
| 1.31 | **TouchOSC** | Control-surface builder | all | n/a |
| 1.32 | *Remote and multi-user patterns* | — | — | — |
| 1.33 | *Protocols, Stream Deck, voice/AI and camera findings* | — | — | — |

---

## 1. Per-product summaries

Each entry covers what the product is, its key features, standout UX ideas worth borrowing, and common user complaints with sources. Sections are numbered for cross-reference, and the index above groups them by category.

### 1.1 Lightkey (Monospace, macOS) — the primary benchmark

**What it is.** Mac-only DMX controller aimed at musicians, churches, clubs and small venues. It's the closest thing to what Prism plans to be, and Prism's target user would most likely compare against it. Sources: https://lightkeyapp.com/en/specs, https://lightkeyapp.com/en/help, the user guide PDF (https://lightkeyapp.com/en/help → "User Guide").

**Pricing/editions.** A free edition is capped at 24 DMX channels, then roughly €79–379/year. All editions have the full feature set; only channel count (256 / 512 / 1,024 / 8,192 = 16 universes) and smart-light count differ. Licences are yearly, include updates/support, and can move between Macs (per HitLight's comparison table, verified 2026-10-17: https://www.hitlight.app/alternatives/lightkey). The current version needs a recent macOS (the spec page listed macOS 26 when we checked; HitLight notes that Lightkey needs a newer macOS than HitLight's macOS 14).

**Output and hardware.** DMX output goes through the Open Lighting Architecture (OLA). USB interfaces include **Enttec DMX USB Pro / Pro Mk2 / Open DMX USB**, DMXking, Eurolite, Jese, Robe, Stage-Profi and others. The Open DMX and some Eurolite models need an **administrator password at every launch** (driver detach). Network protocols: Art-Net 1–3 (ArtPoll; one node, up to 4 universes), sACN (multicast, priorities) and ESP Net. It controls **Philips Hue** (up to 100 lights, multiple bridges; Gradient lights only as one colour) and takes DMX-In from a physical console. (https://lightkeyapp.com/en/specs)

**Workflow model: Design vs Live.**
- **Design view** (programming): type-aware fixture selection, groups, *relative* changes across a selection, fanning, copy/paste of values **and effects between different fixture types**, per-fixture default values, a "synthetic dimmer" for fixtures without a dimmer channel, HSB colour controls, 25 colour favourites, Lee/GamColor/Roscolux gel colour library, and unlimited undo. The inspector only shows controls the selected fixtures actually have.
- **Presets.** Snapshot-style looks stored in nested groups (presets in one group can be "mutually exclusive"), with automatic names and icons. You can capture a snapshot of the current output and export/import presets. **Sequences** step through presets with hold/crossfade times, beat-controlled steps, random order and auto-reverse.
- **Live view** (playback): **Live Pages** hold cue buttons, faders, labels and frames on a free canvas. A **cue** fires a set of presets with fade-in/fade-out curves, hold time and priority (LTP). Cue *modifiers* (Speed, Beat Multiplier, Time Offset, Fade, Dimmer, Hue, CCT, Green, Pan/Tilt, Zoom…) can be mapped to faders. Buttons attached to each other act as a single-choice group (radio buttons). Buttons can toggle or flash, and their colours are *derived from the cue's contents* (a red look gets a red button). **Cue lists** have an X-fade slider, auto numbering and looping. There are **Blind** mode (edit without output), **Freeze**, and "activate at startup / at quit" cues.
- **Beat sources:** tap tempo, MIDI Clock, **Ableton Link**, OS2L (VirtualDJ).

**Effects.** 70+ effect templates. Pattern effects include Chase, Scanner, Yo-yo, Fill, Rain, Meteor, Sparkle, Fire, Jellyfish and Snakes, plus 16 curve templates (sine, ramp, square…) and 14 movement paths for moving heads. Pixel-order options cover multi-segment fixtures. Effects can be copied between fixture types.

**Fixture library and profile editor.** 7,000+ profiles with online library updates and requests through support. Profiles can be **imported from Sunlite SSL2 and FreeStyler FXT/PFF**. There are 800+ gobo images, flexible pixel-count profiles (for strips) and a profile-creation assistant. (https://lightkeyapp.com/en/fixtures, specs page)

**Patching flow.** Drag a fixture from the library onto the patch or stage. Lightkey auto-assigns the next free address and generates a short name. It warns about overlaps, can **show the DIP-switch setting for an address** (for fixtures with DIP switches), can **export/import the patch as CSV/TSV**, and can print an overview. The 2D stage editor supports shapes, trusses and background images, smart alignment guides, a "Fixture Storage" area for unplaced fixtures (v6), and **several fixture instances at the same address**.

**Visualizer.** 2D preview with virtual beams rendered through Core Animation/Metal. Fixtures glow in their output colour and beams show zoom/pan/tilt. The preview is also the selection surface.

**External control and integrations.**
- **MIDI**: learn, feedback to controllers, 14-bit, shift layers, profiles for common controllers.
- **OSC** over UDP or TCP, default port **21600**, Bonjour discovery, address patterns that match object *names*, e.g. `/live/My_Live_Page/cue/Ballyhoo/activate` (https://forum.derivative.ca/t/drive-bpm-speed-for-lightkey-dmx-software-from-touchdesigner-via-osc/413987). Right-clicking a cue → "External Control › Copy OSC Address". The OSC value sets the fade time.
- **Stream Deck** works via a third-party OSC plugin or MIDI; Lightkey's help centre documents the steps.
- **macOS Shortcuts** (about 15 actions), keyboard shortcuts, USB joysticks, DMX-In.
- **Ableton "Live Triggers"**: drag cues onto Live's timeline. ProPresenter integration is also covered in the help centre.
- A community **Home Assistant** integration over OSC exists (https://github.com/jamesarrowood/LightKeyHA).

**Safety and multi-user.** App lock via password, Touch ID or **Apple Watch**. Individual cues can be marked "Requires unlocked app", which is a primitive form of guest-safe control. There is **no native iPhone/iPad remote**: the help centre points users to TouchOSC, Duet Display or Luna Display.

**Reliability.** Autosave and unlimited undo. A common support topic is "room lights go out when I quit Lightkey" or "project opens with a different look". The user then has to choose between restoring the last state and using an "activate at startup" cue (https://glmedia.tech/technical-help/lightkey-colors-cues-priorities/).

**Standout UX ideas worth copying**
1. Controls built around fixture *properties* (colour, zoom, shutter) rather than channel numbers. The inspector adapts to what the selection supports.
2. Cue button colours derived automatically from cue contents.
3. Radio-group behaviour by physically attaching buttons.
4. "Copy OSC Address" on any object, plus name-based OSC paths.
5. Copy/paste of looks and effects across *different* fixture types.
6. Per-cue "requires unlocked app" lock.
7. Every edition is fully featured; the free tier is limited only by channel count.

**Common complaints** (Reddit, reviews)
- **Yearly subscription** is resented by hobbyists and small churches (https://www.reddit.com/r/lightingdesign/comments/1ezx7jx/).
- Permanent installs feel like "a constant fight to keep functional" (macOS updates, drivers, licence) (https://www.reddit.com/r/stagelighting/comments/1sjv3fc/).
- **Volunteers/non-technical users are intimidated**. Admins want a *restricted* control surface, so they build web UIs or TouchOSC layouts on top of Lightkey (https://www.reddit.com/r/lightingdesign/comments/1s7y64g/).
- Laying out ~90 Live buttons by hand is "an evening's work". Faders on generic MIDI controllers bind to cues, not presets.
- Cheap USB-DMX dongles need an admin password at every launch.
- No phone/iPad remote. Music-sync with tracks is harder than busking.
- Praise: responsive support, profiles for nearly everything, more approachable than pro consoles.

**What Prism must beat:** setup time from unboxing to first look; zero-programming looks (plain language, camera, templates); a native phone remote with guest permissions; colour precision (Kelvin + tint, gels, hex); system-audio music mode without loopback drivers; and pricing that doesn't punish hobbyists.

#### 1.1.1 Lightkey file formats and an "Import from Lightkey" plan

**What is publicly known.**
- **Project files:** `.lightkeyproj`, a single file and not a package. **Fixture profiles:** `.lightkeyfxt`. Lightkey doesn't publish a specification.
- A community project has reverse-engineered the project format: **github.com/jimhoggey/Lightkey-Skill** (formerly `lightkey-format`, MIT; Reddit announcement: https://www.reddit.com/r/lightkey/comments/1w8yl9n/). It has class schemas, an fpStore spec and a 30+ entry "pitfalls" list of edits that crashed Lightkey. It reads, and with care writes, real project files. Everything below comes from that project and isn't official.

**Container.** The file is an Apple **binary property list (`bplist00`) produced by `NSKeyedArchiver`**: `$version` = 100000, `$archiver` = `NSKeyedArchiver`, `$top`, and a flat `$objects` table where objects reference each other by `CF$UID` (index 0 is `$null`). Swift can open it with `PropertyListSerialization` and resolve UIDs manually. Don't use `NSKeyedUnarchiver` with Lightkey's classes, because they're private (`LX*`). A custom UID-walker is the robust way.

**Top-level (`$top`) keys observed:**

| Key | Class / content | Import value for Prism |
|---|---|---|
| `universes` | `LXDMXUniverse` → fixtures (`LXDMXFixture`) | **High:** the patch |
| `fixtureProfiles` | `LXFixtureProfile` {UUID, name, manufacturer, personalities[`LXPersonality` {name, capabilities[…]}]} | **High:** per-fixture channel layouts embedded in the project |
| `stages` | `LXStage` (2D layout, positions) | Medium: visualizer layout |
| `rootPresetGroup` | `LXRootPresetGroup` → `LXPresetGroup` (`presetsAreMutuallyExclusive`) → `LXPreset` {name, UUID, `fpStore`} | **High:** looks |
| cues/sequences | `LXCue` {fadeIn/OutDuration, holdDuration (−1 = hold), priority, intensity, presets[], activateAtStartup, requiresUnlockedApp…}, `LXSequence` | Medium: names, timings |
| `livePanels` | `LXControlPanel`, `LXCpanButton`, `LXCpanFrame`, `LXTextCanvasItem` | Low–Medium: button layout for the remote |
| bindings | MIDI / keyboard / DMX-in bindings referencing `cueUUID` | Low (could map to Prism MIDI) |
| misc | `movementPaths`, `colorFavorites`, `effectTemplates`, `appVersion`, `requiredAppVersion` (e.g. "5.9.1") | Low (colour favourites easy) |

**Fixture record (`LXDMXFixture`):** `shortName`, `address` (1-based start), `instanceCount`, `UUID`, `universeUUID`, `fixtureProfileUUID`, `personalityIndex` (the DMX mode), `flexWidth`/`flexHeight` (pixel-count profiles), pan/tilt limits, `ignoresMasterIntensity`, `comments`.

**Capabilities:** `LXIntensityCapability` (+Fine), `LXColorComponentCapability` (one per R/G/B/W/A/UV… channel), `LXShutterStrobeCapability`, `LXPan/TiltCapability` (+Fine), `LXPanTiltSpeedCapability`, `LXZoomCapability`, `LXCommandCapability`, `LXModeCapability` and `LXCustomCapability`. Each has a `channel` offset and `settings` (an array of DMX ranges with `params`). That's enough to rebuild a Prism fixture profile per mode.

**Preset payload (`fpStore`).** Each `LXPreset.fpStore` is a *nested*, ordinary binary plist (not keyed-archived). There are two schemas:
- Older: `umbrellaContainers{fixtureUUID: {definedFeatures:[…], fixtureContainer:{…}, segmentContainers:[{intensity 0…1, color:[Int64], panAngle/tiltAngle (radians), shutterState 1=open/2=strobe, strobeSpeed (Hz), coolWhite…}]}}`.
- Newer (seen in Lightkey's own showcase files): `containers{uuid:{content:{}, subcontainers:[{content:{…}}]}}` with no `definedFeatures`.

A fixture that's absent from a preset means "don't touch" (LTP layering). **Colour packing:** a 64-bit integer with four 16-bit channels, **blue in bits 0–15, green 16–31, red 32–47, alpha 48–63**, stored as a one-element array. The reverse-engineering author first got R/B swapped and painted a venue blue, so Prism should validate against a known saturated preset. Native effects sit in an `effects` array with an `effectClass` code (1000/2000/3000/6000 observed), `extent`, `pixelOrder` and an **opaque `parameters` blob that hasn't been decoded**.

**Pitfalls (from the community docs).** Lightkey compacts and renumbers the archive on save, so UIDs aren't stable. Its parser fails *silently* on unexpected classes or keys. The schema has changed between versions (a release note mentions a smaller storage format). Read-only import is therefore far safer than write-back.

**Recommended Prism import scope (read-only, best effort, versioned):**
1. **Patch:** universes, fixtures, addresses, modes (personality name and channel count), short names, pixel counts. Match each fixture to Prism's library by manufacturer + model + mode name. If there's no match, **synthesize a Prism profile from the embedded `LXPersonality` capabilities** (flagged "imported, verify").
2. **Stage layout:** fixture positions and rotations, scaled to Prism's 2D canvas.
3. **Looks:** decode every preset's static colour (16-bit RGB, plus W where present), intensity and strobe state into Prism Looks. Keep the preset group hierarchy as folders. Mutually exclusive groups map to a "pick one" folder.
4. **Cues:** import names, fade/hold times and member presets as Prism Scenes/Cues. **Effects can't be decoded**: list them as "effect not imported" and offer the closest Prism effect.
5. **Colour favourites** go to the swatch bar. **MIDI bindings** become optional suggested mappings.
6. **Fallbacks:** (a) Lightkey's documented **CSV/TSV patch export** is a stable, supported route for the patch alone. (b) Import Sunlite **SSL2** and FreeStyler **FXT/PFF** profiles the way Lightkey does, plus QLC+ `.qxf`, Open Fixture Library JSON and **GDTF**.
7. **Report:** finish with an import report ("12 fixtures, 38 looks imported; 6 effects need re-creation; 2 profiles synthesized"). **Never modify the original file.**

### 1.2 HitLight (Mac/Windows, public beta, Oslo) — the closest *conceptual* competitor

**What it is.** "DMX lighting for humans" (https://www.hitlight.app/). It's in public beta as of Oct 2026. It targets exactly the "I own lights but will never be a lighting programmer" user, which overlaps directly with Prism's target user.

**Key features** (https://www.hitlight.app/alternatives/lightkey, https://www.hitlight.app/ai-dmx-software)
- **Scenes from plain English.** "warm sunset" or "cold and moody with a blue backlight" becomes an *ordinary, editable* scene. The assistant only uses the patched profiles and current wire values; it never invents channels.
- **Auto Show.** Runs the rig live from a microphone or line input, **from a chosen app's system audio on macOS 14.4+** (Core Audio process taps), or from Pioneer CDJ/XDJ over Pro DJ Link. Nothing has to be programmed first.
- **Missing-fixture flow.** "Request it" with model, mode and DMX chart, or upload a manual or **photo of the DMX chart**. Generated profiles stay marked **draft until tested on the real fixture**.
- **3D rehearsal with no interface attached.** Patch and preview before buying hardware. A browser app authors and visualizes on any platform.
- **Collaboration:** invite collaborators. **Browser and iOS remotes** forward control to the Mac (https://www.hitlight.app/dmx-app-for-iphone-and-ipad). A virtual console of buttons, faders and XY pads can be handed to whoever is on shift.
- **MCP server** so Claude, ChatGPT or Codex can design rigs and scenes, see renders and run the lights. OAuth scopes are chosen per connection (https://www.hitlight.app/connect-ai).
- **Safety:** a native **watchdog** outside the UI latches output to an all-zero frame within 2 s if the app hangs. **Hazard channels (smoke, haze, fans, flame, pyro, blinders, UV, macros, unverified effects) are stripped from every automatic path in code.** Strobes are off by default in Auto Show. Three takeover controls: *Stop* (hold the last safe look), *Fade Out* (1 s) and *Blackout* (instant), placed next to the Auto toggle.
- Timeline editor per scene, step-through buttons, colour palettes that update every scene using them, MIDI learn (including footswitch), and lighting-plot import.
- **Pricing after beta:** Hobby/Student free (1 universe, non-commercial). Pro US\$19/mo or \$149/yr. Venue/Install \$999 per site per year. **Requires an internet connection** for sync, collaboration and AI. There's no Hue, no DMX-In and only a narrow interface list.

**Standout UX ideas**
- Separating "AI generates an editable scene" from "AI drives live from audio", and saying so openly.
- Hard-coded safety exclusions.
- A watchdog with a defined failure state.
- "Draft" status for unverified fixture profiles.
- Rehearsing in a visualizer before buying hardware.

**Weaknesses / Prism opportunities:** HitLight is beta, cloud-dependent and needs a login. It's built for venues and DJs, not video studios. There's no camera verification, no Kelvin/tint/gel-centric colour science and no Hue. **Prism should be offline-first, with on-device AI where possible, and keep video-studio colour accuracy as its core.**

### 1.3 Other notable "AI / autonomous" and simple controllers discovered

| Product | What it does | Notes / source |
|---|---|---|
| **MaestroDMX** (Limbic Media) | Standalone hardware "autonomous lighting designer in a box": listens to music, coordinates colour, dimmers and movement across the rig, 1 universe, Wi-Fi/Ethernet setup through a phone or browser. Cues can be triggered from a laptop, phone, tablet or MIDI footswitch | https://maestrodmx.com/ — proves demand for "set and forget" audio-reactive lighting without programming |
| **DMXDesktop** (Mac) | Mac DMX app that **captures the Mac's own audio on macOS 14.2+ without a loopback driver** | https://www.dmxdesktop.com/dmx-software-mac — confirms system-audio capture is now table stakes on macOS |
| **Audio Lights DMX** (App Store, Oct 2026) | Timeline cue system: drop scenes onto an audio waveform and drag edges to fine-tune timing | https://apps.apple.com/es/app/audio-lights-dmx/id6761784463 |
| **MaizeDMX** (iPad, free) | "Simple and easy to use DMX lighting control" for iPad; reviewed by YouTube AV channels | https://www.maizedmx.com/, https://apps.apple.com/us/app/maizedmx/id1600836335 |
| **Simple DMX Controller** (Windows) | Scenes, faders, timeline, effects, MIDI, GDTF import and a GDTF Maker. Free in 2-hour sessions or \$29.99/yr | https://simpledmx.net/ |
| **Chromateq** (Win/Mac/Linux/RPi/iOS/Android) | Free and paid DMX software family | https://www.chromateq.com/dmx-software-downloads/ |
| **Nanoleaf MCP server / wled-mcp** | Smart lights controlled from Claude/ChatGPT through MCP | https://www.t3.com/home-living/smart-home/you-can-now-control-your-nanoleaf-smart-lights-via-chatgpt-and-claude-heres-how, https://github.com/film42/wled-mcp |

### 1.4 Aputure Sidus Link (mobile) and Sidus Link Pro (iPad/Mac)

These are the fixture manufacturer's own apps for the user's amaran pixel tubes. They're the best reference for *film-style* colour control. Detailed effect parameters are in **Section 5**.

**Sidus Link (free, phone; Bluetooth mesh)** (https://help.aputure.com/en/sidus-link-pro/sidus-link-mobile/modes-and-functions)
- **Colour modes:**
  - **White/CCT** with G/M tint −100…+100, intensity 0–100% and a choice of dimming curve (Linear / Exponential / Logarithmic / S-curve).
  - **Dimming Design:** fade-in, continue and fade-out stages, each with begin/mid/end intensity, duration and a delay of 0–60 s.
  - **SourceType:** 17 real-world source presets, such as Candle 1900K, Tungsten 3200K, HMI 5600K and HP Sodium 2200K.
  - **SourceMatch:** the phone camera measures ambient CCT, then you trim ±300 K and G/M ±100.
  - **Gel:** CTO/CTB fractions plus 300+ LEE and Rosco gels on a 3200 K or 5600 K base, searchable by name, number or colour.
  - **HSI(C):** hue 0–359°, saturation, intensity, plus a white-point CCT of 2000–10000 K and G/M.
  - **RGB** (0–255; Pro adds **hex** entry).
  - **CIE 1931 xy** with gamut overlays (A.Gamut/BT.2020, DCI-P3, BT.709).
  - **Color Picker:** sample a colour with the camera and trim hue ±10° and saturation ±10%.
- **Effects:** up to 15 "System FX" depending on fixture class (Daylight 8 / Bi-colour 9 / Colour-Lite 9 / Colour-Pro 15), plus 7 **Pixel FX** on pixel fixtures such as the amaran PT tubes.
- **Music FX:** import MP3/AAC/WAV/M4A, analyse frequency bands and BPM, map colour to bands, store to fixture slots (FX:S, ≤120 s), run projects (FX:P, ≤30 min) or go **LIVE** from the phone microphone (https://www.sidus.link/software).
- **Scenes/presets**, groups ("group features limited to lowest common capability"), cloud sharing, collaboration via temporary verification codes, a **Fixture Locator** button (blinks the light) and onboarding guides.

**Sidus Link Pro (iPad, and Mac since 2.4)**
- Free plan: Bluetooth control. **Pro** (≈\$10/mo): DMX/CRMX output and the Action Panel. **MAX:** 4 universes over sACN/Art-Net, plus Magic Program and Magic Infinity FX.
- 2.0 restructured the app around **Projects** and added Quickshots (instant recall), cues, **auto-patching of Aputure fixtures**, battery levels and network health. 2.3 added a **3D Visualizer**. 2.4 added the Action Panel (a custom button surface), Mac support, keyboard shortcuts and local backup.
- Effect categories: System FX, **Picker FX** (live playback of colours sampled by the camera), **Magic Program** (keyframe timeline with looping), **Magic Infinity FX** (generative, non-repeating), PIXEL FX and PALETTE. Setting intensity to 0 doesn't clear an active effect (https://help.aputure.com/en/sidus-link-pro/using-effects).

**amaran PT1c/PT2c/PT4c specifics that matter for Prism**
- **Pixels:** 4 per foot, so PT1c = 4, PT2c = 8, PT4c = 16 pixels (https://www.cined.com/amaran-pt1c-pt2c-and-pt4c-pixel-tubes-introduced/). RGBWW, 2700–10000 K with ±green, CRI 95 / TLCI 98 (https://amarancreators.com/pages/amaran-pt2c).
- **On-fixture HSI:** INT 0–100%, HUE 1–360°, SAT 0–100%, white-point CCT 2700–10000 K. **CCT mode:** 2700–10000 K, G/M −1.0…+1.0 (PT manual, https://aperturent-static.s3.amazonaws.com/documents/AmaranPT2cRGBWWLEDPixelTubeLight2-ft2-LightProductionKit.pdf).
- **Wired DMX needs the separately sold "amaran USB-C to DMX adapter".** Factory DMX settings: **address 001, profile "CCT&RGB", loss behaviour "Hold Last Setting"**. Address range 1–512.
- **The fixture only listens to wired DMX while its "DMX Settings" screen is displayed.** Hold OK for 2 s to lock the address so an accidental touch can't exit DMX mode (https://help.aputure.com/en/amaran-pixel-tubes/wired-dmx-control).
- **DMX Loss Behavior** options: Hold Last / Black Out / Fade to Black (60 s) / hold for 2 min then fade (https://help.aputure.com/en/amaran-pixel-tubes/light-configuration-settings).
- Aputure documents **"basic" vs "control-channel" profiles** and, for INFINIMAT, **Standard vs "LE" (light-engine/pixel) profiles**. One profile treats the whole fixture as one cell; the other gives every pixel its own channels (https://help.aputure.com/en/education/basic-vs-control-channel-dmx-profiles, https://help.aputure.com/en/infinimat/profile-selection-and-patching-strategies). Prism's wizard should present this as "**Whole tube = one colour**" vs "**Every pixel separately (for effects)**".

**Standout UX ideas**
- SourceType presets named after real light sources.
- SourceMatch and Color Picker via the camera.
- Gel libraries with search.
- Selectable dimming curves.
- A "Fixture Locator" blink.
- Effects with 3–5 human-scale parameters (Speed 1–10, Frequency 1–10, Warmer/Natural/Cooler).
- Battery and network health surfaced in the UI.

**Common complaints**
- Bluetooth mesh resets: "studio going offline weekly" (https://www.reddit.com/r/videography/comments/wgzyvv/).
- Slow to connect, and lights **blink off on reconnect** (https://www.reddit.com/r/cinematography/comments/1c52498/).
- Locking the phone drops the connection (https://www.reddit.com/r/cinematography/comments/11o8il4/).
- Bluetooth latency.
- Wi-Fi/Ethernet setups fail on networks with client isolation or blocked mDNS (https://help.aputure.com/en/sidus-link-pro/common-connection-issues).
- Paywall for DMX in Pro.
- **This is Prism's opening:** wired DMX through the Enttec is deterministic, and Prism can give it Sidus-quality colour UX.

### 1.5 QLC+ (Q Light Controller Plus): free, open source, Win/Mac/Linux/Raspberry Pi
- **What:** Apache-2.0 DMX controller for hobbyists, bands, community theatre and installs. There are two lines: **v4** (classic Qt widgets, 4.14.x, seen as the stable one) and **v5** (new QML UI with 2D/3D preview, palettes and a beat engine; 5.3.0 released Oct 2026) (https://github.com/mcallegari/qlcplus, releases).
- **Hardware:** Enttec DMX USB Pro through the "DMX USB" plugin (FTDI D2XX; the docs warn not to install VCP drivers). Art-Net, sACN, MIDI, OSC, HID, OS2L. **RDM manager** works with the Enttec Pro and over Art-Net.
- **Patching:** an "Add Fixture" dialog (manufacturer → model → **mode** → universe, start address, **quantity**, **address gap**, name) and an **"Add RGB Panel" wizard** (rows × columns, orientation, snake/zig-zag) that creates pixel heads plus a group in one step. v5 adds a stage wizard and drag-to-2D/3D patching.
- **Fixture model:** Fixture → Modes → **Heads** (pixel cells) → Channels → Capabilities (value ranges). `.qxf` XML library, a separate Fixture Definition Editor, and Open Fixture Library export. **No GDTF/MVR import.**
- **Programming:** Functions (Scene, Chaser, Sequence, **EFX** movement, **RGB Matrix** pixel effects via JavaScript scripts, Show timeline with audio/video, Collection, Script). The **Virtual Console** is a user-built operate surface with kiosk mode. **Simple Desk** offers raw faders and keypad syntax (`1 THRU 10 AT 100`).
- **Audio:** spectrum-based "Audio Triggers" widget, a v5 beat tracker (comb-ACF), beat-based chasers, and OS2L for VirtualDJ. No timecode, no Ableton Link.
- **Remote:** built-in web server (`--web`, port 9999) that mirrors the Virtual Console over WebSocket. **HTTP Basic auth with 3 levels** (admin / VC+Simple Desk / VC only), no HTTPS. There's no REST API, only `ws://host:9999/qlcplusWS`.
- **Files:** `.qxw` XML workspace (parseable), `.qxf` fixtures. Autosave only arrived in 4.14.4 (after 30 s idle).
- **Standout UX ideas:**
  - RGB Panel wizard, and quantity + gap + next-free-address in one dialog.
  - Build vs operate separation, with kiosk mode.
  - A 3-tier web permission model.
  - A live spectrum display in the audio-trigger widget.
  - Beat-based step holds ("hold 2 beats").
- **Complaints:**
  - "V5 is a mess… UI is buggy" (https://www.reddit.com/r/lightingdesign/comments/1tlg4ip/).
  - **Crashes and lost projects**: "I've lost entire projects multiple times" (https://www.reddit.com/r/lightingdesign/comments/1orevfn/do_people_actually_use_qlc/; https://www.reddit.com/r/lightingdesign/comments/1qmvdpr/).
  - **Open and Save dialogs look identical, so users overwrite shows with blank projects.**
  - Users pin old versions.
  - No coherent learning path.
  - "Wonky on a Mac" (disk-permission prompts).
  - Forks exist out of frustration, including one adding WLED and **MCP/AI** support.

### 1.6 ChamSys MagicQ (PC/Mac/Linux; MagicVis; MagicHD)
- **What:** Professional console OS, free on a computer. Up to **64 universes of Art-Net/sACN in free "Demo"**, plus a 32,768-channel and 10,000-cue scale. Tiers: **Demo / Core / Unlocked**. MIDI, OSC, timecode, sound-card audio input and multi-user Net Sessions need **Unlocked**, which requires ChamSys hardware (≈US\$1,500 for the cheapest unlock) (https://chamsyslighting.com/software/magicq-software-licensing/).
- **Hardware:** **third-party USB-DMX (including Enttec) support was removed in v1.9.5.0** (https://www.reddit.com/r/ChamSys/comments/16la217/). Network nodes or ChamSys MagicDMX only.
- **Patching:** Choose Head (search, plus a **"Fixture finder" for unbranded fixtures**), mode, quantity, address. "Patch to free channels"; **patch now, address later**; RDM discovery and auto-patch, though RDM can't know physical order. **Head morphing** swaps a fixture type and converts programming (including CMY↔RGB). Patch offsets.
- **Library:** 28,500+ `.hed` heads, a Head Editor, **GDTF and MVR import** (improved in 1.9.8.3).
- **Programming:** Groups → Palettes → Cues → Cue Stacks with tracking. Group/palette-referenced FX recalculate when groups change. 2D/3D **pixel mapper** (images, movies, text, live feeds).
- **Visualizer:** **MagicVis**, free integrated 3D (program blind, plots, patch lists). MagicHD media player.
- **Remote:** free MagicQ Remote app (Core mode). **QR-code pairing on MQ50/70 consoles with built-in Wi-Fi, "requiring no network configuration by the user"**. Web server editing. Bitfocus Companion OSC/UDP modules.
- **Files and reliability:** `.shw` show, **`.sbk` automatic backup**, "Backup to USB". Even ChamSys admits users are "confused about the different file types".
- **Standout UX ideas:**
  - **Execute Window**, a big-button grid that can be the locked startup page for non-technical operators.
  - QR pairing.
  - Fixture finder by characteristics.
  - Head morphing ("replace my light and keep my looks").
  - ChamSys ships a separate beginner OS, **QuickQ** ("smart-phone like interface with icons and gesture support"), which validates Prism's premise.
- **Complaints:**
  - Opaque licensing (https://www.reddit.com/r/ChamSys/comments/1kdnyzf/).
  - The free mode can't use MIDI or hardware.
  - Dropped Enttec support.
  - "Similar in ability and complexity to MA… can't recommend for non-lighting techs" (https://www.reddit.com/r/ChamSys/comments/1g6gfmu/).

### 1.7 Blackout Lighting Console (iPad; v3 released Oct 2026)
- **What:** An iPad console by a working programmer (Jeff Brink). Popular with **film/TV gaffers** and Eos-like in its logic. Three App Store generations: v2 (legacy), Blackout Next (legacy) and **v3** (iPadOS 18+). Subscription: 1 universe \$15/mo or \$162/yr; 4U \$25/mo; 256U \$40/mo; MIDI-out and LivePlot add-ons \$5/mo each (https://www.newsshooter.com/2025/04/22/blackout-introduces-flexible-subscription-plans/). Two-week full trial (https://apps.apple.com/us/app/blackout-lighting-console-v3/id6767651757).
- **Output:** sACN and Art-Net 4 (per-universe priority), DMX input with merge, Bluetooth to LumenRadio MoonLite/TimoTwo (CRMX). **No USB-DMX (no Enttec Pro).** Output keeps running in the background and while the iPad sleeps.
- **Patch:** 40,000–45,000 "human-verified" profiles (Carallon-licensed) with a "Request a Profile" button. Batch address/label/sort. Patch import from Eos/ChamSys CSV, MA2/Hog/ONYX XML and **MVR**. Fixture creation from templates.
- **Programming:** a context-aware command line that "only offers what comes next". **Colour in the fixture's native model** (HSV, RGB, CMY, CIE xy; CCT shown when on the white curve). Favorites (referenced presets), Looks (cues with per-category timing), a tracking sheet with live diff, a phase-effect engine with keyframes and Bézier easing, Speed Masters with BPM/tap.
- **Film-set integrations:** **Astera native configuration plus live battery telemetry**, LumenRadio CRMX linking, and **Lit Duo meter colour matching: "point the meter at any source and your fixtures match it"**.
- **v3 pixel mapping:** NDI/RTSP/SRT/RTMP/WHIP/USB video into ACES colour-managed pixel maps. **Audio-reactive PixelMaps** bind bass, mids, highs, beat or BPM to any layer parameter.
- **LivePlot:** a live 2D plot at real intensity and colour, **shared by QR code to any browser with unlimited free view-only viewers**.
- **Control and files:** native **Stream Deck integration with mappings stored in the showfile** (Stream Deck+ encoders labelled), MIDI (USB/BLE/network), OSC, MTC, "Screen Lock — ignore external commands". `.blk` showfiles, **cloud backups, local auto-backup every 5 min**, share a showfile and invite a collaborator, partial import/merge with universe remapping and a backup before every import, and newer-version files "refused safely". An in-app "Ask PATCH" AI help assistant (inferred).
- **Standout UX ideas:**
  - QR view-only plot sharing.
  - Meter-based colour matching.
  - Stream Deck mappings saved inside the show.
  - Battery telemetry for wireless fixtures.
  - Backup before every import.
- **Complaints:**
  - Price plus a hardware chain (Art-Net node, router, CRMX transmitter).
  - "FX engine makes me miss my console", and moving lights aren't fun on a small touchscreen (https://www.reddit.com/r/lightingdesign/comments/1gon91l/).
  - Unwanted colours during crossfades (r/stagelighting thread title, Oct 2026), a sign of interpolation-path artefacts.
  - Few App Store ratings.

### 1.8 Luminair 4 (Synthe FX; iPhone/iPad/Mac/Apple Watch)
- **What:** A long-running (since 2008) Apple-platform DMX app under one subscription. Standard = 1 universe, Pro = 4 universes plus 1 Art-Net input. **Enttec DMX USB Pro protocol on macOS only.** Also Art-Net, sACN, **KiNET**, CRMX through MoonLite/TimoTwo, and **RDM over Art-Net with auto address and mode** (https://luminair.app/, https://luminair.app/pro).
- **Library and colour:** 30,000+ Carallon profiles with real units (Hz, degrees). **Replace Fixtures** keeps levels and colours when swapping models. Colour pickers for RGB, RGBAW, CMY, HSI, **XY, Gel (Lee/Apollo/GAM), CCT and Tint**, with custom swatches and print patch list.
- **Programming:** FX (Oscillator, Fire, Water, Television, Police, Alarm…) with group offset fanning, custom drawn movement shapes, scenes/sequences, **Edit Blind**, a **tap-to-bump gesture**, notes and photos on scene buttons.
- **Music:** "Sound Active" mode from the built-in mic or external audio, Inter-App Audio, tap tempo.
- **Smart home:** **HomeKit lights mixed with DMX in one project** (Hue, LIFX, Eve), HomeKit triggers, geofences, iBeacons, **URL-scheme triggers**, MIDI (USB/RTP/BLE), OSC, DMX-input triggers, an astronomical scheduler (Pro), MTC and MSC.
- **Safety:** **Lockdown Mode** per section (Face ID/Touch ID), "volunteer friendly", Apple Watch remote, documents opened in place from iCloud/Dropbox.
- **Standout UX ideas:**
  - HomeKit and DMX together.
  - Gels and tint in the colour UI.
  - Fixture replacement that keeps looks.
  - Photo or icon previews on scene buttons.
  - Per-section lockdown.
- **Complaints (App Store):**
  - Subscription switch backlash.
  - "Crashes randomly, especially when saving."
  - **"Loves to suddenly set all channels to off (BLACKOUT) when first loading a saved project."**
  - Limited effects.
  - Chaotic MIDI mapping, slow feature pace (mostly fixture-library updates through 2025).

### 1.9 Photon 2 (StudiOS; iPad, Apple-silicon Mac, visionOS)
- **What:** A wireless-only DMX and **Philips Hue Entertainment** console (Art-Net/sACN over Wi-Fi through OLA; **no USB DMX**). Tiers: Free (16 channels), Starter (\$44.99 one-time, 128 channels, BeatTracker, Ableton Link), Photon+ (subscription, 512 channels, multi-dashboard, MIDI) (https://apps.apple.com/us/app/photon-2-dmx-light-controller/id1545017671).
- **Features:** groups, scenes → sequences, a **user-built dashboard of widgets** (latch/solo radio behaviour), an automatic **mic beat tracker** that keeps working while music plays over Bluetooth or AirPlay, Ableton Link, and a fixture creator.
- **Complaints:**
  - Features locked behind a subscription even for buyers of the old Pro licence.
  - Slow feature pace.
  - Historic show-loss bug ("fixed an issue that could lead to the loss of the show").
- **Praise:** "worked right away… simplicity and value".

### 1.10 SoundSwitch (inMusic; macOS/Windows)
- **What:** DJ-centric automated lighting. Pricing: \$7.99/mo, \$79.99/yr or \$199 perpetual. Own hardware: Micro DMX Interface \$39.99 and Control One \$299.99. Outputs **DMX, Philips Hue and Nanoleaf**. Integrates with Serato, VirtualDJ, Engine DJ (including standalone **Engine Lighting** on Denon hardware) and rekordbox through the Pro DJ Link Bridge, plus **Ableton Link, MIDI Clock and MTC** (https://www.soundswitch.com/).
- **Supported interfaces include the Enttec DMX USB Pro / Pro Mk2 / Open DMX** (https://support.soundswitch.com/en/support/solutions/articles/69000847091).
- **Music model (pre-analysis, not live audio):**
  - **Autoscripting** generates a light show per track from beat-grid plus **phrase detection** (intro/verse/chorus), with Phrase Editing and Autoscript Presets.
  - **Autoloops** are the fallback for unscripted tracks: lengths of 8–128 bars, 4 banks × 32, beat-grid-synced, sequential or random.
  - Official advice: "keep things simple… solid colour loops, colour transitions and slow intensity fades work well".
- **Abstractions:**
  - **Attribute Cues** (gobo/prism/frost…) and **Position Cues**: editing one updates every script, which keeps shows venue-independent.
  - **Static Looks** layered over autoloops, with per-fixture inclusion. v2.11 (Sep 2026) added fades up to 30 s and "**Thru**" per parameter, so a look can override only one attribute.
- **Patching:** drag from the library, set the address, use Fixture Manager for custom profiles (built from the manual's DMX chart). Support adds missing fixtures if you email the manual.
- **Complaints:**
  - **"Song analysis is terrible"**, phrase detection "a beat too early or completely wrong", autoscript lights random positions, overuses white, strobes land in random places (https://community.enginedj.com/t/what-bothers-me-most-about-soundswitch/67266, https://community.enginedj.com/t/soundswich-does-not-analyze-the-phrases-correctly/65550).
  - **No half-time/double-time BPM toggle.**
  - Multicell fixtures can't be split.
  - Slow updates; hardware out of stock.
  - Beginners: "way too complicated… I made an event in 10 minutes with Lightkey, then 1 hour with SoundSwitch". Missing no-name fixture profiles are the #1 first-run failure (https://www.reddit.com/r/DJs/comments/1hlfp93/).

### 1.11 LightJams (Windows only)
- **What:** A real-time, music-reactive "interactive lighting" tool with perpetual licences (Express 512 channels \$125 … Ultimate \$450) and free updates for life. **Windows only** (the vendor tells Mac users to run Parallels). Enttec DMX USB Pro and Open DMX, Art-Net, sACN, KiNET, OSC, MIDI, **OS2L**, a VST plugin for DAW timing, and TUIO/iPad (https://www.lightjams.com/musicToDMX.html).
- **The most detailed public description of music analysis of any app:**
  - Real-time **BPM plus phase → a "BAR" value**, **break, build-up and drop detection**, and energy level.
  - 2048-band FFT shown as 120 bands or 4 bands (overall/low/mid/high).
  - A one-click "beat" checkbox outputs **beat amplitude 0–100%** (not just on/off), in cleaned, raw, average or instant modes.
  - **Up to 8 audio inputs**, **auto-gain**, a global sensitivity slider, ASIO, and loopback capture of the same PC's audio.
  - Any slider can be linked to an audio value through a music icon.
- **Interaction model:** a grid of sources and effects with formulas. Powerful but not beginner-friendly.

### 1.12 MadMapper 6 (GarageCube; macOS/Windows)
- **What:** Video and LED mapping with an integrated **MadLight** engine that maps video pixels to physical lights (RGB tubes, pixel stages, moving heads). From €399 perpetual or €39/month. The trial **blacks out DMX every 30 seconds** (https://madmapper.com/madmapper/software, https://docs.madmapper.com/madmapper/6/faqs).
- **Output:** Art-Net and sACN, USB DMX (**Enttec DMX USB Pro / Mk2**, DMXKing, garageCube). Tools include a camera-based **LED Scanner** (inferred: auto-detects pixel positions), SVG fixture-layout import/export, and DMX circle/line fixtures.
- **Control:** a master section (output masters, Freeze Engine, Freeze Output, **Global BPM**, project palette), audio FFT and beat detection, **Ableton Link**, keyboard/MIDI/DMX/OSC/audio/gamepad control lists, timelines, scenes and cues, **ICS calendar triggers**, a Mad AI extension, and project backup and recovery. An autosave "Project Data Folder" annoyed some users.
- **Standout idea for Prism:** "**Freeze output**" and global masters as one-click panic and safety tools. A **video/screen → pixel-tube mapping** mode.

### 1.13 Resolume Arena (DMX output)
- **What:** VJ software. **DMX output only in Arena (not Avenue), Art-Net only, no USB-DMX** (https://resolume.com/support/en/dmx, https://support.enttec.com/dmx/edmx-art-net-sacn-networking/using-resolume-arena-with-enttec-art-net-nodes).
- **Features:**
  - "**Lumiverse**": a virtual universe set that's prepared at home and assigned to a node at the show.
  - Fixtures are pixel "slices" sampling the video composition, with a Fixture Editor (pixel grid, colour space, snaking).
  - **Auto start-address patching, with the DIP-switch setting shown visually in the fixture info tab.**
  - **Auto Span** grows a Lumiverse to more universes; Art-Net nodes are auto-detected.
  - DMX input "shortcuts" let a lighting desk control Arena.
  - BPM sync and audio FFT can drive any parameter.
- **Standout ideas:** visual DIP-switch guidance; "prepare at home, bind to hardware at the venue"; Resolume's honest docs ("Don't use the word Lumiverse when talking to your LD buddy").

### 1.14 Obsidian Control Systems ONYX (Windows only; NX consoles, wings and nodes)
- **What:** A pro tracking console OS from the Elation group, for houses of worship, clubs and rental/touring LDs. The same software runs the NX1/NX2/NX4 consoles. The online manual covers **ONYX 4.32** (https://support.obsidiancontrol.com/).
- **Platform:**
  - **Windows only**: "ONYX runs exclusively on Windows PCs" (https://www.obsidiancontrol.com/pages/faq-brand).
  - On Apple Silicon Macs under Parallels, the Obsidian driver package fails to install (https://forum.obsidiancontrol.com/t/obsidian-control-systems-driver-package-x64-has-falled/7675).
- **Licensing ("PC modes")** (https://support.obsidiancontrol.com/Content/License_Information/Onyx_PC_Modes.htm):
  - **FREE:** outputs **Universe 1 only** over Art-Net/sACN, though you can program up to 128 universes. **OSC playback, MIDI and timecode are trial-only.**
  - **NOVA / NOVA+:** 4 universes, unlocked by an NX-DMX or NETRON node or an NX-Touch/NX-K/NX-P surface. Only NOVA+ unlocks OSC/MIDI/timecode.
  - **LIVE 8–128:** unlocked by USB keys or wings.
- **Hardware:**
  - "**No 3rd-party USB-DMX devices are supported**", so an **Enttec DMX USB Pro will not work** (same page; older builds did: https://forum.obsidiancontrol.com/t/enttec-and-onyx/5186).
  - Output goes through Art-Net/sACN nodes or the Obsidian **NX-DMX**, a 2-port USB node with RDM (https://www.obsidiancontrol.com/products/nx-dmx).
- **Patching (the best reference for a wizard)** (https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/Auto_Patch.htm):
  - The **Auto Patch** sheet browses **Manufacturer → Fixture → Mode** and shows each mode's **DMX footprint**.
  - Fields: **Amount**, **Start ID = Auto**, **Universe = Auto** (the first universe with enough free channels, with the free count shown) and **Address = Auto**.
  - A **Footprint/gap** field adds spacing. Names auto-number ("Back Truss 1, 2…").
  - A live **Universe View** fills in as you patch.
  - **Patched Types** and **History** lists give one-click re-adds.
  - A clash triggers a **conflict popup — "Unpatch Fixtures / Edit Command / Cancel Command"**, because each address belongs to one fixture only (https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/Assigning_DMX_Addresses.htm).
  - Other patch tools: Fixture Swap, a **Patch Highlight Tool**, and an "**Unassigned Channels Detected**" warning.
- **RDM:** discovery, identify, re-address, mode change, sensors and lamp hours, **scheduled RDM scans** and an exportable summary report (https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/RDM.htm).
- **Library:**
  - The Obsidian library **publishes a new package daily**, and there is an in-app Fixture Library Editor wizard.
  - **No GDTF**: Obsidian staff confirmed this in Apr 2025, adding that "Google AI says Onyx supports it… The ai machine is incorrect" (https://forum.obsidiancontrol.com/t/does-onyx-have-a-gdtf-fixture-finder/8376).
- **Programming:**
  - "**Every parameter has its own individual FX section**" (https://support.obsidiancontrol.com/Content/Onyx_Manual/Programming/FX/FX_Controls.htm).
  - The **DyLOS** pixel composer and media engine; the FREE mode gets 2 zones (https://www.elationlighting.com/blogs/news/obsidian-control-systems-announces-release-of-onyx-4-4-featuring-creative-dylos-pixel-composer).
  - Cuelists, chases, overrides and presets.
  - **No built-in 3D visualizer.** Users pair ONYX with Capture.
- **Remote and integrations:**
  - **ONYX Remote** iOS app (https://apps.apple.com/us/app/onyx-remote/id338679276) and OSC/TouchOSC.
  - A **Telnet API**.
  - Bitfocus Companion modules over Telnet and OSC (https://bitfocus.io/connections/obsidiancontrol-onyx).
- **Reliability:** consoles autosave. On PC, autosave is reportedly **off by default** (an unofficial reply in https://www.reddit.com/r/lightingdesign/comments/1my5ru2/).
- **Standout UX ideas:**
  - The Auto Patch sheet: Auto universe/address, footprint readout, quantity with auto-names, and a live universe map.
  - A three-choice conflict dialog instead of a silent overlap.
  - "Patched Types" for "add another one of these".
  - The Patch Highlight Tool, i.e. "find my light".
  - "Unassigned channels" warnings feeding a health panel.
  - Scheduled rig checks.
  - A per-parameter "animate" FX.
- **Complaints:**
  - Windows-only.
  - Crashes and freezes (https://forum.obsidiancontrol.com/t/onyx-crashing-regardless-of-show-file-or-pc/8511; https://forum.obsidiancontrol.com/t/onyx-v4-6-freezing-on-windows-11/7735).
  - **Lost cues when a stuck key overwrote them with autosave off** (Reddit above).
  - A "different paradigm" that is hard to learn (https://www.reddit.com/r/lightingdesign/comments/woefhp/onyx_vs_chamsys/).
  - Telnet connections drop for Companion users (https://github.com/bitfocus/companion-module-obsidiancontrol-onyx/issues/5).
  - MIDI/OSC are trial-only in the free mode.

### 1.15 grandMA3 onPC (MA Lighting; Windows and macOS)
- **What:** The touring/festival/TV "industry standard" console software, which is "the same on all grandMA3 devices" and available for **Windows and Mac** (https://www.malighting.com/special/grandma3-software/). The current line is v2.5.x.
- **Licensing:**
  - The software is free, but it outputs nothing without MA hardware: "We are not permitted to output anything from the grandMA3 onPC software unless we have some grandMA3 hardware that unlocks parameters" (https://help.malighting.com/grandMA3/2.2/HTML/qsg_output_dmx.html).
  - Entry hardware: the **onPC DMX-key starter** (1,024 parameters, https://www.malighting.com/product/grandma3-onpc-dmx-key-starter-4035534/) and the DMX-key (4,096 parameters).
  - Licences are counted in **parameters, not DMX channels**, a concept beginners struggle with (https://support.actentertainment.com/knowledgeBase/24775922).
  - **Enttec DMX USB Pro: no.**
- **Patching and library:**
  - Insert fixtures from the MA library, **GDTF Share (connected directly from the software)** or user GDTF files (https://help.malighting.com/grandMA3/2.5/HTML/ft_import_gdtf.html). There is a built-in fixture-type editor.
  - v2.5 added a **Channel Map** in Patch to help users who "lost track on different Modes and Fixture Types".
  - MVR import works, but fixtures arrive as "dummy" types unless GDTFs are linked (https://www.reddit.com/r/GrandMA3/comments/1j3gf0y/patch_error/).
- **Colour:** **GDTF emitter data auto-corrects colour mixing** across fixtures "for the best color matching results" (MA software page). This is the model for Prism's "same teal on every brand".
- **Programming and playback:**
  - **Phasers** are multi-step effects stored inside presets and cues "just like static values".
  - **MAtricks** (fan/wing/block selection helpers) and the **Selection Grid**.
  - **Recipes** store the "ingredients" of a look and "re-cook" it when the rig changes.
  - Executors let you assign any function to any button, fader or encoder action.
  - v2.5 added **Locate**, which finds where an object lives.
  - **Datapools** let several stages or operators share one show file through multi-user sessions.
  - A timecode editor.
- **Beginner content:** "The **MA Startshow** delivers lots of pre-programmed show elements – just patch your fixtures and start programming!" (MA software page).
- **Reliability:** a **backup show is generated on every save** (https://help.malighting.com/grandMA3/2.5/HTML/sfh_backup.html).
- **Standout UX ideas:**
  - The Startshow as a template: patch, and looks exist immediately.
  - **Recipes**, i.e. looks defined by intent that survive fixture swaps.
  - GDTF-based colour matching.
  - The Channel Map as a mode picker.
  - Locate ("where is this look/button?").
  - Effects stored as part of a look rather than a separate engine.
- **Complaints:**
  - **Crashes**, including on Mac and in 2.5.1.1 (Oct 2026) (https://www.reddit.com/r/lightingdesign/comments/wyw1k4/grandma_on_mac_crashing/; https://www.reddit.com/r/GrandMA3/comments/1xkc1za/ma3_onpc_2511_crashes/).
  - A steep learning curve (https://www.reddit.com/r/GrandMA3/comments/1r54i64/).
  - The cost of output and parameter caps (https://www.reddit.com/r/GrandMA3/comments/1kw4rw6/only_4096_onpc_for_the_future/).
  - MVR/fixture-type import friction.

### 1.16 ETC Eos family / ETCnomad (+ Augment3d, Magic Sheets, iRFR/aRFR)
- **What:** The US theatre and TV-studio standard, a command-line-driven tracking console.
  - The software installs on **Mac and PC** for offline editing.
  - An **ETCnomad USB key** turns the computer into a controller that outputs **sACN/Art-Net**, or USB-DMX through ETC's own **Gadget II** (https://www.etcconnect.com/Products/Consoles/Eos-Consoles/ETCnomad/Hardware-Specifications.aspx).
  - The Mac build needs macOS 13+.
  - The Education Package offers a 1K-output key, upgradable to 6K (https://www.etcconnect.com/Student-Package/).
  - **Enttec DMX USB Pro: no.**
- **Patching:** a channel-based patch display with command-line patching to `universe/address` (Eos notation, e.g. `2/1`). RDM through ETC gateways (believed). It is not wizard-style.
- **Colour (an excellent reference):** **Color Tools** has a picker and a **gel picker** that shows gel books, "**similar colors**", and sorting by gel book (https://www.etcconnect.com/uploadedFiles/Main_Site/Documents/Public/Video_Tutorial/Eos_Family_ColorTools_v2.3.0revA.pdf).
- **Effects and pixels:** the effects engine, **Pixel Maps** and the **Virtual Media Server** (ETCnomad specs page).
- **Visualizer:**
  - **Augment3d** is "a full **3D programming environment**", not just visualization (https://www.etcconnect.com/Eos-Experience/).
  - It has quality presets (Low → Ultra) and a live FPS/performance indicator.
- **Magic Sheets:** user-built graphical control pages with live feedback. They **can be auto-generated from Augment3d fixture positions** (https://www.etcconnect.com/Support/Tutorials/Expert-Topics/Augment3d.aspx; https://www.youtube.com/watch?v=MMd9m0aMXUI).
- **Remote:** the **iRFR/aRFR** "radio focus remote" phone apps.
- **Integrations:** OSC (widely used by Companion/TouchOSC), MIDI/MSC and timecode (believed).
- **Standout UX ideas:**
  - A gel picker with "similar colors" (Prism: "closest colour this light can make").
  - Control pages auto-built from the stage layout.
  - Visualizer quality presets with an FPS readout for laptops.
  - Free offline software for learning.
- **Complaints:**
  - Confusion over the output gate: "Confused on if I need an ETC Nomad" (https://www.reddit.com/r/lightingdesign/comments/z70gn7/).
  - Art-Net doesn't work without a key (https://www.reddit.com/r/techtheatre/comments/129yt74/).
  - Augment3d needs strong GPUs.
  - A theatre-centric command-line learning curve.

### 1.17 Capture (Capture Sweden): visualizer, design and documentation
- **What:** Real-time 3D previsualization (beams, colour, gobos, video, lasers) plus plots and paperwork, released in yearly versions (Capture 2025 came out 23 Apr 2025, https://www.capture.se/News/Post/13547/Capture-2025-released). Windows and macOS.
- **Pricing by universes** (https://www.capture.se/Products/Capture/Pricing):
  - **Solo €395** (1 universe), **Duet €795** (2), **Quartet €1,295** (4), **Symphony €2,195** (unlimited).
  - "Universe limitations apply to all aspects of Capture, including documentation."
  - Edition upgrades cost the price difference.
- **Inputs:** Art-Net, sACN, CITP and MA-Net. The **Enttec DMX USB Pro works as an *input*** (1 universe) (https://www.capture.se/Products/Capture/visualisation; https://www.capture.se/Products/2018-Revision-History). It is GDTF/MVR-oriented (believed).
- **Relevance to Prism:**
  - Pros will want to previsualize a Prism show in Capture, so Prism should **send Art-Net/sACN, including to localhost**, and later **export MVR**.
  - A built-in 2D/3D studio preview covers the ~90% of users who won't pay €395+.
  - Universe-tiered pricing is an easy-to-understand model for any paid tier.
- **Complaints:** not researched (budget). The universe caps applying even to documentation are a known limitation.

### 1.18 Budget and hardware-tied controllers: Sunlite Suite 3 / Daslight, FreeStyler, LightShark

#### 1.18.1 Nicolaudie Sunlite Suite 3 / Daslight 5
- **What:** Nicolaudie (France) sells a pro/installation line (**Sunlite**) and a DJ/entry line (**Daslight**). The software is **licensed by Nicolaudie USB/Ethernet interfaces**, e.g. SUNLITE-EC/FC; FC gives "1536 DMX channels out of the box" (https://m-s-v.eu/en/Sunlite-Suite-3-First-Class-lighting-software/SUNLITE-FC).
  - Users ask whether third-party Art-Net nodes work or whether a licence can be bought without an interface (https://forum.daslight.com/viewtopic.php?t=9783).
  - **Enttec DMX USB Pro: believed no.** It isn't on ENTTEC's compatibility list.
- **Suite 3 modules:**
  - Pages, Editor, Timelines, Cycles, Palettes, Fanning, Submasters, Console, Easy Remote, a **3D Visualizer**, **Audio analysis** and Fixtures (https://proluz.es/wp-content/uploads/2022/01/suite3_brochure.pdf).
  - Triggers: "audio, MIDI, DMX, OSC" (https://eu-litterature.n-g.co/Release/sunlite_suite_3_manual_en.pdf).
  - Stand-alone playback from the interface, with dry-contact triggers.
- **Remotes:** **Easy Remote** / **Sunlite Remote** apps (https://apps.apple.com/gb/app/sunlite-remote/id6463859051). The brochure pitches **a designer building a simple remote for "a bar owner."**
- **Standout UX ideas:**
  - The designer-built simplified remote for an end user, which maps to Prism's Host/Talent mode.
  - Scene buttons on pages, the model non-experts grasp instantly.
  - Audio-analysis timelines.
- **Complaints:**
  - "**The 128 DMX channel cap, despite having paid 180€ for a hardware interface**" (https://forum.daslight.com/viewtopic.php?t=9679).
  - Interface/driver detection failures (https://forum.daslight.com/viewtopic.php?t=9873).
  - "Not really happy with the way Sunlite Suite works" (https://www.reddit.com/r/lightingdesign/comments/8esdzr/best_lighting_controller_thats_idiot_proof/).
  - Apple-Silicon lag (https://forum.daslight.com/viewtopic.php?t=11876).
  - ADJ MyDMX 3.0 is called "just a Daslight with a different skin" (https://www.reddit.com/r/lightingdesign/comments/1670aqk/).

#### 1.18.2 FreeStyler DMX (free, Windows only)
- **What:** Community-supported freeware (https://www.freestylersupport.com/wiki/freestyler).
- **Hardware:** ENTTEC lists it as compatible with the DMX USB Pro, including **2-universe output with the Pro Mk2** (https://support.enttec.com/dmx/usbdmx/usbdmx-compatible-usb-software). Setup historically involved driver and COM-port fiddling (https://www.freestylersupport.com/fsforum/viewtopic.php?t=3102).
- **Features:**
  - Steps → sequences → cue list.
  - **Override buttons**: hold for strobe, blackout or blinder.
  - A dedicated **Sound-to-Light (S2L)** panel (https://www.freestylersupport.com/wiki/sound_2_light).
  - A fixture creator and community library, plus a 3D visualizer add-on (believed).
- **Standout UX ideas:** hold-to-flash overrides, and S2L as a small dedicated panel (input, sensitivity, which looks react).
- **Complaints:**
  - **Release semantics confuse users**: lights stay on after a sequence is stopped (FAQ video https://www.youtube.com/watch?v=bHfh2twRny4). Prism must make "what happens when I stop this" obvious.
  - Driver setup, and a dated, Windows-only UI.

#### 1.18.3 LightShark (Work Pro / Equipson): hardware consoles with a browser UI
- **What:** Standalone consoles that **serve their whole UI as a web app** to any tablet, phone or computer: the LS-1, LS-Core and LS-Core io (8 universes, Art-Net/sACN/OSC/MIDI, built-in Wi-Fi) (https://www.thomsunmusic.com/lightshark-ls-core-io; https://kennell.it/wp-content/uploads/2020/03/LIGHT-SHARK-LS-1_manual.pdf).
  - A USB host accepts generic MIDI surfaces as physical faders.
  - The fixture editor "**with support for virtual dimmer**" (https://www.long-mcquade.com/116994/Pro-Audio-Recording/Lighting/Work-Pro/LightShark-LS-Core-DMX-Lighting-Console.htm).
  - LS-Node RDM/Art-Net nodes.
- **Standout UX ideas:**
  - Zero-install browser control from several devices at once, i.e. Prism's QR web remote.
  - A **virtual dimmer** for modes without a master intensity channel. Prism should always synthesize a master brightness.
  - Plug-and-play MIDI controllers.
- **Complaints:** not researched.

### 1.19 Musician and Enttec-ecosystem tools: DMXIS → ShowBuddy Active, ENTTEC EMU, DMXDesktop and others

#### 1.19.1 DMXIS → ShowBuddy Active (db audioware; macOS/Windows)
- **History:** **DMXIS** was an Enttec USB interface bundled with db audioware software that **only the DMXIS interface could unlock**. The hardware is discontinued and the software unsupported (https://support.enttec.com/legacy-product/legacy-products/dmxis-70570-legacy-product; https://www.dmxis.com/what-happened-to-dmxis/). Being tied to one dongle stranded users when it was discontinued (inferred).
- **Successor: ShowBuddy Active** (https://www.dmxis.com/show-buddy-active/)
  - Runs on macOS 10.12+ and Windows 10+.
  - **Perpetual licence, no subscription; the demo is fully functional.** Editions: Active (2 universes), Projection (+video) and Max (16 universes).
  - Hardware: Enttec **DMX USB Pro / Pro Mk2** (1 universe on the Mk2), Open DMX, Art-Net, and DMX KING MAX (8 universes, v2.4.1, Oct 2026).
- **Key features:**
  - Runs standalone **or as a VST/AU plug-in in Ableton Live/Logic**, so lighting is automation on the song timeline.
  - The **2D Visualiser + Light Show FX Engine**: you **draw effects onto the 2D plan**, and the effects are **independent of fixtures**, so moving or adding lights needs no reprogramming. Effects sync to tempo or audio.
  - Performance buttons, fast patching, and TouchOSC/MIDI control.
- **Standout UX ideas for Prism:**
  - **Effects defined on stage geometry/roles, not channels.** A left→right sweep keeps working after you add a tube.
  - A perpetual licence with a full demo.

#### 1.19.2 ENTTEC EMU (ENTTEC's own app; macOS 10.13+/Windows)
- ENTTEC markets it as "Free Lighting Software for Musicians and DJs". The premium/perpetual licence covers 2 hardware IDs with "**32 universes, VST3, MIDI**" (https://www.enttec.com/product/dmx-lighting-control-software/emu-sound-to-light-controller/).
- ENTTEC promotes it for **sound-to-light** (https://support.enttec.com/dmx-software/emu/how-to-make-lights-react-to-music).
- It is the app an Enttec USB Pro buyer meets first, so it is **Prism's most direct free competitor for music mode**. Feature depth wasn't verified in this research.
- **ENTTEC's macOS compatibility list is Prism's real competitive set for the user's interface** (https://support.enttec.com/dmx/usbdmx/usbdmx-compatible-usb-software, updated 26 Oct 2026):
  - EMU, Lightkey (2 universes with the Pro Mk2), QLab 5, QLC+, LXConsole, Chameleon, D::Light, FootLight, Lightning DmxControl, MadMapper, MaizeDMX, Millumin, liveShowsoftware.
  - Capture appears as input only.
  - ENTTEC also keeps a macOS article on "software not recognizing DMX USB Pro" (https://support.enttec.com/dmx/usbdmx-dmx-usb-pro-70304/macos-software-not-recognizing-dmx-usb-pro), so detection problems are common enough to warrant guided diagnostics in Prism.

#### 1.19.3 DMXDesktop (Mac/Windows; "SoundSwitch alternative")
(Also listed in §1.3.) Vendor claims (https://www.dmxdesktop.com/):
- **Live Wire** listens to "whatever's playing… **No DJ software. No analyzed tracks. No programming**", following tempo, energy, mood, build-ups and drops. It captures Mac audio on macOS 14.2+ without a loopback driver.
- **Autonomous/DJ modes:** you pick a colour theme and **which groups may strobe**.
- **QuickShow:** pick fixtures plus an effect style.
- **Patching help:** **Channel Groups auto-detect RGB/RGBW/pan-tilt channel patterns**, plus ~30k profiles, a Profile Builder, and RDM over Art-Net or the Enttec Pro. One testimonial: "within 10 minutes my fixtures were patched".
- **Output:** 3D visualizer (Pro), cloud backups, USB DMX / Art-Net / sACN.
- **Control:** MIDI, OS2L, OSC, **Ableton Link**, plus an iOS/Android app **and a built-in web server for phone control**.
- **Takeaways:** this is direct prior art for Prism's no-setup music mode plus phone remote. Prism must therefore win on studio focus (protected key/fill, Kelvin/tint, camera safety) and native polish.

#### 1.19.4 Others noted
- **ENTTEC ELM 2026:** a 2D/3D LED pixel mapper over Art-Net/sACN ("Start free"; a free licence comes with ENTTEC pixel controllers). It is not a fixture console (https://www.enttec.com/product/dmx-lighting-control-software/pixel-mapping-software/).
- **Chauvet DJ ShowXpress:** free (Win/Mac), paired with Chauvet Xpress interfaces. An old macOS **App Nap** issue disrupted DMX output (https://www.chauvetdj.com/showxpress/). **Lesson:** Prism's output thread must opt out of App Nap/timer coalescing while lights are live.
- **StageLight – DMX Controller:** iPad, free + IAP, Art-Net plus LumenRadio Bluetooth DMX (https://apps.apple.com/us/app/stagelight-dmx-controller/id1118851633).
- **MaestroDMX:** a US\$899 standalone box for autonomous music lighting (see §1.3).

### 1.20 WLED (+ AudioReactive / WLED-SR / WLED-MM): open-source pixel firmware
- **What:** Free ESP32/ESP8266 firmware for addressable LEDs, with a web UI and iOS/Android apps. It *receives* sACN/Art-Net/DDP and can do DMX in/out over RS-485. The "Sound Reactive" fork became the official **AudioReactive** usermod (built in since 0.15) (https://kno.wled.ge/advanced/audio-reactive/).
- **Effects model:** 180+ effects. Each effect exposes **Speed, Intensity**, up to 3 custom sliders, 3 colour slots and a **palette** (~70 built in). **Segments** split a strip into independent zones. **Presets and playlists** (per-entry duration and transition), a global transition time, a JSON/HTTP/WebSocket/MQTT API, and **UDP sync on port 21324**.
- **Audio design (directly reusable):**
  - Squelch (noise gate) → Gain (0.1×–6.5×) → **AGC presets with plain names: Normal / Vivid / Lazy**.
  - The docs say plainly that **"Peak detection is NOT beat detection."**
  - 16 GEQ bands at a 10,240 Hz sample rate.
  - **Audio-reactive palettes**, so *any* palette-based effect becomes music-reactive.
  - A documented calibration recipe: raise squelch in a quiet room, then set gain with music, then enable AGC.
  - Network audio sync on UDP multicast 239.0.0.1:11988.
- **Complaints:**
  - Squelch, gain and AGC interplay confuses users; AGC "goes crazy" in quiet passages (https://www.reddit.com/r/WLED/comments/1wzryc9/).
  - A reboot is needed after changing the mic type.
  - The DMX-effect channel map broke in 0.14 (version your personalities!).
- **Ideas for Prism:**
  - A calibration wizard with a live meter.
  - Named AGC personalities.
  - "Make any effect music-reactive" by modulating its palette or speed.
  - Animated effect thumbnails.
  - Pixel "segments" mapped onto tube zones.

### 1.21 LedFx (open source, Python; Win/Mac/Linux)
- **What:** A network LED effect engine that turns live audio into pixel effects. It streams to WLED (DDP), sACN, Art-Net, Hue, LIFX, Nanoleaf, Govee, OpenRGB, OSC and more. Browser UI on :8888 (https://github.com/ledfx/ledfx).
- **Features:** about 70 effects. **"Virtuals"** span effects across devices. Scenes and playlists. **8 transition modes** (Dissolve, Push, Slide, Iris, Through White/Black…, default 0.4 s). **Silence scene**: after 5 s of silence it switches to a chosen scene and restores it when audio returns. **Power-source selector in plain words: Beat / Bass / Lows / Mids / High.** A **delay_ms** latency compensation of 0–5000 ms for Bluetooth/AirPlay. REST v2 and WebSocket APIs.
- **Audio pipeline (from source code; good defaults for Prism):**
  - 30 kHz internal rate, 60 analysis frames/s, FFT 4096.
  - 3 mel filterbanks (24 bins each: 20–350 Hz, 20–2 kHz, 20–15 kHz).
  - Band edges: beat ≤100 Hz, bass ≤250, mids ≤3 k, high ≤10 k.
  - Asymmetric exponential smoothing (rise 0.99 / decay 0.7). AGC (rise 0.99 / decay 0.01).
  - aubio onset (hfc) + aubio tempo, giving **beat and bar oscillators** (phase 0–1 between beats).
  - A volume-beat detector (+50% over a 0.2 s mean, with a 100 ms refractory period).
- **Complaints:**
  - **macOS system audio needs BlackHole** plus an Audio MIDI Setup multi-output device. This is the top support topic (https://docs.ledfx.app/en/latest/settings/directing_audio.html).
  - Network jitter with many pixels.
  - Too many knobs without previews.
- **Prism opportunity:** native capture through **Core Audio process taps (macOS 14.2+/14.4+)**, with no driver (https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps).

### 1.22 Philips Hue Sync / Hue Entertainment (the consumer benchmark for music and screen sync)
- **What:** The Hue ecosystem (Zigbee lights, Bridge or Bridge Pro) with the **Hue Sync desktop app** (Mac/Windows), the Hue Sync TV app, the HDMI Sync Box and Spotify integration. **A Bridge is required** for Entertainment. There is no DMX, but there are open bridges such as artnet-hue-entertainment (https://github.com/jeffreykog/artnet-hue-entertainment).
- **Entertainment API:** a **DTLS 1.2 PSK UDP stream to the bridge on port 2100 ("HueStream")**, 16-bit RGB or xy per channel.
  - Clients send ~50–60 Hz and the bridge relays over Zigbee at ~25 Hz (https://iotech.blog/posts/philips-hue-entertainment-api/).
  - An **Entertainment area is a 2D room map of lights placed around a TV icon**.
  - Historically about 10 lights per area (uncertain for current bridges).
- **CLIP v2 REST:** xy colour with gamut A/B/C, colour temperature in **mirek 153–500**, brightness 0–100%.
- **Hue Sync desktop** (release notes: https://www.philips-hue.com/en-us/support/release-notes/hue-sync):
  - Video, Game and Music modes, with **Intensity Subtle / Moderate / High / Extreme** and Brightness kept separate.
  - **Per-app audio capture on Mac** plus mic input (v1.4).
  - A **delay setting exists for display sync but not for music**.
  - Stream Deck support (v1.12) and AI game-event effects (v1.13, Sep 2025).
- **Spotify sync** uses **pre-computed light scripts from track metadata** rather than live audio. Spotify closed its Audio Features/Analysis endpoints to new apps in Nov 2024 (from memory), so this route is closed to Prism.
- **AI:**
  - The Hue AI assistant generates scenes from typed or spoken prompts. It was announced at CES 2025 and rolled out from mid-2025 (https://hueblog.com/2025/05/31/hue-ai-assistant-officially-rolling-out/).
  - **Custom AI Behaviors** (Oct 2026, Bridge Pro) turn prompts into automations; the AI runs in the cloud and the engine runs locally. Hueblog notes it sometimes switched on extra lamps (https://hueblog.com/2026/10/29/custom-ai-behaviors-launched-in-the-philips-hue-app/).
- **Standout UX ideas:**
  - **Four named intensity presets** instead of DSP parameters.
  - A Listen-to (per-app) source picker.
  - A 2D entertainment-area map.
  - Brightness kept independent of reactivity.
- **Complaints:**
  - Amplitude-driven music sync looks random, or "just on" with compressed masters (https://www.reddit.com/r/Hue/comments/1b3fv2m/).
  - "Subtle is the only enjoyable one" (https://www.reddit.com/r/Hue/comments/q87tok/).
  - Lights run **~100 ms ahead of AVR audio with no music delay setting** (https://www.reddit.com/r/Hue/comments/oprzba/).
  - Spotify sync drifts ~0.4 s and stops when the phone sleeps.
- **Prism takeaway:** optional Hue output for practicals or background lamps, through the Entertainment API (P2). Copy the intensity-preset UX, and fix the missing **music sync offset**.

### 1.23 Nanoleaf (Rhythm, Desktop app, Orchestrator, AI/MCP)
- **What:**
  - Hardware: panels, strips, bulbs and the 4D screen-mirror camera kit.
  - Apps: the Nanoleaf mobile app and the **Desktop app (Windows 11 / macOS 13+)**.
  - Connectivity: Wi-Fi plus Thread/Matter. No DMX.
  - A **local OpenAPI** (REST on port 16021 with a token created by holding the power button, plus UDP "extControl" streaming; from memory).
- **Features:**
  - **Scenes = palette + motion** (Flow, Wheel, Fade, Highlight, Random, Explode…) with speed, transition and direction. A **layout view mirrors the physical arrangement**, so motions are spatial (https://nanoleaf.me/en-us/blogs/general/everything-you-need-to-know-about-nanoleaf-scenes).
  - Rhythm uses the controller mic.
  - **Orchestrator** (Premium subscription) **captures system output directly** (Spotify/Apple Music/YouTube). Its only controls are **Beat Detection, Mood & Colour Palette, Sensitivity and a Sound Source tab** (https://support.nanoleaf.me/hc/en-us/articles/36106561315604).
  - **Engine DJ** integration sends track and beat data from DJ software.
  - AI text-to-scene, and a **"Nanoleaf MCP — AI Agent"** for Claude/ChatGPT control (https://nanoleaf.me/en-int/pages/nanoleaf-ai-technology).
- **Standout UX ideas:**
  - Four human-language music controls.
  - A **Sound Source picker**.
  - Layout-aware motions.
  - An MCP server as the AI integration surface.
- **Complaints:**
  - **Rhythm mic lag ~100–200 ms** (https://www.reddit.com/r/Nanoleaf/comments/10c4uq7/).
  - The mic needs loud music (https://www.reddit.com/r/Nanoleaf/comments/bregej/).
  - Line-in or direct capture syncs better than the mic (https://www.reddit.com/r/Nanoleaf/comments/mr2hkj/).
  - The best music mode is behind a subscription.

### 1.24 Astera AsteraApp (pro wireless tubes; iOS/Android, free)
- **What:**
  - The app controls Astera Titan/Helios/Hyperion tubes and other fixtures over **Bluetooth through a Bluetooth Bridge**: the ART7 AsteraBox (CRMX + DMX in) or the AsteraBox WIFI (https://astera-led.com/app/; https://astera-led.com/bluetooth-bridge-btb/).
  - **Lamps run effects locally**, so playback survives app disconnects.
- **Colour (the best film-colour UX found):**
  - Wheel, HSI, CCT + G/M, sRGB and **CIE xy entry**.
  - **Double-click any slider to type an exact value.**
  - **"Copy RGB values" to hand to a console.**
  - Per-lamp calibration.
  - **Lee/Rosco gels searchable by number, applied on a Tungsten or Daylight base.**
- **Effects:**
  - Classic and **Film-maker effects** (police, paparazzi, fireworks…).
  - **Layer effects**, which stack effects on top of each other (https://astera-led.com/academy/layered-effects/).
  - **Several lamps can be combined into one virtual fixture.**
  - Hold-to-flash buttons, and beat matching from the ART7 mic.
- **Organization:** Programs, up to 256 groups, Scenes, **backup & handover** of projects to another device, offline manuals/DMX charts, and firmware updates.
- **Standout UX ideas:**
  - Gel-by-number on a chosen base.
  - Typed values on any slider.
  - Copy values out.
  - A virtual fixture across many tubes.
  - Layered effects.
  - Handover of a project between operators.
- **Complaints:**
  - Slow to connect, with random disconnects (App Store reviews, https://apps.apple.com/app/id1367867800).
  - Confusion about needing the bridge box.

### 1.25 Nanlink (Nanlite/Nanguang; iOS/Android, also on Apple-silicon Macs)
- **What:**
  - Controls Nanlite fixtures over **Bluetooth or a 2.4 GHz transmitter box** (https://apps.apple.com/us/app/nanlink/id1584085006).
  - The fixtures themselves also take wired DMX/RDM, and some take CRMX.
  - No music mode and no API.
- **Modes:**
  - **CCT with G/M ±150**, HSI and RGBW, with dimming in 0.1% steps.
  - **Gel**: 151 gels, or 460 on the FC-1200C.
  - **Effects (15):** INT Loop, CCT Flash, Hue Flash, CCT Pulse, Hue Pulse, Hue Loop, Storm/Lightning, Police Car, TV, Paparazzi, Candle/Fire, Disco, Bad Bulb, Firework, Explosion, Welding.
- **Organization:** a **"Scene = a place"** container with groups, and a distinction between **Fixture Preset and Scene Preset** (https://www.nanlink.com/en/h-col-215.html).
- **Anti-pattern:** **moving a fixture to another scene or phone requires a Bluetooth reset on the fixture itself** (https://www.nanlink.com/en/h-col-293.html).
- **Complaints:** "Lights don't consistently connect… the transmitter box can't control both HSI & CCT" (Mac App Store reviews).
- **Prism takeaway:**
  - Copy the effect vocabulary (it overlaps with Sidus; see §5).
  - Copy Fixture-vs-Look presets.
  - Copy "project = studio location".
  - **Never require physical resets to move a light between projects.**

### 1.26 Govee (Govee Home, DreamView, Music Sync Box)
- **What:**
  - Cheap RGBIC strips and bars over Wi-Fi/Bluetooth, with a **cloud developer API and a LAN UDP JSON API** (multicast discovery on 239.255.255.250:4001; from memory).
  - The **Music Sync Box** drives up to 7 devices from its own mic (https://us.govee.com/products/govee-music-sync-box).
- **Features:**
  - **Named music modes**: Energic, Rhythm, Spectrum, Rolling, Separation, Piano Keys, Day and Night, Hopping, Fountain, Shiny, Sprouting. Each comes with a **sensitivity** slider (https://community.govee.com/posts/govee-home-v-430-is-here-experience-all-the-new-fe/45674).
  - **Music DreamView** syncs several devices from the phone mic, but the phone must stay on the music page.
  - A DIY editor with per-segment control.
  - A huge scene library.
  - An AI Lighting Bot (unverified).
- **Standout UX ideas:**
  - Pick music modes **by look (thumbnail)**, not by parameters.
  - One listening hub drives a group.
  - A segment editor for pixel tubes.
- **Complaints:**
  - Laggy or irregular sync (https://www.reddit.com/r/Govee/comments/163tumk/; https://www.reddit.com/r/Govee/comments/1ht9ecq/).
  - The app must stay open (https://www.reddit.com/r/Govee/comments/1q0lbro/).
  - Choppy, flickering effects (https://www.reddit.com/r/Govee/comments/1rtknsg/).

### 1.27 Elgato Control Center (Key Light family; the closest *audience* to Prism)
- **What:**
  - A free app for macOS/Windows/iOS/Android that controls Key Light, Key Light Air/Mini/Neo, Ring Light and Light Strip over **2.4 GHz Wi-Fi**.
  - Each light has **power, a Brightness % slider and a Temperature slider, and nothing else**: no tint, no gels and no effects on the Key Lights.
- **Local REST API:**
  - Endpoint: `http://<ip>:9123/elgato/lights` with JSON `{"on":1,"brightness":0–100,"temperature":143–344}`. **Temperature is in mireds** (143 ≈ 7,000 K, 344 ≈ 2,900 K).
  - Also `/elgato/identify` (blink) and power-on/fade settings.
  - Discovery via Bonjour `_elg._tcp` (https://gist.github.com/sebinside/4812d8979764f4ef8a6c7fb796f285e7; partly from memory).
  - A Companion module exists (https://bitfocus.io/connections/elgato-keylight).
- **Stream Deck:** a **first-party plugin**, including dials with live value feedback on Stream Deck + (https://www.elgato.com/eu/et/explorer/products/lighting/how-to-control-your-key-light-with-stream-deck/).
- **Standout UX ideas:**
  - **Radical simplicity** (two sliders), which suits Prism's "Quick" view for key/fill lights.
  - An **Identify** button.
  - A configurable power-on state and default fade.
  - Stream Deck dials with feedback.
- **Complaints:**
  - **Lights drop off Wi-Fi and have to be re-added** (https://www.reddit.com/r/elgato/comments/112ayek/; https://www.reddit.com/r/elgato/comments/12tlult/).
  - The CCT range is limited to 2,900–7,000 K.
  - No colour or tint on Key Lights.
- **Prism takeaway:** support Elgato lights as a non-DMX output (P2) so that a creator's whole room appears in one app.

### 1.28 Other manufacturer apps: Godox Light, Zhiyun ZY Vega, Litepanels, Quasar starCTRL
- **Godox Light 4.0 (iOS/Android):**
  - Connects over Godox mesh Bluetooth, with **NFC tap-to-pair** ("Connect in a Click").
  - Modes: **CCT, HSI, RGB, CIE xy, Gels**, **Photo Colour Match** and FX.
  - **List Mode vs Studio Mode** (a visual layout), plus layout sharing (https://www.godox.com/product-e/Godox-Light-App.html).
  - **Complaint:** lights only appeared after the user granted an unexplained OS permission.
  - **UX ideas:** one-tap pairing, list vs spatial views, photo colour match.
- **Zhiyun ZY Vega (iPhone only, 2.3★):**
  - Set management with a **grid layout for device positioning**.
  - **CT filters on tungsten or HMI bases**.
  - **Camera-based ambient CCT matching** and camera colour picking (https://apps.apple.com/us/app/zy-vega/id6444816284).
  - **Complaints:** fixture FX are missing from the app, RGB was broken on one model, and the developer's fix for pairing was "click the power button three times to reset the Bluetooth".
- **Litepanels Gemini / SmartLite Director:**
  - The Gemini panels take wired DMX and CRMX. The Bluetooth path is "only meant for iOS control using the SmartLite Director app" (https://help.litepanels.com/en/gemini-control-options.html).
  - The app review "I honestly feel scammed… a polished control system that never materialized" (https://apps.apple.com/us/app/smartlite-director/id1057681116) shows **manufacturer apps get abandoned, which is Prism's opening.**
- **Quasar Science starCTRL (iOS):**
  - Controls up to 7 Rainbow/Double Rainbow tubes over Bluetooth.
  - Controls: Intensity, CCT, **±Green**, Hue/Sat and a **global Fade time**.
  - **FX:** Rainbow, Short Circuit, Paparazzi, Strobe, Fire, Emergency Light (https://help.quasarscience.com/en/all-about-starctrl.html).
  - Scope is deliberately tiny ("running in minutes").
  - Quasar tubes can also be controlled over Bluetooth by Blackout and Luminair.

### 1.29 Cross-product synthesis: music and audio reactivity (inputs to Prism's music mode)
- **Three families of "music sync"** (details in §1.10–§1.11 and §1.20–§1.23):
  - **Pre-analysed track scripts** (SoundSwitch, Hue × Spotify, DMXDesktop DJ mode) need local files or a beat grid, so they are **useless for Spotify/YouTube playback**.
  - **Clock sync** (Ableton Link, MIDI clock/MTC, OS2L, Pro DJ Link, a DAW host) gives exact tempo but no energy information.
  - **Live audio analysis** (Lightjams, DMXDesktop Live Wire, HitLight Auto Show, Nanoleaf Orchestrator, Hue Sync, LedFx, WLED-SR) is the **only viable core for Prism**, with clock sync as an option.
- **Capture on macOS:**
  - **Core Audio process taps** (macOS 14.2+; per-app on 14.4+ as HitLight advertises) need no BlackHole.
  - ScreenCaptureKit audio is the macOS 13 fallback; mic/line-in is the last resort.
  - LedFx on macOS still requires BlackHole/Loopback, a major setup pain.
- **Why auto shows look "random" or "laggy":**
  - Amplitude-driven mapping saturates on compressed masters.
  - Over-smoothing hides beats.
  - Looks change mid-bar.
  - Half/double tempo errors.
  - Auto-strobes and too much white.
  - Mic pickup of speech and room noise.
  - Latency stacks of 100–400 ms (Nanoleaf mic 100–200 ms, Spotify ~400 ms).
  - Bluetooth/AirPlay speaker delay makes lights run *early*.
- **Licensing:** **aubio and BTrack are GPL-3 and Essentia is AGPL-3.** A closed-source app should implement onset and tempo detection itself in Swift/Accelerate (vDSP).
- **Recommended starting pipeline** (synthesized from the research; parameters are starting points, not verified specs):
  - **Onsets:** 48 kHz → 1,024-pt FFT, hop 256–512. Log-compressed **spectral flux** with a separate low-band (40–150 Hz) kick detector. Adaptive-threshold peak picking with an 80–120 ms refractory period.
  - **Bands:** 16–24 mel/CQ bands grouped as Kick/Sub, Bass, Mids, Presence, Air.
  - **Tempo:** autocorrelation over 6–8 s, 60–180 BPM with a prior near 120. A **phase-locked beat oscillator** gives beat phase, bar phase and confidence, with Half/Double/Tap overrides.
  - **Level:** **per-band AGC** (fast rise, slow decay over ~10 s), squelch with hysteresis, and a **silence look after ~3–5 s**.
  - **Smoothing:** asymmetric attack/release envelopes. Map Hue-style **Subtle / Moderate / High / Extreme** presets onto attack, release and flash permission.
  - **Output and latency:** render at a fixed ~40 Hz (a full 512-slot DMX frame tops out at ≈44 Hz). Typical end-to-end latency is ~60–150 ms. Fire predicted beats early, add a **sync-offset slider (−250…+500 ms) with tap calibration**, and automatically add the Core Audio output-device latency for Bluetooth/AirPlay.
  - **Show logic:** change palette or look **only on bar/phrase boundaries**, scale pulses by beat strength, use energy tiers with hysteresis, **strobe off by default**, and stay inside the palette.
  - **Studio-safe defaults:** **key/fill never react**, dimming depth is capped (e.g. ±20%), flashes are capped at **≤3 per second** (WCAG 2.3.1), and strobe rates that alias with 24/25/30/50/60 fps cameras are avoided.
  - **Transparency:** a small live meter (bands, beat dot, bar counter, energy tier) so users see *why* lights move.

### 1.30 Bitfocus Companion (free, open source; Win/Mac/Linux)
- **What:** Turns Elgato Stream Decks and similar devices (or a browser emulator / web buttons) into control surfaces for hundreds of devices. It's ubiquitous in broadcast, AV and churches (https://bitfocus.io/companion).
- **Module model:** each connection exposes **actions, feedbacks (live state → button colour/text), variables and presets**. Presets are ready-made buttons you drag onto the grid, which is the UX that makes Companion approachable.
- **Other features:**
  - **Triggers**: event → condition → actions. New triggers start disabled.
  - **Satellite** remote decks on TCP 16622.
  - HTTP API: `POST /api/location/<page>/<row>/<col>/press`, custom variables, style changes.
  - **Security:** admin password, **surface PIN lockout**, **page permissions per surface**, and in v5 the **REST API is off by default and requires scoped API keys with a "last used" column**.
- **Lighting modules:** ETC Eos (OSC), **Monospace Lightkey (OSC send only; feedback request closed "not planned" because Lightkey sends no OSC state)** (https://github.com/bitfocus/companion-module-monospace-lightkey/issues/3), ONYX (Telnet/OSC), grandMA, MagicQ, generic Art-Net/sACN.
- **Complaints:** only one app can own a Stream Deck (conflicts with Elgato's software); multi-computer setups need networking knowledge; module quality varies.
- **Prism must:** ship an official **Companion module with presets, feedbacks and variables** (e.g. "current look", "music mode on", BPM). Expose **state out** (Lightkey's gap).

### 1.31 TouchOSC (Hexler; desktop/iOS/Android)
- **What:** A modular MIDI/OSC control-surface builder. Mk2 has an editor on every platform, **live synchronized editing across devices**, Lua scripting, "local messages", and TouchOSC Bridge for MIDI over Wi-Fi/USB (https://hexler.net/touchosc).
- **Role in lighting:** **Lightkey's help centre recommends TouchOSC as *the* phone/iPad remote**. QLC+ and ONYX document TouchOSC setups.
- **Complaints:**
  - Network discovery and firewall issues.
  - Building layouts by hand is tedious (users write Python generators).
  - Beginners struggle with raw OSC/MIDI concepts.
  - No state sync unless the host sends feedback.
- **Prism takeaway:** auto-generate the phone UI so normal users never need TouchOSC. Optionally publish an official `.tosc` layout for power users.

### 1.32 Remote and multi-user patterns in pro and prosumer lighting

| App | Pairing | Permissions / lockout | Multi-user |
|---|---|---|---|
| Lightkey | No app (TouchOSC by IP/Bonjour) | Password / Touch ID / Apple Watch; per-cue "requires unlocked app" | No |
| QLC+ web | Type `IP:9999` | HTTP Basic, 3 levels | Many browsers |
| grandMA3 web remote | Type `IP:8080` | MA user profiles; Admin/Guest can't log in; 1–5 connections; credentials in URL (anti-pattern) | Yes |
| ETC iRFR/aRFR | Dedicated Wi-Fi router setup | Eos users | Yes |
| ChamSys MagicQ Remote | **QR pairing on MQ50/70** | Core licence; passwords | Net Sessions |
| Companion | Type `IP:8000` | Admin password, surface PIN, page permissions, scoped API keys | Per-surface pages |
| Luminair | Local app / Apple Watch | Lockdown Mode with biometrics | File sharing |
| Blackout v3 | **QR → browser (view-only LivePlot)** | Screen Lock | Invite collaborator |
| HitLight | iOS/browser remote forwards to the Mac | Account-based; console hand-over | Invite collaborators |

Sources: https://help.malighting.com/grandMA3/2.3/HTML/network_webremote.html, https://support.etcconnect.com/ETC/Consoles/Console_Apps/How_to_Set_Up_Your_Wireless_Network_for_iRFR_or_aRFR_with_Eos_Family_Consoles, https://companion.free/user-guide/beta/security/

**Gap:** nobody in DMX lighting offers **QR-code pairing for *control* with scoped, revocable guest permissions** (Blackout's QR is view-only; MagicQ's QR is only on its hardware consoles). This is open whitespace for Prism.

**macOS gotcha:** since macOS 15, apps need the **Local Network permission** for Art-Net/sACN/Hue/Bonjour. Lightkey documents users having to toggle it in System Settings (https://lightkeyapp.com/en/help). Prism needs a pre-prompt explainer, detection, and a deep link to the setting.

### 1.33 Protocol, Stream Deck, voice/AI and camera findings that shape Prism's integrations

**OSC address spaces in the field**

| Product | Transport | Address style | Feedback |
|---|---|---|---|
| Lightkey | UDP/TCP, port 21600, Bonjour | Name-based `/live/<Page>/cue/<Cue>/activate\|deactivate\|toggle` | **None** |
| QLC+ | UDP 7700 in / 9000 out (+1 per universe) | Arbitrary paths hashed to input channels | Yes |
| grandMA3 | UDP/TCP | `/cmd,s,"Go+ Exec 402"`, `/Page1/Fader201` | Yes; MA warns object addresses "may change between software versions" |
| ETC Eos | UDP user ports; TCP 3032/3037 | `/eos/cue/<list>/<cue>/fire`, `/eos/sub/<n>` | **Gold standard**: subscribe + implicit output (`/eos/out/active/cue`) |
| ONYX | UDP + Telnet | `/Mx/playback/page<n>/<button>/<action>` | Partial; playback pages licence-gated |

Sources: https://lightkeyapp.com/en/help, https://help.malighting.com/grandMA3/2.5/HTML/remote_inputs_osc.html, https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/TCP_port_for_OSC_communication_with_Eos_Software, https://forum.obsidiancontrol.com/t/osc-documentation/5756

**Lessons:**
- Use *stable IDs plus slug aliases*, because OSC address parts can't contain spaces and names break on rename.
- Always send feedback.
- Support UDP and TCP with OSC 1.0 length-prefix and 1.1 SLIP framing (Companion's Eos module needs 1.0).

**Art-Net vs sACN facts** (https://www.dmxdesktop.com/guides/art-net-vs-sacn)

| | Art-Net | sACN (E1.31) |
|---|---|---|
| Port | UDP 6454 | UDP 5568, multicast |
| Priority | **None**; receivers merge at most **2** sources | **0–200 (default 100), highest wins** |
| Universe numbering | Often 0-based on the wire (classic off-by-one) | Universes 1–63,999 |
| Source loss | — | Detected after 2.5 s |

**Stream Deck landscape** (https://www.dmxdesktop.com/stream-deck)

The best-in-class plugin is **DMXDesktop's free plugin**. It:
- auto-discovers the app (last address, then a network search);
- fills dropdowns with real fixture/scene names and only valid targets;
- repaints keys on any state change;
- never overwrites user-typed titles;
- shows a red ⚠ when a target is deleted and a distinct icon when the app is offline;
- supports Stream Deck+ dials (press = full/restore).

Other plugins:
- **amaran Controller** (official) drives Sidus fixtures over Bluetooth through the amaran Desktop app (https://marketplace.elgato.com/product/amaran-controller-2acb7ef3-6442-4341-9e2a-a4b94fbfd824). Prism should advise one controller per fixture, so Bluetooth and DMX don't fight.
- **Elgato Control Center** (Key Light) is the bar creators expect.
- Lightkey has **no official plugin and no feedback**. There's an open Companion request for an Aputure/Sidus module since 2021 (https://github.com/bitfocus/companion-module-requests/issues/623).

How users map scenes to buttons, from best to worst for beginners:
1. Native plugin with name pickers and live state.
2. Companion presets.
3. Generic OSC plugin plus "Copy OSC Address".
4. MIDI over IAC plus learn.
5. Keyboard hotkeys, which break when the app isn't frontmost.

**Voice and AI**
- No lighting console has built-in voice. Lightkey gets Siri indirectly through Shortcuts.
- **Philips Hue's AI assistant (2026) and Custom AI Behaviors (late Oct 2026, Bridge Pro)** follow one pattern: *the LLM writes a declarative artefact in the cloud, and a deterministic engine runs it locally* (https://hueblog.com/2026/10/21/custom-ai-behaviors-set-to-launch-next-week/, https://9to5google.com/2026/01/07/philips-hue-rolling-out-these-upgrades-in-early-2026-spatialaware-scenes/).
- **light-mcp-server** (open source) routes UI, MIDI, OSC, MCP, timeline and CLI through **one command layer**. Show-safety rules bind the assistant exactly like the UI: forbidden modes, maximum UV, protected zones, strobe policy, neutral Panic/Blackout. It adds bearer tokens, PIN rate-limiting (5 tries/min) and a **standby mode** so two apps don't transmit at once (https://github.com/bawaaaaah/light-mcp-server).
- A community engine (r/lightingdesign) uses a copilot that builds and "evolves" sets from video plus audio, with the rule **"Human input through any interface always trumps automated functions"** (https://www.reddit.com/r/lightingdesign/comments/1s2c7mi/).
- **Lightkey warns: "Please do not generate a DMX chart with AI; this leads to wrong results in most cases."** The assistant must never invent fixture personalities.
- Default flash cap of **3 flashes/s** (WCAG 2.3.1-style) for anything AI- or guest-generated.

**Camera verification precedents**
- **xLights "Generate Custom Model"**: the camera records while the software flashes everything twice as a sync marker, then lights each node in turn. It reports missing nodes and nodes with more than one bulb. 2026.16 added direct webcam capture (https://manual.xlights.org/xlights/chapters/chapter-five-menus/tools/generate-custom-model).
- MadMapper Space Scanner does structured-light scanning.
- **Lightform** (dedicated camera hardware) shut down in 2022, so build camera features in software with the webcam or iPhone people already own.
- Pros on r/lightingdesign were sceptical of camera auto-patching. They warned that **sending values to unknown channels can reset or shut down moving heads**, but agreed the use case is non-professionals. So probe only intensity and colour channels at safe levels, and lock camera exposure and white balance.

**Recommended integration architecture for Prism** (synthesised from the above)
1. **One command layer.** UI, OSC, MIDI, HTTP/WebSocket, Stream Deck, Companion, App Intents (Siri/Shortcuts/Spotlight), the phone remote and the AI assistant all call the same API, so permissions, safety rules, logging and undo apply everywhere.
2. **OSC:**
   - Off until enabled; UDP and TCP; Bonjour `_osc._udp`.
   - Addresses such as `/prism/look/{id|slug}/go [fade]` and `/prism/group/{slug}/intensity f`.
   - `/prism/subscribe` for feedback (`/prism/out/look/{id}/active`).
   - `/prism/panic`, `/prism/blackout`, tap/BPM, plus an OSC monitor.
3. **HTTP REST plus WebSocket events:** local-only, off by default, versioned (`/api/v1/...`). Scoped bearer tokens (`read`/`operate`/`edit`) with "last used" and revoke (Companion v5 model). Bonjour `_prism._tcp`.
4. **First-party Stream Deck plugin** (DMXDesktop-grade) **plus a Companion module** with presets, feedbacks and variables.
5. **MIDI learn:**
   - A live readout ("Heard: Note 36 ch10 — APC mini").
   - Auto-classify button / fader / relative encoder / 14-bit.
   - On conflicts, ask Replace / Keep both / Cancel (Blackout).
   - Soft takeover for faders; LED feedback templates for APC mini, Launchpad and nanoKONTROL.
   - Use the same learn flow for DMX-in and OSC.
6. **Phone remote:**
   - The QR holds the LAN URL plus a one-time token, exchanged for a device credential.
   - Optional "Allow this device?" approval on the Mac (the Hue link-button principle).
   - Roles: **Owner / Operator / Guest / Viewer**.
   - Guest sessions expire; per-device revoke; "kick all guests".
   - Auto-reconnect after the phone sleeps (an ONYX Remote complaint).
   - Start as a PWA so guests install nothing.
7. **Protocol hygiene:**
   - sACN priority 100 by default.
   - Art-Net 4 unicast, and show 0- vs 1-based universes.
   - A standby/"don't transmit" mode.
   - Explain the macOS 15 **Local Network permission** before the prompt, detect a denial, and deep-link to settings.
   - Multicast on iOS needs an Apple entitlement, so a web remote avoids it.

---

## 2. Master feature checklist

**How to read this section**
- **Who has it** uses the abbreviations below.
  - `(p)` means partial or limited. `?` means plausible but unverified.
  - "none" means we found no competitor offering it. These are Prism whitespace.
- **Priority** is for Prism's target user: a YouTube/podcast studio owner with amaran pixel tubes and a panel on an Enttec DMX USB Pro.
  - **P0** = the MVP spine. Without it Prism fails the core job or loses to Lightkey on first contact.
  - **P1** = differentiators and expected follow-ups (v1.x).
  - **P2** = later, niche or pro features.

**Abbreviations**

| Group | Abbreviations |
|---|---|
| Mac-first / simple | **LK** Lightkey · **HL** HitLight · **BO** Blackout · **LUM** Luminair · **PH** Photon 2 · **DD** DMXDesktop · **EMU** ENTTEC EMU · **SBA** ShowBuddy Active (ex-DMXIS) |
| Pro / console | **QLC** QLC+ · **MQ** ChamSys MagicQ · **ONX** Obsidian ONYX · **MA3** grandMA3 onPC · **EOS** ETC Eos/Nomad · **CAP** Capture · **SUN** Sunlite/Daslight · **FS** FreeStyler · **LS** LightShark |
| Music / pixel / VJ | **SS** SoundSwitch · **LJ** LightJams · **MM** MadMapper · **RES** Resolume Arena · **WLED** WLED(-AudioReactive) · **LFX** LedFx |
| Fixture-maker apps | **SL** Aputure Sidus Link / Link Pro · **NL** Nanlink · **AST** Astera App · **GOD** Godox Light · **ZY** ZY Vega · **QS** Quasar starCTRL |
| Smart / creator | **HUE** Philips Hue (Sync/Entertainment) · **NLF** Nanoleaf · **GOV** Govee · **ELG** Elgato Control Center |
| Control surfaces | **COMP** Bitfocus Companion · **TOSC** TouchOSC |

### 2.1 Patching

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Add-fixture flow: brand → model → mode → quantity | LK, QLC, MQ, ONX, MA3, EOS, BO, LUM, SS, DD, HL, FS, SUN | **P0** | Search with product photos; recent and "add another" shortcuts (ONX Patched Types) |
| Auto next-free address (and universe) | LK, ONX (Auto universe + address), QLC, MQ, RES, BO (batch) | **P0** | On by default; the user never does arithmetic |
| Plain-language mode picker with footprint and purpose | MA3 Channel Map (p), ONX footprint readout (p) | **P0** | "Whole tube = one colour" vs "every pixel (effects)"; recommend one mode |
| On-fixture instruction card (menu path, address, mode, lock) | LK (DIP picture), RES (DIP picture) | **P0** | Model-specific cards, e.g. the amaran PT DMX screen plus "hold OK 2 s". Phone hand-off by QR (§4) |
| Overlap/conflict prevention with a fix-it dialog | ONX (Unpatch / Edit / Cancel), LK (warns), BO (limit warning) | **P0** | Overlaps impossible unless the user chooses "link these lights" |
| Blink-to-identify any light | SL (Fixture Locator), ELG (identify), ONX (Patch Highlight), RDM identify (MQ, ONX, LUM) | **P0** | Software flash at safe levels; used in setup and daily |
| Pixel-aware patch for tubes/bars (cells, order, snake) | QLC (RGB Panel wizard), LK (flexible pixel profiles), RES, MM, SL Pro | **P0** | PT1c/2c/4c = 4/8/16 px; direction arrow on the stage map |
| Rig health warnings (no address, overlap, not responding, mode mismatch) | ONX ("Unassigned Channels Detected"), SL Pro (network health), BO (Astera telemetry) | **P0** | Plain-language health panel with "fix for me" |
| Hide universes until needed; one numbering convention | none | **P0** | "Universe 1, ch 1–512"; translate Art-Net 0-based / sACN 1-based internally |
| Program without hardware / patch now, address later | MQ, HL (3D rehearsal), LK, EOS (offline) | **P0** | Visualizer-first onboarding before the Enttec arrives |
| Live universe map (used vs free channels) | ONX (Universe View) | P1 | 512-cell bar with a coloured block per light |
| Camera-verified patch (which light is where; detect swaps or dead lights) | none (xLights / MM LED Scanner for pixels only) | P1 | Prism signature feature; probe intensity/colour only, lock exposure and WB |
| Swap fixture, keep looks | MQ (head morphing), ONX (Fixture Swap), LUM (Replace Fixtures), MA3 (Recipes) | P1 | Re-map by colour *intent*, not raw values |
| Several fixtures on one address (linked lights) | LK | P1 | Explicit "Link" action; the UI shows one control |
| Patch sheet export (PDF/CSV) and CSV import | LK (CSV/TSV + print), LUM (print), BO (CSV/XML import) | P1 | Printable "set these on your lights" sheet |
| RDM discovery / readdress / mode set via Enttec Pro | QLC (Enttec RDM), LUM (over Art-Net), DD (Art-Net or Enttec), ONX/MQ (own HW) | P2 (→ P1 if the user's fixtures support RDM) | Aputure/amaran RDM support unverified; always keep the manual path (§4.4) |
| MVR import/export | MA3, MQ, BO (import), CAP | P2 | For pros previsualizing in Capture |
| Channel-by-channel "what changed?" builder for unknown lights | DD (auto-detect RGB / pan-tilt patterns, p) | P2 | Pairs with generic templates |

### 2.2 Fixture library and profile editing

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Curated studio-brand profiles (Aputure/amaran, Nanlite, Godox, Astera, Quasar, Litepanels) with photos and mode explanations | SL (Aputure only), NL (Nanlite only) | **P0** | Quality over quantity first; verified flag |
| Generic templates (Dimmer, CCT, RGB, RGBW, RGBWW, N-pixel tube) | BO, RES, QLC, LK | **P0** | Covers no-name lights, the #1 first-run failure (SS complaint) |
| Synthetic / virtual master dimmer for modes without one | LK, LS | **P0** | Every light always has Brightness + Colour |
| Large general library (thousands of models) | BO (~45k Carallon), LUM (30k Carallon), MQ (28.5k), DD (~30k), LK (7k+), ONX (daily), MA3/EOS/QLC/SS/FS | P1 | Licensing (Carallon) vs import (OFL/GDTF) is an open decision |
| GDTF import | MA3 (native + GDTF Share), MQ; ONX **no** | P1 | Also gives emitter data for colour matching |
| Open Fixture Library / QLC+ `.qxf` import | QLC (export to OFL) | P1 | Free and broad; check licence terms |
| Profile editor | LK, QLC, MQ, ONX, MA3, EOS, BO, LUM, PH, SS, DD, FS, LS, RES | P1 | Wizard-style, with a live test of each channel |
| Draft a profile from a photo/PDF of the DMX chart | HL (AI draft), BO ("Request a Profile"), SS/LK (email support) | P1 | Stays "draft until tested" (HL), with a 30-second verification checklist |
| Draft vs verified status | HL | P1 | Unverified profiles excluded from automatic paths |
| Online library updates | LK, ONX (daily), BO, MA3 (GDTF Share), DD (community) | P1 | Signed, versioned updates |
| Per-fixture colour calibration data (emitters, gamut) | MA3 (GDTF emitters), AST (per-lamp calibration) | P1 | Enables "same colour on every brand" |
| Import SSL2 / FXT / PFF profiles | LK | P2 | Low value for studio users |

### 2.3 Colour and programming

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Kelvin + green/magenta tint | SL, NL, AST, LUM (CCT + Tint), QS, GOD, BO (CCT on white curve); ELG (K only) | **P0** | Default view for white light |
| HSB/HSI and RGB with exact numeric entry | LK (HSB), BO, LUM, SL, AST, GOD, NL | **P0** | Double-click any slider to type (AST) |
| Hex entry and copy | SL Pro (hex), AST (copy RGB values) | **P0** | Brand colours for YouTubers |
| CTO/CTB fractions | SL, ZY (CT filters on base), AST | **P0** | ¼ / ½ / full CTO and CTB on a 3200 or 5600 K base |
| Colour favourites / swatches | LK (25), LUM, AST, GOV | **P0** | Project palette plus a recent-colours row |
| Relative edits / nudges across a selection | LK (relative changes) | **P0** | Warmer/Cooler, ±⅓ stop, more/less colour |
| Unlimited undo | LK | **P0** | Plus a history timeline (P2) |
| LEE/Rosco/GAM gel library, searchable by number or name | LK (Lee/GamColor/Roscolux), LUM, EOS ("similar colors"), SL (300+), AST, NL (151/460), GOD | P1 | Shows "closest this light can make" (EOS idea) |
| Real-source presets (Candle, Tungsten, HMI, Sodium…) | SL (17 SourceTypes), ZY (tungsten/HMI bases) | P1 | Film-native vocabulary |
| Camera colour / CCT match ("match the window light") | SL (SourceMatch, Color Picker), ZY, GOD (Photo Colour Match), BO (Lit Duo meter) | P1 | Continuity Camera or iPhone remote |
| Cross-brand colour matching | MA3 (GDTF emitter correction) | P1 | Uses calibration data or a camera |
| Dimming curves (linear/exp/log/S) | SL | P1 | Per light; camera-friendly low end |
| Copy/paste looks between different fixture types | LK | P1 | By intent (colour, intensity) |
| Blind editing (change without output) | LK, LUM (Edit Blind), MQ (MagicVis blind) | P1 | "Preview on map only" toggle |
| CIE xy entry with gamut display | BO, SL, AST, GOD, LUM | P2 | Pro mode |
| Fanning / spreads across groups | LK, MA3 (MAtricks), SUN, LUM (group offset) | P2 | Used by gradients on tubes |
| Palette from an image or logo | none | P2 | Brand-kit feature |

### 2.4 Effects, including pixel effects

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Named effect library in creator vocabulary (Candle, TV, Fire, Lightning, Cop Car, Paparazzi, Pulse…) | SL (15 System FX), NL (15), AST (film-maker), QS (6), LUM, LK (70+), GOD | **P0** | Reimplement the Sidus set in software (§5) |
| Pixel effects across tube cells (chase, rainbow, fill, sparkle…) | LK (pattern FX with pixel order), SL (7 Pixel FX), QLC (RGB Matrix), WLED (180+), LFX (~70), ONX (DyLOS), MQ (pixel mapper), BO v3, MM, RES | **P0** | Key for amaran PT tubes |
| Three human parameters (Speed, Size/Spread, Intensity) plus palette | WLED (Speed/Intensity/palette), SL (Speed/Frequency 1–10), NLF | **P0** | Same knobs on every effect |
| Effects respect protected lights and flash caps | HL (hazards stripped, strobe off) | **P0** | ≤3 flashes/s by default |
| Animated effect thumbnails | GOV (mode thumbnails, p) | P1 | Pick by look, not by parameters |
| Tempo-synced effects (BPM, tap, beat multiplier) | LK, BO (speed masters), LUM (tap), SS, MM (global BPM), SBA | P1 | Shares the clock with music mode |
| Spatial effects on the stage map (fixture-independent) | SBA (draw FX on 2D plan), NLF (layout-aware), MM/RES (pixel sampling), SS (Position Cues) | P1 | Sweeps survive adding or moving lights |
| Virtual fixture spanning several tubes | AST, LFX (Virtuals), WLED (segments, inverse) | P1 | "Back wall" = 3 tubes as one 48-px line |
| Hold-to-flash / override buttons | FS, AST, LK (flash buttons) | P1 | With a safe release |
| Layered effects (stack modulation on a base look) | AST (layer effects), MA3 (phasers in looks), BO (keyframes) | P2 | |
| Per-parameter "animate" toggle | ONX | P2 | Right-click any slider → Animate |
| Keyframe/timeline effect editor | SL Pro (Magic Program), BO, HL (timeline) | P2 | |
| Generative, non-repeating effects | SL Pro (Magic Infinity FX) | P2 | |
| Video/screen → pixel mapping | MM, RES, BO v3, EOS (VMS), ONX (DyLOS), HUE Sync (screen), NLF/GOV (screen mirror) | P2 | Ambient "match my screen" for streamers |

### 2.5 Presets, looks, cues and playback

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Looks (snapshots) with recall | all controllers | **P0** | |
| Folders of looks; mutually exclusive groups (radio behaviour) | LK (nested, mutually exclusive groups, attached buttons), PH (latch/solo), NL (fixture vs scene presets) | **P0** | Folders like albums ("Podcast", "Interview") |
| Crossfade times with named presets | LK, BO (per-category timing), QS (fade), ELG (fade durations), LFX (8 transition modes), WLED | **P0** | Snap / 1 s / 3 s / 10 s plus custom |
| Perceptual colour interpolation in fades | none (BO users complain about stray hues) | **P0** | OKLab/OKLCH; CCT fades along the Planckian locus |
| Capture current output as a look | LK (snapshot), BO (record DMX-in into looks) | **P0** | "Save what I see" |
| Grand master, freeze and blackout/panic | MM (Freeze Output), LK (Freeze), HL (Stop / Fade / Blackout), most consoles | **P0** | Always visible; keyboard shortcuts |
| Startup look and defined quit behaviour | LK (activate-at-startup/quit cues), ELG (power-on settings) | **P0** | See §2.12 |
| Auto-generated live/remote page from looks | none (LK pages built by hand; EOS Magic Sheets from layout, p) | P1 | Zero-effort default |
| Look thumbnails (render or camera frame) and notes | LUM (photo/icon/notes), LK (button colour from content) | P1 | |
| Override look over music or effects (per-attribute "Thru") | SS (Static Looks + Thru, v2.11) | P1 | "Keep music, but key at 5600 K" |
| Studio templates / starter looks after patch | MA3 (Startshow) | P1 | "Podcast — 2 hosts", "Talking head" |
| Cue lists / sequences (hold, loop, auto-follow) | LK, QLC, MQ, ONX, MA3, EOS, BO, LUM, PH, FS, SUN | P1 | Simple "Scenes in order" for intros/outros |
| Recipes / intent-based looks that re-cook on rig change | MA3 | P1 | Looks stored as roles + colour intent |
| Tracking / LTP priority layering | MQ, MA3, EOS, ONX, LK (LTP priority) | P2 | Keep a simple model by default |
| Timeline or timecode shows | QLC (Show), SUN (timelines), SBA (DAW), LK (Ableton Live Triggers), Audio Lights DMX | P2 | |

### 2.6 Visualizer

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| 2D stage with glowing fixtures; the visualizer is the selection surface | LK, QLC v5, BO (LivePlot), SBA, MM, RES, GOD (Studio Mode), ZY (grid) | **P0** | Click, lasso, scroll-to-dim, right-click Blink |
| Studio photo or plan as background | LK (background images), BO (LivePlot on a set photo) | **P0** | Snap a photo of the room |
| Pixel-accurate tube rendering | LK (pixel profiles), MM, RES | **P0** | Per-cell glow |
| Works with no hardware attached | HL, LK, MQ, EOS, QLC | **P0** | |
| Hover/blind preview of a look on the map | LK (Blind, p) | P1 | Preview without touching real lights |
| Control page auto-built from the layout | EOS (Magic Sheets from Augment3d) | P1 | |
| View-only live plot shared by QR to any browser | BO (LivePlot) | P2 | Producer or client view |
| 3D visualizer | MQ (MagicVis), EOS (Augment3d), QLC v5, HL, DD, SUN (Easy View), SL Pro 2.3, CAP | P2 | 2D first; 3D later |
| Quality presets and FPS indicator | EOS | P2 | |

### 2.7 Music and audio reactivity

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| System-audio capture, per app, with no loopback driver | HL (macOS 14.4+), DD (14.2+), HUE Sync (per-app on Mac), NLF (Orchestrator, Premium), LJ (Windows loopback); LFX needs BlackHole | **P0** | Core Audio process taps; "Listen to: Spotify / Safari / Whole Mac / Mic" |
| Beat and tempo tracking with phase/bar | LJ (BPM + phase → BAR), LFX (beat/bar oscillators), QLC v5, PH (BeatTracker), MM, RES, HL, DD | **P0** | Own Swift/vDSP code (aubio/BTrack are GPL) |
| Changes quantized to bars/phrases | SS (8–128-bar autoloops), DD/HL (structure, p) | **P0** | The top fix for the "random" complaint |
| Tap / half-time / double-time | LK, BO, LUM (tap); half/double requested by SS users | **P0** | |
| Named intensity presets plus one sensitivity control | HUE (Subtle…Extreme), NLF (Mood/Palette/Sensitivity), GOV (Sensitivity), WLED (AGC Normal/Vivid/Lazy) | **P0** | Brightness separate from reactivity (HUE) |
| Auto-gain / per-band normalization | LJ, WLED (AGC), LFX | **P0** | Handles compressed masters |
| Silence → base look | LFX (5 s) | **P0** | |
| Sync offset and latency compensation (Bluetooth/AirPlay) | LFX (delay_ms), PH (works with BT/AirPlay); HUE (display only, not music) | **P0** | Slider, tap calibration, auto device latency |
| Protected fixtures excluded from music (key/fill) | SS (per-fixture inclusion), HL (hazard exclusions) | **P0** | Studio-safe default |
| Strobe off by default; flash-rate cap; camera-safe | HL (strobe off), DD (choose who may strobe) | **P0** | ≤3 flashes/s; avoid frame-rate aliasing |
| Energy tiers, build-up and drop detection | LJ, DD, HL | P1 | With hysteresis |
| "Vibes" (palette + motion + energy mapping) picked by look | NLF (mood + palette), GOV (named modes) | P1 | Chill / Pop / EDM / Lo-fi |
| Live analysis meter (bands, beat dot, bar counter) | LJ, QLC (spectrum), WLED | P1 | Transparency builds trust |
| Ableton Link and MIDI clock in | LK (Link, MIDI clock, OS2L), PH (Link), SS, MM, RES, DD, QLC (OS2L) | P1 | Exact tempo for musicians |
| Mic / line-in input | PH, LUM, FS (S2L), QLC, SUN, NLF, GOV, WLED, LJ, SL (LIVE mic) | P1 | Fallback; gate speech in podcast rooms |
| Pro DJ Link / OS2L / DJ-software sync | SS, HL (Pro DJ Link), LK/QLC/LJ/DD (OS2L), NLF (Engine DJ) | P2 | |
| Pre-analysed track scripts | SS, HUE × Spotify, SL (Music FX from files) | P2 | Not viable for Spotify/YouTube playback |

### 2.8 Voice and AI

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Offline command bar for common phrases ("warmer", "background blue", "brighter key") | none | **P0** | Deterministic grammar on roles; preview + undo |
| Free-form natural-language looks via LLM | HL, HUE (AI assistant), NLF (text-to-scene), GOV (AI bot, ?), MM (Mad AI, ?) | P1 | Produces ordinary editable looks; never invents channels |
| Relative edits with preview and "a bit more / undo" | none | P1 | "a bit" = 300 K or ⅓ stop |
| Voice (push-to-talk / dictation) | none in lighting consoles (HUE/NLF/GOV via Siri/Alexa/Google) | P1 | On-device speech recognition |
| Safety rules bind the AI exactly like the UI | HL (hazard stripping, strobe off), light-mcp-server | **P0** (with any AI) | Protected lights, flash cap, panic |
| Siri / Shortcuts / App Intents | LK (~15 Shortcuts actions), LUM (URL scheme), HUE/NLF/GOV (assistants) | P1 | "Hey Siri, recording look" |
| AI profile drafting from a manual | HL | P1 | See §2.2 |
| AI troubleshooting with rig context | BO ("Ask PATCH", inferred, p) | P2 | Uses the real patch |
| MCP server for external AI agents | HL, NLF (MCP AI agent), wled-mcp, QLC fork | P2 | Scoped tokens |

### 2.9 Remote, mobile and multi-user

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Phone/tablet remote (no install, browser/PWA) | QLC (web :9999), MA3 (web remote), LS (browser UI), DD (web server), WLED, LFX, COMP (web buttons); native apps: MQ, ONX, EOS, LUM, HL, SUN; **LK none** (points to TouchOSC) | P1 | Biggest Lightkey gap; consider pulling into v1.0 |
| QR-code pairing | MQ (MQ50/70 consoles only), BO (view-only LivePlot) | P1 | One-time token in the QR, exchanged for a device credential |
| Scoped guest permissions, expiry and revoke | QLC (3 auth levels), COMP (page permissions, PIN, scoped API keys), LK (per-cue "requires unlocked app"), MA3 (user profiles) | P1 | **Nobody combines QR + guest scopes**: Prism whitespace |
| App lock / kiosk / biometric unlock | LK (Touch ID / Apple Watch), LUM (Lockdown Mode), QLC (kiosk), MQ (Execute window), BO (Screen Lock) | P1 | Recording mode = lock + REC badge |
| Simplified end-user "host" remote | SUN ("bar owner" remote), MQ (Execute window), QLC (Virtual Console kiosk) | P1 | Big look buttons + master only |
| Multi-user editing / sessions | MA3 (sessions, Datapools), MQ (Net Sessions), EOS (multi-console), HL/BO (invite collaborators) | P2 | |
| Attributed change history ("who changed this?") | none | P2 | |
| Apple Watch remote | LUM (remote), LK (unlock only) | P2 | |

### 2.10 Integrations

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Keyboard shortcuts | LK, SL Pro 2.4, MM, most | **P0** | |
| MIDI in with learn and LED feedback | LK, QLC, MA3, EOS, BO, LUM, PH (+), SS, SBA, DD, LJ, MM, RES, SUN, FS, LS; MQ/ONX licence-gated | P1 | Live "Heard: Note 36" readout, soft takeover |
| OSC in | LK, QLC, MA3, EOS, BO, LUM, SUN, LJ, MM, RES, SBA, DD, LS; MQ/ONX licence-gated | P1 | Stable IDs + slug aliases |
| OSC feedback / state out | EOS (gold standard: subscribe), MA3, QLC, ONX (p); **LK none** | P1 | Lightkey's Companion module can't show state |
| Local HTTP REST + WebSocket events | QLC (WebSocket only), WLED, LFX, HUE, NLF, GOV, ELG, COMP | P1 | Off by default; scoped tokens (Companion v5 model) |
| Official Stream Deck plugin with live feedback | BO (native, mappings in showfile), ELG, HUE Sync, DD (free plugin), amaran Controller; LK third-party only | P1 | Look thumbnails on keys; dials for master/CCT |
| Bitfocus Companion module (actions, feedbacks, variables, presets) | ONX, MA3, MQ, EOS, ELG; LK (send-only) | P1 | |
| Ableton Link | LK, PH, SS, MM, RES, DD | P1 | See §2.7 |
| Art-Net / sACN output | LK, QLC, MQ, ONX, MA3, EOS, BO, LUM, PH, LJ, MM, RES (Art-Net only), FS, LS, DD, HL, LFX, SUN (licensed) | P1 | Also to localhost for Capture or other visualizers |
| OBS link (scene ↔ look, REC → recording look) | none native (COMP can bridge) | P2 | Strong creator differentiator |
| Art-Net / sACN / DMX input (receive or merge) | LK (DMX-In), BO (merge), CAP, WLED, LJ | P2 | |
| Timecode (MTC/LTC) | MA3, EOS, ONX (licensed), MQ (unlocked), BO (MTC), LUM (MTC/MSC), SS (MTC), SUN | P2 | |
| Home automation (HomeKit / Home Assistant / Matter) | LUM (HomeKit), LK (Home Assistant via community OSC), HUE/NLF/GOV | P2 | |
| DAW plug-in (AU/VST) | SBA, LJ (VST), EMU (VST3) | P2 | |

### 2.11 Project files and sharing

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Single self-contained project file (profiles embedded) | LK (`.lightkeyproj`), BO (`.blk`), QLC (`.qxw`), MQ (`.shw`) | **P0** | `.prism` package with documented JSON plus thumbnails |
| Newer-version files refused safely; forward-compatible schema | BO | **P0** | Schema version and a migration log |
| Clear, distinct Open vs Save vs New | (QLC anti-pattern: identical dialogs cause overwrites) | **P0** | Native document model with versions |
| Import from Lightkey | none | P1 | Read-only bplist importer (§1.1.1) plus CSV fallback |
| Merge import with preview and automatic backup | BO (partial import, universe remap, backup before import) | P1 | |
| Share project / invite collaborator / cloud | BO (share + invite + cloud), SL (cloud + temporary codes), HL, DD (cloud backup), AST (backup & handover) | P1 | iCloud Drive / AirDrop first; no account needed |
| Human-readable, documented format | QLC (XML) | P1 | Encourages an ecosystem |
| Share a single look (AirDrop / link / QR) | none (LK preset export, p) | P2 | |
| Import QLC+ / MVR / CSV patches | BO (MVR, CSV, XML), MA3/MQ (MVR) | P2 | |

### 2.12 Reliability

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Continuous autosave | LK, BO (every 5 min, local), MM, QLC (since 4.14.4), ONX (consoles; PC reportedly off by default) | **P0** | Every change journaled |
| Automatic versioned backups | MA3 (backup every save), MQ (`.sbk`), BO (cloud + local), DD (cloud), MM | **P0** | "Restore from 10 minutes ago" |
| Crash recovery: resume the last output state | MM (backup & recovery), LK (restore last state, p), BO (p) | **P0** | Relaunch → restore within seconds |
| Explicit quit behaviour (keep / fade / blackout) | LK (activate-at-quit cue), HL (Stop / Fade / Blackout) | **P0** | Setting plus a quit-confirm sheet |
| Output keeps running in background / App Nap disabled | BO (background + iPad sleep); ShowXpress App Nap bug (anti-example) | **P0** | Dedicated real-time output thread |
| Interface hot-plug detection and auto-reconnect | (ENTTEC macOS troubleshooting article shows the need) | **P0** | Detect "another app holds the port" |
| Hardware health panel (fps, device S/N, lights verified) | SL Pro (network health, battery), BO (battery telemetry), ONX (RDM reports) | **P0** | |
| Local Network permission explainer, detection and deep link | BO (warning), LK (documents the toggle) | **P0** | Needed for Art-Net/sACN/remote on macOS 15+ |
| Fixture DMX-loss behaviour guidance | (amaran: Hold Last / Black Out / Fade) | **P0** | Wizard recommends "Hold Last" for studios |
| Watchdog: safe frame if the UI hangs | HL (all-zero within 2 s) | P1 | Configurable: hold vs fade |
| Launch at login + restore last look | none explicit | P1 | Studio "power cut" scenario |
| Standby mode (don't transmit) to avoid two senders | light-mcp-server; RES/QLab flicker anti-example | P1 | |

### 2.13 Hardware support

| Feature | Who has it | Priority | Notes for Prism |
|---|---|---|---|
| Enttec DMX USB Pro (FTDI 0403:6001) | LK, QLC, SS, MM, SBA, DD, HL, LUM (macOS), FS (Windows), LJ (Windows), EMU; CAP (input only). **Not** MQ, ONX, MA3, EOS, BO, PH, RES, SUN (?) | **P0** | Primary output; serial-number display |
| Other USB-DMX (DMXking ultraDMX, Eurolite, Open DMX) | LK (Open DMX needs admin password each launch), QLC, MM, SBA (DMX KING MAX), DD, HL | P1 | Avoid kext/driver prompts |
| Art-Net / sACN nodes | most consoles (see §2.10) | P1 | |
| Generic MIDI controllers (APC mini, nanoKONTROL, Launchpad) | LK (profiles), QLC, LS, MQ | P1 | Ready-made templates |
| RDM over Enttec Pro | QLC, DD, LUM (over Art-Net) | P2 (→ P1 if fixtures support it) | Enttec DMX USB Pro is RDM-capable |
| Enttec Pro Mk2 second universe | LK, QLC, FS | P2 | |
| Philips Hue output | LK (≤100 lights), PH (Entertainment), SS, LUM (HomeKit), LFX | P2 | Practicals and background lamps |
| Elgato Key Light / Nanoleaf / LIFX / WLED / Govee output | SS (Nanoleaf), LFX (many), LUM (HomeKit), COMP (Elgato) | P2 | "Whole room in one app" |
| Wireless DMX (LumenRadio CRMX/Bluetooth) | BO, LUM (MoonLite/TimoTwo), AST (ART7) | P2 | |
| Aputure Sidus Bluetooth control | SL, amaran Desktop + Stream Deck plugin | P2 | No public API found; wired DMX is deterministic |
| DMX input from a physical console | LK, BO, LJ | P2 | |

### 2.14 What the P0 set adds up to (the MVP spine)
1. **Enttec Pro output** that is detected, health-checked and keeps running in the background.
2. **Patch wizard** with curated studio profiles, generic templates, auto-addressing, pixel-aware tubes, instruction cards, blink-to-identify and overlap prevention.
3. **Film-native colour panel**: Kelvin + tint, HSB/RGB/hex, CTO/CTB, swatches, nudges and undo.
4. **Looks**: folders, radio groups, named crossfades with perceptual interpolation, capture-current, master/freeze/blackout, and startup/quit behaviour.
5. **2D photo-backed visualizer** that is also the controller and works without hardware.
6. **Basic music mode**: per-app system audio, beat/bar tracking, bar-quantized changes, intensity presets, AGC, silence look, sync offset, protected faces, strobe caps.
7. **Offline command bar**, with safety rules shared by every input path.
8. **Reliability**: single-file projects, autosave, versioned backups, resume after crash, explicit quit behaviour, Local Network handling.

---

## 3. Top 30 UX innovations for Prism (to be more intuitive than every competitor for non-lighting people)

Ordered roughly by impact for a YouTube/podcast studio owner. "Precedent" means a competitor has a partial version; the Prism twist is what makes it better.

| # | Innovation | What the user experiences | Precedent → Prism twist |
|---|---|---|---|
| 1 | **Lights-first patch wizard with on-fixture instruction cards** | "Add 3 × amaran PT4c" → Prism picks modes and addresses and shows a card per light: *MENU → DMX Settings → Address 017 → Profile CCT&RGB → hold OK 2 s*. A QR opens the card on the phone at the light stand | Lightkey/Resolume DIP helpers → full model-specific, illustrated, phone-handoff cards (§4) |
| 2 | **Blink-to-identify everywhere** | Hover or click any light in the UI and the real light gently pulses. "Which light is pulsing?" binds patch to position | Sidus "Fixture Locator", RDM identify → software identify for *any* DMX light, used during setup *and* daily |
| 3 | **"Check my lights" camera verification** | The Mac/iPhone camera watches the set while Prism blinks each light. It confirms the patch, detects swaps or dead lights, and auto-places fixtures on the stage map. Run it as a 10-second pre-recording health check | No DMX competitor does this. MadMapper's LED Scanner maps pixels; Blackout uses a meter for colour |
| 4 | **Plain-language and voice control with preview + undo** | "Warm up the background a bit" → shows *Background tubes 4300K → 3800K* and applies with a fade. "Undo" or "a bit more" work | HitLight scene generation → *relative* edits on named roles, voice, offline parser for common phrases, LLM for the rest; always an editable Look |
| 5 | **Roles instead of addresses** | Lights get roles (Key, Fill, Hair/Back, Background, Practical, Accent), suggested from stage position. Every UI, voice command and effect targets roles | Nobody does role-semantics; SoundSwitch has venue-independent abstractions |
| 6 | **Film-native colour controls in one synced panel** | Kelvin + G/M tint as the default. Real-source presets (Tungsten, HMI, Sodium…), searchable CTO/CTB and LEE/Rosco gels, hex/RGB/HSB for brand colours, xy for pros; all views stay in sync | Sidus Link, Luminair → combined in a DMX controller with per-fixture calibrated conversion |
| 7 | **"Same colour on every brand" calibration** | One Kelvin/tint value looks the same on the tubes and the panel. Optional calibration with the phone camera or a colour meter; "Match the window light" (SourceMatch) | Blackout + Lit Duo meter, Sidus SourceMatch → built in, camera-based |
| 8 | **Looks as photos** | Every saved look gets an auto thumbnail (visualizer render or real camera frame). Folders work like albums ("Podcast", "Interview", "Product"). Hovering previews the look on the stage map without changing the real lights | Luminair photo previews, Lightkey auto-coloured buttons → real thumbnails plus a hover-preview (blind) |
| 9 | **Human crossfades** | Snap / Quick 1 s / Smooth 3 s / Slow 10 s, plus custom. Fades interpolate in a perceptual colour space so no ugly hues pass through | Blackout users complain of unwanted colours during crossfades → solved by default |
| 10 | **Nudge controls** | Warmer/Cooler, Brighter/Dimmer (in % *and photographic stops*: "+⅓ stop"), More/Less colour, applied to the selection or the whole look. Mirrored by voice ("a bit" = 300 K or ⅓ stop) | Lightkey relative changes → named, quantized, camera-literate nudges |
| 11 | **Auto-generated control panel** | Prism builds the Live/Remote page from looks and folders automatically, with live state; the user can rearrange it | Lightkey users spend "an evening" building ~90 buttons → zero-effort default |
| 12 | **Safe guest remote by QR** | Scan → the phone opens a remote with *scoped* permissions: chosen looks only, brightness within limits, no patch or edit, expiry time, revocable from the Mac. Owner pairing needs approval on the Mac | MagicQ QR (hardware only), Blackout QR (view only), Companion page permissions → first DMX app with QR *control* + guest scopes + one-time tokens (no credentials in the URL, unlike grandMA3) |
| 13 | **Zero-setup music mode from system audio** | Pick "Spotify", "Safari/YouTube" or "Whole Mac" and it reacts immediately: no BlackHole, no Loopback. Vibe presets (Chill, Pop, EDM, Lo-fi), one "How wild?" slider, half/double tempo, and a **silence → base look** fallback | LedFx needs BlackHole; HitLight/DMXDesktop use process taps → plus vibes, silence fallback (LedFx), ½×/2× (SoundSwitch complaint) |
| 14 | **"Protect faces" lights** | Key and Fill are excluded from effects, music mode and voice "party" commands by default, so talent exposure never changes mid-take | HitLight hard-excludes hazardous channels → Prism adds "exposure-critical" exclusions for video |
| 15 | **Recording mode** | One toggle (or OBS/Shortcuts trigger) freezes the rig: no guest changes, no effects on protected lights, a red REC badge, and confirmation before any change | MadMapper "Freeze output", Lightkey lock → studio-specific "take safety" |
| 16 | **Camera-safe guardrails** | Warns about strobe rates and very low dim levels that may flicker on camera at the chosen frame rate or shutter. Strobe rates are capped by default (photosensitivity) | HitLight strobe-off default → camera-aware warnings |
| 17 | **Resume exactly where you left off** | Crash, reboot or power cut: Prism relaunches (optional launch at login) and restores the last look within seconds. An explicit setting covers "When Prism quits: keep lights / fade out / blackout". A watchdog blacks out or holds safely if the app hangs | Lightkey's "lights go out when I quit" support topic; Luminair "blackout on load"; HitLight watchdog → explicit, tested behaviour |
| 18 | **Hardware health panel** | "DMX box connected (Enttec S/N…) · 40 fps · all 5 lights verified". Plain-language fixes for "another app is using the DMX box", the Local Network permission, or a cable/termination issue | Enttec support docs, Lightkey's Local Network note → proactive diagnostics |
| 19 | **Visualizer that *is* the controller** | A room photo or top-down plan with glowing fixtures. Click to select, lasso to group, scroll to dim, right-click → "Blink" | Lightkey 2D preview → photo-real background, direct manipulation, pixel-accurate tube rendering |
| 20 | **Studio templates** | "Podcast — 2 hosts", "Talking head", "Product table", "Gaming room" create roles, groups and starter looks | Nobody ships studio-genre templates |
| 21 | **3-knob effects with live thumbnails** | Every effect has Speed, Size/Spread and Intensity (plus palette), with animated previews. Names match the creator's vocabulary (Candle, TV, Fire, Lightning, Cop Car, Paparazzi, Pixel Chase…) | Sidus FX (§5), WLED Speed/Intensity → consistent across brands, tempo-syncable, rendered by Prism |
| 22 | **"Brand colours from an image"** | Drop a logo or screenshot and Prism extracts a palette, then applies it to the background tubes or saves it as a swatch set | Nobody in DMX does this; it fits the YouTuber brand-consistency need |
| 23 | **Integrations as presets with feedback** | Stream Deck plugin showing look thumbnails and live state on keys. Companion module with presets, feedbacks and variables. OBS scene ↔ look linking. "Copy OSC address / HTTP URL / Shortcut" on any look | Lightkey "Copy OSC Address" (but no feedback), Blackout Stream Deck → feedback + OBS + Shortcuts first-class |
| 24 | **Routines and schedules** | "Studio open 9:00", "Wind down 18:00", "When OBS starts recording → Recording look", "When the Mac sleeps → fade out" | Luminair astronomical scheduler, Companion triggers → human-language rules, start disabled until tested |
| 25 | **Shareable single-file projects** | A `.prism` document embeds fixture profiles, the stage photo, looks with thumbnails and folders. Share a *single look* by AirDrop, link or QR. Imports merge with a preview and an automatic backup | Blackout backup-before-import and partial merge; Lightkey's embedded profiles → self-contained, look-level sharing |
| 26 | **Profile from a photo or PDF of the DMX chart** | For a light not in the library, snap the manual's chart. Prism drafts a profile and walks a 30-second test checklist to mark it verified. Optionally exports to GDTF/OFL | HitLight draft profiles; SoundSwitch/Lightkey "email us the manual" → instant, local, verified by test |
| 27 | **Swap a light, keep the looks** | "Replace PT2c with PT4c" re-maps looks by *colour intent* (Kelvin/tint/hue), not channel values | MagicQ head morphing, Luminair Replace Fixtures → intent-based |
| 28 | **Troubleshooter that knows your rig** | "Light not responding?" runs a guided tree. The AI help sees the actual patch ("Your PT4c at 017 is in *CCT&RGB*; Prism expects *HSI 8-bit*. Change Prism or the light?") | Blackout "Ask PATCH", SoundSwitch support tickets → automatic, offline-capable |
| 29 | **Lock and kiosk** | Touch ID / Apple Watch to edit. Kiosk shows only big look buttons and a master dimmer. Looks can be marked "requires unlock" | Lightkey per-cue lock, MagicQ Execute window, Luminair Lockdown → combined with guest scopes |
| 30 | **History timeline** | Unlimited undo plus a scrubbable "what changed" history ("Restore the look from 10 minutes ago", "Who changed this? — Guest phone 'Alex'") | Lightkey unlimited undo → multi-user attributed history |

---

## 4. Why DMX patching confuses beginners, and a beginner-proof patch workflow for Prism

### 4.1 Root causes of confusion (evidence)

| # | Problem | What beginners experience | Evidence |
|---|---|---|---|
| 1 | **DMX has no discovery.** Nothing on the wire says what a fixture is. The software only knows because someone typed in a profile and an address. (RDM exists, and the Enttec DMX USB Pro supports it, but most creator fixtures don't, or users never enable it.) | "I plugged everything in and nothing happens." | https://www.hitlight.app/ai-dmx-software ("DMX has no discovery"), https://www.enttec.com/product/dmx-usb-interfaces/dmx-usb-pro-professional-1u-usb-to-dmx512-converter/ (DMX/RDM) |
| 2 | **Vocabulary overload.** Channel vs address vs universe vs mode/personality/profile vs footprint. Theatre consoles even use "channel" to mean a fixture number. | People ask "what's the difference between channels and addresses?" | https://www.reddit.com/r/explainlikeimfive/comments/1uychjh/eli5_dmx_channels_adresses_and_universes/ |
| 3 | **Mode (personality) mismatch** between the light and the software | Wrong colours, strobing, the dimmer acting like a colour channel | https://www.y-link.no/en/guides/dmx-channel-modes, https://www.reddit.com/r/lightingdesign/comments/1h42ko1/dmx_lights_working_on_channel_1_dont_understand/ |
| 4 | **Address overlap / everything on 001** (the factory default for amaran and most fixtures) | All lights do the same thing, or one light's colour channel changes another light's dimmer | https://www.reddit.com/r/lightingdesign/comments/14pvlpj/dmx_noob_question/, https://betopperdj.com/blogs/news/dmx-addressing-made-simple-how-to-set-up-multiple-fixtures-without-conflicts |
| 5 | **Setting the address on the physical light** works differently on every fixture: binary DIP switches, 4-digit "A001/d001" menus, deep OLED menus | People give up at the light, often up a ladder, without the manual | Lightkey ships DIP-switch helpers (specs); amaran PT menu path (§1.4) |
| 6 | **Fixture-side state.** The light must be in DMX mode. amaran PT tubes **only listen while the DMX Settings screen is shown**, and the address must be *locked* by holding OK for 2 s. Sound-active or standalone modes override DMX. | The light "ignores" DMX until someone leaves the right menu open | https://help.aputure.com/en/amaran-pixel-tubes/wired-dmx-control |
| 7 | **Pixel fixtures multiply footprints.** "Standard" vs "LE/pixel" profiles: a 16-pixel tube can take ~16× more channels in pixel mode | The universe fills up surprisingly fast; addresses collide | https://help.aputure.com/en/infinimat/profile-selection-and-patching-strategies |
| 8 | **Cabling.** Daisy-chain order doesn't matter for addressing, but people think it does. Termination, 3-pin vs 5-pin, mic cables vs 110 Ω DMX cable, the amaran **USB-C→DMX adapter sold separately** | Flicker, intermittent response, "only the first light works" | amaran PT manual (adapter), https://www.y-link.no/en/guides/dmx-channels-explained-with-real-fixture-examples |
| 9 | **Off-by-one, zero-based and inconsistent numbering.** Art-Net universe 0 vs sACN universe 1; DMX slot 0 = start code; some UIs show 0–511. Every console writes addresses differently: Eos `2/1`, grandMA3 `2.001`, QLC+ absolute `513` | Lights respond one channel or one universe off; tutorials from one product don't transfer to another | Art-Net/sACN specs (§1.33); ETC/MA/QLC+ documentation (§1.14–§1.16) |
| 10 | **Interface/driver issues.** On macOS the Enttec isn't found when **another app has the port open** or FTDI drivers conflict. Open DMX/Eurolite need an admin password at every launch in Lightkey. | "Software says no interface" | https://support.enttec.com/dmx/usbdmx-dmx-usb-pro-70304/macos-software-not-recognizing-dmx-usb-pro, Lightkey specs |
| 11 | **Wrong or missing profiles** (firmware revisions add modes) | Can't find their light; build profiles by hand from PDF charts | HitLight "Request it" flow, Lightkey profile requests |
| 12 | **DMX-loss behaviour surprises.** Lights black out, or hold the last look, when the app quits or a cable is bumped | "Lights go out when I quit the app" | https://glmedia.tech/technical-help/lightkey-colors-cues-priorities/, amaran DMX Loss Behavior |

### 4.2 Design principles
1. **Never ask the user to think in channels.** Show lights, not numbers. Addresses are an implementation detail that Prism picks and then *teaches* the user to set on the light.
2. **Prism decides, the user confirms.** Auto-address, auto-mode (with a recommended mode) and auto-layout come first; editing is optional.
3. **Model-specific, illustrated instructions for the physical light**, delivered where the user is standing (on the phone via QR).
4. **Every step is verified by observation**: blink tests, a "Is it red now?" checklist, and the camera.
5. **Mistakes are detected and fixed in one click**, with an updated instruction card for any light that needs changing.
6. **Plain language everywhere** ("Whole tube = one colour" vs "Each pixel separately"). Jargon sits behind a "Show DMX details" disclosure.
7. **1-based numbering only. Universe "1" is the first universe.** Never show 0–511.

### 4.3 Step-by-step beginner-proof patch wizard

**Step 0: Interface check ("Connect your DMX box").**
- Detect the Enttec DMX USB Pro (FTDI-based, USB VID 0x0403 / PID 0x6001) and read its **serial number and widget parameters** (firmware, break time, refresh rate) through the documented widget API (https://cdn.enttec.com/pdf/assets/70304/70304_DMX_USB_PRO_API.pdf). Show "✓ ENTTEC DMX USB PRO connected (S/N …)".
- If the device exists but can't be opened, say so plainly: **"Another app is using your DMX box (e.g., Lightkey, QLC+, EMU). Quit it and click Retry."** This is the top macOS cause per Enttec support.
- Provide an output **heartbeat indicator** (frames/s) and a **"Test signal"** button.
- If there's no interface yet, let the user continue in **visualizer-only mode** (HitLight shows this lowers the barrier).

**Step 1: "What lights do you have?"**
- Brand-first visual picker with product photos ("Aputure / amaran → Pixel Tubes → PT4c") and a quantity stepper ("3×").
- Search tolerates loose names ("amaran tube 4ft").
- **Optional photo identification**: take a picture of the light or its label, and Prism suggests models.
- Recently used and "studio favourites" (Aputure, amaran, Nanlite, Godox, Astera…) first.

**Step 2: "How do you want to control it?" (mode choice in plain language)**
- For each model show 2–3 human-labelled options with a recommended default, e.g. for amaran PT4c:
  - ★ **"Simple colour (whole tube)"**: CCT + tint + RGB, low channel count. Best for key, fill and background.
  - **"Pixel effects (16 separate zones)"**: needed for chases, rainbows and fire; uses many more channels.
  - "Advanced / 16-bit": hidden under "More options".
- Map each label to the manufacturer's exact profile name, so the instruction card can say *exactly* what to pick on the fixture. Show the factory default where known: amaran PT ships with profile **CCT&RGB** and address **001**.
- A live **channel budget bar** ("You've used 96 of 512") warns before a second universe is needed.

**Step 3: Prism assigns addresses automatically**
- Default to **"easy numbers"**: each light starts on a round number (1, 21, 41… or 1, 101…) so the numbers are easy to remember, with room to switch modes later without re-addressing everything. "Compact" packing is an option.
- Show a **visual universe map**: one 512-cell strip with a coloured block per light, labelled with the light's name. Hover a block to highlight the light on the stage.
- **Linking is explicit.** If the user wants lights to act as one, they choose "Make these lights act as one" and Prism *deliberately* gives them the same address. Accidental overlap is never silent.

**Step 4: "Set up each light" cards (tell the user exactly what to do on the physical fixture)**
- One card per light: a photo or illustration of *that* model's control panel, the target values in huge type, and numbered steps. Example for an amaran PT4c (from Aputure's documentation):
  1. Plug the **amaran USB-C → DMX adapter** into the tube. Connect a DMX cable from the ENTTEC's DMX OUT (or from the previous light's DMX OUT).
  2. Press **MENU → DMX Settings**.
  3. **DMX Address → 017**.
  4. **DMX Profile → "CCT&RGB"** (whatever Step 2 chose).
  5. **DMX Loss Behavior → "Hold Last Setting"** (recommended for studios: the light stays on if the computer sleeps or a cable is bumped) or "Fade to Black".
  6. **Stay on the DMX screen and hold OK for 2 seconds to lock it.** The tube only listens to DMX while this screen is shown.
- For **DIP-switch fixtures**, render the switch bank with the exact ON/OFF pattern for the address (Lightkey does this). For **4-digit LED menus**, show the display text to look for ("A017", "d017"), the button sequence, and the mode code as it appears on the display ("8CH", "P2").
- **Hand-off to phone:** a QR code on each card opens the same card on the user's phone (through the Prism remote), so instructions are with them at the light stand. Cards can also be printed as a **setup sheet** or **sticker labels** ("Background Tube L — 017 — CCT&RGB").
- When the profile came from a manual or user data, Prism marks it **"draft — verify"** (HitLight's pattern) and asks the user to confirm each feature in Step 5.

**Step 5: "Find & confirm" (verify by observation)**
- **Identify:** Prism pulses one light (slow white breathing, or a distinctive colour) and asks "Which light is pulsing?" The user clicks it on the stage view or answers "none". This also binds the patch to positions.
- **Feature checklist**, one tap each: "Is it **red** now? **green? blue?**", "Is it **warm** (orange-ish) now, then **cool** (bluish)?", "Pixel mode: is the **rainbow going left → right**?" (Prism offers **Flip direction** or **Start from the other end** if it's reversed).
- **Diagnosis tree for "No" answers:**

  | Symptom | Likely cause | One-click fix |
  |---|---|---|
  | Nothing lights | Not on the DMX screen, adapter or cable issue, wrong address | Re-show the card; run a cable test |
  | Wrong colours, or strobe/flicker | Mode mismatch | Choose the mode the light is actually in, or redo card step 4 |
  | Two lights react together | Address overlap | Auto re-address and issue a new card |
  | Pixels in the wrong order | Orientation | Flip |
  | Flicker or jumpy only at the end of the chain | Termination / cable | Show the terminator tip |

**Step 6 (optional): camera verification and auto-layout**
- With the Mac or iPhone camera pointed at the set, Prism blinks each patched light in turn (or uses a time-coded colour sequence). It detects *which* region of the image changes, confirms the patch, catches swaps ("the light you called 'Key' is actually on 033; swap?") and pre-places fixtures on the 2D stage at their camera-image positions.
- After setup, the same mechanism powers "**Check my lights**", a 10-second health test before recording.

**Step 7: Place and name**
- Drag lights on the 2D stage (top-down room plan or a photo of the set as the background). Prism suggests names from position and role ("Key", "Fill", "Back Left", "Background Tube 1").
- Group automatically by model and position ("All tubes", "Background").

**Step 8: Save, summarize, protect**
- Summary page: "5 lights, 1 universe, 104/512 channels, all verified ✓". Export a PDF patch sheet and labels. Create an automatic snapshot backup.
- Persist the interface serial number so the project re-binds to the right device automatically.

**Ongoing safety nets after the wizard**
- A **conflict watchdog** for overlap, out-of-range addresses, or a universe overflowing because a mode changed. Each problem is explained in a sentence and offered as a single "Fix it" action, which issues new instruction cards for the lights that must be changed physically.
- **Mode-change assistant:** switching a light to pixel mode recalculates addresses and tells the user exactly which lights need new settings.
- **"Light not responding?"** button on every fixture runs the diagnosis tree.
- **RDM (P2):** for RDM-capable fixtures, discover, identify and set addresses remotely through the Enttec Pro, skipping Step 4.
- **Pro escape hatch:** a classic patch table with numeric entry, CSV import/export, and import from Lightkey / QLC+ / OFL / GDTF.

### 4.4 Precedents this design borrows from (and what Prism adds)

| Mechanism | Best existing example | Prism addition |
|---|---|---|
| Auto universe + auto address + footprint readout + quantity + auto names | ONYX Auto Patch (§1.14) | Hidden behind "Add 3 × PT4c"; addresses rounded to easy numbers |
| Live universe map | ONYX Universe View | Blocks labelled with light names, linked to the stage map |
| Conflict dialog instead of silent overlap | ONYX "Unpatch / Edit / Cancel" | Overlap impossible unless the user explicitly links lights |
| Mode helper | grandMA3 v2.5 Channel Map (§1.15) | Plain-language mode cards with a recommended default |
| DIP-switch drawing for the chosen address | Lightkey, Resolume (§1.1, §1.13) | Full per-model menu walkthroughs, delivered to the phone by QR |
| Pixel panel/tube wizard | QLC+ "Add RGB Panel" (§1.5) | Direction check ("is the rainbow going left → right?") with Flip |
| Identify / highlight | ONYX Patch Highlight, Sidus Fixture Locator, Elgato identify | Identify by click and by camera |
| Patch now, address later | MagicQ (§1.6) | Visualizer-only mode until the Enttec is plugged in |
| Swap fixture, keep programming | MagicQ head morphing, Luminair Replace Fixtures, grandMA3 Recipes | Re-map by colour intent |
| Ready-made content after patching | grandMA3 Startshow | Studio templates generate Key/Fill/Back/Background looks |
| Profile request / draft from a manual | Blackout "Request a Profile", HitLight AI draft (§1.2) | Local draft plus a guided 30-second verification |

> [!NOTE]
> RDM is P2 because we couldn't verify RDM support on amaran/Aputure creator fixtures. Promote it to P1 if testing shows the user's fixtures answer RDM discovery through the Enttec DMX USB Pro.

---

## 5. Aputure Sidus Link effects and colour tools: reference for reimplementation as Prism software effects

**Sources:**
- Sidus Link mobile "Modes and Functions": https://help.aputure.com/en/sidus-link-pro/sidus-link-mobile/modes-and-functions
- Sidus Link Pro "Using Effects": https://help.aputure.com/en/sidus-link-pro/using-effects
- amaran Pixel Tube manual FX: https://help.aputure.com/en/amaran-pixel-tubes/manual-fx-control
- PT manual PDF: https://aperturent-static.s3.amazonaws.com/documents/AmaranPT2cRGBWWLEDPixelTubeLight2-ft2-LightProductionKit.pdf
- Sidus software page: https://www.sidus.link/software

Ranges are as documented. Where Aputure only gives an abstract 1–10 scale, the "Prism implementation sketch" column proposes concrete behaviour. Those sketches are *our design suggestions*, not Aputure's internal algorithms.

> [!NOTE]
> Implementing these in Prism (rather than triggering the fixture's built-in FX over DMX) gives one consistent effect engine across all brands. It also syncs effects across multiple fixtures, adds music/tempo sync, and lets the visualizer preview exactly what's sent. Many fixtures' DMX profiles expose the built-in FX only through an "FX channel" with coarse control, so software effects on top of the CCT/RGB channels are more flexible. They don't need firmware-specific DMX value tables either.

### 5.1 Common parameter vocabulary
- **INT**: effect intensity, 0–100%. In Sidus Pro, setting intensity to 0 *doesn't* clear an effect.
- **Base colour / mode**: **CCT** (Kelvin + G/M), **HSI** (hue 0–359°/1–360°, saturation 0–100%, white-point CCT) or **GEL** (a LEE/Rosco gel on a 3200K or 5600K base). Many effects let you pick which.
- **FRQ** ("frequency"): 1–10, often with a **Random** option. It sets how *often* events happen (flashes, flickers).
- **Speed**: 1–10. It sets how *fast* each event or transition is. Some pixel FX use **physical units (cm/s)**, so motion looks the same on 1 ft and 4 ft tubes.
- **Trigger**: manual one-shot button (Lightning, Explosion).
- **Loop/Stop**: whether a one-shot effect repeats (Paparazzi on the PT tubes).

### 5.2 System FX (up to 15 on Colour-Pro fixtures; 9 on amaran PT tubes, marked ✓PT)

| Effect | Documented parameters | What it looks like | Prism implementation sketch |
|---|---|---|---|
| **Paparazzi** ✓PT | INT; CCT 1600–10000K (mobile doc) / 2700–10000K (PT); G/M −1.0…+1.0 (M1.0–G1.0); FRQ 1–10 (PT adds Random); PT: Stop/Loop | Random camera flashes | Poisson process of flashes at λ = FRQ-mapped 0.3–6 flashes/s. Each flash: 20–60 ms at full INT with a 50–150 ms exponential tail. Optionally run *per fixture* independently for a crowd feel |
| **Lightning** ✓PT | INT; CCT 2000–10000K (PT 2700–10000K); G/M; FRQ 1–10/Random; Speed 1–10 (mobile); **manual Trigger** | Multi-stroke lightning flashes with irregular brightness | Stochastic "stroke train": 1–4 strokes of 30–120 ms with 40–200 ms gaps and random peaks of 40–100%. Interval between events from FRQ. Trigger fires one train. Sync a "thunder" OSC/MIDI out for sound designers |
| **TV** ✓PT | INT; colour range **Warmer 2800–4700K / Natural 4700–6500K / Cooler 6500–10000K** (PT: Warmer/Neutral/Cooler); Speed 1–10 (PT: FRQ) | Flicker of a TV screen off-camera: random brightness and colour-temperature cuts | Sample-and-hold: every 0.1–2 s (Speed) jump to a random CCT in range and intensity 30–100%, with occasional fast 2–3 frame "cuts". For a colour TV variant add low-saturation hue jitter |
| **Fire** ✓PT | INT; **Warmer 1800–2000K / Natural 2200–2600K / Cooler 2600–3000K**; Speed 1–10 (PT: FRQ) | Firelight flicker | Sum of 2–3 octaves of smoothed noise (Perlin/pink) on intensity (40–100%). CCT tracks intensity, lower when dimmer (black-body behaviour). Speed scales the noise time base (≈0.5–6 Hz dominant) |
| **Candle** | INT; **Warmer 1400–1700K / Natural 1700–2000K / Cooler 2000–2300K**; Speed 1–10 | Gentle, slower flicker than Fire | Low-amplitude pink noise (75–100%) plus rare "gust" dips to 50%. Warmer CCT range |
| **Faulty Bulb** ✓PT | INT; base **CCT / HSI / GEL**; FRQ 1–10/Random; Speed 1–10 | A failing bulb: mostly on with random dropouts and buzz | Two-state Markov chain (on/failing). In "failing", 5–30 Hz flicker bursts and drops to 0–30%. FRQ sets how often failures start, Speed how fast the flicker is |
| **Pulsing** ✓PT | INT; base (CCT [CCT, G/M] or HSI [HUE 0–359, SAT]); FRQ 1–10; Speed 1–10 | Smooth breathing | Raised-cosine intensity wave between ~5% and INT. Period from Speed (≈4 s → 0.25 s). Tempo-syncable (1, ½, ¼ beat) |
| **Strobe** | INT; base; FRQ; Speed 1–10/Random | On/off flashes | Square wave with short duty (10–20%), 1–15 Hz. **Prism: cap at ≤3 Hz by default (photosensitivity) with an explicit "allow fast strobe" toggle.** Prefer the fixture's hardware shutter channel if it has one |
| **Explosion** | INT; base; **Decay 1–10**; **manual trigger only** | Instant flash that decays with flicker | Attack at 0 ms to 100%. Exponential decay with τ from Decay (0.3–5 s) plus decaying noise flicker. Colour shifts warmer during decay |
| **Welding** | INT; base; **MIN** (minimum intensity between flickers); FRQ | Arc-welding flicker | High-frequency random flicker (8–25 Hz) between MIN and INT, in bursts separated by pauses (FRQ). Cool bluish-white base by default |
| **Cop Car** ✓PT | INT; Colours **Red / Blue / Red+Blue / Blue+White / Red+Blue+White**; **Flash 1–5**; **Cycle 1–5** (PT: FRQ) | Emergency light bar | Pattern table: N flashes per colour (Flash), alternating colours. Cycle sets the repetition rate. With multiple fixtures, alternate left/right ("wig-wag"). With pixel tubes, split halves |
| **Club Lights** | INT; Colours **3/6/9/12/15/18/24/36**; Speed | Stepping through saturated colours | N equally spaced hues (360/N). Hard steps at the Speed rate. Pixel or group mode: offset phase per fixture |
| **Color Chase** | INT; SAT; Speed | Continuous colour rotation | Hue ramp 0→360° over a period from Speed. Across a group or pixels apply a phase spread (rainbow chase) |
| **Party Lights** ✓PT ("Party Light") | INT; SAT; Speed (PT: FRQ) | Random colour jumps | Random hue each step (with a minimum hue distance of 60° from the previous). Steps at the Speed/FRQ rate. Optional crossfade |
| **Fireworks** ✓PT ("Firework") | INT; colour type **CCT / Color (HUE) / Multi (CCT+HUE)**; FRQ 1–10/Random; CCT random 1600–10000K (PT mode CCT/HUE/CCT+HUE) | Bursts of colour that sparkle out | Random bursts: fast rise, then 0.5–2 s decay with sparkle (random dropouts at 10–20 Hz). New burst colour each time from the chosen palette. On pixels, spawn at a random pixel and spread outward |

### 5.3 Pixel FX (amaran PT1c/PT2c/PT4c: 4/8/16 pixels; similar on INFINIBAR / MT Pro)

| Effect | Documented parameters | What it looks like | Prism implementation sketch |
|---|---|---|---|
| **Color Fade** | INT; **Color No. 2/3/4**; each colour = HUE (30° steps) **or** CCT (2500/3200/4300/5600/6500/7500K); **Speed 1–640 cm/s**; **Move Left/Right**; Play/Pause/Stop | Smooth gradient of 2–4 colours scrolling along the tube | Build a cyclic gradient texture across the tube length (1 period = tube length, or user-defined). Scroll at a physical speed in cm/s, converted to pixels/s using the profile's pixel pitch (PT: 4 px/ft ≈ 7.6 cm/pixel) |
| **Color Cycle** | INT; Color No. 2/3/4; colours as above; **Speed 0.1–10.0 s** (time per colour); **Transition Step / Smooth** | Whole tube cycles through colours | Time-based palette cycler; Smooth = crossfade in OKLab/HSI space, Step = hard cut |
| **One / Two / Three Pixel Chase** | **Pixel INT**; **Bkgd INT**; **Pixel Size S/M/L**; **Departure 1-way / 2-way**; pixel colour; background colour (**Black allowed**); Speed 1–640 cm/s; **Move Left / Loop / Right** | 1, 2 or 3 moving "comets" over a background colour | Render N blobs of width S/M/L (1/2/4 px, soft edges) moving at a physical speed. 2-way = start from both ends. Loop = ping-pong. Background is a constant colour/intensity |
| **Rainbow** | INT; Speed (cm/s); Move Left/Right | Scrolling rainbow | Hue gradient across the length (1 full spectrum per tube or per group) scrolling at the given speed |
| **Pixel Fire** | **Dim Range** low end 0–65%, high end 25–100%; Bkgd INT; fire colour + background colour; **Frequency 0.1–10 Hz**; **Move Horizontal / Vertical** | Flames licking along the tube | 1D fire simulation (heat diffusion plus random sparks at the "base" end) mapped to a black-body palette; Vertical = flames rise from the bottom, Horizontal = travel along. Clamp intensity to Dim Range |

Custom slots on PT, INFINIBAR and MT Pro: **10 Picker FX + 10 Music FX** stored on the fixture.

### 5.4 Sidus Link Pro effect families (beyond the System and Pixel lists)
- **Manual FX**: 30+ parameters for building custom effects (layering base colour, rate, randomness, envelope).
- **Picker FX**: the camera samples colours live and plays them back on the light (for example, matching a screen or a fire in shot). *Prism equivalent:* "Match screen" (sample a region of the Mac's display, or a video file / camera feed) feeding a smoothed colour track. Useful for ambient "TV glow" synced to real content.
- **Magic Program**: a **keyframe timeline** (colour/intensity keys, interpolation, loop). *Prism:* a timeline editor per Look/Effect.
- **Magic Infinity FX**: generative, non-repeating variations. *Prism:* seeded noise-driven effects with "variation" and "calmness" knobs.
- **Music FX**: FX:S (≤120 s stored to the fixture), FX:P (project up to 30 min) and LIVE (device microphone). Analyses frequency bands and BPM and maps colours per band, with clip-fade editing. *Prism:* system-audio capture through Core Audio process taps (macOS 14.2/14.4+), with band→colour/intensity mapping and beat-quantized changes.
- **PALETTE**: saved colour palettes applied to effects.

### 5.5 Colour tools to replicate (non-effect)

**White / CCT.** Kelvin plus a **G/M tint of −100…+100** (on-fixture −1.0…+1.0), intensity 0–100% with **dimming curves Linear / Exponential / Logarithmic / S-curve**.

**Dimming Design.** A three-stage envelope for timed fades (useful for "slow sunrise" looks):

| Stage | Settings |
|---|---|
| Fade-in | begin intensity → mid, with a duration |
| Continue | holds the mid intensity, with a duration |
| Fade-out | mid → end intensity, with a duration |
| Start delay | 0–60 s |

**SourceType (17 presets):**

| Preset | CCT | Preset | CCT |
|---|---|---|---|
| Sunrise/Sunset | 1850K | Studio Lamp | 3200K |
| Candle | 1900K | Studio CP | 3350K |
| Moonlight | 8000K | HMI | 5600K |
| Horizon Daylight | 5000K | HMI | 6000K |
| Day White | 5600K | HP Sodium | 2200K |
| Daylight | 6500K | Warm White Halogen | 2700K |
| Overcast | 7000K | NW Metal Halide | 4300K |
| Blue Sky | 10000K | Xenon short-arc | 6200K |
| Tungsten | 3200K | | |

Real-source presets should eventually carry tint as well as CCT (sodium and metal halide sit off the Planckian locus). That's a Prism improvement.

**SourceMatch.** The camera measures ambient CCT; you then trim ±300 K and G/M ±100. *Prism:* use the Mac or iPhone camera (or a connected colour meter) to measure the room and offer "Match the window light".

**Gel.**

| Gel family | Values |
|---|---|
| CTB fractions | 1/8, 1/4, 1/2, 3/4, Full |
| CTB from a 3200 K base | 3600 / 3800 / 4600 / 5500 / 6500 K |
| CTO fractions | same five fractions |
| CTO from a 6500 K base | 5500 / 4600 / 3800 / 3600 / 3200 K |

Beyond CTO/CTB, Sidus offers 300+ **LEE** gels (Color Correction, Color Filters, 600 series, Cosmetic, 700) and **ROSCO** gels (Color Correction, CalColor, Storaro, Cinelux) on a 3200 K or 5600 K base, searchable by name, number or colour. *Prism:* compute gel colours as published spectral transmission × base illuminant (or use the manufacturers' published xy/Y values), rendered to the fixture's emitters.

**HSI(C).** Hue 0–359°, saturation 0–100%, intensity, plus a white-point CCT of 2000–10000 K and G/M (what "saturation 0" means).

**RGB.** 0–255 (Pro adds hex entry).

**CIE 1931 xy.** Gamut overlays for A.Gamut/BT.2020, DCI-P3 and BT.709.

**Color Picker.** The camera samples a colour; you then trim hue ±10° and saturation ±10%.

### 5.6 Implementation notes for Prism's effect engine
1. **Engine model:** each effect is a pure function `f(t, fixtureIndex, pixelIndex, params, beatClock, audioFeatures) → colour (linear-light XYZ or CCT/tint/HSI) + intensity`. Evaluate at the DMX output rate and at screen refresh for the visualizer. A full 512-slot DMX512 frame tops out at ≈44 Hz; the Enttec Pro's refresh rate and break time are configurable through its API/EMU.
2. **Colour pipeline:** do all maths in linear light or OKLab, then convert per fixture to its emitters (RGB, RGBW, RGBWW, CCT+tint channels) with gamut mapping. This is what makes "same colour on different brands" possible.
3. **Common controls on every effect:** Intensity, Speed (or BPM sync with ½×/2×), Spread/phase across fixtures, Direction, Randomness, Palette, Fade-in/out of the effect itself.
4. **Physical units for pixel motion** (cm/s, as Aputure does) keep mixed-length tube groups coherent.
5. **Determinism:** seeded randomness, so a look recalled later (or on the phone remote) matches the visualizer.
6. **Safety:** strobe/flash rates are capped by default, with a photosensitivity warning before raising them.

---

## 6. Key sources

Every URL cited above, grouped by the section that cites it (accessed October–November 2026).
- Vendor documentation, manuals, release notes and App Store pages support the feature claims.
- Reddit and vendor-forum threads support the user complaints.
- Items flagged as unverified in the text have no primary source here.

**§1.1 Lightkey:** https://lightkeyapp.com/en/specs · https://lightkeyapp.com/en/help · https://www.hitlight.app/alternatives/lightkey · https://lightkeyapp.com/en/fixtures · https://forum.derivative.ca/t/drive-bpm-speed-for-lightkey-dmx-software-from-touchdesigner-via-osc/413987 · https://github.com/jamesarrowood/LightKeyHA · https://glmedia.tech/technical-help/lightkey-colors-cues-priorities/ · https://www.reddit.com/r/lightingdesign/comments/1ezx7jx/ · https://www.reddit.com/r/stagelighting/comments/1sjv3fc/ · https://www.reddit.com/r/lightingdesign/comments/1s7y64g/ · https://www.reddit.com/r/lightkey/comments/1w8yl9n/

**§1.2 HitLight:** https://www.hitlight.app/ · https://www.hitlight.app/alternatives/lightkey · https://www.hitlight.app/ai-dmx-software · https://www.hitlight.app/dmx-app-for-iphone-and-ipad · https://www.hitlight.app/connect-ai

**§1.3 Other notable "AI / autonomous" and simple controllers discovered:** https://maestrodmx.com/ · https://www.dmxdesktop.com/dmx-software-mac · https://apps.apple.com/es/app/audio-lights-dmx/id6761784463 · https://www.maizedmx.com/ · https://apps.apple.com/us/app/maizedmx/id1600836335 · https://simpledmx.net/ · https://www.chromateq.com/dmx-software-downloads/ · https://www.t3.com/home-living/smart-home/you-can-now-control-your-nanoleaf-smart-lights-via-chatgpt-and-claude-heres-how · https://github.com/film42/wled-mcp

**§1.4 Aputure Sidus Link:** https://help.aputure.com/en/sidus-link-pro/sidus-link-mobile/modes-and-functions · https://www.sidus.link/software · https://help.aputure.com/en/sidus-link-pro/using-effects · https://www.cined.com/amaran-pt1c-pt2c-and-pt4c-pixel-tubes-introduced/ · https://amarancreators.com/pages/amaran-pt2c · https://aperturent-static.s3.amazonaws.com/documents/AmaranPT2cRGBWWLEDPixelTubeLight2-ft2-LightProductionKit.pdf · https://help.aputure.com/en/amaran-pixel-tubes/wired-dmx-control · https://help.aputure.com/en/amaran-pixel-tubes/light-configuration-settings · https://help.aputure.com/en/education/basic-vs-control-channel-dmx-profiles · https://help.aputure.com/en/infinimat/profile-selection-and-patching-strategies · https://www.reddit.com/r/videography/comments/wgzyvv/ · https://www.reddit.com/r/cinematography/comments/1c52498/ · https://www.reddit.com/r/cinematography/comments/11o8il4/ · https://help.aputure.com/en/sidus-link-pro/common-connection-issues

**§1.5 QLC+:** https://github.com/mcallegari/qlcplus · https://www.reddit.com/r/lightingdesign/comments/1tlg4ip/ · https://www.reddit.com/r/lightingdesign/comments/1orevfn/do_people_actually_use_qlc/ · https://www.reddit.com/r/lightingdesign/comments/1qmvdpr/

**§1.6 ChamSys MagicQ:** https://chamsyslighting.com/software/magicq-software-licensing/ · https://www.reddit.com/r/ChamSys/comments/16la217/ · https://www.reddit.com/r/ChamSys/comments/1kdnyzf/ · https://www.reddit.com/r/ChamSys/comments/1g6gfmu/

**§1.7 Blackout Lighting Console:** https://www.newsshooter.com/2025/04/22/blackout-introduces-flexible-subscription-plans/ · https://apps.apple.com/us/app/blackout-lighting-console-v3/id6767651757 · https://www.reddit.com/r/lightingdesign/comments/1gon91l/

**§1.8 Luminair 4:** https://luminair.app/ · https://luminair.app/pro

**§1.9 Photon 2:** https://apps.apple.com/us/app/photon-2-dmx-light-controller/id1545017671

**§1.10 SoundSwitch:** https://www.soundswitch.com/ · https://support.soundswitch.com/en/support/solutions/articles/69000847091 · https://community.enginedj.com/t/what-bothers-me-most-about-soundswitch/67266 · https://community.enginedj.com/t/soundswich-does-not-analyze-the-phrases-correctly/65550 · https://www.reddit.com/r/DJs/comments/1hlfp93/

**§1.11 LightJams:** https://www.lightjams.com/musicToDMX.html

**§1.12 MadMapper 6:** https://madmapper.com/madmapper/software · https://docs.madmapper.com/madmapper/6/faqs

**§1.13 Resolume Arena:** https://resolume.com/support/en/dmx · https://support.enttec.com/dmx/edmx-art-net-sacn-networking/using-resolume-arena-with-enttec-art-net-nodes

**§1.14 Obsidian Control Systems ONYX:** https://support.obsidiancontrol.com/ · https://www.obsidiancontrol.com/pages/faq-brand · https://forum.obsidiancontrol.com/t/obsidian-control-systems-driver-package-x64-has-falled/7675 · https://support.obsidiancontrol.com/Content/License_Information/Onyx_PC_Modes.htm · https://forum.obsidiancontrol.com/t/enttec-and-onyx/5186 · https://www.obsidiancontrol.com/products/nx-dmx · https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/Auto_Patch.htm · https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/Assigning_DMX_Addresses.htm · https://support.obsidiancontrol.com/Content/Onyx_Manual/Patch/RDM.htm · https://forum.obsidiancontrol.com/t/does-onyx-have-a-gdtf-fixture-finder/8376 · https://support.obsidiancontrol.com/Content/Onyx_Manual/Programming/FX/FX_Controls.htm · https://www.elationlighting.com/blogs/news/obsidian-control-systems-announces-release-of-onyx-4-4-featuring-creative-dylos-pixel-composer · https://apps.apple.com/us/app/onyx-remote/id338679276 · https://bitfocus.io/connections/obsidiancontrol-onyx · https://www.reddit.com/r/lightingdesign/comments/1my5ru2/ · https://forum.obsidiancontrol.com/t/onyx-crashing-regardless-of-show-file-or-pc/8511 · https://forum.obsidiancontrol.com/t/onyx-v4-6-freezing-on-windows-11/7735 · https://www.reddit.com/r/lightingdesign/comments/woefhp/onyx_vs_chamsys/ · https://github.com/bitfocus/companion-module-obsidiancontrol-onyx/issues/5

**§1.15 grandMA3 onPC:** https://www.malighting.com/special/grandma3-software/ · https://help.malighting.com/grandMA3/2.2/HTML/qsg_output_dmx.html · https://www.malighting.com/product/grandma3-onpc-dmx-key-starter-4035534/ · https://support.actentertainment.com/knowledgeBase/24775922 · https://help.malighting.com/grandMA3/2.5/HTML/ft_import_gdtf.html · https://www.reddit.com/r/GrandMA3/comments/1j3gf0y/patch_error/ · https://help.malighting.com/grandMA3/2.5/HTML/sfh_backup.html · https://www.reddit.com/r/lightingdesign/comments/wyw1k4/grandma_on_mac_crashing/ · https://www.reddit.com/r/GrandMA3/comments/1xkc1za/ma3_onpc_2511_crashes/ · https://www.reddit.com/r/GrandMA3/comments/1r54i64/ · https://www.reddit.com/r/GrandMA3/comments/1kw4rw6/only_4096_onpc_for_the_future/

**§1.16 ETC Eos family / ETCnomad:** https://www.etcconnect.com/Products/Consoles/Eos-Consoles/ETCnomad/Hardware-Specifications.aspx · https://www.etcconnect.com/Student-Package/ · https://www.etcconnect.com/uploadedFiles/Main_Site/Documents/Public/Video_Tutorial/Eos_Family_ColorTools_v2.3.0revA.pdf · https://www.etcconnect.com/Eos-Experience/ · https://www.etcconnect.com/Support/Tutorials/Expert-Topics/Augment3d.aspx · https://www.youtube.com/watch?v=MMd9m0aMXUI · https://www.reddit.com/r/lightingdesign/comments/z70gn7/ · https://www.reddit.com/r/techtheatre/comments/129yt74/

**§1.17 Capture:** https://www.capture.se/News/Post/13547/Capture-2025-released · https://www.capture.se/Products/Capture/Pricing · https://www.capture.se/Products/Capture/visualisation · https://www.capture.se/Products/2018-Revision-History

**§1.18 Budget and hardware-tied controllers:** https://m-s-v.eu/en/Sunlite-Suite-3-First-Class-lighting-software/SUNLITE-FC · https://forum.daslight.com/viewtopic.php?t=9783 · https://proluz.es/wp-content/uploads/2022/01/suite3_brochure.pdf · https://eu-litterature.n-g.co/Release/sunlite_suite_3_manual_en.pdf · https://apps.apple.com/gb/app/sunlite-remote/id6463859051 · https://forum.daslight.com/viewtopic.php?t=9679 · https://forum.daslight.com/viewtopic.php?t=9873 · https://www.reddit.com/r/lightingdesign/comments/8esdzr/best_lighting_controller_thats_idiot_proof/ · https://forum.daslight.com/viewtopic.php?t=11876 · https://www.reddit.com/r/lightingdesign/comments/1670aqk/ · https://www.freestylersupport.com/wiki/freestyler · https://support.enttec.com/dmx/usbdmx/usbdmx-compatible-usb-software · https://www.freestylersupport.com/fsforum/viewtopic.php?t=3102 · https://www.freestylersupport.com/wiki/sound_2_light · https://www.youtube.com/watch?v=bHfh2twRny4 · https://www.thomsunmusic.com/lightshark-ls-core-io · https://kennell.it/wp-content/uploads/2020/03/LIGHT-SHARK-LS-1_manual.pdf · https://www.long-mcquade.com/116994/Pro-Audio-Recording/Lighting/Work-Pro/LightShark-LS-Core-DMX-Lighting-Console.htm

**§1.19 Musician and Enttec-ecosystem tools:** https://support.enttec.com/legacy-product/legacy-products/dmxis-70570-legacy-product · https://www.dmxis.com/what-happened-to-dmxis/ · https://www.dmxis.com/show-buddy-active/ · https://www.enttec.com/product/dmx-lighting-control-software/emu-sound-to-light-controller/ · https://support.enttec.com/dmx-software/emu/how-to-make-lights-react-to-music · https://support.enttec.com/dmx/usbdmx/usbdmx-compatible-usb-software · https://support.enttec.com/dmx/usbdmx-dmx-usb-pro-70304/macos-software-not-recognizing-dmx-usb-pro · https://www.dmxdesktop.com/ · https://www.enttec.com/product/dmx-lighting-control-software/pixel-mapping-software/ · https://www.chauvetdj.com/showxpress/ · https://apps.apple.com/us/app/stagelight-dmx-controller/id1118851633

**§1.20 WLED:** https://kno.wled.ge/advanced/audio-reactive/ · https://www.reddit.com/r/WLED/comments/1wzryc9/

**§1.21 LedFx:** https://github.com/ledfx/ledfx · https://docs.ledfx.app/en/latest/settings/directing_audio.html · https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps

**§1.22 Philips Hue Sync / Hue Entertainment:** https://github.com/jeffreykog/artnet-hue-entertainment · https://iotech.blog/posts/philips-hue-entertainment-api/ · https://www.philips-hue.com/en-us/support/release-notes/hue-sync · https://hueblog.com/2025/05/31/hue-ai-assistant-officially-rolling-out/ · https://hueblog.com/2026/10/29/custom-ai-behaviors-launched-in-the-philips-hue-app/ · https://www.reddit.com/r/Hue/comments/1b3fv2m/ · https://www.reddit.com/r/Hue/comments/q87tok/ · https://www.reddit.com/r/Hue/comments/oprzba/

**§1.23 Nanoleaf:** https://nanoleaf.me/en-us/blogs/general/everything-you-need-to-know-about-nanoleaf-scenes · https://support.nanoleaf.me/hc/en-us/articles/36106561315604 · https://nanoleaf.me/en-int/pages/nanoleaf-ai-technology · https://www.reddit.com/r/Nanoleaf/comments/10c4uq7/ · https://www.reddit.com/r/Nanoleaf/comments/bregej/ · https://www.reddit.com/r/Nanoleaf/comments/mr2hkj/

**§1.24 Astera AsteraApp:** https://astera-led.com/app/ · https://astera-led.com/bluetooth-bridge-btb/ · https://astera-led.com/academy/layered-effects/ · https://apps.apple.com/app/id1367867800

**§1.25 Nanlink:** https://apps.apple.com/us/app/nanlink/id1584085006 · https://www.nanlink.com/en/h-col-215.html · https://www.nanlink.com/en/h-col-293.html

**§1.26 Govee:** https://us.govee.com/products/govee-music-sync-box · https://community.govee.com/posts/govee-home-v-430-is-here-experience-all-the-new-fe/45674 · https://www.reddit.com/r/Govee/comments/163tumk/ · https://www.reddit.com/r/Govee/comments/1ht9ecq/ · https://www.reddit.com/r/Govee/comments/1q0lbro/ · https://www.reddit.com/r/Govee/comments/1rtknsg/

**§1.27 Elgato Control Center:** https://gist.github.com/sebinside/4812d8979764f4ef8a6c7fb796f285e7 · https://bitfocus.io/connections/elgato-keylight · https://www.elgato.com/eu/et/explorer/products/lighting/how-to-control-your-key-light-with-stream-deck/ · https://www.reddit.com/r/elgato/comments/112ayek/ · https://www.reddit.com/r/elgato/comments/12tlult/

**§1.28 Other manufacturer apps:** https://www.godox.com/product-e/Godox-Light-App.html · https://apps.apple.com/us/app/zy-vega/id6444816284 · https://help.litepanels.com/en/gemini-control-options.html · https://apps.apple.com/us/app/smartlite-director/id1057681116 · https://help.quasarscience.com/en/all-about-starctrl.html

**§1.30 Bitfocus Companion:** https://bitfocus.io/companion · https://github.com/bitfocus/companion-module-monospace-lightkey/issues/3

**§1.31 TouchOSC:** https://hexler.net/touchosc

**§1.32 Remote and multi-user patterns in pro and prosumer lighting:** https://help.malighting.com/grandMA3/2.3/HTML/network_webremote.html · https://support.etcconnect.com/ETC/Consoles/Console_Apps/How_to_Set_Up_Your_Wireless_Network_for_iRFR_or_aRFR_with_Eos_Family_Consoles · https://companion.free/user-guide/beta/security/ · https://lightkeyapp.com/en/help

**§1.33 Protocol, Stream Deck, voice/AI and camera findings that shape Prism's integrations:** https://lightkeyapp.com/en/help · https://help.malighting.com/grandMA3/2.5/HTML/remote_inputs_osc.html · https://support.etcconnect.com/ETC/Consoles/Eos_Family/Software_and_Programming/TCP_port_for_OSC_communication_with_Eos_Software · https://forum.obsidiancontrol.com/t/osc-documentation/5756 · https://www.dmxdesktop.com/guides/art-net-vs-sacn · https://www.dmxdesktop.com/stream-deck · https://marketplace.elgato.com/product/amaran-controller-2acb7ef3-6442-4341-9e2a-a4b94fbfd824 · https://github.com/bitfocus/companion-module-requests/issues/623 · https://hueblog.com/2026/10/21/custom-ai-behaviors-set-to-launch-next-week/ · https://9to5google.com/2026/01/07/philips-hue-rolling-out-these-upgrades-in-early-2026-spatialaware-scenes/ · https://github.com/bawaaaaah/light-mcp-server · https://www.reddit.com/r/lightingdesign/comments/1s2c7mi/ · https://manual.xlights.org/xlights/chapters/chapter-five-menus/tools/generate-custom-model

**§4 Why DMX patching confuses beginners, and a beginner-proof patch workflow for Prism:** https://www.hitlight.app/ai-dmx-software · https://www.enttec.com/product/dmx-usb-interfaces/dmx-usb-pro-professional-1u-usb-to-dmx512-converter/ · https://www.reddit.com/r/explainlikeimfive/comments/1uychjh/eli5_dmx_channels_adresses_and_universes/ · https://www.y-link.no/en/guides/dmx-channel-modes · https://www.reddit.com/r/lightingdesign/comments/1h42ko1/dmx_lights_working_on_channel_1_dont_understand/ · https://www.reddit.com/r/lightingdesign/comments/14pvlpj/dmx_noob_question/ · https://betopperdj.com/blogs/news/dmx-addressing-made-simple-how-to-set-up-multiple-fixtures-without-conflicts · https://help.aputure.com/en/amaran-pixel-tubes/wired-dmx-control · https://help.aputure.com/en/infinimat/profile-selection-and-patching-strategies · https://www.y-link.no/en/guides/dmx-channels-explained-with-real-fixture-examples · https://support.enttec.com/dmx/usbdmx-dmx-usb-pro-70304/macos-software-not-recognizing-dmx-usb-pro · https://glmedia.tech/technical-help/lightkey-colors-cues-priorities/ · https://cdn.enttec.com/pdf/assets/70304/70304_DMX_USB_PRO_API.pdf

**§5 Aputure Sidus Link effects and colour tools:** https://help.aputure.com/en/sidus-link-pro/sidus-link-mobile/modes-and-functions · https://help.aputure.com/en/sidus-link-pro/using-effects · https://help.aputure.com/en/amaran-pixel-tubes/manual-fx-control · https://aperturent-static.s3.amazonaws.com/documents/AmaranPT2cRGBWWLEDPixelTubeLight2-ft2-LightProductionKit.pdf · https://www.sidus.link/software

**Additional sources consulted by the research agents (not cited inline):**
- Lightkey format: https://github.com/jimhoggey/Lightkey-Skill
- Blackout: https://apps.apple.com/app/id1414562959 · https://www.reddit.com/r/lightingdesign/comments/1c0ydlb/blackout_ipad_app_seem_familiar/
- Luminair: https://apps.apple.com/us/app/luminair/id920440588
- SoundSwitch: https://inmusicsupport.freshdesk.com/en/support/solutions/articles/69000881393 · https://www.reddit.com/r/DJs/comments/1qopxle/soundswitch_what_is_going_on/
- Lightjams: https://www.lightjams.com/getIt.html · https://www.lightjams.com/tutorial.html
- MadMapper: https://forum.garagecube.com/viewtopic.php?t=36062 · https://www.reddit.com/r/techtheatre/comments/1kr9nlk/using_madmapper_frustrations/
- Resolume: https://resolume.com/support/en/dmx-shortcuts · https://resolume.com/shop/upgrade · https://www.reddit.com/r/vjing/comments/1oy22ma/should_i_buy_resolume/ · https://www.reddit.com/r/techtheatre/comments/1b6nhc4/sending_dmx_from_both_qlab_and_resolume_makes_my/ · https://www.reddit.com/r/resolume/comments/1bti8us/artnet_to_dmx_lights_wont_show_the_right_color/
- WLED: https://kno.wled.ge/features/effects/ · https://kno.wled.ge/interfaces/json-api/ · https://kno.wled.ge/interfaces/e1.31-dmx/ · https://kno.wled.ge/interfaces/udp-notifier/ · https://mm.kno.wled.ge/WLEDSR/Squelch-and-Gain/
- LedFx: https://docs.ledfx.app/en/latest/developer/melbanks.html · https://github.com/existentialaudio/blackhole
- Philips Hue: https://www.philips-hue.com/en-us/explore-hue/blog/sync-with-music · https://github.com/music-assistant/hue-entertainment
- Astera: https://apps.apple.com/us/app/asteraapp/id1367867800 · https://astera-led.com/support/answer/1648/
- ENTTEC pixel mapping: https://support.enttec.com/user-manuals/elm · https://www.enttec.com/pixel-mapping-software-comparison/
- Beginner sentiment: https://www.reddit.com/r/lightingdesign/comments/125r95q/easiest_lighting_software_for_a_sound_guy/ · https://www.reddit.com/r/lightingdesign/comments/u5uxbn/dmx_software_for_mac/

**Known research gaps (verify before relying on them):**
- Current prices for Lightkey and Luminair.
- Exact DMX channel counts for the amaran PT profiles.
- Whether Aputure/amaran fixtures support RDM.
- The feature depth of ENTTEC EMU.
- SoundSwitch's Art-Net and visualizer support.
- Resolume's sACN, REST and timecode support.
- Complaints about Capture, LightShark, Lightjams, ShowBuddy, DMXDesktop and HitLight (not collected).
- The exact Hue Entertainment light limit on current bridges.
- Details of Govee's AI Lighting Bot.
