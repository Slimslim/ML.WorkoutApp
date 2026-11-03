import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

from barpath.workout import (
    PedometerSample, SegmentTarget, TimedValue, WorkoutLibrary, WorkoutProgress, WorkoutResult,
    WorkoutSegment, WorkoutDefinition, Movement, load_workout_csv, split_stats)

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import workout_report  # noqa: E402


def golden_progress():
    p = WorkoutProgress(WorkoutLibrary.quickTest)
    p.start(1000)
    assert p.advance(1060, "crown")
    assert p.advance(1100, "crown")
    assert p.undo(1105, "button")
    assert p.advance(1110, "crown")
    assert p.advance(1170, "crown")
    assert p.advance(1200, "crown")
    return p


def golden_hr():
    return [TimedValue(1000 + 10 * i, 100 + i) for i in range(21)]


GOLDEN_PED = [PedometerSample(1030, 90, 100), PedometerSample(1060, 180, 200),
              PedometerSample(1200, 400, 500)]


def test_library():
    assert len(WorkoutLibrary.all) == 9
    assert [d.id for d in WorkoutLibrary.all] == [
        "hyrox.solo", "hyrox.doubles", "hyrox.half", "partner.wod1", "partner.wod2", "wod.amrap40",
        "wod.helen", "wod.rowThrusters", "free.workout"]
    assert len({d.id for d in WorkoutLibrary.all}) == 9
    assert len(WorkoutLibrary.helen.segments) == 9 and WorkoutLibrary.helen.run_count == 3
    assert WorkoutLibrary.helen.segments[1].title == "KB Swings 21"
    assert len(WorkoutLibrary.rowThrusters.segments) == 17
    assert WorkoutLibrary.rowThrusters.segments[0].title == "Row 15 cal"
    assert WorkoutLibrary.rowThrusters.segments[2].title == "Rest"
    assert len(WorkoutLibrary.amrap20.segments) == 40
    free = WorkoutLibrary.free
    assert len(free.segments) == 60 and free.segments[0].title == "Part 1" and free.time_cap_seconds is None
    assert WorkoutLibrary.definition("wod.nightmareAmrap") is WorkoutLibrary.amrap20
    a40 = WorkoutLibrary.amrap40
    assert len(a40.segments) == 60 and a40.round_size == 5 and a40.time_cap_seconds == 2400
    assert a40.segments[0].title == "Row / Bike 12 cal"
    assert a40.segments[4].kind == "rest" and a40.segments[4].target.value == 60
    solo = WorkoutLibrary.hyroxSolo
    assert len(solo.segments) == 16 and solo.run_count == 8 and solo.station_count == 8
    assert [s.kind for s in solo.segments] == ["run", "station"] * 8
    assert solo.segments[-1].title == "Wall Balls 100"
    assert solo.segments[1].title == "SkiErg 1000 m"
    assert solo.segments[0].title == "Run 1000 m"
    assert len(WorkoutLibrary.partnerWod1.segments) == 10
    assert len(WorkoutLibrary.partnerWod2.segments) == 5
    assert all(s.kind == "station" for s in WorkoutLibrary.partnerWod2.segments)
    assert WorkoutLibrary.halfHyrox.segments[0].title == "Run 500 m"
    assert WorkoutLibrary.definition("partner.wod1") is WorkoutLibrary.partnerWod1
    assert WorkoutLibrary.definition("nope") is None


def test_target_text_and_title():
    assert SegmentTarget(1000, "meters").text == "1000 m"
    assert SegmentTarget(100, "reps").text == "100 reps"
    assert SegmentTarget(20, "calories").text == "20 cal"
    assert SegmentTarget(120, "seconds").text == "2:00"
    assert WorkoutSegment("rest", "rest", "Rest", None).title == "Rest"


def test_golden_splits_and_events():
    p = golden_progress()
    assert p.is_finished and p.finish_time == 1200
    sp = p.splits(5000)
    assert [(s.start, s.end, s.duration) for s in sp] == [
        (1000, 1060, 60), (1060, 1110, 50), (1110, 1170, 60), (1170, 1200, 30)]
    assert p.total_elapsed(5000) == 200
    assert [e.kind for e in p.events] == ["start", "advance", "advance", "undo", "advance", "advance", "finish"]
    assert [e.segment_index for e in p.events] == [0, 1, 2, 1, 2, 3, 3]


def test_golden_stats():
    r = split_stats(golden_progress(), 1300, golden_hr(), GOLDEN_PED)
    assert len(r) == 4
    assert r[0].heart_rate_avg == pytest.approx(102.5)
    assert r[0].heart_rate_max == pytest.approx(105)
    assert r[0].steps == pytest.approx(180)
    assert r[0].distance == pytest.approx(200)
    assert r[0].cadence == pytest.approx(180)
    assert r[0].pace_seconds_per_km == pytest.approx(300)
    assert r[1].pace_seconds_per_km is None
    assert r[3].heart_rate_max == pytest.approx(119)
    empty = split_stats(golden_progress(), 1300, [], [])
    assert empty[0].heart_rate_avg is None and empty[0].steps is None and empty[0].pace_seconds_per_km is None


