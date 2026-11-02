#!/usr/bin/env python3
"""AMRAP 40 (2026-11-01) first look: can we count reps / find work bouts / tell movements apart
from left-wrist device motion alone?

    python3 tools/scratch/amrap40_reps.py [data/raw/2026-11-01-amrap40]

Prints markdown tables (copied into data/raw/2026-11-01-amrap40/ANALYSIS.md).

Inputs: session-*.csv (100 Hz CMDeviceMotion, t = s since startDate) and workout-*.json (segment
start/end in epoch seconds, the Crown presses). Labels come from the owner (README.md): odd rounds
row / push-ups 3x5 / DB clean & jerk / burpees, even rounds bike / pull-ups / alt. DB snatch /
wall walks. Every segment begins with the transition (walking to the next station) because the
Crown is pressed when the previous movement ends.

Signals (device frame, g):
  vert = -(userAccel . gravity)  vertical acceleration (+ = up), band-passed
  gx/gy/gz = gravity components (wrist orientation; gx > 0 = forearm pointing up / hand overhead)
  rot = |rotationRate| (rad/s)

Two families of counters:
  * generic: dominant period by autocorrelation, then local maxima >= 0.6 period apart and above
    mean + 0.5 SD. Applied blindly to the whole Crown segment (what a movement-agnostic counter
    would do) and to the detected work window.
  * specific: one rule per movement, built from what the wrist actually does (below). These are
    fitted on this one session: treat the accuracy as training accuracy.

numpy only (filters are FFT brick-wall, offline). Uses barpath.recording.load_session_csv; runs
barpath.segments.bar_hangs on the pull-up segments for comparison (it finds no hang: see pullup_reps).
"""
from __future__ import annotations

import glob
import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from barpath.recording import load_session_csv  # noqa: E402
from barpath.segments import bar_hangs  # noqa: E402

FS = 100.0
ODD = ("row", "pushup", "cj", "burpee", "rest")
EVEN = ("bike", "pullup", "snatch", "wallwalk", "rest")
TRUTH = {"pushup": 15, "pullup": 6, "cj": 12, "snatch": 12, "burpee": 15, "wallwalk": 3}
# plausible rep period (s) searched by the generic counter
PERIOD_RANGE = {"row": (1.5, 4.0), "bike": (0.6, 2.0), "pushup": (0.8, 3.0), "pullup": (1.2, 5.0),
                "cj": (2.0, 8.0), "snatch": (1.5, 6.0), "burpee": (3.0, 10.0), "wallwalk": (8.0, 25.0)}


# ---- loading ------------------------------------------------------------------------------

def load(folder):
    folder = Path(folder)
    csv = load_session_csv(glob.glob(str(folder / "session-*.csv"))[0])
    wk = json.load(open(glob.glob(str(folder / "workout-*.json"))[0]))
    t0 = csv.start_date.timestamp()
    segs = []
    for s in wk["segments"]:
        i = s["index"]
        rnd = i // 5 + 1
        mv = (ODD if rnd % 2 else EVEN)[i % 5]
        segs.append({"index": i, "round": rnd, "movement": mv,
                     "start": s["start"] - t0, "end": s["end"] - t0})
    return csv.motion, segs


# ---- filters / primitives -------------------------------------------------------------------

def bandpass(x, lo, hi, fs=FS):
    """Zero-phase FFT brick-wall band-pass (lo=0: low-pass). Offline analysis only."""
    x = np.asarray(x, float)
    n = len(x)
    mean = x.mean()
    X = np.fft.rfft(x - mean)
    f = np.fft.rfftfreq(n, 1.0 / fs)
    X[(f < lo) | (f > hi)] = 0
    y = np.fft.irfft(X, n)
    return y + (mean if lo <= 0 else 0.0)


