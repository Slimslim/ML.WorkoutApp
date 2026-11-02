"""Transition vs work time inside each Crown segment (prototype).

The athlete turns the Crown as soon as a movement ends, so every segment is
    [Crown] -- transition (walk over, chalk, set the erg, pick up the DB) -- [first rep] -- work -- [Crown]
This module estimates the onset of real work: seconds after the segment start until the first
rep / stroke / running stride. transition = onset, work = segment duration - onset. A rest
segment has no transition.

    python3 tools/barpath/transitions.py data/raw/2026-11-01-amrap40     (markdown tables)

Detectors (all on the segment's own motion slice, left wrist, device frame, g):
  run       barpath.segments.detect_running (running cadence 130-200/min); onset = first run.
  row       cyclic gx (forearm swings up at the finish), period 1.5-4 s
  bike      cyclic vert (arm push-pull), period 0.6-2 s
            cyclic onset = first point where a 4 s window correlates (r > 0.5) with the window one
            period later, sustained >= 5 s.
  overhead  (DB snatch, C&J, wall balls, thrusters, devil press, KB snatch...) first rep of a
            rhythmic train of forearm-vertical rises (gx up through +0.5/+0.7 after < -0.3);
            onset = the start of that rise (last time gx was below -0.3).
  burpee    overhead rise with a landing impulse (vert < -1.5 g) within 2 s; onset = end of the
            last still moment in the 4 s before the first validated jump (else jump - 2 s).
  kb        barpath.segments.kb_swing_onset (gravity.x flips every swing).
  pullup    hang: gx > 0.8 for >= 2 s (strict) or barpath.segments.bar_hangs (kipping).
  pushup    planted hand (vert SD < 0.04 g, gx < -0.5) with the body moving (|rot| RMS > 0.35).
  wallwalk  burst of hand placements with the forearm pointing down (amrap40 rule).
  rack      DB walking lunges (DB racked at the shoulder): wrist up (gx > 0.5) held >= 5 s
            (partner WOD 2026-10-31 only).
  jumprope  double unders: |userAccel| 1 s SD > 0.9 g sustained >= 2 s.
  generic   fallback for anything else: 3 s motion energy (SD of |userAccel| + 0.1 * |rot| RMS)
            above the segment's own baseline (p10 + 40 % of the p10..p90 span), sustained >= 3 s
            with dips < 2 s tolerated. Agrees with the movement detectors within 5 s on 37/39
            vigorous segments (the four sessions in data/raw); useless for planted-hand movements.

Confidence (0-1): 0.9 movement detector found it and the generic detector agrees within 8 s;
0.75 movement detector only; 0.5 generic only (or movement detector disagreed); 0.0 nothing found
(onset reported as None -> treat the whole segment as work).

Offline prototype: zero-phase FFT filters (np.fft) as in tools/scratch/amrap40_reps.py; a Swift
port would use causal filters and run after the segment ends (it only needs the segment slice).
Thresholds were chosen on the owner's own sessions (data/raw/*), one athlete, left wrist.
"""
from __future__ import annotations

import glob
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from barpath import segments as seg  # noqa: E402
    from barpath.recording import load_session_csv  # noqa: E402
else:
    from . import segments as seg
    from .recording import load_session_csv

FS = 100.0

# ---- constants ------------------------------------------------------------------------------
OVERHEAD_LOW = -0.3          # gx below this = forearm hanging
OVERHEAD_HIGH = 0.7          # gx above this = forearm vertical (hand overhead)
OVERHEAD_HIGH_CJ = 0.5       # alternating C&J: the non-watch-hand reps only reach 0.6-0.9
RHYTHM_GAP_FACTOR = 2.5      # a "train" of reps: consecutive rises closer than 2.5 x the median gap
RHYTHM_GAP_MIN_S = 4.0       # ... but at least 4 s
RHYTHM_MAX_GAP_S = 15.0      # ... and at most 15 s (partner "I go, you go" single reps ~10 s apart)
RHYTHM_MIN_REPS = 3          # first rep of the first train with >= this many rises
BURPEE_IMPULSE_G = -1.5      # vert below this = jump landing / chest to floor
BURPEE_LOOKBACK_S = 4.0      # the first burpee starts at most this long before its jump
BURPEE_STILL_SD = 0.06       # g, 0.5 s SD of |userAccel|: standing still before the first rep
BURPEE_DOWN_S = 2.0          # typical drop-to-floor -> jump time when no still moment is seen
HANG_GX = 0.8
HANG_MIN_S = 3.0            # a 2 s grab-and-drop before the set (AMRAP 40 R4) is setup, not work
STILL_VERT_SD = 0.04
PUSHUP_ROT_RMS = 0.35
CYCLIC_R_MIN = 0.5
CYCLIC_WIN_S = 4.0
CYCLIC_SUSTAIN_S = 5.0
CYCLIC_AMP_FRACTION = 0.25   # window SD must reach 25 % of the segment's p90 1 s amplitude
RACK_GX = 0.5
RACK_MIN_S = 5.0
JUMPROPE_SD_G = 0.9
JUMPROPE_SUSTAIN_S = 2.0
GENERIC_WIN_S = 3.0          # energy window (centred: onsets come out ~1 s early)
GENERIC_SUSTAIN_S = 3.0
GENERIC_FRACTION = 0.4
GENERIC_GAP_S = 2.0
GENERIC_MIN_SPAN = 0.02       # p90 - p10 of the energy below this = flat segment, no onset
WALK_CADENCE = (80.0, 135.0)  # steps/min seen on |userAccel| while walking between stations
AGREE_S = 8.0

