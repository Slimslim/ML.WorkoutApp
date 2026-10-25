import json

import numpy as np
import pytest

from barpath.detector import (Armed, DetectorConfig, Disarmed, LiftEnded, LiftStarted, OnlineLiftDetector,
                              detected_lifts, run_detector)
from barpath.geometry import G
from barpath.recording import MotionSeries, load_session_csv
from barpath.simulate import Choreo, NoiseModel, sense, simulate_session

DOWN_X = (1.0, 0.0, 0.0)      # forearm vertical, hand down: gravity along +x
HORIZONTAL = (0.0, 0.0, 1.0)  # forearm horizontal


def feed(det, t, ua=(0, 0, 0), g=DOWN_X, rr=(0, 0, 0)):
    return det.process(t, ua, g, rr)


def run(det, t0, t1, fn=None, g=DOWN_X, rate=200.0):
    events = []
    for t in np.arange(t0, t1, 1 / rate):
        ua = fn(t) if fn else (0.0, 0.0, 0.0)
        ev = det.process(float(t), ua, g, (0.0, 0.0, 0.0))
        if ev is not None:
            events.append((float(t), ev))
    return events


def up(a_ms2):
    """userAccel (g) for an upward acceleration with gravity along +x (down = +x).
    Physical convention: userAccel = -a/G, and a points up = -x, so userAccel = +a_up/G along x."""
    return (a_ms2 / G, 0.0, 0.0)


def test_arms_after_still_with_vertical_forearm():
    det = OnlineLiftDetector()
    ev = run(det, 0, 1.0)
    assert len(ev) == 1 and isinstance(ev[0][1], Armed)
    assert ev[0][0] == pytest.approx(0.30, abs=0.011)
    assert det.state == "armed"


def test_does_not_arm_with_horizontal_forearm():
    det = OnlineLiftDetector()
    assert run(det, 0, 2.0, g=HORIZONTAL) == []
    assert det.state == "idle"


def test_does_not_arm_while_moving():
    det = OnlineLiftDetector()
    assert run(det, 0, 3.0, fn=lambda t: (0.2 * np.sin(2 * np.pi * 2 * t), 0.0, 0.0)) == []


def test_disarms_when_rehoming_with_horizontal_forearm():
    det = OnlineLiftDetector()
    run(det, 0, 0.5)
    assert det.state == "armed"
    ev = run(det, 0.5, 1.5, g=HORIZONTAL)
    assert [type(e) for _, e in ev] == [Disarmed]
    assert det.state == "idle"


def test_disarms_after_start_window_without_pull():
    det = OnlineLiftDetector()
    run(det, 0, 0.5)
    # wobbling in place (|a| ~ 0.1 g, no net upward velocity)
    ev = run(det, 0.5, 2.0, fn=lambda t: (0.1 * np.sin(2 * np.pi * 3 * t), 0.0, 0.0))
    assert [type(e) for _, e in ev] == [Disarmed]
    assert 1.5 < ev[0][0] < 1.7   # startWindow of motion after the stillness EMA lets go


def test_rehoming_while_armed_updates_homing_time():
    det = OnlineLiftDetector()
    run(det, 0, 2.0)
    assert det.state == "armed" and det.homing_time == pytest.approx(2.0 - 0.005)


def test_lift_start_and_returned_end():
    det = OnlineLiftDetector()
    run(det, 0, 1.0)
    # 0.4 s up at 3 m/s², 0.4 s down at -3 m/s² (v back to 0, h ≈ 0.48), stay, then reverse
    def prof(t):
        s = t - 1.0
        if s < 0.4: return up(3.0)
        if s < 0.8: return up(-3.0)
        if s < 2.0: return up(0.0)
        if s < 2.4: return up(-3.0)
        if s < 2.8: return up(3.0)
        return up(0.0)
    ev = run(det, 1.0, 6.0, fn=prof)
    kinds = [type(e) for _, e in ev]
    assert kinds[0] is LiftStarted
    # homing = last sample with stillDur >= rehomeStill; the EMA keeps 'still' a few samples into the motion
    assert 1.0 - 0.006 <= ev[0][1].homingTime <= 1.0 + 0.05
    end = ev[1][1]
    assert isinstance(end, LiftEnded) and end.reason == "returned"


