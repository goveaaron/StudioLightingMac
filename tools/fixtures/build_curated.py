#!/usr/bin/env python3
"""
build_curated.py — Generates Prism's curated fixture packs:
  1. Resources/FixtureLibrary/curated/amaran.json
  2. Resources/FixtureLibrary/curated/aputure.json
  3. Resources/FixtureLibrary/curated/film_tv.json
  4. Resources/FixtureLibrary/generic/generic.json

All channel layouts, CCT ranges, G/M neutral defaults, crossfades, strobe ranges,
and setup guides follow official manufacturer DMX specifications (see
docs/research/aputure_profiles.md and docs/FIXTURE_SCHEMA.md).
"""

import json
import os
import re

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LIB_ROOT = os.path.join(REPO_ROOT, "Resources", "FixtureLibrary")

# ---------------------------------------------------------------------------
# Standard Emitters (CIE 1931 xy + relative lumens)
# ---------------------------------------------------------------------------

RGBWW_EMITTERS = {
    "red":       {"x": 0.692, "y": 0.306, "lumens": 0.25, "wavelength": 625},
    "green":     {"x": 0.168, "y": 0.718, "lumens": 0.65, "wavelength": 525},
    "blue":      {"x": 0.138, "y": 0.046, "lumens": 0.10, "wavelength": 460},
    "warmWhite": {"x": 0.459, "y": 0.411, "lumens": 0.90, "cct": 2700},
    "coolWhite": {"x": 0.312, "y": 0.329, "lumens": 1.00, "cct": 6500},
}

BLAIR_EMITTERS = {
    "red":    {"x": 0.695, "y": 0.304, "lumens": 0.28, "wavelength": 630},
    "green":  {"x": 0.165, "y": 0.720, "lumens": 0.65, "wavelength": 525},
    "blue":   {"x": 0.142, "y": 0.042, "lumens": 0.10, "wavelength": 455},
    "amber":  {"x": 0.585, "y": 0.412, "lumens": 0.58, "wavelength": 592},
    "cyan":   {"x": 0.082, "y": 0.485, "lumens": 0.48, "wavelength": 500},
    "lime":   {"x": 0.382, "y": 0.558, "lumens": 1.15, "wavelength": 555},
    "indigo": {"x": 0.155, "y": 0.025, "lumens": 0.06, "wavelength": 440},
}

# ---------------------------------------------------------------------------
# Channel Helpers (Aputure / amaran Gen-1 & OS-II & Industry Conventions)
# ---------------------------------------------------------------------------


def ch_int(label="Intensity", fine=False):
    d = {"kind": "intensity", "label": label}
    if fine:
        d["fine"] = True
    return d


def ch_cct(lo, hi, label="CCT", fine=False, default=0):
    d = {"kind": "cct", "label": label}
    if fine:
        d["fine"] = True
    else:
        d["physical"] = [lo, hi]
        if default:
            d["default"] = default
    return d


def ch_gm_gen1(label="G/M Tint", fine=False):
    """Aputure/amaran Gen-1 G/M channel: neutral at 128 (range 120-145 & 0-10)."""
    if fine:
        return {"kind": "tint", "label": label, "fine": True}
    return {
        "kind": "tint",
        "label": label,
        "default": 128,
        "physical": [-1, 1],
        "capabilities": [
            {"range": [0, 10], "label": "Neutral", "tag": "neutral", "physical": [0]},
            {"range": [11, 20], "label": "Full Minus Green", "tag": "tint", "physical": [-1]},
            {"range": [21, 119], "label": "Minus Green (-99% to -1%)", "tag": "tint", "physical": [-0.99, -0.01]},
            {"range": [120, 145], "label": "Neutral", "tag": "neutral", "physical": [0]},
            {"range": [146, 244], "label": "Plus Green (+1% to +99%)", "tag": "tint", "physical": [0.01, 0.99]},
            {"range": [245, 255], "label": "Full Plus Green", "tag": "tint", "physical": [1]},
        ],
    }


def ch_gm_os2(default=133, label="±Green", fine=False):
    """Aputure OS-II ±Green channel (STORM / Ray)."""
    if fine:
        return {"kind": "tint", "label": label, "fine": True}
    return {
        "kind": "tint",
        "label": label,
        "default": default,
        "physical": [-1, 1],
        "capabilities": [
            {"range": [0, 10], "label": "No Effect", "tag": "neutral", "physical": [0]},
            {"range": [11, 20], "label": "Full Minus Green", "tag": "tint", "physical": [-1]},
            {"range": [21, 118], "label": "Minus Green", "tag": "tint", "physical": [-0.99, -0.01]},
            {"range": [119, 146], "label": "Neutral", "tag": "neutral", "physical": [0]},
            {"range": [147, 244], "label": "Plus Green", "tag": "tint", "physical": [0.01, 0.99]},
            {"range": [245, 255], "label": "Full Plus Green", "tag": "tint", "physical": [1]},
        ],
    }


def ch_gm_linear(default=128, label="G/M Tint", fine=False):
    if fine:
        return {"kind": "tint", "label": label, "fine": True}
    return {"kind": "tint", "label": label, "default": default, "physical": [-1, 1]}


def ch_xfade(label="CCT ↔ RGB", fine=False):
    if fine:
        return {"kind": "crossfade", "label": label, "fine": True}
    return {"kind": "crossfade", "label": label, "default": 0, "physical": [0, 1]}


def ch_rgb(fine_pairs=False):
    if fine_pairs:
        return [
            {"kind": "red", "label": "Red"},
            {"kind": "red", "label": "Red", "fine": True},
            {"kind": "green", "label": "Green"},
            {"kind": "green", "label": "Green", "fine": True},
            {"kind": "blue", "label": "Blue"},
            {"kind": "blue", "label": "Blue", "fine": True},
        ]
    return [
        {"kind": "red", "label": "Red"},
        {"kind": "green", "label": "Green"},
        {"kind": "blue", "label": "Blue"},
    ]


def ch_hue(label="Hue", fine=False):
    if fine:
        return {"kind": "hue", "label": label, "fine": True}
    return {"kind": "hue", "label": label, "physical": [0, 360]}


def ch_sat(label="Saturation", fine=False):
    if fine:
        return {"kind": "saturation", "label": label, "fine": True}
    return {"kind": "saturation", "label": label, "physical": [0, 1]}


def ch_hsi_base_cct(lo, hi, label="HSI Base CCT", fine=False):
    if fine:
        return {"kind": "cct", "label": label, "fine": True}
    return {
        "kind": "cct",
        "label": label,
        "default": 0,
        "physical": {"from": lo, "to": hi, "dmx": [11, 255], "unit": "K"},
        "capabilities": [
            {"range": [0, 10], "label": "6500 K Default", "tag": "default", "physical": [6500]},
            {"range": [11, 255], "label": f"{lo}–{hi} K", "tag": "cct", "physical": [lo, hi]},
        ],
    }


def ch_xy(fine_pairs=False):
    x = {"kind": "cieX", "label": "CIE x", "physical": [0, 0.8]}
    y = {"kind": "cieY", "label": "CIE y", "physical": [0, 0.8]}
    if fine_pairs:
        return [x, {"kind": "cieX", "label": "CIE x", "fine": True}, y, {"kind": "cieY", "label": "CIE y", "fine": True}]
    return [x, y]


def ch_strobe_gen1(label="Strobe"):
    """Gen-1 strobe: 0-19 Off, 20-255 1-25 Hz."""
    return {
        "kind": "strobe",
        "label": label,
        "default": 0,
        "capabilities": [
            {"range": [0, 19], "label": "No Effect (Off)", "tag": "off", "physical": [0]},
            {"range": [20, 255], "label": "Strobe 1–25 Hz", "tag": "strobe", "physical": [1, 25]},
        ],
    }


def ch_strobe_os2(label="Strobe"):
    """OS-II strobe: 0-13 Off, 14-128 Random 1-25 Hz, 129-255 Constant 1-25 Hz."""
    return {
        "kind": "strobe",
        "label": label,
        "default": 0,
        "capabilities": [
            {"range": [0, 13], "label": "Off", "tag": "off", "physical": [0]},
            {"range": [14, 128], "label": "Random Strobe 1–25 Hz", "tag": "random", "physical": [1, 25]},
            {"range": [129, 255], "label": "Strobe 1–25 Hz", "tag": "strobe", "physical": [1, 25]},
        ],
    }


def ch_reserved(label="Reserved"):
    return {"kind": "nothing", "label": label, "default": 0, "advanced": True}


def ch_fx_select(label="FX Selection", default=0, caps=None):
    d = {"kind": "effect", "label": label, "default": default, "advanced": True}
    if caps:
        d["capabilities"] = caps
    return d


def ch_fx_param(label="FX Parameter", default=0):
    return {"kind": "effectParameter", "label": label, "default": default, "advanced": True}


def ch_fx_speed(label="FX Frequency", default=0):
    return {"kind": "effectSpeed", "label": label, "default": default, "advanced": True}


def ch_fan(label="Fan Control", default=0):
    return {
        "kind": "fan",
        "label": label,
        "default": default,
        "advanced": True,
        "capabilities": [
            {"range": [0, 63], "label": "Smart / Auto", "tag": "default"},
            {"range": [64, 127], "label": "High", "tag": "fan"},
            {"range": [128, 191], "label": "Medium / Delayed", "tag": "fan"},
            {"range": [192, 255], "label": "Silent", "tag": "fan"},
        ],
    }


def ch_control(label="Control", default=0):
    return {
        "kind": "control",
        "label": label,
        "default": default,
        "advanced": True,
        "capabilities": [
            {"range": [0, 10], "label": "No Function", "tag": "off"},
            {"range": [11, 255], "label": "Control Command (hold 2.5s)", "tag": "control"},
        ],
    }


def expand_16bit(channels_8bit):
    """Expands an 8-bit channel list into 16-bit coarse+fine pairs (keeping strobe/control/effect 8-bit)."""
    out = []
    for ch in channels_8bit:
        out.append(ch)
        if ch["kind"] in ("intensity", "cct", "tint", "crossfade", "red", "green", "blue", "white",
                          "warmWhite", "coolWhite", "amber", "lime", "cyan", "magenta", "yellow",
                          "uv", "indigo", "hue", "saturation", "cieX", "cieY"):
            fine_ch = {"kind": ch["kind"], "label": ch.get("label", ch["kind"]), "fine": True}
            if "cell" in ch:
                fine_ch["cell"] = ch["cell"]
            out.append(fine_ch)
    return out


# ---------------------------------------------------------------------------
# 1. Curated amaran Pack (PT1c, PT2c, PT4c, T2c, T4c, F21c, F22c, F21x, F22x, Ray, Halo)
# ---------------------------------------------------------------------------


