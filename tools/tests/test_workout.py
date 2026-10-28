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
