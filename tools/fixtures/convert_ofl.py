#!/usr/bin/env python3
"""
convert_ofl.py -- PROTOTYPE converter: Open Fixture Library (OFL, MIT) -> Prism
normalized fixture schema ("prism-fixture/1", see
StudioLightingMac/docs/research/fixture_libraries.md, section 5).

Usage:
    python3 convert_ofl.py --ofl ./ofl --out ./prism-out [--pretty] [--only aputure,arri]

Output layout (index + lazy-load):
    out/index.json                       compact search index, one row per fixture
    out/manufacturers.json               manufacturer key -> {name, website, rdmId, count}
    out/fixtures/<mfr>/<model>.json      one Prism fixture definition per file
    out/stats.json                       conversion statistics (used by the research doc)
    out/LICENSE-OFL.txt                  copy of OFL's MIT license (must ship with the data)

Pure Python 3 standard library; no third-party dependencies.
"""
import argparse
import collections
import gzip
import json
import os
import re
import shutil
import subprocess
import sys

SCHEMA_ID = "prism-fixture/1"

# --------------------------------------------------------------------------------------
# Generic helpers
# --------------------------------------------------------------------------------------

_DIGITS = re.compile(r"(\d+)")


def natural_key(value):
    """Approximates JS `a.localeCompare(b, undefined, {numeric: true})` used by OFL."""
    return [(0, int(tok), "") if tok.isdigit() else (1, 0, tok.lower())
            for tok in _DIGITS.split(str(value)) if tok != ""]


def strip_pixel_var(text):
    return re.sub(r"\s*\$pixelKey\s*", " ", text).strip() if text else text


# --------------------------------------------------------------------------------------
# OFL entities / units (see ofl/docs/capability-types.md and schemas/definitions.json)
# --------------------------------------------------------------------------------------

UNIT_RE = re.compile(r"^(-?\d+(?:\.\d+)?)(Hz|bpm|rpm|%|K|deg|ms|s|m\^3/min|m|lm)?$")

KEYWORDS = {
    "speed": {"fast": 100, "slow": 1, "stop": 0, "slow reverse": -1, "fast reverse": -100},
    "rotationSpeed": {"fast CW": 100, "slow CW": 1, "stop": 0, "slow CCW": -1, "fast CCW": -100},
    "time": {"instant": 0, "short": 1, "long": 100},
    "distance": {"near": 1, "far": 100},
    "brightness": {"off": 0, "dark": 1, "bright": 100},
    "colorTemperature": {"warm": -100, "CTO": -100, "default": 0, "cold": 100, "CTB": 100},
    "fogOutput": {"off": 0, "weak": 1, "strong": 100},
    "beamAngle": {"closed": 0, "narrow": 1, "wide": 100},
    "horizontalAngle": {"left": -100, "center": 0, "right": 100},
    "verticalAngle": {"top": -100, "center": 0, "bottom": 100},
    "swingAngle": {"closed": 0, "narrow": 1, "wide": 100},
    "parameter": {"off": 0, "instant": 0, "low": 1, "slow": 1, "small": 1, "short": 1,
                  "high": 100, "fast": 100, "big": 100, "long": 100},
    "percent": {"off": 0, "low": 1, "high": 100},
    "insertion": {"out": 0, "in": 100},
    "irisPercent": {"closed": 0, "open": 100},
}

ROTATION_TYPES = {"PanContinuous", "TiltContinuous", "WheelRotation", "WheelSlotRotation",
                  "PrismRotation", "Prism", "Rotation"}
ANGLE_ROTATION_TYPES = {"Pan", "Tilt", "WheelSlotRotation", "WheelRotation", "Prism",
                        "PrismRotation", "Rotation", "BladeRotation", "BladeSystemRotation"}


def entity_for(prop, cap_type):
    if prop in ("speed", "shakeSpeed"):
        return "rotationSpeed" if (prop == "speed" and cap_type in ROTATION_TYPES) else "speed"
    if prop == "angle":
        return "rotationAngle" if cap_type in ANGLE_ROTATION_TYPES else "beamAngle"
    return {
        "duration": "time", "time": "time", "hold": "time", "brightness": "brightness",
        "colorTemperature": "colorTemperature", "distance": "distance",
        "horizontalAngle": "horizontalAngle", "verticalAngle": "verticalAngle",
        "shakeAngle": "swingAngle", "soundSensitivity": "percent", "frostIntensity": "percent",
        "openPercent": "irisPercent", "insertion": "insertion", "fogOutput": "fogOutput",
        "parameter": "parameter", "slotNumber": "slotNumber",
    }.get(prop, "parameter")


UNIT_NORMALIZE = {"deg": "deg", "%": "%", "K": "K", "Hz": "Hz", "bpm": "bpm", "rpm": "rpm",
                  "s": "s", "ms": "ms", "m": "m", "lm": "lm", "m^3/min": "m3/min", None: None}


def parse_entity(value, prop, cap_type):
    """Returns (number, unit) with OFL keywords normalised to percent."""
    if isinstance(value, bool):
        return (1 if value else 0, None)
    if isinstance(value, (int, float)):
        return (value, None)
    ent = entity_for(prop, cap_type)
    kw = KEYWORDS.get(ent, {})
    if value in kw:
        return (kw[value], "%")
    m = UNIT_RE.match(str(value))
    if not m:
        return (None, None)
    num = float(m.group(1))
    if num.is_integer():
        num = int(num)
    return (num, UNIT_NORMALIZE.get(m.group(2), m.group(2)))


def range_prop(cap, prop):
    """(start, end) raw values for a start/end capable property, or None."""
    if prop in cap:
        return (cap[prop], cap[prop])
    if prop + "Start" in cap:
        return (cap[prop + "Start"], cap[prop + "End"])
    return None


# Comment parsing for `Generic` capabilities, e.g. "-99%…100%", "0…360°", "2000K - 10000K"
COMMENT_RANGE_RE = re.compile(
    r"(-?\d+(?:\.\d+)?)\s*(%|°|deg|K|Hz)?\s*(?:…|\.\.\.?|–|—|-|to|→|~)\s*"
    r"(-?\d+(?:\.\d+)?)\s*(%|°|deg|K|Hz)", re.I)


def parse_comment_range(text):
    if not text:
        return None
    m = COMMENT_RANGE_RE.search(text)
    if not m:
        return None
    unit = m.group(4) or m.group(2)
    unit = {"°": "deg", "deg": "deg", "k": "K", "hz": "Hz"}.get(unit.lower(), unit)
    a, b = float(m.group(1)), float(m.group(3))
    a = int(a) if a.is_integer() else a
    b = int(b) if b.is_integer() else b
    return (a, b, unit)


# unitless ranges such as "0 … 0.8" (CIE 1931 x/y coordinates)
UNITLESS_RANGE_RE = re.compile(r"(\d*\.?\d+)\s*(?:…|\.\.\.?|–|—|-|to|→|~)\s*(\d*\.?\d+)")
# Assumed physical ranges for kinds OFL can only express as Generic/Intensity
DEFAULT_RANGES = {"hue": (0, 360, "deg"), "saturation": (0, 100, "%"), "crossfade": (0, 100, "%")}


