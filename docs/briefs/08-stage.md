# Brief: stage — the 2D stage visualizer

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md`
- The reference screenshot `docs/reference/lightkey-screenshot.png`
- `docs/research/competitors.md` §1.1 (Lightkey canvas), §1.7 (Blackout), §2.6, and §3 (blind
  preview, scroll-to-dim, nudges)

## Goal

The stage is where the user lives: a gorgeous, realistic view of their room.
- Lights glow and spill like the real thing.
- Moving, rotating, selecting and painting feel as smooth as Figma or Keynote, but simpler.

## You own

`Sources/PrismApp/Stage/**` and the stage tests.

## Deliverables (priority order)

### 1. Navigation and fit

- Zoom: pinch, ⌘+/⌘−, ⌘0 to fit; zoom to selection.
- Pan: two-finger scroll, space-drag.
- **Fill the available area.** Today the canvas is a narrow portrait rectangle with a lot of
  wasted space; see the CI screenshots. Make stage size and aspect configurable (stage settings
  popover) and fit nicely at any window size.

### 2. Selection

- Click, ⇧/⌘-click, marquee drag, ⌘A.
- Select by role/group from the context menu.
- Selection halo and hover highlight.

### 3. Move and rotate

- **Dragging** snaps to the grid and to other fixtures' centres and edges, with smart guides and
  distance labels.
- **Rotation handle**, snapping to 15° with ⇧.
- **Arrow nudges:** 1 pt, or 10 pt with ⇧.
- **Arrange:** align and distribute, mirror left↔right, lock positions.
- Everything is undoable through `ShowController`, with drags coalesced.

### 4. Pixel painting (tubes and bars)

- Click a cell to select it; drag across cells to paint with the current color.
- **Gradient tool:** drag across one tube, or across several fixtures spatially.
- **Eyedropper** on any fixture or cell.
- Uses the engine's `setCells`/`paintCells` commands. Until they land, call `updateStates` with
  per-cell states.

### 5. Rendering

- **Light:** realistic additive glow and spill on the floor and backdrop, color mixing where
  beams overlap, and intensity-accurate brightness.
- **Fixture bodies,** crisp at any zoom: tube, panel, par, fresnel, COB with softbox, strip,
  practical bulb.
- **Labels** with smart placement.
- **Badges:** effect running, music, protected, unpatched, DMX conflict.
- **Subject silhouette and props** (desk, chair, camera, backdrop, plant): add, move, resize and
  delete from a props palette.
- **Backdrop options:**
  - dark grid or studio floor;
  - **camera image** (from the camera team's latest frame) or a user photo, with opacity.

### 6. Interactions

- **Scroll over a light** to dim/brighten it, with a HUD; ⌥-scroll changes Kelvin.
- Double-click focuses the inspector.
- **Right-click menu:** Identify, copy/paste color, assign role, group, lock, remove.
- **Drag a look** from the sidebar onto lights to apply it to just those lights.
- **Blind preview:** render `UIState.previewLookID` (set by the shell's sidebar hover) as an
  outlined/dimmed preview, without touching the output.

### 7. Performance

- 60 fps with 50 fixtures × 16 cells.
- Use `Canvas`/`TimelineView`, or a layer- or Metal-backed view if needed.
- Render from the engine's **rendered frame** (what is actually output), so fades and effects
  animate.

## Acceptance

- **Tour scenes:**
  - fit view;
  - zoomed in on the tubes;
  - marquee selection;
  - rotation handles;
  - smart guides (simulated mid-drag);
  - a painted gradient;
  - props editing;
  - camera backdrop (synthetic image).
- **Self-tests:**
  - hit-testing selects each fixture;
  - move + undo restores the position;
  - painting sets cell states.
