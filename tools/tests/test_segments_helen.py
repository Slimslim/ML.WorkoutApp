"""Regression tests for the B2 segment detector on the first real workout recording
(data/raw/2026-10-29-helen, Apple Watch left wrist, 3 rounds: 400 m run, 21 KB swings, 12
pull-ups). Crown switches happen at the END of each movement, so each segment starts with a
transition. One athlete, one workout: these pin today's behaviour, they are not a validation."""
import glob
import os

import pytest

from barpath import recording, segments

DIR = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw", "2026-10-29-helen")
FILES = sorted(glob.glob(os.path.join(DIR, "session-*.csv")))

pytestmark = pytest.mark.skipif(not FILES, reason="Helen recording not in data/raw")


@pytest.fixture(scope="module")
def helen():
    s = recording.load_session_csv(FILES[0])
    segs = segments.crown_segments(s.events)
    runs = segments.detect_running(s.motion)
    return s.motion, segs, runs


def of_kind(segs, kind):
    return [g for g in segs if g["kind"] == kind]


def test_segment_layout(helen):
    _, segs, _ = helen
    assert [g["kind"] for g in segs] == ["run", "kb", "pull"] * 3


def test_three_runs_detected(helen):
    _, _, runs = helen
    assert len(runs) == 3


def test_run_end_within_2s_of_crown(helen):
    _, segs, runs = helen
    for g, (_a, b) in zip(of_kind(segs, "run"), runs):
        assert abs(b - g["end"]) <= 2.0


def test_run_start_after_crown_within_10s(helen):
    _, segs, runs = helen
    for g, (a, _b) in zip(of_kind(segs, "run"), runs):
        # first run: the recording starts with the run, so this is the warm-up to cadence
        assert g["start"] - 1.0 <= a <= g["start"] + 10.0


def test_no_running_inside_stations(helen):
    motion, segs, runs = helen
    for g in segs:
        if g["kind"] == "run":
            continue
        for (a, b) in runs:
            assert b <= g["start"] + 2.0 or a >= g["end"] - 2.0
        # and no single running window lies fully inside a station
        for (w, is_run) in segments.run_windows(motion, g["start"], g["end"]):
            assert not is_run, f"running window at {w:.1f}s inside {g['kind']} segment"


def test_bar_hangs_per_round(helen):
    motion, segs, _ = helen
    counts = [len(segments.bar_hangs(motion, g["start"], g["end"])) for g in of_kind(segs, "pull")]
    # Athlete: 5 sets per round (2-3-3-2-2, 1-2-3-3-3, 3-3-2-2-2). Round 3 starts with ~3 s of
    # hands up on the rack while catching breath (athlete-confirmed); the activity check drops it.
    assert counts == [5, 5, 5]


def test_hangs_are_inside_segment_and_ordered(helen):
    motion, segs, _ = helen
    for g in of_kind(segs, "pull"):
        hangs = segments.bar_hangs(motion, g["start"], g["end"])
        prev = g["start"]
        for (a, b) in hangs:
            assert prev <= a < b <= g["end"] + 0.5
            assert b - a >= segments.HANG_MIN_DURATION_S
            prev = b


def test_kb_work_onset_after_transition(helen):
    motion, segs, _ = helen
    for g in of_kind(segs, "kb"):
        on = segments.work_onset(motion, g["start"], g["end"], "kb")
        assert on is not None
        # lead's spike saw 7-9 s of walking; round 3 has a 12.0 s transition (athlete paused
        # at the bell), so the upper bound is 13 s
        assert 4.0 <= on - g["start"] <= 13.0


def test_pull_and_run_onsets(helen):
    motion, segs, _ = helen
    for g in of_kind(segs, "pull"):
        on = segments.work_onset(motion, g["start"], g["end"], "pull")
        # rounds 1-2: 3-5 s to the bar; round 3: ~11 s (hands on the rack to breathe, then chalk)
        assert on is not None and 1.0 <= on - g["start"] <= 12.0
    for g in of_kind(segs, "run")[1:]:
        on = segments.work_onset(motion, g["start"], g["end"], "run")
        assert on is not None and 0.0 <= on - g["start"] <= 10.0


def test_kb_swing_count_is_21_each_round(helen):
    motion, segs, _ = helen
    counts = [len(segments.kb_swing_count(motion, g["start"], g["end"])) for g in of_kind(segs, "kb")]
    assert counts == [21, 21, 21]   # athlete: all KB sets unbroken, 21 reps
