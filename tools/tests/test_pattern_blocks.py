import numpy as np

from barpath.pattern_blocks import Config, blocks
from barpath.recording import MotionSeries

FS = 100


def synthetic(parts, seed=0):
    """parts: [(kind, seconds)] with kind 'A' (1 Hz, arm up), 'B' (0.5 Hz, arm down), 'rest'."""
    rng = np.random.default_rng(seed)
    acc, grav = [], []
    for kind, sec in parts:
        n = int(sec * FS)
        tt = np.arange(n) / FS
        if kind == "A":
            a = 0.8 * np.abs(np.sin(np.pi * 1.0 * tt)) ** 4
            g = (0.8, 0.0, -0.6)
        elif kind == "B":
            a = 0.4 * np.abs(np.sin(np.pi * 0.5 * tt)) ** 2
            g = (-0.8, 0.2, -0.5)
        else:
            a = np.zeros(n)
            g = (-0.9, 0.0, -0.4)
        acc.append(np.c_[a + 0.01 * rng.standard_normal(n), 0.01 * rng.standard_normal((n, 2))])
        grav.append(np.tile(g, (n, 1)) + 0.02 * rng.standard_normal((n, 3)))
    ua, g = np.vstack(acc), np.vstack(grav)
    n = len(ua)
    return MotionSeries(np.arange(n) / FS, np.tile((1.0, 0, 0, 0), (n, 1)), ua, g, 0.5 * ua)


def test_blocks_follow_the_order_with_rests_inside_and_between():
    parts = [("A", 40), ("rest", 10), ("B", 30), ("rest", 8),
             ("A", 20), ("rest", 6), ("A", 15), ("rest", 9), ("B", 35)]
    bl = blocks(synthetic(parts), ["A", "B", "A", "B"], cfg=Config(restarts=6))
    starts = [0, 50, 88, 138]
    ends = [40, 80, 129, 173]
    for b, s, e in zip(bl, starts, ends):
        assert abs(b.start - s) <= 3, (b, s)
        assert abs(b.end - e) <= 3, (b, e)
    assert len(bl[2].pauses) == 1      # the rest inside the third block (20 + 15)


def test_crown_hint_by_position_is_accepted():
    parts = [("A", 30), ("rest", 5), ("B", 30), ("rest", 5), ("A", 30)]
    bl = blocks(synthetic(parts, 1), ["A", "B", "A"], cfg=Config(restarts=3), hints=[36.0, 71.0])
    assert abs(bl[1].start - 35) <= 3 and abs(bl[2].start - 70) <= 3


def test_walking_is_steps_at_walking_cadence_with_soft_impacts():
    from barpath.pattern_blocks import walking_seconds
    times = np.arange(6.0)
    F = np.zeros((6, 11))
    F[:, 10] = [0.0, 1.6, 1.8, 2.8, 1.7, 1.5]      # steps/s
    F[:, 2] = [0.2, 0.7, 0.8, 2.6, 2.3, 0.6]       # g, 90th percentile impact
    # still / walk / walk / run / arm swings with hard impacts (wall balls) / walk
    assert list(walking_seconds(times, F)) == [False, True, True, False, False, True]
    # with Crown taps: only near a tap (box step-ups look like walking)
    assert list(walking_seconds(times, F, hints=[1.0], cfg=Config(walk_near_hint=1.5))) == \
        [False, True, True, False, False, False]