# movement id (workout JSON / labels) -> detector family
FAMILY = {
    "run": "run", "running": "run",
    "row": "row", "rowing": "row", "rowErg": "row", "skiErg": "row", "ski": "row",
    "bike": "bike", "assaultBike": "bike", "echoBike": "bike",
    "dumbbellSnatch": "overhead", "snatch": "overhead", "cj": "overhead_cj",
    "dumbbellCleanAndJerk": "overhead_cj", "wallBalls": "overhead", "wallball": "overhead",
    "thrusters": "overhead", "devilPress": "overhead", "kettlebellSnatch": "overhead",
    "burpees": "burpee", "burpee": "burpee", "lateralBurpeeOverDumbbell": "burpee",
    "burpeeBroadJumps": "burpee",
    "kettlebellSwings": "kb", "kb": "kb",
    "pullUps": "pullup", "pullup": "pullup", "pull": "pullup", "toesToBar": "pullup",
    "pushUps": "pushup", "pushup": "pushup",
    "wallWalks": "wallwalk", "wallwalk": "wallwalk",
    "doubleUnders": "jumprope", "singleUnders": "jumprope",
    "dumbbellWalkingLunges": "rack",
    "rest": "rest",
}


def family(movement: str) -> str:
    return FAMILY.get(movement, "generic")


@dataclass
class Onset:
    onset: Optional[float]     # seconds after segment start (None = not found / no transition)
    confidence: float          # 0..1
    method: str                # detector that produced it
    specific: Optional[float] = None   # movement detector's answer (s), for the report
    generic: Optional[float] = None    # generic detector's answer (s)


# ---- primitives (offline, numpy) ------------------------------------------------------------

def bandpass(x, lo, hi, fs=FS):
    """Zero-phase FFT brick-wall band-pass (lo <= 0: low-pass keeping the mean)."""
    x = np.asarray(x, float)
    if len(x) < 4:
        return x.copy()
    mean = x.mean()
    X = np.fft.rfft(x - mean)
    f = np.fft.rfftfreq(len(x), 1.0 / fs)
    X[(f < lo) | (f > hi)] = 0
    return np.fft.irfft(X, len(x)) + (mean if lo <= 0 else 0.0)


def rolling(x, win, fn="sd"):
    """Centred rolling SD / mean / RMS over `win` samples (cumsum)."""
    x = np.asarray(x, float)
    n = len(x)
    c1 = np.concatenate([[0], np.cumsum(x)])
    c2 = np.concatenate([[0], np.cumsum(x * x)])
    h = win // 2
    lo = np.clip(np.arange(n) - h, 0, n)
    hi = np.clip(np.arange(n) + h + 1, 0, n)
    cnt = np.maximum(hi - lo, 1)
    m = (c1[hi] - c1[lo]) / cnt
    if fn == "mean":
        return m
    q = (c2[hi] - c2[lo]) / cnt
    if fn == "rms":
        return np.sqrt(q)
    return np.sqrt(np.maximum(q - m * m, 0))


def runs_of(mask, min_len, merge_gap):
    """[(i0, i1)] runs of True; gaps shorter than merge_gap merged, runs shorter than min_len
    dropped (samples)."""
    out, inside, a = [], False, 0
    for i, v in enumerate(mask):
        if v and not inside:
            inside, a = True, i
        elif not v and inside:
            inside = False
            if out and a - out[-1][1] < merge_gap:
                out[-1][1] = i
            else:
                out.append([a, i])
    if inside:
        if out and a - out[-1][1] < merge_gap:
            out[-1][1] = len(mask)
        else:
            out.append([a, len(mask)])
    return [(a, b) for a, b in out if b - a >= min_len]


