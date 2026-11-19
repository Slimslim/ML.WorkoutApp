"""Parity fixtures for BarPathKit's WorkoutEngine.swift (docs/WORKOUT_MODEL_RFC.md §10).

Python is the reference: this module writes, for every synthetic case in engine_cases.py,
`Fixtures/workouts/<case>/` with
- definition.json             the compiled definition (what the watch receives);
- expected_plan.json          {"hash", "plan"}: the canonical plan and its SHA-256;
- events/<scenario>.json      the input events (compact: a tick spec plus events, or a stream);
- expected/<scenario>.result.json  effects, facts, score, boundaries, done, asks after the run;
plus runnable.json (the `requires` / schema-version check) and INDEX.json (counts, so a missing
case fails instead of skipping). Swift reads the same files. Regenerate with
`python3 tools/make_workout_fixtures.py`; tools/tests/test_workout_fixtures.py fails if the files
on disk are not what this module generates.

Event files: {"ticks": {"every": ms, "until": ms}, "events": [...]} is expanded exactly like
`expand_events`: START at 0, a tick every `every` ms up to `until`, then the listed events; sorted
by (t, order) with start 0, tick 1, others 2, stable. {"stream": [...]} is used as written (late
deliveries)."""
import json
import random
from pathlib import Path

from barpath import workout_engine as we
from barpath import workout_structure as ws
from barpath import workout_csv as wc
from barpath import workout_session as wss
from barpath.workout_upgrade import upgrade
from engine_cases import ALL, EMOM, TABATA, part
from upgrade_cases import ALL as UPGRADE_ROWS, EDGE as UPGRADE_EDGE

UPGRADE_CASES = dict(UPGRADE_ROWS, **{k: v[0] for k, v in UPGRADE_EDGE.items()})

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/workouts"
S = 1000


def dumps(v) -> str:
    return json.dumps(v, indent=1, sort_keys=True, ensure_ascii=False) + "\n"


def expand_events(spec: dict) -> list:
    if "stream" in spec:
        return [dict(e) for e in spec["stream"]]
    ticks = spec.get("ticks") or {}
    evs = [(0, 0, 0, {"kind": "start", "t": 0})]
    every, until = ticks.get("every"), ticks.get("until", 0)
    if every:
        evs += [(t, 1, 0, {"kind": "tick", "t": t}) for t in range(every, until + 1, every)]
    for i, e in enumerate(spec.get("events") or []):
        evs.append((e["t"], 2, i, dict(e)))
    return [e for _, _, _, e in sorted(evs, key=lambda x: (x[0], x[1], x[2]))]


def crowns(*ts, **kw):
    return [dict({"kind": "crown", "t": t}, **kw) for t in ts]


def reps(t, *pairs):
    return [{"kind": "reps", "t": t, "step": s, "value": v} for s, v in pairs]


def ticked(every, until, events=()):
    return {"ticks": {"every": every, "until": until}, "events": list(events)}


def _late_stream(case_events_until, late_event):
    """A stream delivered on time up to a tick, then one event stamped earlier (the watch race)."""
    stream = expand_events(case_events_until)
    stream.append(late_event)
    return {"stream": stream}


