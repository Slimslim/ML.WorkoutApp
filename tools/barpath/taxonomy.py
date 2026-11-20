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
DISTANCE_METERS = {"meters": 1.0, "m": 1.0, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344, "km": 1000.0}
CHOICE_CATEGORIES = {"anyCardio": "M"}   # RFC 3.3 movement {"choice": "anyCardio"}

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
    "dragCurl": "W", "curls": "W",
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
    ("cleanAndJerks", "dumbbell"): (22.5, 15.0), ("cleanAndJerks", "dumbbell_pair"): (22.5, 15.0),
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
    (r"\b(echo|assault|air)\s*bikes?\b|\bbikes?\b|\bbiking\b", "bike"),
    (r"\bring\s+rows?\b", "ringRows"),
    (r"\b(bent|pendlay|renegade|upright|barbell|bb|db|dumbbell|kb|kettlebell|seal)\b.*\brows?\b", "barbellRow"),
    (r"\brows?\b|\browing\b|\brower\b", "row"),
    (r"\bruns?\b|\brunning\b|\bjog(s|ging)?\b|\bsprint", "run"), (r"\bswim", "swim"),
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
    (r"drag\s+curls?", "dragCurl"), (r"\bcurls?\b", "curls"),
)
_W_WORDS = re.compile(r"\b(barbell|bb|dumbbell|db|kettlebell|kb|sandbag|med\s*ball|medball|weighted|"
                      r"plate|sled|yoke|press|squat|deadlift|clean|snatch|jerk|carry|goblet)\b")
_M_WORDS = re.compile(r"\b(ergs?|cals?|calories|meters?|metres?|km|miles?|cardio|swim(s|ming)?)\b")
_G_WORDS = re.compile(r"\b(hang(s|ing)?|kip(s|ping)?|rings?|bars?|handstands?|walk(s|ing)?|crawl(s|ing)?|"
                      r"jump(s|ing)?|holds?|tucks?|l-sits?|planks?)\b")
# An implement in the name makes a G lexicon match W (a DB split squat is not an air squat). A vest
# or "weighted" gymnastics stays G: the load is a loading matter (Data chat corpus pass, 0.18).
_W_IMPLEMENT = re.compile(r"\b(barbell|bb|dumbbells?|dbs?|kettlebells?|kbs?|sandbags?|d-?balls?|"
                          r"med\s*balls?|medballs?|plates?)\b", re.I)
_HEAVIEST = re.compile(r"\bheaviest\b|\bheavy\s+single|\b1\s*rm\b|\bmax\s+(load|weight)\b", re.I)
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
    if not isinstance(name, str) or not name or name.startswith("choice:"):
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
    if mid is None:
        return None
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
    """(modality or None, reason). Weighted bodyweight (a vest, "weighted pull-ups") stays G: the
    load is a loading matter. An implement word (DB, KB, sandbag, barbell...) makes it W."""
    mid = movement_id(name)
    s = (name or "").lower() if isinstance(name, str) else ""
    if mid is not None:
        if MOVEMENTS[mid] == "G" and name not in MOVEMENTS and _W_IMPLEMENT.search(s):
            return "W", "implement_word"
        return MOVEMENTS[mid], "lexicon"
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
    modality_hint: Optional[str] = None # a movement choice whose options share one modality


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
    import_strength: bool = False       # the import's kind is strength_sets / max_effort_test
    practice: bool = False
    complex: bool = False
    per_round_movements: bool = False
    score: Optional[str] = None
    source: str = ""
    notes: list = field(default_factory=list)


_LOAD_RE = re.compile(r"(\d+(?:\.\d+)?)(?:\s*/\s*(\d+(?:\.\d+)?))?\s*(lbs?|kg)\b", re.I)
_PCT_RE = re.compile(r"(\d+(?:\.\d+)?)\s*%\s*(?:of\s*)?(?:(\d)\s*(rm)|(tm))?", re.I)
_NUM_RE = re.compile(r"(\d+(?:\.\d+)?)")


def _float(v) -> Optional[float]:
    """A number from a JSON value, or None (never throws)."""
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, str):
        m = re.fullmatch(r"\s*(\d+):(\d\d)\s*", v)
        if m:
            return float(int(m.group(1)) * 60 + int(m.group(2)))
        m = _NUM_RE.search(v)
        return float(m.group(1)) if m else None
    return None


