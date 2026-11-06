"""Plan-aware movement switch detector, v0 (docs/LABELS.md, "Phase 1: switches").

The watch knows the workout plan, so after a movement it only has to decide, every 0.5 s:
"still the current movement, resting, or has the next planned movement started?"

v0 learns the athlete's movements inside the workout: round 1 is known (the athlete turns the
Crown; in the eval it comes from the label), every later window is compared with round 1's
windows (k nearest neighbours on 3 s motion summaries) among {current, next, rest} only. A
switch fires when the next movement wins for `sustain` seconds, and not before `dwell` x the time
the current movement took in round 1 (a 15 cal bike cannot end after 10 s).

Frozen on 2026-11-06 after tuning on two sessions (AMRAP 20, November challenge): its scores
there are optimistic. Later sessions are the real test (tools/score_labels.py --record).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence

import numpy as np

FS = 100.0
VERSION = "switch-v0"


@dataclass
class Config:
    window: float = 3.0     # s of motion per summary
    hop: float = 0.5        # s between decisions
    k: int = 7              # neighbours
    sustain: float = 2.5    # s the next movement must win before the switch fires
    dwell: float = 0.5      # x round-1 duration of the current movement before a switch is allowed


def window_features(motion, t_end: Sequence[float], window: float) -> List[Optional[np.ndarray]]:
    """12 numbers per window ending at each t_end: gravity mean / SD (arm angle), |userAccel|
    mean / SD / p90 (effort), rotation mean / SD, dominant rhythm 0.25-4 Hz. None when the
    window has under 0.5 s of samples."""
    t = motion.t
    acc = np.linalg.norm(motion.user_accel, axis=1)
    rot = np.linalg.norm(motion.rotation_rate, axis=1)
    g = motion.gravity
    out: List[Optional[np.ndarray]] = []
    for te in t_end:
        i0, i1 = np.searchsorted(t, [te - window, te])
        if i1 - i0 < 50:
            out.append(None)
            continue
        a = acc[i0:i1]
        G = g[i0:i1]
        spec = np.abs(np.fft.rfft(a - a.mean()))
        freq = np.fft.rfftfreq(len(a), 1 / FS)
        band = (freq > 0.25) & (freq < 4)
        dom = freq[band][np.argmax(spec[band])] if band.any() else 0.0
        out.append(np.r_[G.mean(0), G.std(0), a.mean(), a.std(), np.percentile(a, 90),
                         rot[i0:i1].mean(), rot[i0:i1].std(), dom])
    return out


def detect(motion, plan: Sequence[str], known: Sequence[dict], cfg: Config = Config()) -> List[float]:
    """Switch times (session seconds) after the known part.

    plan   working movements in order, repeating (["airBike", "boxStepUps", "wallBalls"]).
    known  the segments already known (round 1): [{movement, start, end}], rest allowed. The
           detector starts in the last working movement of `known`, at its end.
    """
    if not known or len(plan) < 2:
        return []
    known_end = max(s["end"] for s in known)
    t_end = np.arange(cfg.window, float(motion.t[-1]), cfg.hop)
    feats = window_features(motion, t_end, cfg.window)

    def label_at(c: float) -> Optional[str]:
        for s in known:
            if s["start"] <= c < s["end"]:
                return "rest" if s["movement"] in ("rest", "transition") else s["movement"]
        return None

    rows = [(t, f) for t, f in zip(t_end, feats) if f is not None]
    T = np.array([t for t, _ in rows])
    X = np.array([f for _, f in rows])
    train = T <= known_end
    Y = np.array([label_at(t - cfg.window / 2) if tr else None for t, tr in zip(T, train)], dtype=object)
    train &= Y != None  # noqa: E711 (numpy elementwise)
    if not train.any():
        return []
    mu = X[train].mean(0)
    sd = X[train].std(0) + 1e-6
    Xn = (X - mu) / sd

    work = [s for s in known if s["movement"] not in ("rest", "transition")]
    dur: dict = {}
    for s in work:
        dur[s["movement"]] = dur.get(s["movement"], 0.0) + s["end"] - s["start"]
    cur = work[-1]["movement"]
    if cur not in plan:
        return []

    def nxt(c: str) -> str:
        return plan[(plan.index(c) + 1) % len(plan)]

    last = work[-1]["start"]          # when the current movement started
    run_start: Optional[float] = None
    switches: List[float] = []
    for i in np.where(T > known_end)[0]:
        cand = [cur, nxt(cur), "rest"]
        mask = train & np.isin(Y.astype(str), cand)
        if not mask.any():
            continue
        dist = np.linalg.norm(Xn[mask] - Xn[i], axis=1)
        nn = np.argsort(dist)[: cfg.k]
        vals, cnt = np.unique(Y[mask][nn].astype(str), return_counts=True)
        p = vals[int(np.argmax(cnt))]
        if p == nxt(cur) and T[i] - cfg.window / 2 - last >= cfg.dwell * dur.get(cur, 0.0):
            if run_start is None:
                run_start = float(T[i])
            if T[i] - run_start >= cfg.sustain:
                switches.append(run_start - cfg.window / 2)
                cur = p
                last = run_start - cfg.window / 2
                run_start = None
        else:
            run_start = None
    return switches


def round1(label: dict):
    """(plan, known segments) from a label with rounds: round 1 as the known part."""
    r1 = [s for s in label["segments"] if s.get("round") == 1]
    plan = [s["movement"] for s in r1 if s["movement"] not in ("rest", "transition")]
    first = label["segments"].index(r1[0]) if r1 else 0
    known = label["segments"][: first + len(r1)] if r1 else []
    return plan, known
