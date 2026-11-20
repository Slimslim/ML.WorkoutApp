#!/usr/bin/env python3
"""E4 (0.18) engine gate: a definition must run identically with the workout engine off and on,
unless it is marked listedOnce (WORKOUT_SPEC 5c). Every built-in and every row of
Fixtures/engine_gate_cases.json is started the way the watch starts it (`start_progress`), driven
by the same scripts with the engine "legacy" and "v2", and the events, step starts, finish and
splits must be equal. tools/tests/test_engine_gate.py and EngineGateTests.swift run it in CI.

Usage:
    python3 tools/engine_gate.py --write-fixture          # regenerate the shared fixture
    python3 tools/engine_gate.py --check-fixture          # exit 1 when it is stale
    python3 tools/engine_gate.py --export rows.json [--ids N]
        Library rows, read-only, from a JSON export: [{"id", "definition"}] with v1 definitions.
        Prints aggregates only; row ids only with --ids N (default 0). Nothing is written.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import repeat_block as rb  # noqa: E402
from barpath.workout import WorkoutDefinition, WorkoutLibrary, split_stats  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
FIXTURE = REPO / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures" / "engine_gate_cases.json"


# ---- scripts --------------------------------------------------------------------------------

def scripts(d: WorkoutDefinition) -> list:
    """Deterministic runs that cross every kind of step: steady Crowns, fast Crowns with undos, the
    clock alone, slow Crowns past any cap, and an early End."""
    n = len(d.segments)
    out = []
    steady = [[0.0, "start"]] + [[37.0 * (k + 1), "crown"] for k in range(n + 4)] + [[37.0 * (n + 5) + 4000.0, "tick"]]
    out.append(steady)
    fast = [[0.0, "start"]]
    t = 0.0
    for k in range(n + 6):
        t += 13.0
        fast.append([t, "crown"])
        if k % 5 == 4:
            t += 2.5
            fast.append([t, "undo"])
    fast.append([t + 4000.0, "tick"])
    out.append(fast)
    out.append([[0.0, "start"], [6000.0, "tick"]])
    out.append([[0.0, "start"]] + [[90.0 * (k + 1), "crown"] for k in range(n + 2)] + [[90.0 * (n + 3) + 4000.0, "tick"]])
    out.append([[0.0, "start"], [41.0, "crown"], [82.0, "crown"], [150.0, "end"]])
    return out


def run(d: WorkoutDefinition, engine: str, script: list) -> dict:
    """What the watch records for one run: events, step starts, finish, and the splits."""
    p = rb.start_progress(d, engine)
    events = rb.run_script(p, script)
    end = max(t for t, _ in script)
    splits = [s.to_dict() for s in split_stats(p, end, [], [])]
    return {"events": events, "starts": p.segment_starts, "finish": p.finish_time, "splits": splits,
            "block": p.block is not None}


def compare(d: WorkoutDefinition) -> list:
    """Differences between engine off and on over every script, as short strings."""
    diffs = []
    for i, script in enumerate(scripts(d)):
        off = run(d, rb.ENGINE_LEGACY, script)
        on = run(d, rb.ENGINE_V2, script)
        for k in ("events", "starts", "finish", "splits"):
            if off[k] != on[k]:
                diffs.append("script %d: %s differ" % (i, k))
    return diffs


# ---- the shared fixture (invented rows shaped like the library's fixed lists) -------------------

def _seg(kind, movement, name, value=None, unit=None):
    s = {"kind": kind, "movement": movement, "name": name}
    if value is not None:
        s["target"] = {"value": float(value), "unit": unit}
    return s


def _rest(seconds=None):
    return _seg("rest", "rest", "Rest", seconds, "seconds" if seconds else None)


def _row(id_, fmt, segments, cap=None, interval=None, round_size=None, team="solo", rounds=None):
    d = {"id": id_, "name": "Gate " + id_, "shortName": "G", "format": fmt, "team": team,
         "healthKitActivity": "crossTraining", "segments": segments}
    if cap is not None:
        d["timeCapSeconds"] = float(cap)
    if interval is not None:
        d["intervalSeconds"] = float(interval)
    if round_size is not None:
        d["roundSize"] = round_size
    if rounds is not None:
        d["rounds"] = rounds
    return d


def rows() -> list:
    run_ = lambda m: _seg("run", "run", "Run", m, "meters")
    st = lambda mv, name, v, u="reps": _seg("station", mv, name, v, u)
    race = []
    for mv, name, v, u in (("skiErg", "SkiErg", 500, "meters"), ("sledPush", "Sled Push", 25, "meters"),
                           ("sledPull", "Sled Pull", 25, "meters"), ("burpeeBroadJumps", "Burpee Broad Jumps", 40, "meters"),
                           ("row", "Row", 500, "meters"), ("farmersCarry", "Farmers Carry", 100, "meters"),
                           ("sandbagLunges", "Sandbag Lunges", 50, "meters"), ("wallBalls", "Wall Balls", 50, "reps")):
        race += [run_(500), st(mv, name, v, u)]
    emom = []
    for _ in range(8):
        emom += [st("powerCleans", "Power Cleans", 3), _rest()]
    tabata = []
    for _ in range(8):
        tabata += [st("airSquats", "Air Squats", 20, "seconds"), _rest(10)]
    amrap_written = [st("burpees", "Burpees", 10), st("pullUps", "Pull-ups", 5), st("airSquats", "Air Squats", 15),
                     st("row", "Row", 10, "calories")] * 3
    rounds_written = [run_(400), st("kettlebellSwings", "KB Swings", 21), st("pullUps", "Pull-ups", 12)] * 3
    alternating = [st("burpees", "Burpees", 12), st("kettlebellSwings", "KB Swings", 15)] * 5
    every_rest = []
    for _ in range(5):
        every_rest += [st("row", "Row", 12, "calories"), st("thrusters", "Thrusters", 10), _rest()]
    return [
        ("race-like fixed list, 8 x (run + station)", _row("gate.race", "forTime", race, round_size=2)),
        ("doubles race-like", _row("gate.raceDoubles", "forTime", race, round_size=2, team="doubles")),
        ("chipper with a for-time cap", _row("gate.chipper", "forTime", [
            st("row", "Row", 30, "calories"), st("wallBalls", "Wall Balls", 40), st("boxJumps", "Box Jumps", 30),
            st("burpees", "Burpees", 20), run_(800)], cap=900)),
        ("written-out EMOM 8 x 1:00", _row("gate.emom", "emom", emom, cap=480, interval=60, round_size=2)),
        ("written-out Tabata 8 x 30 s", _row("gate.tabata", "emom", tabata, cap=240, interval=30, round_size=2)),
        ("written-out every 3:00 without the last rest", _row("gate.every3", "emom", every_rest[:-1], cap=900,
                                                              interval=180, round_size=3)),
        ("alternating EMOM, no roundSize", _row("gate.alternating", "emom", alternating, cap=600, interval=60)),
        ("written-out AMRAP 3 rounds listed (expanded at START)", _row("gate.amrapWritten", "amrap", amrap_written,
                                                                     cap=720, round_size=4)),
        ("AMRAP listing one round (expanded at START)", _row("gate.amrapOne", "amrap", amrap_written[:4], cap=600)),
        ("rounds for time written out with a cap", _row("gate.rounds", "forTime", rounds_written, cap=960,
                                                       round_size=3)),
        ("rounds key but not marked listedOnce: still today's path", _row("gate.roundsUnmarked", "forTime",
                                                                         rounds_written[:3], rounds=3)),
        ("timed rest between written-out rounds", _row("gate.restRounds", "forTime", (
            [run_(200), st("burpees", "Burpees", 10), _rest(60)] * 3)[:-1], round_size=3)),
        ("open parts (free-like)", _row("gate.free", "forTime", [_seg("station", "part", "Part %d" % (i + 1))
                                                                 for i in range(12)])),
    ]


def build_fixture() -> dict:
    cases = []
    for name, row in rows():
        d = WorkoutDefinition.from_dict(row)
        assert rb.plan_for(d).kind == rb.LEGACY, name
        assert not compare(d), name
        expected = [run(d, rb.ENGINE_LEGACY, s) for s in scripts(d)]
        cases.append({"name": name, "definition": row, "scripts": scripts(d),
                      "expected": [{"events": e["events"], "finish": e["finish"], "steps": len(e["starts"])}
                                   for e in expected]})
    return {"note": "E4 engine gate (tools/engine_gate.py): invented rows shaped like the library's "
                    "fixed lists and written-out rows. Each script must give the same events, step "
                    "starts, finish and splits with the engine off and on; expected: the engine-off "
                    "run of the Python reference (events [t, kind, index, source]).",
            "cases": cases}


def fixture_text() -> str:
    return json.dumps(build_fixture(), indent=1, ensure_ascii=False) + "\n"


# ---- library rows from an export (Data chat, read-only) ---------------------------------------

def check_export(path: str, max_ids: int) -> dict:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    checked = unreadable = marked = 0
    differing = []
    for item in data:
        try:
            d = WorkoutDefinition.from_dict(item["definition"])
        except Exception:   # noqa: BLE001 - a row the reader cannot parse is counted, not fatal
            unreadable += 1
            continue
        checked += 1
        if d.listed_once:
            marked += 1
            continue
        if compare(d):
            differing.append(str(item.get("id")))
    return {"rows": len(data), "checked": checked, "unreadable": unreadable, "markedListedOnce": marked,
            "differing": len(differing), "differingIds": differing[:max(0, max_ids)]}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--write-fixture", action="store_true")
    g.add_argument("--check-fixture", action="store_true")
    g.add_argument("--export", help="JSON export [{\"id\", \"definition\"}] of library rows")
    ap.add_argument("--ids", type=int, default=0, help="list up to N differing row ids (default 0)")
    args = ap.parse_args(argv)
    if args.write_fixture:
        FIXTURE.write_text(fixture_text(), encoding="utf-8")
        return 0
    if args.check_fixture:
        return 0 if FIXTURE.exists() and FIXTURE.read_text(encoding="utf-8") == fixture_text() else 1
    stats = check_export(args.export, args.ids)
    sys.stdout.write(json.dumps(stats, indent=1) + "\n")
    builtins_bad = [d.id for d in WorkoutLibrary.known + WorkoutLibrary.engine_tests
                    if not d.listed_once and compare(d)]
    return 1 if stats["differing"] or builtins_bad else 0


if __name__ == "__main__":
    sys.exit(main())
