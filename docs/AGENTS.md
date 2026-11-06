# Working agreement for Prism contributors (agents)

Read `docs/ARCHITECTURE.md` first, then the research notes relevant to you in
`docs/research/`. The user's original request and the reference screenshot
(`docs/reference/lightkey-screenshot.png`) define what "done" means.

## 1. Your workspace

You work in your own git worktree and branch — never directly in the main checkout.

```bash
cd /home/antigravity/goveaaron/StudioLightingMac
git fetch -q origin
git worktree add /home/antigravity/wt/<name> -b agent/<name> origin/main
cd /home/antigravity/wt/<name>
```

Always pass absolute paths under `/home/antigravity/wt/<name>` to file tools.

## 2. Building and testing

The dev VM is Linux (2 CPUs, 8 GB). It can build `PrismCore`, `PrismServer` and
`PrismDevServer` but **not** the macOS app (SwiftUI/AppKit). A global lock serializes
compiles across all agents, so batch your edits before compiling.

```bash
scripts/linux-swift.sh build --target PrismCore          # quick core check
scripts/linux-swift.sh build --build-tests               # everything Linux can build
scripts/linux-swift.sh test --skip-build --filter PrismCoreTests.MyTests
```

The first build in a new worktree compiles swift-nio (~3–5 min). After that, builds are
incremental.

The macOS app is compiled, unit-tested, self-tested and screenshotted by CI on GitHub's
macOS runners. Push your branch, then wait for the result:

```bash
git push -q -u origin agent/<name>
scripts/ci-wait.sh agent/<name>     # blocks until done; prints errors; exit 0 = green
```

`ci-wait.sh` downloads the screenshot artifact to `/tmp/prism-ci/<run-id>/screenshots/`.
**Look at the PNGs with the file viewer** — that is the only way to see the UI. Judge them
critically: alignment, spacing, contrast, clipped text, empty states, beauty.

CI capacity is limited (≈5 concurrent macOS jobs shared by everyone): push when you have
a meaningful batch (not every small edit). Make each push count by reviewing your Swift
carefully for API mistakes first (macOS 14 availability, SwiftUI signatures, `@MainActor`
isolation, `Sendable`).

## 3. Landing on `main`

Land small, green increments often (at least at every milestone):

1. `git fetch -q origin && git merge origin/main` (resolve conflicts carefully — keep both
   sides' intent; never drop someone else's code).
2. Run the Linux build + tests.
3. Push your branch and wait for CI to be green on that exact commit.
4. `git push origin HEAD:main`.
   - If rejected because `main` moved: fetch + merge again. If the merge is clean and Linux
     tests pass you may push to `main` immediately, then run
     `scripts/ci-wait.sh main $(git rev-parse HEAD)` and fix any breakage **right away**.
5. Never force-push `main`; never rewrite shared history.

If `main` is red because of someone else, tell the orchestrator; fix it yourself only if
it's clearly in your area or trivial.

## 4. Ownership

Each agent owns specific directories (listed in your brief). You may freely edit files you
own. For **shared files** — `Package.swift`, `Sources/PrismApp/App/*`,
`Sources/PrismApp/Main/*`, `Sources/PrismApp/Design/*`, `UIState.swift`,
`RootView.swift` (SheetRouter), `PrismCommands.swift`, core model types — make minimal,
additive edits (e.g. add an enum case, a sheet route, a settings tab), keep the existing
style, and mention them in your report. Don't reformat or reorganize files you don't own.
Need a bigger change in someone else's area? Message the orchestrator.

## 5. Code standards

- Follow the reliability rules in `ARCHITECTURE.md §7`. No force unwraps on external data,
  no `try!`, no `fatalError`, no unchecked indexing, never block main or the engine.
- Portable logic goes in `PrismCore` with XCTest tests in `Tests/PrismCoreTests/`
  (one file per area, e.g. `EffectsTests.swift`). Aim for meaningful coverage of edge cases.
- App features add `SelfTest` checks and `ScreenshotTour` scenes for every screen/state.
- Preserve existing comments/docstrings. Document public APIs with `///`.
- No new package dependencies without asking the orchestrator (current: swift-nio only).
- UI copy is friendly, short, plain-English; no DMX jargon unless behind "details".
- Visual language: use `Theme` (colors, radii, spacing, fonts) and `Components`
  (`PrismSlider`, `HexField`, `NumericField`, `.pill` buttons, `prismPanel()`,
  `glassBackground()`, `EmptyStateView`, `StatusPill`, …). Dark, glowing, calm, precise.
- Never commit secrets, tokens or large binaries (> 5 MB) — ask first.

## 6. Communication

- Report to the orchestrator with `send_message` at each milestone: 3–8 lines — what landed
  on main (commit), what's next, any blockers or decisions needed. No essays.
- Ask only when blocked or when a decision affects other workstreams.
- When you finish your brief, do a final self-review (code + screenshots), land everything,
  and send a final report.

## 7. Tooling notes

- `gh` is at `/opt/antigravity/bin/gh` (already authenticated; never run `gh auth login`).
- Long commands are backgrounded automatically; you'll be notified when they finish.
- Python with pillow + numpy: `/home/antigravity/.venv-tools/bin/python`.
- Swift toolchain (Linux): `/home/antigravity/toolchains/swift-6.4.2-RELEASE-debian12/usr/bin`
  (use `scripts/linux-swift.sh`, it sets PATH and takes the lock).
- Do not delete or rewrite other agents' worktrees (`/home/antigravity/wt/*`).