# --------------------------------------------------------------------------------------
# OFL matrix model (port of ofl/lib/model/Matrix.js)
# --------------------------------------------------------------------------------------

class Matrix:
    def __init__(self, j):
        self.j = j
        if "pixelKeys" in j:
            self.structure = j["pixelKeys"]
            z = len(self.structure)
            y = max(len(yy) for yy in self.structure)
            x = max(len(xx) for yy in self.structure for xx in yy)
            self.count = [x, y, z]
            self.custom_keys = True
        else:
            self.count = list(j["pixelCount"])
            self.custom_keys = False
            self.structure = self._default_structure()
        self.positions = {}
        for zi, yy in enumerate(self.structure):
            for yi, xx in enumerate(yy):
                for xi, key in enumerate(xx):
                    if key is not None:
                        self.positions[key] = (xi + 1, yi + 1, zi + 1)
        self.pixel_keys = sorted(self.positions, key=natural_key)
        self.groups = self._compute_groups()

    def _default_structure(self):
        x, y, z = self.count
        axes = [a for a, c in zip("XYZ", self.count) if c > 1]

        def key(px, py, pz):
            if len(axes) == 1:
                return str(max(px, py, pz))
            if len(axes) == 2:
                first = px if "X" in axes else py
                last = py if "Y" in axes else pz
                return "(%d, %d)" % (first, last)
            if len(axes) == 3:
                return "(%d, %d, %d)" % (px, py, pz)
            return "1"
        return [[[key(px, py, pz) for px in range(1, x + 1)] for py in range(1, y + 1)]
                for pz in range(1, z + 1)]

    def by_order(self, first, second, third):
        idx = {"X": 0, "Y": 1, "Z": 2}
        a, b, c = idx[first], idx[second], idx[third]
        return sorted(self.pixel_keys,
                      key=lambda k: (self.positions[k][c], self.positions[k][b], self.positions[k][a]))

    @staticmethod
    def _num_constraint(con):
        if con.startswith(">="):
            n = int(con[2:])
            return lambda p: p >= n
        if con.startswith("<="):
            n = int(con[2:])
            return lambda p: p <= n
        if con.startswith("="):
            n = int(con[1:])
            return lambda p: p == n
        con = {"even": "2n", "odd": "2n+1"}.get(con, con)
        m = re.match(r"^(\d+)n(?:\+(\d+))?$", con)
        if m:
            div, rem = int(m.group(1)), int(m.group(2) or 0)
            return lambda p: p % div == rem
        raise ValueError("bad pixel constraint %r" % con)

    def _compute_groups(self):
        out = collections.OrderedDict()
        for gk, g in self.j.get("pixelGroups", {}).items():
            if isinstance(g, list):
                out[gk] = list(g)
            elif g == "all":
                out[gk] = list(self.pixel_keys)
            else:
                base = self.pixel_keys if "name" in g else self.by_order("X", "Y", "Z")
                funcs = {ax: [self._num_constraint(c) for c in g.get(ax, [])] for ax in "xyz"}
                names = [re.compile(p) for p in g.get("name", [])]
                keep = []
                for k in base:
                    pos = self.positions[k]
                    if all(f(pos[i]) for i, ax in enumerate("xyz") for f in funcs[ax]) and \
                            all(r.search(k) for r in names):
                        keep.append(k)
                out[gk] = keep
        return out

    def repeat_for(self, spec):
        if isinstance(spec, list):
            return spec
        if spec == "eachPixelGroup":
            return list(self.groups.keys())
        if spec == "eachPixelABC":
            return list(self.pixel_keys)
        order = spec.replace("eachPixel", "")
        return self.by_order(order[0], order[1], order[2])

    def orientation(self):
        x, y, z = self.count
        if self.custom_keys and len(self.positions) < x * y * z:
            return "custom"
        if z > 1:
            return "3d"
        if x > 1 and y > 1:
            return "grid"
        if y > 1:
            return "vertical"
        return "horizontal"


# --------------------------------------------------------------------------------------
# Semantic classification (OFL capability -> Prism kind)
# --------------------------------------------------------------------------------------

COLOR_KIND = {"Red": "red", "Green": "green", "Blue": "blue", "Cyan": "cyan",
              "Magenta": "magenta", "Yellow": "yellow", "Amber": "amber", "White": "white",
              "Warm White": "warmWhite", "Cold White": "coolWhite", "UV": "uv",
              "Lime": "lime", "Indigo": "indigo"}
COLOR_KINDS = set(COLOR_KIND.values())

# Name rules are evaluated in order. Each rule lists the base kinds it may override
# (base kinds are derived from OFL capability types first).
WEAK = {"generic", "intensity", "control", "speed", "rotation"}
NAME_RULES = [
    ("tint", r"(\btint\b|green\s*[-/\u2013]?\s*magenta|magenta\s*[-/\u2013]?\s*green|\bg\s*/\s*m\b|"
             r"\bgm\b|\+/-\s*green|\u00b1\s*green|minus\s*green|plus\s*green|green\s*shift|\bg-m\b)",
     WEAK | {"colorMacro"}),
    ("crossfade", r"(cross\s*-?\s*fade|x-?fade|(cct|white)\s*(<->|/|\u2194|to)\s*(rgb|colou?r|hsi)|"
                  r"(rgb|colou?r)\s*(<->|/|\u2194|to)\s*(cct|white)|\bblend\b|colou?r\s*mix\s*(level|ratio)|"
                  r"^mix$)", WEAK),
    ("hue", r"\bhue\b", WEAK),
    ("saturation", r"\bsat(uration|\.)?\b", WEAK),
    ("cieX", r"(\bcie\s*-?\s*x\b|^x$|^x\s*coord|chromaticity\s*x)", {"generic"}),
    ("cieY", r"(\bcie\s*-?\s*y\b|^y$|^y\s*coord|chromaticity\s*y)", {"generic"}),
    ("fan", r"\bfan\b", WEAK | {"effect"}),
    ("cct", r"(\bcct\b|kelvin|colou?r\s*temp|white\s*point|\bctc\b|^ct$)", {"generic", "intensity"}),
    ("control", r"(curve|reset|control|function|\bmode\b|setting|response|smooth|special|\blamp\b|"
                r"dimmer\s*speed|fade\s*time|operat|service|config|calibrat|priority|\bauto\b)",
     {"generic", "speed", "rotation"}),
    ("effectSpeed", r"((speed|rate|tempo).*(effect|fx|program|auto|chase|macro|show)|"
                    r"(effect|fx|program|auto|chase|macro|show).*(speed|rate|tempo))",
     {"generic", "speed", "control"}),
    ("effect", r"(effect|\bfx\b|program|macro|chase|pattern|show|scene|sound|music)",
     {"generic", "speed", "control"}),
    ("strobe", r"(strobe|flash)", {"generic", "speed"}),
    ("shutter", r"shutter", {"generic"}),
    ("intensity", r"(dimmer|intensity|brightness|\bdim\b|master|level)", {"generic"}),
    ("colorMacro", r"(colou?r\s*(macro|preset|select|filter|gel)|\bgel\b|\blee\b|rosco)", {"generic"}),
]
NAME_RULES = [(k, re.compile(p, re.I), allowed) for k, p, allowed in NAME_RULES]

