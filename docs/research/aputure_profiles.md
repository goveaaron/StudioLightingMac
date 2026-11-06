# Aputure & amaran DMX channel maps (research for Prism)

*Research date: 2026-11-06. Scope: every DMX mode of the Aputure and amaran fixtures named in the brief, tubes and panels first.*

*Context: the reference studio runs about 8 Aputure/amaran tubes, one square panel and one round "Dimmer only" fixture from an Enttec DMX USB Pro. In Lightkey, each tube shows exactly 16 pixel segments with the parameters "Dimmer, Color".*

**Confidence tags**

| Tag | Meaning |
|---|---|
| **[V]** | **verified-from-official-doc**: read directly in an Aputure/amaran *DMX Profile Specification* PDF, a product manual or an official help-centre article (URL cited) |
| **[LK]** | decoded from Lightkey's own fixture-library file (`.lightkeyfxt` from lightkeyapp.com), which is what the user's current app shows |
| **[GMA]** | from Aputure's official grandMA fixture-file pack. Aputure wrote it, but it is a console file, not a spec |
| **[OFL]** | **from-OFL**: Open Fixture Library JSON (`OpenLightingProject/open-fixture-library`) |
| **[INF]** | **inferred**: my own reasoning, not stated by a primary source |

Notation:
- Value ranges are inclusive 8-bit DMX values (0–255) unless marked 16-bit.
- "Ch" is the offset from the fixture's start address, so ch 1 = the start address.
- Mode names are written exactly as the official spec prints them. The light's own screen may abbreviate them (see each family's "how to set" notes).

---

## 0. TL;DR for Prism

1. **The user's tubes are almost certainly amaran PT-series pixel tubes (PT1c / PT2c / PT4c), patched in Lightkey as *Aputure → "Amaran PT"*.** [INF from LK]
   - Lightkey draws Amaran PT as 16 segments. No other Aputure/amaran tube profile looks like that: T2C & T4C is 1 segment, INFINIBAR is 48 and MT Pro is 36.
2. **The 16 segments come from how Lightkey draws the fixture. They do not prove a 16-pixel DMX mode.** [LK]
   - Lightkey's Amaran PT profile has one profile-wide `LXStripBeamLayout` of length 16. Every mode and every tube size uses it.
   - Segments per pixel: "2 Pixels" mode lights 8 segments per pixel, 4 px lights 4, 8 px lights 2, 16 px lights 1.
3. **"Dimmer, Color" with no Strobe points to one of Lightkey's "Light Engine CCT & RGB *n* Pixels" modes.** [LK + INF]
   - In Lightkey's PT profile, only the Light Engine (LE) modes have no strobe capability.
   - CCT & RGB, CCT and RGB each include Strobe. System FX includes FX controls.
4. **Only the PT4c has a real 16-zone DMX mode: Mode 10 "Light Engine CCT & RGB 16 Pixels", 112 channels.** [V]
   - Layout: 16 × [Intensity, CCT, G/M, CCT↔RGB crossfade, Red, Green, Blue].
   - The PT4c also has Mode 14 "Light Engine HSI 16 Pixels": 48 ch = 16 × [Intensity, Hue, Saturation]. Lightkey does not offer it.
   - The PT2c tops out at 8 px and the PT1c at 4 px.
5. **Universe math rules out 16 px on every tube with one universe.** [INF]
   - 8 tubes × 112 ch = 896 ch, but one universe holds 512.
   - A classic Enttec DMX USB Pro drives **one** universe. The DMX USB Pro Mk2 can drive two.
   - So one of these is true:
     - **(a)** The tubes run **"Light Engine CCT & RGB 8 Pixels"** (56 ch; 8 × 56 = 448 ch) or a smaller mode. This is the most likely.
     - **(b)** Several tubes share a start address and mirror each other.
     - **(c)** A second universe is in use.
   - Prism should support all three: any pixel count, duplicate start addresses, and 2 universes on a Mk2.
6. **How to confirm:**
   - In Lightkey's patch, read each tube's mode name and footprint (14 / 28 / 56 / 112).
   - Or on the tube itself: **MENU → DMX Settings → DMX Profiles**. [V]
7. **Safe defaults for Prism on "Gen-1" protocol fixtures** (amaran PT/T/F, INFINIBAR, MT Pro, Nova, LS 600c Pro, CS15). [V]
   - **G/M = 128.** The whole range 120–145 is neutral, and so is 0–10.
   - **Strobe = 0.** 0–19 means off.
   - **Reserved channels = 0.**
   - **Crossfade:** 0 = pure CCT white, 255 = pure RGB/HSI colour.
   - Intensity scales everything.
8. **No document says which end of the tube is pixel 1.** [INF] Ask the user to set LE pixel 1 to red and look.

---

## 1. Conventions shared by Aputure/amaran DMX specs

### 1.1 "Gen-1" protocol [V]

Used by amaran PT, T2c/T4c and F21c/F22c, INFINIBAR, MT Pro, Nova P300c/P600c, LS 600c Pro (II) and Electro Storm CS15.

| Function | Encoding |
|---|---|
| Intensity | 0–255 = 0–100 %. Spec tables say "0–100 %" with no curve given, so treat as linear [INF] |
| **G/M** (8-bit) | 0–10 Neutral / No Effect<br>11–20 Full Minus Green<br>21–119 = −99 % … −1 %<br>**120–145 Neutral**<br>146–244 = +1 % … +99 %<br>245–255 Full Plus Green<br>Nova P300c and the PT FX tables label the same ranges "−0.9…−0.1 / 0.1…0.9". Electro Storm XT26 is half range (±50 %) |
| Crossfade (CCT ↔ RGB, CCT ↔ HSI) | "Crossfade to Color": 0 = 100 % CCT white … 255 = 100 % colour |
| Hue | 0–255 = 1°–360°. Assume linear: hue ≈ 1 + v × 359 / 255 [INF] |
| Saturation | 0–255 = 0–100 % |
| HSI base CCT (only where the mode has it) | 0–10 = 6500 K; 11–255 = the fixture's CCT range |
| Strobe | 0–19 No Effect; 20–255 = 1 Hz – 25 Hz |
| x / y (CIE 1931) | 0–255 = 0–0.8, so DMX = round(coord × 255 / 0.8) |
| "Reserved for Future Use" | send 0 |
| GEL modes | **CCT:** 0–126 = 3200 K, 127–255 = 5600 K<br>**Brand:** 0–29 Rosco, 30–59 Lee, 60–255 reserved. The Nova P300c doc prints this reversed: Lee 0–29, Rosco 30–59<br>**Series:** 10-value steps, e.g. 0–9 "R-Col.corr. / L-Col.corr.", 10–19 "R-CalColor / L-Col.Filters", 20–29 "R-Storaro / L-600 Series", 30–39 "R-Cinelux / L-Cosmetic", 40–49 "R-Reserved / L-700 Series"<br>**Category:** gel index in 2-value steps (0–1, 2–3 …) from long per-series tables in each PDF |
| 16-bit pairs | coarse (MSB) on ch *n*, fine (LSB) on ch *n*+1 |

### 1.2 CCT channel scaling (DMX → Kelvin)

| Family | Range | Mapping | Evidence |
|---|---|---|---|
| amaran PT1c/PT2c/PT4c | 2700–10000 K | K = 2700 + v × 28.627 (linear) | [V] the doc's chart lists 2700 = 0, 3200 = 17, 3800 = 38, 4300 = 56, 4800 = 73, 5600 = 101, 6500 = 133, 7500 = 168 |
| INFINIBAR, MT Pro, Nova P300c/P600c, CS15 | 2000–10000 K | K = 2000 + v × 31.373 (linear) | [V] INFINIBAR doc: 2700 = 22, 3200 = 38, 5600 = 115, 6500 = 143 |
| amaran T2c/T4c, F21c/F22c, F21x/F22x | 2500–7500 K | K = 2500 + v × 19.608 | endpoints [V]; linearity [INF] |
| LS 600c Pro / Pro II | 2300–10000 K | K = 2300 + v × 30.196 | endpoints [V]; linearity [INF] |
| LS 600x Pro | 2700–6500 K | probably linear | endpoints [V]; linearity [INF] |
| **LS 300x** | 2700–6500 K | **stepped**: 100 K per 5 DMX values. 0–5 = 2700 K, 6–10 = 2800 K, … 186–190 = 6400 K, 191–195 = 6500 K, 196–255 undefined | [V] manual chart. The chart has a "121–126 / 126–130" overlap typo |
| STORM 1000c / 80c | 1800–20000 K | linear; 3200 K = 20 (8-bit) or 5041 (16-bit) | [V] |
| STORM 1200x | 2500–10000 K | 3200 = 24 (16-bit 6117), 5600 = 106, 6500 = 136, 10000 = 255 | [V] |
| amaran Ray / Halo, profile 1 "CCT Universal" | 2700–6500 K | 3200 = 34, 5600 = 195 (linear) | [V] |

### 1.3 "OS II" protocol (STORM 1000c/80c, STORM 1200x, amaran Ray/Halo spec V1.2) [V]

These conventions differ from Gen-1, so do not mix the two.

- **±Green, 8-bit:** the doc gives the neutral default as 133 or 137 depending on fixture.
- **±Green, 16-bit:** 0–2621 no effect · 2622–5243 Full Minus Green · 5244–30146 minus · **30147–37355 neutral** · 37356–62914 plus · 62915–65535 Full Plus Green.
- **Strobe:** 0–13 Off · 14–128 Random 0.4–25 Hz (amaran: 1–25 Hz) · 129–255 Constant 0.4–25 Hz.
- **Crossfade** channels are named "White Light to RGB", "Crossfade from Static Color" (static → FX) and similar.
- **Control channel:** hold a value for 2.5 s, then return it to 0. Details in §9.1.
- **Fan channel:** works only when the fixture's own fan setting is "DMX Controlled" (STORM).

---

