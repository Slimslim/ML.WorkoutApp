"""Synthetic workout definitions for the v2 structure and engine tests.

All invented for these tests (generic movements and numbers); no gym's or paid programme's text.
Each is a complete v2 definition; `structure` follows docs/WORKOUT_MODEL_RFC.md §3.4."""


def _doc(id_, name, structure, team="solo", **extra):
    d = {"schemaVersion": 2, "id": "test." + id_, "name": name, "shortName": name[:10], "team": team,
         "healthKitActivity": "crossTraining", "structure": structure}
    d.update(extra)
    return d


def part(id_, movement, value=None, unit="reps", **kw):
    p = {"id": id_, "movement": movement}
    if value == "max":
        p["target"] = {"max": True, "unit": unit}
    elif value is not None:
        p["target"] = {"value": value, "unit": unit}
    p.update(kw)
    return {"part": p}


TABATA = _doc("tabata", "Tabata Squats", {
    "score": {"type": "totalReps", "parts": ["sq"], "show": "lowestReps"},
    "body": [{"repeat": {"id": "rp", "times": 8, "body": [
        {"timed": {"id": "work", "seconds": 20, "early": "wait", "late": "cut", "body": [
            part("sq", "airSquats", "max")]}},
        {"rest": {"id": "r", "seconds": 10}}]}}]})

WINDOWS_3334 = _doc("windows3334", "Windows 3-3-3-4", {
    "score": {"type": "totalReps", "parts": ["bench"]},
    "body": [{"repeat": {"id": "rp", "times": 4, "body": [
        {"timed": {"id": "w", "seconds": 180, "early": "wait", "late": "cut", "body": [
            part("bike", "bike", 21, "calories"),
            part("pu", "strictPullUps", 15),
            part("bench", "dumbbellBenchPress", "max")]}},
        {"rest": {"id": "r", "seconds": 60}}],
        "override": [{"rounds": ["last"], "id": "w", "set": {"seconds": 240}},
                     {"rounds": ["last"], "id": "r", "omit": True}]}}]})

WINDOWS_3333 = _doc("windows3333", "Windows 3:00 x4", {
    "score": {"type": "totalReps", "parts": ["bench"]},
    "body": [{"repeat": {"id": "rp", "times": 4, "body": [
        {"timed": {"id": "w", "seconds": 180, "early": "wait", "late": "cut", "body": [
            part("bike", "bike", 21, "calories"),
            part("pu", "strictPullUps", 15),
            part("bench", "dumbbellBenchPress", "max")]}},
        {"rest": {"id": "r", "seconds": 60}}]}}]})

EMOM = _doc("emom", "EMOM 10 Swings", {
    "score": {"type": "windowsCompleted"},
    "body": [{"repeat": {"id": "rp", "times": 10, "body": [
        {"timed": {"id": "m", "seconds": 60, "early": "wait", "late": "cut", "body": [
            part("kb", "kettlebellSwings", 15)]}}]}}]})

EMOM_ALT = _doc("emomAlt", "Alternating EMOM", {
    "score": {"type": "windowsCompleted"},
    "body": [{"repeat": {"id": "rp", "times": 5, "body": [
        {"timed": {"id": "odd", "seconds": 60, "early": "wait", "late": "cut", "body": [
            part("kb", "kettlebellSwings", 15)]}},
        {"timed": {"id": "even", "seconds": 60, "early": "wait", "late": "cut", "body": [
            part("bp", "burpees", 10)]}}]}}]})

EMOM_HOLD = _doc("emomHold", "EMOM with a hold", {
    "score": {"type": "none"},
    "body": [{"repeat": {"id": "rp", "times": 4, "body": [
        {"timed": {"id": "m", "seconds": 60, "early": "wait", "late": "cut", "body": [
            part("plank", "plank", 45, "seconds")]}}]}}]})

AMRAP_LADDER = _doc("amrapLadder", "AMRAP 12 ladder", {
    "score": {"type": "totalReps", "show": "roundsReps"},
    "body": [{"timed": {"id": "amrap", "seconds": 720, "early": "next", "late": "end", "body": [
        {"repeat": {"id": "rp", "times": None,
                    "vary": {"thr": {"from": 3, "step": 3}, "c2b": {"from": 3, "step": 3}},
                    "body": [part("thr", "thrusters", 3), part("c2b", "chestToBar", 3)]}}]}}]})

AMRAP_SHORT = _doc("amrapShort", "AMRAP 2", {
    "score": {"type": "roundsReps"},
    "body": [{"timed": {"id": "amrap", "seconds": 120, "early": "next", "late": "end", "body": [
        {"repeat": {"id": "rp", "times": None, "body": [
            part("a", "airSquats", 5), part("b", "pushUps", 5)]}}]}}]})

AMRAP_BUY_CASH = _doc("amrapBuyCash", "Buy-in, AMRAP, cash-out", {
    "score": {"type": "totalReps"},
    "body": [{"timed": {"id": "amrap", "seconds": 300, "early": "next", "late": "end", "body": [
        part("buy", "row", 20, "calories"),
        {"repeat": {"id": "rp", "times": None, "body": [
            part("a", "wallBalls", 10), part("b", "burpees", 5)]}}]}},
        part("cash", "run", 400, "meters", kind="run")]})

FOR_TIME_CAP = _doc("forTimeCap", "Three rounds, cap 16", {
    "score": {"type": "time", "atCap": "totalReps"},
    "body": [{"timed": {"id": "cap", "seconds": 960, "early": "next", "late": "continue", "body": [
        {"repeat": {"id": "rp", "times": 3, "body": [
            part("run", "run", 400, "meters", kind="run"),
            part("kb", "kettlebellSwings", 21),
            part("pu", "pullUps", 12)]}}]}}]})