def rolling(x, win, fn="sd"):
    """Centered rolling SD / mean / RMS over `win` samples (cumsum, O(n))."""
    x = np.asarray(x, float)
    c1 = np.concatenate([[0], np.cumsum(x)])
    c2 = np.concatenate([[0], np.cumsum(x * x)])
    n = len(x)
    h = win // 2
    lo = np.clip(np.arange(n) - h, 0, n)
    hi = np.clip(np.arange(n) + h + 1, 0, n)
    cnt = hi - lo
    m = (c1[hi] - c1[lo]) / cnt
    if fn == "mean":
        return m
    q = (c2[hi] - c2[lo]) / cnt
    if fn == "rms":
        return np.sqrt(q)
    return np.sqrt(np.maximum(q - m * m, 0))


def acf_period(x, lo_s, hi_s, fs=FS):
    """(period s, autocorrelation at that lag) of the strongest ACF peak in [lo_s, hi_s]."""
    x = np.asarray(x, float) - np.mean(x)
    n = len(x)
    if n < 3 or not np.any(x):
        return float("nan"), 0.0
    F = np.fft.rfft(x, 2 * n)
    ac = np.fft.irfft(F * np.conj(F))[:n]
    ac = ac / ac[0]
    i0, i1 = int(lo_s * fs), min(int(hi_s * fs), n - 2)
    if i1 <= i0 + 2:
        return float("nan"), 0.0
    seg = ac[i0:i1]
    # prefer a true local maximum (avoid the edge of the search range)
    cand = [k for k in range(1, len(seg) - 1) if seg[k] >= seg[k - 1] and seg[k] >= seg[k + 1]]
    k = max(cand, key=lambda j: seg[j]) if cand else int(np.argmax(seg))
    return (i0 + k) / fs, float(seg[k])


def peaks(x, min_dist, height):
    """Indices of local maxima above `height`, greedy by height, >= min_dist samples apart."""
    x = np.asarray(x)
    cand = np.where((x[1:-1] > x[:-2]) & (x[1:-1] >= x[2:]) & (x[1:-1] > height))[0] + 1
    keep = []
    for i in sorted(cand, key=lambda j: -x[j]):
        if all(abs(i - k) >= min_dist for k in keep):
            keep.append(i)
    return sorted(keep)


def hysteresis_rises(x, high, low):
    """Indices where x rises above `high` after having been below `low` (one count per cycle)."""
    out, state = [], None
    for i, v in enumerate(x):
        if v > high and state != "up":
            if state == "down":
                out.append(i)
            state = "up"
        elif v < low and state != "down":
            state = "down"
    return out


def bouts(mask, min_len, merge_gap):
    """[(i0, i1)] runs of True, gaps < merge_gap merged, runs < min_len dropped (samples)."""
    runs, inside, a = [], False, 0
    for i, v in enumerate(mask):
        if v and not inside:
            inside, a = True, i
        elif not v and inside:
            inside = False
            runs.append([a, i])
    if inside:
        runs.append([a, len(mask)])
    merged = []
    for r in runs:
        if merged and r[0] - merged[-1][1] < merge_gap:
            merged[-1][1] = r[1]
        else:
            merged.append(r)
    return [(a, b) for a, b in merged if b - a >= min_len]


# ---- per-segment signals --------------------------------------------------------------------

class Seg:
    def __init__(self, motion, s, pad=0.0):
        t = motion.t
        self.meta = s
        self.i0 = int(np.searchsorted(t, s["start"] - pad))
        self.i1 = int(np.searchsorted(t, s["end"] + pad))
        sl = slice(self.i0, self.i1)
        self.t = t[sl] - s["start"]
        a = motion.user_accel[sl]
        g = motion.gravity[sl]
        r = motion.rotation_rate[sl]
        self.vert = bandpass(-(a * g).sum(1), 0.2, 3.0)
        self.g = np.column_stack([bandpass(g[:, k], 0, 2.0) for k in range(3)])
        self.rot = bandpass(np.linalg.norm(r, axis=1), 0, 3.0)
        self.amag = np.linalg.norm(a, axis=1)
        self.motion = motion

    @property
    def dur(self):
        return self.t[-1] - self.t[0]


# ---- generic periodic-peak counter ----------------------------------------------------------