def build_amaran_pt(model, length_mm, weight_kg, power_w, max_pixels, aliases):
    cct_lo, cct_hi = 2700, 10000
    pt_fx_caps = [
        {"range": [0, 9], "label": "Paparazzi", "tag": "effect"},
        {"range": [10, 19], "label": "Lightning", "tag": "effect"},
        {"range": [20, 29], "label": "TV", "tag": "effect"},
        {"range": [30, 39], "label": "Fire", "tag": "effect"},
        {"range": [40, 49], "label": "Faulty Bulb", "tag": "effect"},
        {"range": [50, 59], "label": "Pulsing", "tag": "effect"},
        {"range": [60, 69], "label": "Cop Car", "tag": "effect"},
        {"range": [70, 79], "label": "Party Lights", "tag": "effect"},
        {"range": [80, 89], "label": "Fireworks", "tag": "effect"},
        {"range": [90, 255], "label": "Reserved (Off)", "tag": "off"},
    ]

    modes = [
        {
            "name": "CCT & RGB",
            "shortName": "10ch",
            "friendlyName": "Full color + white balance · 1 zone",
            "fixtureMenuName": "1: CCT&RGB 8-bit",
            "summary": "Whole tube with white balance (2700–10000 K), G/M tint, RGB color and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_xfade("CCT ↔ RGB"),
                *ch_rgb(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "CCT",
            "shortName": "6ch",
            "friendlyName": "White balance only · 1 zone",
            "fixtureMenuName": "2: CCT 8-bit",
            "summary": "Whole tube with Kelvin white balance, G/M tint and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "CCT & HSI",
            "shortName": "9ch",
            "friendlyName": "HSI color + white balance · 1 zone",
            "fixtureMenuName": "3: CCT&HSI 8-bit",
            "summary": "Whole tube with Kelvin white balance, G/M tint, HSI color and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_xfade("CCT ↔ HSI"),
                ch_hue(),
                ch_sat(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "RGB",
            "shortName": "7ch",
            "friendlyName": "RGB color · 1 zone",
            "fixtureMenuName": "4: RGB 8-bit",
            "summary": "Whole tube with dimmer, RGB color and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                *ch_rgb(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "HSI",
            "shortName": "6ch",
            "friendlyName": "HSI color · 1 zone",
            "fixtureMenuName": "5: HSI 8-bit",
            "summary": "Whole tube with dimmer, hue, saturation and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_hue(),
                ch_sat(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "System FX",
            "shortName": "7ch FX",
            "friendlyName": "Built-in effects · 1 zone",
            "fixtureMenuName": "6: System FX",
            "summary": "On-board Sidus effects (Paparazzi, Lightning, TV, Fire, Cop Car, Fireworks)",
            "recommended": False,
            "channels": [
                ch_int(),
                {
                    "kind": "control",
                    "label": "Loop / Trigger / Stop",
                    "default": 70,
                    "advanced": True,
                    "capabilities": [
                        {"range": [0, 9], "label": "Loop", "tag": "effect"},
                        {"range": [10, 69], "label": "Trigger / Loop", "tag": "effect"},
                        {"range": [70, 255], "label": "Stop", "tag": "off"},
                    ],
                },
                ch_fx_select("FX Selection", default=90, caps=pt_fx_caps),
                ch_fx_param("FX Param 1"),
                ch_fx_param("FX Param 2"),
                ch_fx_speed("FX Frequency"),
                ch_fx_param("FX Param 4"),
            ],
        },
    ]

    # Mode 7..10: Light Engine CCT & RGB 2 / 4 / 8 / 16 Pixels (7 ch per pixel)
    le_cct_rgb_template = [
        ch_int(),
        ch_cct(cct_lo, cct_hi),
        ch_gm_gen1(),
        ch_xfade("CCT ↔ RGB"),
        *ch_rgb(),
    ]
    px_counts = [p for p in (2, 4, 8, 16) if p <= max_pixels]
    rec_px = 8 if 8 in px_counts else max(px_counts)

    mode_num_cct_rgb = {2: 7, 4: 8, 8: 9, 16: 10}
    for px in px_counts:
        mnum = mode_num_cct_rgb[px]
        is_rec = px == rec_px
        modes.append({
            "name": f"Light Engine CCT & RGB {px} Pixels",
            "shortName": f"LE CCT&RGB {px} px",
            "friendlyName": f"Full color · {px} zones" + (" (recommended)" if is_rec else ""),
            "fixtureMenuName": f"{mnum}: LE CCT&RGB {px}PX",
            "summary": f"{px} independent zones, each with dimmer, 2700–10000 K white balance, G/M tint and RGB ({px * 7} ch)",
            "recommended": is_rec,
            "pixels": {
                "count": px,
                "channels": le_cct_rgb_template,
            },
        })

    # Mode 11..14: Light Engine HSI 2 / 4 / 8 / 16 Pixels (3 ch per pixel)
    le_hsi_template = [ch_int(), ch_hue(), ch_sat()]
    mode_num_hsi = {2: 11, 4: 12, 8: 13, 16: 14}
    for px in px_counts:
        mnum = mode_num_hsi[px]
        modes.append({
            "name": f"Light Engine HSI {px} Pixels",
            "shortName": f"LE HSI {px} px",
            "friendlyName": f"HSI color · {px} zones",
            "fixtureMenuName": f"{mnum}: LE HSI {px}PX",
            "summary": f"{px} independent zones with dimmer, hue and saturation ({px * 3} ch)",
            "recommended": False,
            "pixels": {
                "count": px,
                "channels": le_hsi_template,
            },
        })

    return {
        "id": f"amaran.{model.lower()}",
        "manufacturer": "amaran",
        "model": model,
        "category": "tube",
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "diameterMM": 42, "weightKG": weight_kg, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {
            "kind": "curated",
            "url": "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf",
            "license": "Proprietary-Facts",
        },
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profiles"],
            "factoryDefaults": {
                "address": 1,
                "mode": "CCT & RGB",
                "signalLossBehavior": "Hold Last Setting",
            },
            "connector": "USB-C → amaran Type-C to DMX Adapter with Type-C Input (sold separately)",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black (60s) / Hold 2 min & Fade",
            "notes": [
                "Press and hold OK for 2 seconds on the DMX Address screen to lock or unlock the address.",
                "Leave the DMX Address screen visible — wired DMX only controls the tube while the DMX Address screen is showing.",
                "Profile 9 is Light Engine CCT & RGB 8 Pixels (56 ch, fits 8 tubes + panel in one universe).",
            ],
            "manualURL": "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-Product-Manual-V1.2-0207.pdf",
        },
        "addressHelp": "Press MENU → DMX Settings → DMX Address (hold OK 2s to lock). Leave DMX Address screen visible.",
        "links": [
            "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran-PT-DMX-Profile-Specification-V1.0_fc68031c-c061-43a9-930c-a9e77ffc0fe1.pdf",
            "https://help.aputure.com/en/amaran-pixel-tubes/dmx-profile-settings",
        ],
        "revision": 1,
        "modes": modes,
    }


def build_amaran_t_or_f_color(model, category, length_mm, width_mm, weight_kg, power_w, aliases, spec_url, help_url, menu_note):
    cct_lo, cct_hi = 2500, 7500
    modes = [
        {
            "name": "CCT & RGB 8-bit",
            "shortName": "10ch",
            "friendlyName": "Full color + white balance (recommended)",
            "fixtureMenuName": "CCT & RGB 8-bit",
            "summary": "Dimmer, 2500–7500 K white balance, G/M tint, RGB color and strobe",
            "recommended": True,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_xfade("CCT ↔ RGB"),
                *ch_rgb(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "CCT 8-bit",
            "shortName": "6ch",
            "friendlyName": "White balance only",
            "fixtureMenuName": "CCT 8-bit",
            "summary": "Dimmer, 2500–7500 K white balance, G/M tint and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "CCT & HSI 8-bit",
            "shortName": "9ch",
            "friendlyName": "HSI color + white balance",
            "fixtureMenuName": "CCT & HSI 8-bit",
            "summary": "Dimmer, 2500–7500 K white balance, G/M tint, HSI color and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_xfade("CCT ↔ HSI"),
                ch_hue(),
                ch_sat(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "RGB 8-bit",
            "shortName": "7ch",
            "friendlyName": "RGB color",
            "fixtureMenuName": "RGB 8-bit",
            "summary": "Dimmer, RGB color and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                *ch_rgb(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "HSI 8-bit",
            "shortName": "6ch HSI",
            "friendlyName": "HSI color",
            "fixtureMenuName": "HSI 8-bit",
            "summary": "Dimmer, hue, saturation and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                ch_hue(),
                ch_sat(),
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "GEL 8-bit",
            "shortName": "8ch GEL",
            "friendlyName": "Digital gels (Rosco / LEE)",
            "fixtureMenuName": "GEL 8-bit",
            "summary": "Dimmer, base CCT (3200K/5600K), Rosco/LEE gel selection and strobe",
            "recommended": False,
            "channels": [
                ch_int(),
                {
                    "kind": "cct",
                    "label": "Base CCT",
                    "capabilities": [
                        {"range": [0, 126], "label": "3200 K", "tag": "cct", "physical": [3200]},
                        {"range": [127, 255], "label": "5600 K", "tag": "cct", "physical": [5600]},
                    ],
                },
                {"kind": "gel", "label": "Gel Brand (Rosco/LEE)", "advanced": True},
                {"kind": "gel", "label": "Gel Series", "advanced": True},
                {"kind": "gel", "label": "Gel Category", "advanced": True},
                ch_reserved("Reserved 1"),
                ch_reserved("Reserved 2"),
                ch_strobe_gen1(),
            ],
        },
        {
            "name": "FX 8-bit",
            "shortName": "9ch FX",
            "friendlyName": "Built-in effects",
            "fixtureMenuName": "FX 8-bit",
            "summary": "On-board Sidus effects",
            "recommended": False,
            "channels": [
                ch_int(),
                {"kind": "control", "label": "Loop / Trigger / Stop", "default": 70, "advanced": True},
                ch_fx_select("FX Selection", default=90),
                ch_fx_param("FX Param 1"),
                ch_fx_param("FX Param 2"),
                ch_fx_speed("FX Frequency"),
                ch_fx_param("FX Param 4"),
                ch_fx_param("FX Param 5"),
                ch_fx_param("FX Param 6"),
            ],
        },
    ]
    return {
        "id": f"amaran.{model.lower()}",
        "manufacturer": "amaran",
        "model": model,
        "category": category,
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": width_mm, "heightMM": width_mm if category == "panel" else 42, "weightKG": weight_kg, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profiles"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit", "signalLossBehavior": "Hold Last Setting"},
            "connector": "USB-C → amaran Type-C to DMX Adapter with Type-C Input",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting",
            "notes": [menu_note, "Keep the DMX Address screen displayed while controlling via wired DMX."],
            "manualURL": spec_url,
        },
        "links": [spec_url, help_url],
        "revision": 1,
        "modes": modes,
    }


def build_amaran_f_bicolor(model, length_mm, width_mm, weight_kg, power_w, aliases):
    cct_lo, cct_hi = 2500, 7500
    spec_url = "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/F21X-F22X-Pro-DMX-Profile-Specification-V1.0.pdf"
    return {
        "id": f"amaran.{model.lower()}",
        "manufacturer": "amaran",
        "model": model,
        "category": "panel",
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": width_mm, "heightMM": width_mm, "weightKG": weight_kg, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profiles"],
            "factoryDefaults": {"address": 1, "mode": "CCT 8-bit"},
            "connector": "USB-C → amaran Type-C to DMX Adapter with Type-C Input",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting",
            "notes": [
                "Press MENU, rotate and press the INT knob to open DMX Settings.",
                "Hold the INT knob to lock/unlock the DMX Address screen.",
            ],
            "manualURL": spec_url,
        },
        "links": [spec_url],
        "revision": 1,
        "modes": [
            {
                "name": "CCT 8-bit",
                "shortName": "2ch",
                "friendlyName": "White balance (recommended)",
                "fixtureMenuName": "1: CCT 8-bit",
                "summary": "Dimmer + 2500–7500 K white balance",
                "recommended": True,
                "channels": [ch_int(), ch_cct(cct_lo, cct_hi)],
            },
            {
                "name": "FX 8-bit",
                "shortName": "5ch FX",
                "friendlyName": "White balance + built-in effects",
                "fixtureMenuName": "2: FX 8-bit",
                "summary": "Dimmer, CCT and on-board lighting effects",
                "recommended": False,
                "channels": [
                    ch_int(),
                    ch_cct(cct_lo, cct_hi),
                    {"kind": "control", "label": "FX Trigger", "default": 70, "advanced": True},
                    ch_fx_select("FX Selection", default=180),
                    ch_fx_speed("FX Frequency"),
                ],
            },
        ],
    }


def build_amaran_ray_or_halo(model, is_ray, power_w, aliases):
    spec_url = "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/amaran_DMX_V1.2_EN.pdf"
    cct_ext_ch = {
        "kind": "control",
        "label": "CCT Extension",
        "default": 0,
        "advanced": True,
        "capabilities": [
            {"range": [0, 127], "label": "Standard CCT (2300–10000 K)", "tag": "default"},
            {"range": [128, 255], "label": "Extended CCT (1800–20000 K)", "tag": "cct"},
        ],
    }
    modes = [
        {
            "name": "CCT Universal",
            "shortName": "3ch",
            "friendlyName": "Bi-color white + strobe" + ("" if is_ray else " (recommended)"),
            "fixtureMenuName": "P1: CCT Universal",
            "summary": "Dimmer, 2700–6500 K white balance and strobe",
            "recommended": not is_ray,
            "channels": [ch_int(), ch_cct(2700, 6500), ch_strobe_os2()],
        }
    ]
    if is_ray:
        modes.extend([
            {
                "name": "CCT",
                "shortName": "5ch CCT",
                "friendlyName": "Wide white balance + G/M tint",
                "fixtureMenuName": "P2: CCT",
                "summary": "Dimmer, 2300–10000 K white balance, ±Green tint, strobe and CCT extension",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2300, 10000), ch_gm_os2(133), ch_strobe_os2(), cct_ext_ch],
            },
            {
                "name": "RGB",
                "shortName": "5ch RGB",
                "friendlyName": "RGB color",
                "fixtureMenuName": "P3: RGB",
                "summary": "Dimmer, RGB color and strobe",
                "recommended": False,
                "channels": [ch_int(), *ch_rgb(), ch_strobe_os2()],
            },
            {
                "name": "CCT & RGB",
                "shortName": "9ch",
                "friendlyName": "Full color + white balance (recommended)",
                "fixtureMenuName": "P4: CCT & RGB",
                "summary": "Dimmer, 2300–10000 K white balance, ±Green tint, crossfade, RGB and strobe",
                "recommended": True,
                "channels": [
                    ch_int(),
                    ch_cct(2300, 10000),
                    ch_gm_os2(133),
                    ch_xfade("White Light to RGB"),
                    *ch_rgb(),
                    ch_strobe_os2(),
                    cct_ext_ch,
                ],
            },
            {
                "name": "HSI",
                "shortName": "4ch HSI",
                "friendlyName": "HSI color",
                "fixtureMenuName": "P5: HSI",
                "summary": "Dimmer, hue, saturation and strobe",
                "recommended": False,
                "channels": [ch_int(), ch_hue(), ch_sat(), ch_strobe_os2()],
            },
            {
                "name": "HSIC+",
                "shortName": "7ch HSIC+",
                "friendlyName": "HSI color + white balance & tint",
                "fixtureMenuName": "P6: HSIC+",
                "summary": "Dimmer, CCT, ±Green, hue, saturation, strobe and CCT extension",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2300, 10000), ch_gm_os2(133), ch_hue(), ch_sat(), ch_strobe_os2(), cct_ext_ch],
            },
        ])
        # Control + Fan variants (P7-P12)
        base_snapshot = list(modes)
        for idx, bm in enumerate(base_snapshot, start=7):
            modes.append({
                "name": f"{bm['name']} & Control",
                "shortName": f"P{idx}",
                "friendlyName": f"{bm['friendlyName'].replace(' (recommended)', '')} + Fan/Control",
                "fixtureMenuName": f"P{idx}: {bm['name']} + Ctrl",
                "summary": f"{bm['summary']} plus Control and Fan channels",
                "recommended": False,
                "channels": list(bm["channels"]) + [ch_control(), ch_fan()],
            })
    else:
        modes.append({
            "name": "CCT Universal & Control",
            "shortName": "5ch Ctrl",
            "friendlyName": "Bi-color white + Fan/Control",
            "fixtureMenuName": "P7: CCT Universal + Ctrl",
            "summary": "Dimmer, 2700–6500 K white balance, strobe, Control and Fan",
            "recommended": False,
            "channels": [ch_int(), ch_cct(2700, 6500), ch_strobe_os2(), ch_control(), ch_fan()],
        })

    return {
        "id": f"amaran.{model.lower().replace(' ', '-')}",
        "manufacturer": "amaran",
        "model": model,
        "category": "spot",
        "aliases": aliases,
        "physical": {"diameterMM": 200, "powerW": power_w},
        "cctRange": [2300, 10000] if is_ray else [2700, 6500],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS if is_ray else None,
        "setupGuide": {
            "addressMenuPath": ["Main Menu (press CCT knob)", "DMX", "DMX Address"],
            "modeMenuPath": ["Main Menu (press CCT knob)", "DMX", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB" if is_ray else "CCT Universal", "signalLossBehavior": "Hold Last State"},
            "connector": "Locking amaran USB-C to 5-Pin DMX In & Out Adapter",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last State / Instant Off / Fade Out / Hold 2 min then Fade Out",
            "notes": ["Uses the locking amaran USB-C to 5-Pin DMX In & Out Adapter."],
            "manualURL": spec_url,
        },
        "links": [spec_url, "https://help.amarancreators.com/en/amaran-halo-60x-100x/operation-and-controls"],
        "revision": 1,
        "modes": modes,
    }


def build_all_amaran():
    t_url = "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/T2C-T4C-DMX-Profile-Specification-V1.1.pdf"
    f_url = "https://cdn.shopify.com/s/files/1/0862/5432/1947/files/F21C-F22C-DMX-Profile-Specification-V1.0.pdf"
    return [
        build_amaran_pt("PT1c", 300, 0.351, 20, 4, ["PT1c", "Pixel Tube 1c", "amaran PT1c", "Amaran PT 1c"]),
        build_amaran_pt("PT2c", 600, 0.705, 40, 8, ["PT2c", "Pixel Tube 2c", "amaran PT2c", "Amaran PT 2c"]),
        build_amaran_pt("PT4c", 1200, 1.375, 70, 16, ["PT4c", "Pixel Tube 4c", "amaran PT4c", "Amaran PT", "Amaran PT 4c", "pt 4"]),
        build_amaran_t_or_f_color("T2c", "tube", 600, 42, 0.5, 25, ["T2c", "amaran T2c", "T2C & T4C"], t_url,
                                  "https://help.aputure.com/en/amaran-tube/menu-options",
                                  "Press the control knob → DMX Mode, then rotate to set the DMX address (001–512)."),
        build_amaran_t_or_f_color("T4c", "tube", 1200, 42, 0.95, 50, ["T4c", "amaran T4c", "T2C & T4C"], t_url,
                                  "https://help.aputure.com/en/amaran-tube/menu-options",
                                  "Press the control knob → DMX Mode, then rotate to set the DMX address (001–512)."),
        build_amaran_t_or_f_color("F21c", "panel", 600, 300, 0.44, 120, ["F21c", "amaran F21c", "F21C & F22C", "2x1 flex mat"], f_url,
                                  "https://help.aputure.com/en/amaran-flexible-lights/dmx-profiles-and-settings",
                                  "Press MENU, rotate and press the INT knob to open DMX Settings. Hold INT knob to lock address."),
        build_amaran_t_or_f_color("F22c", "panel", 600, 600, 0.88, 240, ["F22c", "amaran F22c", "F21C & F22C", "2x2 flex mat", "square panel"], f_url,
                                  "https://help.aputure.com/en/amaran-flexible-lights/dmx-profiles-and-settings",
                                  "Press MENU, rotate and press the INT knob to open DMX Settings. Hold INT knob to lock address."),
        build_amaran_f_bicolor("F21x", 600, 300, 0.39, 120, ["F21x", "amaran F21x", "F21x Pro"]),
        build_amaran_f_bicolor("F22x", 600, 600, 0.80, 240, ["F22x", "amaran F22x", "F22x Pro"]),
        build_amaran_ray_or_halo("Ray 360c", True, 360, ["Ray 360c", "amaran Ray 360c"]),
        build_amaran_ray_or_halo("Ray 660c", True, 660, ["Ray 660c", "amaran Ray 660c"]),
        build_amaran_ray_or_halo("Halo 60x", False, 60, ["Halo 60x", "amaran Halo 60x"]),
        build_amaran_ray_or_halo("Halo 100x", False, 100, ["Halo 100x", "amaran Halo 100x"]),
        build_amaran_ray_or_halo("Halo 200x", False, 200, ["Halo 200x", "amaran Halo 200x"]),
        build_amaran_ray_or_halo("Halo 300x", False, 300, ["Halo 300x", "amaran Halo 300x"]),
        build_amaran_ray_or_halo("Halo 600x", False, 600, ["Halo 600x", "amaran Halo 600x"]),
    ]


# ---------------------------------------------------------------------------
# 2. Curated Aputure Pack (INFINIBAR, MT Pro, Nova, LS series, STORM, Electro Storm)
# ---------------------------------------------------------------------------


def build_infinibar_or_mt(model, is_mt, length_mm, weight_kg, power_w, px_counts, aliases):
    cct_lo, cct_hi = 2000, 10000
    spec_url = (
        "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/MT%20Pro/All%20Files/MT-Pro-DMX-Profile-Specification-V1.2.pdf"
        if is_mt else
        "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Infinibar/All%20Files/INFINIBAR%20DMX%20Profile%20Specification%20V2.0.pdf"
    )
    modes = [
        {
            "name": "CCT & RGB",
            "shortName": "8ch",
            "friendlyName": "Full color + white balance · 1 zone",
            "fixtureMenuName": "1: CCT & RGB",
            "summary": "Whole bar with 2000–10000 K white balance, G/M tint, RGB color and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb(), ch_strobe_gen1()],
        },
        {
            "name": "CCT",
            "shortName": "4ch",
            "friendlyName": "White balance only · 1 zone",
            "fixtureMenuName": "2: CCT",
            "summary": "Whole bar with dimmer, 2000–10000 K white balance, G/M tint and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_strobe_gen1()],
        },
        {
            "name": "CCT & HSI",
            "shortName": "7ch",
            "friendlyName": "HSI color + white balance · 1 zone",
            "fixtureMenuName": "3: CCT & HSI",
            "summary": "Whole bar with white balance, G/M tint, HSI color and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ HSI"), ch_hue(), ch_sat(), ch_strobe_gen1()],
        },
        {
            "name": "RGB",
            "shortName": "5ch RGB",
            "friendlyName": "RGB color · 1 zone",
            "fixtureMenuName": "4: RGB",
            "summary": "Whole bar with dimmer, RGB color and strobe",
            "recommended": False,
            "channels": [ch_int(), *ch_rgb(), ch_strobe_gen1()],
        },
        {
            "name": "HSI",
            "shortName": "5ch HSI",
            "friendlyName": "HSI color · 1 zone",
            "fixtureMenuName": "5: HSI",
            "summary": "Whole bar with dimmer, hue, saturation, base CCT and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi), ch_strobe_gen1()],
        },
        {
            "name": "XY",
            "shortName": "4ch XY",
            "friendlyName": "CIE 1931 xy · 1 zone",
            "fixtureMenuName": "6: XY",
            "summary": "Whole bar with dimmer, CIE x/y chromaticity and strobe",
            "recommended": False,
            "channels": [ch_int(), *ch_xy(), ch_strobe_gen1()],
        },
        {
            "name": "System FX",
            "shortName": "10ch FX",
            "friendlyName": "Built-in system effects",
            "fixtureMenuName": "7: System FX",
            "summary": "On-board Sidus effects across the bar",
            "recommended": False,
            "channels": [ch_int(), ch_fx_select("FX Selection", default=90)] + [ch_fx_param(f"FX Param {i}") for i in range(1, 9)],
        },
        {
            "name": "Pixel FX",
            "shortName": "36ch Pixel FX",
            "friendlyName": "Built-in pixel chases",
            "fixtureMenuName": "8: Pixel FX",
            "summary": "On-board pixel effects (Color Fade, Color Cycle, Pixel Chase, Rainbow, Pixel Fire)",
            "recommended": False,
            "channels": [
                ch_int(),
                {"kind": "control", "label": "Play / Pause / Stop", "default": 61, "advanced": True},
                ch_fx_select("Pixel FX Selection", default=70),
            ] + [ch_fx_param(f"Pixel FX Param {i}") for i in range(1, 34)],
        },
    ]

    if not is_mt:
        modes.append({
            "name": "HSIC+",
            "shortName": "6ch HSIC+",
            "friendlyName": "HSIC+ · 1 zone",
            "fixtureMenuName": "33: HSIC+",
            "summary": "Whole bar with dimmer, CCT, ±Green, hue, saturation and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_hsi_base_cct(cct_lo, cct_hi, "CCT"), ch_gm_gen1(), ch_hue(), ch_sat(), ch_strobe_gen1()],
        })

    le_cct_rgb = [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb()]
    le_rgb = [ch_int(), *ch_rgb()]
    le_hsi = [ch_int(), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi)]
    le_hsic = [ch_int(), ch_hsi_base_cct(cct_lo, cct_hi, "CCT"), ch_gm_gen1(), ch_hue(), ch_sat()]

    rec_px = 8 if 8 in px_counts else (9 if 9 in px_counts else px_counts[0])
    for px in px_counts:
        is_rec = px == rec_px
        modes.append({
            "name": f"Light Engine CCT & RGB {px} Pixels",
            "shortName": f"LE CCT&RGB {px} px",
            "friendlyName": f"Full color · {px} zones" + (" (recommended)" if is_rec else ""),
            "fixtureMenuName": f"LE CCT&RGB {px}PX",
            "summary": f"{px} zones with dimmer, 2000–10000 K white balance, G/M tint and RGB ({px * 7} ch)",
            "recommended": is_rec,
            "pixels": {"count": px, "channels": le_cct_rgb},
        })
    for px in px_counts:
        modes.append({
            "name": f"Light Engine RGB {px} Pixels",
            "shortName": f"LE RGB {px} px",
            "friendlyName": f"RGB color · {px} zones",
            "fixtureMenuName": f"LE RGB {px}PX",
            "summary": f"{px} zones with dimmer and RGB ({px * 4} ch)",
            "recommended": False,
            "pixels": {"count": px, "channels": le_rgb},
        })
    for px in px_counts:
        modes.append({
            "name": f"Light Engine HSI {px} Pixels",
            "shortName": f"LE HSI {px} px",
            "friendlyName": f"HSI color · {px} zones",
            "fixtureMenuName": f"LE HSI {px}PX",
            "summary": f"{px} zones with dimmer, hue, saturation and base CCT ({px * 4} ch)",
            "recommended": False,
            "pixels": {"count": px, "channels": le_hsi},
        })
    if not is_mt:
        for px in px_counts:
            modes.append({
                "name": f"Light Engine HSIC+ {px} Pixels",
                "shortName": f"LE HSIC+ {px} px",
                "friendlyName": f"HSIC+ · {px} zones",
                "fixtureMenuName": f"LE HSIC+ {px}PX",
                "summary": f"{px} zones with dimmer, CCT, ±Green, hue and saturation ({px * 5} ch)",
                "recommended": False,
                "pixels": {"count": px, "channels": le_hsic},
            })

    slug = model.lower().replace(" ", "-")
    return {
        "id": f"aputure.{slug}",
        "manufacturer": "Aputure",
        "model": model,
        "category": "tube" if is_mt else "bar",
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": 45, "heightMM": 43, "weightKG": weight_kg, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Setting", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Setting", "DMX Profiles"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB", "signalLossBehavior": "Hold Last Setting"},
            "connector": "Aputure Active USB-C to 5-Pin DMX Adapter, or CRMX wireless",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black / Hold 2 min & Fade",
            "notes": [
                "Requires the Aputure Active USB-C to 5-pin DMX Adapter (amaran passive adapters are not compatible).",
                "Hold the control wheel for 2 seconds to lock or unlock the DMX address.",
            ],
            "manualURL": spec_url,
        },
        "links": [spec_url],
        "revision": 1,
        "modes": modes,
    }


