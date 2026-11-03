#!/usr/bin/env python3
"""2026-11-02 first look: barbell power clean & jerk EMOM + "Freedom" (row / power cleans), rep by
rep from left-wrist device motion.

    python3 tools/scratch/pcj_freedom_reps.py [data/raw/2026-11-02-pcj-emom-freedom]

Prints markdown tables (copied into that folder's ANALYSIS.md).

What the watch wrist does in a barbell clean (both hands on the bar, so every rep is seen):
  * floor / hang: forearm hanging, gx (gravity along the forearm, 2 Hz low-pass) ~ -1.
  * pull + catch: gx flips from < -0.5 to > +0.5 in 0.17-0.19 s (the elbows whip round the bar)
    with a 4-8 g |userAccel| spike. A watch glance or a row finish lifts the forearm in 0.4-1.5 s,
    with the wrist rotated the other way (gy < -0.4) and < 3.5 g: never confused here.
  * front rack: gx 0.65-0.9 with gy +0.3..+0.6 (wrist extended under the bar).
  * jerk lockout (C&J only): gx > 0.93 with |gy| < 0.2 (forearm vertical), held ~1-2 s.
  * lowering: gx back below 0, a 3-8 g spike when the bar lands (dropped from the hips/rack).

Rep = catch (fast gx flip + >= 3.5 g spike + wrist extended in the rack, mean gy > 0 while up).
Lockout = gx > 0.93 and |gy| < 0.2 for >= 0.3 s within 6 s after the catch, before the forearm
comes down. A missed pull (no catch) cannot be told apart from standing up after dropping the
bar (both: >= 1 m/s upward wrist burst with the forearm hanging), so it is not reported.

Bar-speed proxy: vertical wrist velocity, same method as tools/scratch/squat_first_look.py
(world-vertical acceleration, FFT band-pass 0.1-4 Hz, integrate, band-pass 0.12-4 Hz), BUT with the
sign fixed: CoreMotion reports userAcceleration with the sign of gravity (a device accelerating
up reads a component along the gravity vector), so up = +(userAccel . gravity_unit) * 9.81. The
squat script uses the opposite sign; here the -(a.g) convention would make every pull go down
and every drop go up. Peak values are smoothed by the 4 Hz cut-off: a proxy for comparing reps,
not a calibrated bar speed.

Thresholds were picked on these two sessions while looking at them: training accuracy, no video.
numpy only; reuses barpath.recording / barpath.workout / barpath.transitions and the row stroke
counter from tools/scratch/amrap40_reps.py.
"""
from __future__ import annotations

import glob
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[1]))
sys.path.insert(0, str(HERE.parent))

from barpath.recording import load_session_csv  # noqa: E402
from barpath.transitions import bandpass, rolling, work_onset  # noqa: E402
from barpath.workout import HeartRateRecovery, HeartRateSeries  # noqa: E402
import amrap40_reps as A  # noqa: E402

FS = 100.0
CATCH_LOW, CATCH_HIGH = -0.5, 0.5     # gx hysteresis for the catch flip
CATCH_MAX_RISE_S = 0.3                # floor -> rack flip time (cleans 0.17-0.19 s, glances >= 0.34 s)
CATCH_MIN_G = 3.5                     # |userAccel| peak within 1 s before / 0.3 s after the flip
LOCK_GX, LOCK_GY, LOCK_HOLD_S = 0.93, 0.2, 0.3
SET_GAP_S = 30.0                      # reps closer than this belong to one set (EMOM)
# owner's loads (README.md): the workout definition says 85 kg for Freedom, the bar was 155 lb
EMOM_LOADS_LB = [125, 135, 145, 145, 155, 155, 165, 175]
FREEDOM_LOAD_LB = 155
LB = 0.45359237
TNG_GAP_S = 3.5                       # catch-to-catch gap below this = touch-and-go
PULL_START_V = 0.15                   # m/s: pull start = last time before the clean peak v < this


# ---- loading / signals ------------------------------------------------------------------------