def test_no_anchor_timeout():
    det = OnlineLiftDetector()
    run(det, 0, 1.0)
    ev = run(det, 1.0, 7.0, fn=lambda t: up(3.0) if t < 1.3 else (0.15 * np.sin(2 * np.pi * 2 * t), 0, 0))
    assert isinstance(ev[0][1], LiftStarted)
    end = ev[1][1]
    assert isinstance(end, LiftEnded) and end.reason == "timeout"
    assert ev[1][0] - end.homingTime == pytest.approx(4.0, abs=0.01)


def test_drop_end_and_cooldown():
    det = OnlineLiftDetector()
    run(det, 0, 1.0)
    def prof(t):
        s = t - 1.0
        if s < 0.4: return up(5.0)        # up 0.8 m total
        if s < 0.8: return up(-5.0)
        if s < 1.6: return up(0.0)        # anchor at ~0.8 m
        if s < 2.0: return up(-8.0)       # fall
        if s < 2.4: return up(8.0)
        return up(0.0)
    ev = run(det, 1.0, 6.0, fn=prof)
    assert [type(e) for _, e in ev][:2] == [LiftStarted, LiftEnded]
    end_t, end = ev[1]
    assert end.reason == "drop"
    assert 1.0 + 1.1 < end.endTime <= 1.0 + 1.62
    assert det.state in ("cooldown", "idle", "armed")
    # nothing re-arms until the cooldown has expired
    arm = [t for t, e in ev if isinstance(e, Armed)]
    assert all(t >= end_t + 1.5 for t in arm)


def test_first_sample_dt_zero_and_clamp():
    det = OnlineLiftDetector()
    feed(det, 100.0)
    assert det.still_dur == 0.0
    feed(det, 101.0)                     # 1 s gap is clamped to 0.05
    assert det.still_dur == pytest.approx(0.05)


# ---- session simulation --------------------------------------------------------------------

@pytest.fixture(scope="module")
def session():
    return simulate_session(seed=7)


def test_session_detects_exactly_two_lifts(session):
    ends = detected_lifts(session.motion)
    assert len(ends) == 2
    for e, lt in zip(ends, session.lifts):
        assert abs(e.homingTime - lt.t_homing) < 0.5
        assert abs(e.endTime - lt.t_end) < 0.5
        assert e.reason == "drop"


def test_no_false_lifts_during_walking(session):
    events = run_detector(session.motion)
    for _, t, ev in events:
        if isinstance(ev, LiftStarted):
            assert any(lt.t_homing - 0.5 < t < lt.t_homing + 1.0 for lt in session.lifts), t


@pytest.mark.parametrize("seed", [1, 2, 3])
def test_session_other_seeds(seed):
    ses = simulate_session(seed=seed)
    ends = detected_lifts(ses.motion)
    assert len(ends) == 2
    for e, lt in zip(ends, ses.lifts):
        assert abs(e.homingTime - lt.t_homing) < 0.5 and abs(e.endTime - lt.t_end) < 0.5


def test_walking_with_pauses_has_no_lifts():
    c = Choreo(start_pose="side")
    c.still(1.0)
    for k in range(4):
        c.walk_straight(4.0 + k)
        c.still(0.6 + 0.4 * k)       # standing still, arm hanging: arms, then disarms on walking
        c.turn(120)
    traj = c.build()
    data = sense(traj, 0.0, traj.duration, np.random.default_rng(5), NoiseModel(), accel_rate=None)
    events = run_detector(data.motion)
    assert any(isinstance(e, Armed) for _, _, e in events)
    assert not any(isinstance(e, (LiftStarted, LiftEnded)) for _, _, e in events)


def test_session_fixture_file(fixtures_dir):
    p = fixtures_dir / "sim_session.csv"
    if not p.exists():
        pytest.skip("fixtures not generated")
    exp = json.loads((fixtures_dir / "sim_session.expected.json").read_text())
    ends = detected_lifts(load_session_csv(p).motion)
    assert len(ends) == exp["liftCount"]
    for e, x in zip(ends, exp["lifts"]):
        assert abs(e.homingTime - x["homingTime"]) <= exp["tolerance"]["time"]
        assert abs(e.endTime - x["endTime"]) <= exp["tolerance"]["time"]