SIMPLE_KINDS = COLOR_KINDS | {"intensity", "cct", "tint", "hue", "saturation", "cieX", "cieY",
                              "crossfade", "none"}
COMPLEX_KINDS = {"pan", "tilt", "panTiltSpeed", "gobo", "goboRotation", "prism", "prismRotation",
                 "iris", "frost", "blade", "zoom", "focus", "colorWheel", "fog"}


def wheel_type(cap, wheels, channel_name):
    names = cap.get("wheel", channel_name)
    if isinstance(names, list):
        names = names[0]
    wheel = wheels.get(names) if wheels else None
    if wheel:
        counts = collections.Counter(s["type"] for s in wheel["slots"]
                                     if s["type"] not in ("Open", "Closed"))
        if counts:
            t = counts.most_common(1)[0][0]
            return {"AnimationGoboStart": "Gobo", "AnimationGoboEnd": "Gobo"}.get(t, t)
    low = (names or "").lower()
    if re.search(r"colou?r", low):
        return "Color"
    if "prism" in low:
        return "Prism"
    if "frost" in low:
        return "Frost"
    if "iris" in low:
        return "Iris"
    return "Gobo"


def cap_kind(cap, wheels, channel_name):
    t = cap["type"]
    if t == "NoFunction":
        return "none"
    if t == "Intensity":
        return "intensity"
    if t == "ColorIntensity":
        return COLOR_KIND[cap["color"]]
    if t == "ColorTemperature":
        return "cct"
    if t == "ColorPreset":
        return "colorMacro"
    if t == "ShutterStrobe":
        return "shutter" if cap["shutterEffect"] in ("Open", "Closed") else "strobe"
    if t in ("StrobeSpeed", "StrobeDuration"):
        return "strobe"
    if t in ("Pan", "PanContinuous"):
        return "pan"
    if t in ("Tilt", "TiltContinuous"):
        return "tilt"
    if t == "PanTiltSpeed":
        return "panTiltSpeed"
    if t in ("WheelSlot", "WheelShake"):
        return {"Color": "colorWheel", "Gobo": "gobo", "Prism": "prism", "Iris": "iris",
                "Frost": "frost"}.get(wheel_type(cap, wheels, channel_name), "gobo")
    if t in ("WheelSlotRotation", "WheelRotation"):
        return {"Color": "colorWheel", "Prism": "prismRotation"}.get(
            wheel_type(cap, wheels, channel_name), "goboRotation")
    if t in ("Effect", "EffectParameter", "SoundSensitivity"):
        return "effect"
    if t in ("EffectSpeed", "EffectDuration"):
        return "effectSpeed"
    if t in ("BeamAngle", "Zoom"):
        return "zoom"
    if t == "Focus":
        return "focus"
    if t in ("Iris", "IrisEffect"):
        return "iris"
    if t in ("Frost", "FrostEffect"):
        return "frost"
    if t == "Prism":
        return "prism"
    if t == "PrismRotation":
        return "prismRotation"
    if t.startswith("Blade"):
        return "blade"
    if t.startswith("Fog"):
        return "fog"
    if t == "Rotation":
        return "rotation"
    if t in ("Speed", "Time"):
        return "speed"
    if t == "Maintenance":
        return "control"
    return "generic"  # Generic, BeamPosition


def cap_width(cap, maxv):
    a, b = cap.get("dmxRange", [0, maxv])
    return b - a + 1


def channel_kind(name, caps, wheels, maxv):
    weights = collections.Counter()
    for c in caps:
        k = cap_kind(c, wheels, name)
        if k != "none":
            weights[k] += cap_width(c, maxv)
    if not weights:
        return "none", "type"
    kinds = set(weights)
    color = [k for k in kinds if k in COLOR_KINDS]
    if "strobe" in kinds and kinds <= {"strobe", "shutter", "intensity", "effect", "generic",
                                       "control", "speed", "effectSpeed"}:
        # combined "Dimmer/Strobe" channels: keep intensity if it owns most of the range
        base = "intensity" if weights.get("intensity", 0) > weights["strobe"] else "strobe"
    elif "shutter" in kinds and kinds <= {"shutter", "intensity", "generic"}:
        base = "intensity" if weights.get("intensity", 0) > weights["shutter"] else "shutter"
    elif len(color) == 1 and kinds <= {color[0], "strobe", "shutter", "effect", "generic"}:
        base = color[0]
    else:
        base = weights.most_common(1)[0][0]
    # Name refinement (OFL has no native types for hue/sat/tint/crossfade/CIE xy).
    clean = strip_pixel_var(name)
    for kind, rx, allowed in NAME_RULES:
        if base in allowed and rx.search(clean):
            # never turn a pure Intensity/Dimmer channel into "control" etc.
            if base == "intensity" and kind not in ("hue", "saturation", "tint", "crossfade", "cct"):
                continue
            return kind, "name"
    return base, "type"


# --------------------------------------------------------------------------------------
# Capability conversion
# --------------------------------------------------------------------------------------

CAP_UNIT_SUFFIX = {"deg": "°", "%": "%", "K": " K", "Hz": " Hz", "s": " s", "ms": " ms", "rpm": " rpm",
                   "bpm": " bpm", "m": " m", "mm": " mm", "xy": "", "lx": " lx", "lm": " lm"}
CAP_KIND_NAMES = {"open": "Open", "closed": "Closed", "none": "No function", "cct": "Color temperature",
                  "cieX": "CIE x", "cieY": "CIE y", "panTiltSpeed": "Pan/tilt speed", "colorMacro": "Color macro",
                  "goboRotation": "Gobo rotation"}


def _humanize(name):
    words = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", name or "").split()
    text = " ".join(words).lower()
    return text[:1].upper() + text[1:] if text else ""


def _fmt_num(v):
    return ("%g" % v) if isinstance(v, (int, float)) else str(v)


def synthesize_cap_label(cap_type, kind, out):
    """Readable label for a capability OFL left without a comment: "Pan 0–530°", "Strobe 1–25 Hz"."""
    base = CAP_KIND_NAMES.get(kind) or (_humanize(kind) if kind and kind != "generic" else _humanize(cap_type))
    unit = out.get("unit")
    suffix = CAP_UNIT_SUFFIX.get(unit, (" " + str(unit)) if unit else "")
    if "value" in out:
        return "%s %s%s" % (base, _fmt_num(out["value"]), suffix)
    if "from" in out and "to" in out:
        return "%s %s–%s%s" % (base, _fmt_num(out["from"]), _fmt_num(out["to"]), suffix)
    return base or "Range"


