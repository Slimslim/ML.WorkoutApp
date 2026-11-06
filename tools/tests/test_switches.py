"""barpath.switches (plan-aware switch detector v0) on synthetic motion: two movements with
different arm angles and rhythm, alternating, the first round known."""
import numpy as np

from barpath import switches as SW
from barpath.recording import MotionSeries

FS = 100.0
RNG = np.random.default_rng(3)


def alternating(n_rounds=6, a_len=10.0, b_len=15.0):
    """A: arm overhead (gravity x +0.9), 1 Hz pumping. B: arm down (gravity x -0.9), 0.5 Hz."""
    parts, segs, t0 = [], [], 0.0
    for r in range(n_rounds):
        for mv, dur, gx, f in (("A", a_len, 0.9, 1.0), ("B", b_len, -0.9, 0.5)):
            n = int(dur * FS)
            t = t0 + np.arange(n) / FS
            g = np.tile([gx, 0.0, -0.43], (n, 1)) + 0.02 * RNG.standard_normal((n, 3))
            ua = np.zeros((n, 3))
            ua[:, 0] = 0.6 * np.sin(2 * np.pi * f * t) + 0.05 * RNG.standard_normal(n)
            parts.append((t, ua, g))
            segs.append({"movement": mv, "round": r + 1, "start": t0, "end": t0 + dur})
            t0 += dur
    t = np.concatenate([p[0] for p in parts])
    ua = np.concatenate([p[1] for p in parts])
    g = np.concatenate([p[2] for p in parts])
    n = len(t)
    return MotionSeries(t, np.zeros((n, 4)), ua, g, np.zeros((n, 3))), segs


def test_finds_every_switch_after_round_one():
    motion, segs = alternating()
    known = [s for s in segs if s["round"] == 1]
    found = SW.detect(motion, ["A", "B"], known)
    truth = [s["start"] for s in segs if s["round"] > 1] + [s["start"] for s in segs if s["round"] == 1][1:]
    truth = sorted(t for t in truth if t > known[-1]["end"] - 1e-9)
    assert len(found) == len(truth)
    assert max(abs(f - t) for f, t in zip(found, truth)) < 3.0


def test_round1_helper_reads_a_label():
    label = {"segments": [{"movement": "run", "start": 0, "end": 500},
                          {"movement": "pullUps", "round": 1, "start": 500, "end": 506},
                          {"movement": "pushUps", "round": 1, "start": 506, "end": 520},
                          {"movement": "rest", "round": 1, "start": 520, "end": 530},
                          {"movement": "pullUps", "round": 2, "start": 530, "end": 536}]}
    plan, known = SW.round1(label)
    assert plan == ["pullUps", "pushUps"]
    assert [s["movement"] for s in known] == ["run", "pullUps", "pushUps", "rest"]
