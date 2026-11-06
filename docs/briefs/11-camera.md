# Brief: camera — the webcam as a lighting assistant

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/macos_media_ai.md`:
  - §5 (AVCapture, BGRA 720p, region colour averaging, exposure/white-balance locking);
  - §4.4 (verification loop);
  - §6 (permissions).
- `docs/research/competitors.md` §3 ("Check my lights") and §1.33

## Goal

A webcam looks at the user's set. Use it to:
1. find where each light is, and which address it's really on;
2. verify that "teal on the left, blue on the right, pink above" actually happened;
3. spot dead, duplicated or swapped lights;
4. help with white balance.

The camera is guidance; the user stays in control.

## You own

`Sources/PrismApp/Camera/**`, `Sources/PrismCore/Vision/**` (new), and the vision tests.

## Deliverables (priority order)

### 1. `CameraController` (AVFoundation)

- Device choice: built-in, USB webcams, Continuity Camera.
- Permission flow.
- Session lifecycle: start only when needed, stop when idle.
- A low-res analysis stream (e.g. 640×360 BGRA) processed on a background queue.
- Survives the device being unplugged. Never blocks the main thread.

### 2. Vision core (`PrismCore/Vision/`)

Portable code, tested on Linux with synthetic RGBA buffers:
- frame differencing and blob detection;
- robust region color sampling (median in linear RGB, exposure-normalized);
- ΔE comparison in OKLab;
- exposure/white-balance handling (lock while measuring; otherwise normalize against a
  reference frame);
- temporal smoothing.

### 3. Light Finder (`AppSheet.lightFinder`)

The request is set via `app.camera.lightFinderRequest`.

- **`.locate(ids)`:**
  - Flash each light (on/off or color-coded patterns) and find its area of effect in the frame.
  - Offer to auto-arrange the lights on the stage to match (left/right/top), with confirmation.
  - Store the fixture → camera-region map for verification. Keep it in machine settings keyed by
    project ID, never in project files.
- **`.scanAddresses(universe:range:)`:**
  - Find unknown lights quickly with binary-search flashing patterns, then propose patch
    entries.
  - Detect **duplicates** (two lights on one address), **dead** lights and **swapped** lights.

### 4. Verification API (contract §4 in `00-shared.md`)

- `ColorExpectation` + `verify(_:) async -> VerificationReport`.
- Each item reports the measured color, ΔE, pass/fail and a hint, e.g. "Left looks more green
  than teal — add about 10% blue?".
- Map stage regions through the Light Finder calibration. If uncalibrated, fall back to a simple
  left/center/right/top split of the frame.
- Also provide `snapshotJPEG(maxDimension:)` for cloud vision models.

### 5. "Check my lights" (Camera workspace)

- One button: each light briefly flashes white.
- Shows a report card: "All 10 lights responded ✓", or the problems with suggested fixes.

### 6. White-balance helper

- The user holds up a grey card; Prism measures it and suggests Kelvin/tint corrections for key
  and fill.
- A "match my camera's white balance" helper.

### 7. Camera workspace UI

- Live preview with overlays: detected light areas labelled with fixture names.
- A side-by-side stage view.
- "Use as stage backdrop": expose `latestFrameImage` for the stage team.
- Privacy indicator; the camera turns off when not in use.

### 8. No camera (CI)

- Every API returns a clear `.unavailable` result and never hangs.
- The tour uses **synthetic frames** (render the stage into a fake camera image) so screenshots
  show the real UI with overlays.

## Acceptance

- **Linux tests** with synthetic frames:
  - blob localization accuracy;
  - verify pass/fail for teal-left / blue-right / pink-top scenes;
  - duplicate/dead detection;
  - the address scan finds N hidden addresses in O(log n) flash rounds.
- **Tour scenes:**
  - camera workspace with overlays;
  - Light Finder steps;
  - verification report;
  - "Check my lights" report;
  - white-balance helper.