def half_up(x: float) -> int:
    """Round half away from zero (matches Swift .rounded()); Python round() is half-to-even."""
    import math
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def parse_load(text) -> dict:
    """'95/65 lbs' -> load_kg (men) and load_kg_f (women); '75% 1RM' -> load_pct, basis;
    'pick load' -> pick_load. A v2 load dict {value, unit} or {percent, basis}."""
    out = {}
    if text is None:
        return out
    if isinstance(text, dict):
        if "percent" in text and _float(text["percent"]) is not None:
            out["load_pct"] = _float(text["percent"])
            out["load_basis"] = text.get("basis", "1RM")
        elif "value" in text:
            k = 1 / LB_PER_KG if text.get("unit") == "lb" else 1.0
            out["load_kg"] = _float(text["value"]) * k if _float(text["value"]) is not None else None
            if _float(text.get("valueF")) is not None:
                out["load_kg_f"] = _float(text["valueF"]) * k
            if out["load_kg"] is None:
                del out["load_kg"]
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

def _period(keys: list) -> Optional[int]:
    """Smallest p with keys[i] == keys[i % p] for all i and at least two full passes."""
    n = len(keys)
    for p in range(1, n // 2 + 1):
        if all(keys[i] == keys[i % p] for i in range(n)):
            return p
    return None


def from_v1(d: dict) -> Workout:
    """Today's flat definition. The block is the whole listed list (#138, owner 20 Nov: roundSize
    only groups for display). Legacy rows that wrote rounds out are folded back by the period of
    repetition of their movements (heuristic: reason legacy_written_out, lower confidence); a target
    that changes by round for the same movement and unit is a rep scheme (21-15-9)."""
    w = Workout(source="v1", team=d.get("team"))
    allsegs = [s for s in (d.get("segments") or []) if isinstance(s, dict)]
    fmt = d.get("format")
    cap = d.get("timeCapSeconds")
    w.cap_s = _float(cap) or None
    interval = _float(d.get("intervalSeconds"))
    n_all = len(allsegs)
    passes = d.get("rounds") if isinstance(d.get("rounds"), int) and d.get("rounds") > 0 else None
    block = allsegs
    rs = n_all
    keys = [(s.get("movement") or s.get("kind"), (s.get("target") or {}).get("unit")) for s in allsegs]
    period = _period(keys) if not passes else None
    if period:
        rs = period
        block = allsegs[:rs]
        passes = n_all // rs
        w.notes.append("legacy_written_out")
        for p in range(rs):
            vals = [(allsegs[i].get("target") or {}).get("value") for i in range(p, n_all, rs)]
            scheme = _ladder_of_values(vals) if len(set(map(str, vals))) > 1 else None
            if scheme and allsegs[p].get("kind") != "rest":
                w.rep_scheme = scheme
    for i, s in enumerate(block):
        t = s.get("target") or {}
        if s.get("kind") == "rest":
            if t.get("unit") == "seconds":
                w.rest_s += (_float(t.get("value")) or 0.0) * (passes or 1)
            continue
        vals = [(allsegs[j].get("target") or {}).get("value") for j in range(i, n_all, rs)]
        nums = [v for v in (_float(x) for x in vals) if v is not None]
        mv = s.get("movement")
        e = Element(movement=mv if isinstance(mv, str) else "", unit=t.get("unit"),
                    value=(sum(nums) / len(nums)) if nums else None, rounds=passes or 1)
        _to_meters(e)
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
            w.windows = half_up(w.cap_s / w.window_s)
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

def _vary_values(spec, times: Optional[int] = None):
    if isinstance(spec, dict) and "step" in spec:
        start, step = _float(spec.get("from")) or 0.0, _float(spec["step"]) or 0.0
        return [start + k * step for k in range(times if times else 3)]
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


def _to_meters(e: Element):
    if e.unit in DISTANCE_METERS and e.unit != "meters" and e.value is not None:
        e.value, e.unit = e.value * DISTANCE_METERS[e.unit], "meters"


def from_v2(doc: dict) -> Workout:
    """Pieces are counted from the body (RFC 5): more than one top-level timed / repeat is a
    multi-part entry, whatever the score type; `combine` says how their scores add up."""
    st = doc.get("structure") if isinstance(doc.get("structure"), dict) else {}
    if not st and isinstance(doc.get("scales"), list) and doc["scales"] and isinstance(doc["scales"][0], dict):
        st = doc["scales"][0].get("structure") or {}
    score = st.get("score") if isinstance(st.get("score"), dict) else {}
    body = st.get("body") if isinstance(st.get("body"), list) else []
    tops = [n for n in body if _node(n)[0] in ("timed", "repeat")]
    if len(tops) > 1:
        top_type = score.get("type")
        w = Workout(source="v2", team=doc.get("team"), score="perPiece" if top_type in (None, "none", "perPiece") else top_type)
        sub_score = {"type": top_type if top_type not in (None, "none", "perPiece") else None}
        for n in tops:
            sub = _v2_workout([n], sub_score, doc.get("team"))
            w.pieces.append(sub)
            w.elements.extend(sub.elements)
            w.notes.extend(x for x in sub.notes if x not in w.notes)
        if score.get("combine"):
            w.notes.append("combine:" + str(score["combine"]))
        return w
    return _v2_workout(body, score, doc.get("team"))


def _v2_workout(body, score: dict, team) -> Workout:
    w = Workout(source="v2", team=team, score=score.get("type"))
    if w.score == "perPiece":
        # RFC 5: one round of the repeat named by `of`, measured by `metric`
        w.score = {"distance": "distance", "reps": "totalReps"}.get(score.get("metric"), "time")
        w.notes.append("per_piece_of_round")

    def note(x):
        if x not in w.notes:
            w.notes.append(x)

    def movement_of(c: dict) -> tuple:
        mv = c.get("movement")
        if isinstance(mv, str):
            return mv, None
        if isinstance(mv, dict) and "choice" in mv:
            note("movement_choice")
            ch = mv["choice"]
            if isinstance(ch, str):
                return "choice:" + ch, CHOICE_CATEGORIES.get(ch)
            if isinstance(ch, list):
                opts = [o for o in ch if isinstance(o, str)]
                mods = {modality_of(o)[0] for o in opts}
                return "choice:" + "|".join(opts), (mods.pop() if len(mods) == 1 and None not in mods else None)
        note("movement_invalid")
        return "", None

    def add_part(c: dict, passes, vary: dict, main: bool, group: Optional[str]):
        spec = vary.get(c.get("id")) if c.get("id") else None
        who = c.get("who")
        name, hint = movement_of(c)
        if isinstance(c.get("target"), dict) and c["target"].get("unit") in DISTANCE_METERS \
                and c["target"]["unit"] != "meters":
            note("distance_converted")
        if isinstance(spec, list) and any(isinstance(v, dict) and "movement" in v for v in spec):
            w.per_round_movements = True
            for v in spec:
                if not isinstance(v, dict):
                    continue
                t = v.get("target") if isinstance(v.get("target"), dict) else (c.get("target") or {})
                vm = v.get("movement")
                e = Element(movement=vm if isinstance(vm, str) else name, unit=t.get("unit"),
                            value=_float(t.get("value")), rounds=1, main=main, who=who, group=group,
                            modality_hint=None if isinstance(vm, str) else hint)
                _to_meters(e)
                w.elements.append(e)
            return
        t = c.get("target") if isinstance(c.get("target"), dict) else {}
        e = Element(movement=name, unit=t.get("unit"), value=_float(t.get("value")),
                    rounds=passes or 1, main=main, who=who, group=group, modality_hint=hint)
        vals = _vary_values(spec) if spec is not None else None
        if vals:
            e.value = sum(vals) / len(vals)
        for k, v in parse_load(c.get("load")).items():
            setattr(e, k, v)
        _to_meters(e)
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
                if _float(c.get("ratio")) is not None:
                    w.rest_ratio = _float(c["ratio"])
                else:
                    w.rest_s += (_float(c.get("seconds")) or 0.0) * (passes or 1)
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
                times = c.get("times") if isinstance(c.get("times"), int) and c.get("times") > 0 else None
                rv = c.get("vary") if isinstance(c.get("vary"), dict) else {}
                if c.get("override"):
                    note("override_ignored")
                if c.get("until") == "athlete":
                    note("until_athlete")
                if c.get("id") and c.get("id") in vary:
                    note("vary_repeat_times")
                if times:   # a {from, step} climb over a counted repeat has `times` values
                    rv = {k: (_vary_values(v, times) if isinstance(v, dict) and "step" in v else v)
                          for k, v in rv.items()}
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
                secs = _float(c.get("seconds")) or 0.0
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
    "load": "load", "distance": "distance", "distance per effort": "distance", "none": "none",
    "windowscompleted": "windowsCompleted",   # set by the "miss a minute" clock label
}
_MIN_RE = re.compile(r"(\d+)\s*(?:min|mins|minutes|')(?![a-z])", re.I)
_FOR_MIN_RE = re.compile(r"\bfor\s*(\d+)\s*(?:min|mins|minutes)(?![a-z])", re.I)
_AMRAP_RE = re.compile(r"\bamrap\s*(\d+)\b", re.I)
_EACH_RE = re.compile(r"(\d+)\s*(sec|secs|seconds|s|min|mins|minutes)\s+each\b|(\d+):(\d\d)\s+each\b", re.I)
_TABATA_RE = re.compile(r"(\d+)\s*(?:s|sec|secs|seconds)\s*(?:on|work)\W+(\d+)\s*(?:s|sec|secs|seconds)\s*(?:off|rest)",
                        re.I)