SCENARIOS = {
    "tabata": {
        "noCrown": ticked(1000, 241 * S),
        "stoppedAndRestCrowns": ticked(500, 241 * S, crowns(25 * S, 41 * S, 47 * S) + reps(
            241 * S, *[("rp.%d.sq" % (k + 1), n) for k, n in enumerate([12, 11, 10, 10, 9, 9, 8, 7])])),
        "lateCrownAtBell": _late_stream(ticked(500, 20500), {"kind": "crown", "t": 20200}),
        "lateStopped": _late_stream(ticked(500, 12500), {"kind": "crown", "t": 12 * S}),
    },
    "windows3334": {
        "recorded13nov": ticked(1000, 1100 * S, crowns(70 * S, 140 * S, 199 * S, 300 * S, 401 * S, 481 * S,
                                                       482 * S, 600 * S, 732 * S, 800 * S, 900 * S, 1041 * S)),
        "gymTruth": ticked(1000, 1000 * S, crowns(70 * S, 140 * S, 300 * S, 370 * S, 540 * S, 760 * S, 830 * S)
                           + reps(1000 * S, ("rp.1.bench", 12), ("rp.2.bench", 7), ("rp.3.pu", 12),
                                  ("rp.4.bench", 12))),
        "iWasFurther": ticked(1000, 181 * S, reps(181 * S, ("rp.1.bench", 5))),
        "lockout": ticked(1000, 16 * S, crowns(10 * S, 13 * S, 15 * S)),
    },
    "windows3333": {"noCrown": ticked(1000, 1000 * S)},
    "emom": {
        "minute7Failed": ticked(1000, 610 * S, crowns(*[60 * S * k + 40 * S for k in range(10) if k != 6])
                                + reps(610 * S, ("rp.7.kb", 11))),
        "bellLockout": ticked(1000, 62 * S, crowns(61500)),
        "grace": ticked(1000, 61 * S, crowns(60300, began=59600)),
        "undoInWindow": ticked(1000, 50 * S, crowns(40 * S) + [{"kind": "undo", "t": 50 * S}]),
        "undoAcrossBell": ticked(1000, 65 * S, crowns(40 * S) + [{"kind": "undo", "t": 65 * S}]),
    },
    "emomAlt": {"threeDone": ticked(1000, 601 * S, crowns(30 * S, 90 * S, 150 * S))},
    "emomHold": {"crownIgnored": ticked(1000, 241 * S, crowns(10 * S))},
    "amrapLadder": {"every20s": ticked(1000, 730 * S, crowns(*range(20 * S, 711 * S, 20 * S))
                                       + reps(730 * S, ("rp.18.c2b", 30)))},
    "amrapShort": {
        "pastTheList": ticked(500, 121 * S, crowns(*range(4500, 120 * S, 4500))),
        "lateCrownMovesTheCut": _late_stream(ticked(500, 120500, crowns(*range(4500, 116 * S, 4500))),
                                             {"kind": "crown", "t": 118500}),
    },
    "amrapBuyCash": {"cashOut": ticked(1000, 401 * S, crowns(60 * S, *range(80 * S, 300 * S, 20 * S), 400 * S)
                                       + reps(300 * S + 500, ("rp.6.b", 4)))},
    "forTimeCap": {
        "beforeCap": ticked(1000, 810 * S, crowns(*[90 * S * k for k in range(1, 10)])),
        "pastCap": ticked(1000, 1170 * S, crowns(*[130 * S * k for k in range(1, 10)])
                          + reps(961 * S, ("rp.3.kb", 15))),
        "twoQuickTurns": ticked(1000, 64 * S, crowns(60 * S, 63 * S)),
    },
    "hardCap": {
        "capped": ticked(1000, 310 * S, crowns(100 * S, 200 * S) + reps(305 * S, ("rp.2.a", 9))),
        "finished": ticked(1000, 241 * S, crowns(*[40 * S * k for k in range(1, 7)])),
        "lateCrownAfterEnd": _late_stream(ticked(500, 300500, crowns(100 * S, 200 * S)),
                                          {"kind": "crown", "t": 300200}),
    },
    "deathBy": {"tenPlusSix": ticked(1000, 700 * S, crowns(*[60 * S * k + 10 * S for k in range(10)])
                                     + reps(661 * S, ("rp.11.b", 6)))},
    "partner": {
        "finished": ticked(1000, 800 * S, crowns(300 * S, 600 * S, 800 * S)),
        "lateFinish": _late_stream(ticked(1000, 801 * S, crowns(300 * S, 600 * S)),
                                   {"kind": "crown", "t": 800 * S}),
    },
    "intervals": {
        "fivePieces": ticked(500, 595 * S, crowns(58 * S, 179 * S, 296 * S, 416 * S, 535 * S)),
        "undoRefused": ticked(1000, 70 * S, crowns(58 * S) + [{"kind": "undo", "t": 70 * S}]),
        # Owner decision (W27 PR3): a Crown turn in a clocked rest outside any window ends it early.
        "crownEndsRest": ticked(1000, 100 * S, crowns(58 * S, 90 * S)),
    },
    "ratioRest": {"roundTimes": ticked(500, 865 * S, crowns(
        50 * S, 100 * S, 155 * S, 200 * S, 370 * S, 430 * S, 490 * S, 700 * S, 730 * S, 760 * S))},
    "descending": {"splits": ticked(0, 0, crowns(*[60 * S * k for k in range(1, 7)]))},
    "hyrox": {
        "race": ticked(0, 0, crowns(*[240 * S * k for k in range(1, 17)], 240 * S + 1500)),
        "undo": ticked(0, 0, crowns(240 * S) + [{"kind": "undo", "t": 250 * S}]),
        # Undo an early Crown, then end the same step again (the CSV must keep the real end).
        "undoThenAgain": ticked(0, 0, crowns(60 * S) + [{"kind": "undo", "t": 61 * S}]
                                + crowns(180 * S, 300 * S)),
        "lateLockout": {"stream": [{"kind": "start", "t": 0}, {"kind": "crown", "t": 99 * S},
                                   {"kind": "tick", "t": 100500}, {"kind": "crown", "t": 100 * S}]},
        "lateIgnored": {"stream": [{"kind": "start", "t": 0}, {"kind": "tick", "t": 100 * S},
                                   {"kind": "crown", "t": 90 * S}]},
        "endEarly": ticked(0, 0, crowns(240 * S) + [{"kind": "end", "t": 300 * S}]),
    },
    "buildMax": {"blockDone": ticked(0, 0, crowns(60 * S, 120 * S, 180 * S, 400 * S)
                                     + [{"kind": "blockDone", "t": 300 * S}])},
    "scaled": {"one": ticked(0, 0, crowns(90 * S))},
}