def test_edge_cases():
    p = WorkoutProgress(WorkoutLibrary.quickTest)
    assert not p.undo(1, "button") and not p.advance(1, "crown")
    assert p.segment_elapsed(10) == 0 and p.current_segment is None
    p.start(1000)
    p.start(2000)
    assert p.start_time == 1000 and len(p.events) == 1
    assert not p.undo(1001, "button")
    assert p.current_segment.title == "Run 200 m" and p.next_segment.title == "Air Squats 20"
    assert not p.advance(999, "crown")
    g = golden_progress()
    assert not g.advance(1300, "crown") and len(g.events) == 7
    assert g.undo(1210, "button") and not g.is_finished
    assert g.events[-1].kind == "unfinish" and g.events[-1].segment_index == 3
    assert g.segment_elapsed(1250) == 80
    assert g.advance(1260, "press") and g.finish_time == 1260


def test_result_json_roundtrip(tmp_path):
    p = golden_progress()
    segs = split_stats(p, 1300, golden_hr(), GOLDEN_PED)
    start = datetime(2026, 10, 31, 9, 0, 0, tzinfo=timezone.utc)
    res = WorkoutResult(WorkoutLibrary.quickTest, start, start, start, 200.0, segs, p.events,
                        110.0, 120.0, "session-x.csv", id="ABC")
    path = tmp_path / "workout-abc.json"
    res.save(path)
    back = WorkoutResult.load(path)
    assert back == res
    assert back.run_seconds == 120 and back.station_seconds == 80
    assert "Quick Test" in workout_report.report(path)


CSV_HEADER = ("# barpath-session v1, sessionId=abc, startDate=2026-10-31T09:00:00Z, workout=quickTest\n"
              "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n")


def write_csv(path):
    lines = [CSV_HEADER.replace("workout=quickTest", "workout=quick.test")]
    lines.append("# event t=0.0 name=segment index=0 kind=run source=start\n")
    for i in range(0, 201, 10):
        lines.append(f"# event t={float(i)} name=hr bpm={100 + i / 10}\n")
    lines.append("# event t=30 name=pedometer steps=90 distance=100 cadence=-1 pace=-1\n")
    lines.append("# event t=60 name=pedometer steps=180 distance=200 cadence=-1 pace=-1\n")
    lines.append("# event t=60 name=segment index=1 kind=station source=crown\n")
    lines.append("# event t=100 name=segment index=2 kind=run source=crown\n")
    lines.append("# event t=105 name=undo index=1 source=button\n")
    lines.append("# event t=110 name=segment index=2 kind=run source=crown\n")
    lines.append("# event t=170 name=segment index=3 kind=station source=crown\n")
    lines.append("# event t=200 name=finish index=3 source=crown\n")
    lines.append("# event t=200 name=pedometer steps=400 distance=-1 cadence=-1 pace=-1\n")
    lines.append("# mark t=50 n=1 label=mark\n")
    for i in range(0, 2001, 10):
        lines.append(f"{i / 10:.3f}," + ",".join(["0"] * 13) + "\n")
    Path(path).write_text("".join(lines))


def test_load_workout_csv(tmp_path):
    path = tmp_path / "session-abc.csv"
    write_csv(path)
    w = load_workout_csv(path)
    assert w.workout_id == "quick.test" and w.session_id == "abc"
    assert w.definition is WorkoutLibrary.quickTest
    assert [b["name"] for b in w.boundaries] == [
        "segment", "segment", "segment", "undo", "segment", "segment", "finish"]
    assert len(w.heart_rates) == 21
    assert [p.distance for p in w.pedometer] == [100, 200, None]
    assert len(w.marks) == 1
    p = w.progress
    assert p.is_finished and p.segment_starts == [0, 60, 110, 170] and p.finish_time == 200
    segs = split_stats(p, w.end_time, w.heart_rates, w.pedometer)
    assert [s.duration for s in segs] == [60, 50, 60, 30]
    assert segs[0].heart_rate_avg == pytest.approx(102.5)
    assert segs[0].pace_seconds_per_km == pytest.approx(300)
    assert segs[0].cadence == pytest.approx(180)
    out = workout_report.report(path)
    assert "Run 200 m" in out and "Total 3:20" in out


def test_csv_without_lift_type_header_is_tolerated(tmp_path):
    path = tmp_path / "s.csv"
    path.write_text(CSV_HEADER + "0.0," + ",".join(["0"] * 13) + "\n")
    w = load_workout_csv(path)
    assert w.workout_id == "quickTest" and w.definition is WorkoutLibrary.quickTest
    assert not w.progress.is_started


def test_interval_rest_ends_on_the_clock():
    p = WorkoutProgress(WorkoutLibrary.rowThrusters)
    p.start(1000)
    assert p.auto_advance_time() == 1180          # rowing: the set ends on the clock too (2026-11-03)
    p.advance(1060, "crown")                       # thrusters
    assert p.auto_advance_time() == 1180
    p.advance(1100, "crown")                       # rest from 1:40
    assert p.auto_advance_time() == 1180          # next set at 3:00
    p.advance(1180, "auto")                        # set 2 row
    p.advance(1250, "crown")
    p.advance(1370, "crown")                       # rest starts late (6:10): next boundary 9:00
    assert p.auto_advance_time() == 1540


def test_fixed_rest_and_amrap_cap():
    from barpath.workout import WorkoutDefinition, WorkoutSegment, SegmentTarget
    d = WorkoutDefinition("t.rest", "Rest test", "Rest", "forTime", "solo", None, "crossTraining",
                          [WorkoutSegment("station", "burpees", "Burpees", SegmentTarget(10, "reps")),
                           WorkoutSegment("rest", "rest", "Rest", SegmentTarget(60, "seconds")),
                           WorkoutSegment("station", "burpees", "Burpees", SegmentTarget(10, "reps"))])
    p = WorkoutProgress(d)
    p.start(0)
    p.advance(42, "crown")
    assert p.auto_advance_time() == 102
    assert p.cap_time is None
    a = WorkoutProgress(WorkoutLibrary.amrap20)
    a.start(500)
    assert a.cap_time == 1700
    assert a.finish(1700, "auto") and a.is_finished
    assert a.events[-1].kind == "finish"