_UNTIL_FAIL_RE = re.compile(r"until\s+(you\s+)?fail|until\s+failure|until\s+you\s+can'?t", re.I)
_DEATH_BY_LINE_RE = re.compile(r"\bmin(ute)?s?\b|\b\d+(st|nd|rd|th)\b", re.I)
_DIST_IN_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(km|k|mi|miles?|m|meters?|metres?)\b", re.I)
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
    if window is None:
        m = _EACH_RE.search(text)        # "5 rounds, 1 min each": the window
        if m:
            if m.group(1):
                window = float(m.group(1)) * (60 if m.group(2).lower().startswith("m") else 1)
            else:
                window = int(m.group(3)) * 60 + int(m.group(4))
            return total, window
    m = _FOR_MIN_RE.search(text) or _AMRAP_RE.search(text)
    if m:
        total = float(m.group(1)) * 60
    elif window is None:
        m = _MIN_RE.search(text)
        if m:
            total = float(m.group(1)) * 60
    return total, window


_COMPLEX_LINE = re.compile(r"^\s*(\d+)\s*x\s*\[(.*?)\]?\s*$", re.I)
_SETS_X_REPS = re.compile(r"\b(\d{1,2})\s*x\s*(\d{1,2})\b", re.I)
_REP_SCHEME = re.compile(r"(?<![\d:/.])(\d{1,2}(?:\s*-\s*\d{1,2}){2,})(?![\d:/])")
HEIGHT_MOVEMENTS = ("wallBalls", "boxJumps", "stepOvers", "medBallBoxStepOvers")


