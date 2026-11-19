"""W46 'vs last time' (docs/RESULTS_INSIGHTS.md section 2): reference tests and the parity fixture
shared with BarPathKit's ResultCompareTests.swift. All data is invented.

Regenerate the fixture after a rule change: REGEN_RESULT_COMPARE=1 python3 -m pytest
tools/tests/test_result_compare.py -q (then check the diff)."""
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

from barpath.result_compare import (ResultScore, compare, reps_done_at_cap, reps_per_round,
                                    same_scale, NOT_COMPARED)
from barpath.workout import (SegmentLoad, SegmentResult, SegmentTarget, WorkoutDefinition,
                             WorkoutResult, WorkoutSegment)

ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/result_compare_cases.json"
MINUS = "−"


def seg(kind, movement, value=None, unit=None, load=None):
    target = SegmentTarget(value, unit) if value is not None else None
    return WorkoutSegment(kind=kind, movement=movement, name=movement.title(), target=target, load=load)


def amrap_def(wall_ball_load=SegmentLoad(20, "lb"), cap=1200.0, wid="test.amrap20"):
    """Invented AMRAP 20: 15 Cal bike, 10 step-ups, 15 wall balls (40 reps a round)."""
    return WorkoutDefinition(wid, "AMRAP 20 test", "AMRAP", "amrap", "solo", cap, "crossTraining",
                             [seg("station", "bike", 15, "calories"),
                              seg("station", "stepUps", 10, "reps"),
                              seg("station", "wallBalls", 15, "reps", wall_ball_load)],
                             round_size=3)


def amrap_run_def():
    """Invented AMRAP with a 400 m run in the round: reps can't be summed."""
    return WorkoutDefinition("test.amrap.run", "Run AMRAP test", "AMRAP", "amrap", "solo", 900.0,
                             "crossTraining",
                             [seg("run", "run", 400, "meters"), seg("station", "burpees", 10, "reps")],
                             round_size=2)


def for_time_def(cap=1200.0, push_ups=20, wid="test.fortime5"):
    """Invented 3 rounds for time: 10 pull-ups, 20 push-ups, 30 squats, 1:00 rest."""
    one = [seg("station", "pullUps", 10, "reps"), seg("station", "pushUps", push_ups, "reps"),
           seg("station", "airSquats", 30, "reps"), seg("rest", "rest", 60, "seconds")]
    return WorkoutDefinition(wid, "3 rounds test", "3 RFT", "forTime", "solo", cap, "crossTraining",
                             one * 3, round_size=4)


def emom_def():
    return WorkoutDefinition("test.emom", "EMOM test", "EMOM", "emom", "solo", None, "crossTraining",
                             [seg("station", "powerCleans", 3, "reps", SegmentLoad(135, "lb")),
                              seg("rest", "rest", 40, "seconds")], interval_seconds=60, round_size=2)


def amrap(rounds, extra, d=None, rx=None):
    d = d or amrap_def()
    return ResultScore(d, 1200.0, False, rounds=rounds, extra_reps=extra, round_size=d.round_size, rx=rx)


def done(total, d=None, rx=None):
    return ResultScore(d or for_time_def(), total, True, rx=rx)


def capped(total, reps, d=None):
    return ResultScore(d or for_time_def(), total, True, capped=True, reps_at_cap=reps)


