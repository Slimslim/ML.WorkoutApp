"""Clean catches from the forearm (data/labels/2026-11-14-clean-warmup.json).

In a clean the forearm goes from hanging along the body to the front rack: the watch's x axis
flips and stays there while the bar sits on the shoulders. A catch = the moment the smoothed
gravity x component crosses `level` into the rack and stays at least `hold` seconds.

Orientation: tuned on a watch worn on the left wrist with the Crown on the left (rack = gx > 0.6).
Recordings loaded with load_session_csv are already in the canonical frame (barpath.orientation),
so the default sign=+1 works for every watch; `sign=-1` is only for raw tester-B-style frames.
Known false catches: raising the wrist to read the watch, handling plates; `hold` filters the
short ones, not all.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List

import numpy as np


@dataclass(frozen=True)
class CatchConfig:
    level: float = 0.6       # smoothed gravity x (g) above which the forearm is in the rack
    hold: float = 0.5        # s the rack must last to count
    smooth: float = 0.1      # s moving-average window on gravity x
    gap: float = 0.8         # s minimum between two catches
    sign: int = 1            # +1: rack is +x (canonical frame); -1: a raw Crown-toward-hand frame


def detect_catches(t: np.ndarray, gravity: np.ndarray, config: CatchConfig = CatchConfig()) -> List[float]:
    """Times (same clock as `t`) at which the forearm enters the front rack and holds it."""
    t = np.asarray(t, dtype=float)
    if len(t) < 3:
        return []
    dt = float(np.median(np.diff(t)))
    n = max(1, int(round(config.smooth / dt)))
    gx = config.sign * np.asarray(gravity, dtype=float)[:, 0]
    # Moving average padded with the edge values, so a recording that starts in the rack does not
    # look like it enters the rack at its first sample.
    gx = np.convolve(np.pad(gx, (n // 2, n - 1 - n // 2), mode="edge"), np.ones(n) / n, mode="valid")
    rack = gx > config.level
    out: List[float] = []
    i = 1
    while i < len(t):
        if rack[i] and not rack[i - 1]:
            j = i
            while j < len(t) and rack[j]:
                j += 1
            if t[j - 1] - t[i] >= config.hold and (not out or t[i] - out[-1] >= config.gap):
                out.append(float(t[i]))
            i = j
        else:
            i += 1
    return out


def match(truth: List[float], found: List[float], tol: float = 0.5) -> dict:
    """One-to-one matching within `tol` seconds: hits, misses, false catches."""
    used = set()
    hits = 0
    for x in truth:
        best = None
        for k, y in enumerate(found):
            if k not in used and abs(y - x) <= tol and (best is None or abs(y - x) < abs(found[best] - x)):
                best = k
        if best is not None:
            used.add(best)
            hits += 1
    return {"hits": hits, "misses": len(truth) - hits, "false": len(found) - len(used)}
