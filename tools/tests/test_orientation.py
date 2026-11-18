import numpy as np

from barpath.orientation import canonicalize, orientation
from barpath.recording import MotionSeries


def series(g, rot=(0.1, 0.2, 0.3), acc=(0.01, 0.02, 0.03), q=(1.0, 0.0, 0.0, 0.0)):
    n = 4
    return MotionSeries(np.arange(n) / 100.0, np.tile(q, (n, 1)), np.tile(acc, (n, 1)),
                        np.tile(g, (n, 1)), np.tile(rot, (n, 1)))


def gravity_from_q(q):
    w, x, y, z = q.T
    return -np.c_[2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]


def test_canonical_watch_is_untouched():
    m = series((0.85, 0.1, -0.5))
    assert canonicalize(m, "left", "left") is m
    assert canonicalize(m, None, None) is m          # files before build 15: the owner's watch


def test_crown_right_on_left_wrist_is_a_half_turn():
    m = canonicalize(series((-0.85, 0.1, -0.5)), "left", "right")
    np.testing.assert_allclose(m.gravity[0], (0.85, -0.1, -0.5))   # front rack reads +x like the owner's
    np.testing.assert_allclose(m.rotation_rate[0], (-0.1, -0.2, 0.3))
    np.testing.assert_allclose(m.user_accel[0], (-0.01, -0.02, 0.03))


def test_turned_quaternion_still_gives_the_turned_gravity():
    a = 0.7
    q = (np.cos(a / 2), np.sin(a / 2) * 0.6, np.sin(a / 2) * 0.8, 0.0)
    raw = series(tuple(gravity_from_q(np.array([q]))[0]), q=q)
    m = canonicalize(raw, "left", "right")
    np.testing.assert_allclose(gravity_from_q(m.q), m.gravity, atol=1e-12)
    np.testing.assert_allclose(np.linalg.norm(m.q, axis=1), 1.0)


def test_right_wrist_is_a_mirror():
    o = orientation("right", "right")        # Crown toward the elbow: mirror only
    assert not o.turn and not o.q_valid
    m = canonicalize(series((0.85, 0.1, -0.5)), "right", "right")
    np.testing.assert_allclose(m.gravity[0], (0.85, -0.1, -0.5))
    np.testing.assert_allclose(m.rotation_rate[0], (-0.1, 0.2, -0.3))   # pseudovector


def test_right_wrist_crown_left_is_mirror_and_turn():
    o = orientation("right", "left")         # Apple's default on the right wrist: Crown toward the hand
    assert o.turn
    np.testing.assert_allclose(o.vector, np.diag([-1.0, 1.0, 1.0]))
    np.testing.assert_allclose(o.rotation, np.diag([1.0, -1.0, -1.0]))


def test_unknown_values_fall_back_to_the_owner():
    assert orientation("LEFT", "?").is_identity