def test_round_sizes_and_heart_rate_series(tmp_path):
    from barpath.workout import HeartRateSeries, RESULT_VERSION
    assert WorkoutLibrary.helen.round_size == 3
    assert WorkoutLibrary.rowThrusters.round_size == 3
    assert WorkoutLibrary.amrap20.round_size == 4
    assert WorkoutLibrary.hyroxSolo.round_size == 2 and WorkoutLibrary.partnerWod1.round_size == 2
    assert WorkoutLibrary.partnerWod2.round_size is None
    d = WorkoutLibrary.helen.to_dict()
    assert d["roundSize"] == 3
    assert type(WorkoutLibrary.helen).from_dict(d) == WorkoutLibrary.helen
    # Same cases as WorkoutSummaryTests.testHeartRateSeriesBucketsAndGaps.
    samples = [TimedValue(12, 120), TimedValue(0, 100), TimedValue(1, 110), TimedValue(40, 130),
               TimedValue(-3, 999), TimedValue(100, 999)]
    s = HeartRateSeries.make(samples, 0, 80)
    assert s.bpm == [105, 115.9, 120, 120, 120, 130, 130, 130, 130, 130, 130, None, None, None, None, None]
    assert s.value_at(2) == 105 and s.value_at(56) is None and s.value_at(80) is None
    assert HeartRateSeries.make([TimedValue(10, 90)], 0, 10, max_gap=0).bpm == [None, 90]
    # Version 2 round trip with nulls and heartRateMin.
    p = golden_progress()
    segs = split_stats(p, 1300, golden_hr(), GOLDEN_PED)
    assert segs[0].heart_rate_min == pytest.approx(100)
    start = datetime(2026, 10, 31, 9, 0, 0, tzinfo=timezone.utc)
    series = HeartRateSeries(1000.0, 5.0, [100.0, None, 102.5])
    res = WorkoutResult(WorkoutLibrary.quickTest, start, start, start, 200.0, segs, p.events,
                        110.0, 120.0, None, id="ABC", heart_rate_series=series)
    assert res.version == RESULT_VERSION == 2
    path = tmp_path / "workout-v2.json"
    res.save(path)
    assert '"heartRateMin"' in path.read_text() and "null" in path.read_text()
    back = WorkoutResult.load(path)
    assert back == res and back.heart_rate_series.bpm[1] is None
    # Version 1 file (no new fields) still loads.
    d1 = res.to_dict()
    d1["version"] = 1
    del d1["heartRateSeries"]
    v1 = WorkoutResult.from_dict(d1)
    assert v1.version == 1 and v1.heart_rate_series is None


# ---- §5 result corrections and partial reps (same cases as WorkoutResultEditingTests.swift) ----

AMRAP_FIXTURE = "workout-amrap-2026-10-30.json"
EDIT_NOW = datetime(2026, 10, 31, 12, 0, 0, tzinfo=timezone.utc)


def load_amrap(fixtures_dir):
    return WorkoutResult.load(fixtures_dir / AMRAP_FIXTURE)


def test_amrap_fixture_loads_without_new_fields(fixtures_dir):
    r = load_amrap(fixtures_dir)
    assert r.version == 2 and r.partial_reps is None and r.edited_at is None
    assert len(r.segments) == 24 and r.heart_rate_series is not None
    assert r.partial_reps_limit == 31          # last segment: Double Unders 31


def test_move_segment_start_fixes_the_round4_mixup(fixtures_dir):
    r = load_amrap(fixtures_dir)
    s0 = r.segments[0].start
    total_before = r.total_seconds
    steps_before = sum(s.steps for s in r.segments[11:14])
    dist_before = sum(s.distance for s in r.segments[11:14])
    untouched = [s.to_dict() for s in r.segments[:11] + r.segments[14:]]
    assert r.move_segment_start(12, s0 + 556.94, EDIT_NOW)
    assert r.move_segment_start(13, s0 + 619.32, EDIT_NOW)
    seg11, seg12, seg13 = r.segments[11], r.segments[12], r.segments[13]
    # Real round 4 from the README: burpees 556.9-619.3, DUs 619.3-700.1.
    assert seg11.duration == pytest.approx(556.94 - (seg11.start - s0), abs=1e-6)
    assert seg11.duration == pytest.approx(60.16783, abs=1e-4)
    assert seg12.duration == pytest.approx(62.38, abs=1e-4)
    assert seg13.duration == pytest.approx(80.75398, abs=1e-4)
    assert seg11.end == seg12.start and seg12.end == seg13.start
    assert seg13.end - s0 == pytest.approx(700.07398, abs=1e-4)
    # HR recomputed from the 5 s series.
    assert seg11.heart_rate_avg == pytest.approx(169.16666666666666, abs=1e-9)
    assert (seg11.heart_rate_max, seg11.heart_rate_min) == (173.0, 167.0)
    assert seg12.heart_rate_avg == pytest.approx(163.15384615384616, abs=1e-9)
    assert (seg12.heart_rate_max, seg12.heart_rate_min) == (168.0, 161.0)
    assert seg13.heart_rate_avg == pytest.approx(160.8125, abs=1e-9)
    assert (seg13.heart_rate_max, seg13.heart_rate_min) == (163.0, 157.0)
    # Steps/distance conserved, shared by time; cadence recomputed; no pace for stations.
    assert sum(s.steps for s in r.segments[11:14]) == pytest.approx(steps_before, abs=1e-9)
    assert sum(s.distance for s in r.segments[11:14]) == pytest.approx(dist_before, abs=1e-9)
    assert seg12.cadence == pytest.approx(seg12.steps / seg12.duration * 60, abs=1e-9)
    assert seg12.pace_seconds_per_km is None
    # Nothing else changes.
    assert r.total_seconds == total_before
    assert [s.to_dict() for s in r.segments[:11] + r.segments[14:]] == untouched
    assert r.edited_at == EDIT_NOW


