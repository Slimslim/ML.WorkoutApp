"""Transition vs work onset (barpath.transitions): synthetic signals with a known onset, plus loose
checks on the owner's recordings (data/raw). The real-data checks pin plausibility, not accuracy:
there are no per-rep timestamps to validate against."""
import glob
import os

import numpy as np
import pytest

from barpath import transitions as T
from barpath.recording import MotionSeries

FS = 100.0
RNG = np.random.default_rng(7)


def series(dur, ua=None, g=None, rot=None):
    n = int(dur * FS)
    t = np.arange(n) / FS
    ua = np.zeros((n, 3)) if ua is None else ua
    g = np.tile([-0.9, 0.0, -0.43], (n, 1)) if g is None else g
    rot = np.zeros((n, 3)) if rot is None else rot
    return t, MotionSeries(t, np.zeros((n, 4)), ua, g, rot)


def walking(t, amp=0.12):
    """Arms-down walking: ~110 steps/min, small accel, a little rotation."""
    ua = np.zeros((len(t), 3))
    ua[:, 0] = 0.15 + amp * np.sin(2 * np.pi * 1.85 * t) + 0.02 * RNG.standard_normal(len(t))
    return ua


# ---- synthetic -------------------------------------------------------------------------------

def test_rest_has_no_transition():
    _, m = series(60)
    o = T.work_onset("rest", m, 0.0, 60.0)
    assert o.onset is None and o.method == "rest" and o.confidence == 1.0


def test_too_short_segment():
    _, m = series(0.5)
    o = T.work_onset("row", m, 0.0, 0.5)
    assert o.onset is None and o.confidence == 0.0


def test_run_onset_is_running_cadence():
    t, _ = series(90)
    ua = walking(t)
    run = t >= 12.0
    # |userAccel| at 160 steps/min (positive offset keeps |a| at the same frequency), SD > 0.25 g
    ua[run, 0] = 0.9 + 0.6 * np.sin(2 * np.pi * (160 / 60) * t[run])
    _, m = series(90, ua=ua)
    o = T.work_onset("run", m, 0.0, 90.0)
    assert o.method == "run"
    assert 10.0 <= o.onset <= 16.0


def test_row_onset_cyclic_gx():
    t, _ = series(60)
    g = np.tile([-0.9, 0.0, -0.43], (len(t), 1))
    g[:, 0] += 0.03 * RNG.standard_normal(len(t))
    row = t >= 9.0
    g[row, 0] = -0.2 + 0.5 * np.sin(2 * np.pi * t[row] / 2.5)
    _, m = series(60, ua=walking(t) * (~row)[:, None], g=g)
    o = T.work_onset("row", m, 0.0, 60.0)
    assert o.method == "row"
    assert 7.0 <= o.onset <= 11.0


def test_bike_onset_cyclic_vert():
    t, _ = series(60)
    ua = np.zeros((len(t), 3))
    ua[:, 0] = 0.03 * RNG.standard_normal(len(t))
    bike = t >= 6.0
    # vert = -(a . g); push-pull at 1 Hz along the gravity direction
    ua[bike, 0] += 0.35 * np.sin(2 * np.pi * 1.0 * t[bike])
    _, m = series(60, ua=ua)
    o = T.work_onset("bike", m, 0.0, 60.0)
    assert o.method == "bike"
    assert 4.5 <= o.onset <= 8.0


def overhead_gx(t, rep_times, width=0.8):
    """Forearm hanging (gx -0.9) with a raise to vertical (+1) centred at each rep time."""
    gx = np.full(len(t), -0.9)
    for r in rep_times:
        gx += 1.9 * np.exp(-0.5 * ((t - r) / (width / 2)) ** 2)
    return np.minimum(gx, 1.0)


def test_overhead_onset_skips_lone_arm_raise():
    t, _ = series(50)
    reps = [3.0] + [20.0 + 2.4 * k for k in range(12)]   # lone wave at 3 s, then 12 snatches
    g = np.tile([-0.9, 0.0, -0.43], (len(t), 1))
    g[:, 0] = overhead_gx(t, reps)
    _, m = series(50, g=g)
    o = T.work_onset("dumbbellSnatch", m, 0.0, 50.0)
    assert o.method == "overhead"
    assert 18.5 <= o.onset <= 20.0   # start of the first real rise


def test_burpee_onset_needs_landing_impulse():
    t, _ = series(80)
    reps = [4.0] + [25.0 + 6.0 * k for k in range(8)]    # arm raise at 4 s without a jump
    g = np.tile([-0.9, 0.0, -0.43], (len(t), 1))
    g[:, 0] = overhead_gx(t, reps)
    ua = np.zeros((len(t), 3))
    ua[t < 22.5] = walking(t[t < 22.5])
    ua[(t >= 18.0) & (t < 22.5)] = 0.005            # standing still at the target
    moving = t >= 22.5                              # down, push-up, up, jump, ...
    ua[moving] = 0.3 * RNG.standard_normal((moving.sum(), 3))
    for r in reps[1:]:
        # chest to floor 2.5 s before the jump, landing just after: vert = -(a . g) < -1.5 g
        for c in (r - 2.5, r + 0.6):
            k = (t > c - 0.15) & (t < c + 0.15)
            ua[k] = 3.0 * g[k] / np.linalg.norm(g[k], axis=1)[:, None]
    _, m = series(80, ua=ua, g=g)
    o = T.work_onset("burpees", m, 0.0, 80.0)
    assert o.method == "burpee"
    assert 22.0 <= o.onset <= 23.0   # end of the still moment = the drop to the floor