def tx_is_instruction(name: str) -> bool:
    """A parsed 'movement' that is really an instruction line: long, or a clock phrase. An
    'Nx [ ... ]' complex line is not an instruction."""
    if _COMPLEX_LINE.match(name):
        return False
    return len(name.split()) > 6 or bool(_EVERY_RE.search(name) or _FOR_MIN_RE.search(name))


def set_scheme(text: str) -> Optional[list]:
    """Reps per set from '5-5-3-3-1' or '4x8' in a line or header, or None."""
    m = _REP_SCHEME.search(text)
    if m:
        return [int(x) for x in re.split(r"\s*-\s*", m.group(1))]
    m = _SETS_X_REPS.search(text)
    if m and 1 <= int(m.group(1)) <= 20:
        return [int(m.group(2))] * int(m.group(1))
    return None


def split_line(name: str) -> tuple:
    """(movement names, is a complex, sets or None) of one parsed line: 'Nx [A + B]' is a complex
    of A and B done N times; 'A + B' is two movements when both are known."""
    sets, inner, cx = None, name, False
    m = _COMPLEX_LINE.match(name)
    if m:
        sets, inner, cx = int(m.group(1)), m.group(2), True
    parts = [x for x in re.split(r"\s*(?:\+|&)\s*", inner) if x.strip()]
    if len(parts) > 1 and all(movement_id(x) for x in parts):
        return parts, True if cx else None, sets
    return [inner.strip() or name], cx, sets


def _num(v) -> Optional[float]:
    if v is None or isinstance(v, bool):
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
    if re.search(r"\bmi\b|mile", s):
        return v * 1609.344
    if "ft" in s or "feet" in s:
        return v * 0.3048
    if "yd" in s or "yard" in s:
        return v * 0.9144
    return v


