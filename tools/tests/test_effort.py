"""barpath/effort.py: Effort and weight lifted (BarPathKit's WorkoutEffort.swift)."""
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from barpath.effort import (day_totals, highest_heart_rate, result_effort, series_effort,
                            weight_lifted_kg, zone)
from barpath.workout import (HeartRateSeries, SegmentLoad, SegmentResult, SegmentTarget,
                             WorkoutDefinition, WorkoutResult, WorkoutSegment)

ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/effort_cases.json"
RAW = ROOT / "data/raw/2026-11-02-pcj-emom-freedom"


def result(segments, done, finished=True, series=None, partial=None,
           start=datetime(2026, 11, 3, 1, 0, tzinfo=timezone.utc)):
    definition = WorkoutDefinition(id="t", name="T", short_name="T", format="forTime", team="solo",
                                   time_cap_seconds=None, health_kit_activity="crossTraining",
                                   segments=segments)
    results = [SegmentResult(index=i, kind=k, movement="m", title="t", start=0, end=1, duration=1)
               for i, k in done]
    return WorkoutResult(definition=definition, start_date=start,
                         finish_date=start + timedelta(minutes=10) if finished else None,
                         end_date=start + timedelta(minutes=12), total_seconds=600.0,
                         segments=results, events=[], heart_rate_series=series, partial_reps=partial)


def cleans(reps=7.0, load=SegmentLoad(155, "lb")):
    return WorkoutSegment(kind="station", movement="powerCleans", name="Power Cleans",
                          target=SegmentTarget(reps, "reps"), load=load)


def test_zones():
    assert [zone(b, 200.0) for b in (99, 100, 120, 140, 160, 180, 200)] == [0, 1, 2, 3, 4, 5, 5]
    assert zone(150.0, 0.0) == 0


@pytest.mark.parametrize("case", json.loads(FIXTURE.read_text()), ids=lambda c: c["name"])
def test_parity_fixture(case):
    series = HeartRateSeries.from_dict(case["series"])
    assert series_effort(series, case["finish"], case["maxHeartRate"]) == case["effort"]


def test_real_class():
    results = [WorkoutResult.from_dict(json.loads(p.read_text())) for p in RAW.glob("workout-*.json")]
    assert highest_heart_rate(results) == 176
    assert sum(result_effort(r, 176.0) for r in results) == pytest.approx(132.25, abs=0.01)


def test_max_comes_from_the_stored_max_without_a_series():
    series = HeartRateSeries(start=0.0, interval=5.0, bpm=[150.0])
    with_series = result([], [], series=series)
    only_max = result([], [])
    only_max.heart_rate_max = 180.0
    assert highest_heart_rate([with_series, only_max]) == 180.0


def test_weight_lifted():
    r = result([cleans()], [(0, "station")])
    assert weight_lifted_kg(r) == pytest.approx(7 * 155 * 0.45359237)
    two = SegmentLoad(50, "lb", count=2)
    assert weight_lifted_kg(result([cleans(10, two)], [(0, "station")])) == pytest.approx(
        10 * 100 * 0.45359237)


def test_weight_lifted_skips_what_it_cannot_know():
    cals = WorkoutSegment(kind="station", movement="row", name="Row", target=SegmentTarget(40, "calories"),
                          load=SegmentLoad(155, "lb"))
    assert weight_lifted_kg(result([cals, cleans(load=None)], [(0, "station"), (1, "station")])) == 0
    assert weight_lifted_kg(result([], [])) == 0


def test_weight_lifted_unfinished_and_wrapped():
    r = result([cleans()], [(0, "station"), (1, "station")], finished=False, partial=3)
    assert weight_lifted_kg(r) == pytest.approx((7 + 3) * 155 * 0.45359237)


def test_days_group_by_local_day_and_keep_missing_heart_rate():
    hr = HeartRateSeries(start=datetime(2026, 11, 3, 1, 0, tzinfo=timezone.utc).timestamp(),
                         interval=60.0, bpm=[200.0, 200.0])
    tz = timezone(timedelta(hours=-8))
    days = day_totals([result([], [], series=hr),
                       result([], [], start=datetime(2026, 11, 3, 2, 0, tzinfo=timezone.utc)),
                       result([], [], start=datetime(2026, 11, 3, 20, 0, tzinfo=timezone.utc))], tz)
    assert [d["day"] for d in days] == ["2026-11-02", "2026-11-03"]
    assert days[0]["effort"] == 10.0
    assert days[0]["minutes"] == 20.0
    assert days[1]["effort"] is None