def acf_period(x, lo_s, hi_s, fs=FS):
    """(period s, r) of the strongest autocorrelation local maximum in [lo_s, hi_s]."""
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
    s = ac[i0:i1]
    cand = [k for k in range(1, len(s) - 1) if s[k] >= s[k - 1] and s[k] >= s[k + 1]]
    k = max(cand, key=lambda j: s[j]) if cand else int(np.argmax(s))
    return (i0 + k) / fs, float(s[k])


class Slice:
    """Signals of one segment, time relative to the segment start."""

    def __init__(self, motion, start: float, end: float):
        i0 = int(np.searchsorted(motion.t, start))
        i1 = int(np.searchsorted(motion.t, end))
        self.motion, self.start, self.end = motion, start, end
        self.t = motion.t[i0:i1] - start
        a = motion.user_accel[i0:i1]
        g = motion.gravity[i0:i1]
        r = motion.rotation_rate[i0:i1]
        self.amag = np.linalg.norm(a, axis=1) if len(a) else np.zeros(0)
        self.vert = bandpass(-(a * g).sum(1), 0.2, 3.0) if len(a) else np.zeros(0)
        self.g = np.column_stack([bandpass(g[:, k], 0, 2.0) for k in range(3)]) if len(g) else np.zeros((0, 3))
        self.rot = bandpass(np.linalg.norm(r, axis=1), 0, 3.0) if len(r) else np.zeros(0)

    @property
    def duration(self) -> float:
        return self.end - self.start

    def time(self, i: int) -> float:
        return float(self.t[min(max(i, 0), len(self.t) - 1)])


# ---- generic detector -----------------------------------------------------------------------

def motion_energy(S: Slice, win_s: float = GENERIC_WIN_S):
    """Rolling SD of |userAccel| (g) + 0.1 x rolling RMS of |rotationRate| (rad/s), centred
    windows of win_s."""
    w = int(win_s * FS)
    return rolling(S.amag, w) + 0.1 * rolling(S.rot, w, "rms")


def is_walking(S: Slice, t0: float, t1: float) -> bool:
    """[t0, t1) (segment time) looks like walking: |userAccel| dominant cadence 80-135/min with a
    peaky spectrum and moderate SD (0.05-0.35 g). Used for the sanity report only."""
    f = seg.window_features(S.motion, S.start + t0, S.start + t1)
    return (f is not None and WALK_CADENCE[0] <= f["cadence"] <= WALK_CADENCE[1]
            and f["peakiness"] > 0.25 and 0.05 < f["sd"] < 0.35)


def generic_onset(S: Slice, sustain_s: float = GENERIC_SUSTAIN_S) -> Optional[float]:
    """Movement-agnostic onset: first time the 3 s motion energy stays above the segment's own
    baseline + 40 % of its p10..p90 span for >= sustain_s (dips < 2 s tolerated, i.e. the pause
    between reps). Assumes the work is more vigorous than the walk-over, so it fails on
    planted-hand movements (push-ups, wall walks, strict pull-ups). None if the segment is flat."""
    if S.duration < sustain_s + 1 or len(S.t) < FS:
        return None
    e = motion_energy(S)
    p10, p90 = np.percentile(e, 10), np.percentile(e, 90)
    if p90 - p10 < GENERIC_MIN_SPAN:
        return None
    thr = p10 + GENERIC_FRACTION * (p90 - p10)
    bs = runs_of(e > thr, int(sustain_s * FS), int(GENERIC_GAP_S * FS))
    return S.time(bs[0][0]) if bs else None


# ---- movement-specific detectors (seconds after segment start, or None) -----------------------

def run_onset(S: Slice) -> Optional[float]:
    runs = seg.detect_running(S.motion, S.start, S.end)
    if not runs:
        return None
    return max(0.0, runs[0][0] - S.start)