def runnable_cases() -> list:
    resume = {"schemaVersion": 2, "structure": {"score": {"type": "time"}, "body": [
        {"repeat": {"id": "a", "times": 2, "body": [{"part": {"id": "x", "movement": "run"}}]}},
        {"repeat": {"id": "b", "times": 2, "resume": "a", "body": [{"part": {"id": "y", "movement": "run"}}]}}]}}
    return [
        {"name": "ok", "doc": ws.compile_definition(EMOM), "engineFeatures": [], "expected": ["ok", []]},
        {"name": "draft", "doc": dict(EMOM, schemaVersion=0), "engineFeatures": [], "expected": ["draft", []]},
        {"name": "newerSchema", "doc": dict(EMOM, schemaVersion=3), "engineFeatures": [],
         "expected": ["updateApp", ["schemaVersion 3"]]},
        {"name": "noSchemaVersion", "doc": {k: v for k, v in TABATA.items() if k != "schemaVersion"},
         "engineFeatures": [], "expected": ["updateApp", ["schemaVersion None"]]},
        {"name": "featureWithoutRequires", "doc": resume, "engineFeatures": [],
         "expected": ["updateApp", ["resume"]]},
        {"name": "requiresListed", "doc": dict(resume, requires=["resume"]), "engineFeatures": [],
         "expected": ["updateApp", ["resume"]]},
        {"name": "unknownRequires", "doc": dict(ws.compile_definition(EMOM), requires=["fooFeature"]),
         "engineFeatures": [], "expected": ["updateApp", ["fooFeature"]]},
        {"name": "featureKnown", "doc": dict(resume, requires=["resume"]), "engineFeatures": ["resume"],
         "expected": ["ok", []]},
    ]


def result(st, effects) -> dict:
    return {"effects": effects, "facts": we.facts(st), "score": we.score(st),
            "boundaries": we.boundaries(st), "done": st.done, "doneT": st.done_t,
            "endedBy": st.ended_by, "asks": list(st.asks),
            "current": st.current.id if st.current else None}


# Cases beyond engine_cases.ALL that the validator would refuse (unknown nodes) or that need plan
# arguments (scale, standard, machine choice): options.json holds the arguments for plan().
_VARIANT_RX = {"score": {"type": "time", "includeRest": False}, "body": [
    {"repeat": {"id": "rp", "times": 3, "vary": {"thr": [21, 15, 9]}, "body": [
        {"group": {"id": "round", "label": "round", "body": [
            {"part": {"id": "thr", "movement": "thrusters", "name": "Übung – 1/2",
                      "target": {"value": 21, "valueF": 15, "unit": "reps"},
                      "load": {"value": 42.5, "valueF": 30, "unit": "kg"}}},
            {"part": {"id": "cardio", "movement": {"choice": ["row", "bike", "skiErg"]},
                      "target": {"value": 12.5, "unit": "calories"}}}]}},
        {"rest": {"id": "r", "ratio": 0.5}}],
        "override": [{"rounds": ["last"], "id": "r", "omit": True}]}}]}
_VARIANT_L1 = {"score": {"type": "time"}, "body": [
    {"part": {"id": "thr", "movement": "ringRows", "name": "Rudern – Ring",
              "target": {"value": 30, "unit": "reps"}}}]}
