#!/usr/bin/env python3
"""E4 (0.18) engine gate: a definition must run identically with the workout engine off and on,
unless it is marked listedOnce (WORKOUT_SPEC 5c), and **exactly as release 0.17.2 ran it**.

Two checks, both in CI (tools/tests/test_engine_gate.py, EngineGateTests.swift):
1. Routing (off == on): every built-in and every row of Fixtures/engine_gate_cases.json is started
   the way the watch starts it (`start_progress`) and driven by the same scripts with the engine
   "legacy" and "v2": events, step starts, finish and splits must be equal.
2. Behaviour (== 0.17.2): Fixtures/engine_gate_golden.json holds the full trace (events, step
   starts, finish, every split field, and the result the watch writes at End, partial reps / reps at
   the cap included) of every built-in and fixture row under every script, written
   by **running the v0.17.2 code itself** (`--write-golden --ref v0.17.2-rc1`, from a `git archive`
   of that tag). Both engines must reproduce it. A difference is a change to how today's rows (Hyrox
   included) run: never regenerate the golden to get green; it needs the owner's sign-off.

Out of scope (watch-level, not in BarPathKit, no engine branch): the Crown's 2 s lockout and
gesture handling, partial-reps entry, HealthKit, checkpoint recovery.

Usage:
    python3 tools/engine_gate.py --write-fixture          # regenerate the routing fixture
    python3 tools/engine_gate.py --check-fixture          # exit 1 when it is stale
    python3 tools/engine_gate.py --write-golden --ref v0.17.2-rc1   # only with owner sign-off
    python3 tools/engine_gate.py --export rows.json [--ids N]
        Library rows, read-only, from a JSON export: [{"id", "definition"}] with v1 definitions.
        Prints aggregates only; row ids only with --ids N (default 0). Nothing is written. Rows
        marked listedOnce are expected to differ and are counted, not checked. Exit 1 on any
        difference, any unreadable row, nothing checked, or a file that is not a list.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import repeat_block as rb  # noqa: E402
from barpath.workout import WorkoutDefinition, WorkoutLibrary, WorkoutResult, split_stats  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
FIXTURE = REPO / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures" / "engine_gate_cases.json"
GOLDEN = FIXTURE.with_name("engine_gate_golden.json")
GOLDEN_REF = "v0.17.2-rc1"


# ---- scripts --------------------------------------------------------------------------------

def scripts(d: WorkoutDefinition) -> list:
    """Deterministic runs that cross every kind of step: steady Crowns, fast Crowns with undos, the
    clock alone, slow Crowns past any cap, an early End, sub-second double Crowns, and an undo
    right after the clock moved on (a timed rest or a window), then a Crown."""
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
    double = [[0.0, "start"]]
    for k in range(min(n, 6)):
        double += [[31.0 * (k + 1), "crown"], [31.0 * (k + 1) + 0.4, "crown"]]
    double.append([31.0 * 7 + 4000.0, "tick"])
    out.append(double)
    out.append([[0.0, "start"], [10.0, "crown"], [200.0, "tick"], [201.0, "undo"], [205.0, "crown"],
                [4205.0, "tick"]])
    return out


PARTIAL_REPS = 7   # entered on the watch after a cap finish (clamped like makeResult)


def result_fields(p, end):
    """The WorkoutResult the watch writes at End (WorkoutSessionModel.makeResult): total, finish,
    partial reps / reps at the cap (PARTIAL_REPS, clamped to the limit, only when finished), and the
    fields views read. Same code in the 0.17.2 runner."""
    from datetime import datetime, timezone
    start = p.start_time
    finish = p.finish_time
    segs = split_stats(p, end, [], [])
    r = WorkoutResult(p.definition, datetime.fromtimestamp(start, tz=timezone.utc),
                      None if finish is None else datetime.fromtimestamp(finish, tz=timezone.utc),
                      datetime.fromtimestamp(end, tz=timezone.utc),
                      (finish if finish is not None else end) - start, segs, list(p.events))
    if finish is not None:
        if r.is_capped:
            lim = r.reps_at_cap_limit
            r.reps_at_cap = min(max(0, PARTIAL_REPS), lim if lim is not None else PARTIAL_REPS)
        else:
            lim = r.partial_reps_limit
            r.partial_reps = min(max(0, PARTIAL_REPS), lim if lim is not None else PARTIAL_REPS)
    return {"totalSeconds": r.total_seconds, "finished": finish is not None, "isCapped": r.is_capped,
            "capSegmentIndex": r.cap_segment_index, "partialRepsLimit": r.partial_reps_limit,
            "repsAtCapLimit": r.reps_at_cap_limit, "partialReps": r.partial_reps, "repsAtCap": r.reps_at_cap,
            "capPositionText": r.cap_position_text, "runSeconds": r.run_seconds,
            "stationSeconds": r.station_seconds}


def run(d: WorkoutDefinition, engine: str, script: list) -> dict:
    """What the watch records for one run: events, step starts, finish, the splits and the result."""
    p = rb.start_progress(d, engine)
    events = rb.run_script(p, script)
    end = max(t for t, _ in script)
    splits = [s.to_dict() for s in split_stats(p, end, [], [])]
    return {"events": events, "starts": p.segment_starts, "finish": p.finish_time, "splits": splits,
            "result": result_fields(p, end), "block": p.block is not None}


# ---- the 0.17.2 golden --------------------------------------------------------------------------

# Runs inside a subprocess on a `git archive` of the reference tag: that release's own
# WorkoutProgress, amrap_expanded and split_stats, driven like repeat_block.run_script (cap first
# on a tie; an undo suppresses a passed auto change and a passed cap, as WorkoutSessionModel does).
_GOLDEN_RUNNER = r"""
import json, sys
from barpath.workout import WorkoutDefinition, WorkoutProgress, WorkoutResult, amrap_expanded, split_stats