def test_move_segment_start_clamps_and_rejects(fixtures_dir):
    r = load_amrap(fixtures_dir)
    a, b = r.segments[4], r.segments[5]
    assert r.move_segment_start(5, a.start - 100, EDIT_NOW)
    assert r.segments[5].start == pytest.approx(a.start + 1, abs=1e-9)
    assert r.segments[4].duration == pytest.approx(1, abs=1e-9)
    end5 = r.segments[5].end
    assert r.move_segment_start(5, end5 + 100, EDIT_NOW)
    assert r.segments[5].start == pytest.approx(end5 - 1, abs=1e-9)
    assert r.segments[5].duration == pytest.approx(1, abs=1e-9)
    before = [s.to_dict() for s in r.segments]
    fresh = load_amrap(fixtures_dir)
    for bad in (0, -1, 24, 99):
        assert not fresh.move_segment_start(bad, fresh.segments[0].start + 10, EDIT_NOW)
    assert fresh.edited_at is None
    assert not r.move_segment_start(3, float("nan"), EDIT_NOW)
    assert [s.to_dict() for s in r.segments] == before


def test_set_partial_reps_and_roundtrip(fixtures_dir, tmp_path):
    r = load_amrap(fixtures_dir)
    r.set_partial_reps(99, EDIT_NOW)
    assert r.partial_reps == 31
    r.set_partial_reps(-4, EDIT_NOW)
    assert r.partial_reps == 0
    r.set_partial_reps(None, EDIT_NOW)
    assert r.partial_reps is None and r.edited_at == EDIT_NOW
    r.set_partial_reps(13, EDIT_NOW)
    assert r.partial_reps == 13
    path = tmp_path / "workout-edited.json"
    r.save(path)
    raw = json.loads(path.read_text())
    assert raw["partialReps"] == 13 and raw["editedAt"] == "2026-10-31T12:00:00Z"
    back = WorkoutResult.load(path)
    assert back.partial_reps == 13 and back.edited_at == EDIT_NOW
    # Swift writes fractional seconds; both forms load.
    raw["editedAt"] = "2026-10-31T12:00:00.250Z"
    assert WorkoutResult.from_dict(raw).edited_at.microsecond == 250000
    # Without a reps target only the lower bound applies.
    q = WorkoutResult(WorkoutLibrary.quickTest, EDIT_NOW, None, EDIT_NOW, 60.0,
                      split_stats(golden_progress(), 1300, [], [])[:1], [])
    assert q.partial_reps_limit is None
    q.set_partial_reps(500, EDIT_NOW)
    assert q.partial_reps == 500


def test_csv_partial_reps_event(tmp_path):
    path = tmp_path / "session-pr.csv"
    write_csv(path)
    text = path.read_text().replace("# mark t=50 n=1 label=mark\n",
                                    "# mark t=50 n=1 label=mark\n"
                                    "# event t=205 name=partialReps reps=9\n"
                                    "# event t=207 name=partialReps reps=13\n")
    path.write_text(text)
    assert load_workout_csv(path).partial_reps == 13


def test_segment_load_round_trip():
    w = WorkoutLibrary.partnerWod1
    dp = w.segments[-1]
    assert dp.load is not None and dp.load.count == 2 and abs(dp.load.kilograms - 36.287) < 0.01
    from barpath.workout import WorkoutDefinition
    back = WorkoutDefinition.from_dict(w.to_dict())
    assert back.segments[-1].load == dp.load
    assert back.segments[0].load is None


# ---- heart-rate recovery after the finish (WORKOUT_SPEC §6; same cases as HeartRateRecoveryTests.swift) ----

# Partner WOD 1, 2026-10-31: the watch's HR samples from 1374.7 s to End (seconds since the start,
# rounded to 0.1 s). Finish at 1389.3 s, End at 1610.5 s.
REAL_TAIL = [
    (1374.7, 159), (1380.2, 159), (1384.7, 161), (1390.3, 162), (1394.7, 161), (1399.7, 160),
    (1404.7, 162), (1409.7, 160), (1414.7, 155), (1419.8, 154), (1424.7, 151), (1430.2, 151),
    (1434.8, 150), (1439.8, 150), (1444.7, 147), (1450.2, 143), (1454.7, 142), (1459.7, 142),
    (1464.7, 139), (1469.7, 138), (1474.8, 136), (1479.8, 132), (1484.7, 129), (1490.3, 125),
    (1494.7, 124), (1500.2, 124), (1505.4, 123), (1510.2, 123), (1514.8, 122), (1520.3, 115),
    (1524.8, 113), (1529.7, 112), (1534.8, 115), (1540.3, 117), (1544.8, 117), (1550.2, 109),
    (1554.7, 107), (1559.7, 104), (1564.7, 101), (1570.2, 107), (1574.8, 114), (1579.8, 119),
    (1585.3, 107), (1589.7, 105), (1594.7, 104), (1599.8, 104), (1605.3, 114), (1609.8, 113)]