def build_nova_p300c():
    cct_lo, cct_hi = 2000, 10000
    spec_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/NovaP300c-P600c/All%20Files/Nova-P300c-DMX-Profile-Specification-V1.1.pdf"
    return {
        "id": "aputure.nova-p300c",
        "manufacturer": "Aputure",
        "model": "Nova P300c",
        "category": "panel",
        "aliases": ["Nova P300c", "P300c", "Aputure Nova P300c", "Nova P300c (Firmware v1.8)"],
        "physical": {"lengthMM": 562, "widthMM": 562, "heightMM": 457, "weightKG": 10.35, "powerW": 360},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit", "signalLossBehavior": "Hold Last Setting"},
            "connector": "5-pin XLR DMX In / Out on control box",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black",
            "notes": ["Nova P300c modes have no hardware strobe channel; Prism emulates strobe via intensity when enabled."],
            "manualURL": spec_url,
        },
        "links": [spec_url, "https://help.aputure.com/en/nova-p600c-p300c/wired-dmx-controlsettings"],
        "revision": 1,
        "modes": [
            {
                "name": "CCT & RGB 8-bit",
                "shortName": "7ch",
                "friendlyName": "Full color + white balance (recommended)",
                "fixtureMenuName": "1: CCT & RGB 8-bit",
                "summary": "Dimmer, 2000–10000 K white balance, G/M tint, crossfade and RGB color",
                "recommended": True,
                "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb()],
            },
            {
                "name": "CCT 8-bit",
                "shortName": "3ch",
                "friendlyName": "White balance only",
                "fixtureMenuName": "2: CCT 8-bit",
                "summary": "Dimmer, 2000–10000 K white balance and G/M tint",
                "recommended": False,
                "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1()],
            },
            {
                "name": "CCT & HSI 8-bit",
                "shortName": "6ch",
                "friendlyName": "HSI color + white balance",
                "fixtureMenuName": "3: CCT & HSI 8-bit",
                "summary": "Dimmer, 2000–10000 K white balance, G/M tint, crossfade, hue and saturation",
                "recommended": False,
                "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ HSI"), ch_hue(), ch_sat()],
            },
            {
                "name": "GEL 8-bit",
                "shortName": "5ch GEL",
                "friendlyName": "Digital gels (LEE / Rosco)",
                "fixtureMenuName": "4: GEL 8-bit",
                "summary": "Dimmer, base CCT (3200K/5600K) and LEE/Rosco gel library",
                "recommended": False,
                "channels": [
                    ch_int(),
                    {"kind": "cct", "label": "Base CCT", "physical": [3200, 5600]},
                    {"kind": "gel", "label": "Gel Brand (LEE/Rosco)", "advanced": True},
                    {"kind": "gel", "label": "Gel Series", "advanced": True},
                    {"kind": "gel", "label": "Gel Category", "advanced": True},
                ],
            },
            {
                "name": "HSI 8-bit",
                "shortName": "3ch HSI",
                "friendlyName": "HSI color",
                "fixtureMenuName": "5: HSI 8-bit",
                "summary": "Dimmer, hue and saturation",
                "recommended": False,
                "channels": [ch_int(), ch_hue(), ch_sat()],
            },
            {
                "name": "Source 8-bit",
                "shortName": "2ch Source",
                "friendlyName": "Real light source presets",
                "fixtureMenuName": "6: Source 8-bit",
                "summary": "Dimmer and 46 real-world light source presets",
                "recommended": False,
                "channels": [ch_int(), {"kind": "colorMacro", "label": "Light Source Preset"}],
            },
            {
                "name": "RGB 8-bit",
                "shortName": "4ch RGB",
                "friendlyName": "RGB color",
                "fixtureMenuName": "7: RGB 8-bit",
                "summary": "Dimmer and RGB color",
                "recommended": False,
                "channels": [ch_int(), *ch_rgb()],
            },
            {
                "name": "XY 8-bit",
                "shortName": "3ch XY",
                "friendlyName": "CIE 1931 xy",
                "fixtureMenuName": "8: XY 8-bit",
                "summary": "Dimmer and CIE 1931 x/y coordinates",
                "recommended": False,
                "channels": [ch_int(), *ch_xy()],
            },
            {
                "name": "FX 8-bit",
                "shortName": "10ch FX",
                "friendlyName": "Built-in effects",
                "fixtureMenuName": "9: FX 8-bit",
                "summary": "FX selection on channel 1, dimmer on channel 2, and effect parameters",
                "recommended": False,
                "channels": [ch_fx_select("FX Selection", default=150), ch_int()] + [ch_fx_param(f"FX Param {i}") for i in range(1, 9)],
            },
        ],
    }