def cyclic_onset(S: Slice, sig, lo_s: float, hi_s: float) -> Optional[float]:
    """Erg / bike: first time a 4 s window correlates (r > 0.5) with the window one period later
    (period from the whole segment's ACF in [lo_s, hi_s]), sustained >= 5 s; refined to the
    first sample in that window whose 1 s amplitude reaches half the run's median amplitude."""
    p, _ = acf_period(sig, lo_s, hi_s)
    if not math.isfinite(p):
        return None
    lag, w, step = int(p * FS), int(CYCLIC_WIN_S * FS), int(0.5 * FS)
    amp = rolling(sig, int(FS))
    floor = CYCLIC_AMP_FRACTION * float(np.percentile(amp, 90))   # ignore near-still windows
    ok = np.zeros(len(sig), bool)
    for c in range(0, len(sig) - w - lag, step):
        x, y = sig[c:c + w], sig[c + lag:c + lag + w]
        if x.std() > floor and y.std() > floor and np.corrcoef(x, y)[0, 1] > CYCLIC_R_MIN:
            ok[c:c + step] = True
    bs = runs_of(ok, int(CYCLIC_SUSTAIN_S * FS), int(1.5 * FS))
    if not bs:
        return None
    a, b = bs[0]
    # the first correlated window may start up to (window + lag) before the strokes: move the
    # onset to where the 1 s amplitude of the signal first reaches half its level in the run
    level = float(np.median(amp[a:b]))
    j1 = min(len(sig), a + w + lag)
    hit = np.where(amp[a:j1] >= 0.5 * level)[0]
    return S.time(a + int(hit[0])) if len(hit) else S.time(a)


def overhead_rises(S: Slice, high=OVERHEAD_HIGH, low=OVERHEAD_LOW):
    """[(t_rise, t_start)]: gx crosses up through `high` after having been below `low`; t_start
    is the last sample below `low` (the start of that arm lift)."""
    out, state, last_low = [], None, 0
    gx = S.g[:, 0]
    for i in range(len(gx)):
        v = gx[i]
        if v < low:
            last_low = i
        if v > high and state != "up":
            if state == "down":
                out.append((S.time(i), S.time(last_low)))
            state = "up"
        elif v < low and state != "down":
            state = "down"
    return out


def first_of_train(events, max_gap=None, min_reps=RHYTHM_MIN_REPS):
    """Index of the first event of the first run of >= min_reps events with gaps <= max_gap
    (default: 2.5 x the median gap, clamped to 4..15 s), so a lone arm raise during the
    walk-over or the dumbbell pick-up is skipped. events = [(t, ...)] sorted by t."""
    if max_gap is None:
        gaps = [events[i + 1][0] - events[i][0] for i in range(len(events) - 1)]
        med = float(np.median(gaps)) if gaps else 0.0
        max_gap = min(RHYTHM_MAX_GAP_S, max(RHYTHM_GAP_MIN_S, RHYTHM_GAP_FACTOR * med))
    k = 0
    while k < len(events):
        j = k
        while j + 1 < len(events) and events[j + 1][0] - events[j][0] <= max_gap:
            j += 1
        if j - k + 1 >= min_reps:
            return k
        k = j + 1
    return None


def overhead_onset(S: Slice, high=OVERHEAD_HIGH) -> Optional[float]:
    ev = overhead_rises(S, high)
    k = first_of_train(ev)
    return ev[k][1] if k is not None else None


def burpee_onset(S: Slice) -> Optional[float]:
    """First overhead rise with a landing impulse (vert < -1.5 g) within +-2 s (a burpee's jump),
    in a train of >= 3. The rep began with the drop to the floor ~1.5-3 s earlier: onset = the end
    of the last still moment (0.5 s SD of |userAccel| < 0.06 g: standing at the target before
    going down) in the BURPEE_LOOKBACK_S before the jump, else jump - BURPEE_DOWN_S."""
    ev = []
    for tr, ts in overhead_rises(S):
        j = int(np.searchsorted(S.t, tr))
        if S.vert[max(0, j - int(2 * FS)):j + int(2 * FS)].min() < BURPEE_IMPULSE_G:
            ev.append((tr, ts))
    k = first_of_train(ev)
    if k is None:
        return None
    tr = ev[k][0]
    j1 = int(np.searchsorted(S.t, tr))
    j0 = int(np.searchsorted(S.t, max(0.0, tr - BURPEE_LOOKBACK_S)))
    if k > 0:   # do not reach back into the previous (rejected) rise
        j0 = max(j0, int(np.searchsorted(S.t, ev[k - 1][0])) + 1)
    sd = rolling(S.amag[j0:j1], int(0.5 * FS))
    still = np.where(sd < BURPEE_STILL_SD)[0]
    if len(still):
        return S.time(j0 + int(still[-1]))
    return max(0.0, tr - BURPEE_DOWN_S)


