"""B2 prototype: segment (run / station) detection on full-session device motion.

Pure functions over a MotionSeries (userAccel in g, gravity vector in the device frame in g,
rotation rate in rad/s; see docs/RECORDER_SPEC.md sign convention). Written to be ported
line-for-line to Swift: plain loops over windows, named constants, no pandas. The only
numpy "magic" is the FFT inside `window_features` (use vDSP / a naive DFT over 0.3-4 Hz in Swift).

Model of a HYROX-style workout recorded on the left wrist, Crown pressed as soon as a
movement ends, so every segment begins with a transition (walking) before the work starts.
First calibrated on data/raw/2026-10-29-helen (one athlete, one workout).
"""
from __future__ import annotations

import math
from typing import Optional

import numpy as np

# ---- running (arm swing at running cadence) ------------------------------------------------
RUN_WINDOW_S = 4.0          # feature window length
RUN_STEP_S = 2.0            # window hop
RUN_CADENCE_MIN = 130.0     # dominant frequency of |userAccel|, cycles/min (steps; 1 per footfall)
RUN_CADENCE_MAX = 200.0
RUN_SD_MIN = 0.25           # SD of |userAccel| in the window, g (walking/stations are lower or aperiodic)
RUN_PEAKINESS_MIN = 0.25    # share of in-band spectral power in the dominant bin (periodic vs noisy)
RUN_DEBOUNCE_WINDOWS = 3    # consecutive windows (6 s) that must agree before the state flips
RUN_MIN_DURATION_S = 20.0   # drop shorter "runs"
BAND_LO_HZ = 0.3            # spectral band searched for the dominant frequency
BAND_HI_HZ = 4.0
MIN_WINDOW_SAMPLES = 20       # skip (data gap) windows with fewer samples

# ---- kettlebell swing onset (wrist flips between palm-up/down every swing) --------------------
KB_WINDOW_S = 1.0
KB_STEP_S = 0.5
KB_GX_RANGE_MIN = 1.0       # max-min of gravity.x within a 1 s window (walking arms-down: < 0.6)
KB_SUSTAIN_WINDOWS = 5      # consecutive windows (3 s) above the range threshold

# ---- bar hangs (wrist up on the bar: gravity.x > 0 means the left forearm points up) ----------
HANG_WINDOW_S = 0.5
HANG_STEP_S = 0.25
HANG_GX_MIN = 0.5           # mean gravity.x of the window above this = arm overhead
HANG_MIN_DURATION_S = 1.5   # a set of >= 1 pull-up lasts at least ~2 s on the bar
HANG_ACTIVE_SD_MIN = 0.5    # SD of |userAccel| (g) over the bout: real sets 0.72-1.74, resting with the hands
                            # up on the rack (Helen R3, athlete-confirmed) 0.34. Arms up + still = not a set.
HANG_MERGE_GAP_S = 1.0      # bouts closer than this are one set (a grip re-adjust). Real gaps between sets are
                            # >= 2.0 s (2.0-2.5 s between the short sets of round 3); do not raise above ~1.5


def _sample_rate(motion) -> float:
    n = len(motion.t)
    if n < 2:
        return 0.0
    return (n - 1) / (motion.t[-1] - motion.t[0])


def _bounds(t, t0: float, t1: float):
    """Index range [i0, i1) of samples with t0 <= t < t1 (binary search; sorted t)."""
    return int(np.searchsorted(t, t0, side="left")), int(np.searchsorted(t, t1, side="left"))


def window_features(motion, t0: float, t1: float) -> Optional[dict]:
    """Features of [t0, t1): cadence (cycles/min of |userAccel|), sd (g), peakiness (0-1),
    gx/gy/gz (mean gravity), gx_range, rot_rms (rad/s). None if too few samples."""
    i0, i1 = _bounds(motion.t, t0, t1)
    n = i1 - i0
    if n < MIN_WINDOW_SAMPLES:
        return None
    ua = motion.user_accel[i0:i1]
    amag = np.empty(n)
    for i in range(n):
        amag[i] = math.sqrt(ua[i, 0] ** 2 + ua[i, 1] ** 2 + ua[i, 2] ** 2)
    mean = amag.mean()
    sd = math.sqrt(((amag - mean) ** 2).mean())
    fs = (n - 1) / (motion.t[i1 - 1] - motion.t[i0])
    x = (amag - mean) * np.hanning(n)
    power = np.abs(np.fft.rfft(x)) ** 2
    freq = np.fft.rfftfreq(n, 1.0 / fs)
    best, best_p, total = 0.0, 0.0, 0.0
    for k in range(len(freq)):
        if BAND_LO_HZ < freq[k] < BAND_HI_HZ:
            total += power[k]
            if power[k] > best_p:
                best_p, best = power[k], freq[k]
    g = motion.gravity[i0:i1]
    r = motion.rotation_rate[i0:i1]
    rot_sq = 0.0
    for i in range(n):
        rot_sq += r[i, 0] ** 2 + r[i, 1] ** 2 + r[i, 2] ** 2
    return {
        "cadence": best * 60.0,
        "sd": sd,
        "peakiness": best_p / total if total > 0 else 0.0,
        "gx": float(g[:, 0].mean()), "gy": float(g[:, 1].mean()), "gz": float(g[:, 2].mean()),
        "gx_range": float(g[:, 0].max() - g[:, 0].min()),
        "rot_rms": math.sqrt(rot_sq / n),
    }


def is_running_window(f: Optional[dict]) -> bool:
    return (f is not None and f["sd"] > RUN_SD_MIN
            and RUN_CADENCE_MIN <= f["cadence"] <= RUN_CADENCE_MAX
            and f["peakiness"] > RUN_PEAKINESS_MIN)