def cases():
    """(name, current, previous) - the expected line is computed by the reference and pinned in
    the fixture; the asserts in the tests below pin the texts the spec names."""
    return [
        ("forTime both finished, faster", done(1000.0), done(1124.0)),
        ("forTime both finished, slower", done(1124.4), done(1086.0)),
        ("forTime both finished, same after rounding", done(1000.4), done(1000.0)),
        ("forTime finished, last capped with reps", done(1126.0), capped(1290.0, 84)),
        ("forTime finished, last capped, reps unknown", done(1126.0), capped(1290.0, None)),
        ("forTime capped, last finished", capped(1250.0, 200), done(1188.0)),
        ("forTime both capped, more reps", capped(1300.0, 93), capped(1290.0, 84)),
        ("forTime both capped, fewer reps", capped(1300.0, 83), capped(1290.0, 84)),
        ("forTime both capped, one rep", capped(1300.0, 85), capped(1290.0, 84)),
        ("forTime both capped, same reps", capped(1300.0, 84), capped(1290.0, 84)),
        ("forTime both capped, reps unknown", capped(1300.0, None), capped(1290.0, 84)),
        ("forTime ended early", ResultScore(for_time_def(), 600.0, False), done(1100.0)),
        ("forTime different reps (scaled)", done(1000.0), done(1100.0, for_time_def(push_ups=10))),
        ("forTime different cap", done(1000.0), done(1100.0, for_time_def(cap=900.0))),
        ("forTime Rx vs Scaled", done(1000.0, rx=True), done(1100.0, rx=False)),
        ("forTime Rx vs not answered", done(1000.0, rx=True), done(1100.0, rx=None)),
        ("forTime over an hour", done(3725.0), done(3600.0)),
        ("amrap more reps", amrap(5, 12), amrap(4, 38)),
        ("amrap one rep fewer", amrap(5, 11), amrap(5, 12)),
        ("amrap one round fewer", amrap(4, 12), amrap(5, 12)),
        ("amrap two rounds more", amrap(7, 0), amrap(5, 0)),
        ("amrap same score", amrap(5, 12), amrap(5, 12)),
        ("amrap different load", amrap(5, 12), amrap(4, 0, amrap_def(SegmentLoad(14, "lb")))),
        ("amrap 9 kg vs 20 lb is the same load", amrap(5, 12, amrap_def(SegmentLoad(9.07, "kg"))),
         amrap(4, 2)),
        ("amrap run round, more rounds", amrap(4, 0, amrap_run_def()), amrap(3, 0, amrap_run_def())),
        ("amrap run round, same rounds more reps", amrap(3, 5, amrap_run_def()),
         amrap(3, 0, amrap_run_def())),
        ("amrap run round, mixed", amrap(4, 2, amrap_run_def()), amrap(3, 5, amrap_run_def())),
        ("amrap run round, same", amrap(3, 5, amrap_run_def()), amrap(3, 5, amrap_run_def())),
        ("no earlier result", amrap(5, 12), None),
        ("other workout id", done(1000.0), done(900.0, for_time_def(wid="test.other"))),
        ("emom: no single score", ResultScore(emom_def(), 480.0, True), ResultScore(emom_def(), 480.0, True)),
    ]


def build_fixture() -> dict:
    out = []
    for name, cur, prev in cases():
        c = compare(cur, prev)
        out.append({"name": name, "current": cur.to_dict(),
                    "previous": None if prev is None else prev.to_dict(),
                    "expected": None if c is None else c.to_dict()})
    return {"comment": "W46 vs last time. Generated by tools/tests/test_result_compare.py; invented data.",
            "cases": out}