REAL_FINISH = 1389.3
REAL_END = 1610.5
REAL_DIR = Path(__file__).resolve().parents[2] / "data" / "raw" / "2026-10-31-partner-wod1"
REAL_ID = "594E886E-2EB8-4D80-8987-D8E9B4228A48"


def real_tail_series(end=REAL_END):
    from barpath.workout import HeartRateSeries
    return HeartRateSeries.make([TimedValue(t, v) for t, v in REAL_TAIL], 0.0, end)


def test_recovery_from_real_tail():
    from barpath.workout import HeartRateRecovery
    rec = HeartRateRecovery.make(real_tail_series(), REAL_FINISH, REAL_END)
    assert rec is not None
    assert rec.heart_rate_at_finish == 161.5          # buckets 1380-1390: 160, 161.5
    assert rec.covered_seconds == pytest.approx(221.2, abs=1e-9)
    assert [m.seconds for m in rec.marks] == [60, 120, 180]
    assert [m.minutes for m in rec.marks] == [1, 2, 3]
    assert rec.mark(1).heart_rate == pytest.approx((147 + 145 + 142.5) / 3, abs=1e-9)
    assert rec.mark(2).heart_rate == pytest.approx((124 + 123 + 122.5) / 3, abs=1e-9)
    assert rec.mark(3).heart_rate == pytest.approx((101 + 104.1 + 110.5) / 3, abs=1e-9)
    assert rec.drop1 == pytest.approx(161.5 - 144.8333333, abs=1e-6)
    assert rec.drop2 == pytest.approx(161.5 - 123.1666667, abs=1e-6)
    assert rec.drop3 == pytest.approx(161.5 - 105.2, abs=1e-6)


def test_recovery_needs_a_minute_and_reports_only_covered_marks():
    from barpath.workout import HeartRateRecovery, HeartRateSeries
    # Ended 59 s after the finish: nothing.
    assert HeartRateRecovery.make(real_tail_series(), REAL_FINISH, REAL_FINISH + 59) is None
    # Series stops at the finish (files before 2026-11-01), End later: nothing.
    assert HeartRateRecovery.make(real_tail_series(REAL_FINISH), REAL_FINISH, REAL_END) is None
    # 90 s after the finish: only the 1-minute mark.
    rec = HeartRateRecovery.make(real_tail_series(REAL_FINISH + 90), REAL_FINISH, REAL_FINISH + 90)
    assert rec is not None and [m.minutes for m in rec.marks] == [1]
    assert rec.drop2 is None and rec.drop3 is None
    # No HR around the finish: nothing.
    gap = HeartRateSeries(0.0, 5.0, [None] * 30 + [120.0] * 30)
    assert HeartRateRecovery.make(gap, 140.0, 300.0) is None
    # A gap at +60 s but values at +120 s: the 2-minute mark alone.
    s = HeartRateSeries(0.0, 5.0, [150.0] * 4 + [None] * 20 + [110.0] * 30)
    rec = HeartRateRecovery.make(s, 20.0, 270.0)
    assert [m.minutes for m in rec.marks] == [2, 3] and rec.drop2 == 40.0


def test_result_recovery_and_old_files(fixtures_dir):
    from barpath.workout import HeartRateSeries
    # The AMRAP fixture's series stops at the finish: no recovery.
    assert load_amrap(fixtures_dir).heart_rate_recovery is None
    start = datetime.fromtimestamp(1_800_000_000, tz=timezone.utc)
    series = real_tail_series()
    shifted = HeartRateSeries(series.start + 1_800_000_000, series.interval, series.bpm)
    fin = datetime.fromtimestamp(1_800_000_000 + REAL_FINISH, tz=timezone.utc)
    end = datetime.fromtimestamp(1_800_000_000 + REAL_END, tz=timezone.utc)
    r = WorkoutResult(WorkoutLibrary.quickTest, start, fin, end, REAL_FINISH, [], [],
                      heart_rate_series=shifted)
    assert r.heart_rate_recovery.heart_rate_at_finish == 161.5
    assert not r.needs_heart_rate_backfill
    r.finish_date = None  # ended without finishing
    assert r.heart_rate_recovery is None


def test_session_csv_heart_rates():
    from barpath.workout import session_csv_heart_rates
    text = ("# barpath-session v1, sessionId=X, startDate=2026-10-31T16:36:02.684Z, workout=partner.wod1\n"
            "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n"
            "# event t=-0.015398 name=segment index=0 kind=run source=start\n"
            "0.0,1,0,0,0,0,0,0,0,0,-1,0,0,0\n"
            "# event t=29.845809 name=hr bpm=108\n"
            "# event t=30.1 name=pedometer steps=2 distance=0.5 cadence=-1.0 pace=-1.0\n"
            "# mark t=31 n=1 label=mark\n"
            "# event t=1390.279843 name=hr bpm=162\n")
    hr = session_csv_heart_rates(text.splitlines())
    origin = datetime(2026, 10, 31, 16, 36, 2, 684000, tzinfo=timezone.utc).timestamp()
    assert [(round(h.t - origin, 6), h.value) for h in hr] == [(29.845809, 108.0), (1390.279843, 162.0)]
    assert session_csv_heart_rates(text.splitlines()[1:]) == []   # no header startDate