def run_windows(motion, t_from: Optional[float] = None, t_to: Optional[float] = None):
    """[(window_start, is_running)] on a RUN_STEP_S grid starting at t_from."""
    if len(motion.t) == 0:
        return []
    t_from = motion.t[0] if t_from is None else t_from
    t_to = motion.t[-1] if t_to is None else t_to
    out = []
    w = t_from
    while w + RUN_WINDOW_S <= t_to + 1e-9:
        out.append((w, is_running_window(window_features(motion, w, w + RUN_WINDOW_S))))
        w += RUN_STEP_S
    return out


def detect_running(motion, t_from: Optional[float] = None, t_to: Optional[float] = None):
    """Debounced running intervals [(start, end)] in session seconds.

    The state flips only after RUN_DEBOUNCE_WINDOWS consecutive windows disagree with it; the
    change is placed at the centre of the first of those windows. Runs shorter than
    RUN_MIN_DURATION_S are dropped; a run still active at the end is closed at t_to."""
    wins = run_windows(motion, t_from, t_to)
    if not wins:
        return []
    t_end = motion.t[-1] if t_to is None else t_to
    half = RUN_WINDOW_S / 2.0
    runs = []
    state, count, start = False, 0, 0.0
    for k in range(len(wins)):
        if wins[k][1] != state:
            count += 1
            if count >= RUN_DEBOUNCE_WINDOWS:
                change = wins[k - RUN_DEBOUNCE_WINDOWS + 1][0] + half
                state, count = wins[k][1], 0
                if state:
                    start = change
                else:
                    runs.append((start, change))
        else:
            count = 0
    if state:
        runs.append((start, t_end))
    return [(a, b) for (a, b) in runs if b - a >= RUN_MIN_DURATION_S]


def bar_hangs(motion, start: float, end: float):
    """Wrist-up bouts [(start, end)] in [start, end): mean gravity.x over 0.5 s windows above
    HANG_GX_MIN, bouts closer than HANG_MERGE_GAP_S merged, bouts shorter than
    HANG_MIN_DURATION_S dropped, and bouts without movement (SD of |userAccel| below
    HANG_ACTIVE_SD_MIN) dropped. Meant for pull-up (bar) segments only."""
    raw = []
    inside, b0 = False, 0.0
    w = start
    last = start
    while w + HANG_WINDOW_S <= end + 1e-9:
        f = window_features(motion, w, w + HANG_WINDOW_S)
        up = f is not None and f["gx"] > HANG_GX_MIN
        if up and not inside:
            inside, b0 = True, w
        elif not up and inside:
            inside = False
            raw.append((b0, last + HANG_WINDOW_S))
        if up:
            last = w
        w += HANG_STEP_S
    if inside:
        raw.append((b0, last + HANG_WINDOW_S))
    merged = []
    for b in raw:
        if merged and b[0] - merged[-1][1] < HANG_MERGE_GAP_S:
            merged[-1] = (merged[-1][0], b[1])
        else:
            merged.append(b)
    out = []
    for (a, b) in merged:
        if b - a < HANG_MIN_DURATION_S:
            continue
        f = window_features(motion, a, b)
        if f is None or f["sd"] < HANG_ACTIVE_SD_MIN:
            continue   # hands up but not pulling (e.g. leaning on the rack to breathe)
        out.append((a, b))
    return out


def kb_swing_onset(motion, start: float, end: float) -> Optional[float]:
    """Start of the first window of KB_SUSTAIN_WINDOWS consecutive 1 s windows whose
    gravity.x range >= KB_GX_RANGE_MIN (the wrist flips every swing)."""
    run, first = 0, 0.0
    w = start
    while w + KB_WINDOW_S <= end + 1e-9:
        f = window_features(motion, w, w + KB_WINDOW_S)
        if f is not None and f["gx_range"] >= KB_GX_RANGE_MIN:
            if run == 0:
                first = w
            run += 1
            if run >= KB_SUSTAIN_WINDOWS:
                return first
        else:
            run = 0
        w += KB_STEP_S
    return None


def work_onset(motion, seg_start: float, seg_end: float, kind: str) -> Optional[float]:
    """Time (session seconds) the movement actually starts after the transition, or None.

    kind: "run" -> start of the first running run inside the segment (or segment start if
    already running); "kb"/"kettlebell" -> first sustained swing; "pull"/"bar" -> start of the
    first hang on the bar."""
    if kind == "run":
        for (a, _b) in detect_running(motion, seg_start, seg_end):
            return a
        return None
    if kind in ("kb", "kettlebell"):
        return kb_swing_onset(motion, seg_start, seg_end)
    if kind in ("pull", "bar"):
        hangs = bar_hangs(motion, seg_start, seg_end)
        return hangs[0][0] if hangs else None
    raise ValueError(f"unknown kind {kind!r}")


# ---- Crown segments from the session CSV events ---------------------------------------------
HELEN_KINDS = ("run", "kb", "pull")   # per-round station order of wod.helen


def crown_segments(events, kinds=HELEN_KINDS):
    """[{index, start, end, kind}] from '# event name=segment|finish' lines (load_session_csv
    .events). The movement kind cycles through `kinds` (the workout definition's order)."""
    marks = [e for e in events if e.get("name") in ("segment", "finish")]
    out = []
    for i in range(len(marks) - 1):
        out.append({"index": i, "start": marks[i]["t"], "end": marks[i + 1]["t"],
                    "kind": kinds[i % len(kinds)]})
    return out