def test_hang_onset():
    t, _ = series(40)
    g = np.tile([-0.9, 0.0, -0.43], (len(t), 1))
    hang = (t >= 11.0) & (t < 28.0)
    g[hang] = [1.0, 0.0, 0.1]
    _, m = series(40, ua=walking(t) * (~hang)[:, None], g=g)
    o = T.work_onset("pullUps", m, 0.0, 40.0)
    assert o.method == "pullup"
    assert 10.5 <= o.onset <= 12.0


def test_generic_fallback_energy_rise():
    t, _ = series(60)
    ua = 0.03 * RNG.standard_normal((len(t), 3))
    on = t >= 15.0
    ua[on] = 0.6 * RNG.standard_normal((on.sum(), 3))
    _, m = series(60, ua=ua)
    o = T.work_onset("sandbagLunges", m, 0.0, 60.0)
    assert o.method == "generic" and o.confidence == 0.5
    assert 12.5 <= o.onset <= 16.0


def test_generic_none_on_flat_segment():
    _, m = series(30)
    o = T.work_onset("sandbagLunges", m, 0.0, 30.0)
    assert o.onset is None and o.confidence == 0.0


def test_split_adds_up():
    t, _ = series(60)
    ua = 0.03 * RNG.standard_normal((len(t), 3))
    ua[t >= 20.0] = 0.6 * RNG.standard_normal(((t >= 20.0).sum(), 3))
    _, m = series(60, ua=ua)
    r = T.split("unknown", m, 0.0, 60.0)
    assert r["transition"] + r["work"] == pytest.approx(r["total"])
    assert 15.0 <= r["transition"] <= 21.0


def test_segment_offset_is_respected():
    """Onset is relative to the segment start, not the session start."""
    t, _ = series(100)
    ua = 0.03 * RNG.standard_normal((len(t), 3))
    on = t >= 60.0
    ua[on] = 0.6 * RNG.standard_normal((on.sum(), 3))
    _, m = series(100, ua=ua)
    o = T.work_onset("x", m, 50.0, 100.0)
    assert 7.5 <= o.onset <= 11.0


def test_first_of_train():
    ev = [(1.0,), (14.0,), (16.0,), (18.0,), (20.0,)]
    assert T.first_of_train(ev) == 1
    assert T.first_of_train([(1.0,), (30.0,)]) is None


# ---- owner's recordings ----------------------------------------------------------------------

RAW = os.path.join(os.path.dirname(__file__), "..", "..", "data", "raw")
AMRAP40 = os.path.join(RAW, "2026-11-01-amrap40")
HELEN = os.path.join(RAW, "2026-10-29-helen")


def have(folder):
    return glob.glob(os.path.join(folder, "session-*.csv")) and glob.glob(os.path.join(folder, "workout-*.json"))


@pytest.fixture(scope="module")
def amrap40():
    if not have(AMRAP40):
        pytest.skip("AMRAP 40 recording not in data/raw")
    m, segs = T.load_workout(AMRAP40)
    return {s["index"]: (s, T.work_onset(s["movement"], m, s["start"], s["end"])) for s in segs}


def test_amrap40_onset_found_in_80_percent_of_stations(amrap40):
    stations = [(s, o) for s, o in amrap40.values() if s["movement"] != "rest"]
    assert len(stations) == 28
    inside = [o.onset is not None and 0.0 <= o.onset < s["end"] - s["start"] for s, o in stations]
    assert sum(inside) >= 0.8 * len(stations)
    # and mostly from a movement-specific detector, not the fallback
    assert sum(o.confidence >= 0.75 for _, o in stations) >= 0.8 * len(stations)


def test_amrap40_rests_have_no_transition(amrap40):
    for s, o in amrap40.values():
        if s["movement"] == "rest":
            assert o.onset is None and o.method == "rest"


def test_amrap40_erg_onsets_short(amrap40):
    """Row / bike follow the 1:00 rest, during which the athlete walks over: <= 12 s to the
    first stroke (rep-counting prototype: 1-10 s)."""
    ergs = [o for s, o in amrap40.values() if s["movement"] in ("row", "bike")]
    assert len(ergs) == 7
    assert all(o.onset is not None and o.onset <= 12.0 for o in ergs)


def test_amrap40_lead_in_matches_rep_counter(amrap40):
    """Pull-up hangs at 11.6 / 13.7 / 17.0 s (ANALYSIS.md); wall walks 29.6 / 32.3 / 42.1 s."""
    expect = {6: 11.6, 16: 13.7, 26: 17.0, 8: 29.6, 18: 32.3, 28: 42.1}
    for i, v in expect.items():
        assert amrap40[i][1].onset == pytest.approx(v, abs=4.0)


def test_helen_kb_and_runs():
    if not have(HELEN):
        pytest.skip("Helen recording not in data/raw")
    m, segs = T.load_workout(HELEN)
    for s in segs:
        o = T.work_onset(s["movement"], m, s["start"], s["end"])
        if s["movement"] == "kettlebellSwings":   # README: ~7-9 s of walking before the swings
            assert 5.0 <= o.onset <= 15.0
        if s["movement"] == "run":                # README: running starts 2-8 s after the Crown
            assert o.onset is not None and o.onset <= 10.0
