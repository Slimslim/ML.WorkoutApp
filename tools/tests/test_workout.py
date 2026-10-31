import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

from barpath.workout import (
    PedometerSample, SegmentTarget, TimedValue, WorkoutLibrary, WorkoutProgress, WorkoutResult,
    WorkoutSegment, load_workout_csv, split_stats)

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
        "hyrox.solo", "hyrox.doubles", "hyrox.half", "partner.wod1", "partner.wod2", "quick.test",
        "wod.helen", "wod.rowThrusters", "wod.nightmareAmrap"]
    assert len({d.id for d in WorkoutLibrary.all}) == 9
    assert len(WorkoutLibrary.helen.segments) == 9 and WorkoutLibrary.helen.run_count == 3
    assert WorkoutLibrary.helen.segments[1].title == "KB Swings 21"
    assert len(WorkoutLibrary.rowThrusters.segments) == 17
    assert WorkoutLibrary.rowThrusters.segments[0].title == "Row 15 cal"
    assert WorkoutLibrary.rowThrusters.segments[2].title == "Rest"
    assert len(WorkoutLibrary.amrap20.segments) == 40
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
    assert p.auto_advance_time() is None          # rowing
    p.advance(1060, "crown")                       # thrusters
    assert p.auto_advance_time() is None
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
