"""Workout taxonomy (docs/WORKOUT_TAXONOMY.md): labels derived from a workout's structure.

Pure functions, no I/O. The classification is never stored; it is recomputed from the structure.

    modality      G / W / M present, the primary one (largest share of the estimated time), the
                  Hyrox station tags; weighted bodyweight stays G (flag `loaded`)
    movements     single / couplet / triplet / 4plus: the main work only (buy-in and cash-out excluded)
    structure     for_time / rounds / amrap / chipper / ladder / intervals / strength / practice /
                  multi_part, plus modifiers (reps_descending, pyramid, complex, buy_in, partner:..., ...)
    time_domain   short / medium / long / very_long from the work time; n/a for strength and practice
    loading       light / moderate / heavy / bodyweight, relative to the athlete: their max, a stated
                  %RM, else the standard for that implement, scale and sex (a proxy); unknown when
                  loaded without a reference; n/a for practice
    scoring       time, rounds_reps, reps, load, calories_distance, pass_fail, none

Every axis returns {"value", "confidence", "reasons"}; confidence is high / medium / low, value
"unknown" has confidence "unknown", value "n/a" has confidence "high". Reasons are short codes.

Three adapters build the same intermediate form (`Workout`):
    from_v2(doc)            a schemaVersion 2 document (RFC #55 piece -> timed -> repeat -> part)
    from_v1(definition)     today's flat WorkoutDefinition dict
    from_draft_piece(cls)   one scale classification of a workout_drafts row (the import's parse)
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

# ---- named constants (owner questions in WORKOUT_TAXONOMY.md) ----------------------------------

SHORT_MAX_S = 8 * 60          # short: up to 8 min of work
MEDIUM_MAX_S = 15 * 60        # medium: up to 15 min
LONG_MAX_S = 30 * 60          # long: up to 30 min; very long beyond
WORK_BOUT_SHORT_MAX_S = 60    # interval bouts: short up to 1:00
WORK_BOUT_MEDIUM_MAX_S = 180  # medium up to 3:00; long beyond

PCT_LIGHT_MAX = 65.0          # % of a max below which a load is light
PCT_HEAVY_MIN = 80.0          # from here heavy
RX_LIGHT_MAX = 0.75           # load / standard below which a load is light
RX_HEAVY_MIN = 1.10           # from here heavy
STRENGTH_MAX_REPS = 6         # reps per set at or below which loaded sets are strength
CHIPPER_MIN_MOVEMENTS = 4

LB_PER_KG = 2.20462
UNKNOWN = "unknown"
NA = "n/a"

# Pace (seconds per rep) per movement; open-division athlete. Fallback per modality.
SECONDS_PER_REP = {
    "doubleUnders": 0.65, "singleUnders": 0.4, "pullUps": 1.75, "strictPullUps": 2.5,
    "chestToBar": 2.0, "muscleUps": 5.5, "barMuscleUps": 4.0, "pushUps": 1.5, "burpees": 4.5,
    "lateralBurpeeOverDumbbell": 4.5, "airSquats": 1.2, "sitUps": 1.5, "ghdSitUps": 2.0,
    "toesToBar": 2.0, "toesToRing": 2.0, "handstandPushUps": 3.0, "boxJumps": 2.5, "lunges": 1.5,
    "pistols": 2.5, "ropeClimbs": 25.0, "wallWalks": 15.0, "ringDips": 2.0, "ringRows": 1.5,
    "vUps": 1.5, "wallBalls": 2.75, "thrusters": 2.75, "kettlebellSwings": 2.0,
    "gobletSquats": 2.0, "dumbbellSnatch": 2.5, "devilPress": 5.0, "sandbagToShoulder": 5.0,
    "stoneToShoulder": 6.0, "sumoDeadliftHighPull": 2.0,
}
SECONDS_PER_REP_DEFAULT = {"G": 2.5, "W": 3.5, "M": 1.0}
SECONDS_PER_REP_HEAVY = 6.5   # barbell reps at a heavy load (>= 80 % or >= 1.10 x standard)
SECONDS_PER_CAL = {"bike": 2.75, "bikeErg": 3.75, "row": 3.75, "skiErg": 4.5}
SECONDS_PER_CAL_DEFAULT = 3.75
METERS_PER_SECOND = {          # distance work
    "run": 3.3, "row": 4.0, "skiErg": 3.57, "bikeErg": 9.0, "bike": 9.0, "swim": 1.0,
    "farmersCarry": 1.2, "sledPush": 0.4, "sledPull": 0.35, "sandbagLunges": 0.45,
    "burpeeBroadJumps": 0.4, "lunges": 0.6, "dumbbellWalkingLunges": 0.6, "bearCrawl": 0.5,
    "shuttleRun": 2.5, "yokeCarry": 0.8,
}
METERS_PER_SECOND_DEFAULT = 1.2
ROXZONE_S = 25.0              # Hyrox transition allowance per run <-> station change
STRENGTH_REST_S = 120.0       # rest between strength sets when none is stated

# ---- movements ---------------------------------------------------------------------------------
# id -> modality. Implements and loads are resolved separately (IMPLEMENT_OF, STANDARDS).
MOVEMENTS = {
    "run": "M", "row": "M", "bike": "M", "bikeErg": "M", "skiErg": "M", "swim": "M",
    "doubleUnders": "M", "singleUnders": "M", "shuttleRun": "M",
    "pullUps": "G", "strictPullUps": "G", "chestToBar": "G", "pushUps": "G", "burpees": "G",
    "burpeeBroadJumps": "G", "airSquats": "G", "sitUps": "G", "ghdSitUps": "G", "toesToBar": "G",
    "toesToRing": "G", "muscleUps": "G", "barMuscleUps": "G", "handstandPushUps": "G",
    "boxJumps": "G", "lunges": "G", "pistols": "G", "ropeClimbs": "G", "plank": "G",
    "ringRows": "G", "ringDips": "G", "vUps": "G", "stepOvers": "G", "wallWalks": "G",
    "bearCrawl": "G", "lateralBurpeeOverDumbbell": "G",
    "thrusters": "W", "cleans": "W", "powerCleans": "W", "snatches": "W", "powerSnatches": "W",
    "cleanAndJerks": "W", "deadlifts": "W", "backSquat": "W", "frontSquat": "W",
    "overheadSquat": "W", "shoulderPress": "W", "pushPress": "W", "pushJerk": "W",
    "benchPress": "W", "dumbbellBenchPress": "W", "barbellRow": "W", "sumoDeadliftHighPull": "W",
    "kettlebellSwings": "W", "gobletSquats": "W", "wallBalls": "W", "dumbbellSnatch": "W",
    "alternatingDumbbellSnatch": "W", "devilPress": "W", "dumbbellOverShoulder": "W",
    "dumbbellWalkingLunges": "W", "frontRackLunges": "W", "medBallBoxStepOvers": "W",
    "sledPush": "W", "sledPull": "W", "farmersCarry": "W", "sandbagLunges": "W",
    "sandbagToShoulder": "W", "stoneToShoulder": "W", "yokeCarry": "W",
}
HYROX_STATIONS = ("skiErg", "sledPush", "sledPull", "burpeeBroadJumps", "row", "farmersCarry",
                  "sandbagLunges", "wallBalls")
ODD_OBJECTS = ("sandbagToShoulder", "stoneToShoulder", "yokeCarry")
BARBELL_LIFTS = ("thrusters", "cleans", "powerCleans", "snatches", "powerSnatches", "cleanAndJerks",
                 "deadlifts", "backSquat", "frontSquat", "overheadSquat", "shoulderPress", "pushPress",
                 "pushJerk", "benchPress", "barbellRow", "sumoDeadliftHighPull")
# The implement a movement id implies (others are resolved from the name, default barbell).
IMPLEMENT_OF = {
    "kettlebellSwings": "kettlebell", "gobletSquats": "kettlebell", "wallBalls": "medball",
    "medBallBoxStepOvers": "medball", "dumbbellSnatch": "dumbbell", "alternatingDumbbellSnatch": "dumbbell",
    "devilPress": "dumbbell_pair", "dumbbellOverShoulder": "dumbbell", "dumbbellWalkingLunges": "dumbbell_pair",
    "dumbbellBenchPress": "dumbbell_pair", "farmersCarry": "dumbbell_pair", "sandbagLunges": "sandbag",
    "sandbagToShoulder": "sandbag", "stoneToShoulder": "stone", "sledPush": "sled", "sledPull": "sled",
    "yokeCarry": "yoke", "frontRackLunges": "barbell",
}
# Standards in kg (men, women), per (movement, implement). Public CrossFit standards. Pairs give the
# weight of one dumbbell. A movement + implement with no entry has no reference (loading unknown).
STANDARDS = {
    ("thrusters", "barbell"): (43.0, 29.0), ("cleans", "barbell"): (61.0, 43.0),
    ("powerCleans", "barbell"): (61.0, 43.0), ("snatches", "barbell"): (43.0, 29.0),
    ("powerSnatches", "barbell"): (43.0, 29.0), ("cleanAndJerks", "barbell"): (61.0, 43.0),
    ("deadlifts", "barbell"): (102.0, 70.0), ("overheadSquat", "barbell"): (43.0, 29.0),
    ("pushPress", "barbell"): (52.0, 34.0), ("pushJerk", "barbell"): (61.0, 43.0),
    ("sumoDeadliftHighPull", "barbell"): (34.0, 25.0),
    ("thrusters", "dumbbell"): (22.5, 15.0), ("thrusters", "dumbbell_pair"): (22.5, 15.0),
    ("cleans", "dumbbell"): (22.5, 15.0), ("cleans", "dumbbell_pair"): (22.5, 15.0),
    ("dumbbellSnatch", "dumbbell"): (22.5, 15.0), ("alternatingDumbbellSnatch", "dumbbell"): (22.5, 15.0),
    ("devilPress", "dumbbell_pair"): (22.5, 15.0), ("dumbbellOverShoulder", "dumbbell"): (22.5, 15.0),
    ("dumbbellWalkingLunges", "dumbbell_pair"): (22.5, 15.0), ("medBallBoxStepOvers", "medball"): (9.0, 6.0),
    ("kettlebellSwings", "kettlebell"): (24.0, 16.0), ("gobletSquats", "kettlebell"): (24.0, 16.0),
    ("cleans", "kettlebell"): (24.0, 16.0), ("snatches", "kettlebell"): (24.0, 16.0),
    ("wallBalls", "medball"): (9.0, 6.0), ("cleans", "medball"): (9.0, 6.0),
}
# Hyrox race divisions: (open men, open women, pro men, pro women) in kg. CHECK THE CURRENT HYROX
# RULEBOOK before relying on these; sled figures are the total sled weight.
HYROX_DIVISIONS = {
    "sledPush": (152.0, 102.0, 202.0, 152.0), "sledPull": (103.0, 78.0, 153.0, 103.0),
    "sandbagLunges": (20.0, 10.0, 30.0, 20.0), "farmersCarry": (24.0, 16.0, 32.0, 24.0),
    "wallBalls": (6.0, 4.0, 9.0, 6.0),
}

# Free-text names (the import's parse) -> id, first match wins. Lowercase.
_NAME_RULES = (
    (r"\bski\s*-?\s*erg\b|\bski\b", "skiErg"),
    (r"\bsled\s+push", "sledPush"), (r"\bsled\s+(pull|drag)", "sledPull"),
    (r"burpee\s+broad\s+jump", "burpeeBroadJumps"),
    (r"farmer", "farmersCarry"), (r"sandbag\s+lunge", "sandbagLunges"),
    (r"sandbag.*shoulder", "sandbagToShoulder"), (r"(d-?ball|atlas|stone).*(shoulder|over|lap)?", "stoneToShoulder"),
    (r"\byoke\b", "yokeCarry"), (r"bear\s+crawl", "bearCrawl"), (r"shuttle", "shuttleRun"),
    (r"wall\s*-?\s*walk", "wallWalks"),
    (r"wall\s*-?\s*ball", "wallBalls"),
    (r"bike\s*-?\s*erg", "bikeErg"),
    (r"\b(echo|assault|air)\s*bike\b|\bbike\b", "bike"),
    (r"\bring\s+rows?\b", "ringRows"),
    (r"\b(bent|pendlay|renegade|upright|barbell|bb|db|dumbbell|kb|kettlebell|seal)\b.*\brows?\b", "barbellRow"),
    (r"\brow(ing|er)?\b", "row"),
    (r"\brun(ning)?\b|\bjog\b|\bsprint", "run"), (r"\bswim", "swim"),
    (r"double\s*-?\s*under|\bdus?\b", "doubleUnders"), (r"single\s*-?\s*under|jump\s*rope", "singleUnders"),
    (r"chest\s*-?\s*to\s*-?\s*bar|\bc2b\b", "chestToBar"),
    (r"bar\s+muscle", "barMuscleUps"), (r"muscle\s*-?\s*up", "muscleUps"),
    (r"strict\s+(pull|chin)\s*-?\s*up", "strictPullUps"), (r"(pull|chin)\s*-?\s*up", "pullUps"),
    (r"handstand\s+push|\bhspu\b", "handstandPushUps"),
    (r"toes\s*-?\s*to\s*-?\s*ring", "toesToRing"), (r"toes\s*-?\s*to\s*-?\s*bar|\bt2b\b|\bttb\b", "toesToBar"),
    (r"ring\s+dip", "ringDips"),
    (r"lateral\s+burpee", "lateralBurpeeOverDumbbell"), (r"burpee", "burpees"),
    (r"push\s*-?\s*up", "pushUps"), (r"ghd\s+sit", "ghdSitUps"), (r"sit\s*-?\s*up", "sitUps"),
    (r"v\s*-?\s*up", "vUps"),
    (r"box\s+jump", "boxJumps"), (r"step\s*-?\s*over", "stepOvers"), (r"rope\s+climb", "ropeClimbs"),
    (r"pistol", "pistols"), (r"plank|hollow|\bhold\b", "plank"),
    (r"sumo\s+deadlift\s+high\s+pull|\bsdhp\b", "sumoDeadliftHighPull"),
    (r"thruster", "thrusters"), (r"clean\s*(&|and)\s*jerk", "cleanAndJerks"),
    (r"power\s+clean", "powerCleans"), (r"power\s+snatch", "powerSnatches"),
    (r"(db|dumbbell).*snatch", "dumbbellSnatch"), (r"devil", "devilPress"),
    (r"front\s*-?\s*rack.*lunge", "frontRackLunges"), (r"(db|dumbbell).*lunge", "dumbbellWalkingLunges"),
    (r"(db|dumbbell).*bench", "dumbbellBenchPress"), (r"bench\s+press", "benchPress"),
    (r"goblet", "gobletSquats"),
    (r"(kb|kettlebell).*swing|\bswings?\b", "kettlebellSwings"),
    (r"snatch", "snatches"), (r"clean", "cleans"), (r"deadlift", "deadlifts"),
    (r"overhead\s+squat|\bohs\b", "overheadSquat"), (r"front\s+squat", "frontSquat"),
    (r"back\s+squat", "backSquat"), (r"push\s+press", "pushPress"), (r"push\s+jerk|\bjerk\b", "pushJerk"),
    (r"(strict|shoulder)\s+press", "shoulderPress"),
    (r"air\s+squat|\bsquats?\b", "airSquats"), (r"lunge", "lunges"),
)
_W_WORDS = re.compile(r"\b(barbell|bb|dumbbell|db|kettlebell|kb|sandbag|med\s*ball|medball|weighted|"
                      r"plate|sled|yoke|press|squat|deadlift|clean|snatch|jerk|carry|goblet)\b")
_M_WORDS = re.compile(r"\b(erg|cal|calories|meters?|km|mile|miles)\b")
_G_WORDS = re.compile(r"\b(hang|kip|ring|bar|handstand|walk|crawl|jump|hold|tuck|l-sit|plank)\b")
_IMPLEMENT_WORDS = (
    (re.compile(r"\b(single\s+arm|single|1)\s*(db|dumbbell)\b|\b(db|dumbbell)\s+single\b", re.I), "dumbbell"),
    (re.compile(r"\b(db|dumbbell)s?\b", re.I), "dumbbell_pair"),
    (re.compile(r"\b(kb|kettlebell)s?\b", re.I), "kettlebell"),
    (re.compile(r"\bsandbag", re.I), "sandbag"),
    (re.compile(r"\b(med\s*ball|medball|wall\s*ball|slam\s*ball)", re.I), "medball"),
    (re.compile(r"\b(d-?ball|atlas|stone)\b", re.I), "stone"),
)


def movement_id(name) -> Optional[str]:
    """Known movement id for an id or a free-text name, or None."""
    if not isinstance(name, str) or not name:
        return None
    if name in MOVEMENTS:
        return name
    s = name.lower()
    for pattern, mid in _NAME_RULES:
        if re.search(pattern, s):
            return mid
    return None


def implement_of(name: str) -> Optional[str]:
    """barbell / dumbbell / dumbbell_pair / kettlebell / medball / sandbag / stone / sled / yoke, or
    None for bodyweight and monostructural movements."""
    mid = movement_id(name)
    if isinstance(name, str) and name not in MOVEMENTS:
        for rx, imp in _IMPLEMENT_WORDS:
            if rx.search(name):
                if imp == "dumbbell_pair" and mid in ("dumbbellSnatch", "alternatingDumbbellSnatch",
                                                     "dumbbellOverShoulder"):
                    return "dumbbell"
                return imp
    if mid in IMPLEMENT_OF:
        return IMPLEMENT_OF[mid]
    if mid in BARBELL_LIFTS:
        return "barbell"
    return None


def modality_of(name) -> tuple:
    """(modality or None, reason). Weighted bodyweight stays G: the load is a loading matter."""
    mid = movement_id(name)
    if mid is not None:
        return MOVEMENTS[mid], "lexicon"
    s = (name or "").lower() if isinstance(name, str) else ""
    if _W_WORDS.search(s):
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
    movement: str
    unit: Optional[str] = None          # reps / calories / meters / seconds / max
    value: Optional[float] = None       # per pass (mean over rounds when it varies)
    load_kg: Optional[float] = None     # men's / single value
    load_kg_f: Optional[float] = None   # women's value of "95/65 lb"
    load_pct: Optional[float] = None
    load_basis: Optional[str] = None
    pick_load: bool = False
    rounds: int = 1                     # passes of this element
    main: bool = True                   # False for buy-in / cash-out
    who: Optional[str] = None           # v2 who: me / partner / together / shared
    group: Optional[str] = None         # complex (one bar, unbroken)


@dataclass
class Workout:
    elements: list = field(default_factory=list)
    pieces: list = field(default_factory=list)   # sub-workouts of a multi-part workout
    cap_s: Optional[float] = None       # time cap / AMRAP clock
    clock_is_duration: bool = False     # the clock is the duration (AMRAP, windows), not a cap
    window_s: Optional[float] = None
    windows: Optional[int] = None
    work_s_per_window: Optional[float] = None   # Tabata 20 s of a 30 s window
    passes: Optional[int] = None
    unbounded: bool = False
    rep_scheme: Optional[str] = None    # descending / ascending / pyramid (known end)
    open_ladder: bool = False           # reps climb until a clock or failure
    intervals: Optional[str] = None     # emom / tabata / every / work_rest / windows
    rest_s: float = 0.0
    rest_ratio: Optional[float] = None
    buy_in: bool = False
    cash_out: bool = False
    partner: Optional[str] = None       # split type, "unknown" when only flagged
    team: Optional[str] = None          # solo / doubles / team
    max_effort: bool = False
    practice: bool = False
    complex: bool = False
    per_round_movements: bool = False
    score: Optional[str] = None
    source: str = ""
    notes: list = field(default_factory=list)


_LOAD_RE = re.compile(r"(\d+(?:\.\d+)?)(?:\s*/\s*(\d+(?:\.\d+)?))?\s*(lbs?|kg)\b", re.I)
_PCT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%\s*(?:of\s*)?(?:(\d)\s*(rm)|(tm))?", re.I)
_NUM_RE = re.compile(r"(\d+(?:\.\d+)?)")


def parse_load(text) -> dict:
    """'95/65 lbs' -> load_kg (men) and load_kg_f (women); '75% 1RM' -> load_pct, basis;
    'pick load' -> pick_load. A v2 load dict {value, unit} or {percent, basis}."""
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
        out["load_basis"] = (m.group(2) + "RM") if m.group(2) else ("TM" if m.group(4) else "1RM")
        return out
    m = _LOAD_RE.search(s)
    if m:
        k = 1 / LB_PER_KG if m.group(3).lower().startswith("lb") else 1.0
        out["load_kg"] = float(m.group(1)) * k
        if m.group(2):
            out["load_kg_f"] = float(m.group(2)) * k
        return out
    if "pick" in s.lower():
        out["pick_load"] = True
    return out


def _ladder_of_values(values) -> Optional[str]:
    vals = [v for v in values if isinstance(v, (int, float))]
    if len(vals) < 2:
        return None
    if all(b > a for a, b in zip(vals, vals[1:])):
        return "ascending"
    if all(b < a for a, b in zip(vals, vals[1:])):
        return "descending"
    peak = vals.index(max(vals))
    if 0 < peak < len(vals) - 1 and all(b >= a for a, b in zip(vals[:peak], vals[1:peak + 1])) \
            and all(b <= a for a, b in zip(vals[peak:], vals[peak + 1:])):
        return "pyramid"
    return None


# ---- adapter: today's flat definition ----------------------------------------------------------

def from_v1(d: dict) -> Workout:
    """Today's flat definition. A written-out list that repeats by roundSize is folded back into one
    block; when its targets change by round, that is a rep scheme (21-15-9)."""
    w = Workout(source="v1", team=d.get("team"))
    allsegs = d.get("segments", [])
    fmt = d.get("format")
    cap = d.get("timeCapSeconds")
    w.cap_s = float(cap) if cap else None
    interval = d.get("intervalSeconds")
    rs = d.get("roundSize")
    n_all = len(allsegs)
    passes = d.get("rounds")
    block = allsegs
    if rs and 0 < rs < n_all and not passes and \
            all(allsegs[i]["movement"] == allsegs[i % rs]["movement"] for i in range(n_all)):
        block = allsegs[:rs]
        passes = -(-n_all // rs)
        w.notes.append("folded_written_out_rounds")
        for p in range(rs):
            vals = [(allsegs[i].get("target") or {}).get("value") for i in range(p, n_all, rs)]
            scheme = _ladder_of_values(vals) if len(set(vals)) > 1 else None
            if scheme and allsegs[p].get("kind") != "rest":
                w.rep_scheme = scheme
    for i, s in enumerate(block):
        t = s.get("target") or {}
        if s.get("kind") == "rest":
            if t.get("unit") == "seconds":
                w.rest_s += float(t.get("value") or 0) * (passes or 1)
            continue
        vals = [(allsegs[j].get("target") or {}).get("value") for j in range(i, n_all, rs)] if block is not allsegs else [t.get("value")]
        nums = [v for v in vals if isinstance(v, (int, float))]
        e = Element(movement=s.get("movement", ""), unit=t.get("unit"),
                    value=(sum(nums) / len(nums)) if nums else None, rounds=passes or 1)
        for k, v in parse_load(s.get("load")).items():
            setattr(e, k, v)
        w.elements.append(e)
    w.passes = passes
    if fmt == "amrap":
        w.unbounded = True
        w.clock_is_duration = True
        w.score = "roundsReps"
    elif fmt == "emom":
        w.intervals = "emom" if interval else "every"
        w.window_s = float(interval) if interval else None
        if w.window_s and w.cap_s:
            w.windows = int(round(w.cap_s / w.window_s))
        w.clock_is_duration = True
        w.score = "none"            # today's EMOM rows record nothing but completion
    else:
        w.score = "time"
    if d.get("team") in ("doubles", "team"):
        w.partner = "stations_split" if _is_race(w) else UNKNOWN
    return w


def _runs(w: Workout) -> int:
    return sum(e.rounds or 1 for e in w.elements if movement_id(e.movement) == "run")


def _is_race(w: Workout) -> bool:
    """Runs interleaved with Hyrox stations (a race or a race simulation)."""
    ids = {movement_id(e.movement) for e in w.elements}
    return _runs(w) >= 4 and len(ids & set(HYROX_STATIONS) - {"row"}) >= 3


# ---- adapter: v2 structure ----------------------------------------------------------------------

def _vary_values(spec):
    if isinstance(spec, dict) and "step" in spec:
        start, step = spec.get("from", 0), spec["step"]
        return [start, start + step, start + 2 * step]
    if isinstance(spec, list):
        if all(isinstance(v, (int, float)) for v in spec):
            return list(spec)
        if all(isinstance(v, dict) and "movement" not in v for v in spec):
            vals = [(v.get("target") or {}).get("value") if isinstance(v.get("target"), dict) else v.get("value")
                    for v in spec]
            if all(isinstance(x, (int, float)) for x in vals):
                return vals
    return None


def _node(wrapper):
    from .workout_structure import node_kind
    return node_kind(wrapper)


def from_v2(doc: dict) -> Workout:
    st = doc.get("structure") or {}
    if not st and isinstance(doc.get("scales"), list) and doc["scales"]:
        st = doc["scales"][0].get("structure") or {}
    score = (st.get("score") or {})
    body = st.get("body") or []
    tops = [n for n in body if _node(n)[0] in ("timed", "repeat")]
    if len(tops) > 1 and score.get("type") == "perPiece":
        w = Workout(source="v2", team=doc.get("team"), score="perPiece")
        for n in tops:
            sub = _v2_workout([n], {"type": score.get("metric")}, doc.get("team"))
            w.pieces.append(sub)
            w.elements.extend(sub.elements)
        return w
    return _v2_workout(body, score, doc.get("team"))


def _v2_workout(body, score: dict, team) -> Workout:
    w = Workout(source="v2", team=team, score=score.get("type"))

    def add_part(c: dict, passes, vary: dict, main: bool, group: Optional[str]):
        spec = vary.get(c.get("id")) if c.get("id") else None
        who = c.get("who")
        if isinstance(spec, list) and any(isinstance(v, dict) and "movement" in v for v in spec):
            w.per_round_movements = True
            for v in spec:
                t = v.get("target") or c.get("target") or {}
                w.elements.append(Element(movement=v.get("movement", c.get("movement", "")),
                                          unit=t.get("unit"), value=t.get("value"), rounds=1,
                                          main=main, who=who, group=group))
            return
        t = c.get("target") or {}
        e = Element(movement=c.get("movement", ""), unit=t.get("unit"), value=t.get("value"),
                    rounds=passes or 1, main=main, who=who, group=group)
        vals = _vary_values(spec) if spec is not None else None
        if vals:
            e.value = sum(vals) / len(vals)
        for k, v in parse_load(c.get("load")).items():
            setattr(e, k, v)
        w.elements.append(e)

    def walk(nodes, passes, depth, inside_window, vary, main=True, group=None):
        kinds = [_node(n)[0] for n in nodes]
        first_rep = kinds.index("repeat") if "repeat" in kinds else None
        last_rep = len(kinds) - 1 - kinds[::-1].index("repeat") if "repeat" in kinds else None
        for i, n in enumerate(nodes):
            kind, c = _node(n)
            if kind is None:
                continue
            outside = first_rep is not None and depth == 0 and (i < first_rep or i > last_rep)
            if kind == "part":
                if outside:
                    if i < first_rep:
                        w.buy_in = True
                    else:
                        w.cash_out = True
                add_part(c, passes, vary, main and not outside, group)
            elif kind == "rest":
                if "ratio" in c:
                    w.rest_ratio = float(c["ratio"])
                else:
                    w.rest_s += float(c.get("seconds") or 0) * (passes or 1)
            elif kind == "group":
                g = c.get("id") or "g" if c.get("asStep") else group
                if c.get("asStep"):
                    w.complex = True
                walk(c.get("body") or [], passes, depth, inside_window, vary, main, g)
                for k, v in parse_load(c.get("load")).items():
                    for e in w.elements:
                        if e.group == g and getattr(e, k) is None:
                            setattr(e, k, v)
            elif kind == "repeat":
                times = c.get("times")
                rv = c.get("vary") or {}
                if times is None:
                    w.unbounded = True
                    if any(isinstance(s, dict) and "step" in s for s in rv.values()):
                        w.open_ladder = True
                else:
                    for s in rv.values():
                        sch = _ladder_of_values(_vary_values(s) or [])
                        if sch:
                            w.rep_scheme = sch
                if depth == 0 and w.passes is None:
                    w.passes = times
                inner_kinds = [_node(x)[0] for x in c.get("body") or []]
                if "timed" in inner_kinds:
                    w.intervals = w.intervals or "windows"
                    w.windows = times
                    rests = [_node(x)[1] for x in c["body"] if _node(x)[0] == "rest"]
                    if rests and "seconds" in rests[0]:
                        w.intervals = "tabata"
                elif "rest" in inner_kinds and times and times >= 2:
                    w.intervals = w.intervals or "work_rest"
                inner = dict(vary)
                inner.update(rv)
                walk(c.get("body") or [], (passes or 1) * times if times else passes, depth + 1,
                     inside_window, inner, main)
            elif kind == "timed":
                secs = float(c.get("seconds") or 0)
                if not inside_window and depth == 0:
                    w.cap_s = (w.cap_s or 0) + secs
                    w.clock_is_duration = c.get("late") in ("end", None) and score.get("type") != "time"
                    walk(c.get("body") or [], passes, 0, True, vary, main, group)
                    continue
                w.window_s = secs
                walk(c.get("body") or [], passes, depth, True, vary, main, group)

    walk(body, None, 0, False, {})
    if w.intervals == "tabata" and w.window_s:
        w.work_s_per_window = w.window_s
        w.window_s = w.window_s + w.rest_s / max(1, w.windows or 1)
        w.rest_s = 0.0
    if w.intervals and w.window_s and w.windows:
        w.cap_s = w.cap_s or w.window_s * w.windows
        w.clock_is_duration = True
    whos = {e.who for e in w.elements if e.who}
    if "shared" in whos:
        w.partner = "split_as_needed"
    elif "partner" in whos and "me" in whos:
        w.partner = "you_go_i_go"
    elif "together" in whos:
        w.partner = "synchro"
    elif team in ("doubles", "team"):
        w.partner = "stations_split" if _is_race(w) else UNKNOWN
    if score.get("type") == "none" and not w.cap_s and not w.intervals:
        w.practice = True
    if score.get("type") == "load" and any(e.unit == "max" or (e.unit == "reps" and e.value == 1)
                                           for e in w.elements):
        w.max_effort = True
    return w


# ---- adapter: the import's draft parse ----------------------------------------------------------

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
    """(total seconds or None, window seconds or None) from a header such as 'AMRAP 12',
    'Every 3 mins for 15 mins' or 'E2MOM'. Numbers only; the text is not kept."""
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


def tx_is_instruction(name: str) -> bool:
    """A parsed 'movement' that is really an instruction line: long, or a clock phrase."""
    return len(name.split()) > 6 or bool(_EVERY_RE.search(name) or _FOR_MIN_RE.search(name))


def _num(v) -> Optional[float]:
    if v is None:
        return None
    m = _NUM_RE.search(str(v))
    return float(m.group(1)) if m else None


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


def _draft_piece(piece: dict, base: str, flags: set, score: Optional[str]) -> Workout:
    w = Workout(source="draft", score=score)
    kind = piece.get("kind") or base
    rounds = piece.get("rounds")
    rounds = int(rounds) if isinstance(rounds, (int, float)) and rounds > 0 else None
    if kind in _DRAFT_INTERVAL_KINDS:
        w.intervals = _DRAFT_INTERVAL_KINDS[kind]
    if kind in ("max_effort_test",):
        w.max_effort = True
    if kind in ("amrap_rounds", "amrap_reps", "cycles_continued_amrap"):
        w.unbounded = True
        w.clock_is_duration = True
    if kind == "rft_each_round_timed":
        w.rest_ratio = 1.0
    if kind == "quality":
        w.practice = True
    if kind == "death_by":
        w.open_ladder = True
        w.unbounded = True
    header = " ".join([str(piece.get("header") or "")] +
                      [str(mv.get("name") or "") for mv in piece.get("movements") or []
                       if not any(mv.get(k) for k in ("reps", "load", "distance", "time"))])
    h_total, h_window = header_clock(header)
    if piece.get("window_s"):
        w.window_s = float(piece["window_s"])
        if rounds:
            w.windows = rounds
    elif h_window:
        w.window_s = h_window
        w.windows = int(round(h_total / h_window)) if h_total else rounds
        w.notes.append("window_from_header")
    if w.window_s and w.windows:
        w.cap_s = w.window_s * w.windows
        w.clock_is_duration = True
    elif h_total:
        w.cap_s = h_total
        w.clock_is_duration = w.unbounded
        w.notes.append("minutes_from_header")
    if rounds and not w.windows:
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
    if "ladder_ascending" in flags:
        w.rep_scheme = "ascending"
    elif "ladder_descending" in flags:
        w.rep_scheme = "descending"
    if "open_ended_ladder" in flags or (w.rep_scheme == "ascending" and w.unbounded):
        w.open_ladder = True        # climbs until the clock: an open ladder, not a rep scheme
        w.rep_scheme = None
    if "partner" in flags:
        w.partner = UNKNOWN
    if "buyin_cashout_named" in flags or kind == "window_buyin_max_reps":
        w.buy_in = True
    if "complex_lift" in flags:
        w.complex = True
    return w


def from_draft_piece(cls: dict) -> Workout:
    """One scale classification of a workout_drafts row (format, flags, scoring, parsed pieces)."""
    fmt = str(cls.get("format") or "")
    flags = set(cls.get("flags") or [])
    parsed = cls.get("parsed") or []
    scoring = [str(s).strip().lower() for s in (cls.get("scoring") or [])]
    base = fmt.split("(")[0].replace("multi_part:", "").split("+")[0]
    scores = [_DRAFT_SCORE.get(s) for s in scoring]
    subs = [_draft_piece(p, base, flags, scores[min(i, len(scores) - 1)] if scores else None)
            for i, p in enumerate(parsed)]
    if len(subs) > 1:
        w = Workout(source="draft", score="perPiece", pieces=subs)
        for s in subs:
            w.elements.extend(s.elements)
    elif subs:
        w = subs[0]
    else:
        w = Workout(source="draft", score=scores[0] if scores else None)
    if scoring and scores and scores[0] is None:
        w.notes.append("score_ambiguous")
    w.notes.append("format:" + base)
    if "hyrox_track" in flags:
        w.notes.append("hyrox_track")
    return w


# ---- axes -------------------------------------------------------------------------------------

def _axis(value, confidence, reasons, **extra):
    if value == UNKNOWN:
        confidence = UNKNOWN
    if value == NA:
        confidence = "high"
    out = {"value": value, "confidence": confidence, "reasons": list(reasons)}
    out.update(extra)
    return out


def _loaded(e: Element) -> bool:
    return e.load_kg is not None or e.load_pct is not None or e.pick_load


def _work_movements(w: Workout) -> list:
    keys = []
    for e in w.elements:
        if not e.main or e.movement in ("part", "rest", ""):
            continue
        k = movement_id(e.movement) or e.movement.strip().lower()
        if k not in keys:
            keys.append(k)
    return keys


def _strength(w: Workout) -> tuple:
    """(is strength, reason). One loaded movement (or one complex), low reps per set, in sets."""
    main = [e for e in w.elements if e.main]
    if not main or w.practice or (w.unbounded and w.score != "load"):
        return False, None
    loaded = [e for e in main if _loaded(e) or (implement_of(e.movement) and modality_of(e.movement)[0] == "W"
                                               and e.unit in ("reps", None))]
    if len(loaded) != len(main):
        return False, None
    if w.complex or len({e.group for e in main if e.group}) == 1 and all(e.group for e in main):
        return True, "complex"
    if len(_work_movements(w)) != 1:
        return False, None
    if w.max_effort or w.score == "load":
        return True, "max_effort" if w.max_effort else "scored_by_load"
    reps = [e.value for e in main if e.unit == "reps" and e.value]
    low_reps = bool(reps) and max(reps) <= STRENGTH_MAX_REPS
    sets = (w.passes or 1) >= 2 or (w.windows or 0) >= 2
    if any(e.load_pct is not None for e in main) and (sets or low_reps):
        return True, "percent_load"
    if low_reps and sets:
        return True, "low_reps_in_sets"
    return False, None


def classify_movements(w: Workout) -> dict:
    n = len(_work_movements(w))
    if n == 0:
        return _axis(UNKNOWN, UNKNOWN, ["no_movements"])
    v = {1: "single", 2: "couplet", 3: "triplet"}.get(n, "4plus")
    return _axis(v, "high", ["movements:%d" % n] + (["buy_in_cash_out_excluded"] if (w.buy_in or w.cash_out) else []))


def _modifiers(w: Workout, structure: str, strength_reason: Optional[str]) -> list:
    mods = []
    if w.rep_scheme:
        mods.append("reps_" + w.rep_scheme if w.rep_scheme != "pyramid" else "pyramid")
    if w.open_ladder and structure != "ladder":
        mods.append("open_ladder")
    for name, on in (("buy_in", w.buy_in), ("cash_out", w.cash_out), ("ratio_rest", w.rest_ratio is not None)):
        if on:
            mods.append(name)
    if w.partner:
        mods.append("partner:" + w.partner)
    if strength_reason == "complex" or w.complex:
        mods.append("complex")
    if w.max_effort:
        mods.append("max_effort")
    if structure == "strength" and w.intervals:
        mods.append("interval_wrapper")
    if _is_race(w):
        mods.append("run_interleaved")
    if any(movement_id(e.movement) in ODD_OBJECTS for e in w.elements):
        mods.append("odd_object")
    if any(_loaded(e) and modality_of(e.movement)[0] == "G" for e in w.elements):
        mods.append("loaded_bodyweight")
    return mods


def classify_structure(w: Workout) -> dict:
    if w.pieces:
        labels = [classify_structure(p)["value"] for p in w.pieces]
        return _axis("multi_part", "high", ["pieces:%d" % len(w.pieces)], modifiers=[], pieces=labels)
    is_strength, why = _strength(w)
    if w.practice:
        v, conf, reasons = "practice", "high", ["not_for_time"]
    elif is_strength:
        v, conf, reasons = "strength", "high", [why]
    elif w.open_ladder and (w.unbounded or w.clock_is_duration):
        v, conf, reasons = "ladder", "high", ["open_ladder"]
    elif w.intervals:
        v, conf, reasons = "intervals", "high", ["intervals:" + w.intervals]
    elif w.unbounded and w.cap_s:
        v, conf, reasons = "amrap", "high", ["clock"]
    elif w.unbounded:
        v, conf, reasons = "amrap", "medium", ["unbounded_without_clock"]
    elif (w.passes or 1) >= 2 and not w.per_round_movements:
        v, conf, reasons = "rounds", "high", ["passes:%d" % w.passes]
    elif len(_work_movements(w)) >= CHIPPER_MIN_MOVEMENTS:
        v, conf, reasons = "chipper", "high", ["one_pass"]
    elif _work_movements(w):
        v, conf, reasons = "for_time", "high", ["one_pass"]
    else:
        return _axis(UNKNOWN, UNKNOWN, ["no_movements"], modifiers=[])
    return _axis(v, conf, reasons, modifiers=_modifiers(w, v, why if is_strength else None))


# -- time --

def _heavy(e: Element) -> bool:
    if e.load_pct is not None:
        return e.load_pct >= PCT_HEAVY_MIN
    ref = _standard(e, "m")
    return bool(ref and e.load_kg and e.load_kg / ref >= RX_HEAVY_MIN)


def element_seconds(e: Element) -> Optional[float]:
    """Estimated seconds of one pass of an element, or None."""
    mid = movement_id(e.movement)
    mod = modality_of(e.movement)[0] or "G"
    if e.unit == "seconds" and e.value:
        return e.value
    if e.unit == "meters" and e.value:
        return e.value / METERS_PER_SECOND.get(mid, METERS_PER_SECOND_DEFAULT)
    if e.unit == "calories" and e.value:
        return e.value * SECONDS_PER_CAL.get(mid, SECONDS_PER_CAL_DEFAULT)
    if e.unit == "reps" and e.value:
        if mid in BARBELL_LIFTS and _heavy(e):
            return e.value * SECONDS_PER_REP_HEAVY
        return e.value * SECONDS_PER_REP.get(mid, SECONDS_PER_REP_DEFAULT[mod])
    return None


def _split_factor(w: Workout, e: Element) -> float:
    """Per-athlete share of an element in partner work."""
    if e.who in ("shared", "partner") or w.partner in ("split_as_needed", "you_go_i_go"):
        return 0.5
    if w.partner == "stations_split" and movement_id(e.movement) != "run":
        return 0.5
    return 1.0


def work_seconds(w: Workout) -> tuple:
    """(estimated work seconds per athlete or None, confidence)."""
    total, missing = 0.0, 0
    for e in w.elements:
        s = element_seconds(e)
        if s is None:
            missing += 1
            continue
        total += s * (e.rounds or 1) * _split_factor(w, e)
    if total <= 0:
        return None, UNKNOWN
    if w.rest_ratio is not None:
        total *= 1.0 + w.rest_ratio
    total += w.rest_s
    if _is_race(w):
        total += ROXZONE_S * 2 * _runs(w)
    return total, "low" if missing else "medium"


def estimated_seconds(w: Workout) -> tuple:
    """(seconds or None, source, confidence). A clock (AMRAP, windows) is the duration; a for-time
    cap is only an upper bound (the estimated work is used when shorter)."""
    if w.cap_s and not w.clock_is_duration:
        work, conf = work_seconds(w)
        if work is not None and work < w.cap_s:
            return work, "estimated_under_cap", conf
        return w.cap_s, "cap_upper_bound", "medium"
    if w.cap_s:
        return w.cap_s, "clock", "high"
    if w.unbounded:
        return None, "unbounded_without_clock", UNKNOWN
    work, conf = work_seconds(w)
    if work is None:
        return None, "no_work_estimate", UNKNOWN
    return work, "estimated_work", conf


def _bucket(secs: float) -> str:
    if secs <= SHORT_MAX_S:
        return "short"
    if secs <= MEDIUM_MAX_S:
        return "medium"
    if secs <= LONG_MAX_S:
        return "long"
    return "very_long"


def classify_time_domain(w: Workout, structure: Optional[str] = None) -> dict:
    structure = structure or classify_structure(w)["value"]
    if structure in ("strength", "practice"):
        return _axis(NA, "high", [structure], seconds=None)
    if w.pieces:
        parts = [estimated_seconds(p)[0] for p in w.pieces]
        known = [p for p in parts if p]
        if not known:
            return _axis(UNKNOWN, UNKNOWN, ["pieces_without_estimate"], seconds=None)
        secs = sum(known)
        return _axis(_bucket(secs), "low" if len(known) < len(parts) else "medium", ["sum_of_pieces"],
                     seconds=round(secs))
    secs, src, conf = estimated_seconds(w)
    if secs is None:
        return _axis(UNKNOWN, UNKNOWN, [src], seconds=None)
    out = _axis(_bucket(secs), conf, [src], seconds=round(secs))
    if w.intervals:
        bout = w.work_s_per_window
        if bout is None:
            per = [element_seconds(e) for e in w.elements if e.main]
            per = [p for p in per if p]
            bout = sum(per) if per else w.window_s
        if bout:
            out["work_bout"] = ("short" if bout <= WORK_BOUT_SHORT_MAX_S else
                                "medium" if bout <= WORK_BOUT_MEDIUM_MAX_S else "long")
    return out


# -- loading --

def _standard(e: Element, sex: str) -> Optional[float]:
    mid = movement_id(e.movement)
    imp = implement_of(e.movement)
    ref = STANDARDS.get((mid, imp))
    if ref is None:
        return None
    return ref[0 if sex == "m" else 1]


def _level_pct(p: float) -> str:
    return "light" if p < PCT_LIGHT_MAX else ("heavy" if p >= PCT_HEAVY_MIN else "moderate")


def _level_ratio(r: float) -> str:
    return "light" if r < RX_LIGHT_MAX else ("heavy" if r >= RX_HEAVY_MIN else "moderate")


_ORDER = {"light": 0, "moderate": 1, "heavy": 2}


def classify_loading(w: Workout, athlete_max_kg: Optional[dict] = None, sex: str = "m",
                     structure: Optional[str] = None) -> dict:
    """The heaviest loaded element decides, relative to the athlete: their max for that movement,
    else a stated %RM, else the standard for that movement, implement and sex ("vs standard",
    medium confidence; Hyrox stations against the race divisions). bodyweight when nothing is
    loaded; unknown when loaded with no reference; n/a for practice."""
    structure = structure or classify_structure(w)["value"]
    if structure == "practice":
        return _axis(NA, "high", ["practice"])
    best, reasons, conf = None, [], "high"
    any_load = any(_loaded(e) for e in w.elements)
    hyrox = _is_race(w) or "hyrox_track" in w.notes
    for e in w.elements:
        mid = movement_id(e.movement)
        kg = e.load_kg_f if (sex == "f" and e.load_kg_f is not None) else e.load_kg
        level, why, c = None, None, "high"
        if e.load_pct is not None:
            level, why = _level_pct(e.load_pct), "percent_of_max"
        elif kg is not None and athlete_max_kg and mid in athlete_max_kg:
            level, why = _level_pct(100.0 * kg / athlete_max_kg[mid]), "athlete_max"
        elif kg is not None and mid in HYROX_DIVISIONS and (hyrox or not _standard(e, sex)):
            om, of, pm, pf = HYROX_DIVISIONS[mid]
            open_ref, pro_ref = (om, pm) if sex == "m" else (of, pf)
            level = "light" if kg < 0.9 * open_ref else ("heavy" if kg >= 0.95 * pro_ref else "moderate")
            why, c = "hyrox_division", "medium"
        elif kg is not None and _standard(e, sex):
            level, why, c = _level_ratio(kg / _standard(e, sex)), "vs_standard", "medium"
        elif kg is not None:
            why = "no_reference"
        elif e.pick_load:
            why = "pick_load"
        if why and why not in reasons:
            reasons.append(why)
        if level and (best is None or _ORDER[level] > _ORDER[best]):
            best, conf = level, c
    if best is not None:
        return _axis(best, conf, reasons)
    if not any_load and all(modality_of(e.movement)[0] in ("G", "M") for e in w.elements) and w.elements:
        return _axis("bodyweight", "high", ["no_external_load"])
    return _axis(UNKNOWN, UNKNOWN, reasons or ["no_load"])


# -- modality --

def classify_modality(w: Workout) -> dict:
    present, stations, reasons, unknown = [], [], [], 0
    share = {"G": 0.0, "W": 0.0, "M": 0.0}
    for e in w.elements:
        mod, why = modality_of(e.movement)
        if mod is None:
            unknown += 1
            continue
        if mod not in present:
            present.append(mod)
        mid = movement_id(e.movement)
        if mid in HYROX_STATIONS and mid not in stations:
            stations.append(mid)
        if why not in reasons:
            reasons.append(why)
        share[mod] += (element_seconds(e) or 0.0) * (e.rounds or 1)
    if not present:
        return _axis(UNKNOWN, UNKNOWN, reasons or ["no_movements"], primary=None, stations=[], loaded=False)
    if unknown:
        reasons.append("unknown_movements:%d" % unknown)
    total = sum(share.values())
    primary = max(share, key=share.get) if total > 0 else present[0]
    conf = "high" if unknown == 0 and reasons == ["lexicon"] else ("medium" if unknown == 0 else "low")
    loaded = any(_loaded(e) and modality_of(e.movement)[0] == "G" for e in w.elements)
    return _axis("".join(m for m in ("G", "W", "M") if m in present), conf, reasons,
                 primary=primary, stations=stations, loaded=loaded)


# -- scoring --

_SCORE_MAP = {"perPiece": "per_piece", "time": "time", "roundsReps": "rounds_reps", "totalReps": "reps", "lowestReps": "reps",
              "load": "load", "distance": "calories_distance", "calories": "calories_distance",
              "maxHeight": "calories_distance", "longestHold": "time",
              "windowsCompleted": "pass_fail", "none": "none"}


def classify_scoring(w: Workout) -> dict:
    if w.pieces:
        per = [classify_scoring(p)["value"] for p in w.pieces]
        return _axis("per_piece", "high", ["pieces:%d" % len(w.pieces)], pieces=per)
    if w.score is None:
        return _axis(UNKNOWN, UNKNOWN, ["no_score"] + [n for n in w.notes if n == "score_ambiguous"])
    if w.open_ladder and w.intervals and w.score in ("roundsReps", "windowsCompleted"):
        return _axis("rounds_reps", "high", ["death_by"])
    v = _SCORE_MAP.get(w.score)
    if v is None:
        return _axis(UNKNOWN, UNKNOWN, ["score:" + str(w.score)])
    if w.intervals and v == "none" and any(e.unit == "max" for e in w.elements):
        return _axis("reps", "medium", ["max_rep_window"])
    return _axis(v, "high", ["score:" + w.score])


def classify(w: Workout, athlete_max_kg: Optional[dict] = None, sex: str = "m") -> dict:
    structure = classify_structure(w)
    out = {
        "modality": classify_modality(w),
        "movements": classify_movements(w),
        "structure": structure,
        "time_domain": classify_time_domain(w, structure["value"]),
        "loading": classify_loading(w, athlete_max_kg, sex, structure["value"]),
        "scoring": classify_scoring(w),
        "source": w.source,
    }
    if w.pieces:
        out["pieces"] = [classify(p, athlete_max_kg, sex) for p in w.pieces]
    return out


def classify_definition(doc: dict, **kw) -> dict:
    """Any definition: v2 when it has a structure, else today's flat format."""
    if doc.get("schemaVersion") == 2 and (doc.get("structure") or doc.get("scales")):
        return classify(from_v2(doc), **kw)
    return classify(from_v1(doc), **kw)
