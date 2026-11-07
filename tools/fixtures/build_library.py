#!/usr/bin/env python3
"""
build_library.py — Builds the complete Prism FixtureLibrary under Resources/FixtureLibrary/:
  1. Runs build_curated.py to generate curated/amaran.json, curated/aputure.json,
     curated/film_tv.json, and generic/generic.json.
  2. Converts Open Fixture Library (MIT) from /home/antigravity/fixture-sources/ofl
     into Resources/FixtureLibrary/ofl/<brand>.json.
  3. Converts QLC+ fixture library (Apache-2.0) from
     /home/antigravity/fixture-sources/qlcplus/resources/fixtures
     into Resources/FixtureLibrary/qlcplus/<brand>.json.
  4. Deduplicates with priority: curated > OFL > QLC+ by normalized (manufacturer, model).
  5. Enforces 1 <= len(mode.channels) <= 512 on every mode.
  6. Writes Resources/FixtureLibrary/index.json ([FixtureLibraryEntry]) for fast lazy loading.

Usage:
    python3 tools/fixtures/build_library.py \
        [--ofl /home/antigravity/fixture-sources/ofl] \
        [--qlc /home/antigravity/fixture-sources/qlcplus/resources/fixtures] \
        [--out Resources/FixtureLibrary]
"""
import argparse
import collections
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import build_curated  # noqa: E402

VALID_CATEGORIES = {
    "tube", "panel", "spot", "fresnel", "par", "bulb", "strip",
    "bar", "wash", "movingHead", "dimmer", "effect", "other",
}

VALID_CHANNEL_KINDS = {
    "intensity", "red", "green", "blue", "white", "warmWhite", "coolWhite",
    "amber", "lime", "cyan", "magenta", "yellow", "uv", "indigo",
    "cct", "tint", "crossfade", "hue", "saturation", "cieX", "cieY", "colorMacro",
    "strobe", "shutter", "zoom", "focus", "iris", "frost", "gobo", "goboRotation",
    "prism", "prismRotation", "blade", "pan", "tilt", "panTiltSpeed",
    "effect", "effectSpeed", "fan", "fog", "rotation", "speed", "control",
    "generic", "nothing",
    # Accepted aliases in FixtureDefinition.swift
    "none", "colorWheel",
}


def slugify(text):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "unknown"


def norm_token(text):
    return re.sub(r"[^a-z0-9]", "", (text or "").lower())


MFR_SYNONYMS = {
    "americandj": "adj",
    "adj": "adj",
    "chauvetdj": "chauvet",
    "chauvetprofessional": "chauvet",
    "chauvetlighting": "chauvet",
    "chauvet": "chauvet",
    "prolights": "prolights",
    "aputure": "aputure",
    "amaran": "amaran",
    "arri": "arri",
    "astera": "astera",
    "asteraledtechnology": "astera",
    "kinoflo": "kinoflo",
    "nanlite": "nanlite",
    "nanguang": "nanlite",
    "godox": "godox",
    "litepanels": "litepanels",
    "quasarscience": "quasarscience",
    "creamsource": "creamsource",
    "rotolight": "rotolight",
    "generic": "generic",
}


def norm_mfr(mfr):
    n = norm_token(mfr)
    return MFR_SYNONYMS.get(n, n)


def norm_model(mfr, model):
    m = norm_token(model)
    mf = norm_token(mfr)
    if mf and m.startswith(mf) and len(m) > len(mf):
        m = m[len(mf):]
    # Normalize SkyPanel S60-C vs S60C, LS C300d vs LS 300d, FP1 Titan Tube vs Titan Tube FP1
    m = re.sub(r"^lsc(\d+)", r"ls\1", m)
    return m


def dedup_keys(mfr, model, aliases=None, fx_id=None):
    keys = set()
    nm = norm_mfr(mfr)
    nmod = norm_model(mfr, model)
    if nm and nmod:
        keys.add((nm, nmod))
    if fx_id:
        keys.add(("id", fx_id))
        if "." in fx_id:
            nslug = norm_model(mfr, fx_id.split(".", 1)[1])
            if nm and nslug:
                keys.add((nm, nslug))
    for al in (aliases or []):
        if "/" in al:
            al = al.split("/", 1)[1]
        nal = norm_model(mfr, al)
        if nm and nal:
            keys.add((nm, nal))
    return keys


def normalize_category(cat):
    if cat == "cob":
        return "spot"
    return cat if cat in VALID_CATEGORIES else "other"