def generic_count(x, lo_s, hi_s):
    p, c = acf_period(x, lo_s, hi_s)
    if not math.isfinite(p):
        return p, c, 0
    k = peaks(x, int(0.6 * p * FS), x.mean() + 0.5 * x.std())
    return p, c, len(k)


# ---- movement-specific detectors -----------------------------------------------------------

STILL_VERT_SD = 0.04     # g, 1 s rolling SD of vert: below = hand planted / not moving
OVERHEAD_HIGH = 0.7      # gx: forearm pointing up (hand overhead)
OVERHEAD_LOW = -0.3


def trim_rhythm(ts, factor=2.5):
    """Drop leading / trailing events whose gap to the neighbour is > factor x the median gap
    (an arm raise during the walk-over, picking up the dumbbell)."""
    ts = list(ts)
    while len(ts) >= 4:
        gaps = np.diff(ts)
        med = float(np.median(gaps))
        if gaps[0] > factor * med:
            ts = ts[1:]
        elif gaps[-1] > factor * med:
            ts = ts[:-1]
        else:
            break
    return ts


def overhead_rises(S, high=OVERHEAD_HIGH, low=OVERHEAD_LOW):
    """Times gx (forearm axis, 2 Hz low-pass) rises through `high` after having been below `low`:
    the watch forearm going from hanging (gx -1) to vertical (gx +1)."""
    return [float(S.t[i]) for i in hysteresis_rises(S.g[:, 0], high, low)]


def burpee_reps(S):
    """Burpee to target: hands-overhead (gx rise through +0.7) with a landing / jump impulse
    (vert < -1.5 g) within +-2 s. The impulse rejects arm raises while walking or resting."""
    out = []
    for tt in overhead_rises(S):
        j = int(np.searchsorted(S.t, tt))
        if S.vert[max(0, j - int(2 * FS)):j + int(2 * FS)].min() < -1.5:
            out.append(tt)
    return trim_rhythm(out)


def snatch_reps(S):
    """Alternating DB snatch: every rep (either hand) takes the watch forearm to vertical."""
    return trim_rhythm(overhead_rises(S))


def cj_reps(S):
    """Alternating DB clean & jerk: only the watch-hand reps reach a full lockout (gx > 0.9);
    the other-hand reps lift the watch forearm only partly (gx 0.6-0.85). Two counters:
      lockout x 2 (assumes strict alternation)   and   rises through 0.5 (each rep)."""
    lock = trim_rhythm(overhead_rises(S, 0.9, OVERHEAD_LOW))
    every = trim_rhythm(overhead_rises(S, 0.5, OVERHEAD_LOW))
    return lock, every


def pullup_reps(S):
    """Strict pull-ups. Hang = longest run with gx (forearm up) > 0.8 for >= 3 s. The hand is
    clamped to the bar so the wrist barely accelerates (|userAccel| SD 0.19-0.23 g, which is why
    barpath.segments.bar_hangs, gated at SD >= 0.5 for Helen's kipping sets, finds no hang
    here); each pull bends the wrist a little and shows as one slow gy oscillation. Count gy
    (0.15-1.0 Hz) maxima >= 1.5 s apart above the hang mean."""
    bs = bouts(S.g[:, 0] > 0.8, int(3 * FS), int(1 * FS))
    if not bs:
        return [], None
    a, b = max(bs, key=lambda r: r[1] - r[0])
    gy = bandpass(S.g[a:b, 1], 0.15, 1.0)
    k = peaks(gy, int(1.5 * FS), gy.mean())
    return [float(S.t[a + i]) for i in k], (float(S.t[a]), float(S.t[b - 1]))