PARTIAL_REPS = 7   # entered on the watch after a cap finish (clamped like makeResult)


def result_fields(p, end):
    '''The WorkoutResult the watch writes at End (WorkoutSessionModel.makeResult): total, finish,
    partial reps / reps at the cap (PARTIAL_REPS, clamped to the limit, only when finished), and the
    fields views read. Same code in the 0.17.2 runner.'''
    from datetime import datetime, timezone
    start = p.start_time
    finish = p.finish_time
    segs = split_stats(p, end, [], [])
    r = WorkoutResult(p.definition, datetime.fromtimestamp(start, tz=timezone.utc),
                      None if finish is None else datetime.fromtimestamp(finish, tz=timezone.utc),
                      datetime.fromtimestamp(end, tz=timezone.utc),
                      (finish if finish is not None else end) - start, segs, list(p.events))
    if finish is not None:
        if r.is_capped:
            lim = r.reps_at_cap_limit
            r.reps_at_cap = min(max(0, PARTIAL_REPS), lim if lim is not None else PARTIAL_REPS)
        else:
            lim = r.partial_reps_limit
            r.partial_reps = min(max(0, PARTIAL_REPS), lim if lim is not None else PARTIAL_REPS)
    return {"totalSeconds": r.total_seconds, "finished": finish is not None, "isCapped": r.is_capped,
            "capSegmentIndex": r.cap_segment_index, "partialRepsLimit": r.partial_reps_limit,
            "repsAtCapLimit": r.reps_at_cap_limit, "partialReps": r.partial_reps, "repsAtCap": r.reps_at_cap,
            "capPositionText": r.cap_position_text, "runSeconds": r.run_seconds,
            "stationSeconds": r.station_seconds}


def tick(p, now, sup):
    for _ in range(10000):
        if not p.is_started or p.is_finished:
            return
        cap = None if sup["cap"] else p.cap_time
        auto = p.auto_advance_time()
        if auto is not None and p.segment_starts[-1] == sup["auto"]:
            auto = None
        if cap is not None and cap <= now and (auto is None or cap <= auto):
            p.finish(max(cap, p.segment_starts[-1]), "auto")
            return
        if auto is None or auto > now:
            return
        if not p.auto_advance(auto):
            return

def run(d, script):
    p = WorkoutProgress(amrap_expanded(d))
    sup = {"auto": None, "cap": False}
    for t, action in script:
        tick(p, t, sup)
        if action == "start":
            p.start(t)
        elif action == "crown":
            p.advance(t, "crown")
        elif action == "undo":
            if p.undo(t, "crown"):
                a = p.auto_advance_time()
                if a is not None and a <= t:
                    sup["auto"] = p.segment_starts[-1]
                c = p.cap_time
                if c is not None and c <= t:
                    sup["cap"] = True
        elif action == "end":
            p.finish(t, "button")
    end = max(t for t, _ in script)
    return {"events": [[e.t, e.kind, e.segment_index, e.source] for e in p.events],
            "starts": p.segment_starts, "finish": p.finish_time,
            "splits": [s.to_dict() for s in split_stats(p, end, [], [])],
            "result": result_fields(p, end)}