def hang_onset(S: Slice) -> Optional[float]:
    """Strict: forearm up (gx > 0.8) for >= 3 s. Kipping (Helen): barpath.segments.bar_hangs.
    The earlier of the two."""
    cand = []
    bs = runs_of(S.g[:, 0] > HANG_GX, int(HANG_MIN_S * FS), int(0.5 * FS))
    if bs:
        cand.append(S.time(bs[0][0]))
    hangs = seg.bar_hangs(S.motion, S.start, S.end)
    if hangs:
        cand.append(max(0.0, hangs[0][0] - S.start))
    return min(cand) if cand else None


def pushup_onset(S: Slice) -> Optional[float]:
    """First set: hand planted (1 s vert SD < 0.04 g, forearm down gx < -0.5) and the body moving
    (1 s |rot| RMS > 0.35 rad/s) for >= 3 s."""
    vsd = rolling(S.vert, int(FS))
    rot_rms = rolling(S.rot, int(FS), "rms")
    work = (vsd < STILL_VERT_SD) & (S.g[:, 0] < -0.5) & (rot_rms > PUSHUP_ROT_RMS)
    bs = runs_of(work, int(3 * FS), int(1.5 * FS))
    return S.time(bs[0][0]) if bs else None


def wallwalk_onset(S: Slice) -> Optional[float]:
    """First 4-12 s burst of hand placements (vert 1 s SD > 0.05 g) with the forearm down (1 s mean
    gx < -0.8), steady (mean |rot| < 1.7) and the palm flat (mean gy > -0.25). Fitted on AMRAP 40."""
    vsd = rolling(S.vert, int(FS))
    gxs = rolling(S.g[:, 0], int(FS), "mean")
    for a, b in runs_of((vsd > 0.05) & (gxs < -0.8), int(3 * FS), int(1.5 * FS)):
        d = S.time(b - 1) - S.time(a)
        if 4.0 <= d <= 12.0 and S.rot[a:b].mean() < 1.7 and S.g[a:b, 1].mean() > -0.25:
            return S.time(a)
    return None


def jumprope_onset(S: Slice) -> Optional[float]:
    sd = rolling(S.amag, int(FS))
    bs = runs_of(sd > JUMPROPE_SD_G, int(JUMPROPE_SUSTAIN_S * FS), int(0.5 * FS))
    return S.time(bs[0][0]) if bs else None


def rack_onset(S: Slice) -> Optional[float]:
    """Weight racked at the shoulder (lunges with a DB): forearm up (gx > 0.5) for >= 5 s."""
    bs = runs_of(S.g[:, 0] > RACK_GX, int(RACK_MIN_S * FS), int(1.0 * FS))
    return S.time(bs[0][0]) if bs else None


def kb_onset(S: Slice) -> Optional[float]:
    t = seg.kb_swing_onset(S.motion, S.start, S.end)
    return None if t is None else t - S.start


def specific_onset(fam: str, S: Slice) -> Optional[float]:
    if fam == "run":
        return run_onset(S)
    if fam == "row":
        return cyclic_onset(S, S.g[:, 0], 1.5, 4.0)
    if fam == "bike":
        return cyclic_onset(S, S.vert, 0.6, 2.0)
    if fam == "overhead":
        return overhead_onset(S)
    if fam == "overhead_cj":
        return overhead_onset(S, OVERHEAD_HIGH_CJ)
    if fam == "burpee":
        return burpee_onset(S)
    if fam == "kb":
        return kb_onset(S)
    if fam == "pullup":
        return hang_onset(S)
    if fam == "pushup":
        return pushup_onset(S)
    if fam == "wallwalk":
        return wallwalk_onset(S)
    if fam == "jumprope":
        return jumprope_onset(S)
    if fam == "rack":
        return rack_onset(S)
    return None


# ---- public API -------------------------------------------------------------------------------

def work_onset(movement: str, motion, seg_start: float, seg_end: float) -> Onset:
    """Onset of real work in the segment [seg_start, seg_end) (session seconds) for `movement`
    (workout JSON movement id, or a short label such as 'row', 'bike', 'cj', 'run', 'rest').

    Returns Onset(onset s after seg_start or None, confidence 0-1, method). Rest -> Onset(None,
    1.0, 'rest'): no transition. Runs use the generic detector only as a cross-check (walking
    to the start line is not 'work')."""
    fam = family(movement)
    if fam == "rest":
        return Onset(None, 1.0, "rest")
    S = Slice(motion, seg_start, seg_end)
    if len(S.t) < FS:
        return Onset(None, 0.0, "too-short")
    spec = specific_onset(fam, S)
    gen = generic_onset(S)
    if spec is not None:
        conf = 0.9 if gen is not None and abs(gen - spec) <= AGREE_S else 0.75
        return Onset(round(spec, 2), conf, fam, spec, gen)
    if gen is not None and fam != "run":
        return Onset(round(gen, 2), 0.5, "generic" if fam == "generic" else f"generic({fam})", None, gen)
    return Onset(None, 0.0, "none", None, gen)