def test_fixture_matches_reference():
    data = build_fixture()
    if os.environ.get("REGEN_RESULT_COMPARE"):
        lines = [json.dumps(c, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                 for c in data["cases"]]
        FIXTURE.write_text('{"comment":' + json.dumps(data["comment"]) + ',\n"cases":[\n'
                           + ",\n".join(lines) + "\n]}\n")
    stored = json.loads(FIXTURE.read_text())
    assert stored == json.loads(json.dumps(data))
    # The stored inputs give the stored outputs (what the Swift test does).
    for c in stored["cases"]:
        prev = None if c["previous"] is None else ResultScore.from_dict(c["previous"])
        got = compare(ResultScore.from_dict(c["current"]), prev)
        assert (None if got is None else got.to_dict()) == c["expected"], c["name"]


def text(cur, prev):
    c = compare(cur, prev)
    return None if c is None else (c.text, c.tone)


def test_both_finished():
    assert text(done(1000.0), done(1124.0)) == ("2:04 faster", "better")
    assert text(done(1124.4), done(1086.0)) == ("0:38 slower", "worse")
    assert text(done(1000.4), done(1000.0)) == ("Same time", "same")
    assert text(done(3725.0), done(3600.0)) == ("2:05 slower", "worse")


def test_finished_vs_capped():
    assert text(done(1126.0), capped(1290.0, 84)) == ("Finished (last time capped at 20:00 + 84)", "better")
    assert text(done(1126.0), capped(1290.0, None)) == ("Finished (last time capped at 20:00)", "better")
    assert text(capped(1250.0, 200), done(1188.0)) == ("Capped (last time finished in 19:48)", "worse")


def test_both_capped():
    assert text(capped(1300.0, 93), capped(1290.0, 84)) == ("+9 reps at the cap", "better")
    assert text(capped(1300.0, 83), capped(1290.0, 84)) == (MINUS + "1 rep at the cap", "worse")
    assert text(capped(1300.0, 84), capped(1290.0, 84)) == ("Same reps at the cap", "same")
    assert text(capped(1300.0, None), capped(1290.0, 84)) is None


def test_amrap_total_reps():
    assert reps_per_round(amrap_def(), 3) == 40     # 15 Cal + 10 + 15
    assert text(amrap(5, 12), amrap(4, 38)) == ("+14 reps", "better")
    assert text(amrap(4, 12), amrap(5, 12)) == (MINUS + "1 round", "worse")
    assert text(amrap(7, 0), amrap(5, 0)) == ("+2 rounds", "better")
    assert text(amrap(5, 12), amrap(5, 12)) == ("Same score", "same")


def test_amrap_with_a_distance():
    assert reps_per_round(amrap_run_def(), 2) is None
    r = amrap_run_def()
    assert text(amrap(4, 0, r), amrap(3, 0, r)) == ("+1 round", "better")
    assert text(amrap(3, 5, r), amrap(3, 0, r)) == ("+5 reps", "better")
    assert text(amrap(4, 2, r), amrap(3, 5, r)) == ("+1 round, " + MINUS + "3 reps", "better")


def test_not_compared():
    assert text(done(1000.0), done(1100.0, for_time_def(push_ups=10))) == (NOT_COMPARED, "neutral")
    assert text(done(1000.0, rx=True), done(1100.0, rx=False)) == (NOT_COMPARED, "neutral")
    assert text(amrap(5, 12), amrap(4, 0, amrap_def(SegmentLoad(14, "lb")))) == (NOT_COMPARED, "neutral")
    # Not answered on one side: the segments decide.
    assert text(done(1000.0, rx=True), done(1100.0)) == ("1:40 faster", "better")
    # 9.07 kg is 20 lb.
    assert same_scale(amrap_def(SegmentLoad(9.07, "kg")), amrap_def())


def test_nothing_to_say():
    assert compare(amrap(5, 12), None) is None
    assert compare(ResultScore(for_time_def(), 600.0, False), done(1100.0)) is None
    assert compare(done(1000.0), done(900.0, for_time_def(wid="test.other"))) is None
    assert compare(ResultScore(emom_def(), 480.0, True), ResultScore(emom_def(), 480.0, True)) is None


def _capped_result(reps_at_cap, with_run=False):
    d = for_time_def(cap=300.0)
    if with_run:
        d.segments[0] = seg("run", "run", 200, "meters")
    start = datetime(2026, 1, 5, 10, 0, tzinfo=timezone.utc)
    t0 = start.timestamp()
    # Pull-ups 0-60, push-ups 60-150, squats 150-280, rest 280-340 (cap at 300), round 2 ...
    bounds = [(0, 60), (60, 150), (150, 280), (280, 340), (340, 400), (400, 520)]
    segs = [SegmentResult(index=i, kind=d.segments[i].kind, movement=d.segments[i].movement,
                          title="t", start=t0 + a, end=t0 + b, duration=b - a)
            for i, (a, b) in enumerate(bounds)]
    return WorkoutResult(definition=d, start_date=start, finish_date=None,
                         end_date=start + timedelta(seconds=520), total_seconds=520.0,
                         segments=segs, events=[], reps_at_cap=reps_at_cap)


def test_reps_done_at_cap():
    # Pull-ups 10 + push-ups 20 + squats 30 finished by the 5:00 cap (the rest counts 0), plus reps_at_cap.
    assert reps_done_at_cap(_capped_result(0)) == 60
    assert reps_done_at_cap(_capped_result(7)) == 67
    assert reps_done_at_cap(_capped_result(None)) is None
    assert reps_done_at_cap(_capped_result(7, with_run=True)) is None