VARIANTS = {"schemaVersion": 2, "id": "test.variants", "name": "Übung – 1/2", "team": "solo",
            "structure": _VARIANT_RX,
            "scales": [{"id": "rx", "label": "Rx", "short": "Rx", "rank": 2, "structure": _VARIANT_RX},
                       {"id": "l1", "label": "Level 1", "short": "L1", "rank": 1, "structure": _VARIANT_L1}]}
UNKNOWN_NODES = {"schemaVersion": 2, "id": "test.unknown", "name": "Unknown blocks", "team": "solo",
                 "structure": {"score": {"type": "time"}, "body": [
                     {"future": {"id": "x", "laps": 3}, "rawText": "3 laps of a future block"},
                     part("a", "run", 400, "meters", kind="run"),
                     {"group": {"id": "g", "body": [{"futureToo": {}}, part("b", "burpees", 10)]}}]}}

_VARIANT_CROWNS = crowns(30 * S, 61 * S, 122 * S, 152 * S, 228 * S, 258 * S)
# A ratio rest after long work (32-bit: milli × measured ms passes 2^31), and one clamped at
# MAX_BELL_MS.
RATIO_LONG = {"schemaVersion": 2, "id": "test.ratioLong", "name": "Long row, rest 100x", "team": "solo",
              "structure": {"score": {"type": "time"}, "body": [
                  part("row", "row", 10000, "meters"), {"rest": {"id": "r", "ratio": 100}},
                  part("run", "run", 400, "meters", kind="run")]}}
EXTRA = {
    "ratioLong": (RATIO_LONG, {}, {
        "tenMinutes": ticked(60 * S, 61200 * S, crowns(600 * S, 60700 * S)),
        "clamped": ticked(600 * S, 7800 * S, crowns(7200 * S))}),
    "unknownNodes": (UNKNOWN_NODES, {}, {"athletePaced": ticked(0, 0, crowns(60 * S, 120 * S, 180 * S, 240 * S))}),
    "variantsM": (VARIANTS, {}, {"rounds": ticked(500, 260 * S, _VARIANT_CROWNS)}),
    "variantsF": (VARIANTS, {"standard": "F", "choices": {"cardio": "bike"}},
                  {"rounds": ticked(500, 260 * S, _VARIANT_CROWNS)}),
    "variantsL1": (VARIANTS, {"scale": "l1"}, {"one": ticked(0, 0, crowns(90 * S))}),
}

RANDOM_CASES = ("tabata", "windows3334", "amrapShort", "forTimeCap", "intervals", "hyrox")


def _random_scenarios(name: str) -> dict:
    """Seeded random event streams (RFC 10.3): Crowns (some begun earlier), undos, and one stream
    with Crowns delivered after the next tick."""
    out = {}
    for seed in (1, 2):
        rng = random.Random("%s-%d" % (name, seed))
        horizon = 1100 * S
        tick = rng.choice([200, 1000])
        evs = []
        for t in sorted(rng.sample(range(500, horizon, 100), rng.randint(10, 50))):
            e = {"kind": "crown", "t": t}
            if rng.random() < 0.15:
                e["began"] = t - rng.choice([100, 400, 900])
            evs.append(e)
        for t in sorted(rng.sample(range(1000, horizon, 100), 3)):
            evs.append({"kind": "undo", "t": t})
        spec = ticked(tick, horizon, evs)
        out["random%d" % seed] = spec
        if seed == 2:
            on_time = expand_events(spec)
            stream, pending = [], []
            for e in on_time:
                if e["kind"] == "crown" and rng.random() < 0.4:
                    pending.append(e)
                    continue
                stream.append(e)
                if e["kind"] == "tick" and pending:
                    stream.extend(pending)
                    pending = []
            stream.extend(pending)
            out["random2late"] = {"stream": stream}
    return out


