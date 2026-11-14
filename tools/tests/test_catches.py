"""Clean catch detector (tools/barpath/catches.py) on synthetic forearm motion."""
import numpy as np

from barpath.catches import CatchConfig, detect_catches, match


def forearm(segments, hz=200):
    """segments: [(seconds, gx)] -> t, gravity (gx then the rest of a unit vector)."""
    t, g = [], []
    now = 0.0
    for dur, gx in segments:
        n = int(dur * hz)
        t += list(now + np.arange(n) / hz)
        g += [[gx, 0.0, -float(np.sqrt(max(0.0, 1 - gx * gx)))]] * n
        now += dur
    return np.array(t), np.array(g)


def test_two_catches_held_in_the_rack():
    t, g = forearm([(2, -1.0), (1.8, 0.85), (2, -1.0), (1.6, 0.85), (1, -1.0)])
    got = detect_catches(t, g)
    assert [round(x, 1) for x in got] == [2.0, 5.8]


def test_a_short_wrist_flick_is_not_a_catch():
    t, g = forearm([(2, -1.0), (0.3, 0.9), (2, -1.0)])
    assert detect_catches(t, g) == []


def test_other_orientation_uses_sign():
    t, g = forearm([(2, 1.0), (1.5, -0.85), (1, 1.0)])
    # Read with the wrong sign, the catch at 2.0 s is missed (the return to the hang looks like a rack).
    assert 2.0 not in [round(x, 1) for x in detect_catches(t, g)]
    assert [round(x, 1) for x in detect_catches(t, g, CatchConfig(sign=-1))] == [2.0]


def test_match_is_one_to_one():
    assert match([1.0, 5.0, 9.0], [1.2, 1.3, 9.6], tol=0.5) == {"hits": 1, "misses": 2, "false": 2}
