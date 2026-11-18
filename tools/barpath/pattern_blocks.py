"""Movement blocks from the whole recording, after the workout (owner's idea, 2026-11-18).

Every movement repeats a pattern (pedalling, throws, sit-ups, strides). Looked at afterwards, a
workout is a chain of pattern blocks in the order of the plan; a pause inside a block and a return
to the same pattern is a rest inside the movement, and the time between the end of one pattern and
the start of the next is the transition. Nothing is trained: each workout teaches itself (round 2's
bike looks like round 1's), so it works with the little data we have.

Input: the motion and the movements in the order they were done, planned rests included as "rest"
(a timed rest's window comes from the watch's timer: `fixed`, exact) (the plan unrolled with the
athlete's score: an AMRAP of 6 rounds + 1 bike calorie is 6 x [bike, step-ups, wall balls] + bike).
Output: for every movement its first and last moment of pattern, and the gaps in between.

How: one feature vector per second (4 s of motion around it: effort, arm angle, rotation, rhythm
strength and period, step rate). Hidden states, left to right: for each movement in order a
`work` state and a `pause` state after it (rest inside the movement, or the transition to the next
one). Each movement's pattern (a diagonal Gaussian over the features, shared by every round of that
movement) and one shared pause pattern are estimated from the workout itself: start from an even
split of the time, align (Viterbi), re-estimate, repeat. Switching movement and entering / leaving
a pause cost a fixed penalty, so a block does not flicker.

The order repeats (bike, step-ups, wall balls, bike, ...), so on motion alone the whole chain can
fit one movement off (right boundaries, wrong names). `hints` (the athlete's Crown taps, by position:
the k-th tap = the switch into movement k) anchor it: that switch is cheaper near its tap, never
required, so a late tap only loses its pull (a forgotten one shifts the later hints: to handle).

Walking is part of the transition (owner, 2026-11-18): the pause after a movement is standing
still or walking, whichever fits the second. Walking = steps at 1-2.3 per second with soft impacts
(90th percentile of |userAccel| < 1.3 g); running is 2.5-3.2 steps/s with 2.4-3 g, and a planned run
stays a movement. Box step-ups and lunges look like walking, so the transition INTO a stepping
movement is standing only (walking there would eat the first steps), and walking is learned from
step-like seconds near the other Crown taps, where transitions happen.

Experimental (not on the watch, not in the app): scored by tools/score_pattern_blocks.py.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence

import numpy as np

import re

FS = 100.0
# movements that are themselves steps: walking next to them is not a transition
REST = "rest"     # a planned (timed) rest in the order: a block of standing / walking, no pattern
STEPPING = re.compile(r"step|lunge|carry|walk|sled|ruck|farmer", re.I)
HOP = 1.0        # s between feature vectors
WINDOW = 4.0     # s of motion per feature vector


@dataclass
class Config:
    switch_cost: float = 25.0    # moving on to the next movement
    pause_cost: float = 8.0      # entering or leaving a pause
    iterations: int = 8
    restarts: int = 24           # starting splits tried (the first one even)
    seed: int = 0
    calm_pct: float = 15.0       # % of the calmest seconds (by effort) that define a pause
    min_work: float = 5.0
    walk_steps: tuple = (1.0, 2.3)   # steps/s of walking; running is 2.5-3.2 with 2.4-3 g impacts
    walk_impact: float = 1.3     # g, 90th percentile of |userAccel| below which steps are walking
    walk_near_hint: float = 20.0  # s: walking is learned from step-like seconds this close to a tap
    walking: bool = True         # walking is part of the transition, not of a movement (a run stays a movement)
    hint_bonus: float = 15.0     # switch made cheaper near a Crown tap (a hint, never required)
    hint_sigma: float = 15.0     # s        # s of pattern before a movement can pause or end
    var_floor: float = 0.05      # in units of the whole workout's variance (features are z-scored)


@dataclass
class Block:
    movement: str
    index: int                   # position in the order
    start: float                 # first second of pattern (session seconds)
    end: float                   # last second of pattern
    work: float                  # seconds of pattern inside (pauses removed)
    pauses: List[tuple]          # rests inside the movement: [(start, end)]
    walk_after: float = 0.0      # s of walking between this block's end and the next block's start


def features(motion, steps=None, hop: float = HOP, window: float = WINDOW):
    """(times, F): one row per `hop` seconds: |userAccel| mean, SD, p90; gravity mean x, y, z and
    mean SD; |rotation| mean; rhythm strength (best autocorrelation of |userAccel| at 0.4-5 s) and
    its period; step rate (steps/s, 0 without a pedometer)."""
    t = motion.t
    acc = np.linalg.norm(motion.user_accel, axis=1)
    rot = np.linalg.norm(motion.rotation_rate, axis=1)
    g = motion.gravity
    times = np.arange(t[0] + window / 2, t[-1] - window / 2 + 1e-9, hop) if len(t) else np.zeros(0)
    rows = []
    for tc in times:
        i0, i1 = np.searchsorted(t, [tc - window / 2, tc + window / 2])
        if i1 - i0 < 50:
            rows.append(np.full(11, np.nan))
            continue
        a = acc[i0:i1]
        G = g[i0:i1]
        strength, period = _rhythm(a[::2], FS / 2)
        rate = 0.0
        if steps is not None and len(steps[0]) > 1:
            st, sv = steps
            rate = float(np.interp(tc + window / 2, st, sv) - np.interp(tc - window / 2, st, sv)) / window
        rows.append(np.r_[a.mean(), a.std(), np.percentile(a, 90), G.mean(0), G.std(0).mean(),
                          rot[i0:i1].mean(), strength, np.log(period), rate])
    F = np.array(rows).reshape(len(rows), 11)
    # fill short holes (sampling gaps) with the nearest row
    bad = np.isnan(F).any(1)
    if bad.any() and (~bad).any():
        good = np.flatnonzero(~bad)
        for i in np.flatnonzero(bad):
            F[i] = F[good[np.argmin(np.abs(good - i))]]
    return times, F


def _rhythm(a: np.ndarray, fs: float):
    z = a - a.mean()
    den = float((z * z).sum())
    lo, hi = int(0.4 * fs), min(int(5 * fs), len(z) - 2)
    if den < 1e-9 or hi <= lo:
        return 0.0, 1.0
    ac = np.correlate(z, z, "full")[len(z) - 1:] / den
    k = lo + int(np.argmax(ac[lo:hi]))
    return float(ac[k]), k / fs


def align(times, F, order: Sequence[str], cfg: Config = Config(), hints: Sequence[Optional[float]] = (),
          fixed: Optional[dict] = None):
    """State per row: 2k = work of movement k, 2k + 1 = pause after it. EM from several starting
    splits of the time: each movement gets one random share of the time, the same in every round
    (the order repeats, so a bad start can lock in one movement off); the path that explains the
    workout best (lowest total cost) wins."""
    T, K = len(times), len(order)
    mu, sd = np.nanmean(F, 0), np.nanstd(F, 0) + 1e-9
    Z = (F - mu) / sd
    low = Z[:, 0] < np.percentile(Z[:, 0], 20)
    # fixed[k] = (start, end): a timed rest the watch's own timer ran, so its window is known exactly:
    # inside it only that rest, outside it never
    pin = None
    if fixed:
        pin = np.zeros((T, 2 * K))
        for k, (a, b) in fixed.items():
            inside = (times >= a) & (times < b)
            pin[inside, :] += 1e6
            pin[inside, 2 * k] -= 1e6
            pin[~inside, 2 * k] += 1e6
            pin[:, 2 * k + 1] += 1e6
    walk = None
    if cfg.walking:
        # learn walking only near taps between two movements that are not steps themselves
        clean = [h if (h is not None and not STEPPING.search(order[k])) else None
                 for k, h in enumerate(hints[: K - 1], start=1)]
        walk = walking_seconds(times, F, cfg, clean if any(c is not None for c in clean) else ())
    # hints[k - 1]: when the athlete marked the switch into movement k (the k-th Crown tap). The
    # order repeats, so a hint has to say WHICH switch it is, not only when
    bonus = np.zeros((T, K))
    for k, h in enumerate(hints[: K - 1], start=1):
        if h is not None:
            bonus[:, k] = cfg.hint_bonus * np.exp(-0.5 * ((times - h) / cfg.hint_sigma) ** 2)
    rng = np.random.default_rng(cfg.seed)
    best, best_cost = None, np.inf
    taps = list(hints[: K - 1])
    from_taps = len(taps) == K - 1 and all(h is not None for h in taps) and all(np.diff(taps) > 0)
    for r in range(cfg.restarts + int(from_taps)):
        if from_taps and r == cfg.restarts:
            # one more start: the athlete's own Crown splits (the motion then moves them)
            state = np.searchsorted(np.array(taps), times, side="right") * 2 + low
        else:
            # one share of time per movement, repeated every round it appears in
            moves = sorted(set(order))
            share = np.ones(len(moves)) if r == 0 else rng.dirichlet(np.ones(len(moves)))
            w = np.array([share[moves.index(m)] for m in order])
            edges = np.r_[0, np.cumsum(w) / w.sum()] * T
            state = np.clip(np.searchsorted(edges, np.arange(T), side="right") - 1, 0, K - 1) * 2 + low
        state, cost = _em(Z, state, order, cfg, bonus, walk, pin)
        if cost < best_cost:
            best, best_cost = state, cost
    return best


def walking_seconds(times, F, cfg: Config = Config(), hints: Sequence[Optional[float]] = ()):
    """Seconds that look like walking: steps at walking cadence with soft impacts (running has
    more steps and much harder impacts). Box step-ups look the same, so with Crown taps only the
    step-like seconds near a tap (where transitions happen) are kept."""
    steps, impact = F[:, 10], F[:, 2]
    walk = (steps >= cfg.walk_steps[0]) & (steps < cfg.walk_steps[1]) & (impact < cfg.walk_impact)
    taps = [h for h in hints if h is not None]
    if taps:
        near = np.min(np.abs(times[:, None] - np.array(taps)[None, :]), 1) <= cfg.walk_near_hint
        walk &= near
    return walk


def _em(Z, state, order, cfg, bonus=None, walk=None, pin=None):
    T, K = len(Z), len(order)
    moves = sorted(set(order) - {REST})
    mid = {m: i for i, m in enumerate(moves)}
    calm = Z[:, 0] < np.percentile(Z[:, 0], cfg.calm_pct)
    cost = np.inf
    for _ in range(cfg.iterations):
        nll = np.zeros((T, len(moves) + 1))
        for i in range(len(moves) + 1):
            if i == len(moves):
                # the pause pattern is learned once, from the calmest moments of this workout, and
                # kept: re-estimated, it can swallow a whole low-effort movement (step-ups) and
                # shift every block by one
                sel = calm
            else:
                ks = [k for k, x in enumerate(order) if mid.get(x) == i]
                sel = np.isin(state // 2, ks) & (state % 2 == 0)
            X = Z[sel] if sel.sum() >= 3 else Z
            mean, var = X.mean(0), np.maximum(X.var(0), cfg.var_floor)
            nll[:, i] = 0.5 * (((Z - mean) ** 2) / var + np.log(var)).sum(1)
        gap = nll[:, len(moves)]
        if walk is not None and walk.sum() >= 5:
            # a transition is standing still OR walking: the gap takes whichever fits the second
            X = Z[walk]
            mean, var = X.mean(0), np.maximum(X.var(0), cfg.var_floor)
            gap = np.minimum(gap, 0.5 * (((Z - mean) ** 2) / var + np.log(var)).sum(1))
        emis = np.empty((T, 2 * K))
        for k, m in enumerate(order):
            if m == REST:
                emis[:, 2 * k] = emis[:, 2 * k + 1] = gap
                continue
            emis[:, 2 * k] = nll[:, mid[m]]
            nxt = order[k + 1] if k + 1 < K else ""
            stepping = bool(STEPPING.search(nxt))     # walking there would eat the steps' start
            emis[:, 2 * k + 1] = nll[:, len(moves)] if stepping else gap
        if pin is not None:
            emis = emis + pin
        new, cost = _viterbi(emis, K, cfg, bonus)
        if np.array_equal(new, state):
            break
        state = new
    return state, cost


def _viterbi(emis: np.ndarray, K: int, cfg: Config, bonus=None):
    """Left-to-right path with a minimum work time per movement: work k is a chain of D states
    (D = min_work rows) before it may pause or move on. Returns (2k / 2k + 1 per row, total cost)."""
    T = len(emis)
    D = max(1, int(round(cfg.min_work / HOP)))
    # expanded states: movement k -> work chain k*(D+1) .. k*(D+1)+D-1, pause k*(D+1)+D
    S = K * (D + 1)
    w0 = lambda k: k * (D + 1)
    wl = lambda k: k * (D + 1) + D - 1
    ps = lambda k: k * (D + 1) + D
    src = [[] for _ in range(S)]
    for k in range(K):
        for j in range(1, D):
            src[w0(k) + j].append((w0(k) + j - 1, 0.0))
        src[wl(k)].append((wl(k), 0.0))
        src[wl(k)].append((ps(k), cfg.pause_cost))
        src[ps(k)].append((ps(k), 0.0))
        src[ps(k)].append((wl(k), cfg.pause_cost))
        if k:
            src[w0(k)].append((wl(k - 1), cfg.switch_cost))
            src[w0(k)].append((ps(k - 1), cfg.switch_cost))
    n = max(len(x) for x in src)
    SW = np.zeros((S, n))
    kof = np.arange(S) // (D + 1)
    SRC = np.zeros((S, n), dtype=np.int64)
    C = np.full((S, n), np.inf)
    for i, lst in enumerate(src):
        for j, (a, c) in enumerate(lst):
            SRC[i, j], C[i, j] = a, c
            SW[i, j] = float(c == cfg.switch_cost and i % (D + 1) == 0 and i > 0)
    kind = np.empty(S, dtype=np.int64)      # back to the 2K compact states
    for k in range(K):
        kind[w0(k):w0(k) + D] = 2 * k
        kind[ps(k)] = 2 * k + 1
    E = emis[:, kind]
    cost = np.full(S, np.inf)
    cost[0] = E[0, 0]
    back = np.zeros((T, S), dtype=np.int64)
    rows = np.arange(S)
    for t in range(1, T):
        cand = cost[SRC] + C
        if bonus is not None:
            cand = cand - SW * bonus[t, kof][:, None]
        j = np.argmin(cand, 1)
        back[t] = SRC[rows, j]
        cost = cand[rows, j] + E[t]
    end = list(range(w0(K - 1), ps(K - 1) + 1))   # the last movement may be cut short by the clock
    last = end[int(np.argmin(cost[end]))]
    total = float(cost[last])
    path = np.empty(T, dtype=np.int64)
    path[-1] = last
    for t in range(T - 1, 0, -1):
        path[t - 1] = back[t, path[t]]
    return kind[path], total


def blocks(motion, order: Sequence[str], steps=None, cfg: Config = Config(),
           hints: Sequence[Optional[float]] = (), fixed: Optional[dict] = None) -> List[Block]:
    """One Block per movement in `order` (None-free: a movement the path skipped gets a 0 s block
    at the end of the previous one)."""
    times, F = features(motion, steps)
    state = align(times, F, order, cfg, hints, fixed)
    walking = walking_seconds(times, F, cfg)
    out: List[Block] = []
    for k, m in enumerate(order):
        w = times[state == 2 * k]
        if len(w) == 0:
            t0 = out[-1].end if out else float(times[0])
            out.append(Block(m, k, t0, t0, 0.0, []))
            continue
        start, end = float(w[0] - HOP / 2), float(w[-1] + HOP / 2)
        inside = (times > start) & (times < end) & (state == 2 * k + 1)
        out.append(Block(m, k, start, end, len(w) * HOP, _runs(times, inside)))
    for a, b in zip(out, out[1:]):
        a.walk_after = float(((times > a.end) & (times < b.start) & walking).sum() * HOP)
    return out


def _runs(times, mask) -> List[tuple]:
    out, i = [], 0
    n = len(mask)
    while i < n:
        if mask[i]:
            j = i
            while j + 1 < n and mask[j + 1]:
                j += 1
            out.append((float(times[i] - HOP / 2), float(times[j] + HOP / 2)))
            i = j + 1
        else:
            i += 1
    return out