def compute_badge_from_channels(channels):
    """Matches Swift ColorCapabilities.badge logic for FixtureLibraryEntry."""
    kinds = set()
    cells = set()
    for ch in channels:
        if isinstance(ch, str):
            k = ch
            c = None
        else:
            k = ch.get("kind", "generic")
            c = ch.get("cell")
        if k.endswith("Fine") and len(k) > 4:
            k = k[:-4]
        if k == "none":
            k = "nothing"
        if k == "colorWheel":
            k = "colorMacro"
        kinds.add(k)
        if c is not None:
            cells.add(c)
    has_rgb = {"red", "green", "blue"} <= kinds
    has_w = "white" in kinds
    has_ww = "warmWhite" in kinds
    has_cw = "coolWhite" in kinds
    has_a = "amber" in kinds
    has_uv = "uv" in kinds
    has_lime = "lime" in kinds
    has_cmy = {"cyan", "magenta", "yellow"} <= kinds and not has_rgb
    has_cct = "cct" in kinds or (has_ww and has_cw)
    has_hsi = "hue" in kinds and "saturation" in kinds
    has_xy = "cieX" in kinds and "cieY" in kinds

    parts = []
    if has_cct:
        parts.append("CCT")
    if has_rgb:
        s = "RGB"
        if has_w:
            s += "W"
        if has_ww or has_cw:
            s += "WW"
        if has_a:
            s += "A"
        if has_uv:
            s += "UV"
        if has_lime:
            s += "L"
        parts.append(s)
    elif has_cmy:
        parts.append("CMY")
    elif has_hsi:
        parts.append("HSI")
    elif has_xy:
        parts.append("XY")
    elif not has_cct and "intensity" in kinds:
        parts.append("Dimmer")
    if len(cells) > 1:
        parts.append(f"{len(cells)} px")
    return " + ".join(parts) if parts else "DMX"


def compute_badge_for_fixture(fx_dict):
    modes = fx_dict.get("modes", [])
    if not modes:
        return "DMX"
    rec = next((m for m in modes if m.get("recommended")), modes[0])
    chans = list(rec.get("channels", []))
    px = rec.get("pixels")
    if px and px.get("count", 0) > 0:
        for i in range(px["count"]):
            for pch in px.get("channels", []):
                c = {"kind": pch} if isinstance(pch, str) else dict(pch)
                c["cell"] = i
                chans.append(c)
    return compute_badge_from_channels(chans)


def git_commit(path):
    try:
        return subprocess.check_output(["git", "-C", path, "rev-parse", "--short=12", "HEAD"], text=True).strip()
    except Exception:
        return None


# ==============================================================================
# 1. OFL Converter (using /home/antigravity/fixture-sources/convert_ofl.py logic)
# ==============================================================================

def load_ofl_converter(ofl_root):
    # Always the converter next to this script (tools/fixtures/convert_ofl.py), never a copy
    # that happens to sit beside the OFL checkout.
    conv_dir = os.path.dirname(os.path.abspath(__file__))
    if conv_dir not in sys.path:
        sys.path.insert(0, conv_dir)
    import convert_ofl  # noqa: E402
    return convert_ofl