def plan_error_cases() -> list:
    def doc(body):
        return {"schemaVersion": 2, "structure": {"score": {"type": "none"}, "body": body}}
    cases = [
        ("tooManySteps", [{"repeat": {"id": "rp", "times": 401, "body": [part("a", "run")]}}]),
        ("hugeTimes", [{"repeat": {"id": "rp", "times": 1e20, "body": [part("a", "run")]}}]),
        ("hugeListRounds", [{"timed": {"id": "t", "seconds": 60, "early": "next", "late": "end", "body": [
            {"repeat": {"id": "rp", "times": None, "listRounds": 1e30, "body": [part("a", "run")]}}]}}]),
        ("hugeSeconds", [{"timed": {"id": "t", "seconds": 1e19, "early": "next", "late": "cut",
                                    "body": [part("a", "run")]}}]),
        ("hugeRestSeconds", [part("w", "run"), {"rest": {"id": "r", "seconds": 10 ** 12}}]),
        ("hugeRatio", [part("w", "run"), {"rest": {"id": "r", "ratio": 1e9}}]),
        ("hugeSecondsTarget", [{"part": {"id": "a", "movement": "plank",
                                         "target": {"value": 1e19, "unit": "seconds"}}}]),
        ("zeroTimes", [{"repeat": {"id": "rp", "times": 0, "body": [part("a", "run")]}}]),
        ("emptyBody", []),
        ("varyHugeSeconds", [{"repeat": {"id": "rp", "times": 2, "vary": {"t": [60, 10 ** 12]}, "body": [
            {"timed": {"id": "t", "seconds": 60, "early": "wait", "late": "cut",
                       "body": [part("a", "run")]}}]}}]),
        ("emptyNestedRepeats", [part("a", "run"), {"repeat": {"id": "r1", "times": 10000, "body": [
            {"repeat": {"id": "r2", "times": 10000, "body": []}}]}}]),
        # Bells past 7 days of START (MAX_BELL_MS): eight chained 24 h rests.
        ("bellsPastAWeek", [{"repeat": {"id": "rp", "times": 8, "body": [
            {"rest": {"id": "r", "seconds": 86400}}]}}, part("a", "run")]),
    ]
    hold = {"part": {"id": "hold", "movement": "plank", "target": {"value": 60, "valueF": 1e19, "unit": "seconds"}}}
    hold_x = {"part": {"id": "hold", "movement": "plank", "target": {"value": 60, "valueF": "x", "unit": "seconds"}}}
    hold_neg = {"part": {"id": "hold", "movement": "plank", "target": {"value": 60, "valueF": -5, "unit": "seconds"}}}
    cases_f = [("secondsTargetValueFHuge", [hold]), ("secondsTargetValueFText", [hold_x]),
               ("secondsTargetValueFNegative", [hold_neg])]
    out = []
    for name, body, opts in [(n, b, {}) for n, b in cases] + [(n, b, {"standard": "F"}) for n, b in cases_f]:
        try:
            we.plan(doc(body), **opts)
            reason = "ok"
        except we.NotRunnable as e:
            reason = e.reason
        assert reason != "ok", name
        case = {"name": name, "doc": doc(body), "reason": reason}
        if opts:
            case["options"] = opts
        out.append(case)
    return out


def _plan_hash(doc):
    """The plan hash, or None when the definition doesn't plan (the reader refuses it)."""
    try:
        return we.plan(doc).hash if isinstance(doc, dict) else None
    except we.NotRunnable:
        return None


def upgrade_fixture() -> list:
    """Every built-in library row and the synthetic legacy look-alikes (RFC 7.3): the input, the
    upgraded definition, its label and reasons, and the hash of its plan."""
    out = []
    for name in sorted(UPGRADE_CASES):
        u = upgrade(UPGRADE_CASES[name])
        out.append({"name": name, "input": UPGRADE_CASES[name], "label": u["label"], "reasons": u["reasons"],
                    "definition": u["definition"], "planHash": _plan_hash(u["definition"])})
    return out


CSV_SCENARIOS = [("tabata", "stoppedAndRestCrowns"), ("windows3334", "gymTruth"), ("windows3334", "lockout"),
                 ("hyrox", "undo"), ("amrapShort", "pastTheList"), ("variantsF", "rounds"),
                 ("unknownNodes", "athletePaced")]


ODD_IDS_DOC = {"schemaVersion": 2, "structure": {"score": {"type": "time"}, "body": [
    {"part": {"id": "Épaulé 1", "movement": "cleans", "target": {"value": 5, "unit": "reps"}}},
    {"rest": {"id": "007", "seconds": 10}},
    {"part": {"id": "inf", "movement": "burpees", "target": {"value": 10, "unit": "reps"}}},
    {"part": {"id": "nb\u00a0sp,x=1", "movement": "row", "target": {"value": 250, "unit": "meters"}}},
]}}
ODD_IDS_EVENTS = {"ticks": {"every": 1000, "until": 40000}, "events": [
    {"kind": "crown", "t": 5000}, {"kind": "reps", "t": 6000, "step": "Épaulé 1", "value": 5},
    {"kind": "crown", "t": 22000}, {"kind": "reps", "t": 23000, "step": "x y", "value": 3},
    {"kind": "crown", "t": 30000}]}