HARD_CAP = _doc("hardCap", "Hard cap 5", {
    "score": {"type": "time", "atCap": "totalReps"},
    "body": [{"timed": {"id": "cap", "seconds": 300, "early": "next", "late": "end", "body": [
        {"repeat": {"id": "rp", "times": 3, "body": [
            part("a", "thrusters", 21), part("b", "pullUps", 21)]}}]}}]})

DEATH_BY = _doc("deathBy", "Death by burpees", {
    "score": {"type": "roundsReps"},
    "body": [{"repeat": {"id": "rp", "times": None, "vary": {"b": {"from": 1, "step": 1}}, "body": [
        {"timed": {"id": "min", "seconds": 60, "early": "wait", "late": "end", "body": [
            part("b", "burpees", 1)]}}]}}]})

PARTNER = _doc("partner", "Partner chipper", {
    "score": {"type": "time", "atCap": "totalReps"},
    "body": [{"timed": {"id": "cap", "seconds": 1500, "early": "next", "late": "continue", "body": [
        part("wb", "wallBalls", 100, who="shared"),
        part("row", "row", 80, "calories", who="shared"),
        part("run", "run", 800, "meters", kind="run", who="together")]}}]}, team="doubles")

INTERVALS = _doc("intervals", "5 x 250 m row", {
    "score": {"type": "perPiece", "metric": "time", "show": "avg"},
    "body": [{"repeat": {"id": "rp", "times": 5, "body": [
        part("row", "row", 250, "meters"), {"rest": {"id": "r", "seconds": 60}}]}}]})

RATIO_REST = _doc("ratioRest", "Rest as long as the round", {
    "score": {"type": "time"},
    "body": [{"repeat": {"id": "rp", "times": 3, "body": [
        {"group": {"id": "round", "label": "round", "body": [
            part("ski", "skiErg", 15, "calories"),
            part("so", "stepOvers", 12),
            part("sn", "alternatingDumbbellSnatch", 16)]}},
        {"rest": {"id": "r", "ratio": 1}}],
        "override": [{"rounds": ["last"], "id": "r", "omit": True}]}}]})

DESCENDING = _doc("descending", "21-15-9", {
    "score": {"type": "time"},
    "body": [{"repeat": {"id": "rp", "times": 3, "vary": {"thr": [21, 15, 9], "pu": [21, 15, 9]},
                         "body": [part("thr", "thrusters", 21), part("pu", "pullUps", 21)]}}]})

HYROX_STATIONS = [
    {"movement": "skiErg", "target": {"value": 1000, "unit": "meters"}},
    {"movement": "sledPush", "target": {"value": 50, "unit": "meters"}},
    {"movement": "sledPull", "target": {"value": 50, "unit": "meters"}},
    {"movement": "burpeeBroadJumps", "target": {"value": 80, "unit": "meters"}},
    {"movement": "row", "target": {"value": 1000, "unit": "meters"}},
    {"movement": "farmersCarry", "target": {"value": 200, "unit": "meters"}},
    {"movement": "sandbagLunges", "target": {"value": 100, "unit": "meters"}},
    {"movement": "wallBalls", "target": {"value": 100, "unit": "reps"}},
]

HYROX = _doc("hyrox", "HYROX Solo", {
    "score": {"type": "time"},
    "body": [{"repeat": {"id": "rp", "times": 8, "body": [
        part("run", "run", 1000, "meters", kind="run"),
        {"part": {"id": "st", "kind": "station", "movement": "skiErg"}}],
        "vary": {"st": HYROX_STATIONS}}}]})

BUILD_TO_MAX = _doc("buildMax", "Build to a heavy 3", {
    "score": {"type": "load"},
    "body": [{"repeat": {"id": "att", "times": None, "until": "athlete", "body": [
        part("sq", "backSquat", 3, load={"value": 100, "unit": "kg"})]}},
        part("cool", "row", 500, "meters")]})

SCALED = _doc("scaled", "Two scales", {
    "score": {"type": "time"},
    "body": [{"part": {"id": "a", "movement": "pullUps",
                       "target": {"value": 30, "valueF": 20, "unit": "reps"}}}]},
    scales=[
        {"id": "rx", "label": "Rx", "short": "Rx", "rank": 2, "structure": None},
        {"id": "l1", "label": "Level 1", "short": "L1", "rank": 1, "structure": {
            "score": {"type": "time"},
            "body": [{"part": {"id": "a", "movement": "ringRows", "target": {"value": 30, "unit": "reps"}}}]}}])
SCALED["scales"][0]["structure"] = SCALED["structure"]

ALL = {
    "tabata": TABATA, "windows3334": WINDOWS_3334, "windows3333": WINDOWS_3333, "emom": EMOM,
    "emomAlt": EMOM_ALT, "emomHold": EMOM_HOLD, "amrapLadder": AMRAP_LADDER, "amrapShort": AMRAP_SHORT,
    "amrapBuyCash": AMRAP_BUY_CASH, "forTimeCap": FOR_TIME_CAP, "hardCap": HARD_CAP, "deathBy": DEATH_BY,
    "partner": PARTNER, "intervals": INTERVALS, "ratioRest": RATIO_REST, "descending": DESCENDING,
    "hyrox": HYROX, "buildMax": BUILD_TO_MAX, "scaled": SCALED,
}
