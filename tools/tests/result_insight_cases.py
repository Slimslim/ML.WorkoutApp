"""Synthetic fixtures for the results-page insight rules (barpath/result_insights.py and
BarPathKit's ResultInsights.swift).

Every workout and every time here is invented: no tester data. The shapes follow the workouts
the rules are written for (a class AMRAP with a repeated movement, Barbara-style rounds with
rest, a 21-15-9 ladder, run + station races, an EMOM loads ladder).

Run this file to rewrite the shared JSON fixture after changing a case or a rule:
    python3 tools/tests/result_insight_cases.py
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS))

from barpath.result_insights import insights  # noqa: E402
from barpath.workout import (SegmentLoad, SegmentResult, SegmentTarget, WorkoutDefinition,  # noqa: E402
                             WorkoutEvent, WorkoutResult, WorkoutSegment)

FIXTURE = TOOLS.parent / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/result_insights_cases.json"
START = datetime(2027, 1, 15, 18, 0, tzinfo=timezone.utc)   # invented


def station(movement, name, value, unit="reps", load=None):
    return WorkoutSegment("station", movement, name, SegmentTarget(value, unit), load)


def run(meters):
    return WorkoutSegment("run", "run", "Run", SegmentTarget(meters, "meters"))


def rest(seconds):
    return WorkoutSegment("rest", "rest", "Rest", SegmentTarget(seconds, "seconds"))


def definition(id, name, fmt, segments, cap=None, round_size=None, interval=None):
    return WorkoutDefinition(id=id, name=name, short_name=name, format=fmt, team="solo",
                             time_cap_seconds=cap, health_kit_activity="crossTraining",
                             segments=segments, interval_seconds=interval, round_size=round_size)


def make_result(d, durations, finished, uid):
    """Segments back to back from START; durations[i] belongs to definition segment i. With
    finished=False the last duration is the segment cut by the cap."""
    t0 = START.timestamp()
    t = t0
    segs = []
    events = [WorkoutEvent(t0, "start", 0, None)]
    for i, dur in enumerate(durations):
        ds = d.segments[i]
        segs.append(SegmentResult(index=i, kind=ds.kind, movement=ds.movement, title=ds.title,
                                  start=t, end=t + dur, duration=float(dur)))
        t += dur
        if i + 1 < len(durations):
            events.append(WorkoutEvent(t, "advance", i + 1, "crown"))
    total = t - t0
    finish = None
    if finished:
        events.append(WorkoutEvent(t, "finish", len(durations) - 1, "crown"))
        finish = START + timedelta(seconds=total)
    return WorkoutResult(definition=d, start_date=START, finish_date=finish,
                         end_date=START + timedelta(seconds=total + 60), total_seconds=total,
                         segments=segs, events=events, id=uid)


def _uid(n):
    return f"00000000-0000-4000-8000-{n:012d}"


def amrap_bike_drift():
    d = definition("test.amrapBike", "Test AMRAP 20", "amrap",
                   [station("bike", "Bike", 15, "calories"), station("stepUps", "Step-ups", 20),
                    station("wallBalls", "Wall Balls", 20)] * 8, cap=1200, round_size=3)
    durs = [89, 60, 70, 108, 61, 71, 110, 62, 69, 111, 60, 72, 109, 62, 71, 15]
    return make_result(d, durs, False, _uid(1))


def barbara_for_time():
    rnd = [station("pullUps", "Pull-ups", 20), station("pushUps", "Push-ups", 30),
           station("sitUps", "Sit-ups", 40), station("airSquats", "Air Squats", 50), rest(180)]
    d = definition("test.barbara", "Test Barbara", "forTime", (rnd * 5)[:24], round_size=5)
    pu = [50, 55, 60, 66, 70]
    push = [45, 55, 65, 72, 80]
    sit = [75, 76, 77, 78, 76]
    sq = [70, 72, 71, 73, 72]
    durs = []
    for r in range(5):
        durs += [pu[r], push[r], sit[r], sq[r]]
        if r < 4:
            durs.append(180)
    return make_result(d, durs, True, _uid(2))


def ladder_21_15_9():
    load = SegmentLoad(95, "lb")
    segs = []
    for reps in (21, 15, 9):
        segs += [station("thrusters", "Thrusters", reps, load=load), station("pullUps", "Pull-ups", reps)]
    d = definition("test.ladder", "Test 21-15-9", "forTime", segs)
    return make_result(d, [100, 60, 75, 45, 70, 27], True, _uid(3))


def _race_definition():
    return definition("test.race", "Test Race", "forTime",
                      [run(1000), station("skiErg", "SkiErg", 1000, "meters"),
                       run(1000), station("sledPush", "Sled Push", 50, "meters"),
                       run(1000), station("row", "Row", 1000, "meters"),
                       run(1000), station("wallBalls", "Wall Balls", 100)], round_size=2)


def runs_started_hard():
    return make_result(_race_definition(), [230, 250, 262, 180, 270, 260, 258, 300], True, _uid(4))


def runs_fade_last():
    return make_result(_race_definition(), [240, 250, 245, 180, 248, 260, 262, 300], True, _uid(5))


def emom_loads():
    loads = [95, 95, 115, 115, 135, 135, 140, 140, 145, 145]
    d = definition("test.emom", "Test EMOM 10", "emom",
                   [station("powerSnatch", "Power Snatch", 2, load=SegmentLoad(v, "lb")) for v in loads],
                   interval=60)
    return make_result(d, [60] * 9, False, _uid(6))


def amrap_check_timing():
    d = definition("test.amrapDU", "Test AMRAP 12", "amrap",
                   [station("burpees", "Burpees", 10), station("doubleUnders", "Double Unders", 30),
                    station("dumbbellSnatch", "Alt. DB Snatch", 10, load=SegmentLoad(50, "lb")),
                    station("doubleUnders", "Double Unders", 30)] * 6, cap=720, round_size=4)
    durs = [40, 30, 35, 30,
            44, 31, 36, 3,      # Crown pressed twice: a 3 s segment
            46, 32, 37, 31,
            48, 31, 38, 32,
            51, 33, 39, 33,
            20]
    return make_result(d, durs, False, _uid(7))


def silence_two_steady_rounds():
    d = definition("test.twoRounds", "Test 2 rounds", "forTime",
                   [station("row", "Row", 500, "meters"), station("burpees", "Burpees", 15)] * 2)
    return make_result(d, [100, 50, 102, 51], True, _uid(8))


def silence_chipper():
    d = definition("test.chipper", "Test Chipper", "forTime",
                   [station("row", "Row", 1000, "meters"), station("wallBalls", "Wall Balls", 50),
                    station("burpees", "Burpees", 40), station("pullUps", "Pull-ups", 30)])
    return make_result(d, [240, 180, 200, 150], True, _uid(9))


def runs_mixed_distances():
    d = definition("test.mixedRuns", "Test Runs", "forTime",
                   [run(400), station("burpees", "Burpees", 10), run(800), station("burpees", "Burpees", 10),
                    run(400), station("burpees", "Burpees", 10), run(800), station("burpees", "Burpees", 10)])
    return make_result(d, [80, 30, 190, 31, 92, 32, 195, 33], True, _uid(10))


def check_outlier_chipper():
    d = definition("test.outlier", "Test Outlier", "forTime",
                   [run(400), station("skiErg", "SkiErg", 500, "meters"), run(400),
                    station("row", "Row", 500, "meters"), run(400), station("wallBalls", "Wall Balls", 30),
                    run(400), station("burpees", "Burpees", 20)])
    # Run 3 was not ended with the Crown until the wall balls were nearly done: 400 s, then 3 s.
    return make_result(d, [90, 110, 95, 105, 400, 3, 92, 80], True, _uid(11))


CASES = [
    ("amrap_bike_drift", amrap_bike_drift),
    ("barbara_for_time", barbara_for_time),
    ("ladder_21_15_9", ladder_21_15_9),
    ("runs_started_hard", runs_started_hard),
    ("runs_fade_last", runs_fade_last),
    ("emom_loads", emom_loads),
    ("amrap_check_timing", amrap_check_timing),
    ("silence_two_steady_rounds", silence_two_steady_rounds),
    ("silence_chipper", silence_chipper),
    ("runs_mixed_distances", runs_mixed_distances),
    ("check_outlier_chipper", check_outlier_chipper),
]


def build() -> list:
    out = []
    for name, make in CASES:
        r = make()
        out.append({"name": name, "result": r.to_dict(), "expected": insights(r, r.definition)})
    return out


def dump(cases: list) -> str:
    return json.dumps(cases, indent=1, ensure_ascii=False, sort_keys=True) + "\n"


if __name__ == "__main__":
    FIXTURE.write_text(dump(build()), encoding="utf-8")
    print(f"wrote {FIXTURE}")