cases = json.load(sys.stdin)
out = []
for c in cases:
    d = WorkoutDefinition.from_dict(c["definition"])
    out.append([run(d, s) for s in c["scripts"]])
json.dump(out, sys.stdout)
"""


def golden_rows() -> list:
    """Every built-in (as stored) and every routing-fixture row, with their scripts."""
    out = [(d.id, d.to_dict()) for d in WorkoutLibrary.known]
    out += [(row["id"], row) for _, row in rows()]
    return [{"name": name, "definition": row, "scripts": scripts(WorkoutDefinition.from_dict(row))}
            for name, row in out]


def build_golden(ref: str) -> dict:
    """Runs the reference release's own code on every golden row (a subprocess on `git archive`)."""
    cases = golden_rows()
    with tempfile.TemporaryDirectory() as tmp:
        archive = subprocess.run(["git", "-C", str(REPO), "archive", ref, "tools/barpath"],
                                 check=True, capture_output=True).stdout
        subprocess.run(["tar", "-x", "-C", tmp], input=archive, check=True)
        code = "import sys; sys.path.insert(0, %r)\n" % str(Path(tmp) / "tools") + _GOLDEN_RUNNER
        res = subprocess.run([sys.executable, "-I", "-c", code], input=json.dumps(cases).encode(),
                             capture_output=True, check=True, cwd=tmp)
    traces = json.loads(res.stdout)
    for c, t in zip(cases, traces):
        c["traces"] = t
    return {"ref": ref,
            "note": "E4 golden: the full trace of every built-in and gate row under every script, "
                    "written by running the %s code itself (tools/engine_gate.py --write-golden). "
                    "Both engines must reproduce it. A difference means today's rows (Hyrox "
                    "included) run differently: do not regenerate to get green; it needs the "
                    "owner's sign-off." % ref,
            "cases": cases}


def golden_diffs(golden: dict) -> list:
    """Where this code (engine off or on) differs from the golden, as short strings."""
    diffs = []
    for c in golden["cases"]:
        d = WorkoutDefinition.from_dict(c["definition"])
        for i, (script, want) in enumerate(zip(c["scripts"], c["traces"])):
            for engine in (rb.ENGINE_LEGACY, rb.ENGINE_V2):
                got = run(d, engine, script)
                for k in ("events", "starts", "finish", "splits", "result"):
                    if got[k] != want[k]:
                        diffs.append("%s script %d engine %s: %s differ" % (c["name"], i, engine, k))
    return diffs


def compare(d: WorkoutDefinition) -> list:
    """Differences between engine off and on over every script, as short strings."""
    diffs = []
    for i, script in enumerate(scripts(d)):
        off = run(d, rb.ENGINE_LEGACY, script)
        on = run(d, rb.ENGINE_V2, script)
        for k in ("events", "starts", "finish", "splits", "result"):
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
        ("short for-time cap, finished past it (reps at the cap)", _row("gate.capShort", "forTime", [
            st("burpees", "Burpees", 20), st("airSquats", "Air Squats", 30), st("pushUps", "Push-ups", 20),
            st("kettlebellSwings", "KB Swings", 25)], cap=120)),
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
    if not isinstance(data, list):
        raise SystemExit("export must be a JSON list of {\"id\", \"definition\"}")
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
    g.add_argument("--write-golden", action="store_true",
                   help="rewrite the 0.17.2 golden from --ref (only with the owner's sign-off)")
    g.add_argument("--export", help="JSON export [{\"id\", \"definition\"}] of library rows")
    ap.add_argument("--ids", type=int, default=0, help="list up to N differing row ids (default 0)")
    ap.add_argument("--ref", default=GOLDEN_REF, help="release tag the golden is written from")
    args = ap.parse_args(argv)
    if args.write_fixture:
        FIXTURE.write_text(fixture_text(), encoding="utf-8")
        return 0
    if args.check_fixture:
        return 0 if FIXTURE.exists() and FIXTURE.read_text(encoding="utf-8") == fixture_text() else 1
    if args.write_golden:
        GOLDEN.write_text(json.dumps(build_golden(args.ref), indent=1, ensure_ascii=False) + "\n",
                          encoding="utf-8")
        return 0
    stats = check_export(args.export, args.ids)
    sys.stdout.write(json.dumps(stats, indent=1) + "\n")
    builtins_bad = [d.id for d in WorkoutLibrary.known + WorkoutLibrary.engine_tests
                    if not d.listed_once and compare(d)]
    bad = stats["differing"] or stats["unreadable"] or stats["checked"] == 0 or builtins_bad
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