def _distance_in(text: str) -> Optional[float]:
    """Meters from a distance written in a name or header ("Run 5k", "Swim 800 m"), or None."""
    m = _DIST_IN_RE.search(text or "")
    if not m:
        return None
    v, u = float(m.group(1)), m.group(2).lower()
    if u in ("km", "k"):
        return v * 1000
    if u.startswith("mi"):
        return v * 1609.344
    return v


def _seconds(text) -> Optional[float]:
    s = str(text).lower()
    mult = 1.0
    m = re.match(r"\s*(\d+)\s*x\s*(.*)", s)
    if m:
        mult, s = float(m.group(1)), m.group(2)
    m = re.search(r"(\d+):(\d\d)", s)
    if m:
        return mult * (int(m.group(1)) * 60 + int(m.group(2)))
    v = _num(s)
    if v is None:
        return None
    return mult * (v * 60 if "min" in s else v)


_STRENGTH_KINDS = ("strength_sets", "max_effort_test")
_AMRAP_KINDS = ("amrap_rounds", "amrap_reps", "cycles_continued_amrap")


def _draft_score(label: str, kind: str, w: Workout, strengthy: bool) -> Optional[str]:
    """The import's scoring label -> a score type. Combined labels are split by the piece's kind
    and the movements' units."""
    units = {e.unit for e in w.elements}
    if label == "time or load":
        return "load" if strengthy or w.max_effort else "time"
    if label == "load, reps or hold time":
        if "seconds" in units and not any(_loaded(e) for e in w.elements):
            return "longestHold"
        return "load" if strengthy or any(_loaded(e) for e in w.elements) else "totalReps"
    if label == "none or max reps":
        return "totalReps" if "max" in units else "none"
    mapped = _DRAFT_SCORE.get(label)
    holds = [e for e in w.elements if e.unit == "seconds" or re.search(r"\bhold|plank|l-?sit|\bhang\b",
                                                                       e.movement, re.I)]
    if mapped == "load" and w.elements and len(holds) == len(w.elements) \
            and not any(_loaded(e) for e in w.elements):
        return "longestHold"                            # a hold is scored by its time, not a load
    return mapped