def convert_all_ofl(ofl_root, out_root, seen_models):
    conv = load_ofl_converter(ofl_root)
    fx_dir = os.path.join(ofl_root, "fixtures")
    manufacturers = json.load(open(os.path.join(fx_dir, "manufacturers.json")))
    manufacturers.pop("$schema", None)
    commit = git_commit(ofl_root)

    # First pass: collect redirect aliases (e.g., SameAsDifferentBrand)
    redirects_to = collections.defaultdict(list)
    for man_key in sorted(os.listdir(fx_dir)):
        mdir = os.path.join(fx_dir, man_key)
        if not os.path.isdir(mdir):
            continue
        for fname in sorted(os.listdir(mdir)):
            if not fname.endswith(".json"):
                continue
            raw = json.load(open(os.path.join(mdir, fname)))
            if "redirectTo" in raw:
                redirects_to[raw["redirectTo"]].append(raw.get("name", fname[:-5]))

    ofl_dir = os.path.join(out_root, "ofl")
    if os.path.isdir(ofl_dir):
        shutil.rmtree(ofl_dir)
    os.makedirs(ofl_dir, exist_ok=True)

    entries = []
    stats = {"converted": 0, "skipped_dedup": 0, "skipped_modes": 0}

    for man_key in sorted(os.listdir(fx_dir)):
        mdir = os.path.join(fx_dir, man_key)
        if not os.path.isdir(mdir):
            continue
        brand_fixtures = []
        for fname in sorted(os.listdir(mdir)):
            if not fname.endswith(".json"):
                continue
            fx_key = fname[:-5]
            path = os.path.join(mdir, fname)
            fx = json.load(open(path))
            if "redirectTo" in fx:
                continue

            man_info = manufacturers.get(man_key, {})
            mfr_name = man_info.get("name", man_key)
            model_name = fx["name"]
            aliases = []
            if fx.get("shortName") and fx["shortName"] != model_name:
                aliases.append(fx["shortName"])
            aliases.extend(redirects_to.get(f"{man_key}/{fx_key}", []))

            fx_id = f"{slugify(man_key)}.{slugify(fx_key)}"
            dkeys = dedup_keys(mfr_name, model_name, aliases, fx_id=fx_id)
            if dkeys & seen_models:
                stats["skipped_dedup"] += 1
                continue

            pf = conv.convert_fixture(man_key, fx_key, fx, manufacturers, commit)
            # Filter modes to 1 <= footprint <= 512
            valid_modes = [m for m in pf["modes"] if 1 <= len(m.get("channels", [])) <= 512]
            if not valid_modes:
                stats["skipped_modes"] += 1
                continue

            # Mark recommended mode (first simple/standard mode with color/intensity or first mode)
            rec_idx = 0
            for idx, m in enumerate(valid_modes):
                if m.get("colorModel") not in ("none",) and len(m["channels"]) <= 64:
                    rec_idx = idx
                    break
            valid_modes[rec_idx]["recommended"] = True

            cat = normalize_category(pf["category"])
            aliases_full = list(dict.fromkeys(aliases + [f"{man_key}/{fx_key}"]))

            prism_fx = collections.OrderedDict()
            prism_fx["$schema"] = "prism-fixture/1"
            prism_fx["id"] = fx_id
            prism_fx["manufacturer"] = mfr_name
            prism_fx["model"] = model_name
            prism_fx["category"] = cat
            if aliases_full:
                prism_fx["aliases"] = aliases_full
            if "physical" in pf:
                prism_fx["physical"] = pf["physical"]
            if "pixels" in pf:
                prism_fx["pixels"] = pf["pixels"]
            prism_fx["definitions"] = pf["definitions"]
            prism_fx["modes"] = valid_modes
            prism_fx["source"] = "ofl"
            prism_fx["verification"] = "community"
            prism_fx["sourceInfo"] = {
                "kind": "ofl",
                "license": "MIT",
                "url": pf["source"]["url"],
                "authors": pf["source"].get("authors", []),
                "commit": commit,
            }
            if pf.get("notes"):
                prism_fx["notes"] = pf["notes"]

            brand_fixtures.append(prism_fx)
            seen_models |= dkeys
            stats["converted"] += 1

        if brand_fixtures:
            rel_file = f"ofl/{man_key}.json"
            abs_file = os.path.join(out_root, rel_file)
            payload = {"schemaVersion": 1, "fixtures": brand_fixtures}
            with open(abs_file, "w", encoding="utf-8") as fh:
                json.dump(payload, fh, separators=(",", ":"), ensure_ascii=False)
            for pfx in brand_fixtures:
                # Compute badge using resolved channel kinds
                rec_m = next((m for m in pfx["modes"] if m.get("recommended")), pfx["modes"][0])
                entries.append({
                    "id": pfx["id"],
                    "manufacturer": pfx["manufacturer"],
                    "model": pfx["model"],
                    "category": pfx["category"],
                    "aliases": pfx.get("aliases", []),
                    "modeNames": [m["name"] for m in pfx["modes"]],
                    "badge": compute_badge_from_channels(rec_m["channels"]),
                    "source": "ofl",
                    "file": rel_file,
                })

    return entries, stats


# ==============================================================================
# 2. QLC+ Converter (.qxf XML -> Prism FixtureDefinitionFile)
# ==============================================================================

QLC_NS = "{http://www.qlcplus.org/FixtureDefinition}"