@pytest.mark.skipif(not (REAL_DIR / f"session-{REAL_ID}.csv").exists(), reason="real 2026-10-31 data missing")
def test_backfill_real_partner_wod1(tmp_path):
    from barpath.workout import session_csv_heart_rates
    r = WorkoutResult.load(REAL_DIR / f"workout-{REAL_ID}.json")
    before = list(r.heart_rate_series.bpm)
    assert len(before) == 278 and r.needs_heart_rate_backfill and r.heart_rate_recovery is None
    with open(REAL_DIR / f"session-{REAL_ID}.csv") as f:
        hr = session_csv_heart_rates(f)
    assert len(hr) == 311
    # CSV t is seconds since the CSV header's startDate: the finish event lands on finishDate.
    assert r.backfill_heart_rate(hr)
    assert r.heart_rate_series.bpm[:278] == before            # the watch's buckets are kept
    assert len(r.heart_rate_series.bpm) == 323 and not r.needs_heart_rate_backfill
    assert r.edited_at is None
    rec = r.heart_rate_recovery
    assert rec is not None and rec.covered_seconds == pytest.approx(221.19, abs=0.01)
    # Athlete's reading of the raw samples: 162 -> 143 -> 123 -> 107. With the 5 s grid and the
    # +-7.5 s mean: 161 -> 145 -> 123 -> 105 (drops 16 / 38 / 56).
    assert rec.heart_rate_at_finish == 161.0
    assert [round(m.heart_rate) for m in rec.marks] == [145, 123, 105]
    assert [round(m.drop) for m in rec.marks] == [16, 38, 56]
    assert not r.backfill_heart_rate(hr)                       # once only
    path = tmp_path / "backfilled.json"
    r.save(path)
    back = WorkoutResult.load(path)
    assert back.heart_rate_series == r.heart_rate_series
    assert [round(m.heart_rate) for m in back.heart_rate_recovery.marks] == [145, 123, 105]


# ---- recovery tail on the overview timeline (WorkoutSummaryTimeline.swift RecoveryTail; same cases
# as HeartRateRecoveryTests.swift testRecoveryTail*) ----

def real_tail_result(end=REAL_END, finished=True):
    """Partner WOD 1 shape: 4 quick-test segments from 0 to the finish (1389.3 s), the real HR tail,
    End at `end`; all shifted to 1_800_000_000."""
    from barpath.workout import HeartRateSeries, SegmentResult
    t0 = 1_800_000_000
    q = REAL_FINISH / 4
    kinds = ["run", "station", "run", "station"]
    segs = [SegmentResult(i, kinds[i], kinds[i], f"S{i}", t0 + i * q, t0 + (i + 1) * q, q) for i in range(4)]
    series = real_tail_series(end)
    shifted = HeartRateSeries(series.start + t0, series.interval, series.bpm)
    start = datetime.fromtimestamp(t0, tz=timezone.utc)
    fin = datetime.fromtimestamp(t0 + REAL_FINISH, tz=timezone.utc) if finished else None
    return WorkoutResult(WorkoutLibrary.quickTest, start, fin, datetime.fromtimestamp(t0 + end, tz=timezone.utc),
                         REAL_FINISH, segs, [], heart_rate_series=shifted)


def test_recovery_tail_from_real_shape():
    r = real_tail_result()
    assert r.summary_origin == 1_800_000_000 and r.summary_duration == pytest.approx(REAL_FINISH, abs=1e-6)
    tail = r.recovery_tail
    assert tail is not None
    assert tail.start == pytest.approx(REAL_FINISH, abs=1e-6)
    assert tail.end == pytest.approx(REAL_END, abs=1e-6)
    assert tail.interval == 5.0 and len(tail.heart_rate) == 45          # ceil(221.2 / 5)
    assert tail.heart_rate[:4] == [161.5, 160.0, 162.0, 160.0]
    assert tail.heart_rate[-1] == 113.5
    assert tail.heart_rate_low == 101.0 and tail.heart_rate_high == 162.0
    assert tail.heart_rate_at_finish == 161.5
    assert [m.minutes for m in tail.marks] == [1, 2, 3]
    assert tail.time_of_mark(tail.marks[0]) == pytest.approx(REAL_FINISH + 60, abs=1e-6)
    assert tail.time_of_sample(0) == pytest.approx(REAL_FINISH + 2.5, abs=1e-6)
    assert tail.time_of_sample(44) == pytest.approx(REAL_FINISH + 220.6, abs=1e-6)  # last bucket cut at End
    # The chip at +1:23: 136 bpm, -25.5 since the finish.
    m = tail.moment(REAL_FINISH + 83)
    assert m.seconds_after_finish == pytest.approx(83, abs=1e-6)
    assert m.heart_rate == 136.0 and m.change == pytest.approx(-25.5, abs=1e-9)
    assert tail.moment(REAL_FINISH - 1) is None and tail.moment(REAL_END + 1) is None
    assert tail.heart_rate_at(REAL_FINISH - 1) is None
    assert tail.heart_rate_at(REAL_END + 50) == 113.5                     # clamped to the last value


def test_recovery_tail_only_with_a_recovery(fixtures_dir):
    assert load_amrap(fixtures_dir).recovery_tail is None                 # series stops at the finish
    assert real_tail_result(end=REAL_FINISH + 59).recovery_tail is None   # End within a minute
    assert real_tail_result(finished=False).recovery_tail is None         # ended without finishing
    short = real_tail_result(end=REAL_FINISH + 90).recovery_tail          # 90 s: one mark, 18 values
    assert short is not None and [m.minutes for m in short.marks] == [1] and len(short.heart_rate) == 18


