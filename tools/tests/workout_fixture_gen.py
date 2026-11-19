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
from pathlib import Path

from barpath import workout_engine as we
from barpath import workout_structure as ws
from engine_cases import ALL, EMOM, TABATA

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
    },
    "ratioRest": {"roundTimes": ticked(500, 865 * S, crowns(
        50 * S, 100 * S, 155 * S, 200 * S, 370 * S, 430 * S, 490 * S, 700 * S, 730 * S, 760 * S))},
    "descending": {"splits": ticked(0, 0, crowns(*[60 * S * k for k in range(1, 7)]))},
    "hyrox": {
        "race": ticked(0, 0, crowns(*[240 * S * k for k in range(1, 17)], 240 * S + 1500)),
        "undo": ticked(0, 0, crowns(240 * S) + [{"kind": "undo", "t": 250 * S}]),
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


def generate() -> dict:
    """{relative path: file text} for everything under Fixtures/workouts."""
    files = {}
    scenario_count = 0
    for name in sorted(ALL):
        doc = ws.compile_definition(ALL[name])
        p = we.plan(doc)
        files["%s/definition.json" % name] = dumps(doc)
        files["%s/expected_plan.json" % name] = dumps({"hash": p.hash, "plan": p.to_dict()})
        for scen, spec in sorted(SCENARIOS[name].items()):
            st, eff = we.run(p, expand_events(spec))
            files["%s/events/%s.json" % (name, scen)] = dumps(spec)
            files["%s/expected/%s.result.json" % (name, scen)] = dumps(result(st, eff))
            scenario_count += 1
    rc = runnable_cases()
    for c in rc:
        status, missing = ws.check_runnable(c["doc"], tuple(c["engineFeatures"]))
        assert [status, missing] == c["expected"], (c["name"], status, missing)
    files["runnable.json"] = dumps(rc)
    files["INDEX.json"] = dumps({"cases": sorted(ALL), "scenarios": scenario_count, "runnable": len(rc),
                                 "planner": we.PLANNER_VERSION})
    return files


def write(out: Path = OUT) -> int:
    files = generate()
    for rel, text in files.items():
        path = out / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return len(files)