def floor_bouts(S):
    """Push-up sets: the watch hand is planted (vert 1 s SD < STILL_VERT_SD, forearm pointing
    down gx < -0.5) while the body moves over it (1 s RMS of |rot| > 0.35 rad/s). Planted and
    quieter than that = resting in plank / on the knees. Reps per set: gz (0.25-1.0 Hz) maxima
    >= 1.3 s apart above the set mean (wrist extension changes as the chest goes down).
    Returns (set windows, reps per set)."""
    vsd = rolling(S.vert, int(FS))
    rot_rms = rolling(S.rot, int(FS), "rms")
    planted = (vsd < STILL_VERT_SD) & (S.g[:, 0] < -0.5)
    work = planted & (rot_rms > 0.35)
    bs = bouts(work, int(3 * FS), int(1.5 * FS))
    reps = []
    for a, b in bs:
        gz = bandpass(S.g[a:b, 2], 0.25, 1.0)
        reps.append(len(peaks(gz, int(1.3 * FS), gz.mean())))
    return [(float(S.t[a]), float(S.t[b - 1])) for a, b in bs], reps


def wallwalk_reps(S):
    """Wall walk: a 5-9 s burst of hand placements (vert 1 s SD > 0.05 g) with the forearm
    pointing down the whole time (1 s mean gx < -0.8), steady (mean |rot| < 1.7 rad/s) and the
    palm flat (mean gy > -0.25). Walking over / setting up has the arm swinging (higher |rot|,
    gy < -0.3). Fitted on these 3 segments only."""
    vsd = rolling(S.vert, int(FS))
    gxs = rolling(S.g[:, 0], int(FS), "mean")
    out = []
    for a, b in bouts((vsd > 0.05) & (gxs < -0.8), int(3 * FS), int(1.5 * FS)):
        d = S.t[b - 1] - S.t[a]
        if 4.0 <= d <= 12.0 and S.rot[a:b].mean() < 1.7 and S.g[a:b, 1].mean() > -0.25:
            out.append((float(S.t[a]), float(S.t[b - 1])))
    return out


def cyclic_window(S, sig, lo_s, hi_s):
    """Longest run where the 4 s rolling ACF of `sig` at the dominant period stays high: the
    erg / bike work window. Returns (t_start, t_end, period)."""
    p, _ = acf_period(sig, lo_s, hi_s)
    lag = int(p * FS)
    w = int(4 * FS)
    ok = np.zeros(len(sig), bool)
    step = int(0.5 * FS)
    for c in range(0, len(sig) - w - lag, step):
        x, y = sig[c:c + w], sig[c + lag:c + lag + w]
        if x.std() > 0 and y.std() > 0 and np.corrcoef(x, y)[0, 1] > 0.5:
            ok[c:c + w + lag] = True
    bs = bouts(ok, int(5 * FS), int(3 * FS))
    if not bs:
        return None
    a, b = max(bs, key=lambda r: r[1] - r[0])
    pw, _ = acf_period(sig[a:b], lo_s, hi_s)
    return S.t[a], S.t[b - 1], pw


def strokes(S, sig, lo_s, hi_s):
    """Strokes / revolutions inside the cyclic window: peaks >= 0.6 period apart above the mean."""
    cw = cyclic_window(S, sig, lo_s, hi_s)
    if cw is None:
        return None
    a, b, p = cw
    j0, j1 = np.searchsorted(S.t, a), np.searchsorted(S.t, b)
    x = sig[j0:j1]
    k = peaks(x, int(0.6 * p * FS), x.mean())
    return a, b, p, len(k)


# ---- classification features -----------------------------------------------------------------

