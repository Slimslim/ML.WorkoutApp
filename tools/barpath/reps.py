"""Rep counting for strength lifts where the hands hold the bar (deadlift first).

Offline, on a stretch of 200 Hz device motion (a set). Simple, port-friendly filters
(centred moving averages; the Swift RepCounter mirrors this exactly):
1. vertical acceleration a_up = +(userAccel·ĝ)·G (physical sign, spec §4);
2. low-pass: centred moving average over `smooth` s; integrate (trapezoid) to velocity;
3. high-pass: subtract a centred moving average of the velocity over `detrend` s;
4. candidate reps = local velocity maxima ≥ minPeakVelocity, picked greedily by height with
   ≥ minRepInterval between them;
5. each candidate's concentric phase runs between the zero crossings around its peak; its
   range of motion = ∫v over it. Keep it if ROM ≥ minRange and the forearm hangs
   (|ĝ.x| ≥ armHangMin) at the top (bar held at arm's length).
Validated on the 2026-10-29 deadlift sets (275 / 300 lb × 6, filmed): 6/6 and 6/6, rep times
match the video, ROM within ~0–12 cm of the video's 56–61 cm (first/last rep read low).
"""
from dataclasses import dataclass, field
from typing import List

import numpy as np

from .geometry import G


@dataclass(frozen=True)
class RepConfig:
    smooth: float = 0.15          # s, low-pass moving average on vertical accel
    detrend: float = 3.0          # s, moving average removed from velocity (high-pass)
    minPeakVelocity: float = 0.2  # m/s
    minRepInterval: float = 1.2   # s
    minRange: float = 0.30        # m, concentric range of motion
    armHangMin: float = 0.8       # |ĝ.x| at the top of the rep (arms hanging)


@dataclass
class Rep:
    start: float         # s, start of the concentric (upward) phase
    peak: float          # s, time of peak upward velocity
    end: float           # s, top of the rep
    range: float         # m
    meanVelocity: float  # m/s, mean concentric velocity
    peakVelocity: float  # m/s


@dataclass
class RepAnalysis:
    reps: List[Rep] = field(default_factory=list)
    rejected: List[Rep] = field(default_factory=list)  # candidates failing the ROM / arm checks

    @property
    def count(self) -> int:
        return len(self.reps)

    @property
    def velocityLoss(self) -> float:
        """Fractional drop in mean concentric velocity from the faster of the first two reps
        to the last rep (0.25 = the last rep was 25 % slower)."""
        if len(self.reps) < 2:
            return 0.0
        best = max(r.meanVelocity for r in self.reps[:2])
        return (best - self.reps[-1].meanVelocity) / best if best > 0 else 0.0


def moving_average(x: np.ndarray, width: int) -> np.ndarray:
    """Centred moving average; the window shrinks at the edges (mean of what exists)."""
    x = np.asarray(x, float)
    n = len(x)
    w = max(1, int(width))
    h = w // 2
    c = np.concatenate([[0.0], np.cumsum(x)])
    lo = np.clip(np.arange(n) - h, 0, n)
    hi = np.clip(np.arange(n) + h + 1, 0, n)
    return (c[hi] - c[lo]) / (hi - lo)


def vertical_velocity(t, user_accel, gravity, cfg: RepConfig = RepConfig()):
    t = np.asarray(t, float)
    fs = 1.0 / float(np.median(np.diff(t)))
    ghat = gravity / np.linalg.norm(gravity, axis=1)[:, None]
    a_up = np.sum(user_accel * ghat, axis=1) * G
    a_lp = moving_average(a_up, int(round(cfg.smooth * fs)))
    v = np.concatenate([[0.0], np.cumsum(0.5 * (a_lp[1:] + a_lp[:-1]) * np.diff(t))])
    v = v - moving_average(v, int(round(cfg.detrend * fs)))
    return v, ghat


def count_reps(t, user_accel, gravity, cfg: RepConfig = RepConfig()) -> RepAnalysis:
    t = np.asarray(t, float)
    out = RepAnalysis()
    if len(t) < 50:
        return out
    v, ghat = vertical_velocity(t, user_accel, gravity, cfg)
    fs = 1.0 / float(np.median(np.diff(t)))
    min_gap = int(round(cfg.minRepInterval * fs))
    cand = [i for i in range(1, len(v) - 1)
            if v[i] >= cfg.minPeakVelocity and v[i] >= v[i - 1] and v[i] > v[i + 1]]
    cand.sort(key=lambda i: (-v[i], i))
    picked: List[int] = []
    for i in cand:
        if all(abs(i - j) >= min_gap for j in picked):
            picked.append(i)
    picked.sort()
    for i in picked:
        s = i
        while s > 0 and v[s - 1] > 0:
            s -= 1
        e = i
        while e < len(v) - 1 and v[e + 1] > 0:
            e += 1
        if e <= s:
            continue
        rom = float(np.sum(0.5 * (v[s + 1:e + 1] + v[s:e]) * np.diff(t[s:e + 1])))
        dur = float(t[e] - t[s])
        rep = Rep(start=float(t[s]), peak=float(t[i]), end=float(t[e]), range=rom,
                  meanVelocity=rom / dur if dur > 0 else 0.0, peakVelocity=float(v[i]))
        ok = rom >= cfg.minRange and abs(ghat[e, 0]) >= cfg.armHangMin
        (out.reps if ok else out.rejected).append(rep)
    return out


@dataclass
class SetTracker:
    """Live strength-mode tracker (mirrors BarPathKit SetTracker): feed ~1 s batches; a rep is
    confirmed once its top is `settle` s old; `setEndGap` s without a new rep ends the set."""
    cfg: RepConfig = RepConfig()
    setEndGap: float = 6.0
    preRoll: float = 3.0
    postRoll: float = 2.0
    idleHistory: float = 20.0
    maxHistory: float = 90.0

    def __post_init__(self):
        self.live: List[Rep] = []
        self.idx = np.zeros(0, int)   # indices into the session arrays
        self.floor = -np.inf

    @property
    def settle(self):
        return self.cfg.detrend / 2 + 0.3

    def process(self, t, ua, g, new_idx):
        """`new_idx`: indices of this batch in the session arrays. Returns events."""
        new_idx = new_idx[t[new_idx] >= self.floor]
        self.idx = np.concatenate([self.idx, new_idx])
        if len(self.idx) == 0:
            return []
        latest = t[self.idx[-1]]
        keep = max(self.floor, latest - (self.maxHistory if self.live else self.idleHistory))
        if self.live:
            keep = min(keep, max(self.floor, self.live[0].start - self.preRoll))
            keep = max(keep, latest - self.maxHistory)
        self.idx = self.idx[t[self.idx] >= keep]
        ev = []
        i = self.idx
        reps = count_reps(t[i], ua[i], g[i], self.cfg).reps
        conf = [r for r in reps if r.end <= latest - self.settle]
        if len(conf) > len(self.live):
            ev.append(("rep", len(conf), latest))
        if len(conf) >= len(self.live):
            self.live = conf
        if self.live and latest - self.live[-1].end >= self.setEndGap:
            ev.append(self._finish())
        return ev

    def flush(self, t, ua, g):
        if len(self.idx):
            i = self.idx
            reps = count_reps(t[i], ua[i], g[i], self.cfg).reps
            if len(reps) > len(self.live):
                self.live = reps
        return self._finish() if self.live else None

    def _finish(self):
        reps = self.live
        self.live = []
        self.floor = reps[-1].end + self.postRoll
        return ("set", reps[0].start - self.preRoll, reps[-1].end + self.postRoll, reps)