@pytest.mark.skipif(not (REAL_DIR / f"session-{REAL_ID}.csv").exists(), reason="real 2026-10-31 data missing")
def test_recovery_tail_real_partner_wod1_after_backfill():
    from barpath.workout import session_csv_heart_rates
    r = WorkoutResult.load(REAL_DIR / f"workout-{REAL_ID}.json")
    assert r.recovery_tail is None                                        # as recorded: series ends at the finish
    with open(REAL_DIR / f"session-{REAL_ID}.csv") as f:
        assert r.backfill_heart_rate(session_csv_heart_rates(f))
    tail = r.recovery_tail
    assert tail.start == pytest.approx(r.summary_duration, abs=1e-9) == pytest.approx(1389.35, abs=0.01)
    assert tail.duration == pytest.approx(221.19, abs=0.01) and len(tail.heart_rate) == 45
    assert tail.heart_rate_at_finish == 161.0
    assert [round(m.heart_rate) for m in tail.marks] == [145, 123, 105]
    assert tail.heart_rate_low == 101.0 and tail.heart_rate_high == 162.0
    assert tail.moment(tail.start + 83).change == -25.0


# ---- interval workouts: the clock moves on even if the Crown was not turned (2026-11-03) ----

def _emom(sets=3, interval=60.0):
    work = WorkoutSegment("station", "powerCleanAndJerk", "Power C&J", SegmentTarget(2, "reps"))
    rest = WorkoutSegment("rest", Movement.rest, "Rest", None)
    segs = ([work, rest] * sets)[:-1]
    return WorkoutDefinition("t.emom", "EMOM", "EMOM", "emom", "solo", sets * interval, "crossTraining",
                             segs, interval_seconds=interval, round_size=2)


def test_emom_work_segment_ends_on_the_minute_without_crown():
    p = WorkoutProgress(_emom())
    p.start(1000.0)
    assert p.auto_advance_time() == 1060.0          # work segment: next minute mark
    assert p.auto_advance(1060.0)
    assert p.current_index == 2                     # skipped the rest straight to set 2
    sp = p.splits(1060.0)
    assert sp[1].duration == 0.0 and sp[2].start == 1060.0
    assert p.auto_advance_time() == 1120.0


def test_emom_crown_after_reps_starts_rest_until_the_minute():
    p = WorkoutProgress(_emom())
    p.start(1000.0)
    p.advance(1018.0, "crown")                      # set done after 18 s
    assert p.current_segment.kind == "rest"
    assert p.auto_advance_time() == 1060.0
    p.auto_advance(1060.0)
    assert p.current_index == 2 and p.segment_starts[-1] == 1060.0


def test_emom_last_set_finishes_on_the_last_minute():
    p = WorkoutProgress(_emom(sets=2))
    p.start(1000.0)
    p.auto_advance(1060.0)
    assert p.current_index == 2
    assert p.auto_advance_time() == 1120.0
    p.auto_advance(1120.0)
    assert p.is_finished and p.finish_time == 1120.0


def test_interval_with_two_movements_jumps_to_next_set():
    row = WorkoutSegment("station", Movement.row, "Row", SegmentTarget(15, "calories"))
    thr = WorkoutSegment("station", Movement.thrusters, "Thrusters", SegmentTarget(12, "reps"))
    rest = WorkoutSegment("rest", Movement.rest, "Rest", None)
    d = WorkoutDefinition("t.e3", "E3", "E3", "emom", "solo", 540.0, "crossTraining",
                          ([row, thr, rest] * 3)[:-1], interval_seconds=180.0, round_size=3)
    p = WorkoutProgress(d)
    p.start(0.0)
    assert p.auto_advance_time() == 180.0           # still rowing at 3:00
    p.auto_advance(180.0)
    assert p.current_index == 3 and p.current_segment.movement == Movement.row


def test_non_interval_work_segments_never_auto_advance():
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(0.0)
    assert p.auto_advance_time() is None
    assert p.auto_advance_target_index() == 1


# ---- for-time cap (WORKOUT_SPEC §5b, W7; same cases as WorkoutCapTests.swift) ----

HELEN_T0 = 1_800_000_000.0


def helen_progress(finish_offset):
    """Helen (16:00 cap), 9 segments of 110 s each from t0, finishing at t0 + finish_offset
    (the last segment ends there)."""
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(HELEN_T0)
    for i in range(1, 9):
        assert p.advance(HELEN_T0 + 110 * i, "crown")
    assert p.advance(HELEN_T0 + finish_offset, "crown")
    return p


def helen_result(finish_offset):
    p = helen_progress(finish_offset)
    start = datetime.fromtimestamp(HELEN_T0, timezone.utc)
    fin = datetime.fromtimestamp(HELEN_T0 + finish_offset, timezone.utc)
    return WorkoutResult(WorkoutLibrary.helen, start, fin, fin, float(finish_offset),
                         split_stats(p, HELEN_T0 + finish_offset, [], []), list(p.events))


def test_for_time_cap_time_only_for_time():
    p = WorkoutProgress(WorkoutLibrary.helen)
    assert p.for_time_cap_time is None                    # not started
    p.start(HELEN_T0)
    assert p.for_time_cap_time == HELEN_T0 + 960
    assert p.cap_time is None                             # AMRAP cap only: Helen doesn't stop
    a = WorkoutProgress(WorkoutLibrary.amrap20)
    a.start(HELEN_T0)
    assert a.for_time_cap_time is None and a.cap_time == HELEN_T0 + 1200
    q = WorkoutProgress(WorkoutLibrary.quickTest)       # no cap
    q.start(HELEN_T0)
    assert q.for_time_cap_time is None and q.cap_segment_index(HELEN_T0 + 99999) is None