QLC_PRESET_MAP = {
    "IntensityMasterDimmer": ("intensity", False),
    "IntensityMasterDimmerFine": ("intensity", True),
    "IntensityDimmer": ("intensity", False),
    "IntensityDimmerFine": ("intensity", True),
    "IntensityRed": ("red", False),
    "IntensityRedFine": ("red", True),
    "IntensityGreen": ("green", False),
    "IntensityGreenFine": ("green", True),
    "IntensityBlue": ("blue", False),
    "IntensityBlueFine": ("blue", True),
    "IntensityCyan": ("cyan", False),
    "IntensityCyanFine": ("cyan", True),
    "IntensityMagenta": ("magenta", False),
    "IntensityMagentaFine": ("magenta", True),
    "IntensityYellow": ("yellow", False),
    "IntensityYellowFine": ("yellow", True),
    "IntensityAmber": ("amber", False),
    "IntensityAmberFine": ("amber", True),
    "IntensityWhite": ("white", False),
    "IntensityWhiteFine": ("white", True),
    "IntensityUV": ("uv", False),
    "IntensityUVFine": ("uv", True),
    "IntensityIndigo": ("indigo", False),
    "IntensityIndigoFine": ("indigo", True),
    "IntensityLime": ("lime", False),
    "IntensityLimeFine": ("lime", True),
    "IntensityHue": ("hue", False),
    "IntensityHueFine": ("hue", True),
    "IntensitySaturation": ("saturation", False),
    "IntensitySaturationFine": ("saturation", True),
    "IntensityLightness": ("intensity", False),
    "IntensityLightnessFine": ("intensity", True),
    "IntensityValue": ("intensity", False),
    "IntensityValueFine": ("intensity", True),
    "PositionPan": ("pan", False),
    "PositionPanFine": ("pan", True),
    "PositionTilt": ("tilt", False),
    "PositionTiltFine": ("tilt", True),
    "PositionXAxis": ("pan", False),
    "PositionYAxis": ("tilt", False),
    "SpeedPanSlowFast": ("panTiltSpeed", False),
    "SpeedPanFastSlow": ("panTiltSpeed", False),
    "SpeedTiltSlowFast": ("panTiltSpeed", False),
    "SpeedTiltFastSlow": ("panTiltSpeed", False),
    "SpeedPanTiltSlowFast": ("panTiltSpeed", False),
    "SpeedPanTiltFastSlow": ("panTiltSpeed", False),
    "ColorMacro": ("colorMacro", False),
    "ColorDoubleMacro": ("colorMacro", False),
    "ColorWheel": ("colorMacro", False),
    "ColorWheelFine": ("colorMacro", True),
    "ColorRGBMixer": ("hue", False),
    "ColorCTOMixer": ("cct", False),
    "ColorCTCMixer": ("cct", False),
    "ColorCTBMixer": ("cct", False),
    "GoboWheel": ("gobo", False),
    "GoboWheelFine": ("gobo", True),
    "GoboIndex": ("goboRotation", False),
    "GoboIndexFine": ("goboRotation", True),
    "ShutterStrobeSlowFast": ("strobe", False),
    "ShutterStrobeFastSlow": ("strobe", False),
    "ShutterIrisMinToMax": ("iris", False),
    "ShutterIrisMaxToMin": ("iris", False),
    "ShutterIrisFine": ("iris", True),
    "BeamFocusNearFar": ("focus", False),
    "BeamFocusFarNear": ("focus", False),
    "BeamFocusFine": ("focus", True),
    "BeamZoomSmallBig": ("zoom", False),
    "BeamZoomBigSmall": ("zoom", False),
    "BeamZoomFine": ("zoom", True),
    "PrismRotationSlowFast": ("prismRotation", False),
    "PrismRotationFastSlow": ("prismRotation", False),
    "NoFunction": ("nothing", False),
}

QLC_COLOUR_MAP = {
    "Red": "red",
    "Green": "green",
    "Blue": "blue",
    "Cyan": "cyan",
    "Magenta": "magenta",
    "Yellow": "yellow",
    "Amber": "amber",
    "White": "white",
    "Warm White": "warmWhite",
    "Cold White": "coolWhite",
    "UV": "uv",
    "Lime": "lime",
    "Indigo": "indigo",
}

QLC_GROUP_MAP = {
    "Intensity": "intensity",
    "Colour": "colorMacro",
    "Gobo": "gobo",
    "Prism": "prism",
    "Beam": "zoom",
    "Shutter": "strobe",
    "Speed": "effectSpeed",
    "Effect": "effect",
    "Maintenance": "control",
    "Pan": "pan",
    "Tilt": "tilt",
    "Nothing": "nothing",
}

QLC_NAME_RULES = [
    ("warmWhite", re.compile(r"\b(warm\s*white|ww)\b", re.I)),
    ("coolWhite", re.compile(r"\b(cold\s*white|cool\s*white|cw)\b", re.I)),
    ("tint", re.compile(r"(\btint\b|green\s*[-/]?\s*magenta|\bg/m\b|\bgm\b|minus\s*green|plus\s*green)", re.I)),
    ("crossfade", re.compile(r"(cross\s*-?\s*fade|x-?fade|(cct|white)\s*(<->|/|to)\s*(rgb|colou?r))", re.I)),
    ("hue", re.compile(r"\bhue\b", re.I)),
    ("saturation", re.compile(r"\bsat(uration)?\b", re.I)),
    ("cieX", re.compile(r"(\bcie\s*x\b|^x\s*coord)", re.I)),
    ("cieY", re.compile(r"(\bcie\s*y\b|^y\s*coord)", re.I)),
    ("cct", re.compile(r"(\bcct\b|kelvin|colou?r\s*temp|\bcto\b|\bctb\b|\bctc\b)", re.I)),
    ("fan", re.compile(r"\bfan\b", re.I)),
    ("fog", re.compile(r"\b(fog|smoke|haze|blower)\b", re.I)),
    ("frost", re.compile(r"\bfrost\b", re.I)),
    ("iris", re.compile(r"\biris\b", re.I)),
    ("focus", re.compile(r"\bfocus\b", re.I)),
    ("zoom", re.compile(r"\bzoom\b", re.I)),
    ("strobe", re.compile(r"\b(strobe|flash)\b", re.I)),
    ("shutter", re.compile(r"\bshutter\b", re.I)),
    ("panTiltSpeed", re.compile(r"(pan.*tilt.*speed|p/t\s*speed|movement\s*speed)", re.I)),
    ("goboRotation", re.compile(r"gobo.*(rot|index)", re.I)),
    ("prismRotation", re.compile(r"prism.*(rot|index)", re.I)),
    ("control", re.compile(r"(reset|control|function|dimmer\s*curve|dimmer\s*mode|special)", re.I)),
]

