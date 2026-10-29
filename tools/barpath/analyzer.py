"""Offline lift analyzer — Python reference of BarPathKit's LiftAnalyzer (spec §5).

Interpretations of points the spec leaves open (the Swift port must match):
  * Stillness EMAs start at 0, first sample dt = 0, dt = clamp(t_i - t_{i-1}, 0, 0.05)
    (identical to the detector).
  * A still run's duration is t[last] - t[first].
  * Homing test: from the run's last sample s, v_up is integrated with the trapezoid rule;
    the run qualifies if v_up >= startVelocity at some sample i with t_i - t_s <= startWindow.
  * Anchors are the still runs that start after the homing index with duration >= anchorMinStill.
  * Sign (agreed change to §5): aW = -rot(userAccel)·G, gravity-only vertical = +(aDev·ĝ).
  * Path-end drop test for an anchor: the "open-ended tail" runs from the anchor's last sample
    to the first sample of the next anchor (or to the end of the data), integrated from v = 0
    without drift removal; a drop is min(z_tail) < z_anchor - dropDistance.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List, Optional, Tuple

import numpy as np

from .geometry import G, normalize, quat_conj, quat_rotate
from .recording import LiftRecording

NOTE_GRAVITY_ONLY = "Orientation unavailable: vertical only"
NOTE_PSEUDO_ANCHOR = "No still hold at the finish: end estimated at the calmest point before the drop"
NOTE_LATERAL = "Large sideways drift: horizontal path unreliable"
NOTE_END_OVER_START = "Forward/back estimated: assumes the bar finishes above where it started"
NOTE_NO_ANCHOR = "No still recovery found: path uncorrected"
NOTE_FORWARD_ESTIMATED = "Forward direction estimated"


class AnalysisError(Exception):
    pass


class TooShort(AnalysisError):
    pass


class NoHomingFound(AnalysisError):
    pass


@dataclass(frozen=True)
class AnalyzerConfig:
    emaTau: float = 0.08
    stillRot: float = 0.5
    stillAcc: float = 0.06
    homingMinStill: float = 0.2
    startVelocity: float = 0.5
    startWindow: float = 1.0
    anchorMinStill: float = 0.25
    dropDistance: float = 0.5
    maxUncorrectedDuration: float = 3.0
    armsUpMax: float = 0.3        # forearm 'up' (turned over) when hang < this
    armsDownMin: float = 0.8      # forearm back 'down' (bar released) when hang > this
    pseudoAnchorWindow: float = 1.0  # search the calmest point in this window before arms-down
    pseudoAnchorSmooth: float = 0.1  # s, moving-average width for the calmness score
    driftWeighting: str = "accel"    # "time" | "accel" | "accelRot" (Revision E: accel)
    pseudoAnchorMode: str = "auto"   # "auto" | "zupt" | "endOnly" (auto: endOnly for cleans)
    leverForearm: float = 0.109      # m, wrist→bar offset along the forearm toward the hand
    leverNormal: float = -0.026      # m, along the watch-face normal (− = below the face)
    endOverStart: bool = True        # horizontal prior: the bar finishes above the start
    pseudoAnchorRule: str = "calm"   # "calm" | "preDrop"
    dropOnsetAccel: float = 0.1     # g, vertical accel below -this = the drop has begun
    preDropWindow: float = 0.3      # s, search window before the drop onset
    catchRiseVelocity: float = 0.15  # m/s, vz above this after the catch = stand-up has begun
    maxLateral: float = 0.15         # m, sideways excursion above this lowers confidence


# The simulator's ground truth is the WRIST trajectory; tests that compare against it use
# the Revision-D behaviour (no lever arm, no end-over-start prior, linear drift removal).
WRIST_REFERENCE = AnalyzerConfig(driftWeighting="time", pseudoAnchorMode="zupt", leverForearm=0.0,
                                 leverNormal=0.0, endOverStart=False)


@dataclass
class PathSample:
    t: float
    forward: float
    lateral: float
    vertical: float
    vForward: float
    vVertical: float
    speed: float


@dataclass
class PathSeries:
    """Columnar form of [PathSample] (index i <-> PathSample i)."""
    t: np.ndarray
    forward: np.ndarray
    lateral: np.ndarray
    vertical: np.ndarray
    vForward: np.ndarray
    vVertical: np.ndarray
    speed: np.ndarray

    def __len__(self) -> int:
        return len(self.t)

    def __getitem__(self, i: int) -> PathSample:
        return PathSample(*(float(getattr(self, k)[i]) for k in
                            ("t", "forward", "lateral", "vertical", "vForward", "vVertical", "speed")))


@dataclass
class LiftSegment:
    startIndex: int
    endIndex: int
    duration: float
    peakVerticalVelocity: float
    heightGain: float
    maxHeight: float
    minHeight: float
    driftCorrection: float


@dataclass
class LiftMetrics:
    peakVerticalVelocity: float
    timeToPeakVelocity: float
    maxHeight: float
    catchHeight: Optional[float]
    dropUnderBar: Optional[float]
    finalHeight: float
    maxForward: float
    maxBackward: float
    duration: float


@dataclass
class LiftAnalysis:
    recordingId: str
    homingIndex: int
    endIndex: int
    path: PathSeries
    segments: List[LiftSegment]
    metrics: LiftMetrics
    confidence: str  # "high" | "medium" | "low"
    notes: List[str] = field(default_factory=list)
    # extras (not in the Swift struct, handy for plotting/debugging)
    quaternionMode: str = "direct"  # "direct" | "conjugate" | "gravityOnly"
    anchorRuns: List[Tuple[int, int]] = field(default_factory=list)


# ---------------------------------------------------------------------------------------------

def stillness_mask(t, user_accel, rotation_rate, emaTau, stillRot, stillAcc, reverse: bool = False) -> np.ndarray:
    """§4 EMA stillness, run forward (or, with reverse=True, backward in time: the same recursion
    over samples n-1 ... 0 with dt_i = clamp(t_{i+1} - t_i, 0, 0.05))."""
    n = len(t)
    still = np.zeros(n, dtype=bool)
    rot_n = np.linalg.norm(rotation_rate, axis=1)
    acc_n = np.linalg.norm(user_accel, axis=1)
    rot_ema = acc_ema = 0.0
    order = range(n - 1, -1, -1) if reverse else range(n)
    prev = None
    for i in order:
        dt = 0.0 if prev is None else min(max((t[prev] - t[i]) if reverse else (t[i] - t[prev]), 0.0), 0.05)
        prev = i
        a = min(1.0, dt / emaTau) if emaTau > 0 else 1.0
        rot_ema += a * (rot_n[i] - rot_ema)
        acc_ema += a * (acc_n[i] - acc_ema)
        still[i] = rot_ema < stillRot and acc_ema < stillAcc
    return still


def still_runs(mask: np.ndarray) -> List[Tuple[int, int]]:
    """Maximal runs of True as (first, last) inclusive index pairs."""
    runs = []
    n = len(mask)
    i = 0
    while i < n:
        if mask[i]:
            j = i
            while j + 1 < n and mask[j + 1]:
                j += 1
            runs.append((i, j))
            i = j + 1
        else:
            i += 1
    return runs


def principal_axis(xy: np.ndarray) -> np.ndarray:
    """Principal eigenvector of the 2x2 population covariance of xy (N,2):
    (lambda - syy, sxy) normalised; if sxy ~ 0, the axis with the larger variance."""
    d = xy - xy.mean(axis=0)
    sxx = float(np.mean(d[:, 0] ** 2))
    syy = float(np.mean(d[:, 1] ** 2))
    sxy = float(np.mean(d[:, 0] * d[:, 1]))
    if abs(sxy) < 1e-12:
        return np.array([1.0, 0.0]) if sxx >= syy else np.array([0.0, 1.0])
    lam = 0.5 * (sxx + syy) + np.sqrt(0.25 * (sxx - syy) ** 2 + sxy * sxy)
    e = np.array([lam - syy, sxy])
    return e / np.linalg.norm(e)


def _cumtrapz(y: np.ndarray, t: np.ndarray) -> np.ndarray:
    """Cumulative trapezoid along axis 0, starting at 0."""
    out = np.zeros_like(y, dtype=float)
    if len(t) > 1:
        dt = np.diff(t)
        inc = 0.5 * (y[1:] + y[:-1]) * (dt if y.ndim == 1 else dt[:, None])
        out[1:] = np.cumsum(inc, axis=0)
    return out


CLEAN_TYPES = ("clean", "powerClean", "hangClean")


def _drift_weights(a, rot, t, mode: str) -> np.ndarray:
    """Cumulative 0→1 weights for distributing a segment's velocity drift.

    "time": linear in time (spec §5). "accel": proportional to the accumulated |a|
    above 1 g-equivalent of motion… concretely ∫|a_world| dt, so the drift is attributed
    to the violent phases (pull, turnover, catch impact) where the sensor error is made.
    "accelRot": ∫|a|·|ω| dt."""
    n = len(t)
    if n < 2 or t[-1] <= t[0]:
        return np.zeros(n)
    if mode == "time":
        return (t - t[0]) / (t[-1] - t[0])
    an = np.linalg.norm(a, axis=1)
    if mode == "accelRot":
        w = an * np.linalg.norm(rot, axis=1)
    else:
        w = an
    c = np.concatenate([[0.0], np.cumsum(0.5 * (w[1:] + w[:-1]) * np.diff(t))])
    return c / c[-1] if c[-1] > 0 else (t - t[0]) / (t[-1] - t[0])


def world_acceleration(rec: LiftRecording):
    """Returns (aW (N,3) m/s² with world z up, rotation quaternions or None, mode).

    aDev = userAccel·G; userAccel is -a/G (physical CoreMotion convention), so aW = -rot(aDev);
    gravity-only vertical = +(aDev·ĝ)."""
    m = rec.motion
    a_dev = m.user_accel * G
    q = m.q
    qn = normalize(q)
    zA = float(np.median(quat_rotate(qn, m.gravity)[:, 2]))
    zB = float(np.median(quat_rotate(quat_conj(qn), m.gravity)[:, 2]))
    best, mode = (zA, "direct") if abs(zA + 1) <= abs(zB + 1) else (zB, "conjugate")
    if best < -0.8:
        qq = qn if mode == "direct" else quat_conj(qn)
        aW = -quat_rotate(qq, a_dev)       # userAccel = -a/G (physical convention)
        return aW, qq, mode
    ghat = normalize(m.gravity)
    vert = np.sum(a_dev * ghat, axis=1)    # +(aDev·ĝ): up, since userAccel = -a/G
    aW = np.zeros_like(a_dev)
    aW[:, 2] = vert
    return aW, None, "gravityOnly"


def analyze(rec: LiftRecording, config: AnalyzerConfig = AnalyzerConfig(), *, spec_literal: bool = False) -> LiftAnalysis:
    c = config
    m = rec.motion
    n = len(m)
    if n < 2:
        raise TooShort("recording has fewer than 2 samples")
    t = m.t
    notes: List[str] = []

    # 1. world frame
    aW, qq, mode = world_acceleration(rec)
    if mode == "gravityOnly":
        notes.append(NOTE_GRAVITY_ONLY)

    # 2. stillness (forward, as §4) + backward pass used to find the true end of each still run
    still = stillness_mask(t, m.user_accel, m.rotation_rate, c.emaTau, c.stillRot, c.stillAcc)
    runs = still_runs(still)
    if spec_literal:
        def release(run):
            return run[1]
    else:
        still_b = stillness_mask(t, m.user_accel, m.rotation_rate, c.emaTau, c.stillRot, c.stillAcc,
                                 reverse=True)

        def release(run):
            """Last sample of the run that the backward EMA also calls still (the causal EMA
            keeps saying 'still' for ~emaTau after motion has started)."""
            r0, r1 = run
            idx = np.nonzero(still_b[r0:r1 + 1])[0]
            return r0 + int(idx[-1]) if len(idx) else r0

    # 3. homing
    homing_idx = None
    homing_run = None
    for run in runs:
        r0, r1 = run
        if t[r1] - t[r0] < c.homingMinStill:
            continue
        s0 = release(run)
        j1 = int(np.searchsorted(t, t[s0] + c.startWindow, side="right"))
        if j1 - s0 < 2:
            continue
        v = _cumtrapz(aW[s0:j1, 2], t[s0:j1])
        if np.any(v >= c.startVelocity):
            homing_idx, homing_run = s0, run
            break
    if homing_idx is None:
        if rec.homing_time is None:
            raise NoHomingFound("no still run followed by a pull, and no homingTime")
        homing_idx = int(np.argmin(np.abs(t - rec.homing_time)))
        homing_run = next(((r0, r1) for (r0, r1) in runs if r0 <= homing_idx <= r1),
                          (homing_idx, homing_idx))
        notes.append("Homing taken from the watch estimate")
    if t[-1] - t[homing_idx] < 0.5:
        raise TooShort("less than 0.5 s of data after homing")

    # 4. anchors: (first, release, last) — v is forced to 0 on [first, release]
    anchors = [(r0, release((r0, r1)), r1) for (r0, r1) in runs
               if r0 > homing_run[1] and t[r1] - t[r0] >= c.anchorMinStill]

    # 4b. arms-down: after the turnover the forearm points up; when it points down again the
    # bar has been dropped/lowered. Everything after that is not part of the lift.
    arms_down_idx = None
    pseudo_end = None
    if not spec_literal:
        r0h, r1h = homing_run
        ghat = normalize(m.gravity)
        hang_sign = 1.0 if np.mean(ghat[r0h:r1h + 1, 0]) >= 0 else -1.0
        hang = hang_sign * ghat[:, 0]
        up_idx = next((i for i in range(homing_idx, n) if hang[i] < c.armsUpMax), None)
        if up_idx is not None:
            arms_down_idx = next((i for i in range(up_idx, n) if hang[i] > c.armsDownMin), None)
        if arms_down_idx is not None:
            anchors = [a for a in anchors if a[0] < arms_down_idx]
            if not any(a[0] > up_idx for a in anchors):
                # no still hold at the finish: the lifter is (nearly) at rest just before the
                # drop, so use the calmest point of the last second before arms-down
                calm = np.linalg.norm(m.user_accel, axis=1) + 0.05 * np.linalg.norm(m.rotation_rate, axis=1)
                dt_med = float(np.median(np.diff(t))) if n > 1 else 0.005
                w = max(1, int(round(c.pseudoAnchorSmooth / dt_med)))
                calm_s = np.convolve(calm, np.ones(w) / w, mode="same")
                j0 = max(up_idx, int(np.searchsorted(t, t[arms_down_idx] - c.pseudoAnchorWindow)))
                j1 = arms_down_idx
                if c.pseudoAnchorRule == "preDrop":
                    # The drop/lowering starts with the bar falling (vertical accel well below 0).
                    # Search the calm point just BEFORE that onset, so a steady stand-up isn't
                    # mistaken for the bar being at rest.
                    a_up_s = np.convolve(aW[:, 2], np.ones(w) / w, mode="same")
                    d = j1
                    while d > j0 and a_up_s[d] < -c.dropOnsetAccel * G:
                        d -= 1
                    j1 = max(j0 + 1, d)
                    j0 = max(up_idx, int(np.searchsorted(t, t[j1] - c.preDropWindow)))
                if j1 > j0:
                    pa = j0 + int(np.argmin(calm_s[j0:j1]))
                    if pa > homing_idx + 1:
                        mode_pa = c.pseudoAnchorMode
                        if mode_pa == "auto":
                            mode_pa = "endOnly" if rec.lift_type in CLEAN_TYPES else "zupt"
                        if mode_pa == "endOnly":
                            pseudo_end = pa
                        else:
                            anchors.append((pa, pa, pa))
                        notes.append(NOTE_PSEUDO_ANCHOR)

    # 5. velocity: piecewise ZUPT between still runs
    v = np.zeros((n, 3))
    seg_bounds: List[Tuple[int, int, float]] = []  # (s, e, driftCorrection)
    s = homing_idx
    for (a0, ar, a1) in anchors:
        e = a0
        vraw = _cumtrapz(aW[s:e + 1], t[s:e + 1])
        drift = vraw[-1].copy()
        frac = _drift_weights(aW[s:e + 1], m.rotation_rate[s:e + 1], t[s:e + 1], c.driftWeighting)
        v[s:e + 1] = vraw - drift[None, :] * frac[:, None]
        seg_bounds.append((s, e, float(np.linalg.norm(drift))))
        v[a0:ar + 1] = 0.0
        s = ar

    # positions (0 at homing) over the corrected region
    p = np.zeros((n, 3))
    last_corr = anchors[-1][1] if anchors else homing_idx
    p[homing_idx:last_corr + 1] = _cumtrapz(v[homing_idx:last_corr + 1], t[homing_idx:last_corr + 1])

    # 6. path end
    no_anchor = not anchors and pseudo_end is None
    if pseudo_end is not None:
        # End-only pseudo anchor: the path ends there, but the last segment is integrated
        # WITHOUT forcing zero velocity (the wrist may still move while the bar rests, e.g.
        # elbows coming up in the front rack).
        s0 = anchors[-1][1] if anchors else homing_idx
        end_idx = max(pseudo_end, s0 + 1)
        sl = slice(s0, end_idx + 1)
        v[sl] = _cumtrapz(aW[sl], t[sl])
        p[sl] = p[s0] + _cumtrapz(v[sl], t[sl])
        seg_bounds = [sb for sb in seg_bounds if sb[1] <= s0] + [(s0, end_idx, 0.0)]
    elif no_anchor:
        j1 = int(np.searchsorted(t, t[homing_idx] + c.maxUncorrectedDuration, side="right")) - 1
        end_idx = max(min(j1, n - 1), homing_idx + 1)
        sl = slice(homing_idx, end_idx + 1)
        v[sl] = _cumtrapz(aW[sl], t[sl])
        p[sl] = _cumtrapz(v[sl], t[sl])
        seg_bounds = [(homing_idx, end_idx, 0.0)]
        notes.append(NOTE_NO_ANCHOR)
    elif arms_down_idx is not None:
        end_idx = anchors[-1][1]
        seg_bounds = [sb for sb in seg_bounds if sb[1] <= end_idx]
    else:
        end_idx = anchors[-1][1]
        for k, (a0, ar, a1) in enumerate(anchors):
            tail_end = anchors[k + 1][0] if k + 1 < len(anchors) else n - 1
            if tail_end <= ar:
                continue
            sl = slice(ar, tail_end + 1)
            vt = _cumtrapz(aW[sl], t[sl])
            zt = p[ar, 2] + _cumtrapz(vt[:, 2], t[sl])
            if np.min(zt) < p[ar, 2] - c.dropDistance:
                end_idx = ar
                break
        seg_bounds = [sb for sb in seg_bounds if sb[1] <= end_idx]

    # 7. horizontal axes
    up = np.array([0.0, 0.0, 1.0])
    hs = slice(homing_idx, end_idx + 1)
    if mode == "gravityOnly":
        fwd_axis = np.array([1.0, 0.0, 0.0])
        lat_axis = np.array([0.0, 1.0, 0.0])
        p[:, :2] = 0.0
        v[:, :2] = 0.0
    else:
        r0, r1 = homing_run
        f = quat_rotate(qq[r0:r1 + 1], np.array([0.0, 0.0, 1.0])).mean(axis=0)
        f[2] = 0.0
        if np.linalg.norm(f) >= 0.3:
            fwd_axis = f / np.linalg.norm(f)
        else:
            xy = p[hs, :2]
            e2 = principal_axis(xy)
            fwd_axis = np.array([e2[0], e2[1], 0.0])
            proj = xy @ e2
            if proj.max() < abs(proj.min()):
                fwd_axis = -fwd_axis
            notes.append(NOTE_FORWARD_ESTIMATED)
        lat_axis = np.cross(up, fwd_axis)

    tt = t[hs] - t[homing_idx]
    pb = p[hs].copy()
    vb = v[hs].copy()
    # 7b. wrist → bar lever arm (Revision E): bar POSITION = watch + R(t)·r − R(homing)·r, r in the
    # device frame: leverForearm toward the hand (the direction gravity points with the arm
    # hanging at homing) and leverNormal along the watch-face normal.
    if mode != "gravityOnly" and (c.leverForearm != 0.0 or c.leverNormal != 0.0):
        r0h, r1h = homing_run
        hand_sign = 1.0 if np.mean(normalize(m.gravity[r0h:r1h + 1])[:, 0]) >= 0 else -1.0
        r_dev = np.array([hand_sign * c.leverForearm, 0.0, c.leverNormal])
        o = quat_rotate(qq[hs], r_dev)
        pb = pb + (o - o[0])
        # Velocities stay the wrist's: adding d/dt(R·r) inflates peak velocity by 0.3–0.5 m/s
        # vs video (rotation timing), while the wrist's peak matches video within ~0.1 m/s.
    fwd = pb @ fwd_axis
    lat = pb @ lat_axis
    vert = pb[:, 2]
    vf = vb @ fwd_axis
    vv = vb[:, 2]
    # 7c. end-over-start horizontal prior (Revision E): remove a linearly growing horizontal
    # velocity error so the bar finishes above the start (validated against video: median
    # horizontal RMS error ~7 cm vs ~12–17 cm without).
    if c.endOverStart and mode != "gravityOnly" and len(tt) > 1 and tt[-1] > 0.5:
        T = tt[-1]
        kf = 2.0 * fwd[-1] / T ** 2
        kl = 2.0 * lat[-1] / T ** 2
        fwd = fwd - kf * tt ** 2 / 2.0
        lat = lat - kl * tt ** 2 / 2.0
        vf = vf - kf * tt
        vb = vb - np.outer(kf * tt, fwd_axis) - np.outer(kl * tt, lat_axis)
        notes.append(NOTE_END_OVER_START)
    spd = np.linalg.norm(vb, axis=1)
    path = PathSeries(tt, fwd, lat, vert, vf, vv, spd)

    # 8. metrics (kinematic phases, Revision D): pull top = first vz <= 0 after peak velocity;
    # catch = lowest point between the pull top and the start of the stand-up (vz back above
    # catchRiseVelocity) or the path end. No still pause in the catch is needed.
    ipk = int(np.argmax(vv))
    t_pk = tt[ipk]
    if spec_literal:
        catch_anchor = next(((a0, a1) for (a0, ar, a1) in anchors
                             if a0 <= end_idx and t[a0] - t[homing_idx] > t_pk), None)
        lim = (catch_anchor[0] if catch_anchor else end_idx) - homing_idx
        imax = int(np.argmax(vert[:lim + 1]))
        max_h = float(vert[imax])
        if catch_anchor is not None:
            catch_h = float(np.min(vert[imax:lim + 1]))
            dub = max_h - catch_h
        else:
            catch_h = dub = None
    else:
        last = len(vv) - 1
        itop = next((i for i in range(ipk, last + 1) if vv[i] <= 0.0), last)
        max_h = float(np.max(vert[:itop + 1]))
        ibot = next((i for i in range(itop, last + 1) if vv[i] > c.catchRiseVelocity), last)
        if itop < last:
            icatch = itop + int(np.argmin(vert[itop:ibot + 1]))
            catch_h = float(vert[icatch])
            dub = max_h - catch_h
        else:
            catch_h = dub = None
    lat_extent = float(np.max(np.abs(lat))) if len(lat) else 0.0
    if not spec_literal and mode != "gravityOnly" and lat_extent > c.maxLateral:
        notes.append(NOTE_LATERAL)
    metrics = LiftMetrics(
        peakVerticalVelocity=float(vv[ipk]), timeToPeakVelocity=float(t_pk), maxHeight=max_h,
        catchHeight=catch_h, dropUnderBar=dub, finalHeight=float(vert[-1]),
        maxForward=float(fwd.max()), maxBackward=float(fwd.min()), duration=float(tt[-1]))

    # 9. segments
    segments = []
    for (s, e, dc) in seg_bounds:
        i0, i1 = s - homing_idx, e - homing_idx
        segments.append(LiftSegment(
            startIndex=i0, endIndex=i1, duration=float(t[e] - t[s]),
            peakVerticalVelocity=float(vv[i0:i1 + 1].max()),
            heightGain=float(vert[i1] - vert[i0]),
            maxHeight=float(vert[i0:i1 + 1].max()), minHeight=float(vert[i0:i1 + 1].min()),
            driftCorrection=dc))

    # 10. confidence
    max_drift = max((sg.driftCorrection for sg in segments), default=0.0)
    conf = "high" if max_drift < 0.25 else ("medium" if max_drift < 0.6 else "low")
    if mode == "gravityOnly" and conf == "high":
        conf = "medium"
    if no_anchor:
        conf = "low"
    if NOTE_LATERAL in notes and conf == "high":
        conf = "medium"

    return LiftAnalysis(recordingId=rec.id, homingIndex=int(homing_idx), endIndex=int(end_idx), path=path,
                        segments=segments, metrics=metrics, confidence=conf, notes=notes,
                        quaternionMode=mode, anchorRuns=[(a[0], a[2]) for a in anchors if a[0] <= end_idx])


class LiftAnalyzer:
    """Namespace mirroring the Swift enum: LiftAnalyzer.analyze(recording, config)."""
    analyze = staticmethod(analyze)