class Session:
    def __init__(self, csv_path, json_path):
        csv = load_session_csv(csv_path)
        self.wk = json.load(open(json_path))
        self.t0 = csv.start_date.timestamp()
        m = csv.motion
        self.motion = m
        self.t = m.t
        a, g = m.user_accel, m.gravity
        gu = g / np.maximum(np.linalg.norm(g, axis=1), 1e-6)[:, None]
        self.gx = bandpass(g[:, 0], 0, 2.0)
        self.gy = bandpass(g[:, 1], 0, 2.0)
        self.amag = np.linalg.norm(a, axis=1)
        up = (a * gu).sum(1) * 9.81                      # m/s^2, + = up (see module docstring)
        self.v = bandpass(np.cumsum(bandpass(up, 0.1, 4.0)) / FS, 0.12, 4.0)
        ev = self.wk["events"]
        self.start = ev[0]["t"] - self.t0
        self.finish = next((e["t"] for e in ev if e["kind"] == "finish"), None)
        self.end = next((e["t"] for e in ev if e["kind"] == "end"), None)
        self.finish_s = None if self.finish is None else self.finish - self.t0
        self.segs = [dict(s, s0=s["start"] - self.t0, s1=s["end"] - self.t0) for s in self.wk["segments"]]

    def i(self, ts):
        return int(np.clip(np.searchsorted(self.t, ts), 0, len(self.t) - 1))


def find(folder, workout_id):
    for jp in glob.glob(str(Path(folder) / "workout-*.json")):
        wk = json.load(open(jp))
        if wk["definition"]["id"] == workout_id:
            return Session(str(Path(folder) / wk["recordingFileName"]), jp)
    raise FileNotFoundError(workout_id)


# ---- rep detection ------------------------------------------------------------------------------

def catches(S, t_from=-1e9, t_to=1e9):
    """Clean catches: [{catch, pull_start, v_clean, g_peak}] in session seconds."""
    gx, out, state, last_low = S.gx, [], None, 0
    i0, i1 = S.i(t_from), S.i(t_to)
    for i in range(i0, i1):
        if gx[i] < CATCH_LOW:
            last_low = i
        if gx[i] > CATCH_HIGH and state != "up":
            if state == "down" and (i - last_low) / FS <= CATCH_MAX_RISE_S:
                j = i
                while j < len(gx) - 1 and gx[j] > 0.0 and j - i < 15 * FS:
                    j += 1
                gpk = S.amag[max(0, i - 100):i + 30].max()
                if gpk >= CATCH_MIN_G and S.gy[i:j].mean() > 0.0:
                    out.append(_phases(S, i, j))
            state = "up"
        elif gx[i] < CATCH_LOW and state != "down":
            state = "down"
    return out


def _phases(S, i, j):
    """Phases of one rep: i = catch sample, j = first sample after it with gx < 0 (lowering)."""
    t, v = S.t, S.v
    a = max(0, i - 100)
    k = a + int(np.argmax(v[a:i + 5]))                    # clean peak upward velocity
    p, lim = k, max(0, i - int(3 * FS))
    while p > lim and v[p] > PULL_START_V:
        p -= 1
    rep = {"catch": float(t[i]), "pull_start": float(t[p]), "v_clean": float(v[k]),
           "g_peak": float(S.amag[a:i + 30].max()), "down": float(t[j]), "lockout": None}
    # lockout: gx > 0.93 and |gy| < 0.2 for >= 0.3 s, between 0.5 s after the catch and lowering
    ok = (S.gx > LOCK_GX) & (np.abs(S.gy) < LOCK_GY)
    hold = int(LOCK_HOLD_S * FS)
    for q in range(i + 50, min(j, i + int(6 * FS)) - hold):
        if ok[q:q + hold].all():
            d0 = max(i + 30, q - 150)
            dip = d0 + int(np.argmin(v[d0:q]))              # jerk dip: lowest v before lockout
            drv = dip + int(np.argmax(v[dip:q + 20]))       # drive: highest v after the dip
            rep.update(lockout=float(t[q]), dip=float(t[dip]), v_dip=float(v[dip]),
                       v_jerk=float(v[drv]))
            break
    return rep