QLC_OFF_RE = re.compile(
    r"\b(off|stop|no\s*(function|effect|strobe|macro|rotation)|none|disabled|open|normal|neutral)\b",
    re.I,
)
QLC_DANGER_RE = re.compile(r"\b(reset|lamp\s*(on|off)|calibrat|firmware|store|save)\b", re.I)
QLC_KELVIN_RE = re.compile(r"(\d{4,5})\s*K?\s*(?:\.\.+|-|–|to)\s*(\d{4,5})\s*K", re.I)


def qlc_channel_spec(ch_elem):
    name = (ch_elem.get("Name") or "Channel").strip()
    preset = (ch_elem.get("Preset") or "").strip()
    grp_elem = ch_elem.find(QLC_NS + "Group")
    group = grp_elem.text.strip() if (grp_elem is not None and grp_elem.text) else ""
    byte = int(grp_elem.get("Byte", "0")) if grp_elem is not None else 0
    colour = (ch_elem.findtext(QLC_NS + "Colour") or "").strip()
    default_attr = ch_elem.get("Default")

    fine = (byte > 0)
    kind = "generic"

    if preset and preset in QLC_PRESET_MAP:
        kind, preset_fine = QLC_PRESET_MAP[preset]
        fine = fine or preset_fine
    elif group == "Intensity" and colour in QLC_COLOUR_MAP:
        kind = QLC_COLOUR_MAP[colour]
    elif group in QLC_GROUP_MAP:
        kind = QLC_GROUP_MAP[group]

    # Refine weak kinds by channel name
    if kind in ("generic", "intensity", "colorMacro", "effect", "effectSpeed", "zoom", "strobe", "control", "white"):
        for rkind, rx in QLC_NAME_RULES:
            if kind == "intensity" and rkind not in ("warmWhite", "coolWhite", "cct", "tint", "hue", "saturation", "crossfade"):
                continue
            if kind == "white" and rkind not in ("warmWhite", "coolWhite"):
                continue
            if rx.search(name):
                kind = rkind
                break

    if re.search(r"\bfine\b|\b16\s*-?\s*bit\b|\blsb\b", name, re.I) and byte > 0:
        fine = True

    caps_out = []
    phys_range = None
    for cap in ch_elem.findall(QLC_NS + "Capability"):
        cmin = int(cap.get("Min", "0"))
        cmax = int(cap.get("Max", "255"))
        cpreset = (cap.get("Preset") or "").strip()
        label = (cap.text or "").strip()
        entry = {"name": label or cpreset or kind, "range": [cmin, cmax]}
        if cpreset == "ShutterOpen":
            entry["kind"] = "open"
        elif cpreset == "ShutterClose":
            entry["kind"] = "closed"
        elif cpreset.startswith("Strobe") or cpreset.startswith("Pulse") or cpreset.startswith("Ramp"):
            entry["kind"] = "strobe"
        if kind == "cct" and phys_range is None:
            m = QLC_KELVIN_RE.search(label)
            if m:
                phys_range = [float(m.group(1)), float(m.group(2))]
        caps_out.append(entry)

    # Compute safe default value
    if default_attr is not None and default_attr.isdigit():
        default_val = max(0, min(255, int(default_attr)))
    elif kind in ("pan", "tilt") and not fine:
        default_val = 128
    elif kind == "tint" and not fine:
        default_val = 128
    elif kind in ("strobe", "shutter", "effect", "effectSpeed", "control", "colorMacro", "gobo", "prism", "fan", "fog"):
        default_val = 0
        for c in caps_out:
            if c.get("kind") == "open":
                default_val = c["range"][0]
                break
        else:
            for c in caps_out:
                lbl = c.get("name", "")
                if QLC_OFF_RE.search(lbl) and not QLC_DANGER_RE.search(lbl):
                    default_val = c["range"][0]
                    break
            else:
                if caps_out and QLC_DANGER_RE.search(caps_out[0].get("name", "")):
                    for c in caps_out:
                        if not QLC_DANGER_RE.search(c.get("name", "")):
                            default_val = c["range"][0]
                            break
    else:
        default_val = 0

    spec = {"name": name, "kind": kind}
    if fine:
        spec["fine"] = True
    if default_val != 0:
        spec["default"] = default_val
    if phys_range:
        spec["physical"] = phys_range
    if len(caps_out) > 1 or (len(caps_out) == 1 and kind in ("strobe", "shutter", "effect", "control", "colorMacro")):
        # Keep capabilities compact (strip transient 'kind' helper)
        spec["capabilities"] = [{"label": c["name"], "range": c["range"]} for c in caps_out[:32]]
    if kind in ("control", "effect", "effectSpeed", "panTiltSpeed", "fan"):
        spec["advanced"] = True
    return spec