def features(S, windows=None):
    """Features over the union of `windows` [(t0, t1)] (None = whole segment)."""
    if windows is None:
        m = np.ones(len(S.t), bool)
    else:
        m = np.zeros(len(S.t), bool)
        for a, b in windows:
            m[int(np.searchsorted(S.t, a)):int(np.searchsorted(S.t, b))] = True
    v, g, rot = S.vert[m], S.g[m], S.rot[m]
    p_gx, c_gx = acf_period(g[:, 0], 0.6, 8.0)
    p_v, c_v = acf_period(v, 0.6, 8.0)
    rises = [x for x in overhead_rises(S, 0.5, OVERHEAD_LOW) if m[min(int(np.searchsorted(S.t, x)), len(m) - 1)]]
    lock = [x for x in overhead_rises(S, 0.9, OVERHEAD_LOW) if m[min(int(np.searchsorted(S.t, x)), len(m) - 1)]]
    return {"gx_p95": np.percentile(g[:, 0], 95), "gy_p95": np.percentile(g[:, 1], 95),
            "vert_min": v.min(), "vert_sd": v.std(), "rot_p99": np.percentile(rot, 99),
            "p_gx": p_gx, "c_gx": c_gx, "p_v": p_v, "c_v": c_v,
            "still_frac": float((rolling(S.vert, int(FS))[m] < STILL_VERT_SD).mean()),
            "rises": len(rises),
            "rise_gap": float(np.median(np.diff(rises))) if len(rises) > 1 else float("nan"),
            "lock_frac": len(lock) / len(rises) if rises else float("nan")}


# ---- report -----------------------------------------------------------------------------------

def f1(x, d=1):
    return "-" if x is None or (isinstance(x, float) and not math.isfinite(x)) else f"{x:.{d}f}"


def specific(X, mv):
    """(count, count label, work window, extra) for one segment by the movement-specific rule."""
    if mv == "burpee":
        ts = burpee_reps(X)
        return len(ts), str(len(ts)), (ts[0] - 2, ts[-1] + 2) if ts else None, ts
    if mv == "snatch":
        ts = snatch_reps(X)
        return len(ts), str(len(ts)), (ts[0] - 2, ts[-1] + 2) if ts else None, ts
    if mv == "cj":
        lock, every = cj_reps(X)
        win = (every[0] - 2, every[-1] + 2) if every else None
        return 2 * len(lock), f"{2 * len(lock)} (2x{len(lock)}; every-rep rule {len(every)})", win, (lock, every)
    if mv == "pullup":
        ts, hang = pullup_reps(X)
        return len(ts), str(len(ts)), hang, ts
    if mv == "pushup":
        bs, reps = floor_bouts(X)
        return sum(reps), f"{sum(reps)} ({'+'.join(map(str, reps))})", (bs[0][0], bs[-1][1]) if bs else None, (bs, reps)
    if mv == "wallwalk":
        ww = wallwalk_reps(X)
        return len(ww), str(len(ww)), (ww[0][0], ww[-1][1]) if ww else None, ww
    raise ValueError(mv)


def acc(pairs):
    pairs = [(tr, c) for tr, c in pairs if c is not None]
    if not pairs:
        return "-"
    ex = sum(1 for tr, c in pairs if c == tr)
    mae = sum(abs(c - tr) for tr, c in pairs) / len(pairs)
    return f"{ex}/{len(pairs)} exact, MAE {mae:.1f}"