def test_cap_segment_index_live_and_finished():
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(HELEN_T0)
    for i in range(1, 9):
        p.advance(HELEN_T0 + 110 * i, "crown")
    assert p.cap_segment_index(HELEN_T0 + 959) is None    # cap not reached yet
    assert p.cap_segment_index(HELEN_T0 + 960) is None    # exactly at the cap: not past it
    assert p.cap_segment_index(HELEN_T0 + 961) == 8       # Pull-ups R3 (started at 880 s)
    assert p.segment_index_at(HELEN_T0 + 109.9) == 0 and p.segment_index_at(HELEN_T0 + 110) == 1
    assert p.segment_index_at(HELEN_T0 - 1) is None
    p.advance(HELEN_T0 + 1000, "crown")                   # finished after the cap: keeps going
    assert p.is_finished and p.total_elapsed(0) == 1000
    assert p.cap_segment_index(HELEN_T0) == 8              # `now` is ignored once finished
    under = helen_progress(950)
    assert under.cap_segment_index(HELEN_T0 + 2000) is None


def test_result_cap_fields_and_text(tmp_path):
    r = helen_result(1100)                                 # 18:20, cap 16:00
    assert r.for_time_cap_seconds == 960 and r.is_capped
    assert r.total_seconds == 1100                         # the time for the full workout
    assert r.cap_reached_at == HELEN_T0 + 960
    assert r.cap_segment_index == 8                        # segment 8 runs 880..1100
    assert r.reps_at_cap_limit == 12                       # Pull-ups 12
    assert r.cap_position_text == "in Pull-ups (R3)"
    r.set_reps_at_cap(40, EDIT_NOW)
    assert r.reps_at_cap == 12 and r.edited_at == EDIT_NOW
    r.set_reps_at_cap(-3, EDIT_NOW)
    assert r.reps_at_cap == 0
    r.set_reps_at_cap(7, EDIT_NOW)
    assert r.cap_position_text == "7/12 Pull-ups (R3)"
    assert r.partial_reps is None                          # AMRAP field untouched
    path = tmp_path / "helen-capped.json"
    r.save(path)
    raw = json.loads(path.read_text())
    assert raw["repsAtCap"] == 7 and "partialReps" not in raw
    back = WorkoutResult.load(path)
    assert back.reps_at_cap == 7 and back.is_capped and back.cap_segment_index == 8
    # Older files: no repsAtCap key → None.
    del raw["repsAtCap"]
    assert WorkoutResult.from_dict(raw).reps_at_cap is None
    r.set_reps_at_cap(None, EDIT_NOW)
    assert r.reps_at_cap is None


def test_result_cap_boundaries():
    under = helen_result(950)
    assert not under.is_capped and under.cap_reached_at is None
    assert under.cap_segment_index is None and under.cap_position_text is None
    exact = helen_result(960)                              # finished on the cap: not capped
    assert not exact.is_capped
    # Segments of 120 s: segment 8 (Pull-ups R3) starts exactly on the cap and owns it.
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(HELEN_T0)
    for i in range(1, 9):
        p.advance(HELEN_T0 + 120 * i, "crown")
    p.advance(HELEN_T0 + 1200, "crown")
    start = datetime.fromtimestamp(HELEN_T0, timezone.utc)
    fin = datetime.fromtimestamp(HELEN_T0 + 1200, timezone.utc)
    r = WorkoutResult(WorkoutLibrary.helen, start, fin, fin, 1200.0,
                      split_stats(p, HELEN_T0 + 1200, [], []), list(p.events))
    assert r.cap_segment_index == 8                        # start 960 <= cap < end: the new segment
    assert r.reps_at_cap_limit == 12
    # Ended (not finished) after the cap: still capped, segment at the cap.
    q = WorkoutProgress(WorkoutLibrary.helen)
    q.start(HELEN_T0)
    q.advance(HELEN_T0 + 900, "crown")                     # KB Swings R1 from 900 s
    end = datetime.fromtimestamp(HELEN_T0 + 1000, timezone.utc)
    e = WorkoutResult(WorkoutLibrary.helen, start, None, end, 1000.0,
                      split_stats(q, HELEN_T0 + 1000, [], []), list(q.events))
    assert e.is_capped and e.cap_segment_index == 1
    assert e.cap_position_text == "in KB Swings (R1)"
    # Run at the cap: no reps target.
    e2 = WorkoutResult(WorkoutLibrary.helen, start, None, end, 1000.0,
                       split_stats(helen_progress_partial(), HELEN_T0 + 1000, [], []), [])
    assert e2.cap_segment_index == 0 and e2.reps_at_cap_limit is None
    e2.set_reps_at_cap(250, EDIT_NOW)
    assert e2.reps_at_cap == 250 and e2.cap_position_text == "250 Run (R1)"


def helen_progress_partial():
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(HELEN_T0)
    return p


def test_amrap_is_never_for_time_capped(fixtures_dir):
    r = load_amrap(fixtures_dir)
    assert r.for_time_cap_seconds is None and not r.is_capped and r.cap_position_text is None


def test_csv_cap_events(tmp_path):
    path = tmp_path / "session-cap.csv"
    write_csv(path)
    text = path.read_text().replace("# mark t=50 n=1 label=mark\n",
                                    "# mark t=50 n=1 label=mark\n"
                                    "# event t=150 name=capReached index=2\n"
                                    "# event t=205 name=repsAtCap reps=4\n"
                                    "# event t=207 name=repsAtCap reps=6\n")
    path.write_text(text)
    w = load_workout_csv(path)
    assert w.reps_at_cap == 6 and w.partial_reps is None
    assert w.cap_reached == {"t": 150.0, "index": 2}
    assert w.progress is not None and w.progress.is_finished   # boundaries unaffected