FINE_WORDS = re.compile(r"\bfine\b|\blsb\b|16\s*-?\s*bits?\b|\blow\s*byte\b|\(f\)", re.I)
LABEL_NOISE = {"fine", "lsb", "bit", "bits", "the", "and", "of", "ch", "channel", "byte", "low"}


def _label_words(text):
    return {w for w in re.findall(r"[a-z]+", (text or "").lower()) if w not in LABEL_NOISE and len(w) > 1}


def repair_qlc_fine_channels(ch_list):
    """Fix QLC+ fine (LSB) flags the Prism renderer could never honour.

    Prism drives a fine channel only when it directly follows a coarse channel of the same
    kind and cell. Some QLC+ profiles flag ordinary channels as fine ("Auto Program" with
    Byte=1, "Blue Fine" in a profile with no Blue) or file a fine channel in the wrong group
    ("Tilt Fine" in the Pan group). Unrepaired, those channels would sit at 0 forever.
    Returns the number of channels changed.
    """
    changed = 0
    for i, ch in enumerate(ch_list):
        if not ch.get("fine"):
            continue
        prev = ch_list[i - 1] if i > 0 else None
        same_role = prev is not None and prev.get("kind") == ch.get("kind") and prev.get("cell") == ch.get("cell")
        if same_role and not prev.get("fine"):
            continue  # correctly paired with the coarse channel before it
        label = ch.get("name", "")
        if same_role:
            continue  # extra precision byte (24-bit); harmless, stays at its default
        if not FINE_WORDS.search(label):
            ch.pop("fine", None)  # an ordinary channel mis-flagged as fine
            changed += 1
            continue
        if prev is not None and not prev.get("fine"):
            words, prev_words = _label_words(label), _label_words(prev.get("name", ""))
            if not words or words & prev_words:
                # "Tilt Fine" filed under Pan right after "Tilt": follow the coarse channel.
                ch["kind"] = prev.get("kind")
                if "cell" in prev:
                    ch["cell"] = prev["cell"]
                else:
                    ch.pop("cell", None)
                changed += 1
                continue
        has_coarse = any(not c.get("fine") and c.get("kind") == ch.get("kind") and c.get("cell") == ch.get("cell")
                         for c in ch_list)
        if not has_coarse:
            ch.pop("fine", None)  # "Blue Fine" with no Blue channel: it is the Blue channel
            changed += 1
    return changed


def qlc_category(qtype, model_name, all_kinds, phys):
    if "pan" in all_kinds or "tilt" in all_kinds or qtype in ("Moving Head", "Scanner"):
        return "movingHead"
    if qtype in ("Smoke", "Hazer", "Fan", "Laser", "Flower", "Strobe", "Effect") or "fog" in all_kinds:
        return "effect"
    low = model_name.lower()
    if re.search(r"\b(tube|titan|helios|hyperion|pavotube|t12|t8)\b", low):
        return "tube"
    if re.search(r"\b(fresnel|ecl\s*fresnel|dw\s*fresnel)\b", low):
        return "fresnel"
    if re.search(r"\b(panel|softlight|soft\s*panel|1x1|2x1)\b", low):
        return "panel"
    if re.search(r"\b(par|slimpar|colorband\s*par|party\s*par|led\s*par|flat\s*par)\b", low):
        return "par"
    if re.search(r"\b(strip|tape|flex)\b", low):
        return "strip"
    if qtype in ("LED Bar (Beams)", "LED Bar (Pixels)") or re.search(r"\b(bar|batten|pixbar|colorband|cyc)\b", low):
        return "bar"
    if re.search(r"\b(profile|leko|source\s*four|ellipsoidal|spot)\b", low):
        return "spot"
    if qtype == "Dimmer":
        return "dimmer" if all_kinds <= {"intensity", "nothing"} else "other"
    if qtype == "Color Changer":
        return "wash"
    return "other"