def convert_capability(cap, maxv, chan_kind, wheels, channel_name):
    t = cap["type"]
    # Ranges stay in the channel's own resolution; the app scales them by the shared
    # definition's "res" when it decodes the profile.
    out = {"dmx": list(cap.get("dmxRange", [0, maxv]))}
    k = cap_kind(cap, wheels, channel_name)
    if t == "ShutterStrobe":
        eff = cap["shutterEffect"]
        if eff == "Open":
            k = "open"
        elif eff == "Closed":
            k = "closed"
        else:
            k = "strobe"
            if eff != "Strobe":
                out["pattern"] = eff[0].lower() + eff[1:]
            if cap.get("randomTiming"):
                out["random"] = True
            if cap.get("soundControlled"):
                out["sound"] = True
    elif t == "Generic" and chan_kind not in ("generic",):
        k = chan_kind  # e.g. tint / hue / crossfade encoded as Generic in OFL
    elif k in ("intensity", "control", "speed", "rotation") and chan_kind in (
            "hue", "saturation", "tint", "crossfade", "fan", "cct", "cieX", "cieY"):
        k = chan_kind
    out["kind"] = k

    label = cap.get("comment")
    prop_order = ["brightness", "colorTemperature", "speed", "duration", "angle", "distance",
                  "openPercent", "frostIntensity", "insertion", "fogOutput", "parameter",
                  "soundSensitivity", "horizontalAngle", "verticalAngle", "shakeSpeed",
                  "shakeAngle", "time", "slotNumber"]
    for prop in prop_order:
        rng = range_prop(cap, prop)
        if rng is None:
            continue
        a, ua = parse_entity(rng[0], prop, t)
        b, ub = parse_entity(rng[1], prop, t)
        if prop == "slotNumber":
            out["slot"] = a if a == b else [a, b]
            slot_info = describe_slot(cap, wheels, channel_name, a)
            if slot_info and not label:
                label = slot_info.get("name")
            if slot_info and slot_info.get("colors"):
                out["colors"] = slot_info["colors"]
            continue
        if a is None:
            continue
        if a == b:
            out["value"] = a
        else:
            out["from"], out["to"] = a, b
        if ua or ub:
            out["unit"] = ua or ub
        break  # one primary physical quantity per capability is enough for Prism v1
    if t == "Intensity" or t == "ColorIntensity":
        if "from" not in out and "value" not in out:
            out["from"], out["to"], out["unit"] = 0, 100, "%"
    if t == "ColorPreset":
        cols = cap.get("colors") or cap.get("colorsStart")
        if cols:
            out["colors"] = cols
        if cap.get("colorsEnd"):
            out["colorsTo"] = cap["colorsEnd"]
    if t in ("Effect", "IrisEffect", "FrostEffect"):
        label = cap.get("effectName") or cap.get("effectPreset") or label
        if cap.get("soundControlled"):
            out["sound"] = True
    if t == "Maintenance" and "hold" in cap:
        h, u = parse_entity(cap["hold"], "hold", t)
        out["hold"] = {"value": h, "unit": u}
    if t.startswith("Blade"):
        out["blade"] = cap.get("blade")
    if t == "Generic" and "from" not in out and "value" not in out:
        parsed = parse_comment_range(label)
        if parsed:
            out["from"], out["to"], out["unit"] = parsed
    if k in ("cieX", "cieY") and "from" not in out:
        m = UNITLESS_RANGE_RE.search(label or "")
        if m:  # e.g. Aputure Nova "X" channel: comment "0 … 0.8"
            out["from"], out["to"], out["unit"] = float(m.group(1)), float(m.group(2)), "xy"
        elif cap_width(cap, maxv) >= (maxv + 1) // 2:
            out["from"], out["to"], out["unit"] = 0.0, 0.8, "xy"
            out["assumed"] = True
    if k == "tint" and "from" not in out and "value" not in out:
        low = label or ""
        if re.search(r"neutral|\bnone\b|\boff\b|center|normal", low, re.I):
            out["value"], out["unit"] = 0, "%"
        elif re.search(r"(full|max)\w*\s*(minus|-|\u2212)\s*green|\bfull\s*magenta", low, re.I):
            out["value"], out["unit"] = -100, "%"
        elif re.search(r"(full|max)\w*\s*(plus|\+)\s*green|\bfull\s*green", low, re.I):
            out["value"], out["unit"] = 100, "%"
    if k in DEFAULT_RANGES and "from" not in out and "value" not in out and \
            cap_width(cap, maxv) >= (maxv + 1) // 4 and not OFF_LABEL_RE.search(label or ""):
        out["from"], out["to"], out["unit"] = DEFAULT_RANGES[k]
        out["assumed"] = True
    if t in ("PanContinuous", "TiltContinuous", "WheelRotation", "WheelSlotRotation",
             "PrismRotation", "Rotation") and "speed" in "".join(cap.keys()).lower():
        out["continuous"] = True
    if label:
        out["label"] = label
    if cap.get("menuClick"):
        out["menuClick"] = cap["menuClick"]
    if cap.get("helpWanted"):
        out["helpWanted"] = True
    return out


def describe_slot(cap, wheels, channel_name, slot_number):
    names = cap.get("wheel", channel_name)
    if isinstance(names, list):
        names = names[0]
    wheel = (wheels or {}).get(names)
    if not wheel or slot_number is None:
        return None
    slots = wheel["slots"]
    if float(slot_number).is_integer() and 1 <= int(slot_number) <= len(slots):
        s = slots[int(slot_number) - 1]
        return {"name": s.get("name") or s["type"], "colors": s.get("colors")}
    return None


# --------------------------------------------------------------------------------------
# Fixture conversion
# --------------------------------------------------------------------------------------

def resolve_template(obj, pixel_key):
    pk = json.dumps(pixel_key)[1:-1]
    return json.loads(json.dumps(obj).replace("$pixelKey", pk))


class Registry:
    """All channel keys usable in modes: coarse, fine aliases, switching aliases, matrix channels."""

    def __init__(self, fx, matrix):
        self.entries = {}
        if matrix is not None:
            pixel_keys = matrix.pixel_keys + list(matrix.groups.keys())
            for tkey, tjson in fx.get("templateChannels", {}).items():
                for pk in pixel_keys:
                    self._add(resolve_template(tkey, pk), resolve_template(tjson, pk), pk, tkey)
        for key, cj in fx.get("availableChannels", {}).items():
            prev = self.entries.get(key)
            self._add(key, cj, prev["pixelKey"] if prev else None, None)

    def _add(self, key, cj, pixel_key, template_key):
        self.entries[key] = {"type": "coarse", "key": key, "json": cj, "pixelKey": pixel_key,
                             "templateKey": template_key}
        for i, fk in enumerate(cj.get("fineChannelAliases", [])):
            self.entries[fk] = {"type": "fine", "key": fk, "coarseKey": key, "byte": i + 1,
                                "pixelKey": pixel_key, "templateKey": template_key}
        cases = collections.OrderedDict()
        for cap in cj.get("capabilities", []) or []:
            for alias, target in (cap.get("switchChannels") or {}).items():
                cases.setdefault(alias, []).append((cap["dmxRange"], target))
        for alias, lst in cases.items():
            self.entries[alias] = {"type": "switch", "key": alias, "triggerKey": key,
                                   "cases": lst, "pixelKey": pixel_key, "templateKey": template_key}

    def get(self, key):
        return self.entries.get(key)