def glances(S, t_from, t_to):
    """Wrist raised to look at the watch: gx 0.3-0.93 with gy < -0.4 held >= 0.7 s, quiet."""
    i0, i1 = S.i(t_from), S.i(t_to)
    m = (S.gx[i0:i1] > 0.3) & (S.gx[i0:i1] < LOCK_GX) & (S.gy[i0:i1] < -0.4)
    return [float(S.t[i0 + a]) for a, b in A.bouts(m, int(0.7 * FS), int(0.5 * FS))]


def row_strokes(S, s0, s1):
    """Erg strokes inside [s0, s1). Candidate strokes = maxima of gx band-passed 0.15-1 Hz, >= 1.5 s
    apart, where the raw (2 Hz) gx > 0 (forearm swung up at the finish) and gz < -0.5 (hands on
    the handle). Rowing = from the first candidate that starts a run of 5 with every gap 1.5-4.5 s
    to the last candidate that ends such a run; strokes = candidates in between. (The amrap40
    cyclic window keeps only the longest correlated run and lost most of rounds 3 and 5 here; a
    rolling-SD mask started rows while the athlete was still putting the bar down.)
    Returns (first stroke, last stroke, mean period s, strokes), seconds from s0, or None."""
    i0, i1 = S.i(s0), S.i(s1)
    gx, gz = S.gx[i0:i1], bandpass(S.motion.gravity[i0:i1, 2], 0, 2.0)
    x = bandpass(gx, 0.15, 1.0)
    gzm = rolling(gz, int(2 * FS), "mean")
    k = [q for q in A.peaks(x, int(1.5 * FS), 0.1) if gzm[q] < -0.5]
    ts = [q / FS for q in k]
    ok = lambda j: all(1.5 <= ts[j + n + 1] - ts[j + n] <= 4.5 for n in range(4))
    first = next((j for j in range(len(ts) - 4) if ok(j)), None)
    last = next((j + 4 for j in range(len(ts) - 5, -1, -1) if ok(j)), None)
    if first is None:
        return None
    n = last - first + 1
    return ts[first], ts[last], (ts[last] - ts[first]) / max(n - 1, 1), n


# ---- helpers --------------------------------------------------------------------------------------

def mmss(x):
    if x is None or not math.isfinite(x):
        return "-"
    s = "-" if x < 0 else ""
    x = abs(int(round(x)))
    return f"{s}{x // 60}:{x % 60:02d}"


def f(x, d=1):
    return "-" if x is None or (isinstance(x, float) and not math.isfinite(x)) else f"{x:.{d}f}"


def hr_series(S):
    return HeartRateSeries.from_dict(S.wk["heartRateSeries"])


def hr_window(S, a, b):
    """(mean, max) of the 5 s series buckets whose centre lies in [a, b) (session seconds)."""
    hs = hr_series(S)
    vals = [v for k, v in enumerate(hs.bpm)
            if v is not None and a <= hs.start - S.t0 + (k + 0.5) * hs.interval < b]
    return (float(np.mean(vals)), float(np.max(vals))) if vals else (float("nan"), float("nan"))