def _draft_piece(piece: dict, base: str, flags: set, label: Optional[str], clock: list, rest: list) -> Workout:
    w = Workout(source="draft")
    kind = str(piece.get("kind") or base)
    rounds = _float(piece.get("rounds"))
    rounds = int(rounds) if rounds and rounds > 0 else None
    window = _float(piece.get("window_s")) or None
    strengthy = kind in _STRENGTH_KINDS or any("rest between sets" in c for c in clock)
    if kind in _DRAFT_INTERVAL_KINDS:
        w.intervals = _DRAFT_INTERVAL_KINDS[kind]
    if kind == "max_effort_test":
        w.max_effort = True
    if kind in _STRENGTH_KINDS:
        w.import_strength = True
    if kind in _AMRAP_KINDS:
        w.unbounded = True
        w.clock_is_duration = True
    if kind == "quality":
        w.practice = True
    if kind == "death_by":
        w.open_ladder = True
        w.unbounded = True
    if kind == "window_buyin_max_reps" and not (rounds and rounds > 1):
        # one window: a buy-in, then max work until the clock (an AMRAP with a buy-in)
        w.intervals, w.unbounded, w.clock_is_duration, w.buy_in = None, True, True, True
    if "work_ratio" in rest:
        w.rest_ratio = 1.0
        w.notes.append("ratio_assumed_1_to_1")
    lines = [mv for mv in (piece.get("movements") or []) if isinstance(mv, dict)]
    segs = [seg for seg in (piece.get("segments") or []) if isinstance(seg, dict)]
    for seg in segs:
        lines += [mv for mv in (seg.get("movements") or []) if isinstance(mv, dict)]
    seg_heads = [str(seg.get("header") or "") for seg in segs]
    if len(segs) >= 2 and (kind in _AMRAP_KINDS or any(_AMRAP_RE.search(h) or _EVERY_RE.search(h) or
                                                        re.search(r"fixed|start", h, re.I) for h in seg_heads)):
        # repeated AMRAP / fixed-start segments: windows, not one chipper
        seg_total = header_clock(seg_heads[0])[0] if seg_heads else None
        w.intervals, w.unbounded, w.clock_is_duration = "windows", False, True
        if seg_total and not window:
            window = seg_total
        rounds = rounds if rounds and rounds > len(segs) else len(segs)
        w.per_round_movements = True
        w.notes.append("segments_as_windows")
    text_all = " ".join([str(piece.get("header") or ""), str(piece.get("notes") or "")] + clock)
    if kind == "emom" and _UNTIL_FAIL_RE.search(text_all):
        w.open_ladder = w.unbounded = True              # an until-failure EMOM is an open ladder
        w.notes.append("until_failure")
    header = " ".join([str(piece.get("header") or "")] +
                      [str(mv.get("name") or "") for mv in lines
                       if not any(mv.get(k) for k in ("reps", "load", "distance", "time"))])
    h_total, h_window = header_clock(header)
    if window and w.unbounded and not w.intervals:
        w.cap_s = window                              # the AMRAP's length
    elif window:
        w.window_s = window
        w.windows = rounds or (half_up(h_total / window) if h_total else None)
    elif h_window:
        w.window_s = h_window
        w.windows = half_up(h_total / h_window) if h_total else rounds
        w.notes.append("window_from_header")
    if kind == "tabata":
        m = _TABATA_RE.search(text_all)
        if m:                                         # custom work/rest from the header or notes
            w.window_s, w.work_s_per_window = float(m.group(1)) + float(m.group(2)), float(m.group(1))
            w.notes.append("tabata_custom")
        elif not w.window_s:
            w.window_s, w.work_s_per_window = 30.0, 20.0   # the classic 20 s on / 10 s off
        else:
            w.work_s_per_window = w.work_s_per_window or (w.window_s * 2.0 / 3.0)
        if not w.windows:
            w.windows = rounds or 8
            if not rounds:
                w.notes.append("tabata_default_8")
    if w.window_s and not w.intervals and not w.unbounded:
        w.intervals = "every"                         # every N min, fixed starts, each round timed
    if w.window_s and w.windows:
        w.cap_s = w.window_s * w.windows
        w.clock_is_duration = True
    elif h_total and not w.cap_s:
        w.cap_s = h_total
        w.clock_is_duration = w.unbounded
        w.notes.append("minutes_from_header")
    if rounds and not w.windows:
        w.passes = rounds
    if any("miss a minute" in c for c in clock):
        label = "windowscompleted"
    skipped = []
    for mv in lines:
        name = str(mv.get("name") or "")
        has_num = any(mv.get(k) for k in ("reps", "load", "distance", "time", "unit"))
        if re.match(r"\s*rest\b", name, re.I):
            t = _seconds(mv.get("time") or name)
            if t:
                w.rest_s += t * (w.passes or w.windows or 1)
            continue
        if not has_num and tx_is_instruction(name):
            w.notes.append("instruction_line")
            skipped.append(name)
            continue
        if kind == "death_by" and _DEATH_BY_LINE_RE.search(name) and re.search(r"\breps?\b", name, re.I):
            w.notes.append("death_by_line")           # "N reps in the Nth minute": the rule
            continue
        names, cx, sets = split_line(name)
        if cx or (len(names) > 1 and strengthy):
            w.complex = True
        if sets and not w.passes and not w.windows:
            w.passes = sets
        for nm in names:
            e = Element(movement=nm, rounds=w.passes or w.windows or 1, group="cx" if w.complex and len(names) > 1 else None)
            mid = movement_id(nm)
            dist = mv.get("distance")
            if dist and mid in HEIGHT_MOVEMENTS and mv.get("reps"):
                dist = None                           # a target height, not a distance
                w.notes.append("height_not_distance")
            reps = str(mv.get("reps") or "").strip().lower()
            if dist:
                e.unit, e.value = "meters", _distance_m(dist)
            elif str(mv.get("unit") or "").lower().startswith("cal"):
                e.unit, e.value = "calories", _num(mv.get("reps"))
            elif reps == "max":
                e.unit, e.value = "max", _seconds(mv["time"]) if mv.get("time") else None
            elif mv.get("time"):
                e.unit, e.value = "seconds", _seconds(mv["time"])
            elif reps:
                e.unit, e.value = "reps", _num(reps)
            elif set_scheme(name):
                sch = set_scheme(name)
                e.unit, e.value = "reps", sum(sch) / len(sch)
            elif _distance_in(nm):                    # "Run 5k" with no number fields
                e.unit, e.value = "meters", _distance_in(nm)
            for k, v in parse_load(mv.get("load")).items():
                setattr(e, k, v)
            w.elements.append(e)
    if not w.elements:
        # the movement is only in the header or an instruction line (a strength piece, a test)
        for text in [str(piece.get("header") or "")] + skipped:
            names, cx, sets = split_line(text)
            known = [n for n in names if movement_id(n)]
            if not known:
                continue
            sch = set_scheme(text)
            if sch and not w.passes and not w.windows:
                w.passes = len(sch)
                w.rep_scheme = _ladder_of_values(sch)
            if cx or len(known) > 1:
                w.complex = strengthy or cx or w.complex
            dist = None if sch else _distance_in(text)
            for n in known:
                unit = "reps" if sch else ("meters" if dist else None)
                value = (sum(sch) / len(sch)) if sch else dist
                w.elements.append(Element(movement=n, unit=unit, value=value,
                                          rounds=w.passes or w.windows or 1,
                                          group="cx" if w.complex and len(known) > 1 else None))
            w.notes.append("movement_from_header")
            break
    if not w.elements and strengthy:
        # a strength piece whose only movement name is unknown: still one movement (its name is
        # kept in memory only, never written out)
        head = str(piece.get("header") or "").strip() or (skipped[0] if skipped else "")
        if head:
            sch = set_scheme(head)
            if sch and not w.passes and not w.windows:
                w.passes = len(sch)
            w.elements.append(Element(movement=split_line(head)[0][0], unit="reps" if sch else None,
                                      value=(sum(sch) / len(sch)) if sch else None,
                                      rounds=w.passes or w.windows or 1))
            w.notes.append("unknown_movement_from_header")
    if _HEAVIEST.search(str(piece.get("header") or "")):
        w.notes.append("heaviest")
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
    if w.buy_in and w.unbounded and len(w.elements) >= 2 and w.elements[0].main:
        w.elements[0].main = False                    # the AMRAP's buy-in is not one of its movements
    if "complex_lift" in flags:
        w.complex = True
    if label is not None:
        w.score = _draft_score(label, kind, w, strengthy)
        if w.score is None:
            w.notes.append("score_ambiguous")
    return w