def build_nova_p600c():
    cct_lo, cct_hi = 2000, 10000
    spec_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/NovaP300c-P600c/P600c%20All%20Files/Nova-P600c-DMX-Profile-Specification-V1.1.1.pdf"
    base_8bit = [
        ("1", "CCT & RGB 8-bit", "Full color + white balance · 1 zone (recommended)", True,
         [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb(), ch_strobe_gen1()]),
        ("2", "CCT 8-bit", "White balance only · 1 zone", False,
         [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_strobe_gen1()]),
        ("3", "CCT & HSI 8-bit", "HSI color + white balance · 1 zone", False,
         [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ HSI"), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi), ch_strobe_gen1()]),
        ("4", "RGB 8-bit", "RGB color · 1 zone", False,
         [ch_int(), *ch_rgb(), ch_strobe_gen1()]),
        ("5", "HSI 8-bit", "HSI color · 1 zone", False,
         [ch_int(), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi), ch_strobe_gen1()]),
        ("6", "GEL 8-bit", "Digital gels", False,
         [ch_int(), {"kind": "cct", "label": "Base CCT", "physical": [3200, 5600]},
          {"kind": "gel", "label": "Gel Brand", "advanced": True},
          {"kind": "gel", "label": "Gel Series", "advanced": True},
          {"kind": "gel", "label": "Gel Category", "advanced": True}, ch_strobe_gen1()]),
        ("7", "XY 8-bit", "CIE 1931 xy · 1 zone", False,
         [ch_int(), *ch_xy(), ch_strobe_gen1()]),
        ("8", "Source 8-bit", "Real light source presets", False,
         [ch_int(), {"kind": "colorMacro", "label": "Source Preset"},
          {"kind": "cieX", "label": "x Adjust", "default": 128},
          {"kind": "cieY", "label": "y Adjust", "default": 128}, ch_strobe_gen1()]),
        ("9", "FX 8-bit", "Built-in effects", False,
         [ch_int(), ch_fx_select("FX Selection", default=190)] + [ch_fx_param(f"FX Param {i}") for i in range(1, 20)]),
        ("10", "WW & RGB 8-bit", "Direct emitter control (WW/CW/RGB)", False,
         [{"kind": "warmWhite", "label": "Warm White"}, {"kind": "coolWhite", "label": "Cool White"}, *ch_rgb()]),
    ]
    modes = []
    for num, name, friendly, rec, chans in base_8bit:
        modes.append({
            "name": name,
            "shortName": f"{len(chans)}ch",
            "friendlyName": friendly,
            "fixtureMenuName": f"{num}: {name}",
            "recommended": rec,
            "channels": chans,
        })
    # Modes 11-13: 4 Light Engines
    le_cct_rgb = [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb()]
    le_hsi = [ch_int(), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi)]
    le_xy = [ch_int(), *ch_xy()]
    modes.extend([
        {
            "name": "Light Engine CCT & RGB 8-bit",
            "shortName": "28ch 4px",
            "friendlyName": "Full color · 4 zones",
            "fixtureMenuName": "11: LE CCT&RGB 8-bit",
            "recommended": False,
            "pixels": {"count": 4, "channels": le_cct_rgb},
        },
        {
            "name": "Light Engine HSI 8-bit",
            "shortName": "16ch 4px",
            "friendlyName": "HSI color · 4 zones",
            "fixtureMenuName": "12: LE HSI 8-bit",
            "recommended": False,
            "pixels": {"count": 4, "channels": le_hsi},
        },
        {
            "name": "Light Engine XY 8-bit",
            "shortName": "12ch 4px",
            "friendlyName": "CIE xy · 4 zones",
            "fixtureMenuName": "13: LE XY 8-bit",
            "recommended": False,
            "pixels": {"count": 4, "channels": le_xy},
        },
        {
            "name": "Ultimate Mode 8-bit",
            "shortName": "22ch Ultimate",
            "friendlyName": "Ultimate mode (multi-mode switch)",
            "fixtureMenuName": "14: Ultimate 8-bit",
            "recommended": False,
            "channels": [
                ch_int(),
                {
                    "kind": "colorMode",
                    "label": "Lighting Mode Selection",
                    "default": 0,
                    "capabilities": [
                        {"range": [0, 9], "label": "CCT & RGB", "tag": "rgb"},
                        {"range": [10, 19], "label": "CCT", "tag": "cct"},
                        {"range": [20, 29], "label": "CCT & HSI", "tag": "hsi"},
                        {"range": [30, 39], "label": "RGB", "tag": "rgb"},
                        {"range": [40, 49], "label": "HSI", "tag": "hsi"},
                        {"range": [50, 59], "label": "Gel", "tag": "gel"},
                        {"range": [60, 69], "label": "XY", "tag": "xy"},
                        {"range": [70, 79], "label": "Source", "tag": "source"},
                        {"range": [80, 89], "label": "FX", "tag": "effect"},
                    ],
                },
                ch_cct(cct_lo, cct_hi),
                ch_gm_gen1(),
                ch_xfade("CCT ↔ RGB"),
                *ch_rgb(),
                ch_strobe_gen1(),
            ] + [ch_reserved(f"Ultimate Param {i}") for i in range(10, 23)],
        },
        {
            "name": "CCT & RGB 16-bit",
            "shortName": "15ch 16-bit",
            "friendlyName": "Full color + white balance (16-bit smooth)",
            "fixtureMenuName": "15: CCT & RGB 16-bit",
            "recommended": False,
            "channels": expand_16bit(base_8bit[0][4]),
        },
        {
            "name": "CCT 16-bit",
            "shortName": "7ch 16-bit",
            "friendlyName": "White balance only (16-bit smooth)",
            "fixtureMenuName": "16: CCT 16-bit",
            "recommended": False,
            "channels": expand_16bit(base_8bit[1][4]),
        },
        {
            "name": "RGB 16-bit",
            "shortName": "9ch 16-bit",
            "friendlyName": "RGB color (16-bit smooth)",
            "fixtureMenuName": "18: RGB 16-bit",
            "recommended": False,
            "channels": expand_16bit(base_8bit[3][4]),
        },
        {
            "name": "Light Engine CCT & RGB 16-bit",
            "shortName": "56ch 4px 16-bit",
            "friendlyName": "Full color · 4 zones (16-bit smooth)",
            "fixtureMenuName": "25: LE CCT&RGB 16-bit",
            "recommended": False,
            "pixels": {"count": 4, "channels": expand_16bit(le_cct_rgb)},
        },
    ])

    return {
        "id": "aputure.nova-p600c",
        "manufacturer": "Aputure",
        "model": "Nova P600c",
        "category": "panel",
        "aliases": ["Nova P600c", "P600c", "Aputure Nova P600c"],
        "physical": {"lengthMM": 802, "widthMM": 802, "heightMM": 484, "weightKG": 13.7, "powerW": 600},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit", "signalLossBehavior": "Hold Last Setting"},
            "connector": "5-pin XLR DMX In / Out, or LumenRadio CRMX",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black",
            "notes": ["Supports 1-zone whole-panel modes and 4-zone Light Engine modes."],
            "manualURL": spec_url,
        },
        "links": [spec_url],
        "revision": 1,
        "modes": modes,
    }


def build_ls_600c_pro(model, aliases):
    cct_lo, cct_hi = 2300, 10000
    spec_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600c%20Pro%20II/Documents/LS600c%20Pro%20%26%20LS600c%20Pro%20II%20DMX%20Profile%20Specification%20V1.6.pdf"
    c8 = [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb(), ch_strobe_gen1()]
    modes = [
        {
            "name": "CCT & RGB 8-bit",
            "shortName": "8ch",
            "friendlyName": "Full color + white balance (recommended)",
            "fixtureMenuName": "1: CCT & RGB 8-bit",
            "summary": "Dimmer, 2300–10000 K white balance, G/M tint, crossfade, RGB and strobe",
            "recommended": True,
            "channels": c8,
        },
        {
            "name": "CCT 8-bit",
            "shortName": "4ch",
            "friendlyName": "White balance only",
            "fixtureMenuName": "2: CCT 8-bit",
            "summary": "Dimmer, 2300–10000 K white balance, G/M tint and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_strobe_gen1()],
        },
        {
            "name": "CCT & HSI 8-bit",
            "shortName": "8ch HSI",
            "friendlyName": "HSI color + white balance",
            "fixtureMenuName": "3: CCT & HSI 8-bit",
            "summary": "Dimmer, CCT, G/M tint, crossfade, hue, saturation, base CCT and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("CCT ↔ HSI"), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi), ch_strobe_gen1()],
        },
        {
            "name": "RGB 8-bit",
            "shortName": "5ch RGB",
            "friendlyName": "RGB color",
            "fixtureMenuName": "4: RGB 8-bit",
            "summary": "Dimmer, RGB color and strobe",
            "recommended": False,
            "channels": [ch_int(), *ch_rgb(), ch_strobe_gen1()],
        },
        {
            "name": "HSI 8-bit",
            "shortName": "5ch HSI",
            "friendlyName": "HSI color",
            "fixtureMenuName": "5: HSI 8-bit",
            "summary": "Dimmer, hue, saturation, base CCT and strobe",
            "recommended": False,
            "channels": [ch_int(), ch_hue(), ch_sat(), ch_hsi_base_cct(cct_lo, cct_hi), ch_strobe_gen1()],
        },
        {
            "name": "GEL 8-bit",
            "shortName": "6ch GEL",
            "friendlyName": "Digital gels",
            "fixtureMenuName": "6: GEL 8-bit",
            "summary": "Dimmer, base CCT, Rosco/LEE gel selection and strobe",
            "recommended": False,
            "channels": [ch_int(), {"kind": "cct", "label": "Base CCT", "physical": [3200, 5600]},
                         {"kind": "gel", "label": "Gel Brand", "advanced": True},
                         {"kind": "gel", "label": "Gel Series", "advanced": True},
                         {"kind": "gel", "label": "Gel Category", "advanced": True}, ch_strobe_gen1()],
        },
        {
            "name": "xy 8-bit",
            "shortName": "4ch xy",
            "friendlyName": "CIE 1931 xy",
            "fixtureMenuName": "7: xy 8-bit",
            "summary": "Dimmer, CIE x/y coordinates and strobe",
            "recommended": False,
            "channels": [ch_int(), *ch_xy(), ch_strobe_gen1()],
        },
        {
            "name": "Source 8-bit",
            "shortName": "5ch Source",
            "friendlyName": "Real light source presets",
            "fixtureMenuName": "8: Source 8-bit",
            "summary": "Dimmer, source preset, x/y adjust and strobe",
            "recommended": False,
            "channels": [ch_int(), {"kind": "colorMacro", "label": "Source"}, *ch_xy(), ch_strobe_gen1()],
        },
        {
            "name": "FX 8-bit",
            "shortName": "10ch FX",
            "friendlyName": "Built-in effects",
            "fixtureMenuName": "9: FX 8-bit",
            "summary": "Dimmer, effect trigger, FX selection and parameters",
            "recommended": False,
            "channels": [ch_int(), {"kind": "control", "label": "Effect Trigger", "default": 61, "advanced": True},
                         ch_fx_select("FX Selection", default=150)] + [ch_fx_param(f"FX Param {i}") for i in range(1, 8)],
        },
        {
            "name": "WW & RGB 8-bit",
            "shortName": "5ch WWRGB",
            "friendlyName": "Direct emitter control (WW/CW/RGB)",
            "fixtureMenuName": "10: WW & RGB 8-bit",
            "summary": "Warm White, Cool White, Red, Green and Blue channels",
            "recommended": False,
            "channels": [{"kind": "warmWhite", "label": "Warm White"}, {"kind": "coolWhite", "label": "Cool White"}, *ch_rgb()],
        },
        {
            "name": "CCT & RGB 16-bit",
            "shortName": "15ch 16-bit",
            "friendlyName": "Full color + white balance (16-bit smooth)",
            "fixtureMenuName": "12: CCT & RGB 16-bit",
            "summary": "16-bit dimmer, CCT, G/M tint, crossfade, RGB and 8-bit strobe",
            "recommended": False,
            "channels": expand_16bit(c8),
        },
        {
            "name": "CCT 16-bit",
            "shortName": "7ch 16-bit",
            "friendlyName": "White balance only (16-bit smooth)",
            "fixtureMenuName": "13: CCT 16-bit",
            "summary": "16-bit dimmer, CCT, G/M tint and 8-bit strobe",
            "recommended": False,
            "channels": expand_16bit([ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_strobe_gen1()]),
        },
    ]
    slug = model.lower().replace(" ", "-")
    return {
        "id": f"aputure.{slug}",
        "manufacturer": "Aputure",
        "model": model,
        "category": "spot",
        "aliases": aliases,
        "physical": {"diameterMM": 300, "weightKG": 5.86, "powerW": 720},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": spec_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Mode", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Mode", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit", "signalLossBehavior": "Hold Last Setting"},
            "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX, Art-Net / sACN etherCON",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black / Hold 2 min & Fade",
            "notes": ["Hold MENU for 2s to lock DMX address; hold SELECT for 2s to unlock."],
            "manualURL": spec_url,
        },
        "links": [spec_url],
        "revision": 1,
        "modes": modes,
    }