def csv_fixture(cases: dict) -> list:
    """The engine's CSV lines (RFC 9) for a few scenarios: plan and bell lines, then the step and
    ignored-input lines after the run."""
    out = []
    for i, (name, scen) in enumerate(CSV_SCENARIOS):
        doc, opts, scenarios = cases[name]
        p = we.plan(doc, **opts)
        st, _ = we.run(p, expand_events(scenarios[scen]))
        epoch, uptime = 1795000000000 + 1000 * i, 50000 + 7 * i
        out.append({"case": name, "scenario": scen, "startEpochMs": epoch, "startUptimeMs": uptime,
                    "planLines": wc.plan_lines(p, epoch, uptime),
                    "eventLines": [[t, line] for t, line in wc.event_lines(st)]})
    # Free-text ids: non-ASCII, Unicode spaces, ids that look like numbers (RFC 9 encoding).
    p = we.plan(ODD_IDS_DOC)
    st, _ = we.run(p, expand_events(ODD_IDS_EVENTS))
    epoch, uptime = 1795000000000 + 1000 * len(CSV_SCENARIOS), 50000 + 7 * len(CSV_SCENARIOS)
    out.append({"case": "oddIds", "scenario": "inline", "doc": ODD_IDS_DOC, "events": ODD_IDS_EVENTS,
                "startEpochMs": epoch, "startUptimeMs": uptime, "planLines": wc.plan_lines(p, epoch, uptime),
                "eventLines": [[t, line] for t, line in wc.event_lines(st)]})
    return out


# ---- session.json: the watch session on the engine (workout_session.py) ----------------------

SESSION_EVENTS = [
    {"kind": "crown", "t": 1500},
    {"kind": "crown", "t": 1500.9, "began": 900.2},
    {"kind": "crown", "t": -5, "began": -1},
    {"kind": "tick", "t": 9.3e18},
    {"kind": "tick", "t": 1e300, "began": 2 ** 70},
    {"kind": "undo", "t": "12"},
    {"kind": "undo", "t": None, "began": "x"},
    {"kind": "undo", "t": True, "began": False},
    {"kind": 7, "t": 100},
    {"t": 100},
    {"kind": "reps", "t": 5000, "step": "rp.1.sq", "value": 12},
    {"kind": "reps", "t": 5000, "step": "rp.1.sq", "value": None},
    {"kind": "reps", "t": 5000, "step": 3, "value": {"n": 4.5, "x": [1, 2]}},
    {"kind": "end", "t": 700000, "source": "button", "x-note": {"keep": ["me", 1.5]}},
    {"kind": "crown", "t": 604800000},
    {"kind": "crown", "t": 604800001},
    {},
    [],
    "crown",
    None,
]


def _session_routes(cases: dict) -> list:
    from upgrade_cases import ALL as LEGACY
    out = []
    for name in ("hyrox.solo", "hyrox.doubles", "wod.helen"):
        if name in LEGACY:
            out.append({"name": "legacy:" + name, "raw": LEGACY[name]})
    for name in ("tabata", "hyrox", "emom", "variantsL1"):
        out.append({"name": "case:" + name, "case": name})
    hy = cases["hyrox"][0]
    unknown = dict(hy, requires=["teleport"])
    out += [
        {"name": "notAnObject", "raw": ["structure"]},
        {"name": "schemaOne", "raw": {"schemaVersion": 1, "name": "x", "segments": []}},
        {"name": "schemaNull", "raw": {"schemaVersion": None, "segments": []}},
        {"name": "schemaTrue", "raw": {"schemaVersion": True, "segments": []}},
        {"name": "draft", "raw": dict(hy, schemaVersion=0)},
        {"name": "schemaThree", "raw": dict(hy, schemaVersion=3)},
        {"name": "unknownFeature", "raw": unknown},
        {"name": "unknownFeatureExact", "raw": dict(unknown, fidelity="exact")},
        {"name": "unknownFeatureExactNoSegments",
         "raw": {k: v for k, v in dict(unknown, fidelity="exact").items() if k != "segments"}},
        {"name": "unknownFeatureApprox", "raw": dict(unknown, fidelity="approx", approx=["upgrade:x"])},
        {"name": "structureNotObject", "raw": {"schemaVersion": 2, "structure": "x"}},
        {"name": "tooLarge", "raw": {"schemaVersion": 2, "structure": {"score": {"type": "time"}, "body": [
            {"repeat": {"id": "r", "times": 401, "body": [part("a", "burpees", 1)]}}]}}},
        {"name": "empty", "raw": {"schemaVersion": 2, "structure": {"score": {"type": "time"}, "body": []}}},
    ]
    for r in out:
        raw = cases[r["case"]][0] if "case" in r else r["raw"]
        opts = cases[r["case"]][1] if "case" in r else {}
        if "case" in r:
            r["options"] = opts
        r["expected"] = wss.route(raw, **opts)
    return out