def _signature(w: Workout) -> tuple:
    return (tuple(movement_id(e.movement) or e.movement.lower() for e in w.elements), w.window_s, w.cap_s,
            w.unbounded, w.intervals)


def from_draft_piece(cls: dict) -> Workout:
    """One scale classification of a workout_drafts row (format, flags, clock, rest, scoring,
    parsed pieces). Identical timed pieces in a row are one set of repeated windows."""
    fmt = str(cls.get("format") or "")
    flags = {str(f) for f in (cls.get("flags") or []) if isinstance(f, (str, int))}
    clock = [str(c).lower() for c in (cls.get("clock") or []) if isinstance(c, str)]
    rest = [str(r).lower() for r in (cls.get("rest") or []) if isinstance(r, str)]
    parsed = [p for p in (cls.get("parsed") or []) if isinstance(p, dict)]
    scoring = [str(x).strip().lower() for x in (cls.get("scoring") or [])]
    base = fmt.split("(")[0].replace("multi_part:", "").split("+")[0]
    subs = [_draft_piece(p, base, flags, scoring[min(i, len(scoring) - 1)] if scoring else None, clock, rest)
            for i, p in enumerate(parsed)]
    if len(subs) > 1 and (subs[0].cap_s or subs[0].window_s) and subs[0].elements \
            and all(_signature(x) == _signature(subs[0]) for x in subs):
        w = subs[0]
        n = len(subs)
        if w.window_s:
            w.windows = (w.windows or 1) * n
        else:
            w.window_s, w.windows, w.unbounded = w.cap_s, n, False
        w.intervals = w.intervals or "windows"
        w.cap_s = w.window_s * w.windows
        w.clock_is_duration = True
        w.notes.append("merged_repeated_windows")
    elif len(subs) > 1:
        w = Workout(source="draft", score="perPiece", pieces=subs)
        for x in subs:
            w.elements.extend(x.elements)
            w.notes.extend(x.notes)
    elif subs:
        w = subs[0]
    else:
        w = Workout(source="draft", score=_DRAFT_SCORE.get(scoring[0]) if scoring else None)
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


