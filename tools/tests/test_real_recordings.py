"""Smoke tests over real watch recordings in data/raw/ (no ground truth yet).

They guard against regressions that break real data: every recording must load, analyze
without raising, and confirm the physical CoreMotion sign convention (spec §4)."""
import glob
import os

import numpy as np
import pytest

from barpath import analyzer, recording

ROOT = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw")
# Lift recordings only: WorkoutResult files (workout-<id>.json) are a different format.
FILES = sorted(f for f in glob.glob(os.path.join(ROOT, "**", "*.json"), recursive=True)
               if not os.path.basename(f).startswith("workout-"))


@pytest.mark.skipif(not FILES, reason="no real recordings in data/raw")
@pytest.mark.parametrize("path", FILES, ids=[os.path.basename(f) for f in FILES])
def test_real_recording_analyzes(path):
    rec = recording.load_recording(path)
    a = analyzer.analyze(rec)
    assert a.endIndex > a.homingIndex
    assert np.all(np.isfinite(a.path.vertical))
    assert a.metrics.peakVerticalVelocity > 0.5


@pytest.mark.skipif(not FILES, reason="no real recordings in data/raw")
@pytest.mark.parametrize("path", FILES, ids=[os.path.basename(f) for f in FILES])
def test_real_recording_sign_convention(path):
    """userAccel·ĝ must track |raw| − 1 (userAccel = −a/G), see spec §4.

    |raw| − 1 ≈ a_up/G only holds for small accelerations, so compare where |userAccel| < 0.5 g
    (impacts and large horizontal jerks otherwise dominate the magnitude)."""
    rec = recording.load_recording(path)
    if len(rec.accel) == 0:
        pytest.skip("no 800 Hz accel stream")
    m = rec.motion
    ghat = m.gravity / np.linalg.norm(m.gravity, axis=1)[:, None]
    up = np.sum(m.user_accel * ghat, axis=1)
    raw_mag = np.linalg.norm(rec.accel.accel, axis=1) - 1.0
    up_i = np.interp(rec.accel.t, m.t, up)
    small = np.interp(rec.accel.t, m.t, np.linalg.norm(m.user_accel, axis=1)) < 0.5
    assert np.corrcoef(raw_mag[small], up_i[small])[0, 1] > 0.4


FIXTURES = os.path.join(os.path.dirname(__file__), "..", "..", "BarPath", "BarPathKit", "Tests",
                        "BarPathKitTests", "Fixtures")


@pytest.mark.parametrize("name", ["real_snatch", "real_power_clean"])
def test_real_lift_snapshot(name):
    """The Swift parity fixtures' expected values must stay in sync with the Python analyzer."""
    import json
    rec = recording.load_recording(os.path.join(FIXTURES, name + ".json"))
    exp = json.load(open(os.path.join(FIXTURES, name + ".python.json")))
    a = analyzer.analyze(rec)
    m = a.metrics
    assert a.homingIndex == exp["homingIndex"] and a.endIndex == exp["endIndex"]
    for key in ("peakVerticalVelocity", "maxHeight", "catchHeight", "finalHeight", "maxForward", "maxBackward"):
        assert getattr(m, key) == pytest.approx(exp[key], abs=1e-9)
    assert a.notes == exp["notes"]