def mode_channel_keys(mode, matrix):
    keys = []
    for ref in mode["channels"]:
        if isinstance(ref, dict) and ref.get("insert") == "matrixChannels":
            pks = matrix.repeat_for(ref["repeatFor"])
            if ref["channelOrder"] == "perPixel":
                pairs = [(t, pk) for pk in pks for t in ref["templateChannels"]]
            else:
                pairs = [(t, pk) for t in ref["templateChannels"] for pk in pks]
            keys.extend(None if t is None else resolve_template(t, pk) for t, pk in pairs)
        else:
            keys.append(ref)
    return keys


def merge_cases(cases):
    """Merge DMX-contiguous switching cases that select the same definition/byte."""
    out = []
    for c in sorted(cases, key=lambda c: c["when"][0]):
        prev = out[-1] if out else None
        if prev and prev["def"] == c["def"] and prev.get("byte") == c.get("byte") and \
                prev["when"][1] + 1 == c["when"][0]:
            prev["when"] = [prev["when"][0], c["when"][1]]
        else:
            out.append(dict(c, when=list(c["when"])))
    return out


def to_dmx(value, maxv):
    if isinstance(value, str) and value.endswith("%"):
        return int(round(float(value[:-1]) / 100.0 * maxv))
    return value


OFF_LABEL_RE = re.compile(
    r"\b(off|stop(ped)?|no\s*(function|effect|strobe|fx|macro|program|rotation|movement)|none|"
    r"disabled?|inactive|open|manual|normal|neutral|default|standby)\b", re.I)
DANGER_LABEL_RE = re.compile(r"(reset|lamp\s*(on|off)|calibrat|firmware|update|factory|"
                             r"\bstore\b|\bsave\b|\brecord\b|address)", re.I)
SAFE_DEFAULT_KINDS = {"strobe", "shutter", "effect", "effectSpeed", "control", "colorMacro",
                      "colorWheel", "gobo", "goboRotation", "prism", "prismRotation", "fan",
                      "generic", "speed", "rotation", "frost", "iris", "blade", "fog", "zoom",
                      "focus", "panTiltSpeed"}


def compute_default(kind, caps_out, ofl_default, maxv):
    """DMX 'home' value. OFL defaultValue wins; otherwise choose a value that leaves the
    fixture in a neutral, light-passing, non-animated state and never triggers maintenance."""
    if ofl_default is not None:
        return to_dmx(ofl_default, maxv), "ofl"
    if kind in ("pan", "tilt"):
        return (maxv + 1) // 2, "center"
    if kind in SAFE_DEFAULT_KINDS:
        def safe(c):
            return not DANGER_LABEL_RE.search(c.get("label", ""))
        for c in caps_out:  # 1. shutter open (so intensity works)
            if c["kind"] == "open":
                return c["dmx"][0], "open"
        for c in caps_out:  # 2. explicitly labelled off / stop / no function
            if OFF_LABEL_RE.search(c.get("label", "")) and safe(c):
                return c["dmx"][0], "off"
        nones = sorted((c for c in caps_out if c["kind"] == "none"),
                       key=lambda c: (c["dmx"][0] != 0, c["dmx"][0]))
        if nones:  # 3. NoFunction range, preferring one that starts at 0
            return nones[0]["dmx"][0], "off"
        if caps_out and not safe(caps_out[0]):  # 4. avoid a reset at DMX 0
            for c in caps_out:
                if safe(c):
                    return c["dmx"][0], "safe"
    if kind == "tint":
        for c in caps_out:
            if c.get("value") == 0 or re.search(r"neutral|center|off|normal|\bnone\b", c.get("label", ""), re.I):
                return c["dmx"][0], "neutral"
        for c in caps_out:
            if "from" in c and c["from"] < 0 < c["to"]:
                a, b = c["dmx"]
                frac = (0 - c["from"]) / float(c["to"] - c["from"])
                return int(round(a + frac * (b - a))), "neutral"
        return (maxv + 1) // 2, "center"
    return 0, "zero"


def channel_definition(key, cj, wheels, name_hint=None):
    """Prism channel definition for an OFL coarse channel json (template or resolved)."""
    n_fine = len(cj.get("fineChannelAliases", []))
    res_bytes = {"8bit": 1, "16bit": 2, "24bit": 3}.get(cj.get("dmxValueResolution"), 1 + n_fine)
    maxv = 256 ** res_bytes - 1
    caps = [cj["capability"]] if "capability" in cj else cj["capabilities"]
    name = strip_pixel_var(cj.get("name", name_hint or key))
    kind, via = channel_kind(cj.get("name", key), caps, wheels, maxv)
    caps_out = [convert_capability(c, maxv, kind, wheels, cj.get("name", key)) for c in caps]
    d = collections.OrderedDict()
    d["kind"] = kind
    d["name"] = name
    if via == "name":
        d["kindFrom"] = "name"
    d["res"] = 8 * res_bytes
    default, default_src = compute_default(kind, caps_out, cj.get("defaultValue"), maxv)
    d["default"] = default
    if "highlightValue" in cj:
        d["highlight"] = to_dmx(cj["highlightValue"], maxv)
    if cj.get("precedence"):
        d["precedence"] = cj["precedence"]
    if cj.get("constant"):
        d["constant"] = True
    # Overall physical range (convenience for the colour engine): span of all capabilities of
    # the channel's kind that share the unit of the widest proportional one, in DMX order.
    cand = [c for c in caps_out if c.get("unit") and ("from" in c or "value" in c) and c["kind"] == kind]
    prop = [c for c in cand if "from" in c] or [c for c in caps_out if "from" in c and c.get("unit")]
    if prop:
        best = max(prop, key=lambda c: c["dmx"][1] - c["dmx"][0])
        same = sorted((c for c in (cand or prop) if c["unit"] == best["unit"]),
                      key=lambda c: c["dmx"][0]) or [best]
        vals = [v for c in same for v in ((c["from"], c["to"]) if "from" in c else (c["value"],))]
        start, end = min(vals), max(vals)
        if best["from"] > best["to"]:  # descending channel (e.g. CCT cold->warm, zoom wide->narrow)
            start, end = end, start
        if start != end:
            d["range"] = {"from": start, "to": end, "unit": best["unit"]}
    trivial = (len(caps_out) == 1 and caps_out[0]["dmx"] == [0, maxv] and
               caps_out[0].get("unit") == "%" and caps_out[0].get("from") == 0 and
               caps_out[0].get("to") == 100 and set(caps_out[0]) <= {"dmx", "kind", "from", "to", "unit"})
    if not trivial:
        for src_cap, c in zip(caps, caps_out):
            if not c.get("label"):
                c["label"] = synthesize_cap_label(src_cap.get("type", ""), c.get("kind"), c)
        d["capabilities"] = caps_out
    if any(c.get("helpWanted") for c in caps):
        d["helpWanted"] = True
    return d