def element_modality(e: Element) -> tuple:
    """(modality or None, reason) of an element; a movement choice uses its shared modality."""
    if e.movement.startswith("choice:"):
        return (e.modality_hint, "movement_choice") if e.modality_hint else (None, "movement_choice")
    mod, why = modality_of(e.movement)
    if mod is None and _loaded(e):
        return "W", "loaded_unknown"
    return mod, why


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
    if w.score == "load" or w.import_strength:
        # the lift's load is the score, or the import says strength: strength even when the load
        # wasn't parsed (Data chat corpus pass: 170 of 518 strength_sets pieces regressed)
        if w.complex or len(_work_movements(w)) > 1:
            return True, "complex" if w.complex else "scored_by_load"
        if w.max_effort:
            return True, "max_effort"
        return True, "scored_by_load" if w.score == "load" else "import_strength"
    loaded = [e for e in main if _loaded(e) or (implement_of(e.movement) and element_modality(e)[0] == "W"
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
    if any(_loaded(e) and element_modality(e)[0] == "G" for e in w.elements):
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
    if "legacy_written_out" in w.notes:
        conf, reasons = ("medium" if conf == "high" else conf), reasons + ["legacy_written_out"]
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
    mod = element_modality(e)[0] or "G"
    if e.unit in ("seconds", "max") and e.value:    # "max reps in 1 min" lasts the minute
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
    if w.cap_s and not w.clock_is_duration and w.score not in (None, "time"):
        # minutes on a piece scored by distance, calories or reps are its clock, not a cap
        return w.cap_s, "clock_not_cap", "high"
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
                     seconds=half_up(secs))
    secs, src, conf = estimated_seconds(w)
    if secs is None:
        return _axis(UNKNOWN, UNKNOWN, [src], seconds=None)
    out = _axis(_bucket(secs), conf, [src], seconds=half_up(secs))
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
        if "no_reference" in reasons or "pick_load" in reasons:
            conf = "low"
        return _axis(best, conf, reasons)
    if not any_load and w.elements:
        mods = [element_modality(e)[0] for e in w.elements]
        # an implement word, "heaviest", a W movement or a load score: loaded, the number unknown
        implement = any(_W_IMPLEMENT.search(e.movement) or _HEAVIEST.search(e.movement) for e in w.elements)
        if implement or "W" in mods or w.score == "load" or w.import_strength or "heaviest" in w.notes:
            return _axis(UNKNOWN, UNKNOWN, reasons or ["loaded_without_number"])
        if all(m in ("G", "M") for m in mods):
            return _axis("bodyweight", "high", ["no_external_load"])
        # nothing loaded, only unknown names: bodyweight, low confidence (Data chat corpus pass)
        return _axis("bodyweight", "low", ["no_external_load", "unknown_movements_assumed_bodyweight"])
    return _axis(UNKNOWN, UNKNOWN, reasons or ["no_load"])


# -- modality --

def classify_modality(w: Workout) -> dict:
    present, stations, reasons, unknown = [], [], [], 0
    share = {"G": 0.0, "W": 0.0, "M": 0.0}
    for e in w.elements:
        mod, why = element_modality(e)
        if mod is None:
            unknown += 1
            if why == "movement_choice" and why not in reasons:
                reasons.append(why)
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
        why = reasons + (["unknown_movements:%d" % unknown] if unknown else ["no_movements"])
        return _axis(UNKNOWN, UNKNOWN, why, primary=None, stations=[], loaded=False)
    if unknown:
        reasons.append("unknown_movements:%d" % unknown)
    total = sum(share.values())
    primary = max(share, key=share.get) if total > 0 else present[0]
    conf = "high" if unknown == 0 and reasons == ["lexicon"] else ("medium" if unknown == 0 else "low")
    loaded = any(_loaded(e) and element_modality(e)[0] == "G" for e in w.elements)
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
        top = _SCORE_MAP.get(w.score) if w.score not in (None, "perPiece") else None
        why = ["pieces:%d" % len(w.pieces)] + [n for n in w.notes if n.startswith("combine:")]
        return _axis(top or "per_piece", "high", why, pieces=per)
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
        "notes": sorted(set(w.notes)),     # adapter codes (legacy_written_out, override_ignored, ...)
    }
    if w.pieces:
        out["pieces"] = [classify(p, athlete_max_kg, sex) for p in w.pieces]
    return out


def classify_definition(doc: dict, **kw) -> dict:
    """Any definition: v2 when it has a structure, else today's flat format."""
    if doc.get("schemaVersion") == 2 and (doc.get("structure") or doc.get("scales")):
        return classify(from_v2(doc), **kw)
    return classify(from_v1(doc), **kw)