def recovery_lines(S):
    rec = HeartRateRecovery.make(hr_series(S), S.finish, S.end)
    hs = hr_series(S)
    out = ["| | HR | drop |", "|---|---:|---:|"]
    if rec is None:
        return out + ["| (not enough after the finish) | | |"]
    out.append(f"| at finish (peak of last 10 s) | {rec.heart_rate_at_finish:.0f} | |")
    for mk in rec.marks:
        out.append(f"| +{mk.seconds:.0f} s (±7.5 s mean) | {mk.heart_rate:.0f} | {mk.drop:+.0f} |")
    out.append(f"| recorded after finish | {rec.covered_seconds:.0f} s | |")
    k0 = int((S.finish - hs.start) // hs.interval)
    tail = [v for v in hs.bpm[k0:] if v is not None]
    out.append(f"\n5 s series finish → End: {', '.join(f'{v:.0f}' for v in tail)}")
    return out


# ---- workout 1: power C&J EMOM ---------------------------------------------------------------------

def emom(folder):
    S = find(folder, "wod.pcjEmom")
    iv = S.wk["definition"].get("intervalSeconds", 60.0)
    nsets = sum(1 for s in S.wk["definition"]["segments"] if s["kind"] == "station")
    reps = catches(S)
    work = [r for r in reps if S.finish_s is None or r["catch"] <= S.finish_s + 20]
    after = [r for r in reps if r not in work]
    sets = []
    for r in work:
        if sets and r["pull_start"] - sets[-1][-1]["down"] < SET_GAP_S:
            sets[-1].append(r)
        else:
            sets.append([r])
    L = []
    P = L.append
    P(f"Start {S.start:+.2f} s (session time), minute marks every {iv:.0f} s, {nsets} sets planned, "
      f"finish (Crown) at {mmss(S.finish_s - S.start)}.\n")
    P("### Every rep (session seconds; m:ss = since start)\n")
    P("| set | rep | pull start | catch (rack) | lockout | down | pull s | rack s | jerk dip→lockout s | "
      "overhead s | clean peak v m/s | jerk dip v | jerk drive v | peak g |")
    P("|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    for k, st in enumerate(sets, 1):
        for n, r in enumerate(st, 1):
            lk = r["lockout"]
            P(f"| {k} | {n} | {r['pull_start']:.1f} ({mmss(r['pull_start'] - S.start)}) | {r['catch']:.1f} | "
              f"{f(lk)} | {r['down']:.1f} | {r['catch'] - r['pull_start']:.2f} | "
              f"{f(r['dip'] - r['catch'] if lk else None)} | {f(lk - r['dip'] if lk else None, 2)} | "
              f"{f(r['down'] - lk if lk else None)} | {r['v_clean']:.2f} | {f(r.get('v_dip'), 2)} | "
              f"{f(r.get('v_jerk'), 2)} | {r['g_peak']:.1f} |")
    for r in after:
        P(f"| after finish | | {r['pull_start']:.1f} | {r['catch']:.1f} | {f(r['lockout'])} | {r['down']:.1f} | "
          f"{r['catch'] - r['pull_start']:.2f} | | | | {r['v_clean']:.2f} | | | {r['g_peak']:.1f} |")
    nl = sum(1 for r in work if r["lockout"])
    P(f"\n{len(work)} catches before the finish, {nl} with a jerk lockout; {len(after)} after the finish.\n")

    P("### Sets vs the minute marks\n")
    P("| set | minute (mark) | reps | first pull after mark s | set duration s (pull → last down) | "
      "rest until next mark s | HR avg / max in the minute |")
    P("|---:|---|---:|---:|---:|---:|---|")
    set_rows = []
    for k, st in enumerate(sets, 1):
        a, b = st[0]["pull_start"], st[-1]["down"]
        mi = int((a - S.start) // iv)
        mark = S.start + mi * iv
        rest = mark + iv - b
        ha, hm = hr_window(S, mark, mark + iv)
        set_rows.append((k, mi, mark, a, b))
        P(f"| {k} | {mi + 1} ({mmss(mi * iv)}) | {len(st)} | {a - mark:.1f} | {b - a:.1f} | {rest:.1f} | "
          f"{ha:.0f} / {hm:.0f} |")
    offs = [a - mark for _, _, mark, a, _ in set_rows]
    durs = [b - a for _, _, _, a, b in set_rows]
    P(f"\nFirst pull {min(offs):.1f}-{max(offs):.1f} s after the mark (median {np.median(offs):.1f}); "
      f"sets last {min(durs):.1f}-{max(durs):.1f} s (median {np.median(durs):.1f}).\n")

    P("### Watch segments vs what happened\n")
    P("| seg | kind | source of start | start | end | dur s | should start at (EMOM clock) | error s | "
      "reps inside (set#) |")
    P("|---:|---|---|---|---|---:|---|---:|---|")
    src = {e["segmentIndex"]: e.get("source", e["kind"]) for e in S.wk["events"] if e["kind"] in ("start", "advance")}
    for s in S.segs:
        idx = s["index"]
        # ideal EMOM: station k starts at mark k, rest k starts when set k ends
        k = idx // 2
        if s["kind"] == "station":
            ideal = S.start + k * iv
        else:
            ideal = set_rows[k][4] if k < len(set_rows) else float("nan")
        inside = [f"{n}" for n, st in enumerate(sets, 1) for r in st if s["s0"] <= r["catch"] < s["s1"]]
        P(f"| {idx} | {s['kind']} | {src.get(idx, '-')} | {mmss(s['s0'] - S.start)} | {mmss(s['s1'] - S.start)} | "
          f"{s['s1'] - s['s0']:.1f} | {mmss(ideal - S.start)} | {s['s0'] - ideal:+.1f} | "
          f"{len(inside)} ({','.join(sorted(set(inside), key=int))}) |")
    g = glances(S, S.start, (S.end or S.t[-1]) - S.t0 if S.end else S.t[-1])
    P(f"\nWatch glances (wrist raised to read the screen): {', '.join(mmss(x - S.start) for x in g)}.\n")

    P("### Bar-speed proxy by set (mean of the reps)\n")
    P("| set | load lb (kg) | clean peak v m/s | jerk drive v m/s | jerk dip v m/s | pull s | rack s | overhead s |")
    P("|---:|---|---:|---:|---:|---:|---:|---:|")
    for k, st in enumerate(sets, 1):
        lk = [r for r in st if r["lockout"]]
        lb = EMOM_LOADS_LB[k - 1] if k <= len(EMOM_LOADS_LB) else None
        P(f"| {k} | {lb if lb else '-'} ({f(lb * LB if lb else None, 0)}) | {np.mean([r['v_clean'] for r in st]):.2f} | "
          f"{f(np.mean([r['v_jerk'] for r in lk]) if lk else None, 2)} | "
          f"{f(np.mean([r['v_dip'] for r in lk]) if lk else None, 2)} | "
          f"{np.mean([r['catch'] - r['pull_start'] for r in st]):.2f} | "
          f"{f(np.mean([r['dip'] - r['catch'] for r in lk]) if lk else None)} | "
          f"{f(np.mean([r['down'] - r['lockout'] for r in lk]) if lk else None)} |")
    vc = [r["v_clean"] for r in work]
    if len(vc) > 2:
        sl = np.polyfit(np.arange(len(vc)), vc, 1)[0]
        P(f"\nClean peak v trend: {sl * len(vc):+.2f} m/s over the {len(vc)} reps (linear fit).\n")
    if len(sets) == len(EMOM_LOADS_LB):
        x = np.array([EMOM_LOADS_LB[k] for k, st in enumerate(sets) for _ in st], float) * LB
        y = np.array([r["v_clean"] for st in sets for r in st])
        b1, b0 = np.polyfit(x, y, 1)
        rr = np.corrcoef(x, y)[0, 1]
        yj = np.array([r["v_jerk"] for st in sets for r in st if r["lockout"]])
        xj = np.array([EMOM_LOADS_LB[k] for k, st in enumerate(sets) for r in st if r["lockout"]], float) * LB
        j1 = np.polyfit(xj, yj, 1)[0]
        P(f"Load-velocity (clean peak v vs kg, per rep): slope {b1 * 10:+.3f} m/s per 10 kg, r = {rr:+.2f}; "
          f"fit {b0 + b1 * 125 * LB:.2f} m/s at 125 lb -> {b0 + b1 * 175 * LB:.2f} m/s at 175 lb. Jerk drive v slope {j1 * 10:+.3f} m/s per 10 kg, "
          f"r = {np.corrcoef(xj, yj)[0, 1]:+.2f}.\n")

    P("### Heart rate\n")
    P("| seg | kind | avg | max (JSON) |")
    P("|---:|---|---:|---:|")
    for s in S.segs:
        P(f"| {s['index']} | {s['kind']} | {f(s.get('heartRateAvg'), 0)} | {f(s.get('heartRateMax'), 0)} |")
    P(f"\nWorkout avg {S.wk['heartRateAvg']:.0f}, max {S.wk['heartRateMax']}.\n")
    P("Recovery (HeartRateRecovery rules):\n")
    L.extend(recovery_lines(S))
    return "\n".join(L)


# ---- workout 2: Freedom -------------------------------------------------------------------------

def freedom(folder):
    S = find(folder, "wod.freedom")
    L = []
    P = L.append
    rows = [s for s in S.segs if s["movement"] == "row"]
    pcs = [s for s in S.segs if s["movement"] != "row"]
    rnd = []
    for k, (ro, pc) in enumerate(zip(rows, pcs), 1):
        st = row_strokes(S, ro["s0"], ro["s1"])
        on = work_onset("row", S.motion, ro["s0"], ro["s1"])
        reps = catches(S, pc["s0"] - 2, pc["s1"] + 2)
        rnd.append({"k": k, "row": ro, "pc": pc, "strokes": st, "onset": on, "reps": reps})
    target = sum(int(s["target"]["value"]) for s in S.wk["definition"]["segments"] if s["movement"] != "row")

    P(f"Power cleans at {FREEDOM_LOAD_LB} lb ({FREEDOM_LOAD_LB * LB:.0f} kg, owner; the definition says "
      f"{S.wk['definition']['segments'][1].get('load', {}).get('value', '?')} kg).\n")
    P(f"Start {S.start:+.2f} s, finish {mmss(S.finish_s - S.start)} (Crown), End {mmss(S.end - S.t0 - S.start)}.\n")
    P("### Rounds\n")
    P("| round | row cal | row segment | strokes window (from seg start) | strokes | period s | rate /min | "
      "cal/stroke | transitions.py row onset s (method, conf) | cleans segment | reps found | clean window |")
    P("|---:|---:|---|---|---:|---:|---:|---:|---|---|---:|---|")
    for R in rnd:
        ro, pc, st = R["row"], R["pc"], R["strokes"]
        cal = S.wk["definition"]["segments"][ro["index"]]["target"]["value"]
        o = R["onset"]
        if st:
            a, b, p, n = st
            stx = f"{a:.0f}-{b:.0f} | {n} | {p:.2f} | {60 / p:.1f} | {cal / n:.2f}"
        else:
            stx = "- | - | - | - | -"
        reps = R["reps"]
        cw = f"{mmss(reps[0]['pull_start'] - S.start)}-{mmss(reps[-1]['down'] - S.start)}" if reps else "-"
        P(f"| {R['k']} | {cal:.0f} | {mmss(ro['s0'] - S.start)}-{mmss(ro['s1'] - S.start)} ({ro['s1'] - ro['s0']:.0f} s) | "
          f"{stx} | {f(o.onset)} ({o.method}, {o.confidence:.2f}) | "
          f"{mmss(pc['s0'] - S.start)}-{mmss(pc['s1'] - S.start)} ({pc['s1'] - pc['s0']:.0f} s) | "
          f"**{len(reps)}** | {cw} |")
    tot = sum(len(R["reps"]) for R in rnd)
    P(f"\nPower cleans found: **{tot}** of {target}.\n")

    P("### Transitions (from motion; Crown = the watch's segment boundary)\n")
    P("| round | last stroke → Crown s | Crown → first pull s | **row → bar** (last stroke → first pull) s | "
      "last clean down → Crown s | Crown → first stroke s | **bar → row** (last clean down → first stroke) s |")
    P("|---:|---:|---:|---:|---:|---:|---:|")
    for n, R in enumerate(rnd):
        ro, pc, st, reps = R["row"], R["pc"], R["strokes"], R["reps"]
        last_stroke = ro["s0"] + st[1] if st else float("nan")
        fp = reps[0]["pull_start"] if reps else float("nan")
        ld = reps[-1]["down"] if reps else float("nan")
        if n + 1 < len(rnd):
            nr = rnd[n + 1]
            nst = nr["strokes"]
            first_stroke = nr["row"]["s0"] + (nst[0] if nst else nr["onset"].onset)
            crown_b = pc["s1"]
            b2r = (f"{ld and crown_b - ld:.1f} | {first_stroke - crown_b:.1f} | **{first_stroke - ld:.1f}**")
        else:
            b2r = f"{pc['s1'] - ld:.1f} (finish) | - | -"
        P(f"| {R['k']} | {ro['s1'] - last_stroke:.1f} | {fp - ro['s1']:.1f} | **{fp - last_stroke:.1f}** | {b2r} |")
    P("")

    P("### Every power clean\n")
    P("| round | rep | pull start (m:ss) | catch s | gap to previous catch s | style | pull s | rack s (catch → down) | "
      "clean peak v m/s | peak g |")
    P("|---:|---:|---|---:|---:|---|---:|---:|---:|---:|")
    allrep = []
    for R in rnd:
        prev = None
        for n, r in enumerate(R["reps"], 1):
            gap = r["catch"] - prev if prev is not None else float("nan")
            style = "-" if prev is None else ("touch-and-go" if gap < TNG_GAP_S else "single")
            prev = r["catch"]
            allrep.append((R["k"], n, r, gap))
            P(f"| {R['k']} | {n} | {mmss(r['pull_start'] - S.start)} | {r['catch']:.1f} | {f(gap)} | {style} | "
              f"{r['catch'] - r['pull_start']:.2f} | {r['down'] - r['catch']:.1f} | {r['v_clean']:.2f} | {r['g_peak']:.1f} |")
    P("")
    lk = [r for _, _, r, _ in allrep if r["lockout"]]
    P(f"Jerk-lockout check on the cleans (should be none): {len(lk)}.\n")

    P("### Pace and speed proxy per round\n")
    P("| round | reps | first pull → last down s | median gap s (min-max) | singles / TnG | sec per rep | "
      "clean peak v mean m/s (min-max) | rack s mean | HR avg / max row | HR avg / max cleans |")
    P("|---:|---:|---:|---|---|---:|---|---:|---|---|")
    for R in rnd:
        reps = R["reps"]
        if not reps:
            continue
        gaps = np.diff([r["catch"] for r in reps])
        span = reps[-1]["down"] - reps[0]["pull_start"]
        vs = [r["v_clean"] for r in reps]
        ro, pc = R["row"], R["pc"]
        P(f"| {R['k']} | {len(reps)} | {span:.1f} | {np.median(gaps):.1f} ({gaps.min():.1f}-{gaps.max():.1f}) | "
          f"{int((gaps >= TNG_GAP_S).sum())} / {int((gaps < TNG_GAP_S).sum())} | {span / len(reps):.1f} | "
          f"{np.mean(vs):.2f} ({min(vs):.2f}-{max(vs):.2f}) | {np.mean([r['down'] - r['catch'] for r in reps]):.1f} | "
          f"{f(ro.get('heartRateAvg'), 0)} / {f(ro.get('heartRateMax'), 0)} | "
          f"{f(pc.get('heartRateAvg'), 0)} / {f(pc.get('heartRateMax'), 0)} |")
    vc = [r["v_clean"] for _, _, r, _ in allrep]
    if len(vc) > 2:
        sl = np.polyfit(np.arange(len(vc)), vc, 1)[0]
        P(f"\nClean peak v trend: {sl * len(vc):+.2f} m/s over the {len(vc)} reps (linear fit).\n")

    P("### Time budget\n")
    row_t = sum(r["strokes"][1] - r["strokes"][0] for r in rnd if r["strokes"])
    cl_t = sum(R["reps"][-1]["down"] - R["reps"][0]["pull_start"] for R in rnd if R["reps"])
    total = S.finish_s - S.start
    P(f"Rowing (stroke windows) {mmss(row_t)}, cleans (first pull → last down) {mmss(cl_t)}, "
      f"everything else (transitions, set-up, start) {mmss(total - row_t - cl_t)} of {mmss(total)}.\n")

    P("### Heart-rate recovery (HeartRateRecovery rules)\n")
    L.extend(recovery_lines(S))
    return "\n".join(L)


def main(argv):
    folder = argv[0] if argv else "data/raw/2026-11-02-pcj-emom-freedom"
    print("## Workout 1 · Every 1:00 × 8 power clean & jerk\n")
    print(emom(folder))
    print("\n## Workout 2 · Freedom\n")
    print(freedom(folder))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