def split(movement: str, motion, seg_start: float, seg_end: float) -> dict:
    """{total, transition, work, confidence, method} in seconds. No onset -> transition 0."""
    o = work_onset(movement, motion, seg_start, seg_end)
    total = seg_end - seg_start
    tr = 0.0 if o.onset is None else min(o.onset, total)
    return {"total": total, "transition": tr, "work": total - tr, "confidence": o.confidence,
            "method": o.method, "onset": o}


def walking_seconds(motion, start: float, end: float, step: float = 2.0) -> float:
    """Seconds of [start, end) that look like walking (4 s windows on a 2 s grid)."""
    if end - start < 4.0:
        return 0.0
    S = Slice(motion, start, end)
    n, w = 0, 0.0
    while w + 4.0 <= S.duration + 1e-9:
        n += is_walking(S, w, w + 4.0)
        w += step
    return n * step


# ---- data loading (owner's sessions in data/raw) ------------------------------------------------

AMRAP40_ODD = ("row", "pushup", "cj", "burpee", "rest")
AMRAP40_EVEN = ("bike", "pullup", "snatch", "wallwalk", "rest")


def load_workout(folder):
    """(motion, [{index, movement, label, start, end}]) with times in session seconds. Segment
    bounds come from the workout JSON (Crown presses); AMRAP 40 movements from the owner's labels
    (odd rounds row/push-ups/C&J/burpees, even rounds bike/pull-ups/snatch/wall walks)."""
    folder = Path(folder)
    csv = load_session_csv(glob.glob(str(folder / "session-*.csv"))[0])
    wk = json.load(open(glob.glob(str(folder / "workout-*.json"))[0]))
    t0 = csv.start_date.timestamp()
    amrap40 = "amrap40" in folder.name
    out = []
    for s in wk["segments"]:
        i = s["index"]
        mv = s.get("movement") or s.get("kind")
        if s.get("kind") == "run":
            mv = "run"
        if amrap40:
            rnd = i // 5 + 1
            mv = (AMRAP40_ODD if rnd % 2 else AMRAP40_EVEN)[i % 5]
        out.append({"index": i, "movement": mv, "label": s.get("title", mv),
                    "start": s["start"] - t0, "end": s["end"] - t0})
    return csv.motion, out


def mmss(x: float) -> str:
    x = int(round(x))
    return f"{x // 60}:{x % 60:02d}"


def report(folder) -> str:
    motion, segs = load_workout(folder)
    lines = ["| # | movement | total | transition | work | conf | method | specific / generic s | walking in transition s |",
             "|---:|---|---:|---:|---:|---:|---|---|---:|"]
    tot = {"total": 0.0, "transition": 0.0}
    for s in segs:
        r = split(s["movement"], motion, s["start"], s["end"])
        o = r["onset"]
        if o.method == "rest":
            lines.append(f"| {s['index']} | rest | {mmss(r['total'])} | – | – | – | rest | | |")
            continue
        tot["total"] += r["total"]
        tot["transition"] += r["transition"]
        sg = f"{'-' if o.specific is None else f'{o.specific:.1f}'} / {'-' if o.generic is None else f'{o.generic:.1f}'}"
        walk = walking_seconds(motion, s["start"], s["start"] + r["transition"])
        lines.append(f"| {s['index']} | {s['movement']} | {mmss(r['total'])} | {mmss(r['transition'])} | "
                     f"{mmss(r['work'])} | {r['confidence']:.2f} | {o.method} | {sg} | {walk:.0f} |")
    lines.append(f"\nTime in transitions: **{mmss(tot['transition'])}** of {mmss(tot['total'])} "
                 f"non-rest time ({100 * tot['transition'] / max(tot['total'], 1):.0f} %).")
    return "\n".join(lines)


if __name__ == "__main__":
    for f in sys.argv[1:] or sorted(glob.glob("data/raw/*/workout-*.json")):
        folder = f if Path(f).is_dir() else str(Path(f).parent)
        print(f"\n### {Path(folder).name}\n")
        print(report(folder))
