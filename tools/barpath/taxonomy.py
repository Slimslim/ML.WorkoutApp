"""Workout taxonomy (docs/WORKOUT_TAXONOMY.md): five axes derived from a workout's structure.

Pure functions, no I/O. The classification is never stored; it is recomputed from the structure.

    modality      G / W / M per movement, plus the Hyrox station tags
    shape         single, couplet, triplet, chipper, rounds, ladder, intervals, strength_sets,
                  multi_part (+ modifiers: buy_in, cash_out, partner, max_effort, ...)
    time_domain   short / medium / long / very_long, from the cap, the windows or the estimated work
    loading       light / moderate / heavy relative to the athlete (their max when known, else the
                  RX standard as a proxy), unknown without a load or a reference
    scoring       time, rounds_reps, reps, load, calories_distance, pass_fail, none

Every axis comes back as {"value", "confidence", "reasons"}; confidence is high / medium / low, and
value "unknown" always has confidence "unknown". Reasons are short codes (never workout text).

Three adapters build the same intermediate form (`Workout`):
    from_v2(doc)            a schemaVersion 2 document (RFC #55 piece -> timed -> repeat -> part)
    from_v1(definition)     today's flat WorkoutDefinition dict (format, segments, cap, roundSize...)
    from_draft_piece(cls)   one scale classification of a workout_drafts row (the import's parse)
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

# ---- named constants (thresholds are owner questions, WORKOUT_TAXONOMY.md "Open questions") ------

SHORT_MAX_S = 8 * 60          # short: up to 8 min
MEDIUM_MAX_S = 15 * 60        # medium: up to 15 min
LONG_MAX_S = 30 * 60          # long: up to 30 min; very long beyond

# Estimated work pace when there is no clock (seconds).
SECONDS_PER_REP = {"G": 2.5, "W": 3.5, "M": 3.0}
RUN_M_PER_S = 3.3             # about 5:00 / km
ERG_M_PER_S = 4.0             # row / ski, about 2:05 / 500 m
SECONDS_PER_CAL = 4.0         # row / bike / ski calories
CARRY_M_PER_S = 1.2           # sled, farmers carry, lunges for distance
REST_BETWEEN_SETS_S = 120     # strength sets without a stated rest

# Loading: percent of the athlete's max (or of a stated %RM).
PCT_LIGHT_MAX = 65.0          # below: light
PCT_HEAVY_MIN = 80.0          # from here: heavy
# Loading against the RX standard when no max is known: load / RX.
RX_LIGHT_MAX = 0.75
RX_HEAVY_MIN = 1.10

CHIPPER_MIN_MOVEMENTS = 4     # one pass through 4+ movements is a chipper

LB_PER_KG = 2.20462

MODALITIES = ("G", "W", "M")
SHAPES = ("single", "couplet", "triplet", "chipper", "rounds", "ladder", "intervals",
          "strength_sets", "multi_part")
TIME_DOMAINS = ("short", "medium", "long", "very_long")
LOADINGS = ("light", "moderate", "heavy")
SCORINGS = ("time", "rounds_reps", "reps", "load", "calories_distance", "pass_fail", "none")
UNKNOWN = "unknown"

HYROX_STATIONS = ("skiErg", "sledPush", "sledPull", "burpeeBroadJumps", "row", "farmersCarry",
                  "sandbagLunges", "wallBalls")

# ---- movement lexicon -------------------------------------------------------------------------
# id -> (modality, RX standard in kg as (men, women) or None). Public CrossFit/Hyrox standards.
MOVEMENTS = {
    # monostructural
    "run": ("M", None), "row": ("M", None), "bike": ("M", None), "skiErg": ("M", None),
    "swim": ("M", None), "doubleUnders": ("M", None), "singleUnders": ("M", None),
    # gymnastics / bodyweight
    "pullUps": ("G", None), "strictPullUps": ("G", None), "chestToBar": ("G", None),
    "pushUps": ("G", None), "burpees": ("G", None), "burpeeBroadJumps": ("G", None),
    "airSquats": ("G", None), "sitUps": ("G", None), "toesToBar": ("G", None),
    "muscleUps": ("G", None), "handstandPushUps": ("G", None), "boxJumps": ("G", None),
    "lunges": ("G", None), "pistols": ("G", None), "ropeClimbs": ("G", None),
    "plank": ("G", None), "ringRows": ("G", None), "ringDips": ("G", None), "vUps": ("G", None),
    "stepOvers": ("G", None), "lateralBurpeeOverDumbbell": ("G", None),
    # weightlifting / loaded
    "thrusters": ("W", (43.0, 29.0)), "cleans": ("W", (61.0, 43.0)),
    "powerCleans": ("W", (61.0, 43.0)), "snatches": ("W", (43.0, 29.0)),
    "powerSnatches": ("W", (43.0, 29.0)), "cleanAndJerks": ("W", (61.0, 43.0)),
    "deadlifts": ("W", (102.0, 70.0)), "backSquat": ("W", None), "frontSquat": ("W", None),
    "overheadSquat": ("W", (43.0, 29.0)), "shoulderPress": ("W", None),
    "pushPress": ("W", (52.0, 34.0)), "pushJerk": ("W", (61.0, 43.0)),
    "benchPress": ("W", None), "dumbbellBenchPress": ("W", None), "barbellRow": ("W", None),
    "kettlebellSwings": ("W", (24.0, 16.0)), "wallBalls": ("W", (9.0, 6.0)),
    "dumbbellSnatch": ("W", (22.5, 15.0)), "alternatingDumbbellSnatch": ("W", (22.5, 15.0)),
    "devilPress": ("W", (22.5, 15.0)), "dumbbellOverShoulder": ("W", (22.5, 15.0)),
    "dumbbellWalkingLunges": ("W", (22.5, 15.0)), "medBallBoxStepOvers": ("W", (9.0, 6.0)),
    "sledPush": ("W", None), "sledPull": ("W", None), "farmersCarry": ("W", (2 * 24.0, 2 * 16.0)),
    "sandbagLunges": ("W", (20.0, 10.0)),
}

# Free-text names (the import's parse) -> id, by keyword, first match wins. Lowercase.
_NAME_RULES = (
    (r"\bski\s*-?\s*erg\b|\bski\b", "skiErg"),
    (r"\bsled\s+push", "sledPush"), (r"\bsled\s+(pull|drag)", "sledPull"),
    (r"burpee\s+broad\s+jump", "burpeeBroadJumps"),
    (r"farmer", "farmersCarry"), (r"sandbag\s+lunge", "sandbagLunges"),
    (r"wall\s*-?\s*ball", "wallBalls"),
    (r"\b(echo|assault|air)\s*bike\b|\bbike\b|\bbikeerg\b", "bike"),
    (r"\bring\s+rows?\b", "ringRows"),
    (r"\b(bent|pendlay|renegade|upright|barbell|bb|db|dumbbell|kb|kettlebell|seal)\b.*\brows?\b", "barbellRow"),
    (r"\brow(ing|er)?\b", "row"),
    (r"\brun(ning)?\b|\bjog\b|\bsprint", "run"), (r"\bswim", "swim"),
    (r"double\s*-?\s*under|\bdus?\b", "doubleUnders"), (r"single\s*-?\s*under|jump\s*rope", "singleUnders"),
    (r"chest\s*-?\s*to\s*-?\s*bar|\bc2b\b", "chestToBar"),
    (r"strict\s+pull\s*-?\s*up", "strictPullUps"), (r"pull\s*-?\s*up", "pullUps"),
    (r"muscle\s*-?\s*up", "muscleUps"), (r"handstand\s+push|\bhspu\b", "handstandPushUps"),
    (r"toes\s*-?\s*to\s*-?\s*bar|\bt2b\b|\bttb\b", "toesToBar"),
    (r"ring\s+row", "ringRows"), (r"ring\s+dip", "ringDips"),
    (r"lateral\s+burpee", "lateralBurpeeOverDumbbell"), (r"burpee", "burpees"),
    (r"push\s*-?\s*up", "pushUps"), (r"sit\s*-?\s*up", "sitUps"), (r"v\s*-?\s*up", "vUps"),
    (r"box\s+jump", "boxJumps"), (r"step\s*-?\s*over", "stepOvers"), (r"rope\s+climb", "ropeClimbs"),
    (r"pistol", "pistols"), (r"plank|hollow|hold\b", "plank"),
    (r"thruster", "thrusters"), (r"clean\s*(&|and)\s*jerk", "cleanAndJerks"),
    (r"power\s+clean", "powerCleans"), (r"power\s+snatch", "powerSnatches"),
    (r"(db|dumbbell).*snatch", "dumbbellSnatch"), (r"devil", "devilPress"),
    (r"(db|dumbbell).*(lunge)", "dumbbellWalkingLunges"),
    (r"(db|dumbbell).*bench", "dumbbellBenchPress"), (r"bench\s+press", "benchPress"),
    (r"snatch", "snatches"), (r"clean", "cleans"), (r"deadlift", "deadlifts"),
    (r"overhead\s+squat|\bohs\b", "overheadSquat"), (r"front\s+squat", "frontSquat"),
    (r"back\s+squat", "backSquat"), (r"push\s+press", "pushPress"), (r"push\s+jerk|\bjerk\b", "pushJerk"),
    (r"(strict|shoulder)\s+press", "shoulderPress"),
    (r"(kb|kettlebell)\s+swing|\bswings?\b", "kettlebellSwings"),
    (r"air\s+squat|\bsquats?\b", "airSquats"), (r"lunge", "lunges"),
)
# Words that make an unlisted movement loaded (W) or monostructural (M).
_W_WORDS = re.compile(r"\b(barbell|bb|dumbbell|db|kettlebell|kb|sandbag|med\s*ball|medball|weighted|"
                      r"plate|sled|yoke|press|squat|deadlift|clean|snatch|jerk|carry)\b")
_M_WORDS = re.compile(r"\b(erg|cal|calories|meters?|km|mile|miles)\b")
_G_WORDS = re.compile(r"\b(hang|kip|ring|bar|handstand|walk|crawl|jump|hold|tuck|l-sit|plank)\b")


def movement_id(name: str) -> Optional[str]:
    """Known movement id for a free-text name, or None."""
    if not name:
        return None
    if name in MOVEMENTS:
        return name
    s = name.lower()
    for pattern, mid in _NAME_RULES:
        if re.search(pattern, s):
            return mid
    return None


def modality_of(movement: str, loaded: bool = False) -> tuple:
    """(modality or None, reason). A known id uses the lexicon; an unknown name its keywords."""
    mid = movement_id(movement)
    if mid is not None:
        mod = MOVEMENTS[mid][0]
        if mod == "G" and loaded:
            return "W", "loaded_bodyweight"
        return mod, "lexicon"
    s = (movement or "").lower()
    if loaded or _W_WORDS.search(s):
        return "W", "keyword_w"
    if _M_WORDS.search(s):
        return "M", "keyword_m"
    if _G_WORDS.search(s):
        return "G", "keyword_g"
    return None, "unknown_movement"


# ---- intermediate form ------------------------------------------------------------------------

@dataclass
class Element:
    """One work part as listed (not as repeated)."""
    movement: str                       # id or free-text name
    unit: Optional[str] = None          # reps / calories / meters / seconds / max
    value: Optional[float] = None
    load_kg: Optional[float] = None     # absolute load (men's / first value)
    load_pct: Optional[float] = None    # percent of a max
    load_basis: Optional[str] = None    # 1RM / 3RM / TM
    pick_load: bool = False             # "pick a load", no number
    rounds: int = 1                     # passes of the element (from an enclosing repeat)


@dataclass
class Workout:
    elements: list = field(default_factory=list)
    pieces: int = 1                     # independent scored pieces
    cap_s: Optional[float] = None       # time cap / AMRAP clock
    window_s: Optional[float] = None    # one window of an interval ("every X")
    windows: Optional[int] = None       # number of windows
    passes: Optional[int] = None        # rounds of the main block; None = until the clock
    unbounded: bool = False             # repeat until the clock / athlete
    ladder: Optional[str] = None        # "ascending" / "descending" / "open"
    intervals: Optional[str] = None     # "emom" / "tabata" / "every" / "work_rest" / "windows"
    strength_sets: bool = False
    rest_s: float = 0.0                 # fixed rest in the whole workout
    ratio_rest: bool = False
    buy_in: bool = False
    cash_out: bool = False
    partner: bool = False
    max_effort: bool = False
    per_round_movements: bool = False   # a vary swaps the movement each round (Hyrox's stations)
    score: Optional[str] = None         # source score code, mapped by classify_scoring
    source: str = ""                    # v2 / v1 / draft
    notes: list = field(default_factory=list)  # adapter reason codes


_LOAD_RE = re.compile(r"(\d+(?:\.\d+)?)(?:\s*/\s*(\d+(?:\.\d+)?))?\s*(lbs?|kg)\b", re.I)
_PCT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%\s*(?:of\s*)?(\d)?\s*(rm|tm)?", re.I)
_NUM_RE = re.compile(r"(\d+(?:\.\d+)?)")


def parse_load(text) -> dict:
    """'95/65 lbs' -> load_kg (first value); '75% 1RM' -> load_pct, basis; 'pick load' -> pick_load."""
    out = {}
    if text is None:
        return out
    if isinstance(text, dict):
        if "percent" in text:
            out["load_pct"] = float(text["percent"])
            out["load_basis"] = text.get("basis", "1RM")
        elif "value" in text:
            v = float(text["value"])
            out["load_kg"] = v / LB_PER_KG if text.get("unit") == "lb" else v
        return out
    s = str(text)
    m = _PCT_RE.search(s)
    if m and "%" in s:
        out["load_pct"] = float(m.group(1))
        out["load_basis"] = ((m.group(2) or "1") + (m.group(3) or "RM").upper()) if m.group(3) else "1RM"
        return out
    m = _LOAD_RE.search(s)
    if m:
        v = float(m.group(1))
        out["load_kg"] = v / LB_PER_KG if m.group(3).lower().startswith("lb") else v
        return out
    if "pick" in s.lower():
        out["pick_load"] = True
    return out


# ---- adapters ---------------------------------------------------------------------------------

def from_v1(d: dict) -> Workout:
    """Today's flat definition. A written-out list is folded back by roundSize when it repeats."""
    w = Workout(source="v1")
    segs = [s for s in d.get("segments", []) if s.get("kind") != "rest"]
    rests = [s for s in d.get("segments", []) if s.get("kind") == "rest"]
    fmt = d.get("format")
    cap = d.get("timeCapSeconds")
    w.cap_s = float(cap) if cap else None
    interval = d.get("intervalSeconds")
    rs = d.get("roundSize")
    n_all = len(d.get("segments", []))
    passes = d.get("rounds")
    block = segs
    if rs and 0 < rs < n_all and not passes:
        block_all = d["segments"][:rs]
        if all(d["segments"][i]["movement"] == block_all[i % rs]["movement"] for i in range(n_all)):
            block = [s for s in block_all if s.get("kind") != "rest"]
            passes = -(-n_all // rs)
            w.notes.append("folded_written_out_rounds")
    for s in block:
        t = s.get("target") or {}
        e = Element(movement=s.get("movement", ""), unit=t.get("unit"), value=t.get("value"),
                    rounds=passes or 1)
        for k, v in parse_load(s.get("load")).items():
            setattr(e, k, v)
        w.elements.append(e)
    for r in rests:
        t = r.get("target") or {}
        if t.get("unit") == "seconds":
            w.rest_s += float(t.get("value") or 0)
    w.passes = passes
    if fmt == "amrap":
        w.unbounded = True
        w.score = "roundsReps"
    elif fmt == "emom":
        w.intervals = "emom" if interval else "every"
        w.window_s = float(interval) if interval else None
        if w.window_s and w.cap_s:
            w.windows = int(round(w.cap_s / w.window_s))
        w.score = "windowsCompleted"
    else:
        w.score = "time"
    if d.get("team") in ("doubles", "team"):
        w.partner = True
    w.ladder = _ladder_of_values([e.value for e in w.elements]) if passes is None else None
    return w


def _ladder_of_values(values) -> Optional[str]:
    """A movement whose target rises or falls across the listed parts (same movement repeated)."""
    vals = [v for v in values if isinstance(v, (int, float))]
    if len(vals) < 3:
        return None
    if all(b > a for a, b in zip(vals, vals[1:])):
        return "ascending"
    if all(b < a for a, b in zip(vals, vals[1:])):
        return "descending"
    return None


def _vary_values(spec):
    """Numeric per-round targets of one vary entry, or None (e.g. a list of movement patches)."""
    if isinstance(spec, dict) and "step" in spec:
        start, step = spec.get("from", 0), spec["step"]
        return [start, start + step, start + 2 * step]
    if isinstance(spec, list):
        if all(isinstance(v, (int, float)) for v in spec):
            return list(spec)
        if all(isinstance(v, dict) and "movement" not in v for v in spec):
            vals = [((v.get("target") or {}).get("value") if isinstance(v.get("target"), dict) else v.get("value"))
                    for v in spec]
            if all(isinstance(x, (int, float)) for x in vals):
                return vals
    return None


def _vary_direction(vary: dict) -> Optional[str]:
    """ascending / descending / open for numeric vary entries; None when the vary only swaps
    movements (Hyrox's 8 stations) or there is none."""
    dirs = set()
    numeric = False
    for spec in (vary or {}).values():
        vals = _vary_values(spec)
        if vals is None:
            continue
        numeric = True
        d = _ladder_of_values(vals) if len(vals) >= 3 else (
            "ascending" if len(vals) == 2 and vals[1] > vals[0] else
            "descending" if len(vals) == 2 and vals[1] < vals[0] else None)
        if d:
            dirs.add(d)
    if len(dirs) == 1:
        return dirs.pop()
    return "open" if numeric else None


def _node(wrapper: dict) -> tuple:
    from .workout_structure import node_kind
    return node_kind(wrapper)


def from_v2(doc: dict) -> Workout:
    """A schemaVersion 2 document: structure.body of part / rest / group / repeat / timed nodes."""
    w = Workout(source="v2")
    st = doc.get("structure") or {}
    if not st and isinstance(doc.get("scales"), list) and doc["scales"]:
        st = doc["scales"][0].get("structure") or {}
    score = st.get("score") or {}
    w.score = score.get("type")
    body = st.get("body") or []
    pieces = [n for n in body if _node(n)[0] in ("timed", "repeat")]
    if score.get("type") == "perPiece" and len(pieces) > 1:
        w.pieces = len(pieces)

    def add_part(c: dict, passes: Optional[int], vary: dict):
        spec = vary.get(c.get("id")) if c.get("id") else None
        if isinstance(spec, list) and any(isinstance(v, dict) and "movement" in v for v in spec):
            w.per_round_movements = True
            for v in spec:                       # per-round movements: one element per round
                t = v.get("target") or c.get("target") or {}
                w.elements.append(Element(movement=v.get("movement", c.get("movement", "")),
                                          unit=t.get("unit"), value=t.get("value"), rounds=1))
            return
        e = Element(movement=c.get("movement", ""), rounds=passes or 1)
        t = c.get("target") or {}
        e.unit, e.value = t.get("unit"), t.get("value")
        vals = _vary_values(spec) if spec is not None else None
        if vals:
            e.value = sum(vals) / len(vals)
        for k, v in parse_load(c.get("load")).items():
            setattr(e, k, v)
        if c.get("who") in ("partner", "together", "shared"):
            w.partner = True
        w.elements.append(e)

    def walk(nodes, passes: Optional[int], depth: int, inside_window: bool, vary: dict):
        for n in nodes:
            kind, c = _node(n)
            if kind is None:
                continue
            if kind == "part":
                add_part(c, passes, vary)
            elif kind == "rest":
                if "ratio" in c:
                    w.ratio_rest = True
                else:
                    w.rest_s += float(c.get("seconds") or 0) * (passes or 1)
            elif kind == "group":
                walk(c.get("body") or [], passes, depth, inside_window, vary)
            elif kind == "repeat":
                times = c.get("times")
                if times is None:
                    w.unbounded = True
                d = _vary_direction(c.get("vary") or {})
                if d:
                    w.ladder = d
                if depth == 0 and w.passes is None:
                    w.passes = times
                body_kinds = [_node(x)[0] for x in c.get("body") or []]
                if "timed" in body_kinds:
                    w.intervals = w.intervals or "windows"
                    w.windows = times
                elif ("rest" in body_kinds and times and times >= 2
                      and any(_node(x)[0] == "rest" and "seconds" in _node(x)[1] for x in c["body"])
                      and score.get("type") != "load"):
                    w.intervals = w.intervals or "work_rest"
                inner = dict(vary)
                inner.update(c.get("vary") or {})
                walk(c.get("body") or [], (passes or 1) * times if times else passes, depth + 1,
                     inside_window, inner)
            elif kind == "timed":
                secs = float(c.get("seconds") or 0)
                if not inside_window and depth == 0:
                    w.cap_s = (w.cap_s or 0) + secs
                else:
                    w.window_s = secs
                walk(c.get("body") or [], passes, depth, True, vary)

    walk(body, None, 0, False, {})
    # buy-in / cash-out: parts around the main repeat, at the top or directly inside the clock
    top = body
    if len(body) == 1 and _node(body[0])[0] == "timed":
        top = _node(body[0])[1].get("body") or []
    kinds = [_node(n)[0] for n in top]
    if "repeat" in kinds:
        first, last = kinds.index("repeat"), len(kinds) - 1 - kinds[::-1].index("repeat")
        w.buy_in = any(k == "part" for k in kinds[:first])
        w.cash_out = any(k == "part" for k in kinds[last + 1:])
    if w.intervals and w.window_s and w.windows and not w.cap_s:
        w.cap_s = w.window_s * w.windows
    if score.get("type") == "load":
        w.strength_sets = True
    if doc.get("team") in ("doubles", "team"):
        w.partner = True
    return w


_DRAFT_INTERVAL_KINDS = {"emom": "emom", "tabata": "tabata", "intervals_max_reps": "work_rest",
                         "repeat_windows_max_reps": "windows", "window_buyin_max_reps": "windows",
                         "window_max_distance": "windows", "station_rotation": "windows",
                         "death_by": "emom"}
_DRAFT_SCORE = {
    "time": "time", "time per round": "time", "time per effort": "time",
    "rounds+reps": "roundsReps", "rounds + reps": "roundsReps", "rounds+reps cumulative": "roundsReps",
    "reps": "totalReps", "total reps": "totalReps", "reps per window": "totalReps",
    "reps (total or per interval)": "totalReps", "reps after buy-in (time if not finished?)": "totalReps",
    "load": "load", "load, reps or hold time": "load", "distance": "distance",
    "distance per effort": "distance", "none": "none", "none or max reps": "none",
}
_MIN_RE = re.compile(r"(\d+)\s*(?:min|mins|minutes|')(?![a-z])", re.I)
_FOR_MIN_RE = re.compile(r"\bfor\s*(\d+)\s*(?:min|mins|minutes)(?![a-z])", re.I)
_AMRAP_RE = re.compile(r"\bamrap\s*(\d+)\b", re.I)
_EVERY_RE = re.compile(r"\bevery\s*(\d+)\s*(min|mins|minutes|sec|secs|seconds)(?![a-z])|\bevery\s*(\d+):(\d\d)\b"
                       r"|\be(\d)mom\b", re.I)


def header_clock(text: str) -> tuple:
    """(total seconds or None, window seconds or None) from a piece header such as 'AMRAP 12',
    'Every 3 mins for 15 mins' or 'E2MOM x 6'. Numbers only; the text is not kept."""
    total = window = None
    m = _EVERY_RE.search(text)
    if m:
        if m.group(1):
            window = float(m.group(1)) * (1 if m.group(2).lower().startswith("sec") else 60)
        elif m.group(3):
            window = int(m.group(3)) * 60 + int(m.group(4))
        else:
            window = int(m.group(5)) * 60
    m = _FOR_MIN_RE.search(text) or _AMRAP_RE.search(text)
    if m:
        total = float(m.group(1)) * 60
    elif window is None:
        m = _MIN_RE.search(text)
        if m:
            total = float(m.group(1)) * 60
    return total, window


def _num(v) -> Optional[float]:
    if v is None:
        return None
    m = _NUM_RE.search(str(v))
    return float(m.group(1)) if m else None


def from_draft_piece(cls: dict) -> Workout:
    """One scale classification of a workout_drafts row: format, flags, scoring and the import's
    parse (pieces with kind, rounds, window_s and movements {name, reps, load, distance, unit, time}).
    The header text is read for minutes only; nothing is kept."""
    w = Workout(source="draft")
    fmt = str(cls.get("format") or "")
    flags = set(cls.get("flags") or [])
    parsed = cls.get("parsed") or []
    scoring = cls.get("scoring") or []
    if fmt.startswith("multi_part") or "pieces)" in fmt or len(parsed) > 1:
        w.pieces = max(len(parsed), 2)
    base = fmt.split("(")[0].replace("multi_part:", "").split("+")[0]
    if scoring:
        w.score = _DRAFT_SCORE.get(str(scoring[0]).strip().lower())
        if w.score is None:
            w.notes.append("score_ambiguous")
    total_cap = 0.0
    for piece in parsed:
        kind = piece.get("kind") or base
        rounds = piece.get("rounds")
        rounds = int(rounds) if isinstance(rounds, (int, float)) and rounds > 0 else None
        if kind in _DRAFT_INTERVAL_KINDS:
            w.intervals = w.intervals or _DRAFT_INTERVAL_KINDS[kind]
        if kind == "strength_sets":
            w.strength_sets = True
        if kind in ("max_effort_test",):
            w.max_effort = True
        if kind in ("amrap_rounds", "amrap_reps", "cycles_continued_amrap"):
            w.unbounded = True
        if kind == "rft_each_round_timed":
            w.ratio_rest = True
        if piece.get("window_s"):
            w.window_s = float(piece["window_s"])
            if rounds:
                w.windows = (w.windows or 0) + rounds
                total_cap += w.window_s * rounds
        header = " ".join([str(piece.get("header") or "")] +
                          [str(mv.get("name") or "") for mv in piece.get("movements") or []
                           if not any(mv.get(k) for k in ("reps", "load", "distance", "time"))])
        h_total, h_window = header_clock(header)
        if h_window and not piece.get("window_s"):
            w.window_s = h_window
            if h_total:
                w.windows = (w.windows or 0) + int(round(h_total / h_window))
            elif rounds:
                w.windows = (w.windows or 0) + rounds
                h_total = h_window * rounds
            w.notes.append("window_from_header")
        if h_total and not piece.get("window_s"):
            total_cap += h_total
            w.notes.append("minutes_from_header")
        if rounds and w.passes is None and not piece.get("window_s"):
            w.passes = rounds
        for mv in piece.get("movements") or []:
            if not any(mv.get(k) for k in ("reps", "load", "distance", "time", "unit")) and \
                    tx_is_instruction(str(mv.get("name") or "")):
                w.notes.append("instruction_line")
                continue
            e = Element(movement=str(mv.get("name") or ""), rounds=rounds or 1)
            if mv.get("distance"):
                e.unit, e.value = "meters", _distance_m(mv["distance"])
            elif str(mv.get("unit") or "").lower().startswith("cal"):
                e.unit, e.value = "calories", _num(mv.get("reps"))
            elif mv.get("time"):
                e.unit, e.value = "seconds", _seconds(mv["time"])
            elif str(mv.get("reps") or "").lower() == "max":
                e.unit = "max"
            elif mv.get("reps") is not None:
                e.unit, e.value = "reps", _num(mv.get("reps"))
            for k, v in parse_load(mv.get("load")).items():
                setattr(e, k, v)
            w.elements.append(e)
    if total_cap > 0:
        w.cap_s = total_cap
    if "ladder_ascending" in flags:
        w.ladder = "ascending"
    elif "ladder_descending" in flags:
        w.ladder = "descending"
    elif "open_ended_ladder" in flags or base == "death_by":
        w.ladder = "open"
    if "partner" in flags:
        w.partner = True
    if "buyin_cashout_named" in flags or base == "window_buyin_max_reps":
        w.buy_in = True
    if "hyrox_track" in flags:
        w.notes.append("hyrox_track")
    if base in ("quality",):
        w.notes.append("quality_untimed")
    w.notes.append("format:" + base)
    return w


def tx_is_instruction(name: str) -> bool:
    """A parsed 'movement' that is really an instruction line: long, or a clock phrase."""
    return len(name.split()) > 6 or bool(_EVERY_RE.search(name) or _FOR_MIN_RE.search(name))


def _distance_m(text) -> Optional[float]:
    v = _num(text)
    if v is None:
        return None
    s = str(text).lower()
    if "km" in s:
        return v * 1000
    if "mi" in s:
        return v * 1609.344
    if "ft" in s:
        return v * 0.3048
    return v


def _seconds(text) -> Optional[float]:
    s = str(text).lower()
    m = re.search(r"(\d+):(\d\d)", s)
    if m:
        return int(m.group(1)) * 60 + int(m.group(2))
    v = _num(s)
    if v is None:
        return None
    return v * 60 if "min" in s else v


# ---- axes -------------------------------------------------------------------------------------

def _axis(value, confidence, reasons):
    if value == UNKNOWN:
        confidence = UNKNOWN
    return {"value": value, "confidence": confidence, "reasons": list(reasons)}


def classify_modality(w: Workout) -> dict:
    mods, tags, reasons, unknown = [], [], [], 0
    for e in w.elements:
        loaded = e.load_kg is not None or e.load_pct is not None or e.pick_load
        mod, why = modality_of(e.movement, loaded)
        if mod is None:
            unknown += 1
            continue
        if mod not in mods:
            mods.append(mod)
        mid = movement_id(e.movement)
        if mid in HYROX_STATIONS and mid not in tags:
            tags.append(mid)
        if why not in reasons:
            reasons.append(why)
    if not mods:
        return dict(_axis(UNKNOWN, UNKNOWN, reasons or ["no_movements"]), stations=[])
    if unknown:
        reasons.append("unknown_movements:%d" % unknown)
    conf = "high" if unknown == 0 and "lexicon" in reasons and len(reasons) == 1 else (
        "medium" if unknown == 0 else "low")
    return dict(_axis("".join(m for m in MODALITIES if m in mods), conf, reasons), stations=tags)


GENERIC_MOVEMENTS = ("part", "rest", "")


def _distinct_movements(w: Workout) -> int:
    keys = []
    for e in w.elements:
        if e.movement in GENERIC_MOVEMENTS:
            continue
        k = movement_id(e.movement) or e.movement.strip().lower()
        if k and k not in keys:
            keys.append(k)
    return len(keys)


def classify_shape(w: Workout) -> dict:
    mods = [m for m, on in (("buy_in", w.buy_in), ("cash_out", w.cash_out), ("partner", w.partner),
                            ("max_effort", w.max_effort), ("ratio_rest", w.ratio_rest)) if on]
    n = _distinct_movements(w)
    if w.pieces > 1:
        return dict(_axis("multi_part", "high", ["pieces:%d" % w.pieces]), modifiers=mods)
    if w.strength_sets:
        return dict(_axis("strength_sets", "high", ["sets_scored_by_load"]), modifiers=mods)
    if w.intervals:
        if w.ladder:
            mods.append("ladder_" + w.ladder)
        return dict(_axis("intervals", "high", ["intervals:" + w.intervals]), modifiers=mods)
    if w.ladder:
        return dict(_axis("ladder", "high" if w.ladder != "open" else "medium",
                          ["ladder:" + w.ladder]), modifiers=mods)
    if n == 0:
        return dict(_axis(UNKNOWN, UNKNOWN, ["no_movements"]), modifiers=mods)
    one_pass = not w.unbounded and (w.passes in (None, 1) or w.per_round_movements)
    if n >= CHIPPER_MIN_MOVEMENTS:
        if one_pass:
            return dict(_axis("chipper", "high", ["movements:%d" % n, "one_pass"]), modifiers=mods)
        return dict(_axis("rounds", "medium", ["movements:%d" % n, "repeats"]), modifiers=mods)
    name = {1: "single", 2: "couplet", 3: "triplet"}[n]
    return dict(_axis(name, "high", ["movements:%d" % n]), modifiers=mods)


def _element_seconds(e: Element) -> Optional[float]:
    mid = movement_id(e.movement)
    mod = modality_of(e.movement, e.load_kg is not None)[0] or "G"
    if e.unit == "seconds" and e.value:
        return e.value
    if e.unit == "meters" and e.value:
        if mid == "run":
            return e.value / RUN_M_PER_S
        if mid in ("row", "skiErg", "bike", "swim"):
            return e.value / ERG_M_PER_S
        return e.value / CARRY_M_PER_S
    if e.unit == "calories" and e.value:
        return e.value * SECONDS_PER_CAL
    if e.unit == "reps" and e.value:
        return e.value * SECONDS_PER_REP[mod]
    return None


def _work_seconds(w: Workout) -> tuple:
    """(estimated seconds of the listed work or None, confidence)."""
    total, missing = 0.0, 0
    for e in w.elements:
        s = _element_seconds(e)
        if s is None:
            missing += 1
            continue
        total += s * (e.rounds or 1)
    if w.strength_sets:
        sets = max((e.rounds for e in w.elements), default=1)
        total += REST_BETWEEN_SETS_S * max(0, sets - 1)
    total += w.rest_s
    if total <= 0:
        return None, UNKNOWN
    return total, "low" if missing else "medium"


def estimated_seconds(w: Workout) -> tuple:
    """(seconds or None, source, confidence). A clock (AMRAP, windows) is the duration. A for-time
    cap is only an upper bound: the estimated work is used when it is shorter."""
    if w.cap_s and w.score == "time" and not w.intervals:
        work, conf = _work_seconds(w)
        if work is not None and work < w.cap_s:
            return work, "estimated_under_cap", conf
        return w.cap_s, "cap_upper_bound", "medium"
    if w.cap_s:
        return w.cap_s, "clock", "high"
    if w.window_s and w.windows:
        return w.window_s * w.windows, "windows", "high"
    if w.unbounded:
        return None, "unbounded_without_clock", UNKNOWN
    work, conf = _work_seconds(w)
    if work is None:
        return None, "no_work_estimate", UNKNOWN
    return work, "estimated_work", conf


def classify_time_domain(w: Workout) -> dict:
    secs, src, conf = estimated_seconds(w)
    if secs is None:
        return dict(_axis(UNKNOWN, UNKNOWN, [src]), seconds=None)
    if secs <= SHORT_MAX_S:
        v = "short"
    elif secs <= MEDIUM_MAX_S:
        v = "medium"
    elif secs <= LONG_MAX_S:
        v = "long"
    else:
        v = "very_long"
    return dict(_axis(v, conf, [src]), seconds=round(secs))


def _level_pct(p: float) -> str:
    return "light" if p < PCT_LIGHT_MAX else ("heavy" if p >= PCT_HEAVY_MIN else "moderate")


def _level_rx(ratio: float) -> str:
    return "light" if ratio < RX_LIGHT_MAX else ("heavy" if ratio >= RX_HEAVY_MIN else "moderate")


_ORDER = {"light": 0, "moderate": 1, "heavy": 2}


def classify_loading(w: Workout, athlete_max_kg: Optional[dict] = None, sex: str = "m") -> dict:
    """The heaviest loaded element decides. With the athlete's max for that movement: % of max.
    With a stated % of a max: that percent. Otherwise the RX standard as a proxy (medium
    confidence). No load or no reference: unknown."""
    best, reasons, conf = None, [], "high"
    for e in w.elements:
        mid = movement_id(e.movement)
        level, why, c = None, None, "high"
        if e.load_pct is not None:
            level, why = _level_pct(e.load_pct), "percent_of_max"
        elif e.load_kg is not None and athlete_max_kg and mid in athlete_max_kg:
            level, why = _level_pct(100.0 * e.load_kg / athlete_max_kg[mid]), "athlete_max"
        elif e.load_kg is not None and mid in MOVEMENTS and MOVEMENTS[mid][1]:
            rx = MOVEMENTS[mid][1][0 if sex == "m" else 1]
            level, why, c = _level_rx(e.load_kg / rx), "rx_standard", "medium"
        elif e.load_kg is not None:
            why = "no_reference"
        elif e.pick_load:
            why = "pick_load"
        if why and why not in reasons:
            reasons.append(why)
        if level and (best is None or _ORDER[level] > _ORDER[best]):
            best = level
            conf = c
    if best is None:
        return _axis(UNKNOWN, UNKNOWN, reasons or ["no_load"])
    return _axis(best, conf, reasons)


_SCORE_MAP = {"time": "time", "roundsReps": "rounds_reps", "totalReps": "reps", "lowestReps": "reps",
              "load": "load", "distance": "calories_distance", "calories": "calories_distance",
              "maxHeight": "calories_distance", "longestHold": "time",
              "windowsCompleted": "pass_fail", "none": "none"}


def classify_scoring(w: Workout) -> dict:
    if w.score is None:
        return _axis(UNKNOWN, UNKNOWN, ["no_score"] + [n for n in w.notes if n == "score_ambiguous"])
    if w.score == "perPiece":
        return _axis("time", "low", ["per_piece"])
    v = _SCORE_MAP.get(w.score)
    if v is None:
        return _axis(UNKNOWN, UNKNOWN, ["score:" + str(w.score)])
    conf = "medium" if (w.source == "v1" and w.score == "windowsCompleted") else "high"
    return _axis(v, conf, ["score:" + w.score])


def classify(w: Workout, athlete_max_kg: Optional[dict] = None, sex: str = "m") -> dict:
    return {
        "modality": classify_modality(w),
        "shape": classify_shape(w),
        "time_domain": classify_time_domain(w),
        "loading": classify_loading(w, athlete_max_kg, sex),
        "scoring": classify_scoring(w),
        "source": w.source,
    }


def classify_definition(doc: dict, **kw) -> dict:
    """Any definition: v2 when it has a structure, else today's flat format."""
    if doc.get("schemaVersion") == 2 and (doc.get("structure") or doc.get("scales")):
        return classify(from_v2(doc), **kw)
    return classify(from_v1(doc), **kw)
