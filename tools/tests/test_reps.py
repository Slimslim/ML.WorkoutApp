"""Rep counter on the filmed 2026-10-29 deadlift sets (ground truth: video, 6 reps each)."""
import csv
import glob
import os

import numpy as np
import pytest

from barpath import recording
from barpath.reps import count_reps, moving_average

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw", "2026-10-29-gym")


def _session(sid):
    files = glob.glob(os.path.join(ROOT, f"session-{sid}*.csv"))
    if not files:
        pytest.skip("gym recordings not present")
    return recording.load_session_csv(files[0])


def _video_reps(sid):
    rows = [r for r in csv.DictReader(open(os.path.join(ROOT, "video_paths", "lifts.csv")))
            if sid in r["video"]]
    return rows


@pytest.mark.parametrize("sid", ["0A3AE1B5", "8B36E5AE"])
def test_deadlift_set_counts_six_reps(sid):
    s = _session(sid)
    a = count_reps(s.motion.t, s.motion.user_accel, s.motion.gravity)
    assert a.count == 6
    video = _video_reps(sid)
    assert len(video) == 6
    # rep spacing matches the video (the two clocks differ by a constant offset)
    dw = np.diff([r.start for r in a.reps])
    dv = np.diff([float(r["t_start"]) for r in video])
    assert np.max(np.abs(dw - dv)) < 0.4
    # range of motion: inner reps within 15 cm of the video's
    rom_v = np.array([float(r["rise_cm"]) for r in video]) / 100
    rom_w = np.array([r.range for r in a.reps])
    assert np.max(np.abs(rom_w[1:-1] - rom_v[1:-1])) < 0.15


def test_moving_average_edges():
    x = np.arange(5, dtype=float)
    assert np.allclose(moving_average(x, 3), [0.5, 1, 2, 3, 3.5])
    assert np.allclose(moving_average(x, 1), x)


@pytest.mark.parametrize("sid", ["0A3AE1B5", "8B36E5AE"])
def test_set_tracker_replay_finds_one_set_of_six(sid):
    from barpath.reps import SetTracker
    s = _session(sid)
    m = s.motion
    t = m.t - m.t[0]
    tr = SetTracker()
    events = []
    for k in range(0, len(t), 200):   # ~1 s batches, as on the watch
        events += tr.process(t, m.user_accel, m.gravity, np.arange(k, min(len(t), k + 200)))
    last = tr.flush(t, m.user_accel, m.gravity)
    if last:
        events.append(last)
    sets = [e for e in events if e[0] == "set"]
    assert len(sets) == 1 and len(sets[0][3]) == 6
    live = [e[1] for e in events if e[0] == "rep"]
    assert live == [1, 2, 3, 4, 5, 6]
