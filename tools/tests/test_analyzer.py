import json

import numpy as np
import pytest

from barpath.analyzer import (NOTE_GRAVITY_ONLY, NOTE_NO_ANCHOR, AnalyzerConfig, NoHomingFound, TooShort,
                              analyze, principal_axis)
from barpath.recording import LiftRecording, MotionSeries
from barpath.simulate import simulate_lift

import make_fixtures

TOL = {"maxHeight": "height", "catchHeight": "height", "finalHeight": "height",
       "peakVerticalVelocity": "velocity", "maxBackward": "horizontal"}
TOLERANCE = make_fixtures.TOLERANCE


def check(metrics, truth, keys=TOL):
    errs = {}
    for k, tk in keys.items():
        got = getattr(metrics, k)
        assert got is not None, k
        errs[k] = got - truth[k]
    bad = {k: round(e, 4) for k, e in errs.items() if abs(e) > TOLERANCE[keys[k]]}
    assert not bad, f"out of tolerance: {bad}"


@pytest.mark.parametrize("name,lift_type,seed,conj", make_fixtures.LIFTS)
def test_analyzer_recovers_ground_truth(name, lift_type, seed, conj):
    sim = simulate_lift(lift_type, seed=seed, conjugate=conj)
    a = analyze(sim.recording)
    assert a.quaternionMode == ("conjugate" if conj else "direct")
    assert a.confidence == "high"
    assert a.notes == []
    check(a.metrics, sim.truth)
    assert a.metrics.dropUnderBar == pytest.approx(a.metrics.maxHeight - a.metrics.catchHeight)
    # homing within 0.2 s of the true pull start; path ends at the final hold (before the drop)
    t = sim.recording.motion.t
    assert abs(t[a.homingIndex] - sim.lift.t_homing) < 0.2
    assert sim.lift.t_end - 0.3 < t[a.endIndex] < sim.lift.t_end + 0.2
    # segments: pull->catch, recovery->hold (+ rack->overhead for C&J)
    assert len(a.segments) == (3 if lift_type == "cleanAndJerk" else 2)
    assert a.segments[0].startIndex == 0 and a.segments[-1].endIndex <= len(a.path) - 1


@pytest.mark.parametrize("name,lift_type,seed,conj", make_fixtures.LIFTS)
def test_fixture_files_match_ground_truth(fixtures_dir, name, lift_type, seed, conj):
    p = fixtures_dir / f"{name}.json"
    if not p.exists():
        pytest.skip("fixtures not generated (python tools/make_fixtures.py)")
    exp = json.loads((fixtures_dir / f"{name}.expected.json").read_text())
    truth = simulate_lift(lift_type, seed=seed, conjugate=conj).truth
    for k in TOL:
        assert exp[k] == pytest.approx(truth[k], abs=1e-3)
    a = analyze(LiftRecording.load(p))
    check(a.metrics, exp)


@pytest.mark.parametrize("lift_type", ["snatch", "cleanAndJerk"])
def test_vertical_metrics_robust_over_seeds(lift_type):
    vertical = {k: v for k, v in TOL.items() if k != "maxBackward"}
    for seed in range(10, 20):
        sim = simulate_lift(lift_type, seed=seed, fill_detector_fields=False)
        check(analyze(sim.recording).metrics, sim.truth, vertical)


def test_noise_free_is_exact():
    from barpath.simulate import NoiseModel
    z = NoiseModel(accel_noise=0, accel_bias=(0, 0), gyro_noise=0, gyro_bias=0, gravity_noise=0,
                   attitude_error_deg=0, yaw_drift_deg_per_min=0)
    for lt in ("snatch", "cleanAndJerk"):
        sim = simulate_lift(lt, seed=1, noise=z, fill_detector_fields=False)
        m = analyze(sim.recording).metrics
        for k in TOL:
            assert getattr(m, k) == pytest.approx(sim.truth[k], abs=0.005), k


def test_gravity_only_fallback_with_garbage_quaternions():
    sim = simulate_lift("snatch", seed=1, fill_detector_fields=False)
    rec = sim.recording
    rng = np.random.default_rng(0)
    q = rng.normal(size=rec.motion.q.shape)
    rec.motion.q = q / np.linalg.norm(q, axis=1, keepdims=True)
    a = analyze(rec)
    assert a.quaternionMode == "gravityOnly"
    assert NOTE_GRAVITY_ONLY in a.notes
    assert a.confidence in ("medium", "low")
    assert np.all(a.path.forward == 0) and np.all(a.path.lateral == 0)
    assert a.metrics.maxForward == 0 and a.metrics.maxBackward == 0
    vertical = {k: v for k, v in TOL.items() if k != "maxBackward"}
    check(a.metrics, sim.truth, vertical)


def test_no_anchor_path_uncorrected():
    sim = simulate_lift("snatch", seed=1, fill_detector_fields=False)
    rec = sim.recording
    t = rec.motion.t
    i1 = int(np.searchsorted(t, sim.lift.t_catch_still - 0.1))  # cut before the catch settles
    rec.motion = rec.motion.slice(0, i1)
    a = analyze(rec)
    assert NOTE_NO_ANCHOR in a.notes and a.confidence == "low"
    assert len(a.segments) == 1 and a.segments[0].driftCorrection == 0
    # Revision D: the catch is found from vz (no still pause needed), even without anchors
    assert a.metrics.catchHeight is not None
    assert a.path.t[-1] <= AnalyzerConfig().maxUncorrectedDuration + 1e-9


def test_errors():
    sim = simulate_lift("snatch", seed=1, fill_detector_fields=False)
    rec = sim.recording
    still = rec.motion.slice(0, 250)       # 1.25 s of stillness, no pull
    rec.motion = still
    rec.homing_time = None
    with pytest.raises(NoHomingFound):
        analyze(rec)
    rec.homing_time = 1.0                   # fallback homing, but < 0.5 s of data after it
    with pytest.raises(TooShort):
        analyze(rec)
    rec.motion = rec.motion.slice(0, 1)
    with pytest.raises(TooShort):
        analyze(rec)


def test_principal_axis():
    rng = np.random.default_rng(0)
    d = np.array([np.cos(0.6), np.sin(0.6)])
    xy = rng.normal(size=(500, 1)) * d + rng.normal(scale=0.05, size=(500, 2))
    e = principal_axis(xy)
    assert abs(abs(e @ d) - 1) < 1e-2
    assert np.allclose(np.abs(principal_axis(np.array([[0, 0], [0, 1.0], [0, 2.0]]))), [0, 1])