def convert_all_qlc(qlc_root, out_root, seen_models):
    commit = git_commit(qlc_root)
    qlc_dir = os.path.join(out_root, "qlcplus")
    if os.path.isdir(qlc_dir):
        shutil.rmtree(qlc_dir)
    os.makedirs(qlc_dir, exist_ok=True)

    files = sorted(glob.glob(os.path.join(qlc_root, "*", "*.qxf")))
    by_brand = collections.defaultdict(list)
    entries = []
    stats = {"converted": 0, "skipped_dedup": 0, "skipped_modes": 0, "parse_errors": 0}
    used_ids = set()

    for fpath in files:
        try:
            root = ET.parse(fpath).getroot()
        except ET.ParseError:
            stats["parse_errors"] += 1
            continue

        mfr = (root.findtext(QLC_NS + "Manufacturer") or "").strip()
        model = (root.findtext(QLC_NS + "Model") or "").strip()
        qtype = (root.findtext(QLC_NS + "Type") or "Other").strip()
        author_str = (root.findtext(QLC_NS + "Creator/" + QLC_NS + "Author") or "").strip()
        authors = [a.strip() for a in re.split(r"[,;&/]| and ", author_str) if a.strip()]

        if not mfr or not model:
            continue

        brand_slug = slugify(mfr)
        model_slug = slugify(model)
        fx_id = f"{brand_slug}.{model_slug}"
        dkeys = dedup_keys(mfr, model, fx_id=fx_id)
        if dkeys & seen_models:
            stats["skipped_dedup"] += 1
            continue

        # Parse channels
        ch_by_name = {}
        for ch_elem in root.findall(QLC_NS + "Channel"):
            cname = (ch_elem.get("Name") or "").strip()
            if cname:
                ch_by_name[cname] = qlc_channel_spec(ch_elem)

        # Parse physical
        phys_elem = root.find(QLC_NS + "Physical")
        phys_spec = {}
        layout_wh = None
        if phys_elem is not None:
            dims = phys_elem.find(QLC_NS + "Dimensions")
            if dims is not None:
                w = float(dims.get("Width", "0") or 0)
                h = float(dims.get("Height", "0") or 0)
                d = float(dims.get("Depth", "0") or 0)
                wt = float(dims.get("Weight", "0") or 0)
                if w > 0:
                    phys_spec["lengthMM"] = w
                if h > 0:
                    phys_spec["widthMM"] = h
                if d > 0:
                    phys_spec["heightMM"] = d
                if wt > 0:
                    phys_spec["weightKg"] = wt
            tech = phys_elem.find(QLC_NS + "Technical")
            if tech is not None:
                pw = float(tech.get("PowerConsumption", "0") or 0)
                conn = (tech.get("DmxConnector") or "").strip()
                if pw > 0:
                    phys_spec["powerW"] = pw
                if conn:
                    phys_spec["dmxConnector"] = conn
            lens = phys_elem.find(QLC_NS + "Lens")
            if lens is not None:
                dmax = float(lens.get("DegreesMax", "0") or 0)
                if dmax > 0:
                    phys_spec["beamDegrees"] = dmax
            lay = phys_elem.find(QLC_NS + "Layout")
            if lay is not None:
                lw = int(lay.get("Width", "0") or 0)
                lh = int(lay.get("Height", "0") or 0)
                if lw > 1 and lh > 1:
                    layout_wh = (lw, lh)

        # Parse modes
        modes_out = []
        all_kinds = set()
        seen_mode_names = set()
        for m_elem in root.findall(QLC_NS + "Mode"):
            mname = (m_elem.get("Name") or "Default").strip() or "Default"
            # Patches refer to modes by name, so repeated names get a number.
            base_mname, n_dup = mname, 2
            while mname in seen_mode_names:
                mname = f"{base_mname} ({n_dup})"
                n_dup += 1
            seen_mode_names.add(mname)
            m_ch_elems = m_elem.findall(QLC_NS + "Channel")
            if not (1 <= len(m_ch_elems) <= 512):
                continue

            # Map channel index -> head (cell) index if <Head> elements exist
            heads = m_elem.findall(QLC_NS + "Head")
            slot_to_cell = {}
            if len(heads) > 1:
                for cell_idx, h_elem in enumerate(heads):
                    for hc in h_elem.findall(QLC_NS + "Channel"):
                        if hc.text and hc.text.strip().isdigit():
                            slot_to_cell[int(hc.text.strip())] = cell_idx

            ch_list = []
            for idx, mc in enumerate(m_ch_elems):
                cname = (mc.text or "").strip()
                base = ch_by_name.get(cname, {"name": cname or f"Ch {idx + 1}", "kind": "generic"})
                ch_copy = dict(base)
                if idx in slot_to_cell:
                    ch_copy["cell"] = slot_to_cell[idx]
                    if slot_to_cell[idx] > 0:
                        ch_copy.pop("capabilities", None)
                ch_list.append(ch_copy)
                all_kinds.add(ch_copy["kind"])

            stats["repaired_fine"] = stats.get("repaired_fine", 0) + repair_qlc_fine_channels(ch_list)
            mode_obj = {
                "name": mname,
                "channels": ch_list,
            }
            if len(heads) > 1 and layout_wh and layout_wh[0] * layout_wh[1] == len(heads):
                mode_obj["cellLayout"] = {"type": "grid", "columns": layout_wh[0], "rows": layout_wh[1]}
            modes_out.append(mode_obj)

        if not modes_out:
            stats["skipped_modes"] += 1
            continue

        # Mark recommended mode
        rec_idx = 0
        for idx, m in enumerate(modes_out):
            kinds = {c["kind"] for c in m["channels"]}
            if ({"red", "green", "blue"} <= kinds or "cct" in kinds or "intensity" in kinds) and len(m["channels"]) <= 32:
                rec_idx = idx
                break
        modes_out[rec_idx]["recommended"] = True

        cat = qlc_category(qtype, model, all_kinds, phys_spec)
        if fx_id in used_ids:
            suffix = 2
            while f"{fx_id}-{suffix}" in used_ids:
                suffix += 1
            fx_id = f"{fx_id}-{suffix}"
        used_ids.add(fx_id)

        fx_obj = collections.OrderedDict()
        fx_obj["id"] = fx_id
        fx_obj["manufacturer"] = mfr
        fx_obj["model"] = model
        fx_obj["category"] = cat
        if phys_spec:
            fx_obj["physical"] = phys_spec
        fx_obj["modes"] = modes_out
        fx_obj["source"] = "qlcplus"
        fx_obj["verification"] = "community"
        fx_obj["sourceInfo"] = {
            "kind": "qlcplus",
            "license": "Apache-2.0",
            "authors": authors,
            "commit": commit,
        }

        by_brand[brand_slug].append(fx_obj)
        seen_models |= dkeys
        stats["converted"] += 1

    for brand_slug in sorted(by_brand):
        brand_fixtures = by_brand[brand_slug]
        rel_file = f"qlcplus/{brand_slug}.json"
        abs_file = os.path.join(out_root, rel_file)
        payload = {"schemaVersion": 1, "fixtures": brand_fixtures}
        with open(abs_file, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, separators=(",", ":"), ensure_ascii=False)
        for fx_obj in brand_fixtures:
            rec_m = next((m for m in fx_obj["modes"] if m.get("recommended")), fx_obj["modes"][0])
            entries.append({
                "id": fx_obj["id"],
                "manufacturer": fx_obj["manufacturer"],
                "model": fx_obj["model"],
                "category": fx_obj["category"],
                "aliases": fx_obj.get("aliases", []),
                "modeNames": [m["name"] for m in fx_obj["modes"]],
                "badge": compute_badge_from_channels(rec_m["channels"]),
                "source": "qlcplus",
                "file": rel_file,
            })

    return entries, stats