def build_ls_bicolor_and_daylight():
    # LS 600x Pro
    ls600x_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600x%20Pro/All%20Files/LS600X-Pro-DMX-Profile-Specification-V1.0-.pdf"
    ls600x = {
        "id": "aputure.ls-600x-pro",
        "manufacturer": "Aputure",
        "model": "LS 600x Pro",
        "category": "spot",
        "aliases": ["LS 600x Pro", "600x Pro", "Aputure 600x", "LS600x"],
        "physical": {"diameterMM": 300, "weightKG": 4.6, "powerW": 720},
        "cctRange": [2700, 6500],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": ls600x_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Mode", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Mode", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "Lighting", "signalLossBehavior": "Hold Last Setting"},
            "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX, Art-Net / sACN",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting / Black Out / Fade To Black",
            "notes": ["Profile 1 (Lighting, 2 ch) gives clean Dimmer + CCT control without effect channels."],
            "manualURL": ls600x_url,
        },
        "links": [ls600x_url],
        "revision": 1,
        "modes": [
            {
                "name": "Lighting",
                "shortName": "2ch",
                "friendlyName": "White balance (recommended)",
                "fixtureMenuName": "1: Lighting",
                "summary": "Dimmer and 2700–6500 K white balance",
                "recommended": True,
                "channels": [ch_int(), ch_cct(2700, 6500)],
            },
            {
                "name": "Effects",
                "shortName": "5ch FX",
                "friendlyName": "Built-in effects",
                "fixtureMenuName": "2: Effects",
                "summary": "Dimmer, CCT, effect selection, frequency and trigger",
                "recommended": False,
                "channels": [
                    ch_int(),
                    ch_cct(2700, 6500),
                    ch_fx_select("Effects", default=180),
                    ch_fx_speed("Frequency"),
                    {"kind": "control", "label": "Trigger", "default": 0, "advanced": True},
                ],
            },
            {
                "name": "Lighting & Effects",
                "shortName": "6ch",
                "friendlyName": "White balance + built-in effects",
                "fixtureMenuName": "3: Lighting & Effects",
                "summary": "Dimmer, CCT, mode switch (0–127 Lighting / 128–255 Effects) and FX controls",
                "recommended": False,
                "channels": [
                    ch_int(),
                    ch_cct(2700, 6500),
                    {
                        "kind": "colorMode",
                        "label": "Mode",
                        "default": 0,
                        "capabilities": [
                            {"range": [0, 127], "label": "Lighting", "tag": "cct"},
                            {"range": [128, 255], "label": "Effects", "tag": "effect"},
                        ],
                    },
                    ch_fx_select("Effects", default=180),
                    ch_fx_speed("Frequency"),
                    {"kind": "control", "label": "Trigger", "default": 0, "advanced": True},
                ],
            },
        ],
    }

    # LS 300x (stepped CCT: 0-5=2700K, 6-10=2800K, ..., 191-195=6500K)
    ls300x_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20300x/All%20files/LS_300x-Product_Manual_EN.pdf"
    stepped_caps = []
    for step_idx in range(39):  # 2700K .. 6500K in 100K steps (39 steps)
        lo_dmx = 0 if step_idx == 0 else step_idx * 5 + 1
        hi_dmx = (step_idx + 1) * 5
        kelvin = 2700 + step_idx * 100
        stepped_caps.append({"range": [lo_dmx, hi_dmx], "label": f"{kelvin} K", "tag": "cct", "physical": [kelvin]})
    ls300x = {
        "id": "aputure.ls-300x",
        "manufacturer": "Aputure",
        "model": "LS 300x",
        "category": "spot",
        "aliases": ["LS 300x", "300x", "Aputure 300x"],
        "physical": {"diameterMM": 250, "weightKG": 3.1, "powerW": 350},
        "cctRange": [2700, 6500],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": ls300x_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX mode"],
            "modeMenuPath": ["MENU", "DMX mode"],
            "factoryDefaults": {"address": 1, "mode": "Standard 6-ch"},
            "connector": "5-pin XLR DMX In / Out on control box",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting",
            "notes": ["LS 300x has a single 6-channel DMX personality; space multiple units 6 addresses apart."],
            "manualURL": ls300x_url,
        },
        "links": [ls300x_url],
        "revision": 1,
        "modes": [
            {
                "name": "Standard 6-ch",
                "shortName": "6ch",
                "friendlyName": "White balance + effects (6 ch)",
                "fixtureMenuName": "DMX Mode (6ch)",
                "summary": "Dimmer, stepped 2700–6500 K CCT (DMX 0–195), mode switch and effects",
                "recommended": True,
                "channels": [
                    ch_int("Dimmer"),
                    {
                        "kind": "cct",
                        "label": "CCT (2700–6500 K)",
                        "physical": {"from": 2700, "to": 6500, "dmx": [0, 195], "unit": "K"},
                        "capabilities": stepped_caps,
                    },
                    ch_fx_speed("FX Frequency"),
                    {
                        "kind": "colorMode",
                        "label": "Mode (Manual / FX)",
                        "default": 0,
                        "capabilities": [
                            {"range": [0, 127], "label": "Manual Lighting", "tag": "cct"},
                            {"range": [128, 255], "label": "FX Mode", "tag": "effect"},
                        ],
                    },
                    ch_fx_select("FX", default=180),
                    {"kind": "control", "label": "Trigger", "default": 0, "advanced": True},
                ],
            }
        ],
    }

    # Daylight COBs: LS 600d, LS 1200d Pro, LS 600d Pro, LS 300d II, LS C300d II
    daylight_fixtures = []
    for model, power_w, has_1ch, has_16bit, url, aliases in [
        ("LS 600d", 720, True, False, "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600d/All%20files/LS-600d-DMX-Profile-Specification-V1.0-.pdf", ["LS 600d", "600d", "Aputure 600d"]),
        ("LS 1200d Pro", 1440, True, True, "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%201200d%20Pro/All%20Files/LS1200D-Pro-DMX-Profile-Specification-V1.0-.pdf", ["LS 1200d Pro", "1200d Pro", "Aputure 1200d"]),
        ("LS 600d Pro", 720, False, False, "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20600d%20Pro/All%20Files/LS-600d-Pro-DMX-Profile-Specification-V1.0-.pdf", ["LS 600d Pro", "600d Pro", "Aputure 600d Pro"]),
        ("LS 300d II", 350, False, False, "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/LS%20300d%20II/All%20files/LS-600d-Pro-LS-300d-II-common-DMX-Profile-Specification-V1.0.pdf", ["LS 300d II", "300d II", "Aputure 300d II"]),
        ("LS C300d II", 350, False, False, "https://open-fixture-library.org/aputure/ls-c300d-ii", ["LS C300d II", "C300d II"]),
    ]:
        modes = []
        if has_1ch:
            modes.extend([
                {
                    "name": "Lighting 8-bit",
                    "shortName": "1ch",
                    "friendlyName": "Brightness only (recommended)",
                    "fixtureMenuName": "1: Lighting 8-bit",
                    "summary": "Single-channel 5600 K daylight dimmer",
                    "recommended": True,
                    "channels": [ch_int()],
                },
                {
                    "name": "Effect 8-bit",
                    "shortName": "4ch FX",
                    "friendlyName": "Built-in effects",
                    "fixtureMenuName": "2: Effect 8-bit",
                    "summary": "Dimmer and on-board lighting effects",
                    "recommended": False,
                    "channels": [ch_int(), ch_fx_select("Effects", default=160), ch_fx_speed("Frequency"), {"kind": "control", "label": "Trigger", "default": 0, "advanced": True}],
                },
            ])
        modes.append({
            "name": "Lighting & Effect 8-bit",
            "shortName": "5ch",
            "friendlyName": "Brightness + effects" + ("" if has_1ch else " (recommended)"),
            "fixtureMenuName": "3: Lighting & Effect 8-bit" if has_1ch else "Lighting & Effect 8-bit",
            "summary": "Dimmer, mode switch (0–127 Lighting / 128–255 Effects) and FX parameters",
            "recommended": not has_1ch,
            "channels": [
                ch_int(),
                {"kind": "colorMode", "label": "Mode", "default": 0, "capabilities": [
                    {"range": [0, 127], "label": "Lighting", "tag": "default"},
                    {"range": [128, 255], "label": "Effects", "tag": "effect"},
                ]},
                ch_fx_select("Effects", default=160),
                ch_fx_speed("Frequency"),
                {"kind": "control", "label": "Trigger", "default": 0, "advanced": True},
            ],
        })
        if has_16bit:
            modes.extend([
                {
                    "name": "Lighting 16-bit",
                    "shortName": "2ch 16-bit",
                    "friendlyName": "Brightness only (16-bit smooth)",
                    "fixtureMenuName": "4: Lighting 16-bit",
                    "summary": "16-bit coarse + fine daylight dimmer",
                    "recommended": False,
                    "channels": [ch_int(), ch_int(fine=True)],
                },
                {
                    "name": "Effect 16-bit",
                    "shortName": "5ch 16-bit FX",
                    "friendlyName": "Built-in effects (16-bit dimmer)",
                    "fixtureMenuName": "5: Effect 16-bit",
                    "summary": "16-bit dimmer and on-board effects",
                    "recommended": False,
                    "channels": [ch_int(), ch_int(fine=True), ch_fx_select("Effects", default=160), ch_fx_speed("Frequency"), {"kind": "control", "label": "Trigger", "default": 0, "advanced": True}],
                },
                {
                    "name": "Lighting & Effect 16-bit",
                    "shortName": "6ch 16-bit",
                    "friendlyName": "Brightness + effects (16-bit smooth)",
                    "fixtureMenuName": "6: Lighting & Effect 16-bit",
                    "summary": "16-bit dimmer, mode switch and effects",
                    "recommended": False,
                    "channels": [ch_int(), ch_int(fine=True), {"kind": "colorMode", "label": "Mode", "default": 0}, ch_fx_select("Effects", default=160), ch_fx_speed("Frequency"), {"kind": "control", "label": "Trigger", "default": 0, "advanced": True}],
                },
            ])
        slug = model.lower().replace(" ", "-")
        daylight_fixtures.append({
            "id": f"aputure.{slug}",
            "manufacturer": "Aputure",
            "model": model,
            "category": "spot",
            "aliases": aliases,
            "physical": {"diameterMM": 300, "powerW": power_w},
            "cctRange": [5600, 5600],
            "verification": "manufacturerChart",
            "source": "curated",
            "sourceInfo": {"kind": "curated", "url": url, "license": "Proprietary-Facts"},
            "setupGuide": {
                "addressMenuPath": ["MENU", "DMX Mode", "DMX Address"],
                "modeMenuPath": ["MENU", "DMX Mode", "DMX Profile"],
                "factoryDefaults": {"address": 1, "mode": modes[0]["name"]},
                "connector": "5-pin XLR DMX In / Out",
                "addressDisplayFormat": "001",
                "usesDipSwitches": False,
                "signalLossBehavior": "Hold Last Setting",
                "notes": ["5600 K daylight COB monolight."],
                "manualURL": url,
            },
            "links": [url],
            "revision": 1,
            "modes": modes,
        })

    return [ls600x, ls300x] + daylight_fixtures


