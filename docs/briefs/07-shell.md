# Brief: shell — app frame, looks, Live page, onboarding, polish

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- The reference screenshot `docs/reference/lightkey-screenshot.png`
- `docs/research/competitors.md` §1.1 (Lightkey), §1.7 (Blackout), §2.5 and §3. The top-30 UX
  ideas include: looks as photos, an auto-generated Live page, studio templates, resume after
  crash, recording mode.
- `docs/research/macos_systems.md` §9 (single instance, SIGTERM, launch at login)

## Goal

An app frame people fall in love with: calm, dark, glowing and fast.
- **Looks** are the heart of it: photos of lighting states.
- The **Live page** builds itself.
- **Onboarding** gets a non-lighting person to their first beautiful look in under 2 minutes.

## You own

`Sources/PrismApp/App/**` (shared infrastructure: keep it stable for everyone),
`Sources/PrismApp/Main/**`, `Looks/**`, `Settings/**` (the General/Safety panes and the tab
list), `Design/**`, `Onboarding/**`, `Support/**`, and the shell tests.

## Deliverables (priority order)

### 1. Polish pass over the whole frame

Covers the toolbar, sidebar, bottom bar, toasts and sheets.
- Consistent spacing and typography from `Theme`.
- Liquid Glass on macOS 26 (`glassEffect` behind `#available`), with tasteful material fallbacks
  on 14/15.
- **Fix:**
  - **NSTableView reentrancy warning.** CI launch logs show "Application performed a reentrant
    operation in its NSTableView delegate". It's a state change during a List/Table update,
    probably a selection binding mutating mid-update; check the sidebar `List` and the patch
    table, and coordinate with the patch team.
  - **Sidebar text clipping** at narrow widths.
  - **"Favorites" duplicating looks.** Rethink it, e.g. pinned looks as a compact chip row.

### 2. App icon

- Design a stunning icon (a prism splitting light into beams, macOS squircle style) with the
  `generate_image` tool.
- Save it as `Support/AppIcon.png` (1024×1024). `scripts/build_app.sh` already builds the
  `.icns` from it.
- Also make a monochrome template icon for the menu bar.

### 3. Looks sidebar

- **Folders:** create, rename, delete, collapse; drag looks between folders.
- **Editing:** drag-reorder, inline rename, duplicate, delete with undo.
- **Thumbnails:** small, cached stage renders of each look.
- **Hover preview:** blind preview on the stage, without changing the output. Add
  `UIState.previewLookID` and let the stage team render it.
- **Keyboard:** 1–9 recall, ↑/↓ + Return.
- "Update look from current lights", per-look fade time, favorites, search.

### 4. Live page (`LiveWorkspace`)

- An auto-generated performance surface:
  - big photo-like look tiles;
  - **role faders** auto-built from roles and groups (Key, Fill, Back, Background, Practicals);
  - master;
  - fade presets (Snap / Quick / Smooth / Slow);
  - blackout and a music toggle.
- A **Recording mode** toggle: locks key/fill, no flashing, remote read-only (the engine
  enforces this).
- Touch-friendly; works in full screen.

### 5. Menu bar extra (`MenuBarPanel`)

- Status, master, quick look recall, music toggle, blackout, "Open Prism".
- Prism keeps running when the window is closed.

### 6. Onboarding

- **Welcome** offers four paths:
  - Explore the demo studio;
  - **Import from Lightkey** (`AppSheet.importLightkey`, built by the patch team);
  - **Start from a template** (`TemplatesSheet`);
  - Set up my lights (the patch team's wizard).
- **Templates:** full projects (fixtures, positions, roles, looks) for:
  - Podcast (2 hosts)
  - Talking head
  - Product table
  - Gaming room
  - YouTube set

  Generic profiles are fine; use curated ones once the library lands.
- A **3-step coach-mark tour** of Stage, Inspector and Looks. Dismissible, and never shown
  during automation.

### 7. Settings

- **General pane:**
  - startup options;
  - quit behaviour: keep lights / fade out / blackout;
  - launch at login (`SMAppService`);
  - menu bar icon.
- **Safety pane.**
- Keep the tab list tidy.

### 8. Lifecycle and reliability

- **Single instance:** a second launch activates the first and forwards files.
- **SIGTERM** triggers a graceful terminate (the install script relies on this).
- **Safe mode:** hold ⌥ at launch, or after 2 crashes; skips restoring the last session.
- Crash-resume toast (already exists).
- **Help menu:**
  - Run Diagnostics (a UI for `SelfTest`);
  - Keyboard Shortcuts;
  - Report a Problem (collects logs).

### 9. History popover

A toolbar clock button that renders the engine team's attributed history timeline.

### 10. Automation infrastructure

- You own `ScreenshotTour.swift` and `SelfTest.swift`; keep them robust for every team.
- Add a scene filter via the `PRISM_TOUR_FILTER` environment variable.
- Keep the window size consistent and dark appearance forced.

### 11. Accessibility

Labels on every control, keyboard navigation, and Reduced Motion support.

## Acceptance

- No NSTableView reentrancy warning in the CI launch log.
- No clipped text in any tour screenshot.
- **Tour scenes:**
  - sidebar states (folders, renaming, hover preview);
  - Live page, normal and in recording mode;
  - menu bar panel;
  - templates;
  - onboarding;
  - History popover.
- The app icon shows in the bundle that CI builds.
