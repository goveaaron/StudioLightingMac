# Brief: assistant — talk to your lights

**Read first:**
- `00-shared.md`, `docs/AGENTS.md`, `docs/ARCHITECTURE.md` (command language)
- `docs/research/macos_media_ai.md`, §0.3 first, then:
  - §2 (wake word, SpeechAnalyzer, TTS);
  - §3 (Foundation Models guided generation, plus the rule-parser fallback);
  - §4 (cloud LLM schema, camera verification, Keychain).
- `docs/research/competitors.md` §2.8 and §1.33

## Goal

Every phrase does exactly the right thing, instantly, with undo. For example:

> "All right, Prism — warm up the background a bit. Bit more blue to the back left. Bring the
> tubes down a little. Brighten up the key a little. Bring down the fill a little."

Scene requests set up the right lights, then check the result with the camera:

> "Teal on the left, blue on the right, pink above."

## You own

`Sources/PrismCore/Assistant/**` (new), `Command/FixtureSelector.swift`,
`Command/SelectorResolver.swift`, `Sources/PrismApp/Assistant/**`, `Sources/PrismApp/Voice/**`,
and the assistant tests.

## Deliverables (priority order)

### 1. Offline natural-language parser (`PrismCore/Assistant/`)

Deterministic and Linux-tested.
- **Intents:**
  - set/adjust intensity, color, warmth, tint, saturation;
  - recall/save looks;
  - effects ("make it flicker like a candle");
  - music on/off and mood;
  - blackout, undo/redo;
  - "what's on?".
- **Targets** through `SelectorResolver`:
  - roles: key, fill, back, background, hair, practical;
  - types: tubes/sticks/batons, panel, "round light";
  - spatial words: left, right, centre, top/above, floor/bottom, back-left, front-right…;
  - labels ("B3", "PN1") and names;
  - "everything", "the rest".
- **Quantities:**
  - "a little" / "a bit" / "a lot" (the engine team's nudge constants);
  - "50%", "half", "2 stops", "3200K", "#FF00AA";
  - named colors (`NamedColors`).
- **Multi-clause** sentences: split on "and", "then", ".", ",".
- **Follow-ups:** "a bit more", "too much", "back", "undo that".
- **Corrections:** "no, the other side".
- **Every example phrase from the user has a test.**

### 2. `SelectorResolver` spatial upgrade (you own it)

- Resolve spatial words from stage positions in normalized room coordinates. "Left" means the
  viewer's left on the stage plan; make the orientation configurable.
- Synonyms and quantifiers.
- When a request is ambiguous, ask one short clarifying question.

### 3. Plan → preview → apply → undo

- Text becomes a `LightingPlan`: commands plus a human summary.
- The ⌘K overlay shows what will change, with the affected lights highlighted on the stage.
- Applying a plan is **one** undo step.
- Voice applies immediately, with a toast and an "Undo" chip.

### 4. Foundation Models (macOS 26, `#available`, weak-linked)

- Guided generation into the same plan types, with rig state available as a tool.
- **Fallback chain:** on-device → optional cloud (OpenAI/Anthropic/Gemini; keys in Keychain;
  model name is a setting) → rule parser.
- The app works fully with the rule parser alone.

### 5. Voice

- Push-to-talk: ⇧⌘K, or click the mic.
- Optional wake phrase: "Hey Prism", "All right, Prism", or user-defined (e.g. "light app").
- Recognition: `SFSpeechRecognizer` on-device (14+), `SpeechAnalyzer` (26+).
- A live transcript in the overlay, and optional short spoken confirmations.
- Mic permission flow.
- **Never trigger from music playing in the room:** require high wake-phrase confidence; design
  this carefully.

### 6. Camera verification loop

- After a scene request, call `app.camera.verify(…)`.
- Show the result, e.g. "Left looks teal ✓ · right looks blue ✓ · top looks pink ✓", or one
  suggested correction with a one-click fix.
- At most 2 automatic corrections, and only if auto-correct is enabled. No loops.

### 7. ⌘K overlay (`AssistantOverlay`)

A Raycast/Spotlight-style command bar: suggestions as you type, history, examples, results.

### 8. Settings pane (`AssistantSettingsPane`)

Wake phrase, voice on/off, spoken replies, AI provider and keys, auto-verify with the camera.

## Acceptance

- **Parser tests:** all of the user's phrases, plus at least 150 variations (typos, casing,
  fillers like "um", "please", "could you").
- **Self-test:** "teal on the left, blue on the right, pink above" applied to the demo rig gives
  the expected states (left tubes teal, right tubes blue, top tubes pink).
- **Tour scenes:**
  - overlay with suggestions;
  - typed command preview;
  - result with the undo chip;
  - listening state;
  - settings.