NAME_CATEGORY_RULES = [
    ("tube", r"(\btube\b|titan|helios|hyperion|pavotube|infinibar|\bq-?led\b|crossfade\s*x|\bt\d{1,2}\b.*pixel)"),
    ("bulb", r"(\bbulb\b|\bnyx\b|\be27\b|\ba19\b|lightdrop)"),
    ("fresnel", r"(fresnel|\bl\d{1,2}-c\b|\borbiter\b|\bpc\b|\bfresnel\b)"),
    ("panel", r"(panel|skypanel|litemat|litetile|\bmat\b|celeb|freestyle|\bnova\b|\btile\b|"
              r"\bs\d{2,3}-?c\b|\bp\d{3}c\b|1x1|2x1|softlight|soft\s*light|softled|flat|fos/?4\s*p[dl]|\bpl-e\d)"),
    ("cob", r"(\bls[\s-]?\d{3,4}|\bc\d{3}d\b|\bamaran\b|\bforza\b|\bsl\d{2,3}|monolight|\bcob\b|"
            r"\bmini\s*mix\b|\bmaxi\s*mix\b|\bsl1\b|\bepos\b|\b\d{3}x?b\b|\bp3\b|\bdled|stryder|broadcaster|"
            r"\b(bee|hornet|wasp)\b)"),
    ("par", r"(\bpar\b|\bpar\s?-?\d+|slim\s?par|\bparty\s?par|\bpar\d+)"),
    ("strip", r"(\bstrip\b|\btape\b|ribbon|\bflex\b)"),
    ("bar", r"(\bbar\b|batten|\blinear\b|\bcyc\b|\bline\b|\bribalta\b|\bstick\b|\brail\b)"),
    ("spot", r"(profile|ellipsoidal|source\s*(4|four)|\bleko\b|\bspot\b|\bfos4\b|\bfollow\s*spot)"),
    ("wash", r"(\bwash\b|\bflood\b|\bblinder\b|\buplight|\bpinspot\b)"),
    ("dimmer", r"(dimmer|\bpack\b|\brelay\b|desk\s*channel|switch\s*pack)"),
]
NAME_CATEGORY_RULES = [(c, re.compile(p, re.I)) for c, p in NAME_CATEGORY_RULES]


def prism_category(name, ofl_cats, all_kinds, physical, has_matrix):
    primary = ofl_cats[0]
    if "pan" in all_kinds or "tilt" in all_kinds or primary in ("Moving Head", "Scanner", "Barrel Scanner"):
        return "movingHead", "rule:pan/tilt"
    if primary in ("Smoke", "Hazer", "Fan", "Laser", "Flower") or "fog" in all_kinds:
        return "effect", "ofl:" + primary
    for cat, rx in NAME_CATEGORY_RULES:
        if rx.search(name):
            if cat == "dimmer" and primary != "Dimmer":
                continue
            return cat, "rule:name"
    dims = (physical or {}).get("dimensions")
    if dims and min(dims) > 0:
        w, h, d = dims
        longest, mid, short = sorted([w, h, d], reverse=True)
        if longest >= 6 * mid and mid <= 1.6 * short and mid <= 70:  # slim round-ish profile
            return "tube", "rule:shape"
        if longest >= 4 * mid:
            return "bar", "rule:shape"
    if primary in ("Pixel Bar", "Stand"):
        return "bar", "ofl:" + primary
    if primary == "Matrix":
        return "panel", "ofl:Matrix"
    if primary == "Blinder":
        return "wash", "ofl:Blinder"
    if primary in ("Strobe", "Effect"):
        return "effect", "ofl:" + primary
    if primary == "Dimmer":
        if all_kinds <= {"intensity", "none"}:
            return "dimmer", "ofl:Dimmer"
        return "other", "ofl:Dimmer(ambiguous)"
    if primary == "Color Changer":
        return "wash", "ofl:Color Changer"
    return "other", "fallback"


def color_model(kinds):
    s = {k for k in kinds if not k.endswith("Fine")}
    has_rgb = {"red", "green", "blue"} <= s
    if has_rgb:
        model = "rgb" + "".join(code for k, code in [
            ("white", "w"), ("warmWhite", "ww"), ("coolWhite", "cw"), ("amber", "a"),
            ("lime", "l"), ("cyan", "c"), ("magenta", "m"), ("yellow", "y"),
            ("uv", "uv"), ("indigo", "i")] if k in s)
    elif {"cyan", "magenta", "yellow"} <= s:
        model = "cmy"
    elif "hue" in s and "saturation" in s:
        model = "hsi"
    elif "cieX" in s and "cieY" in s:
        model = "xy"
    elif "cct" in s or {"warmWhite", "coolWhite"} <= s:
        model = "cct"
    elif s & COLOR_KINDS:
        model = "single:" + "+".join(sorted(s & COLOR_KINDS))
    elif "colorWheel" in s or "colorMacro" in s:
        model = "macro"
    elif "intensity" in s:
        model = "dimmer"
    else:
        model = "none"
    features = []
    if "cct" in s and model != "cct":
        features.append("cct")
    for f in ("tint", "crossfade", "colorMacro", "colorWheel", "strobe", "effect"):
        if f in s:
            features.append(f)
    if "hue" in s and model != "hsi":
        features.append("hsi")
    if "cieX" in s and model != "xy":
        features.append("xy")
    return model, features


def complexity(kinds, ofl_cats):
    s = {k[:-4] if k.endswith("Fine") else k for k in kinds}
    if s & COMPLEX_KINDS or "Laser" in ofl_cats:
        return "complex"
    if s <= SIMPLE_KINDS:
        return "simple"
    return "standard"