def main(argv):
    folder = argv[0] if argv else "data/raw/2026-11-01-amrap40"
    motion, segs = load(folder)
    S = {s["index"]: Seg(motion, s) for s in segs}
    work = {}

    print("## Rep counts (counted, true in column 'true')\n")
    print("Generic = autocorrelation period + peak picking; cell = whole Crown segment / detected work "
          "window. Specific = per-movement rule (script docstrings).\n")
    print("| seg | R | movement | dur s | true | generic vert | generic gx | generic rot | specific | work window s |")
    print("|---:|---:|---|---:|---:|---|---|---|---|---|")
    tally = {}
    for s in segs:
        mv = s["movement"]
        if mv not in TRUTH:
            continue
        X = S[s["index"]]
        lo, hi = PERIOD_RANGE[mv]
        sigs = (X.vert, X.g[:, 0], X.rot)
        gen = [generic_count(x, lo, hi)[2] for x in sigs]
        n, label, win, _ = specific(X, mv)
        work[s["index"]] = win
        if win is not None:
            j0, j1 = np.searchsorted(X.t, win[0]), np.searchsorted(X.t, win[1])
            genw = [generic_count(x[j0:j1], lo, hi)[2] for x in sigs]
        else:
            genw = [None] * 3
        tr = TRUTH[mv]
        tally.setdefault(mv, []).append((tr, gen, genw, n))
        cells = [f"{a} / {b if b is not None else '-'}" for a, b in zip(gen, genw)]
        wtxt = f"{win[0]:.1f}-{win[1]:.1f}" if win else "-"
        print(f"| {s['index']} | {s['round']} | {mv} | {X.dur:.0f} | {tr} | {cells[0]} | {cells[1]} | {cells[2]} | "
              f"**{label}** | {wtxt} |")

    print("\n## Accuracy per movement (segments with the exact count; MAE in reps)\n")
    print("| movement | segs | generic vert (segment) | generic gx (segment) | generic rot (segment) | "
          "generic, best signal in work window (oracle) | specific rule |")
    print("|---|---:|---|---|---|---|---|")
    for mv, rows in tally.items():
        cols = [acc([(tr, gen[k]) for tr, gen, _, _ in rows]) for k in range(3)]
        best = []
        for tr, _, genw, _ in rows:
            cand = [c for c in genw if c is not None]
            best.append((tr, min(cand, key=lambda c: abs(c - tr)) if cand else None))
        print(f"| {mv} | {len(rows)} | {cols[0]} | {cols[1]} | {cols[2]} | {acc(best)} | "
              f"**{acc([(tr, n) for tr, _, _, n in rows])}** |")

    print("\n## Push-up sets: work vs rest inside the segment\n")
    print("| seg | R | sets | set windows (s from segment start) | set length s | reps per set (true 5+5+5) | rest between sets s |")
    print("|---:|---:|---:|---|---|---|---|")
    for s in segs:
        if s["movement"] != "pushup":
            continue
        bs, reps = floor_bouts(S[s["index"]])
        rests = ", ".join(f"{bs[k + 1][0] - bs[k][1]:.1f}" for k in range(len(bs) - 1))
        print(f"| {s['index']} | {s['round']} | {len(bs)} | {', '.join(f'{a:.1f}-{b:.1f}' for a, b in bs)} | "
              f"{', '.join(f'{b - a:.1f}' for a, b in bs)} | {'+'.join(map(str, reps))} | {rests} |")

    print("\n## Pull-up hangs and wall-walk reps\n")
    print("| seg | R | movement | bouts (s from segment start) | bar_hangs() (barpath) | lead-in before first bout s |")
    print("|---:|---:|---|---|---|---:|")
    for s in segs:
        X = S[s["index"]]
        if s["movement"] == "pullup":
            ts, h = pullup_reps(X)
            bh = bar_hangs(motion, s["start"], s["end"])
            print(f"| {s['index']} | {s['round']} | pull-up | hang {h[0]:.1f}-{h[1]:.1f} ({h[1] - h[0]:.1f} s), "
                  f"pulls at {', '.join(f'{x:.1f}' for x in ts)} | {len(bh)} hangs | {h[0]:.1f} |")
        if s["movement"] == "wallwalk":
            ww = wallwalk_reps(X)
            gaps = [ww[k + 1][0] - ww[k][0] for k in range(len(ww) - 1)]
            print(f"| {s['index']} | {s['round']} | wall walk | {', '.join(f'{a:.1f}-{b:.1f}' for a, b in ww)} "
                  f"(rep every {', '.join(f'{g:.0f}' for g in gaps)} s) | - | {ww[0][0] if ww else float('nan'):.1f} |")

    print("\n## Row and bike: stroke / revolution rate\n")
    print("Row on gx (forearm swings up at the finish), bike on vert (arm push-pull).\n")
    print("| seg | R | movement | segment s | cyclic window s | period s | rate /min | cycles counted |")
    print("|---:|---:|---|---:|---|---:|---:|---:|")
    for s in segs:
        mv = s["movement"]
        if mv not in ("row", "bike"):
            continue
        X = S[s["index"]]
        r = strokes(X, X.g[:, 0] if mv == "row" else X.vert, *PERIOD_RANGE[mv])
        if r is None:
            print(f"| {s['index']} | {s['round']} | {mv} | {X.dur:.0f} | - | - | - | - |")
            continue
        a, b, p, n = r
        work[s["index"]] = (a, b)
        print(f"| {s['index']} | {s['round']} | {mv} | {X.dur:.0f} | {a:.1f}-{b:.1f} | {p:.2f} | {60 / p:.1f} | {n} |")

    print("\n## Crown segment vs detected work (transition = lead-in before the first rep)\n")
    print("| movement | segs | Crown s (mean) | lead-in s (min..max) | work s (mean) | tail s (mean) |")
    print("|---|---:|---:|---|---:|---:|")
    by = {}
    for s in segs:
        w = work.get(s["index"])
        if w is None:
            continue
        X = S[s["index"]]
        by.setdefault(s["movement"], []).append((X.dur, max(0.0, w[0]), w[1] - max(0.0, w[0]), max(0.0, X.dur - w[1])))
    for mv in ("row", "bike", "pushup", "pullup", "cj", "snatch", "burpee", "wallwalk"):
        r = np.array(by.get(mv, []))
        if len(r) == 0:
            continue
        print(f"| {mv} | {len(r)} | {r[:, 0].mean():.0f} | {r[:, 1].min():.0f}..{r[:, 1].max():.0f} | "
              f"{r[:, 2].mean():.0f} | {r[:, 3].mean():.0f} |")

    print("\n## Features on the work window\n")
    print("Work window = detected sets / reps / cyclic part (push-ups: the three set windows only).\n")
    print("| seg | R | movement | gx p95 | gy p95 | vert min g | vert SD g | rot p99 rad/s | gx period s (acf r) | "
          "vert period s (acf r) | still frac | rises >0.5 | median rise gap s | lockout frac |")
    print("|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    feats = {}
    for s in segs:
        if s["movement"] == "rest":
            continue
        X = S[s["index"]]
        if s["movement"] == "pushup":
            wins = floor_bouts(X)[0]
        else:
            wins = [work[s["index"]]] if work.get(s["index"]) else None
        f = features(X, wins)
        feats[s["index"]] = f
        print(f"| {s['index']} | {s['round']} | {s['movement']} | {f['gx_p95']:+.2f} | {f['gy_p95']:+.2f} | "
              f"{f['vert_min']:+.2f} | {f['vert_sd']:.2f} | {f['rot_p99']:.1f} | {f['p_gx']:.2f} ({f['c_gx']:.2f}) | "
              f"{f['p_v']:.2f} ({f['c_v']:.2f}) | {f['still_frac']:.2f} | {f['rises']} | {f1(f['rise_gap'])} | "
              f"{f1(f['lock_frac'], 2)} |")

    print("\n## Which features separate the pairs (min-max per movement on the work window)\n")
    pairs = [("row", "bike", ["p_gx", "gx_p95", "c_v"]),
             ("cj", "snatch", ["rise_gap", "lock_frac", "gy_p95", "vert_min", "rot_p99"]),
             ("burpee", "wallwalk", ["vert_min", "rot_p99", "gx_p95", "rises", "still_frac"]),
             ("pushup", "pullup", ["gx_p95", "vert_sd", "still_frac"])]
    print("| pair | feature | A range | B range | separated | gap / spread |")
    print("|---|---|---|---|---|---:|")
    for a, b, names in pairs:
        for nm in names:
            va = [feats[s["index"]][nm] for s in segs if s["movement"] == a]
            vb = [feats[s["index"]][nm] for s in segs if s["movement"] == b]
            lo, hi = (va, vb) if max(va) < min(vb) else (vb, va)
            gap = min(hi) - max(lo)
            spread = max(max(va) - min(va), max(vb) - min(vb), 1e-9)
            print(f"| {a} vs {b} | {nm} | {min(va):.2f}..{max(va):.2f} | {min(vb):.2f}..{max(vb):.2f} | "
                  f"{'yes' if gap > 0 else 'no'} | {gap / spread:+.2f} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
