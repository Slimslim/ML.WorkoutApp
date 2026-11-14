"""Build 15 records workouts at 200 Hz: the Python loader decimates them to the 100 Hz the workout
detectors are tuned for, and tells the true rates. Lifting CSVs are never resampled."""
import glob
import os

import numpy as np
import pytest

from barpath import recording, segments

HEAD = "# barpath-session v1, sessionId=00000000-0000-0000-0000-000000000001, startDate=2026-11-11T10:00:00Z, {tag}{rate}\n"
COLS = "t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz\n"


def synth(n100: int, upsample: int = 1):
    """n100 samples' worth of a smooth 'working' signal at 100 Hz, optionally sampled `upsample` times finer."""
    t = np.arange(n100 * upsample) / (100.0 * upsample)
    ax = 0.5 * np.sin(2 * np.pi * 1.2 * t) + 0.2 * np.sin(2 * np.pi * 3.1 * t)
    gx = 0.3 * np.sin(2 * np.pi * 0.2 * t)
    rows = np.zeros((len(t), 14))
    rows[:, 0] = t
    rows[:, 1] = 1.0
    rows[:, 5] = ax
    rows[:, 8] = gx
    rows[:, 9] = -np.sqrt(1 - gx ** 2)
    rows[:, 11] = 0.8 * np.cos(2 * np.pi * 1.2 * t)
    return rows


def write(path, rows, tag, rate=""):
    with open(path, "w") as f:
        f.write(HEAD.format(tag=tag, rate=rate))
        f.write(COLS)
        f.write("# event t=0.000000 name=segment index=0 kind=station source=start\n")
        for r in rows:
            f.write(f"{r[0]:.6f}," + ",".join(f"{x:.5f}" for x in r[1:]) + "\n")
        f.write("# event t=5.000000 name=hr bpm=150\n")


def test_200hz_workout_loads_as_100hz(tmp_path):
    p100, p200 = tmp_path / "a.csv", tmp_path / "b.csv"
    write(p100, synth(1000), "workout=wod.helen", ", sampleRate=100")
    write(p200, synth(1000, 2), "workout=wod.helen", ", sampleRate=200")
    a, b = recording.load_session_csv(p100), recording.load_session_csv(p200)
    assert (a.sample_rate, a.source_rate) == (100.0, 100.0)
    assert (b.sample_rate, b.source_rate) == (100.0, 200.0)
    assert len(a.motion) == len(b.motion) == 1000
    np.testing.assert_allclose(a.motion.t, b.motion.t, atol=1e-9)
    np.testing.assert_allclose(a.motion.user_accel, b.motion.user_accel, atol=1e-4)
    np.testing.assert_allclose(a.motion.gravity, b.motion.gravity, atol=1e-4)
    assert [e["name"] for e in b.events] == ["segment", "hr"]
    # a detector on both
    assert segments.detect_running(a.motion) == segments.detect_running(b.motion)
    ra = segments.work_onset(a.motion, 0.0, 9.0, "kb")
    rb = segments.work_onset(b.motion, 0.0, 9.0, "kb")
    assert ra == rb or abs(ra - rb) < 0.05


def test_rate_measured_when_header_has_none(tmp_path):
    p = tmp_path / "c.csv"
    write(p, synth(600, 2), "workout=wod.helen")
    s = recording.load_session_csv(p)
    assert s.source_rate == pytest.approx(200.0, rel=0.01) and len(s.motion) == 600


def test_keep_native_rate_and_lifting_untouched(tmp_path):
    p = tmp_path / "d.csv"
    write(p, synth(500, 2), "workout=wod.helen", ", sampleRate=200")
    assert len(recording.load_session_csv(p, workout_hz=None).motion) == 1000
    q = tmp_path / "e.csv"
    write(q, synth(500, 2), "liftType=snatch", ", sampleRate=200")
    s = recording.load_session_csv(q)
    assert len(s.motion) == 1000 and s.sample_rate == 200.0


def test_plan_profile_header(tmp_path):
    p = tmp_path / "f.csv"
    write(p, synth(300), "workout=x", ", sampleRate=100, planProfile=high")
    assert recording.load_session_csv(p).plan_profile == "high"


HELEN = sorted(glob.glob(os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw", "2026-10-29-helen", "session-*.csv")))


@pytest.mark.skipif(not HELEN, reason="Helen recording not in data/raw")
def test_real_helen_as_200hz_gives_same_detections(tmp_path):
    base = recording.load_session_csv(HELEN[0])
    m = base.motion
    n = len(m)
    # Upsample the real 100 Hz recording to 200 Hz by linear interpolation of every column.
    t2 = np.arange(2 * n - 1) * 0.5
    idx = np.arange(n)
    cols = [np.interp(t2, idx, m.t)]
    for j in range(4):
        cols.append(np.interp(t2, idx, m.q[:, j]))
    for arr in (m.user_accel, m.gravity, m.rotation_rate):
        for j in range(3):
            cols.append(np.interp(t2, idx, arr[:, j]))
    rows = np.stack(cols, axis=1)
    p = tmp_path / "helen200.csv"
    write(p, rows, "workout=wod.helen", ", sampleRate=200")
    up = recording.load_session_csv(p)
    assert len(up.motion) == n
    assert segments.detect_running(up.motion) == segments.detect_running(m)
    np.testing.assert_allclose(up.motion.user_accel, m.user_accel, atol=2e-5)