def build_storm_and_electro_storm():
    # STORM 1000c & STORM 80c (OS II protocol, 1800-20000 K, RGBACL BLAIR-CG engine)
    storm_c_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/STORM%2080c/manuals/STORM%201000c%20%26%2080c%20DMX%20Profile%20Specification%20V1.3.pdf"
    storm_fixtures = []
    for model, power_w, aliases in [
        ("STORM 1000c", 1000, ["STORM 1000c", "Aputure STORM 1000c", "1000c"]),
        ("STORM 80c", 80, ["STORM 80c", "Aputure STORM 80c", "80c"]),
    ]:
        c_rgb_8 = [ch_int(), ch_cct(1800, 20000), ch_gm_os2(137), ch_xfade("White Light to RGB"), *ch_rgb()]
        hsic_8 = [ch_int(), ch_cct(1800, 20000), ch_gm_os2(137), ch_hue(), ch_sat()]
        cct_8 = [ch_int(), ch_cct(1800, 20000), ch_gm_os2(137)]
        irgb_8 = [ch_int(), *ch_rgb()]
        rgbacl_8 = [
            {"kind": "red", "label": "Red"},
            {"kind": "green", "label": "Green"},
            {"kind": "blue", "label": "Blue"},
            {"kind": "amber", "label": "Amber"},
            {"kind": "cyan", "label": "Cyan"},
            {"kind": "lime", "label": "Lime"},
        ]
        modes = [
            {
                "name": "CCT & RGB 8-bit",
                "shortName": "P1 (7ch)",
                "friendlyName": "Full color + white balance (recommended)",
                "fixtureMenuName": "P1: CCT & RGB 8-bit",
                "summary": "Dimmer, 1800–20000 K white balance, ±Green, crossfade and RGB",
                "recommended": True,
                "channels": c_rgb_8,
            },
            {
                "name": "CCT & RGB 16-bit",
                "shortName": "P2 (14ch)",
                "friendlyName": "Full color + white balance (16-bit smooth)",
                "fixtureMenuName": "P2: CCT & RGB 16-bit",
                "recommended": False,
                "channels": expand_16bit(c_rgb_8),
            },
            {
                "name": "HSI 8-bit",
                "shortName": "P9 (3ch)",
                "friendlyName": "HSI color",
                "fixtureMenuName": "P9: HSI 8-bit",
                "recommended": False,
                "channels": [ch_int(), ch_hue(), ch_sat()],
            },
            {
                "name": "HSIC+ 8-bit",
                "shortName": "P11 (5ch)",
                "friendlyName": "HSIC+ color + white balance",
                "fixtureMenuName": "P11: HSIC+ 8-bit",
                "recommended": False,
                "channels": hsic_8,
            },
            {
                "name": "xy 8-bit",
                "shortName": "P19 (3ch)",
                "friendlyName": "CIE 1931 xy",
                "fixtureMenuName": "P19: xy 8-bit",
                "recommended": False,
                "channels": [ch_int(), *ch_xy()],
            },
            {
                "name": "RGB 8-bit",
                "shortName": "P21 (3ch)",
                "friendlyName": "RGB direct (no master dimmer)",
                "fixtureMenuName": "P21: RGB 8-bit",
                "recommended": False,
                "channels": ch_rgb(),
            },
            {
                "name": "iRGB 8-bit",
                "shortName": "P23 (4ch)",
                "friendlyName": "Dimmer + RGB",
                "fixtureMenuName": "P23: iRGB 8-bit",
                "recommended": False,
                "channels": irgb_8,
            },
            {
                "name": "RGBACL 8-bit",
                "shortName": "P25 (6ch)",
                "friendlyName": "Direct 6-emitter RGBACL",
                "fixtureMenuName": "P25: RGBACL 8-bit",
                "recommended": False,
                "channels": rgbacl_8,
            },
            {
                "name": "CCT+ 8-bit",
                "shortName": "P27 (3ch)",
                "friendlyName": "White balance + ±Green only",
                "fixtureMenuName": "P27: CCT+ 8-bit",
                "recommended": False,
                "channels": cct_8,
            },
            {
                "name": "CCT & RGB & Control 8-bit",
                "shortName": "P41 (10ch)",
                "friendlyName": "Full color + Strobe / Control / Fan",
                "fixtureMenuName": "P41: CCT & RGB & Control 8-bit",
                "recommended": False,
                "channels": c_rgb_8 + [ch_strobe_os2(), ch_control(), ch_fan()],
            },
        ]
        slug = model.lower().replace(" ", "-")
        storm_fixtures.append({
            "id": f"aputure.{slug}",
            "manufacturer": "Aputure",
            "model": model,
            "category": "spot",
            "aliases": aliases,
            "physical": {"diameterMM": 300 if power_w > 200 else 150, "powerW": power_w},
            "cctRange": [1800, 20000],
            "verification": "manufacturerChart",
            "source": "curated",
            "sourceInfo": {"kind": "curated", "url": storm_c_url, "license": "Proprietary-Facts"},
            "emitters": BLAIR_EMITTERS,
            "setupGuide": {
                "addressMenuPath": ["MENU", "DMX", "DMX Address"],
                "modeMenuPath": ["MENU", "DMX", "DMX Profile"],
                "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit", "signalLossBehavior": "Hold Last State"},
                "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX",
                "addressDisplayFormat": "001",
                "usesDipSwitches": False,
                "signalLossBehavior": "Hold Last State / Black Out / Fade Out",
                "notes": ["Odd profile numbers are 8-bit; even profile numbers are 16-bit. Profiles 41–72 append Strobe, Control and Fan."],
                "manualURL": storm_c_url,
            },
            "links": [storm_c_url],
            "revision": 1,
            "modes": modes,
        })

    # STORM 1200x (2500-10000 K BLAIR bi-color with ±Green and limited color)
    s1200x_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/STORM%201200x/documents/STORM%201200x%20DMX%20Profile%20Specification%20V1.5.pdf"
    storm_fixtures.append({
        "id": "aputure.storm-1200x",
        "manufacturer": "Aputure",
        "model": "STORM 1200x",
        "category": "spot",
        "aliases": ["STORM 1200x", "Aputure STORM 1200x", "1200x"],
        "physical": {"diameterMM": 330, "powerW": 1440},
        "cctRange": [2500, 10000],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": s1200x_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT+ 8-bit"},
            "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX, Art-Net / sACN",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last State",
            "notes": ["BLAIR white-light engine with full ±Green ASC MITC range (2500–10000 K)."],
            "manualURL": s1200x_url,
        },
        "links": [s1200x_url],
        "revision": 1,
        "modes": [
            {
                "name": "CCT+ 8-bit",
                "shortName": "P1 (3ch)",
                "friendlyName": "White balance + ±Green (recommended)",
                "fixtureMenuName": "P1: CCT+ 8-bit",
                "recommended": True,
                "channels": [ch_int(), ch_cct(2500, 10000), ch_gm_os2(133)],
            },
            {
                "name": "CCT+ 16-bit",
                "shortName": "P2 (6ch)",
                "friendlyName": "White balance + ±Green (16-bit smooth)",
                "fixtureMenuName": "P2: CCT+ 16-bit",
                "recommended": False,
                "channels": expand_16bit([ch_int(), ch_cct(2500, 10000), ch_gm_os2(133)]),
            },
            {
                "name": "CCT+ Control 8-bit",
                "shortName": "P3 (6ch)",
                "friendlyName": "White balance + ±Green + Strobe/Ctrl/Fan",
                "fixtureMenuName": "P3: CCT+ Control 8-bit",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2500, 10000), ch_gm_os2(133), ch_strobe_os2(), ch_control(), ch_fan()],
            },
            {
                "name": "Limited CCT & RGB 8-bit",
                "shortName": "P17 (7ch)",
                "friendlyName": "White balance + limited-gamut RGB",
                "fixtureMenuName": "P17: Limited CCT & RGB 8-bit",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2500, 10000), ch_gm_os2(133), ch_xfade("CCT → RGB"), *ch_rgb()],
            },
        ],
    })

    # Electro Storm XT26 & CS15
    xt26_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Electro%20Storm%20XT26/Electro%20Storm%20XT26%20DMX%20Profile%20Specification%20V1.1.pdf"
    cs15_url = "https://docs.aputure.com/hubfs/Knowledge%20Base/Aputure/Electro%20Storm%20CS15/Electro%20Storm%20CS15%20DMX%20Profile%20Specification%20V1.1.pdf"
    ext_acc = [
        {"kind": "zoom", "label": "Motorized Zoom (18–50°)", "default": 0, "physical": {"from": 18, "to": 50, "dmx": [20, 255], "unit": "deg"}},
        {"kind": "pan", "label": "Motorized Yoke Pan", "default": 0, "physical": {"from": 0, "to": 360, "dmx": [20, 255], "unit": "deg"}},
        {"kind": "tilt", "label": "Motorized Yoke Tilt", "default": 0, "physical": {"from": -135, "to": 135, "dmx": [20, 255], "unit": "deg"}},
    ]
    ext_fn = [ch_fan(), {"kind": "dimmerCurve", "label": "Dimming Curve", "default": 0, "advanced": True}]

    storm_fixtures.append({
        "id": "aputure.electro-storm-xt26",
        "manufacturer": "Aputure",
        "model": "Electro Storm XT26",
        "category": "spot",
        "aliases": ["Electro Storm XT26", "XT26", "Aputure XT26"],
        "physical": {"diameterMM": 350, "powerW": 2600},
        "cctRange": [2700, 6500],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": xt26_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT 8-bit (Full Extensions)"},
            "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX, Art-Net / sACN",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting",
            "notes": [
                "Channel footprint depends on DMX Profile Extension toggles: Motorized Accessories (+3 ch) and Function Configuration (+2 ch), both ON by default."
            ],
            "manualURL": xt26_url,
        },
        "links": [xt26_url],
        "revision": 1,
        "modes": [
            {
                "name": "CCT 8-bit (Base)",
                "shortName": "4ch",
                "friendlyName": "White balance (Extensions OFF)",
                "fixtureMenuName": "1: CCT 8-bit (4ch)",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2700, 6500), ch_gm_gen1(), ch_strobe_gen1()],
            },
            {
                "name": "CCT 8-bit (Full Extensions)",
                "shortName": "9ch",
                "friendlyName": "White balance + Accessories & Fan (Default ON)",
                "fixtureMenuName": "1: CCT 8-bit (9ch)",
                "recommended": True,
                "channels": [ch_int(), ch_cct(2700, 6500), ch_gm_gen1(), ch_strobe_gen1()] + ext_acc + ext_fn,
            },
            {
                "name": "CCT 16-bit (Base)",
                "shortName": "7ch 16-bit",
                "friendlyName": "White balance 16-bit (Extensions OFF)",
                "fixtureMenuName": "4: CCT 16-bit (7ch)",
                "recommended": False,
                "channels": expand_16bit([ch_int(), ch_cct(2700, 6500), ch_gm_gen1(), ch_strobe_gen1()]),
            },
        ],
    })

    storm_fixtures.append({
        "id": "aputure.electro-storm-cs15",
        "manufacturer": "Aputure",
        "model": "Electro Storm CS15",
        "category": "spot",
        "aliases": ["Electro Storm CS15", "CS15", "Aputure CS15"],
        "physical": {"diameterMM": 350, "powerW": 1500},
        "cctRange": [2000, 10000],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": cs15_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX", "DMX Profile"],
            "factoryDefaults": {"address": 1, "mode": "CCT & RGB 8-bit (Full Extensions)"},
            "connector": "5-pin XLR DMX In / Out, LumenRadio CRMX, Art-Net / sACN",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Setting",
            "notes": [
                "Channel footprint depends on DMX Profile Extension toggles: Motorized Accessories (+3 ch) and Function Configuration (+2 ch), both ON by default."
            ],
            "manualURL": cs15_url,
        },
        "links": [cs15_url],
        "revision": 1,
        "modes": [
            {
                "name": "CCT & RGB 8-bit (Base)",
                "shortName": "8ch",
                "friendlyName": "Full color + white balance (Extensions OFF)",
                "fixtureMenuName": "1: CCT & RGB 8-bit (8ch)",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2000, 10000), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb(), ch_strobe_gen1()],
            },
            {
                "name": "CCT & RGB 8-bit (Full Extensions)",
                "shortName": "13ch",
                "friendlyName": "Full color + white balance (Extensions ON, recommended)",
                "fixtureMenuName": "1: CCT & RGB 8-bit (13ch)",
                "recommended": True,
                "channels": [ch_int(), ch_cct(2000, 10000), ch_gm_gen1(), ch_xfade("CCT ↔ RGB"), *ch_rgb(), ch_strobe_gen1()] + ext_acc + ext_fn,
            },
            {
                "name": "CCT 8-bit (Base)",
                "shortName": "4ch",
                "friendlyName": "White balance only (Extensions OFF)",
                "fixtureMenuName": "2: CCT 8-bit (4ch)",
                "recommended": False,
                "channels": [ch_int(), ch_cct(2000, 10000), ch_gm_gen1(), ch_strobe_gen1()],
            },
            {
                "name": "RGB 8-bit (Base)",
                "shortName": "5ch RGB",
                "friendlyName": "RGB color (Extensions OFF)",
                "fixtureMenuName": "4: RGB 8-bit (5ch)",
                "recommended": False,
                "channels": [ch_int(), *ch_rgb(), ch_strobe_gen1()],
            },
        ],
    })

    return storm_fixtures


def build_all_aputure():
    return [
        build_infinibar_or_mt("INFINIBAR PB3", False, 304, 0.6, 14, [4, 6, 8, 12, 24], ["INFINIBAR PB3", "PB3", "Aputure PB3", "Infinibar"]),
        build_infinibar_or_mt("INFINIBAR PB6", False, 604, 1.0, 27, [4, 6, 8, 12, 16, 24, 48], ["INFINIBAR PB6", "PB6", "Aputure PB6", "Infinibar"]),
        build_infinibar_or_mt("INFINIBAR PB12", False, 1204, 1.96, 48, [4, 6, 8, 12, 16, 24, 32, 48], ["INFINIBAR PB12", "PB12", "Aputure PB12", "Infinibar"]),
        build_infinibar_or_mt("MT Pro", True, 300, 0.391, 7.5, [4, 6, 9, 12, 18, 36], ["MT Pro", "Aputure MT Pro", "MTPro"]),
        build_nova_p300c(),
        build_nova_p600c(),
        build_ls_600c_pro("LS 600c Pro", ["LS 600c Pro", "600c Pro", "Aputure 600c"]),
        build_ls_600c_pro("LS 600c Pro II", ["LS 600c Pro II", "600c Pro II", "Aputure 600c II"]),
        *build_ls_bicolor_and_daylight(),
        *build_storm_and_electro_storm(),
    ]


# ---------------------------------------------------------------------------
# 3. Curated Film/TV Pack (Nanlite, Godox, Astera, Litepanels, ARRI, Kino Flo, Quasar, Creamsource, Rotolight)
# ---------------------------------------------------------------------------


def make_film_rgbww_fixture(brand, model, category, cct_lo, cct_hi, length_mm, width_mm, power_w, aliases,
                            pixel_counts=None, address_path=None, mode_path=None, connector="5-pin XLR DMX In / Out",
                            addr_fmt="001", manual_url=None, notes=None):
    slug_brand = brand.lower().replace(" ", "-")
    slug_model = model.lower().replace(" ", "-").replace("/", "-")
    modes = [
        {
            "name": "CCT & RGB",
            "shortName": "7ch",
            "friendlyName": "Full color + white balance" + (" · 1 zone" if pixel_counts else " (recommended)"),
            "fixtureMenuName": "CCT & RGB",
            "summary": f"Dimmer, {cct_lo}–{cct_hi} K white balance, G/M tint, crossfade and RGB color",
            "recommended": not bool(pixel_counts),
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_linear(), ch_xfade("CCT ↔ RGB"), *ch_rgb()],
        },
        {
            "name": "CCT",
            "shortName": "3ch",
            "friendlyName": "White balance only",
            "fixtureMenuName": "CCT",
            "summary": f"Dimmer, {cct_lo}–{cct_hi} K white balance and G/M tint",
            "recommended": False,
            "channels": [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_linear()],
        },
        {
            "name": "RGBW",
            "shortName": "5ch RGBW",
            "friendlyName": "Dimmer + RGBW",
            "fixtureMenuName": "RGBW",
            "summary": "Dimmer, Red, Green, Blue and White",
            "recommended": False,
            "channels": [ch_int(), *ch_rgb(), {"kind": "white", "label": "White"}],
        },
        {
            "name": "HSI",
            "shortName": "3ch HSI",
            "friendlyName": "HSI color",
            "fixtureMenuName": "HSI",
            "summary": "Dimmer, hue (0–360°) and saturation",
            "recommended": False,
            "channels": [ch_int(), ch_hue(), ch_sat()],
        },
        {
            "name": "CCT & RGB 16-bit",
            "shortName": "14ch 16-bit",
            "friendlyName": "Full color + white balance (16-bit smooth)",
            "fixtureMenuName": "CCT & RGB 16-bit",
            "summary": "16-bit dimmer, CCT, G/M tint, crossfade and RGB",
            "recommended": False,
            "channels": expand_16bit([ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_linear(), ch_xfade("CCT ↔ RGB"), *ch_rgb()]),
        },
    ]
    if pixel_counts:
        rec_px = 8 if 8 in pixel_counts else (10 if 10 in pixel_counts else pixel_counts[-1])
        px_template_rgbw = [ch_int(), *ch_rgb(), {"kind": "white", "label": "White"}]
        px_template_cct_rgb = [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_linear(), ch_xfade("CCT ↔ RGB"), *ch_rgb()]
        for px in pixel_counts:
            is_rec = px == rec_px
            modes.append({
                "name": f"Pixel CCT & RGB {px} Zones",
                "shortName": f"{px}px CCT+RGB",
                "friendlyName": f"Full color · {px} zones" + (" (recommended)" if is_rec else ""),
                "fixtureMenuName": f"Pixel {px}x CCT&RGB",
                "summary": f"{px} independent zones with dimmer, {cct_lo}–{cct_hi} K white balance, tint and RGB",
                "recommended": is_rec,
                "pixels": {"count": px, "channels": px_template_cct_rgb},
            })
            modes.append({
                "name": f"Pixel RGBW {px} Zones",
                "shortName": f"{px}px RGBW",
                "friendlyName": f"RGBW color · {px} zones",
                "fixtureMenuName": f"Pixel {px}x RGBW",
                "summary": f"{px} independent zones with dimmer and RGBW",
                "recommended": False,
                "pixels": {"count": px, "channels": px_template_rgbw},
            })

    return {
        "id": f"{slug_brand}.{slug_model}",
        "manufacturer": brand,
        "model": model,
        "category": category,
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": width_mm, "heightMM": width_mm if category == "panel" else 45, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": manual_url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": address_path or ["MENU", "DMX", "Address"],
            "modeMenuPath": mode_path or ["MENU", "DMX", "DMX Mode"],
            "factoryDefaults": {"address": 1, "mode": modes[0]["name"]},
            "connector": connector,
            "addressDisplayFormat": addr_fmt,
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Look",
            "notes": notes or ["Verify DMX address and mode on the fixture screen match Prism's patch."],
            "manualURL": manual_url,
        },
        "links": [manual_url] if manual_url else None,
        "revision": 1,
        "modes": modes,
    }