# ==============================================================================
# 3. Main Pipeline
# ==============================================================================

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ofl", default="/home/antigravity/fixture-sources/ofl")
    ap.add_argument("--qlc", default="/home/antigravity/fixture-sources/qlcplus/resources/fixtures")
    ap.add_argument("--out", default=os.path.join(REPO_ROOT, "Resources", "FixtureLibrary"))
    args = ap.parse_args()

    out_root = os.path.abspath(args.out)
    # 1. Build curated & generic packs
    build_curated.main()

    # Compact curated & generic files and collect their entries + deduplication keys
    seen_models = set()
    all_entries = []
    curated_count = 0

    for sub in ("curated", "generic"):
        sub_dir = os.path.join(out_root, sub)
        if not os.path.isdir(sub_dir):
            continue
        for fname in sorted(os.listdir(sub_dir)):
            if not fname.endswith(".json"):
                continue
            rel_file = f"{sub}/{fname}"
            abs_file = os.path.join(out_root, rel_file)
            data = json.load(open(abs_file, encoding="utf-8"))
            # Re-write compact JSON to save repo space while remaining valid UTF-8
            with open(abs_file, "w", encoding="utf-8") as fh:
                json.dump(data, fh, separators=(",", ":"), ensure_ascii=False)
            for fx in data.get("fixtures", []):
                curated_count += 1
                seen_models |= dedup_keys(fx["manufacturer"], fx["model"], fx.get("aliases", []), fx_id=fx["id"])
                all_entries.append({
                    "id": fx["id"],
                    "manufacturer": fx["manufacturer"],
                    "model": fx["model"],
                    "category": normalize_category(fx["category"]),
                    "aliases": fx.get("aliases", []),
                    "modeNames": [m["name"] for m in fx["modes"]],
                    "badge": compute_badge_for_fixture(fx),
                    "source": fx.get("source", sub),
                    "file": rel_file,
                })

    # 2. Convert OFL
    ofl_entries, ofl_stats = convert_all_ofl(args.ofl, out_root, seen_models)
    all_entries.extend(ofl_entries)

    # 3. Convert QLC+
    qlc_entries, qlc_stats = convert_all_qlc(args.qlc, out_root, seen_models)
    all_entries.extend(qlc_entries)

    # 4. Write compact index.json
    index_path = os.path.join(out_root, "index.json")
    with open(index_path, "w", encoding="utf-8") as fh:
        json.dump(all_entries, fh, separators=(",", ":"), ensure_ascii=False)

    total_bytes = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, fs in os.walk(out_root)
        for f in fs
    )
    print(f"Curated + Generic fixtures: {curated_count}")
    print(f"OFL fixtures: {ofl_stats}")
    print(f"QLC+ fixtures: {qlc_stats}")
    print(f"Total index entries: {len(all_entries)}")
    print(f"Total FixtureLibrary size: {total_bytes / (1024 * 1024):.2f} MB")


if __name__ == "__main__":
    main()