SESSION_VIEW_SKIP = ("random",)
CHECKPOINT_SCENARIOS = [("tabata", "stoppedAndRestCrowns", 33 * S), ("windows3334", "gymTruth", 545 * S),
                        ("hyrox", "undo", None), ("amrapShort", "pastTheList", 61 * S),
                        ("variantsF", "rounds", 150 * S), ("emom", "grace", 60500),
                        ("intervals", "crownEndsRest", 95 * S)]
LINE_SCENARIOS = [("tabata", "stoppedAndRestCrowns"), ("windows3334", "gymTruth"), ("hyrox", "undo"),
                  ("hyrox", "undoThenAgain"), ("ratioLong", "tenMinutes"),
                  ("amrapShort", "lateCrownMovesTheCut"), ("intervals", "crownEndsRest")]
CHECKPOINT_WATCH = {"heartRates": [[1795000001.5, 121], [1795000006.25, 122.5]], "recordedCSV": True,
                    "workoutId": "00000000-0000-4000-8000-000000000001", "x-later": {"a": [1, "é"]}}


def _view(st) -> dict:
    pr = wss.project(st)
    return {"count": len(pr["segments"]), "starts": pr["starts"], "sources": pr["sources"],
            "finish": pr["finish"], "finishSource": pr["finishSource"], "latestAsk": wss.latest_ask(st),
            "nextBell": wss.next_bell(st)}