def make_film_bicolor_fixture(brand, model, category, cct_lo, cct_hi, length_mm, width_mm, power_w, aliases,
                              has_gm=False, connector="5-pin XLR DMX In / Out", addr_fmt="001", manual_url=None):
    slug_brand = brand.lower().replace(" ", "-")
    slug_model = model.lower().replace(" ", "-").replace("/", "-")
    base_ch = [ch_int(), ch_cct(cct_lo, cct_hi)] + ([ch_gm_linear()] if has_gm else [])
    modes = [
        {
            "name": "CCT 8-bit",
            "shortName": f"{len(base_ch)}ch",
            "friendlyName": "White balance" + (" + G/M tint" if has_gm else "") + " (recommended)",
            "fixtureMenuName": "CCT 8-bit",
            "summary": f"Dimmer and {cct_lo}–{cct_hi} K white balance" + (" with G/M tint" if has_gm else ""),
            "recommended": True,
            "channels": base_ch,
        },
        {
            "name": "CCT + Strobe",
            "shortName": f"{len(base_ch) + 1}ch",
            "friendlyName": "White balance + strobe",
            "fixtureMenuName": "CCT + Strobe",
            "summary": f"Dimmer, {cct_lo}–{cct_hi} K white balance and strobe",
            "recommended": False,
            "channels": base_ch + [ch_strobe_gen1()],
        },
        {
            "name": "CCT 16-bit",
            "shortName": f"{len(base_ch) * 2}ch 16-bit",
            "friendlyName": "White balance (16-bit smooth)",
            "fixtureMenuName": "CCT 16-bit",
            "summary": "16-bit smooth dimming and white balance",
            "recommended": False,
            "channels": expand_16bit(base_ch),
        },
    ]
    return {
        "id": f"{slug_brand}.{slug_model}",
        "manufacturer": brand,
        "model": model,
        "category": category,
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": width_mm, "heightMM": width_mm if category == "panel" else 180, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": manual_url, "license": "Proprietary-Facts"},
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX", "Address"],
            "modeMenuPath": ["MENU", "DMX", "DMX Mode"],
            "factoryDefaults": {"address": 1, "mode": "CCT 8-bit"},
            "connector": connector,
            "addressDisplayFormat": addr_fmt,
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Look",
            "notes": ["Set DMX address and mode on the fixture's DMX menu."],
            "manualURL": manual_url,
        },
        "links": [manual_url] if manual_url else None,
        "revision": 1,
        "modes": modes,
    }


def build_arri_skypanel(model, length_mm, width_mm, power_w, zones, aliases):
    cct_lo, cct_hi = 2800, 10000
    url = "https://www.arri.com/en/lighting/led/skypanel"
    # ARRI SkyPanel P01 (CCT & RGBW 8-bit, 12 ch), P02 (CCT 8-bit, 7 ch), P03 (CCT & HSI 8-bit, 10 ch), P06 (CCT & RGBW 16-bit, 20 ch)
    p01_ch = [
        ch_int("Dimmer"),
        ch_cct(cct_lo, cct_hi, "Color Temperature"),
        ch_gm_gen1("Green-Magenta Point"),
        ch_xfade("Crossfade to Color"),
        *ch_rgb(),
        {"kind": "white", "label": "White"},
        ch_fan("Fan Control"),
        {"kind": "colorMacro", "label": "Presets"},
        ch_strobe_gen1("Strobe"),
        ch_reserved("Reserved"),
    ]
    p02_ch = [
        ch_int("Dimmer"),
        ch_cct(cct_lo, cct_hi, "Color Temperature"),
        ch_gm_gen1("Green-Magenta Point"),
        ch_fan("Fan Control"),
        {"kind": "colorMacro", "label": "Presets"},
        ch_strobe_gen1("Strobe"),
        ch_reserved("Reserved"),
    ]
    p03_ch = [
        ch_int("Dimmer"),
        ch_cct(cct_lo, cct_hi, "Color Temperature"),
        ch_gm_gen1("Green-Magenta Point"),
        ch_xfade("Crossfade to Color"),
        ch_hue("Hue"),
        ch_sat("Saturation"),
        ch_fan("Fan Control"),
        {"kind": "colorMacro", "label": "Presets"},
        ch_strobe_gen1("Strobe"),
        ch_reserved("Reserved"),
    ]
    modes = [
        {
            "name": "P01: CCT & RGBW 8bit",
            "shortName": "P01 (12ch)",
            "friendlyName": "Full color + white balance (recommended)",
            "fixtureMenuName": "P01: CCT & RGBW 8bit",
            "summary": "Dimmer, 2800–10000 K CCT, G/M tint, crossfade, RGBW, fan, presets and strobe",
            "recommended": True,
            "channels": p01_ch,
        },
        {
            "name": "P02: CCT 8bit",
            "shortName": "P02 (7ch)",
            "friendlyName": "White balance only",
            "fixtureMenuName": "P02: CCT 8bit",
            "summary": "Dimmer, 2800–10000 K CCT, G/M tint, fan, presets and strobe",
            "recommended": False,
            "channels": p02_ch,
        },
        {
            "name": "P03: CCT & HSI 8bit",
            "shortName": "P03 (10ch)",
            "friendlyName": "HSI color + white balance",
            "fixtureMenuName": "P03: CCT & HSI 8bit",
            "summary": "Dimmer, 2800–10000 K CCT, G/M tint, crossfade, hue, saturation, fan, presets and strobe",
            "recommended": False,
            "channels": p03_ch,
        },
        {
            "name": "P06: CCT & RGBW 16bit",
            "shortName": "P06 (20ch)",
            "friendlyName": "Full color + white balance (16-bit smooth)",
            "fixtureMenuName": "P06: CCT & RGBW 16bit",
            "summary": "16-bit dimmer, CCT, G/M tint, crossfade and RGBW",
            "recommended": False,
            "channels": expand_16bit(p01_ch),
        },
    ]
    if zones > 1:
        zone_ch = [ch_int(), ch_cct(cct_lo, cct_hi), ch_gm_gen1(), ch_xfade("Crossfade"), *ch_rgb(), {"kind": "white", "label": "White"}]
        modes.append({
            "name": f"P14: Light Engine CCT & RGBW ({zones} Zones)",
            "shortName": f"P14 ({zones}px)",
            "friendlyName": f"Full color · {zones} zones",
            "fixtureMenuName": "P14: LE CCT & RGBW 8bit",
            "summary": f"{zones} independent zones with CCT, tint and RGBW",
            "recommended": False,
            "pixels": {"count": zones, "channels": zone_ch},
        })

    slug = model.lower().replace(" ", "-").replace("-", "-")
    return {
        "id": f"arri.{slug}",
        "manufacturer": "ARRI",
        "model": model,
        "category": "panel",
        "aliases": aliases,
        "physical": {"lengthMM": length_mm, "widthMM": width_mm, "heightMM": 133, "powerW": power_w},
        "cctRange": [cct_lo, cct_hi],
        "verification": "manufacturerChart",
        "source": "curated",
        "sourceInfo": {"kind": "curated", "url": url, "license": "Proprietary-Facts"},
        "emitters": RGBWW_EMITTERS,
        "setupGuide": {
            "addressMenuPath": ["MENU", "DMX Settings", "DMX Address"],
            "modeMenuPath": ["MENU", "DMX Settings", "DMX Protocol"],
            "factoryDefaults": {"address": 1, "mode": "P01: CCT & RGBW 8bit", "signalLossBehavior": "Hold Last Look"},
            "connector": "5-pin XLR DMX In / Out, EtherCON (Art-Net / sACN), LumenRadio CRMX",
            "addressDisplayFormat": "001",
            "usesDipSwitches": False,
            "signalLossBehavior": "Hold Last Look / Black Out / Hold 2 min & Fade Out",
            "notes": ["Protocol P01 (12 ch) is ARRI's standard 8-bit CCT & RGBW mode."],
            "manualURL": url,
        },
        "links": [url],
        "revision": 1,
        "modes": modes,
    }


def build_all_film_tv():
    fixtures = []
    # Nanlite PavoTube II C & X series
    for model, length_mm, power_w, px_list, aliases in [
        ("PavoTube II 6C", 250, 10, None, ["PavoTube II 6C", "PavoTube 6C", "pavotube"]),
        ("PavoTube II 15C", 770, 30, [4, 8], ["PavoTube II 15C", "PavoTube 15C", "pavotube"]),
        ("PavoTube II 30C", 1170, 60, [4, 8, 16], ["PavoTube II 30C", "PavoTube 30C", "pavotube"]),
        ("PavoTube II 60C", 2200, 120, [8, 16], ["PavoTube II 60C", "PavoTube 60C", "pavotube"]),
        ("PavoTube II 15X", 770, 35, [4, 8], ["PavoTube II 15X", "PavoTube 15X", "pavotube 15x", "pavotube"]),
        ("PavoTube II 30X", 1170, 70, [4, 8, 16], ["PavoTube II 30X", "PavoTube 30X", "pavotube 30x", "pavotube"]),
        ("PavoTube II 60X", 2200, 140, [8, 16, 32], ["PavoTube II 60X", "PavoTube 60X", "pavotube 60x", "pavotube"]),
    ]:
        fixtures.append(make_film_rgbww_fixture(
            "Nanlite", model, "tube", 2700, 7500 if "C" in model else 12000, length_mm, 43, power_w, aliases,
            pixel_counts=px_list, connector="Locking 5-pin DMX cable (CB-DMX-ACP-1/2) or CRMX", addr_fmt="A001",
            manual_url="https://www.nanlite.com"
        ))
    # Nanlite PavoSlim, Forza, FS
    fixtures.extend([
        make_film_rgbww_fixture("Nanlite", "PavoSlim 60C", "panel", 2700, 7500, 300, 300, 72, ["PavoSlim 60C", "Nanlite PavoSlim 60C"]),
        make_film_rgbww_fixture("Nanlite", "PavoSlim 120C", "panel", 2700, 7500, 600, 300, 150, ["PavoSlim 120C", "Nanlite PavoSlim 120C"]),
        make_film_bicolor_fixture("Nanlite", "PavoSlim 60B", "panel", 2700, 6500, 300, 300, 72, ["PavoSlim 60B"]),
        make_film_bicolor_fixture("Nanlite", "PavoSlim 120B", "panel", 2700, 6500, 600, 300, 150, ["PavoSlim 120B"]),
        make_film_rgbww_fixture("Nanlite", "Forza 60C", "spot", 1800, 20000, 224, 110, 88, ["Forza 60C", "Nanlite Forza 60C"]),
        make_film_bicolor_fixture("Nanlite", "Forza 150B", "spot", 2700, 6500, 247, 133, 170, ["Forza 150B", "Nanlite Forza 150B"]),
        make_film_bicolor_fixture("Nanlite", "Forza 300B II", "spot", 2700, 6500, 327, 226, 350, ["Forza 300B II", "Forza 300B"], has_gm=True),
        make_film_bicolor_fixture("Nanlite", "Forza 500B II", "spot", 2700, 6500, 350, 230, 580, ["Forza 500B II", "Forza 500B"], has_gm=True),
        make_film_bicolor_fixture("Nanlite", "FS-150B", "spot", 2700, 6500, 356, 213, 175, ["FS-150B", "Nanlite FS-150B", "FS 150B"]),
        make_film_bicolor_fixture("Nanlite", "FS-300B", "spot", 2700, 6500, 346, 233, 350, ["FS-300B", "Nanlite FS-300B", "FS 300B"]),
        make_film_rgbww_fixture("Nanlite", "FS-300C", "spot", 2700, 7500, 346, 233, 350, ["FS-300C", "Nanlite FS-300C", "FS 300C"]),
    ])

    # Godox TL30/TL60/TL120, SL/SZ, KNOWLED MG/F
    fixtures.extend([
        make_film_rgbww_fixture("Godox", "TL30", "tube", 2700, 6500, 300, 42, 8, ["TL30", "Godox TL30"]),
        make_film_rgbww_fixture("Godox", "TL60", "tube", 2700, 6500, 750, 48, 18, ["TL60", "Godox TL60"], pixel_counts=[4, 8], connector="RJ45 DMX In / Out"),
        make_film_rgbww_fixture("Godox", "TL120", "tube", 2700, 6500, 1170, 48, 30, ["TL120", "Godox TL120"], pixel_counts=[4, 8, 16], connector="RJ45 DMX In / Out"),
        make_film_bicolor_fixture("Godox", "SL60IIBi", "spot", 2800, 6500, 230, 140, 75, ["SL60IIBi", "Godox SL60IIBi", "SL60"]),
        make_film_bicolor_fixture("Godox", "SL150IIBi", "spot", 2800, 6500, 290, 160, 150, ["SL150IIBi", "Godox SL150IIBi", "SL150"]),
        make_film_rgbww_fixture("Godox", "SZ150R", "spot", 2800, 6500, 336, 198, 150, ["SZ150R", "Godox SZ150R"]),
        make_film_bicolor_fixture("Godox", "SZ200Bi", "spot", 2800, 6500, 336, 198, 200, ["SZ200Bi", "Godox SZ200Bi"]),
        make_film_bicolor_fixture("Godox", "KNOWLED MG1200Bi", "spot", 2800, 6500, 380, 280, 1400, ["KNOWLED MG1200Bi", "MG1200Bi", "Godox MG1200Bi"], has_gm=True),
        make_film_rgbww_fixture("Godox", "KNOWLED MG1200R", "spot", 1800, 10000, 380, 280, 1500, ["KNOWLED MG1200R", "MG1200R", "Godox MG1200R"]),
        make_film_bicolor_fixture("Godox", "KNOWLED F200Bi", "panel", 2700, 8500, 600, 600, 230, ["KNOWLED F200Bi", "F200Bi", "Godox F200Bi"], has_gm=True),
        make_film_bicolor_fixture("Godox", "KNOWLED F400Bi", "panel", 2700, 8500, 1200, 600, 450, ["KNOWLED F400Bi", "F400Bi", "Godox F400Bi"], has_gm=True),
        make_film_bicolor_fixture("Godox", "KNOWLED F600Bi", "panel", 2700, 8500, 1200, 1200, 670, ["KNOWLED F600Bi", "F600Bi", "Godox F600Bi"], has_gm=True),
    ])

    # Astera Titan, Helios, Hyperion, AX1, PixelBrick
    fixtures.extend([
        make_film_rgbww_fixture("Astera", "Titan Tube (FP1)", "tube", 1750, 20000, 1035, 42, 72,
                                ["Titan Tube", "FP1", "Astera Titan", "FP1 Titan Tube"], pixel_counts=[4, 8, 16],
                                connector="AsteraBox CRMX or PowerBox 5-pin DMX"),
        make_film_rgbww_fixture("Astera", "Helios Tube (FP2)", "tube", 1750, 20000, 550, 42, 36,
                                ["Helios Tube", "FP2", "Astera Helios", "FP2 Helios Tube"], pixel_counts=[4, 8],
                                connector="AsteraBox CRMX or PowerBox 5-pin DMX"),
        make_film_rgbww_fixture("Astera", "Hyperion Tube (FP3)", "tube", 1750, 20000, 2031, 42, 144,
                                ["Hyperion Tube", "FP3", "Astera Hyperion", "FP3 Hyperion Tube"], pixel_counts=[8, 16, 32],
                                connector="AsteraBox CRMX or PowerBox 5-pin DMX"),
        make_film_rgbww_fixture("Astera", "AX1 PixelTube", "tube", 1750, 20000, 1035, 42, 28,
                                ["AX1 PixelTube", "AX1", "Astera AX1"], pixel_counts=[4, 8, 16],
                                connector="AsteraBox CRMX"),
        make_film_rgbww_fixture("Astera", "PixelBrick (PB15)", "par", 1750, 20000, 98, 98, 15,
                                ["PixelBrick", "PB15", "Astera PixelBrick"],
                                connector="AsteraBox CRMX or PowerBox DMX"),
    ])

    # Litepanels Gemini & Astra
    fixtures.extend([
        make_film_rgbww_fixture("Litepanels", "Gemini 1x1 Soft", "panel", 2700, 10000, 320, 320, 200,
                                ["Gemini 1x1 Soft", "Litepanels Gemini 1x1", "Gemini 1x1"]),
        make_film_rgbww_fixture("Litepanels", "Gemini 2x1 Soft", "panel", 2700, 10000, 635, 320, 325,
                                ["Gemini 2x1 Soft", "Litepanels Gemini 2x1", "Gemini 2x1"]),
        make_film_rgbww_fixture("Litepanels", "Gemini 2x1 Hard", "panel", 2700, 10000, 635, 320, 500,
                                ["Gemini 2x1 Hard", "Litepanels Gemini 2x1 Hard"]),
        make_film_bicolor_fixture("Litepanels", "Astra 6X Bi-Color", "panel", 3200, 5600, 450, 413, 105,
                                  ["Astra 6X Bi-Color", "Astra 6X", "Litepanels Astra"]),
    ])

    # ARRI SkyPanel S30/S60/S120/S360 & Orbiter
    fixtures.extend([
        build_arri_skypanel("SkyPanel S30-C", 426, 300, 220, 2, ["SkyPanel S30-C", "SkyPanel S30C", "S30-C", "S30C", "skypanel"]),
        build_arri_skypanel("SkyPanel S60-C", 645, 300, 450, 4, ["SkyPanel S60-C", "SkyPanel S60C", "S60-C", "S60C", "skypanel"]),
        build_arri_skypanel("SkyPanel S120-C", 1290, 300, 430, 8, ["SkyPanel S120-C", "SkyPanel S120C", "S120-C", "S120C", "skypanel"]),
        build_arri_skypanel("SkyPanel S360-C", 1280, 1050, 1500, 12, ["SkyPanel S360-C", "SkyPanel S360C", "S360-C", "S360C", "skypanel"]),
        make_film_rgbww_fixture("ARRI", "Orbiter", "spot", 2000, 20000, 343, 386, 500,
                                ["ARRI Orbiter", "Orbiter"], manual_url="https://www.arri.com/en/lighting/led/orbiter"),
    ])

    # Kino Flo FreeStyle, Celeb, Diva-Lite LED, Select
    fixtures.extend([
        make_film_rgbww_fixture("Kino Flo", "FreeStyle 31 LED", "panel", 2500, 9900, 990, 290, 150,
                                ["FreeStyle 31", "Kino Flo FreeStyle 31", "FreeStyle"]),
        make_film_rgbww_fixture("Kino Flo", "FreeStyle T44 LED", "tube", 2500, 9900, 1200, 38, 54,
                                ["FreeStyle T44", "Kino Flo FreeStyle T44"]),
        make_film_rgbww_fixture("Kino Flo", "Celeb 250 LED DMX", "panel", 2500, 9900, 610, 355, 150,
                                ["Celeb 250", "Celeb 250 LED DMX", "Kino Flo Celeb 250"]),
        make_film_rgbww_fixture("Kino Flo", "Celeb 450 LED DMX", "panel", 2500, 9900, 1140, 355, 255,
                                ["Celeb 450", "Celeb 450 LED DMX", "Kino Flo Celeb 450"]),
        make_film_rgbww_fixture("Kino Flo", "Diva-Lite LED 20", "panel", 2500, 9900, 580, 330, 150,
                                ["Diva-Lite LED 20", "Diva-Lite 20", "Kino Flo Diva-Lite"]),
        make_film_rgbww_fixture("Kino Flo", "Select 20 LED", "panel", 2500, 9900, 650, 330, 150,
                                ["Select 20 LED", "Select 30 LED", "Kino Flo Select"]),
    ])

    # Quasar Science Rainbow 2, Double Rainbow, Crossfade X
    fixtures.extend([
        make_film_rgbww_fixture("Quasar Science", "Rainbow 2 (Q50R2)", "tube", 1750, 10000, 1196, 44, 50,
                                ["Rainbow 2", "Q50R2", "Q25R2", "Q100R2", "Quasar Rainbow 2"], pixel_counts=[8, 12, 24]),
        make_film_rgbww_fixture("Quasar Science", "Double Rainbow (RR50)", "tube", 1750, 10000, 573, 76, 50,
                                ["Double Rainbow", "RR50", "RR100", "Quasar Double Rainbow"], pixel_counts=[10, 20]),
        make_film_bicolor_fixture("Quasar Science", "Crossfade X", "tube", 2000, 6000, 1200, 38, 50,
                                  ["Crossfade X", "Quasar Crossfade X"]),
    ])

    # Creamsource Vortex & Rotolight
    fixtures.extend([
        make_film_rgbww_fixture("Creamsource", "Vortex8", "panel", 2200, 15000, 690, 380, 650,
                                ["Vortex8", "Creamsource Vortex8", "Vortex 8"], pixel_counts=[4, 8]),
        make_film_rgbww_fixture("Creamsource", "Vortex4", "panel", 2200, 15000, 380, 380, 325,
                                ["Vortex4", "Creamsource Vortex4", "Vortex 4"], pixel_counts=[4]),
        make_film_rgbww_fixture("Rotolight", "Titan X2", "panel", 2800, 10000, 620, 340, 420,
                                ["Titan X2", "Rotolight Titan X2"]),
        make_film_rgbww_fixture("Rotolight", "Titan X1", "panel", 2800, 10000, 340, 340, 210,
                                ["Titan X1", "Rotolight Titan X1"]),
        make_film_rgbww_fixture("Rotolight", "Anova Pro 3", "panel", 2800, 10000, 490, 430, 220,
                                ["Anova Pro 3", "Rotolight Anova Pro 3"]),
    ])

    return fixtures