def convert_fixture(man_key, fx_key, fx, manufacturers, commit):
    wheels = fx.get("wheels", {})
    matrix = Matrix(fx["matrix"]) if "matrix" in fx else None
    reg = Registry(fx, matrix)
    definitions = collections.OrderedDict()
    def_key_for = {}
    warnings = []

    def get_def(entry):
        """definition key for a coarse registry entry (template channels deduplicated)."""
        dk = entry["templateKey"] or entry["key"]
        if dk not in definitions:
            src = (fx["templateChannels"][dk] if entry["templateKey"] else entry["json"])
            definitions[dk] = channel_definition(dk, src, wheels)
        return dk

    all_kinds = set()
    modes_out = []
    for mode in fx["modes"]:
        keys = mode_channel_keys(mode, matrix)
        offsets_by_key = {k: i for i, k in enumerate(keys) if k is not None}
        chans = []
        cells = collections.OrderedDict()
        for off, key in enumerate(keys):
            if key is None:
                chans.append({"kind": "none"})
                continue
            e = reg.get(key)
            if e is None:
                warnings.append("unknown channel key %r in mode %r" % (key, mode["name"]))
                chans.append({"kind": "none", "unresolved": key})
                continue
            entry = collections.OrderedDict()
            if e["type"] == "switch":
                trig = reg.get(e["triggerKey"])
                tj = trig["json"]
                tdef = to_dmx(tj.get("defaultValue", 0), 255)
                cases = []
                default_target = None
                target_entries = []
                for rng, target in e["cases"]:
                    te = reg.get(target) if target else None
                    case = {"when": rng, "def": None}
                    if te is not None:
                        ce = te if te["type"] != "fine" else reg.get(te["coarseKey"])
                        case["def"] = get_def(ce)
                        if te["type"] == "fine":
                            case["byte"] = te["byte"]
                    cases.append(case)
                    target_entries.append(te)
                    if rng[0] <= tdef <= rng[1] and default_target is None:
                        default_target = len(cases) - 1
                di = default_target if default_target is not None else 0
                dt = cases[di]
                base = definitions[dt["def"]]["kind"] if dt["def"] else "none"
                entry["kind"] = base + ("Fine" if dt.get("byte") else "")
                if dt["def"]:
                    entry["def"] = dt["def"]
                entry["switch"] = {"trigger": offsets_by_key.get(e["triggerKey"]), "cases": merge_cases(cases)}
                pk = e["pixelKey"]
                if pk is None:  # alias of plain channel: take the pixel of the default target
                    te = target_entries[di] or next((t for t in target_entries if t), None)
                    pk = te["pixelKey"] if te else None
            elif e["type"] == "fine":
                ce = reg.get(e["coarseKey"])
                dk = get_def(ce)
                entry["kind"] = definitions[dk]["kind"] + "Fine"
                entry["def"] = dk
                entry["coarse"] = offsets_by_key.get(e["coarseKey"])
                if e["byte"] > 1:
                    entry["byte"] = e["byte"]
                pk = e["pixelKey"]
            else:
                dk = get_def(e)
                entry["kind"] = definitions[dk]["kind"]
                entry["def"] = dk
                fines = [offsets_by_key[fk] for fk in e["json"].get("fineChannelAliases", [])
                         if fk in offsets_by_key]
                if fines:
                    entry["fine"] = fines
                pk = e["pixelKey"]
            # pixel/cell assignment ("all"-groups are fixture-wide master channels)
            if pk is not None and matrix is not None:
                members = matrix.groups.get(pk, [pk])
                if len(members) == len(matrix.pixel_keys) and pk in matrix.groups:
                    entry["scope"] = "master"
                else:
                    entry["cell"] = pk
                    cell = cells.setdefault(pk, collections.OrderedDict(
                        [("key", pk)] + ([("pixels", members)] if pk in matrix.groups else []) +
                        [("offsets", collections.OrderedDict())]))
                    ok = entry["kind"]
                    if ok in cell["offsets"]:
                        prev = cell["offsets"][ok]
                        cell["offsets"][ok] = (prev if isinstance(prev, list) else [prev]) + [off]
                    else:
                        cell["offsets"][ok] = off
            chans.append(entry)
        kinds = {c["kind"] for c in chans}
        all_kinds |= {k[:-4] if k.endswith("Fine") else k for k in kinds}
        cm, feats = color_model(kinds)
        m = collections.OrderedDict()
        m["key"] = mode.get("shortName", mode["name"])
        m["name"] = mode["name"]
        m["footprint"] = len(chans)
        m["colorModel"] = cm
        if cells:
            feats = feats + ["pixels"]
        if feats:
            m["features"] = feats
        m["complexity"] = complexity(kinds, fx["categories"])
        if "rdmPersonalityIndex" in mode:
            m["rdmPersonality"] = mode["rdmPersonalityIndex"]
        if "physical" in mode:
            m["physical"] = mode["physical"]
        m["channels"] = chans
        if cells:
            m["cells"] = list(cells.values())
        modes_out.append(m)

    phys = fx.get("physical", {})
    category, cat_src = prism_category(fx["name"], fx["categories"], all_kinds, phys, matrix is not None)
    out = collections.OrderedDict()
    out["$schema"] = SCHEMA_ID
    out["id"] = "%s/%s" % (man_key, fx_key)
    man = manufacturers.get(man_key, {})
    out["manufacturer"] = man.get("name", man_key)
    out["manufacturerKey"] = man_key
    out["model"] = fx["name"]
    if "shortName" in fx:
        out["shortName"] = fx["shortName"]
    out["category"] = category
    out["categorySource"] = cat_src
    out["tags"] = [re.sub(r"\s+", "", c[0].lower() + c[1:]) for c in fx["categories"]]
    p = collections.OrderedDict()
    if "dimensions" in phys:
        p["dimensionsMm"] = phys["dimensions"]
    if "weight" in phys:
        p["weightKg"] = phys["weight"]
    if "power" in phys:
        p["powerW"] = phys["power"]
    if "DMXconnector" in phys:
        p["dmxConnector"] = phys["DMXconnector"]
    bulb = phys.get("bulb", {})
    if "type" in bulb:
        p["lightSource"] = bulb["type"]
    if "colorTemperature" in bulb:
        p["nativeCctK"] = bulb["colorTemperature"]
    if "lumens" in bulb:
        p["lumens"] = bulb["lumens"]
    lens = phys.get("lens", {})
    if "degreesMinMax" in lens:
        p["beamAngleDeg"] = lens["degreesMinMax"]
    if "name" in lens:
        p["lens"] = lens["name"]
    if p:
        out["physical"] = p
    if matrix is not None:
        px = collections.OrderedDict()
        px["count"] = len(matrix.pixel_keys)
        px["grid"] = matrix.count
        px["orientation"] = matrix.orientation()
        px["cells"] = [collections.OrderedDict([("key", k), ("x", matrix.positions[k][0] - 1),
                                                ("y", matrix.positions[k][1] - 1),
                                                ("z", matrix.positions[k][2] - 1)])
                       for k in matrix.pixel_keys]
        groups = {g: v for g, v in matrix.groups.items() if len(v) != len(matrix.pixel_keys)}
        if groups:
            px["groups"] = groups
        mp = phys.get("matrixPixels", {})
        if "dimensions" in mp:
            px["cellSizeMm"] = mp["dimensions"]
        if "spacing" in mp:
            px["spacingMm"] = mp["spacing"]
        out["pixels"] = px
    if wheels:
        out["wheels"] = wheels
    out["definitions"] = definitions
    out["modes"] = modes_out
    src = collections.OrderedDict()
    src["library"] = "ofl"
    src["license"] = "MIT"
    src["path"] = "fixtures/%s/%s.json" % (man_key, fx_key)
    if commit:
        src["commit"] = commit
    src["url"] = "https://open-fixture-library.org/%s/%s" % (man_key, fx_key)
    src["authors"] = fx["meta"]["authors"]
    src["lastModified"] = fx["meta"]["lastModifyDate"]
    if "importPlugin" in fx["meta"]:
        src["importedFrom"] = fx["meta"]["importPlugin"]["plugin"]
    out["source"] = src
    if "links" in fx:
        out["links"] = fx["links"]
    if "rdm" in fx:
        out["rdm"] = {"manufacturerId": man.get("rdmId"), "modelId": fx["rdm"]["modelId"]}
    notes = []
    if fx.get("helpWanted") or any(d.get("helpWanted") for d in definitions.values()):
        notes.append("helpWanted")
    if any("switch" in c for m in modes_out for c in m["channels"]):
        notes.append("switchingChannels")
    if warnings:
        notes.extend(warnings)
    if notes:
        out["notes"] = notes
    return out