## 2. amaran PT1c / PT2c / PT4c pixel tubes — the user's likely tubes

**Sources:**
- amaran PT DMX Profile Specification V1.0 (Nov 2022, controller firmware V1.0) [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf?v=1714345028
- amaran PT Product Manual V1.2 [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-Product-Manual-V1.2-0207.pdf
- Help centre [V] https://help.aputure.com/en/amaran-pixel-tubes/dmx-profile-settings · https://help.aputure.com/en/which-amaran-lights-can-i-control-with-dmx-which-adapters-are-needed-for-each-fixture

### 2.1 Physical and control

| Model | Size | Pixels ("Light Engines") | Weight | CCT |
|---|---|---|---|---|
| PT1c | Φ42 × 300 mm (1 ft) | 4 | 351 g | 2700–10000 K |
| PT2c | ~600 mm (2 ft) | 8 | — | 2700–10000 K |
| PT4c | ~1200 mm (4 ft) | **16** | 1375 g | 2700–10000 K |

- **Wired DMX** goes through the tube's USB-C port and the **"amaran Type-C to DMX Adapter with Type-C Input"**. [V]
  - It is sold separately; kits include it.
  - This is the *older* amaran adapter. It is not the new locking Ray/Halo adapter and not the Aputure "Active" adapter.
- **Per-pixel control is only available over DMX.** The app controls whole tubes and the built-in FX. [V] (PT FAQ)
- **Wireless:** Sidus Link / amaran app over Bluetooth mesh.
- No CRMX or RDM is mentioned in any PT document. [INF]

### 2.2 How to set DMX address & mode on a PT tube [V]

1. Connect the amaran USB-C→DMX adapter to the tube. Run DMX from the Enttec to the adapter's IN, and daisy-chain from its OUT to the next tube.
2. Press **MENU**. Use **Up/Down** and **OK** to choose **DMX Settings** in the system menu.
3. **DMX Address**: Up/Down sets 001–512. *Press and hold OK for 2 s to lock or unlock the address* (this prevents leaving DMX mode by accident).
4. **DMX Profiles**: Up/Down chooses the mode.
5. **DMX Loss Behavior** has four options:
   - Hold Last Setting
   - Black Out
   - Fade To Black (60 s)
   - Hold for 2 min, then fade to black over 60 s
6. **Leave the DMX Address screen showing.** Per the help centre: "DMX Address Screen must be visible for Hard Line DMX to control the fixture."

Factory defaults are address 001, profile CCT&RGB and Hold Last Setting. [V]

**What the screen shows:** the manual's screenshot lists "1: CCT&RGB 8-bit", "2: CCT 8-bit", "3: CCT&HSI 8-bit" and so on. Nothing documents the on-screen labels for profiles 7–14 [INF], so pick by number:
- **9** = LE CCT&RGB 8 px (PT2c/PT4c)
- **10** = LE CCT&RGB 16 px (PT4c only)

### 2.3 Mode list [V]

| # | Mode name (spec) | Ch | Models |
|---|---|---|---|
| 1 | CCT & RGB | 10 | all |
| 2 | CCT | 6 | all |
| 3 | CCT & HSI | 9 | all |
| 4 | RGB | 7 | all |
| 5 | HSI | 6 | all |
| 6 | System FX – List of Effects | 7 | all |
| 7 | Light Engine CCT & RGB 2 Pixels | 14 | PT1c / PT2c / PT4c |
| 8 | Light Engine CCT & RGB 4 Pixels | 28 | PT1c / PT2c / PT4c |
| 9 | Light Engine CCT & RGB 8 Pixels | 56 | PT2c / PT4c |
| **10** | **Light Engine CCT & RGB 16 Pixels** | **112** | **PT4c only** |
| 11 | Light Engine HSI 2 Pixels | 6 | PT1c / PT2c / PT4c |
| 12 | Light Engine HSI 4 Pixels | 12 | PT1c / PT2c / PT4c |
| 13 | Light Engine HSI 8 Pixels | 24 | PT2c / PT4c |
| 14 | Light Engine HSI 16 Pixels | 48 | PT4c only |

Aputure's grandMA pack has modes 1–5 and 7–14 but leaves out 6 (System FX). [GMA]

### 2.4 Whole-tube modes [V]

**Mode 1 — CCT & RGB (10 ch)**

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–255 = 0–100 % |
| 2 | CCT | 0–255 = 2700–10000 K (§1.2) |
| 3 | G/M | Gen-1 G/M table (§1.1); neutral 120–145 or 0–10 |
| 4 | CCT ↔ RGB | crossfade to colour, 0 = CCT … 255 = RGB |
| 5 | Red | 0–100 % |
| 6 | Green | 0–100 % |
| 7 | Blue | 0–100 % |
| 8 | Reserved for Future Use | 0 |
| 9 | Reserved for Future Use | 0 |
| 10 | Strobe | 0–19 no effect; 20–255 = 1–25 Hz |

**Mode 2 — CCT (6 ch):** 1 Intensity · 2 CCT · 3 G/M · 4 Reserved · 5 Reserved · 6 Strobe

**Mode 3 — CCT & HSI (9 ch):** 1 Intensity · 2 CCT · 3 G/M · 4 CCT ↔ HSI crossfade · 5 Hue (1–360°) · 6 Saturation · 7 Reserved · 8 Reserved · 9 Strobe

**Mode 4 — RGB (7 ch):** 1 Intensity · 2 Red · 3 Green · 4 Blue · 5 Reserved · 6 Reserved · 7 Strobe

**Mode 5 — HSI (6 ch):** 1 Intensity · 2 Hue · 3 Saturation · 4 Reserved · 5 Reserved · 6 Strobe

The PT has no HSI base-CCT channel, and the white point at saturation 0 is not documented.

**Mode 6 — System FX (7 ch)**

| Ch | Function | Values |
|---|---|---|
| 1 | Intensity | 0–100 % |
| 2 | Loop / Trigger / Stop | **Lightning:** 0–9 Loop, 10–69 Trigger, 70–255 Stop<br>**Other effects:** 0–69 Loop, 70–255 Stop |
| 3 | FX Selection | 0–9 Paparazzi · 10–19 Lightning · 20–29 TV · 30–39 Fire · 40–49 Faulty Bulb · 50–59 Pulsing · 60–69 Cop Car · 70–79 Party Lights · 80–89 Fireworks · 90–255 Reserved |
| 4–7 | Effect parameters | see the next table |

Effect parameters for channels 4–7. "Frequency 1–10" always means 0–9 = 1, 10–19 = 2, … 90–99 = 10, and 100–255 reserved. Where "+Random" is listed, 100–109 = Random and 110–255 is reserved.

| Effect | Ch 4 | Ch 5 | Ch 6 | Ch 7 |
|---|---|---|---|---|
| Paparazzi | CCT 2700–10000 K | G/M | Frequency 1–10 | — |
| Lightning | CCT | G/M | Frequency 1–10 + Random | — |
| TV | CCT range: 0–9 Warmer, 10–19 Natural, 20–29 Cooler, 30–255 reserved | Frequency 1–10 + Random | — | — |
| Fire | CCT range (as TV) | Speed 1–10 | — | — |
| Faulty Bulb | Mode: 0–9 CCT, 10–19 HSI, 20–255 reserved | CCT mode: CCT · HSI mode: Hue | CCT mode: G/M · HSI mode: Saturation | Frequency 1–10 + Random |
| Pulsing | as Faulty Bulb | as Faulty Bulb | as Faulty Bulb | Frequency |
| Cop Car | Colour: 0–9 Red, 10–19 Blue, 20–29 Red+Blue, 30–39 Blue+White, 40–49 Red+Blue+White, 50–255 reserved | Frequency 1–10 | — | — |
| Party Lights | Saturation | Frequency | — | — |
| Fireworks | Type: 0–9 CCT, 10–19 HUE, 20–29 CCT+HUE, 30–255 reserved | Frequency 1–10 + Random | — | — |

### 2.5 Pixel modes ("Light Engine"): exact structure [V]

There is **no global header channel**: no master dimmer and no strobe. The mode is simply *N* identical per-pixel blocks, starting with Light Engine 1.

**Light Engine CCT & RGB *n* Pixels: 7 channels per pixel**

| Offset within the pixel block | Function | Values |
|---|---|---|
| +0 | Intensity | 0–100 % |
| +1 | CCT | 2700–10000 K |
| +2 | G/M | Gen-1 table |
| +3 | CCT ↔ RGB | crossfade to colour |
| +4 | Red | 0–100 % |
| +5 | Green | 0–100 % |
| +6 | Blue | 0–100 % |

**Light Engine HSI *n* Pixels: 3 channels per pixel**

| Offset | Function | Values |
|---|---|---|
| +0 | Intensity | 0–100 % |
| +1 | Hue | 1°–360° |
| +2 | Saturation | 0–100 % |

**Address formula:** DMX address of pixel *p* (1-based), function *k* (0-based offset) = start + (*p* − 1) × N + *k*, with N = 7 for CCT & RGB or 3 for HSI.

**Mode 10 (PT4c, 112 ch), worked example at start address 1** [V]:
- LE 1 → ch 1–7; LE 2 → 8–14; … LE 15 → 99–105; LE 16 → 106–112.
- So pixel 16's Blue is ch 112.

**Physical size of a pixel:**
- In the 16-px mode on a PT4c, one LE ≈ 75 mm.
- In lower pixel counts the tube's 16 (PT4c) / 8 (PT2c) / 4 (PT1c) native zones are grouped evenly. For example, a PT4c in 8 px drives 2 native zones per LE. [INF; consistent with the native pixel counts and the spec's model availability]

**Pixel order:** nothing documents whether LE 1 sits at the control-box/USB-C end or the far end. [INF] Prism should provide a per-fixture "reverse pixel order" toggle.

**Universe budgeting for PT tubes** [INF arithmetic]

| Mode | Ch per tube | Tubes per 512-ch universe | 8 tubes need |
|---|---|---|---|
| LE CCT & RGB 16 px (PT4c) | 112 | 4 | 896 ch → 2 universes |
| LE CCT & RGB 8 px | 56 | 9 | 448 ch → fits, with 64 ch spare for the panel and round light |
| LE CCT & RGB 4 px | 28 | 18 | 224 |
| LE CCT & RGB 2 px | 14 | 36 | 112 |
| LE HSI 16 px (PT4c) | 48 | 10 | 384 |
| LE HSI 8 px | 24 | 21 | 192 |
| CCT & RGB (whole tube) | 10 | 51 | 80 |

Example single-universe plan for 8 × PT4c in LE 8 px [INF]:
- Tube starts: 1, 57, 113, 169, 225, 281, 337, 393 (tubes end at 448).
- Panel from 449 (e.g. an F22c in CCT & RGB 8-bit uses 449–458).
- Round fixture at 459.

### 2.6 How Lightkey's "Amaran PT" profile maps to the spec [LK]

| Lightkey mode (`customName`) | Footprint | Spec mode | Lightkey capability classes, by channel | Segments lit per pixel |
|---|---|---|---|---|
| CCT & RGB | 10 | Mode 1 | 1 Intensity · 2 ColorFilter (CCT 2700–10000 K) · 3 GreenSaturation · 4 XfadeToColor · 5–7 ColorComponent R/G/B · **10 ShutterStrobe** (0–19 open, 20–255 = 1–25 Hz) | 16 (whole tube) |
| CCT | 6 | Mode 2 | 1 Intensity · 2 ColorFilter · 3 GreenSaturation · **6 ShutterStrobe** | 16 |
| RGB | 7 | Mode 4 | 1 Intensity · 2–4 ColorComponent · **7 ShutterStrobe** | 16 |
| System FX | 7 | Mode 6 | 1 Intensity · 2 Custom "FX Control" · 3 Custom "FX Selection" · 4–7 Custom "Channel 4…7" | 16 |
| Light Engine CCT & RGB 2 Pixels | 14 | Mode 7 | per pixel: Intensity · ColorFilter · GreenSaturation · XfadeToColor · ColorComponent R/G/B. **No strobe** | 8 |
| Light Engine CCT & RGB 4 Pixels | 28 | Mode 8 | same as above, per pixel | 4 |
| Light Engine CCT & RGB 8 Pixels | 56 | Mode 9 | same | 2 |
| Light Engine CCT & RGB 16 Pixels | 112 | Mode 10 | same | 1 |

Notes on Lightkey's PT profile:
- Lightkey names the parameter groups itself: Intensity becomes "Dimmer", and ColorFilter / XfadeToColor / ColorComponent become "Color".
- So "Dimmer, Color" with no strobe fits only the four LE rows. [LK + INF]
- It has no CCT & HSI or HSI modes and no LE HSI modes.
- Each pixel block carries a `beamIndexes` range:
  - 2 px: beams 0–7 and 8–15
  - 4 px: 4 beams each
  - 8 px: 2 beams each
  - 16 px: pixel *N* → beam *N*−1
- The profile is the same for PT1c, PT2c and PT4c. **Lightkey will let a user patch "16 Pixels" on a PT2c even though the tube cannot do it.** Prism should prevent that with a model picker.

---

## 3. Aputure INFINIBAR PB3 / PB6 / PB12 (pixel bars)

**Sources:**
- INFINIBAR DMX Profile Specification V2.0 (Aug 2024, controller firmware V2.0) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Infinibar/All%20Files/INFINIBAR%20DMX%20Profile%20Specification%20V2.0.pdf
- V1.0 (Sep 2022) has modes 1–32 only; V2.0 adds HSIC+ as modes 33–41.
- Help [V] https://help.aputure.com/en/infinibar/dmx-profiles-settings · https://help.aputure.com/en/infinibar/photometrics-and-technical-specifications

### 3.1 Physical and control [V]

| Model | Length | Native pixels | Weight | CCT |
|---|---|---|---|---|
| PB3 | 30.4 × 4.5 × 4.3 cm | 24 | 0.6 kg | 2000–10000 K |
| PB6 | 60.4 cm | 48 | 1.0 kg | 2000–10000 K |
| PB12 | 120.4 cm | 96 | 1.96 kg | 2000–10000 K |

- **Control:** Sidus Link (Bluetooth), wired DMX/RDM and CRMX.
- **Wired DMX needs the Aputure *Active* USB-C to 5-pin DMX adapter.** The amaran adapters are **not** compatible. [V]

### 3.2 How to set DMX address & mode [V]

1. Press **MENU**, then rotate and press the control wheel to reach **DMX Setting**.
2. **DMX Address**: rotate to set; hold the wheel for 2 s to lock.
3. **DMX Profiles**: rotate to choose.
4. **Loss Behavior**: choose what happens when signal drops.
5. **DMX Smoothing**: Off / Smooth / Super Smooth (firmware ≥ 1.7).

On firmware before 1.6, the DMX screen must stay displayed.

### 3.3 Mode list (V2.0 numbering) [V]

| # | Name | Ch |
|---|---|---|
| 1 | CCT & RGB | 8 |
| 2 | CCT | 4 |
| 3 | CCT & HSI | 7 |
| 4 | RGB | 5 |
| 5 | HSI | 5 |
| 6 | XY | 4 |
| 7 | System FX – List of Effects | 10 |
| 8 | Pixel FX – List of Effects | 36 |
| 9–16 | Light Engine CCT & RGB 4 / 6 / 8 / 12 / **16** / 24 / 32 / 48 Pixels | 28 / 42 / 56 / 84 / **112** / 168 / 224 / 336 |
| 17–24 | Light Engine RGB 4 / 6 / 8 / 12 / 16 / 24 / 32 / 48 Pixels | 16 / 24 / 32 / 48 / **64** / 96 / 128 / 192 |
| 25–32 | Light Engine HSI 4 … 48 Pixels | 16 / 24 / 32 / 48 / 64 / 96 / 128 / 192 |
| 33 | HSIC+ | 6 |
| 34–41 | Light Engine HSIC+ 4 … 48 Pixels | 20 / 30 / 40 / 60 / 80 / 120 / 160 / 240 |

Errors in the spec's table of contents:
- LE RGB 16 px is listed as "72 channels". 16 × 4 = **64**; the body pages are correct.
- Mode 35 is spelled "HISC+".

**Which bar offers which pixel counts:** the pixel count must divide the bar's native count.
- PB3 (24 px): 4, 6, 8, 12, 24
- PB6 (48 px): 4, 6, 8, 12, 16, 24, 48
- PB12 (96 px): all eight
- Source: Aputure's grandMA pack, built for V1.x firmware. [GMA]

**Mode numbers shift per bar in the grandMA pack** because only supported pixel counts are listed. [GMA]

| Bar | LE CCT & RGB | LE RGB | LE HSI |
|---|---|---|---|
| PB3 | M9–13 | M14–18 | M19–23 |
| PB6 | M9–15 | M16–22 | M23–29 |
| PB12 | M9–16 | M17–24 | M25–32 |

**So Prism must identify modes by name + footprint, never by number alone.**

**16 zones on INFINIBAR:** PB6 and PB12 offer "Light Engine CCT & RGB 16 Pixels" (112 ch). That is 3 native pixels per LE on a PB6 and 6 on a PB12. [V + INF]

### 3.4 Channel maps [V]

**Whole-bar modes:**

| Mode | Ch 1 | Ch 2 | Ch 3 | Ch 4 | Ch 5 | Ch 6 | Ch 7 | Ch 8 |
|---|---|---|---|---|---|---|---|---|
| 1 CCT & RGB | Intensity | CCT 2000–10000 K | G/M | CCT↔RGB | Red | Green | Blue | Strobe |
| 2 CCT | Intensity | CCT | G/M | Strobe | | | | |
| 3 CCT & HSI | Intensity | CCT | G/M | CCT↔HSI | Hue | Sat | Strobe | |
| 4 RGB | Intensity | Red | Green | Blue | Strobe | | | |
| 5 HSI | Intensity | Hue | Sat | CCT (0–10 = 6500 K; 11–255 = 2000–10000 K) | Strobe | | | |
| 6 xy | Intensity | x (0–0.8) | y (0–0.8) | Strobe | | | | |
| 33 HSIC+ | Intensity | CCT (0–10 = 6500 K; 11–255 = 2000–10000 K) | ±Green | Hue | Sat | Strobe | | |

**Mode 7, System FX (10 ch):**
- **Ch 1:** Intensity.
- **Ch 2:** FX Selection — 0–9 Paparazzi II · 10–19 Lightning III · 20–29 TV III · 30–39 Fire III · 40–49 Faulty Bulb III · 50–59 Pulsing III · 60–69 Cop Car III · 70–79 Party Lights II · 80–89 Fireworks II · 90–255 Reserved.
- **Ch 3–10:** per-effect parameters, including a Stop/Play channel.
- Example, Paparazzi II:
  - Ch 3 CCT; ch 4 G/M
  - Ch 5 interval lower limit, 0.2–2 s
  - Ch 6 interval upper limit, 1–18 s
  - Ch 7: 0–10 Stop · 11–127 Play · 128–255 Reserved
- Example, Lightning III: ch 3 selects 0–9 CCT or 10–19 HSI.

**Mode 8, Pixel FX (36 ch):**
- **Ch 1:** Intensity.
- **Ch 2:** 0–10 Play · 11–60 Pause · 61–120 Stop · 121–255 Reserved.
- **Ch 3:** effect — 0–9 Color Fade · 10–19 Color Cycle · 20–29 One Pixel Chase · 30–39 Two Pixel Chase · 40–49 Three Pixel Chase · 50–59 Rainbow · 60–69 Pixel Fire · 70–255 Reserved.
- **Ch 4–36:** parameters. Example, Color Fade:
  - Ch 4 number of colours (per-bar tables)
  - Ch 5 Move: 0–127 Left / 128–255 Right
  - Ch 6 Speed, 1–640 cm/s
  - Ch 7 Colour-1 mode: 0–9 CCT / 10–19 HSI / 20–29 Black
  - Ch 8–10 colour-1 values, and so on for further colours

**Per-pixel blocks** (LE modes have no strobe and no header channel):

| LE family | Channels per pixel | Order |
|---|---|---|
| CCT & RGB | 7 | Intensity, CCT, G/M, CCT↔RGB, R, G, B |
| RGB | 4 | Intensity, R, G, B |
| HSI | 4 | Intensity, Hue, Saturation, CCT (0–10 = 6500 K; 11–255 = 2000–10000 K) |
| HSIC+ | 5 | Intensity, CCT (0–10 = 6500 K), ±Green, Hue, Saturation |

**Lightkey's "Infinibar" profile** draws a 48-segment strip. [LK] Two of its modes are mislabelled:
- "Light Engine CCT & RGB 18 Pixels" has 112 ch. That is really 16 px × 7, at 3 beams per pixel.
- "RGB 18 Pixels" has 64 ch, which is 16 × 4.

---

## 4. Aputure MT Pro (36-pixel, ~1 ft mini tube)

**Sources:**
- MT Pro DMX Profile Specification (doc V1.1 Sep 2022, controller firmware V1.2) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/MT%20Pro/All%20Files/MT-Pro-DMX-Profile-Specification-V1.2.pdf
- Help [V] https://help.aputure.com/en/mt-pro/dmx-profiles-settings

**Physical:** 30 cm, 36 native pixels, 2000–10000 K. The help centre describes it as a "7.5W RGBWW Full Color Portable Battery Powered Pixelated Mini Linear LED with CRMX". [V]

Individual pixel control is only available over DMX or CRMX. [V]

**Wired DMX** needs the Aputure Active USB-C to 5-pin DMX adapter. [V]

**How to set** [V]:
1. Press **MENU** and use the Function Control Wheel to reach **DMX Settings**.
2. **DMX Address**: hold the wheel 2 s to lock.
3. **DMX Profiles**: choose the mode.
4. **Loss Behavior**: choose what happens when signal drops.

From firmware 1.6 a **DMX Status** screen shows address, profile and battery.

**Modes** [V]:

| # | Name | Ch |
|---|---|---|
| 1–6 | CCT & RGB 8 · CCT 4 · CCT & HSI 7 · RGB 5 · HSI 5 · XY 4 | same layouts as INFINIBAR (§3.4) |
| 7 | System FX – List of Effects | 10 |
| 8 | Pixel FX – List of Effects | 36. Ch 2: 0–9 Play / 10–60 Pause / 61–255 Stop |
| 9–14 | Light Engine CCT & RGB 4 / 6 / 9 / 12 / 18 / 36 Pixels | 28 / 42 / 63 / 84 / 126 / 252 (7 ch/px) |
| 15–20 | Light Engine RGB 4 / 6 / 9 / 12 / 18 / 36 Pixels | 16 / 24 / 36 / 48 / 72 / 144 (4 ch/px) |
| 21–26 | Light Engine HSI 4 / 6 / 9 / 12 / 18 / 36 Pixels | 16 / 24 / 36 / 48 / 72 / 144 (4 ch/px: Int, Hue, Sat, HSI base CCT) |

**No 16-pixel mode exists on MT Pro.**

**Lightkey's "MT Pro"** draws a 36-segment strip. It also has an extra "LE CCT & RGB 2 Pixels" (14 ch) mode that is not in the official spec. [LK]

---

## 5. amaran T2c / T4c (non-pixel RGBWW tubes)

**Sources:**
- T2c/T4c DMX Profile Specification V1.1 [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/T2C-T4C-DMX-Profile-Specification-V1.1.pdf?v=1739938087 (header: "Controller Firmware V1.4", "V1.0 June 2022")
- Manual [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/T2C-Manual-EN_220316.pdf
- Help [V] https://help.aputure.com/en/amaran-tube/menu-options

**Physical:** T2c is 2 ft and T4c is 4 ft (lengths from the model names [INF]). CCT 2500–7500 K. Control by Sidus Link app or DMX. [V]

**DMX treats the whole tube as one zone.** The light has "TouchBar FX" and "Picker FX" locally, but there are **no pixel modes**. [V]

**How to set** [V]:
- Press the knob → **"DMX mode"**, then rotate the knob to set the DMX channel (001–512).
- Requires the "amaran USB-C to DMX Adapter with USB-C Input".
- **No document says how to choose the profile on the tube.** [gap]

**Modes, in the PDF's order** [V]:

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | CCT 8-bit | 6 | Int, CCT 2500–7500 K, G/M, Res, Res, Strobe |
| 2 | RGB 8-bit | 7 | Int, R, G, B, Res, Res, Strobe |
| 3 | HSI 8-bit | 6 | Int, Hue, Sat, Res, Res, Strobe |
| 4 | GEL 8-bit | 8 | Int, CCT (0–126 3200 K / 127–255 5600 K), Rosco 0–29 / Lee 30–59, Series, Category, Res, Res, Strobe |
| 5 | FX 8-bit | 9 | see below |
| 6 | CCT & RGB 8-bit | 10 | Int, CCT, G/M, CCT↔RGB, R, G, B, Res, Res, Strobe |
| 7 | CCT & HSI 8-bit | 9 | Int, CCT, G/M, CCT↔HSI, Hue, Sat, Res, Res, Strobe |

**Mode 5, FX 8-bit (9 ch):**
- **Ch 1:** Intensity.
- **Ch 2:** for Lightning, 0–9 Loop / 10–69 Trigger / 70–255 Stop. For other effects, 0–69 Loop / 70–255 Stop.
- **Ch 3:** FX Selection — 0–9 Paparazzi · 10–19 Lightning · 20–29 TV · 30–39 Fire · 40–49 Faulty Bulb · 50–59 Pulsing · 60–69 Cop Car · 70–79 Party Lights · 80–89 Fireworks · 90–255 Reserved.
- **Ch 4–9:** parameters, the same ideas as PT §2.4. Example, Paparazzi: ch 4 CCT, ch 5 G/M, ch 6 Frequency 1–10.
- Faulty Bulb and Pulsing add a **GEL** sub-mode, which uses ch 5–9.

**The mode numbering conflicts between sources:**
- The grandMA pack orders them "1 CCT+RGB, 2 CCT, 3 CCT+HSI, 4 RGB, 5 HSI, 6 GEL". [GMA]
- Lightkey's "T2C & T4C" has CCT & RGB 10, CCT 6, RGB 7, GEL 8 and FX 9, drawn as a single beam. [LK]
- So match by name and footprint.

---

## 6. amaran F21c / F22c and F21x / F22x (flexible LED mats)

**Sources:**
- F21c/F22c DMX Profile Specification V1.0 (June 2022, firmware V1.1) [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/F21C-F22C-DMX-Profile-Specification-V1.0.pdf?v=1714261743
- F21x/F22x Pro DMX Profile Specification V1.0 (firmware v1.1) [V] https://cdn.shopify.com/s/files/1/0862/5432/1947/files/F21X-F22X-Pro-DMX-Profile-Specification-V1.0.pdf
- Help [V] https://help.aputure.com/en/amaran-flexible-lights/dmx-profiles-and-settings

**Physical:**
- F21 = 1 × 2 ft (rectangular); **F22 = 2 × 2 ft (square)**. Sizes come from the product naming and are widely published, but the official spec tables are images, so I could not read them. [INF]
- c = RGBWW, 2500–7500 K. x = bi-colour, 2500–7500 K.
- Wired DMX uses the "amaran Type-C to DMX Adapter with Type-C Input". [V]

**How to set** [V]:
1. Press **MENU**, rotate the **INT** knob and press to select **DMX Settings**.
2. Rotate the INT knob to set the DMX channel (001–512).
3. On the DMX Address screen, press and hold the INT knob to lock (hold again to unlock).
4. The control box must keep showing the "DMX Address Screen".

The default address is 001. **No document says how to choose the profile on the light.** [gap]

### F21c / F22c modes [V]

The channel layouts are identical to the matching T2c/T4c modes in §5.

| # | Name | Ch |
|---|---|---|
| 1 | CCT & RGB 8-bit | 10 (Int, CCT, G/M, CCT↔RGB, R, G, B, Res, Res, Strobe) |
| 2 | CCT 8-bit | 6 |
| 3 | CCT & HSI 8-bit | 9 |
| 4 | RGB 8-bit | 7 |
| 5 | HSI 8-bit | 6 |
| 6 | GEL 8-bit | 8 |
| 7 | FX 8-bit | 9 |

Lightkey's "F21C & F22C" draws one beam, with modes "CCT & RGB 8-bit" 10, "CCT 8-bit" 6, "RGB 8-bit" 7, "Gel 8-bit" 8 and "FX 8-bit" 9. [LK]

### F21x / F22x modes [V]

**M1 "CCT 8-bit"** (the table of contents calls it "Lighting 8-bit"), **2 ch:** 1 Intensity · 2 CCT 2500–7500 K.

**M2 "FX 8-bit", 5 ch:**
- **Ch 1** Intensity; **ch 2** CCT.
- **Ch 3** trigger:
  - Lightning: 0–9 Loop / 10–69 Trigger / 70–255 Stop
  - Explosion: 0–69 Trigger / 70–255 Stop
  - Others: 0–69 Loop / 70–255 Stop
- **Ch 4** FX: 0–19 Paparazzi · 20–39 Fireworks · 40–59 Faulty bulb · 60–79 Lightning · 80–99 TV · 100–119 Pulsing · 120–139 Strobe · 140–159 Explosion · 160–179 Fire · 180–255 reserved.
- **Ch 5** Frequency: 1–10 in 20-value steps; 200–255 Random.

---

## 7. Aputure Nova P300c and Nova P600c (RGBWW panels)

### 7.1 Nova P300c

**Sources:**
- Nova P300c DMX Profile Specification V1.1 (Sept 2022, controller firmware V1.8) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/NovaP300c-P600c/All%20Files/Nova-P300c-DMX-Profile-Specification-V1.1.pdf
- The modes match OFL `aputure/nova-p300c`. [OFL]

**Physical:** CCT 2000–10000 K. **No strobe channel in any P300c mode.** [V]

**How to set:**
- The help page says "Rotate the wheel to select the DMX Profile": https://help.aputure.com/en/nova-p600c-p300c/wired-dmx-controlsettings
- The full button path is not documented. [INF] Expect a DMX item in the system menu, with address and profile inside.
- The manual (https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/NovaP300c-P600c/All%20Files/Nova_P300c_Manual_20200722-EN.pdf) has no DMX menu description.

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | CCT & RGB 8-bit | 7 | Int, CCT, G/M (±0.1–0.9 labels), CCT↔RGB, R, G, B |
| 2 | CCT 8-bit | 3 | Int, CCT, G/M |
| 3 | CCT & HSI 8-bit | 6 | Int, CCT, G/M, CCT↔HSI, Hue, Sat |
| 4 | GEL 8-bit | 5 | Int, CCT 3200/5600, **Lee 0–29 / Rosco 30–59**, Series, Category |
| 5 | HSI 8-bit | 3 | Int, Hue, Sat |
| 6 | Source 8-bit | 2 | INT, Source (2-value steps: 0–1 Tungsten Bulb, 2–3 Incandescent, 4–5 Halogen, 6–7 Antique Bulb, 8–9 Warm Antique Bulb, 10–11 Christmas Lights, 12–13 Night Light, 14–15 Infrared Heat Lamp … 90–91 Violet Glow Stick; 92–255 reserved) |
| 7 | RGB 8-bit | 4 | Int, R, G, B |
| 8 | XY 8-bit | 3 | Int, x, y (0–0.8) |
| 9 | FX 8-bit | 10 | see below |

**Mode 9, FX 8-bit (10 ch):**
- **Ch 1:** FX Selection — 0–9 Club Lights · 10–19 Paparazzi · 20–29 Lightning · 30–39 TV · 40–49 Candle · 50–59 Fire · 60–69 Strobe · 70–79 Explosion · 80–89 Faulty Bulb · 90–99 Pulsing · 100–109 Welding · 110–119 Cop Car · 120–129 Color Chase · 130–139 Party Lights · 140–149 Firework · 150–255 Reserved.
- **Ch 2:** Intensity. Note the order: the effect comes **first**, intensity **second**.
- **Ch 3–10:** parameters. Example, Club Lights ch 3 = number of colours: 0–9 = 3, 10–19 = 6, … 70–79 = 36.

**Lightkey's "Nova P300c (Firmware v1.8)"** draws a 6 × 6 grid of beams. [LK]

### 7.2 Nova P600c (2 × 1 panel [INF], 4 light engines [V])

**Source:** Nova P600c DMX Profile Specification V1.1.1 (May 2022, firmware V1.5) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/NovaP300c-P600c/P600c%20All%20Files/Nova-P600c-DMX-Profile-Specification-V1.1.1.pdf

CCT 2000–10000 K. Same Gen-1 encodings as §1.1.

**8-bit modes:**

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | CCT & RGB 8-bit | 8 | Int, CCT, G/M, CCT↔RGB, R, G, B, Strobe |
| 2 | CCT 8-bit | 4 | Int, CCT, G/M, Strobe |
| 3 | CCT & HSI 8-bit | 8 | Int, CCT, G/M, CCT↔HSI, Hue, Sat, HSI Base CCT, Strobe |
| 4 | RGB 8-bit | 5 | Int, R, G, B, Strobe |
| 5 | HSI 8-bit | 5 | Int, Hue, Sat, HSI Base CCT, Strobe |
| 6 | GEL 8-bit | 6 | Int, CCT, Rosco/Lee, Series, Category, Strobe |
| 7 | XY 8-bit | 4 | Int, x, y, Strobe |
| 8 | Source 8-bit | 5 | INT, Source, x adjust, y adjust, Strobe |
| 9 | FX 8-bit | 21 | Int, FX Selection (19 effects: 0–9 Club Lights … 140–149 Fireworks, 150–159 Color Fade, 160–169 Color Cycle, 170–179 Color Gradient, 180–189 One Color Chase), ch 3–21 parameters (the doc prints "3 – 35") |
| 10 | WW & RGB 8-bit | 5 | Warm White, Cool White, R, G, B (**no intensity channel**) |
| 11 | Light Engine CCT & RGB 8-bit | 28 | 4 × [Int, CCT, G/M, CCT↔RGB, R, G, B] |
| 12 | Light Engine HSI 8-bit | 16 | 4 × [Int, Hue, Sat, HSI Base CCT] |
| 13 | Light Engine XY 8-bit | 12 | 4 × [Int, x, y] |
| 14 | Ultimate Mode 8-bit | 22 | see below |

**Mode 14, Ultimate (22 ch):**
- **Ch 1:** Intensity.
- **Ch 2:** Lighting Mode Selection — 0–9 CCT & RGB · 10–19 CCT · 20–29 CCT & HSI · 30–39 RGB · 40–49 HSI · 50–59 Gel · 60–69 XY · 70–79 Source · 80–89 FX (the doc misprints this as "80–79") · 90–255 Reserved.
- **Ch 3–22:** the parameters of the selected mode.

**16-bit modes** (coarse/fine pairs; strobe stays 8-bit):

| # | Name | Ch | Channels |
|---|---|---|---|
| 15 | CCT & RGB 16-bit | 15 | 1/2 Int, 3/4 CCT, 5/6 G/M, 7/8 CCT↔RGB, 9/10 R, 11/12 G, 13/14 B, 15 Strobe |
| 16 | CCT 16-bit | 7 | |
| 17 | CCT & HSI 16-bit | 15 | |
| 18 | RGB 16-bit | 9 | |
| 19 | HSI 16-bit | 9 | |
| 20 | GEL 16-bit | 7 | |
| 21 | XY 16-bit | 7 | |
| 22 | Source 16-bit | 6 | |
| 23 | FX 16-bit | 35 | 1/2 Int, 3 FX select, 4–35 parameters |
| 24 | WWRGB 16-bit | 10 | |
| 25 | Light Engine CCT & RGB 16-bit | 56 | |
| 26 | Light Engine HSI 16-bit | 32 | |
| 27 | Light Engine XY 16-bit | 24 | |
| 28 | Ultimate Mode 16-bit | 36 | 1/2 Int, 3 select, 4–36 |

**Lightkey's "Nova P600c"** draws a 4 × 1 grid. [LK] Two problems:
- It has no LE HSI mode.
- "8 Bit – Source" appears twice, and the second copy sits where 16-bit Source should be.

---

## 8. Aputure LS (Light Storm) COB family

### 8.1 LS 600c Pro and LS 600c Pro II (RGBWW COB)

**Sources:**
- LS600c Pro & LS600c Pro II DMX Profile Specification V1.6 [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600c%20Pro%20II/Documents/LS600c%20Pro%20%26%20LS600c%20Pro%20II%20DMX%20Profile%20Specification%20V1.6.pdf
- Settings help [V] https://help.aputure.com/en/ls600c-pro/lighting-configuration-settings · https://help.aputure.com/en/ls-600c-pro-ii/lighting-configuration-settings

CCT 2300–10000 K. Gen-1 encodings (§1.1).

**How to set** [V]:
1. Press **MENU**, rotate the Select wheel to **DMX Mode**.
2. **DMX Address**: hold MENU 2 s to lock; hold SELECT 2 s to unlock.
3. **DMX Loss Behavior**: choose what happens when signal drops.
4. **DMX Profile**: pick a profile from the 8-bit or 16-bit list.

The Pro II also has:
- **DMX Smoothing**: Off / Feather / Smooth / Super Smooth
- CRMX, Art-Net and sACN

**8-bit modes:**

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | CCT & RGB 8-bit | 8 | Int, CCT, G/M, CCT↔RGB, R, G, B, Strobe |
| 2 | CCT 8-bit | 4 | Int, CCT, G/M, Strobe |
| 3 | CCT & HSI 8-bit | 8 | Int, CCT, G/M, CCT↔HSI, Hue, Sat, HSI Base CCT (0–10 = 6500 K), Strobe |
| 4 | RGB 8-bit | 5 | Int, R, G, B, Strobe |
| 5 | HSI 8-bit | 5 | Int, Hue, Sat, HSI Base CCT, Strobe |
| 6 | GEL 8-bit | 6 | Int, CCT, Rosco/Lee, Series, Category, Strobe |
| 7 | xy 8-bit | 4 | Int, x, y, Strobe |
| 8 | Source 8-bit | 5 | INT, Source (3-value steps … 102–104 Blow Torch, 105–107 Road Flare … 136–138 Violet Glow Stick), x, y, Strobe |
| 9 | FX 8-bit | 10 | see below |
| 10 | WW & RGB 8-bit | 5 | Warm White, Cool White, R, G, B |
| 11 | Ultimate Mode 8-bit | 11 | Int; ch 2 Lighting Mode Selection (0–9 CCT & RGB … 80–89 FX, misprinted "80–79"); ch 3–11 parameters |

**Mode 9, FX 8-bit (10 ch):**
- **Ch 1:** Int.
- **Ch 2:** Effect Trigger — 0–10 Loop · 11–60 Trigger · 61–255 Stop.
- **Ch 3:** FX Selection — 0–9 Club Lights … 140–149 Fireworks.
- **Ch 4–10:** parameters.

**16-bit modes:**

| # | Name | Ch |
|---|---|---|
| 12 | CCT & RGB 16-bit | 15 |
| 13 | CCT 16-bit | 7 |
| 14 | CCT & HSI 16-bit | 15 |
| 15 | RGB 16-bit | 9 |
| 16 | HSI 16-bit | 9 |
| 17 | GEL 16-bit | 7 |
| 18 | xy 16-bit | 7 |
| 19 | Source 16-bit | 6 |
| 20 | **"FX CCT 16-bit"** | 12 (1/2 Int, 3 FX select, 4–12) |
| 21 | WWRGB 16-bit | 10 |
| 22 | Ultimate Mode 16-bit | 16 |

### 8.2 LS 600x Pro (bi-colour)

**Sources:**
- LS600X Pro DMX Profile Specification V1.0.1 (Feb 2022, firmware v1.2) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600x%20Pro/All%20Files/LS600X-Pro-DMX-Profile-Specification-V1.0-.pdf
- Manual [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600x%20Pro/All%20Files/LS-600x-Pro-Product-Manual.pdf

CCT 2700–6500 K. **Menu:** DMX Mode → DMX Address / DMX Loss Behavior / DMX Profile. [V]

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | Lighting | 2 | Int, CCT |
| 2 | Effects | 5 | Int, CCT, Effects, Frequency, Trigger |
| 3 | Lighting & Effects | 6 | Int, CCT, Mode (0–127 Lighting / 128–255 Effects), Effects, Frequency, Trigger |

Value ranges:
- **Effects:** 0–19 Paparazzi · 20–39 Fireworks · 40–59 Faulty bulb · 60–79 Lightning · 80–99 TV · 100–119 Pulsing · 120–139 Strobe · 140–159 Explosion · 160–179 Fire · 180–255 reserved.
- **Frequency:** 1–10 in 20-value steps; 200–219 Random; 220–255 reserved.
- **Trigger:**
  - Lightning: 0–10 Stop, 11–127 Trigger, 128–255 Loop
  - Explosion: 0–10 Stop, 11–127 Trigger, 128–255 reserved

OFL splits the trigger across two channels (6 / 7-channel modes). The official doc does not, so this is an OFL error. [OFL vs V]

### 8.3 LS 300x (bi-colour; the official manual contains the DMX chart)

**Source:** LS 300x Product Manual [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20300x/All%20files/LS_300x-Product_Manual_EN.pdf

**One mode, 6 channels:**

| Ch | Function | Values |
|---|---|---|
| 1 | Dimmer | 0–255 |
| 2 | CCT | **stepped**: 0–5 = 2700 K, 6–10 = 2800 K … 191–195 = 6500 K (100 K per 5 values); 196–255 undefined |
| 3 | FX Frequency | 0–19 = 1 … 180–199 = 10; 200–219 = Random; 220–255 undefined |
| 4 | Mode | 0–127 Manual / 128–255 FX |
| 5 | FX | 0–19 Paparazzi · 20–39 Fireworks · 40–59 Faulty Bulb · 60–79 Lightning · 80–99 TV · 100–119 Pulsing · 120–139 Strobe · 140–159 Explosion · 160–178 Fire · 180–255 undefined |
| 6 | Trigger | **Lightning:** 0 start, 1–127 single trigger, 128–255 cycle<br>**Explosion:** 0 start, 1–127 single trigger, 128–255 undefined |

**How to set** [V]:
1. Press **MENU** and rotate the dimming wheel to **"DMX mode"**, then press MENU.
2. Rotate the brightness wheel to set the channel.
3. Press MENU to go back.

When chaining several lights, space their addresses 6 apart.

### 8.4 LS 600d Pro and LS 300d II (daylight)

**Sources** [V]:
- https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600d%20Pro/All%20Files/LS-600d-Pro-DMX-Profile-Specification-V1.0-.pdf
- Common doc: https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20300d%20II/All%20files/LS-600d-Pro-LS-300d-II-common-DMX-Profile-Specification-V1.0.pdf

**One mode, "Lighting & Effect 8-bit", 5 ch:**
- Int
- Mode: 0–127 Lighting / 128–255 Effects
- Effects: same list as §8.5 with no Fire; 160–255 reserved
- Frequency
- Trigger

OFL lists 6 ch. Follow the official doc.

### 8.5 LS 600d (V1.0.1 Apr 2022) and LS 1200d Pro

**Sources** [V]:
- https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600d/All%20files/LS-600d-DMX-Profile-Specification-V1.0-.pdf
- https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%201200d%20Pro/All%20Files/LS1200D-Pro-DMX-Profile-Specification-V1.0-.pdf

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | Lighting 8-bit | **1** | Intensity |
| 2 | Effect 8-bit | 4 | Intensity, Effects, Frequency, Trigger |
| 3 | Lighting & Effect 8-bit | 5 | Intensity, Mode (0–127 Lighting / 128–255 Effects), Effects, Frequency, Trigger |
| 4 | Lighting 16-bit (1200d Pro only) | 2 | Intensity coarse/fine |
| 5 | Effect 16-bit (1200d Pro only) | 5 | Intensity 16-bit, Effects, Frequency, Trigger |
| 6 | Lighting & Effect 16-bit (1200d Pro only) | 6 | Intensity 16-bit, Mode, Effects, Frequency, Trigger |

Value ranges:
- **Effects:** 0–19 Paparazzi · 20–39 Fireworks · 40–59 Faulty bulb · 60–79 Lightning · 80–99 TV · 100–119 Pulsing · 120–139 Strobe · 140–159 Explosion · 160–255 Reserved.
- **Frequency:** 1–10 in 20-value steps; 200–219 Random; 220–255 reserved.
- **Trigger:**
  - Lightning: 0–10 Stop, 11–127 Trigger, 128–255 Loop
  - Explosion: 0–10 Stop, 11–127 Trigger, 128–255 reserved

**A daylight LS in "Lighting 8-bit" is a real 1-channel "Dimmer only" Aputure fixture.** See §13.

### 8.6 LS C300d II

Source: OFL `aputure/ls-c300d-ii`, which cites the manual. The manual itself is image-only. [OFL]

**5 ch:**
- Dimmer
- Mode: 0–127 Manual / 128–255 FX
- FX Control: same list as LS 300x minus Fire; 160–255 none
- FX Frequency: 1–10 in 20-value steps; 200–219 Random
- FX Options (trigger)

---

## 9. Aputure STORM (OS II protocol)

### 9.1 STORM 1000c / STORM 80c

**Source:** STORM 1000c & 80c DMX Profile Specification V1.3 (May 2026, controller firmware V1.0) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/STORM%2080c/manuals/STORM%201000c%20%26%2080c%20DMX%20Profile%20Specification%20V1.3.pdf

**Encodings:**
- CCT 1800–20000 K (3200 K = 20; 16-bit 5041).
- ±Green default 137 (the overview text says 133); 16-bit default 35390.
- Odd-numbered profiles are 8-bit and even-numbered are 16-bit.

**Basic profiles:**

| # (8 / 16-bit) | Name | Ch (8 / 16) | 8-bit channel order |
|---|---|---|---|
| 1 / 2 | CCT & RGB | 7 / 14 | Int, CCT, ±Green, Crossfade (White Light → RGB), R, G, B |
| 3 / 4 | CCT & RGB & FX | 17 / 26 | P1 + 8 Crossfade 2 (static → FX), 9 Trigger, 10 Effect select (15 effects, Club Lights … Fireworks), 11–17 Effect parameters |
| 5 / 6 | CCT & RGB & xy | 10 / 20 | P1 + 8 Crossfade 2 (→ xy), 9 x, 10 y (defaults = 3200 K: x 0.4234 → 136, y 0.3989 → 125) |
| 7 / 8 | CCT & RGB & xy & FX | 20 / 32 | |
| 9 / 10 | HSI | 3 / 6 | Int, Hue 0–359.9°, Sat |
| 11 / 12 | HSIC+ | 5 / 10 | Int, CCT, ±Green, Hue, Sat |
| 13 / 14 | HSIC+ & FX | 15 / 22 | |
| 15 / 16 | HSIC+ & xy | 8 / 16 | |
| 17 / 18 | HSIC+ & xy & FX | 18 / 28 | |
| 19 / 20 | xy | 3 / 6 | |
| 21 / 22 | RGB | 3 / 6 | R, G, B (no intensity channel) |
| 23 / 24 | iRGB | 4 / 8 | Int, R, G, B |
| 25 / 26 | RGBACL | 6 / 12 | R, G, B, Amber, Cyan, Lime |
| 27 / 28 | CCT+ | 3 / 6 | Int, CCT, ±Green |
| 29 / 30 | Source Mode | 4 / 7 | Int, Source, x, y |
| 31 / 32 | Legacy Gel | 5 / 6 | |

**Control profiles 41–72:** each is the matching basic profile plus **Strobe, Control and Fan**. Example: P41 "CCT & RGB & Control 8-bit" = P1 + 8 Strobe, 9 Control, 10 Fan Mode = 10 ch.

**Colour-space profiles 81–90, all "& Control":**

| Profile | Ch (8-bit / 16-bit) |
|---|---|
| VRGB | P81 9 / P82 14 |
| VRGB-I | P83 10 / P84 16 |
| VRGB-CS | P85 7 / P86 10 |
| VRGB-709 | P87 6 / P88 9 |
| VRGB-sRGB | P89 6 / P90 9 |

P81 layout: R, G, B, CCT, ±Green, Color (colour-space chart), Strobe, Control, Fan.

**Strobe:** 0–13 Off · 14–128 Random 0.4–25 Hz · 129–255 Constant 0.4–25 Hz.

**Fan:** 0–38 Smart · 39–77 High (39–50 Max, 80c only) · 78–115 Medium · 116–153 Low · 154–191 Delayed · 192–255 Silent. The fan channel only works when the light's System Fan setting is "DMX Controlled".

**Control channel:** hold the value for 2.5 s, then return to 0. The light confirms with a red flash at 20 %.

| Values | Action |
|---|---|
| 0–10 | none |
| 11–13 / 14–16 | flash on / off |
| 17–19 / 20–22 / 23–25 | Sidus Bluetooth on / off / reset |
| 26–28 / 29–31 / 32–34 / 35–37 | smoothing Off / Smooth / Super Smooth / Feather |
| 38–40 / 41–43 / 44–46 / 47–49 / 50–52 / 53–55 | CRMX on / off / unlink / link / RX / TX |
| 56–58 / 59–61 | RDM off / on |
| 62–64 / 65–67 | High Speed on / off |
| 68–70 / 71–73 | Constant Output / Max Output |
| 74–76 / 77–79 | Studio Mode on / off |
| 80–82 / 83–85 | fan DMX control on / off |
| 98–100 / 101–103 / 104–106 / 107–109 | dimming curve Linear / Exp / Log / S-curve |
| 250–252 / 253–255 | control channel on / off |

The doc's prose examples cite channels 7/8/9; the tables (8/9/10) are authoritative.

### 9.2 STORM 1200x (bi-colour)

**Source:** STORM 1200x DMX Profile Specification V1.5 (July 2025) [V] https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/STORM%201200x/documents/STORM%201200x%20DMX%20Profile%20Specification%20V1.5.pdf

**Encodings:**
- CCT 2500–10000 K: 3200 = 24 (16-bit 6117), 5600 = 106, 6500 = 136, 10000 = 255.
- ±Green default 133.
- Odd profiles are 8-bit, even are 16-bit.

| # | Name | Ch (8 / 16) | 8-bit order |
|---|---|---|---|
| 1 / 2 | CCT+ | 3 / 6 | Int, CCT, ±Green |
| 3 / 4 | CCT+ Control | 6 / 9 | + Strobe, Control, Fan (0–38 Auto/Smart, 39–77 Max, 78–115 Med, 116–153 Low, 154–191 Delayed, 192–255 Silent) |
| 5 / 6 | CCT+ Control & FX | 10 / 13 | Int, CCT, ±Green, Crossfade (CCT → FX), Trigger, Effect, Frequency, Strobe, Control, Fan |
| 7 / 8 | xy | 3 / 6 | |
| 9 / 10 | xy & Control | 6 / 9 | |
| 11 / 12 | xy & Control & FX | 10 / 13 | |
| 13 / 14 | CCT & xy | 6 / 12 | |
| 15 / 16 | CCT & xy & Control | 9 / 15 | the doc misnumbers ch 11–13 |
| 17 / 18 | Limited CCT & RGB | 7 / 14 | Int, CCT, ±Green, Crossfade (CCT → RGB), R, G, B |
| 19 / 20 | Limited CCT & RGB & Control | 10 / 17 | |
| 21 / 22 | Limited HSIC+ | 5 / 10 | |
| 23 / 24 | Limited HSIC+ Control | 8 / 13 | |
| 25 / 26 | RGB | 3 / 6 | |
| 27 / 28 | RGB & Control | 6 / 9 | |
| 29 / 30 | RGBA | 4 / 8 | |
| 31 / 32 | RGBA & Control | 7 / 11 | |

---

## 10. Aputure Electro Storm XT26 and CS15 (variable footprint)

**Sources** [V]:
- https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Electro%20Storm%20XT26/Electro%20Storm%20XT26%20DMX%20Profile%20Specification%20V1.1.pdf (the header reads V1.2, May 2024, firmware V1.2)
- https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Electro%20Storm%20CS15/Electro%20Storm%20CS15%20DMX%20Profile%20Specification%20V1.1.pdf (V1.1, Jan 2024, firmware V1.2)
- XT26 manual: https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Electro%20Storm%20XT26/ElectroStorm%20XT26%20Manual%20V1.0%20EN.pdf

**The footprint changes with two settings** in the light's **"DMX Profile Extension"** menu. Changing either one means the fixture must be re-patched.
- **"Motorized Accessories"** (default ON) adds **+3 ch**:
  - Zoom 18–50°
  - Pan 0–360°
  - Tilt ±135°
  - Each has 0–19 = no effect.
- **"Function Configuration"** (default ON) adds **+2 ch**:
  - Fan: Smart / High / Medium / Silent, in quarters of the range
  - Dimming curve: Linear / S-curve / Exp / Log

**XT26** (2700–6500 K; G/M is half range):

| # | Name | Ch | Notes |
|---|---|---|---|
| 1 | CCT 8-bit | 4–9 | 1 Int, 2 CCT, 3 G/M, 4 Strobe; + 5 Zoom, 6 Pan, 7 Tilt; + 8 Fan, 9 Dimming curve |
| 2 | FX 8-bit | 4–9 | |
| 3 | CCT & FX 8-bit | 7–12 | |
| 4 | CCT 16-bit | 7–15 | |
| 5 | FX 16-bit | 5–13 | the table of contents says 4–12 |
| 6 | CCT & FX 16-bit | 10–18 | |

**CS15** (2000–10000 K), 22 modes:

| # | Name | Ch | Notes |
|---|---|---|---|
| 1 | CCT & RGB 8-bit | 8–13 | Int, CCT, G/M, CCT↔RGB, R, G, B, Strobe, + options |
| 2 | CCT 8-bit | 4–9 | |
| 3 | CCT & HSI 8-bit | 8–13 | |
| 4 | RGB 8-bit | 5–10 | |
| 5 | Adv.HSI 8-bit | 5–10 | |
| 6 | Gel 8-bit | 6–11 | |
| 7 | x y 8-bit | 4–9 | |
| 8 | Source 8-bit | 5–10 | |
| 9 | FX 8-bit | 10–15 | |
| 10 | WWRGB 8-bit | 6–11 | |
| 11 | Ultimate 8-bit | — | the doc leaves the count blank |
| 12–22 | 16-bit versions | — | 12 CCT & RGB 15–23 · 13 CCT 7–15 · 14 CCT & HSI 15–23 · 15 RGB 9–17 · 16 Adv.HSI 9–17 · 17 Gel 7–15 · 18 x y 7–15 · 19 Source 6–14 · 20 FX 13–21 · 21 WWRGB 11–19 · 22 Ultimate 8–24 |

---

## 11. amaran Ray 360c / 660c and amaran Halo 60x / 100x / 200x / 300x / 600x (2025–26 COBs)

**Sources:**
- amaran DMX Profile Specification **V1.2 EN (June 2026)** [V]. It is image-only; I read it page by page. https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran_DMX_V1.2_EN.pdf?v=1793844618
- CN V1.1 (Mar 2026, text) https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaranHalo_DMXProfile_CN_V1.1_260303.pdf?v=1772650840
- Ray CN V1.0 https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaranRay360c660c_DMXProfile_CN_V1.0.pdf?v=1764889016
- Halo help [V] https://help.amarancreators.com/en/amaran-halo-60x-100x/operation-and-controls

These lights use the **new locking "amaran USB-C to 5-Pin DMX In & Out Adapter"**. [V] Halo is bi-colour, 2700–6500 K.

| # | Name | Ch | Channels |
|---|---|---|---|
| 1 | CCT Universal | 3 | Int, CCT 2700–6500 K (3200 = 34, 5600 = 195), Strobe (0–13 Off, 14–128 Random 1–25 Hz, 129–255 Constant) |
| 2 | CCT | 5 | Int, CCT, ±Green (default 133), Strobe, CCT Extension (0–127 off / 128–255 on) |
| 3 | RGB | 5 | Int, R, G, B, Strobe (CCT locked at 6500 K) |
| 4 | CCT & RGB | 9 | Int, CCT, ±Green, Crossfade, R, G, B, Strobe, CCT Extension |
| 5 | HSI | 4 | Int, Hue, Sat, Strobe |
| 6 | HSIC+ | 7 | Int, CCT, ±Green, Hue, Sat, Strobe, CCT Extension |
| 7–12 | profiles 1–6 + Control + Fan | 5 / 7 / 7 / 11 / 6 / 9 | e.g. P7 = Int, CCT, Strobe, Control, Fan |

Notes:
- **P1 limits CCT and drops ±Green** so that mixed amaran series behave alike.
- **P2 CCT range** depends on CCT Extension:
  - Off: 2300–10000 K (3200 = 30)
  - On: 1800–20000 K. The doc says 3200 = 17, but a linear scale would give 20. Flag this.
- **Fan (P7–12):** 0–63 Auto/Smart · 64–127 High · 128–191 Delayed · 192–255 Silent.
- **Control chart:** 11–16 flash, 26–37 smoothing; all other values N/A.
- **Compatibility:** Ray 360c/660c support every profile. **Halo models support only P1 (and its Control version, P7).**

**How to set on a Halo** [V]:
1. Main menu (rotate and press the CCT knob) → **DMX**.
2. The menu shows **DMX Status Display**, **DMX Address** (1–512), **DMX Signal Loss Behavior** and **DMX Profile**.
3. Signal-loss choices: Hold Last State / Instant Off / Fade Out / Hold 2 min then Fade Out.

**Ray:** the path is presumably the same. [INF]

---

## 12. Fixtures in the brief with no wired DMX [V]

These are controlled only by on-board controls and the Sidus Link / amaran app over Bluetooth mesh. Each spec page lists "Control Methods: Manual, Sidus Link App" with no DMX:
- amaran **100d S / 200d S / 100x S / 200x S**
- **150c / 300c**
- **COB 60d S / 60x S**
- **P60c / P60x**
- **Ace 25c / 25x** (Manual, amaran App)
- **Aputure Accent B7c** (on-board, Sidus Link, Bluetooth mesh; 2000–10000 K; E26/E27)
- **amaran Verge** (on-board / app)

Sources:
- https://help.aputure.com/en/amaran-150c-300c/photometrics-technical-specifications
- https://help.aputure.com/en/amaran-p60c-p60x/photometrics-and-technical-specifications
- https://help.aputure.com/en/b7c-bulb/photometrics-technical-specifications
- https://help.aputure.com/en/amaran-100xs-200xs/technical-specifications-photometrics
- https://help.aputure.com/en/amaran-60ds/photometrics-technical-specifications
- The amaran wired-DMX compatibility list is limited to F21c/F22c/F21x/F22x, PT1c/PT2c/PT4c, T2c/T4c, Ray 360c/660c and Halo 60x–600x: https://help.aputure.com/en/which-amaran-lights-can-i-control-with-dmx-which-adapters-are-needed-for-each-fixture

Prism cannot drive any of these over the Enttec. Sidus Link Pro (iPad) can control them over Bluetooth, but that is outside DMX.

---

## 13. The user's other two fixtures: hypotheses [INF]

**Round fixture shown as "Dimmer" only.** Three explanations fit:
- A **daylight Aputure LS** (LS 600d or LS 1200d Pro) in **"Lighting 8-bit"**, a true 1-channel mode (§8.5).
- A **COB patched in Lightkey as a generic 1-channel dimmer.** If this is an amaran Halo in P1 "CCT Universal":
  - The light's ch 2 (CCT) and ch 3 (strobe) would sit at 0, giving 2700 K with strobe off.
  - Prism would then need a "CCT stays at 0" warning, or should simply patch the real 3-ch profile.
- A practical lamp on a DMX dimmer pack.

The Halo's own P1 would show Dimmer + Color + Strobe, not Dimmer alone.

**Square panel:**
- Most likely an **amaran F22c** (2 × 2 ft, on the same amaran USB-C adapter family as the PT tubes) or an **F22x**.
- Alternatively an Aputure **Nova P300c**, which Lightkey draws as a 6 × 6 grid.
- Ask the user for the model name, or for the Lightkey patch line showing manufacturer, fixture, mode and footprint.

---

## 14. Implementation notes for Prism's fixture library [INF, derived from the above]

- **Model a mode as:**
  - an ordered list of channel roles: intensity, cct, gm, xfade, red/green/blue, hue, sat, hsiBaseCct, x, y, strobe, reserved, enum (FX select), and so on
  - plus, for pixel modes, a repeat block: `pixelCount × [roles]`
  - plus an optional header, which none of the PT / INFINIBAR / MT Pro / Nova pixel modes have
- **Key modes by (manufacturer, model, mode name, footprint).** Mode numbers differ between docs, Lightkey and the grandMA pack (T2c/T4c, INFINIBAR).
- **Value encoders needed:**
  - Gen-1 G/M piecewise table
  - linear CCT with per-family limits, plus the stepped LS 300x table
  - hue 1–360°
  - xy 0–0.8
  - OS-II 16-bit ±Green table
  - enum FX tables
- **Pixel UI:** draw the selected mode's real pixel count (2/4/8/16), not a fixed 16. Offer "reverse pixel order" and "mirror with another fixture" (same address).
- **Colour control:**
  - For CCT & RGB blocks, output white as crossfade 0 + CCT + G/M, and colour as crossfade 255 + RGB.
  - Intermediate crossfade values blend the two; this gives smooth white↔colour fades.
- **Patch validation:**
  - Reject footprints over 512 or overlapping addresses unless the user chooses mirroring.
  - Warn that a PT2c can't do 16 px, nor a PT1c 8/16 px.
  - Warn that an INFINIBAR PB3 has no 16 px mode.
- **Electro Storm:** footprint depends on the two "DMX Profile Extension" toggles, so Prism must ask about them.

---

## 15. Gaps and open questions

1. **Which PT LE mode the user actually runs.** Confirm in Lightkey (mode name / footprint) or on the tube.
2. **PT physical pixel order** (which end is LE 1) is undocumented. Test with LE 1 = red.
3. **PT on-screen labels for profiles 7–14** are unknown; choose by number. The white point of PT HSI modes at saturation 0 is undocumented.
4. **Profile selection on the light itself** is undocumented for T2c/T4c and F21/F22. Only the address step appears in the help and manuals.
5. **Nova P300c exact DMX button path** is undocumented; the help only says "Rotate the wheel to select the DMX Profile".
6. **Lightkey's library has errors:**
   - INFINIBAR "18 Pixels" really means 16.
   - MT Pro has an unofficial 2-px mode.
   - Nova P600c has a duplicated Source mode and is missing LE HSI.
   - Lightkey's PT profile ignores tube length.
7. **Conflicting mode numbering** for T2c/T4c (PDF vs grandMA vs Lightkey) and per-bar INFINIBAR numbering.
8. **Not captured: QLC+ has no Aputure fixtures.** GDTF Share files were not downloaded (the account wall). Sidus Link Bridge / Sidus One are not DMX targets for Prism.
9. **Image-only PDFs I did not transcribe:** amaran 150c, 200x S, 200d S, 60d S, F22x manuals; Verge; LS C300d II manual. None of these documents carry DMX tables for the lights in this report, because those lights have no DMX (except the F22x, whose spec PDF is covered in §6, and the LS C300d II, covered from OFL in §8.6).
10. **Doc typos to code around:**
    - INFINIBAR LE RGB 16 px is printed as 72 (correct: 64).
    - "80–79" in the Ultimate modes means 80–89.
    - STORM 1000c prose cites wrong channels.
    - LS 300x CCT chart overlaps.
    - XT26 FX 16-bit count differs between the table of contents and the body.

---

## 16. Source index

**Official Aputure DMX specs:**
- Base: https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/
- Paths under it:
  - `Infinibar/All%20Files/INFINIBAR%20DMX%20Profile%20Specification%20V2.0.pdf`
  - `MT%20Pro/All%20Files/MT-Pro-DMX-Profile-Specification-V1.2.pdf`
  - `NovaP300c-P600c/All%20Files/Nova-P300c-DMX-Profile-Specification-V1.1.pdf`
  - `NovaP300c-P600c/P600c%20All%20Files/Nova-P600c-DMX-Profile-Specification-V1.1.1.pdf`
  - `LS%20600c%20Pro%20II/Documents/LS600c%20Pro%20%26%20LS600c%20Pro%20II%20DMX%20Profile%20Specification%20V1.6.pdf`
  - `LS%20600x%20Pro/All%20Files/LS600X-Pro-DMX-Profile-Specification-V1.0-.pdf`
  - `LS%20600d%20Pro/All%20Files/LS-600d-Pro-DMX-Profile-Specification-V1.0-.pdf`
  - `LS%20300d%20II/All%20files/LS-600d-Pro-LS-300d-II-common-DMX-Profile-Specification-V1.0.pdf`
  - `LS%20600d/All%20files/LS-600d-DMX-Profile-Specification-V1.0-.pdf`
  - `LS%201200d%20Pro/All%20Files/LS1200D-Pro-DMX-Profile-Specification-V1.0-.pdf`
  - `STORM%2080c/manuals/STORM%201000c%20%26%2080c%20DMX%20Profile%20Specification%20V1.3.pdf`
  - `STORM%201200x/documents/STORM%201200x%20DMX%20Profile%20Specification%20V1.5.pdf`
  - `Electro%20Storm%20XT26/Electro%20Storm%20XT26%20DMX%20Profile%20Specification%20V1.1.pdf`
  - `Electro%20Storm%20CS15/Electro%20Storm%20CS15%20DMX%20Profile%20Specification%20V1.1.pdf`
  - `LS%20300x/All%20files/LS_300x-Product_Manual_EN.pdf` (manual containing the DMX chart)

**Official amaran DMX specs:**
- Base: https://cdn.shopify.com/s/files/1/0862/5432/1947/files/
- Files under it:
  - `amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf?v=1714345028`
  - `amaran-PT-Product-Manual-V1.2-0207.pdf`
  - `T2C-T4C-DMX-Profile-Specification-V1.1.pdf?v=1739938087`
  - `T2C-Manual-EN_220316.pdf`
  - `F21C-F22C-DMX-Profile-Specification-V1.0.pdf?v=1714261743`
  - `F21X-F22X-Pro-DMX-Profile-Specification-V1.0.pdf`
  - `amaran_DMX_V1.2_EN.pdf?v=1793844618`
  - `amaranHalo_DMXProfile_CN_V1.1_260303.pdf?v=1772650840`
  - `amaranRay360c660c_DMXProfile_CN_V1.0.pdf?v=1764889016`

**Help centre:**
- https://help.aputure.com/en/amaran-pixel-tubes/dmx-profile-settings
- https://help.aputure.com/en/infinibar/dmx-profiles-settings
- https://help.aputure.com/en/mt-pro/dmx-profiles-settings
- https://help.aputure.com/en/amaran-tube/menu-options
- https://help.aputure.com/en/amaran-flexible-lights/dmx-profiles-and-settings
- https://help.aputure.com/en/nova-p600c-p300c/wired-dmx-controlsettings
- https://help.aputure.com/en/ls600c-pro/lighting-configuration-settings
- https://help.aputure.com/en/ls-600c-pro-ii/lighting-configuration-settings
- https://help.aputure.com/en/which-amaran-lights-can-i-control-with-dmx-which-adapters-are-needed-for-each-fixture
- https://help.aputure.com/en/lighting-console-profiles-download
- https://help.amarancreators.com/en/amaran-halo-60x-100x/operation-and-controls

**Console and fixture libraries:**
- grandMA pack: https://help.aputure.com/hubfs/Knowledge%20Base/company%20files/grandMA%20Files/Aputure%20Fixture%20Profiles%20for%20grandMA-%205-24-224.zip
- Lightkey: https://lightkeyapp.com/en/fixtures/download?m=Aputure&f=Amaran%20PT (likewise `Infinibar`, `MT%20Pro`, `T2C%20%26%20T4C`, `F21C%20%26%20F22C`, `Nova%20P300c%20(Firmware%20v1.8)`, `Nova%20P600c`)
- OFL: https://raw.githubusercontent.com/OpenLightingProject/open-fixture-library/master/fixtures/aputure/ (nova-p300c, ls-600x-pro, ls-600d-pro, ls-c300d-ii, ls-300x, …)