def session_fixture(cases: dict) -> dict:
    """What workout_session.py gives for the same inputs: decoded events, routes, the views of
    every non-random scenario at four points (a quarter, half, three quarters and all of its
    events), checkpoints (text, byte for byte) and the CSV lines written as the run goes."""
    out = {"maxEventMs": wss.MAX_EVENT_MS, "checkpointVersion": wss.CHECKPOINT_VERSION}
    out["events"] = [{"raw": e, "decoded": wss.decode_event(e)} for e in SESSION_EVENTS]
    out["routes"] = _session_routes(cases)
    views = []
    for name in sorted(cases):
        doc, opts, scenarios = cases[name]
        p = we.plan(doc, **opts)
        for scen, spec in sorted(scenarios.items()):
            if scen.startswith(SESSION_VIEW_SKIP):
                continue
            evs = expand_events(spec)
            n = len(evs)
            at = []
            final = None
            for k in sorted({n // 4, n // 2, (3 * n) // 4, n}):
                st, _ = we.run(p, evs[:k])
                v = _view(st)
                v["events"] = k
                at.append(v)
                final = st
            segs = wss.project(final)["segments"]
            for v in at:   # earlier views are a prefix of the final list (rounds are only appended)
                assert v["count"] <= len(segs)
            views.append({"case": name, "scenario": scen, "segments": segs, "at": at})
    out["views"] = views
    cps = []
    for i, (name, scen, saved) in enumerate(CHECKPOINT_SCENARIOS):
        doc, opts, scenarios = cases[name]
        p = we.plan(doc, **opts)
        evs = expand_events(scenarios[scen])
        if saved is None:
            saved = max(int(e["t"]) for e in evs)
        live, _ = we.run(p, [e for e in evs if int(e["t"]) <= saved])
        o = wss.options_dict(opts.get("scale"), opts.get("standard", "M"), opts.get("choices"))
        epoch = 1795000000000 + 1000 * i
        cp = wss.make_checkpoint(doc, p, live, epoch, saved, options=o, watch=CHECKPOINT_WATCH)
        text = wss.checkpoint_text(cp)
        rec = wss.recover(cp)
        assert rec["status"] == "ok", (name, scen, rec)
        cps.append({"case": name, "scenario": scen, "savedAtMs": saved, "startEpochMs": epoch,
                    "text": text, "view": _view(rec["state"]), "liveView": _view(live)})
    out["checkpoints"] = cps
    lines = []
    for name, scen in LINE_SCENARIOS:
        doc, opts, scenarios = cases[name]
        p = we.plan(doc, **opts)
        st = we.initial(p)
        written = {}
        batches = []
        for i, e in enumerate(expand_events(scenarios[scen])):
            st, _ = we.reduce(st, e)
            new = wss.new_lines(st, written)
            if new:
                batches.append({"after": i + 1, "lines": [[t, line] for t, line in new]})
        lines.append({"case": name, "scenario": scen, "batches": batches})
    out["lines"] = lines
    return out


# ---- phone.json: what the phone sends for a library row (workout_session.phone_route) -----------

def phone_fixture(cases: dict) -> list:
    """For every legacy row, its Python upgrade, every v2 case and a few edge rows: the phone's
    route and the fidelity it stores."""
    from upgrade_cases import ALL as LEGACY
    rows = []
    for name in sorted(LEGACY):
        rows.append(("legacy:" + name, LEGACY[name]))
        rows.append(("upgraded:" + name, upgrade(LEGACY[name])["definition"]))
    for name in sorted(cases):
        rows.append(("case:" + name, cases[name][0]))
    tab = cases["tabata"][0]
    rows += [
        ("textOnly", dict(tab, fidelity="textOnly", rawText="20 s on, 10 s off x 8")),
        ("unknownFeature", dict(tab, requires=["teleport"])),
        ("authoredApprox", dict(tab, fidelity="approx", approx=["partnerSplitGuessed"], rawText="x")),
        ("approxNotAList", dict(tab, approx="upgrade:x")),
        ("tooBig", dict(tab, rawText="x" * (17 * 1024))),
        ("draft", dict(tab, schemaVersion=0)),
        ("notAnObject", [1, 2]),
    ]
    out = []
    for name, raw in rows:
        out.append({"name": name, "raw": raw, "route": wss.phone_route(raw), "fidelity": wss.phone_fidelity(raw)})
    return out


def generate() -> dict:
    """{relative path: file text} for everything under Fixtures/workouts."""
    files = {}
    scenario_count = 0
    cases = {name: (ws.compile_definition(ALL[name]), {}, dict(SCENARIOS[name])) for name in ALL}
    for name in RANDOM_CASES:
        cases[name][2].update(_random_scenarios(name))
    for name, (doc, opts, scen) in EXTRA.items():
        cases[name] = (ws.compile_definition(doc), opts, scen)
    for name in sorted(cases):
        doc, opts, scenarios = cases[name]
        p = we.plan(doc, **opts)
        files["%s/definition.json" % name] = dumps(doc)
        if opts:
            files["%s/options.json" % name] = dumps(opts)
        files["%s/expected_plan.json" % name] = dumps({"hash": p.hash, "plan": p.to_dict()})
        for scen, spec in sorted(scenarios.items()):
            st, eff = we.run(p, expand_events(spec))
            files["%s/events/%s.json" % (name, scen)] = dumps(spec)
            files["%s/expected/%s.result.json" % (name, scen)] = dumps(result(st, eff))
            scenario_count += 1
    rc = runnable_cases()
    for c in rc:
        status, missing = ws.check_runnable(c["doc"], tuple(c["engineFeatures"]))
        assert [status, missing] == c["expected"], (c["name"], status, missing)
    files["runnable.json"] = dumps(rc)
    pe = plan_error_cases()
    files["planErrors.json"] = dumps(pe)
    up = upgrade_fixture()
    files["upgrade.json"] = dumps(up)
    cv = csv_fixture(cases)
    files["csv.json"] = dumps(cv)
    se = session_fixture(cases)
    files["session.json"] = dumps(se)
    ph = phone_fixture(cases)
    files["phone.json"] = dumps(ph)
    files["INDEX.json"] = dumps({"cases": sorted(cases), "scenarios": scenario_count, "runnable": len(rc),
                                 "planErrors": len(pe), "upgrade": len(up), "csv": len(cv),
                                 "sessionEvents": len(se["events"]), "sessionRoutes": len(se["routes"]),
                                 "sessionViews": len(se["views"]), "sessionCheckpoints": len(se["checkpoints"]),
                                 "sessionLines": len(se["lines"]), "phone": len(ph),
                                 "planner": we.PLANNER_VERSION})
    return files


def write(out: Path = OUT) -> int:
    files = generate()
    for rel, text in files.items():
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return len(files)