def index_row(pf):
    modes = pf["modes"]
    return collections.OrderedDict([
        ("id", pf["id"]),
        ("mfr", pf["manufacturerKey"]),
        ("model", pf["model"]),
        ("cat", pf["category"]),
        ("tags", pf["tags"]),
        ("modes", [[m["key"], m["footprint"], m["colorModel"]] for m in modes]),
        ("px", pf.get("pixels", {}).get("count", 0)),
        ("cx", max(("simple", "standard", "complex").index(m["complexity"]) for m in modes)),
    ])


def git_commit(path):
    try:
        return subprocess.check_output(["git", "-C", path, "rev-parse", "HEAD"], text=True).strip()
    except Exception:  # noqa: BLE001
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ofl", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "ofl"))
    ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "prism-out"))
    ap.add_argument("--pretty", action="store_true", help="indent JSON output")
    ap.add_argument("--only", help="comma separated manufacturer keys")
    args = ap.parse_args()

    fx_dir = os.path.join(args.ofl, "fixtures")
    manufacturers = json.load(open(os.path.join(fx_dir, "manufacturers.json")))
    manufacturers.pop("$schema", None)
    commit = git_commit(args.ofl)
    only = set(args.only.split(",")) if args.only else None

    if os.path.isdir(args.out):
        shutil.rmtree(args.out)
    os.makedirs(os.path.join(args.out, "fixtures"))
    dump_kw = {"indent": 1, "ensure_ascii": False} if args.pretty else {"separators": (",", ":"), "ensure_ascii": False}

    index, redirects, errors = [], [], []
    stats = collections.defaultdict(collections.Counter)
    sizes = {"ofl_raw": 0, "prism_raw": 0, "prism_gzip_each": 0}
    for man_key in sorted(os.listdir(fx_dir)):
        mdir = os.path.join(fx_dir, man_key)
        if not os.path.isdir(mdir) or (only and man_key not in only):
            continue
        for fname in sorted(os.listdir(mdir)):
            if not fname.endswith(".json"):
                continue
            path = os.path.join(mdir, fname)
            raw = open(path, "rb").read()
            fx = json.loads(raw)
            fx_key = fname[:-5]
            if "redirectTo" in fx:
                redirects.append({"from": "%s/%s" % (man_key, fx_key), "name": fx["name"],
                                  "to": fx["redirectTo"], "reason": fx["reason"]})
                continue
            sizes["ofl_raw"] += len(raw)
            try:
                pf = convert_fixture(man_key, fx_key, fx, manufacturers, commit)
            except Exception as exc:  # noqa: BLE001
                errors.append("%s/%s: %r" % (man_key, fx_key, exc))
                continue
            data = json.dumps(pf, **dump_kw).encode("utf-8")
            os.makedirs(os.path.join(args.out, "fixtures", man_key), exist_ok=True)
            with open(os.path.join(args.out, "fixtures", man_key, fx_key + ".json"), "wb") as fh:
                fh.write(data)
            sizes["prism_raw"] += len(data)
            sizes["prism_gzip_each"] += len(gzip.compress(data, 9))
            index.append(index_row(pf))
            # statistics
            stats["category"][pf["category"]] += 1
            stats["categorySource"][pf["categorySource"].split(":")[0]] += 1
            stats["fixtureComplexity"][index[-1]["cx"]] += 1
            for m in pf["modes"]:
                stats["modeComplexity"][m["complexity"]] += 1
                stats["modeColorModel"][m["colorModel"]] += 1
                for c in m["channels"]:
                    stats["slotKind"][c["kind"]] += 1
            for d in pf["definitions"].values():
                stats["definitionKind"][d["kind"]] += 1
                if d.get("kindFrom") == "name":
                    stats["kindFromName"][d["kind"]] += 1

    # alias rows for redirects (SameAsDifferentBrand => searchable under the other brand)
    by_id = {r["id"]: r for r in index}
    alias_rows = []
    for r in redirects:
        if r["to"] in by_id:
            alias_rows.append({"id": r["from"], "aliasOf": r["to"], "model": r["name"],
                               "mfr": r["from"].split("/")[0], "reason": r["reason"]})
    idx = {"$schema": "prism-fixture-index/1", "source": {"library": "ofl", "commit": commit, "license": "MIT"},
           "fixtures": index, "aliases": alias_rows}
    idx_data = json.dumps(idx, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    open(os.path.join(args.out, "index.json"), "wb").write(idx_data)

    counts = collections.Counter(r["mfr"] for r in index)
    mans = {k: {"name": v["name"], "website": v.get("website"), "rdmId": v.get("rdmId"),
                "count": counts.get(k, 0)} for k, v in manufacturers.items() if counts.get(k)}
    json.dump(mans, open(os.path.join(args.out, "manufacturers.json"), "w"), indent=1, ensure_ascii=False)
    shutil.copy(os.path.join(args.ofl, "LICENSE"), os.path.join(args.out, "LICENSE-OFL.txt"))

    # tarball-like single blob size estimate (what an app bundle would ship if packed)
    blob = b"".join(open(os.path.join(dp, f), "rb").read()
                    for dp, _, fs in os.walk(os.path.join(args.out, "fixtures")) for f in fs)
    sizes["prism_gzip_all"] = len(gzip.compress(blob, 9))
    sizes["index_raw"] = len(idx_data)
    sizes["index_gzip"] = len(gzip.compress(idx_data, 9))
    summary = {"commit": commit, "fixtures": len(index), "redirects": len(redirects),
               "aliasRows": len(alias_rows), "errors": errors, "sizes": sizes,
               "stats": {k: dict(v) for k, v in stats.items()}}
    json.dump(summary, open(os.path.join(args.out, "stats.json"), "w"), indent=1)
    print(json.dumps({k: summary[k] for k in ("fixtures", "redirects", "aliasRows", "sizes")}, indent=1))
    if errors:
        print("ERRORS (%d):" % len(errors), *errors[:20], sep="\n  ")


if __name__ == "__main__":
    sys.exit(main())
