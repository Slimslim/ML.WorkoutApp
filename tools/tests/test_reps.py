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


# --- synthetic sets (code review 2026-10-29: slow sets, duplicate flush, long sets) ---

FS = 200.0


def _synthetic_set(n_reps, period, rom=0.6, up=1.0, down=1.0, lead=8.0, tail=10.0):
    """Arms hanging (ĝ = -x), bar pulled `rom` m in `up` s (half-sine velocity), held,
    lowered in `down` s, paused on the floor; one rep every `period` s."""
    def rep_v(t):
        v = np.zeros_like(t)
        vu = np.pi * rom / (2 * up)
        vd = np.pi * rom / (2 * down)
        m = (t >= 0) & (t < up)
        v[m] = vu * np.sin(np.pi * t[m] / up)
        t2 = t - (up + 0.4)
        m = (t2 >= 0) & (t2 < down)
        v[m] = -vd * np.sin(np.pi * t2[m] / down)
        return v
    total = lead + n_reps * period + tail
    t = np.arange(0, total, 1 / FS)
    v = np.zeros_like(t)
    for k in range(n_reps):
        v += rep_v(t - lead - k * period)
    a_up = np.gradient(v, t)
    g = np.tile([-1.0, 0.0, 0.0], (len(t), 1))
    ua = g * (a_up / 9.80665)[:, None]
    return t, ua, g


def _replay(t, ua, g, flush_after_set=False):
    from barpath.reps import SetTracker
    tr = SetTracker()
    events, dup = [], []
    for k in range(0, len(t), 200):
        ev = tr.process(t, ua, g, np.arange(k, min(len(t), k + 200)))
        events += ev
        if flush_after_set and any(e[0] == "set" for e in ev):
            d = tr.flush(t, ua, g)
            if d:
                dup.append(d)
    last = tr.flush(t, ua, g)
    if last:
        events.append(last)
    sets = [e for e in events if e[0] == "set"]
    live = [e[1] for e in events if e[0] == "rep"]
    return sets, live, dup


def test_synthetic_fast_set_is_one_set():
    sets, live, _ = _replay(*_synthetic_set(6, 2.5))
    assert [len(s[3]) for s in sets] == [6]
    assert live == list(range(1, 7))


def test_slow_dead_stop_set_is_not_split():
    # reps 5 s apart: the next rep is detected but not yet confirmed when 6 s pass
    sets, live, _ = _replay(*_synthetic_set(5, 5.0, up=1.6, down=1.4))
    assert [len(s[3]) for s in sets] == [5]
    assert live == list(range(1, 6))


def test_flush_right_after_set_end_does_not_duplicate():
    sets, _, dup = _replay(*_synthetic_set(6, 2.5), flush_after_set=True)
    assert [len(s[3]) for s in sets] == [6]
    assert dup == []


def test_long_set_keeps_counting():
    # 25 reps × 4.5 s ≈ 112 s, longer than the old 90 s history cap
    sets, live, _ = _replay(*_synthetic_set(25, 4.5))
    assert [len(s[3]) for s in sets] == [25]
    assert live == list(range(1, 26))
    assert sets[0][1] < 8.0   # recording still starts before the first rep