# ---------------------------------------------------------------------------
# 4. Generic Templates (preserving all existing IDs & modes + adding requested templates)
# ---------------------------------------------------------------------------


def build_generics():
    base_path = os.path.join(LIB_ROOT, "generic", "generic.json")
    existing = json.load(open(base_path))["fixtures"]
    existing_ids = {f["id"] for f in existing}

    # Enrich generic fixtures with friendlyName and setupGuide (applied after the merge below)
    def enrich(fx):
        if "setupGuide" not in fx:
            fx["setupGuide"] = {
                "addressMenuPath": ["Menu", "DMX Address"],
                "modeMenuPath": ["Menu", "Channel Mode"],
                "factoryDefaults": {"address": 1, "mode": fx["modes"][0]["name"]},
                "connector": "3-pin or 5-pin XLR DMX",
                "addressDisplayFormat": "A001",
                "usesDipSwitches": False,
                "signalLossBehavior": "Hold Last Setting",
                "notes": [fx.get("addressHelp") or "Set the light to the DMX address and channel count shown."],
            }
        for m in fx["modes"]:
            if "friendlyName" not in m and "summary" in m:
                m["friendlyName"] = m["summary"]
            if "fixtureMenuName" not in m and "shortName" in m:
                m["fixtureMenuName"] = m["shortName"]

    extra_generics = [
        {
            "id": "generic.dimmer-pack-4ch",
            "manufacturer": "Generic",
            "model": "4-Channel Dimmer Pack",
            "category": "dimmer",
            "aliases": ["dimmer pack", "4ch dimmer", "4 channel dimmer", "relay pack", "shoebox dimmer"],
            "source": "generic",
            "notes": "4-channel DMX dimmer pack driving up to 4 tungsten or practical lamps.",
            "setupGuide": {
                "addressMenuPath": ["Address Buttons / DIP Switches", "Set Start Address"],
                "modeMenuPath": ["4-Channel Mode"],
                "factoryDefaults": {"address": 1, "mode": "4 Channels"},
                "connector": "3-pin or 5-pin XLR DMX",
                "addressDisplayFormat": "001",
                "usesDipSwitches": True,
                "signalLossBehavior": "Blackout",
                "notes": ["Addresses 4 consecutive DMX channels starting at the pack's base address."],
            },
            "modes": [
                {
                    "name": "4 Channels (Pixels)",
                    "shortName": "4ch",
                    "friendlyName": "4 independent dimmer outputs (recommended)",
                    "fixtureMenuName": "4CH",
                    "summary": "4 individually dimmable outputs",
                    "recommended": True,
                    "pixels": {"count": 4, "channels": ["intensity"]},
                },
                {
                    "name": "1 Channel (All Linked)",
                    "shortName": "1ch",
                    "friendlyName": "All 4 outputs together (1 ch)",
                    "fixtureMenuName": "1CH",
                    "summary": "All outputs controlled by 1 channel",
                    "recommended": False,
                    "channels": ["intensity"],
                },
            ],
        },
        {
            "id": "generic.led-bar",
            "manufacturer": "Generic",
            "model": "LED Pixel Bar / Batten",
            "category": "bar",
            "aliases": ["led bar", "batten", "pixel batten", "rgb bar", "wall washer bar"],
            "source": "generic",
            "physical": {"lengthMM": 1000, "widthMM": 65, "heightMM": 80},
            "modes": [
                {
                    "name": "Dimmer + RGB (Whole Bar)",
                    "shortName": "4ch",
                    "friendlyName": "Whole bar · 1 zone",
                    "fixtureMenuName": "4CH",
                    "summary": "Brightness + RGB across the entire bar",
                    "recommended": False,
                    "channels": ["intensity", "red", "green", "blue"],
                },
                {
                    "name": "8 × RGB Pixels",
                    "shortName": "24ch",
                    "friendlyName": "RGB color · 8 zones (recommended)",
                    "fixtureMenuName": "24CH",
                    "summary": "8 independent RGB zones along the bar",
                    "recommended": True,
                    "pixels": {"count": 8, "channels": ["red", "green", "blue"]},
                },
                {
                    "name": "8 × RGBW Pixels",
                    "shortName": "32ch",
                    "friendlyName": "RGBW color · 8 zones",
                    "fixtureMenuName": "32CH",
                    "summary": "8 independent RGBW zones along the bar",
                    "recommended": False,
                    "pixels": {"count": 8, "channels": ["red", "green", "blue", "white"]},
                },
            ],
        },
        {
            "id": "generic.led-strip",
            "manufacturer": "Generic",
            "model": "LED Strip (DMX Decoder)",
            "category": "strip",
            "aliases": ["led strip", "led tape", "dmx decoder", "rgb strip", "rgbw strip", "cob strip"],
            "source": "generic",
            "physical": {"lengthMM": 2000, "widthMM": 12},
            "modes": [
                {
                    "name": "RGB Strip (3ch)",
                    "shortName": "3ch",
                    "friendlyName": "RGB strip (3 ch)",
                    "fixtureMenuName": "3CH RGB",
                    "summary": "Red, Green, Blue decoder outputs",
                    "recommended": False,
                    "channels": ["red", "green", "blue"],
                },
                {
                    "name": "RGBW Strip (4ch)",
                    "shortName": "4ch",
                    "friendlyName": "RGBW strip (4 ch, recommended)",
                    "fixtureMenuName": "4CH RGBW",
                    "summary": "Red, Green, Blue, White decoder outputs",
                    "recommended": True,
                    "channels": ["red", "green", "blue", "white"],
                },
                {
                    "name": "RGBWW Strip (5ch)",
                    "shortName": "5ch",
                    "friendlyName": "RGB + Warm/Cool White strip (5 ch)",
                    "fixtureMenuName": "5CH RGBWW",
                    "summary": "Red, Green, Blue, Warm White, Cool White decoder outputs",
                    "recommended": False,
                    "channels": ["red", "green", "blue", "warmWhite", "coolWhite"],
                },
            ],
        },
        {
            "id": "generic.fog-haze",
            "manufacturer": "Generic",
            "model": "Fog / Haze Machine",
            "category": "effect",
            "aliases": ["fog", "hazer", "haze machine", "fog machine", "smoke machine", "atmosphere"],
            "source": "generic",
            "modes": [
                {
                    "name": "1-Channel (Output)",
                    "shortName": "1ch",
                    "friendlyName": "Haze / Fog output only",
                    "fixtureMenuName": "1CH",
                    "summary": "Single channel controlling output volume",
                    "recommended": False,
                    "channels": [{"kind": "generic", "label": "Haze Output"}],
                },
                {
                    "name": "2-Channel (Output + Fan)",
                    "shortName": "2ch",
                    "friendlyName": "Haze output + fan speed (recommended)",
                    "fixtureMenuName": "2CH",
                    "summary": "Channel 1: Haze output, Channel 2: Fan speed",
                    "recommended": True,
                    "channels": [
                        {"kind": "generic", "label": "Haze Output"},
                        {"kind": "fan", "label": "Fan Speed", "advanced": False},
                    ],
                },
            ],
        },
    ]

    # Extras replace any stale copy already in generic.json (keeps re-runs idempotent
    # and lets fixes to these definitions take effect).
    extra_by_id = {eg["id"]: eg for eg in extra_generics}
    existing = [extra_by_id.get(fx["id"], fx) for fx in existing]
    for eg in extra_generics:
        if eg["id"] not in existing_ids:
            existing.append(eg)
    for fx in existing:
        enrich(fx)

    return existing


def normalize_fixture_id(fixture_id):
    """`brand.model-slug` with only [a-z0-9-] in each part (e.g. "astera.titan-tube-(fp1)"
    becomes "astera.titan-tube-fp1"). IDs are persisted in shows, so keep this stable."""
    brand, _, model = fixture_id.partition(".")

    def slug(text):
        return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")

    return f"{slug(brand)}.{slug(model)}" if model else slug(brand)


def write_pack(rel_path, fixtures):
    full_path = os.path.join(LIB_ROOT, rel_path)
    os.makedirs(os.path.dirname(full_path), exist_ok=True)
    for fx in fixtures:
        clean = normalize_fixture_id(fx["id"])
        if clean != fx["id"]:
            print(f"  id {fx['id']} -> {clean}")
            fx["id"] = clean
    ids = [fx["id"] for fx in fixtures]
    if len(ids) != len(set(ids)):
        raise SystemExit(f"duplicate fixture ids in {rel_path}")
    payload = {"schemaVersion": 1, "fixtures": fixtures}
    with open(full_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)
    print(f"Wrote {len(fixtures)} fixtures to {rel_path}")


def main():
    write_pack("curated/amaran.json", build_all_amaran())
    write_pack("curated/aputure.json", build_all_aputure())
    write_pack("curated/film_tv.json", build_all_film_tv())
    write_pack("generic/generic.json", build_generics())


if __name__ == "__main__":
    main()
