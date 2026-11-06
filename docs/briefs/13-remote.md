# Brief: remote — phone control by QR code, and share links with guardrails

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- `docs/research/macos_systems.md`:
  - §5 (Local Network privacy, NIO server, Bonjour, LAN IPs);
  - §7 (cloudflared quick tunnel, checksums);
  - §4.3 (resources: use `.embedInCode`, never `Bundle.module`).
- `docs/research/competitors.md` §1.32, §2.9 and §3 (QR guest remote with scopes)

## Goal

- **On the phone:** scan the QR code on the Mac and a beautiful remote opens instantly, with no
  app install. It offers looks; key, fill, back and background faders; and colors.
- **For someone remote:** share a link and they can play within the limits you set. They can
  **never** break the lighting or cause hiccups.

## You own

`Sources/PrismCore/Remote/**` (new), `Sources/PrismServer/**`, `Sources/PrismDevServer/**`,
`Resources/WebRemote/**`, `tools/web-test/**`, `Sources/PrismApp/Remote/**`,
`Tests/PrismServerTests/**`. You also own adding resources to `Package.swift` for your
targets: keep that edit minimal and additive.

## Deliverables (priority order)

### 1. Server (`PrismServer`, SwiftNIO)

- **Transport:** HTTP + WebSocket on port 8742, falling back to a free port.
- **Content:** serves the embedded static web app plus a JSON API.
- **Live updates:** a WebSocket state stream of diffs at ≤ 20 Hz.
- **Robustness:** backpressure, connection limits, timeouts, graceful shutdown.
- **Isolation:** runs on its own event loop and talks to the app only through `RemoteHost`.

### 2. Protocol and security (`PrismCore/Remote/`, enforced server-side, fully tested)

- `RemoteHost` protocol and versioned messages.
- **Pairing:**
  - the QR code encodes `http://<lan-ip>:8742/#/join/<secret>` (the secret sits in the URL
    fragment, so it is never logged);
  - the secret is exchanged for a session token.
- **Roles:** viewer, guest, operator, admin.
- **Per-link permissions:**
  - allowed fixtures/roles and looks;
  - intensity range; color allowed;
  - effects allowed, but **never strobe**;
  - a **minimum fade injected** (e.g. ≥ 0.5 s, so guests can't flash lights);
  - rate limits;
  - protected key/fill;
  - expiry and maximum uses.
- **Controls on the Mac:**
  - optional approval prompt for new devices;
  - a **kill switch** that revokes everything instantly;
  - an activity log of who did what.
- Recording mode makes every guest read-only.

### 3. Internet sharing (optional)

- A cloudflared quick tunnel, downloaded on demand with checksum verification (§7.2–7.3).
- Runs as a child process: parse the trycloudflare URL, restart it on failure, stop it on quit.
- The share sheet shows the public link and its QR code, with clear warnings.

### 4. Web remote (`Resources/WebRemote/`)

- **Build:** no build step needed (vanilla ES modules + CSS), or commit the built output.
- **Platform:**
  - mobile-first, matching the app's dark, glowing style;
  - an installable PWA;
  - reconnects automatically.
- **Screens:**
  - looks grid (tap to recall);
  - faders by role/group;
  - color wheel, swatches and hex for allowed fixtures;
  - a simplified stage (tap a light);
  - music toggle and mood (if allowed);
  - a "Connected as Guest — what you can do" panel.
- Haptics where available.

### 5. App side (`PrismApp/Remote/`)

- **`RemoteController`:** start/stop the server, advertise over Bonjour (`_prism-lights._tcp`),
  detect LAN IPs, manage links.
- **`RemoteWorkspace`:**
  - a big, beautiful QR code (`CIQRCodeGenerator`);
  - connected devices with names and roles;
  - links with a permissions editor;
  - activity log and kill switch.
- `ShareRemoteSheet`, `RemoteSettingsPane`, and a toolbar indicator while guests are connected
  (tell the shell team what to show).

### 6. REST API for integrations

- `/api/v1/…` with admin-created API keys, for Stream Deck, Companion and Home Assistant.
- Document it in `docs/API.md`.

### 7. Tests

- **`PrismServerTests`:**
  - the pairing flow;
  - permission enforcement:
    - intensity range and protected fixtures;
    - strobe stripped, minimum fade injected;
    - rate limits;
  - WebSocket updates.
- **`PrismDevServer`** runs the demo rig on Linux.
- **Playwright** tests in `tools/web-test/` against the dev server:
  - load, pair, recall a look, move a fader;
  - phone-sized screenshots.
- Ask the orchestrator to add a CI job that uploads them.

## Acceptance

- Server tests pass on Linux.
- The dev server serves the remote, and the Playwright screenshots look great at iPhone and iPad
  sizes.
- **App tour:**
  - Remote workspace with the QR code;
  - share sheet;
  - permissions editor;
  - simulated device list.
