"""Physically plausible synthetic watch recordings.

Ground truth is a smooth wrist trajectory + attitude in a world frame (x east, y north,
z up). Every channel (body position, yaw, wrist offset in the lifter's body frame, arm angles)
is a C2 quintic-Hermite spline, so acceleration and angular rate are smooth and consistent
with position. Sensor outputs are derived from that ground truth:

  device frame:  +x along the forearm toward the hand, +z out of the watch face
                 (arm hanging, overhand grip: gravity_dev ≈ (+1, 0, 0) g, face → away from lifter)
  attitude q:    device → world, q.rotate(v_dev) = v_world  ("direct" convention for the
                 analyzer; the conjugate fixture stores q*)
  userAccel:     -a_dev / G + bias + noise + (gravity_true - gravity_est)  [g]
  gravity:       R_est^T (0, 0, -1)                                         [g]
  raw accel:     gravity_true - a_dev / G + bias + noise, 800 Hz           [g]
  rotationRate:  body angular velocity + bias + noise                       [rad/s]

Sign convention: physical CoreMotion. raw = -(specific force)/G, so at rest raw = gravity
(points down) and |raw| = 1 + a_up/G; raw = gravity + userAccel, hence userAccel = -a/G.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Callable, Dict, List, Optional, Tuple

import numpy as np

from .geometry import G, axis_angle_matrix, matrix_to_quat, quat_conj
from .recording import AccelSeries, LiftRecording, MotionSeries

DEG = np.pi / 180.0


# --------------------------------------------------------------------------------------------
# Quintic Hermite spline (scalar)
# --------------------------------------------------------------------------------------------

class QuinticSpline:
    """C2 piecewise quintic through knots (t, p, v, a). Constant extrapolation outside."""

    def __init__(self, knots: List[Tuple[float, float, float, float]]):
        knots = sorted(knots, key=lambda k: k[0])
        self.t = np.array([k[0] for k in knots], dtype=float)
        if np.any(np.diff(self.t) <= 0):
            raise ValueError("knot times must be strictly increasing")
        self.p = np.array([k[1] for k in knots], dtype=float)
        self.v = np.array([k[2] for k in knots], dtype=float)
        self.a = np.array([k[3] for k in knots], dtype=float)
        n = len(knots) - 1
        self.coef = np.zeros((max(n, 0), 6))
        for i in range(n):
            T = self.t[i + 1] - self.t[i]
            p0, v0, a0 = self.p[i], self.v[i] * T, self.a[i] * T * T
            p1, v1, a1 = self.p[i + 1], self.v[i + 1] * T, self.a[i + 1] * T * T
            c0, c1, c2 = p0, v0, a0 / 2
            # solve for c3, c4, c5 on normalised time u in [0,1]
            A = np.array([[1, 1, 1], [3, 4, 5], [6, 12, 20]], dtype=float)
            b = np.array([p1 - c0 - c1 - c2, v1 - c1 - 2 * c2, a1 - 2 * c2])
            c3, c4, c5 = np.linalg.solve(A, b)
            self.coef[i] = [c0, c1, c2, c3, c4, c5]

    def __call__(self, t: np.ndarray) -> np.ndarray:
        t = np.asarray(t, dtype=float)
        out = np.empty_like(t)
        lo, hi = self.t[0], self.t[-1]
        out[t <= lo] = self.p[0]
        out[t >= hi] = self.p[-1]
        mid = (t > lo) & (t < hi)
        if np.any(mid):
            tm = t[mid]
            i = np.clip(np.searchsorted(self.t, tm, side="right") - 1, 0, len(self.t) - 2)
            T = self.t[i + 1] - self.t[i]
            u = (tm - self.t[i]) / T
            c = self.coef[i]
            out[mid] = c[:, 0] + u * (c[:, 1] + u * (c[:, 2] + u * (c[:, 3] + u * (c[:, 4] + u * c[:, 5]))))
        return out


class Channel:
    """Knot list builder for one scalar channel."""

    def __init__(self, value: float, t0: float = 0.0):
        self.knots: List[Tuple[float, float, float, float]] = [(t0, value, 0.0, 0.0)]

    @property
    def t_end(self) -> float:
        return self.knots[-1][0]

    @property
    def value(self) -> float:
        return self.knots[-1][1]

    def to(self, t: float, value: float, vel: float = 0.0, acc: float = 0.0) -> "Channel":
        if t <= self.t_end + 1e-9:
            raise ValueError(f"knot at {t} not after {self.t_end}")
        self.knots.append((t, value, vel, acc))
        return self

    def hold(self, t: float) -> "Channel":
        if t > self.t_end + 1e-9:
            self.to(t, self.value)
        return self

    def spline(self) -> QuinticSpline:
        return QuinticSpline(self.knots)


# --------------------------------------------------------------------------------------------
# Choreography: channels for one continuous take
# --------------------------------------------------------------------------------------------

WALK_SPEED = 1.3
STEP_FREQ = 1.8          # steps/s; arm swing at STEP_FREQ/2
ARM_LEN = 0.60
SWING_AMP = 20 * DEG

# body-frame wrist offsets (forward, lateral(+left), vertical) relative to the grip at homing
GRIP = np.array([0.25, 0.40, 0.0])     # watch on the left wrist, snatch-width grip
SIDE = np.array([0.0, 0.22, 0.55])      # arm hanging at the left side, standing


@dataclass
class LiftTruth:
    lift_type: str
    t_homing: float           # session time the pull starts (wrist still before)
    t_catch_still: float      # start of the still catch (first anchor after the peak)
    t_end: float              # end of the final overhead hold (right before the drop)
    heading: float            # rad
    values: Dict[str, float] = field(default_factory=dict)


class Choreo:
    def __init__(self, heading_deg: float = 37.0, start_pose: str = "side"):
        o = SIDE - GRIP if start_pose == "side" else np.zeros(3)
        self.cx = Channel(0.0)
        self.cy = Channel(0.0)
        self.yaw = Channel(heading_deg * DEG)
        self.of, self.ol, self.ov = Channel(o[0]), Channel(o[1]), Channel(o[2])
        self.theta = Channel(0.0)
        self.splay = Channel(0.0)
        self.twist = Channel(-90 * DEG if start_pose == "side" else 0.0)
        self.walk = Channel(0.0)
        self.t = 0.0
        self.lifts: List[LiftTruth] = []

    @property
    def channels(self):
        return [self.cx, self.cy, self.yaw, self.of, self.ol, self.ov, self.theta, self.splay,
                self.twist, self.walk]

    def hold_all(self, t: float) -> None:
        for ch in self.channels:
            ch.hold(t)
        self.t = max(self.t, t)

    def still(self, dur: float) -> "Choreo":
        self.hold_all(self.t + dur)
        return self

    def walk_straight(self, dur: float, ramp: float = 0.8) -> "Choreo":
        """Walk forward along the current heading at WALK_SPEED with smooth start/stop."""
        t0 = self.t
        self.hold_all(t0)
        psi = self.yaw.value
        d = np.array([np.cos(psi), np.sin(psi)])
        x0 = np.array([self.cx.value, self.cy.value])
        s_ramp = 0.5 * WALK_SPEED * ramp
        total = s_ramp * 2 + WALK_SPEED * (dur - 2 * ramp)
        for ch, k in ((self.cx, 0), (self.cy, 1)):
            ch.to(t0 + ramp, x0[k] + d[k] * s_ramp, d[k] * WALK_SPEED)
            ch.to(t0 + dur - ramp, x0[k] + d[k] * (total - s_ramp), d[k] * WALK_SPEED)
            ch.to(t0 + dur, x0[k] + d[k] * total)
        self.walk.to(t0 + ramp, 1.0).to(t0 + dur - ramp, 1.0).to(t0 + dur, 0.0)
        self.hold_all(t0 + dur)
        return self

    def turn(self, deg: float, dur: float = 1.4) -> "Choreo":
        t0 = self.t
        self.hold_all(t0)
        self.yaw.to(t0 + dur, self.yaw.value + deg * DEG)
        self.walk.to(t0 + dur / 2, 0.5).to(t0 + dur, 0.0)
        self.hold_all(t0 + dur)
        return self

    def set_up(self, dur: float = 1.3) -> "Choreo":
        """From standing (arm at the side) bend down and grip the bar."""
        t0 = self.t
        self.hold_all(t0)
        self.ov.to(t0 + 0.6 * dur, 0.15, -0.5).to(t0 + dur, 0.0)
        self.of.to(t0 + dur, 0.0)
        self.ol.to(t0 + dur, 0.0)
        self.twist.to(t0 + 0.7 * dur, -10 * DEG, 50 * DEG).to(t0 + dur, 0.0)
        self.theta.to(t0 + 0.5 * dur, 12 * DEG).to(t0 + dur, 0.0)
        self.hold_all(t0 + dur)
        return self

    def _drop_to_side(self, t0: float, fall: float = 0.7) -> float:
        """Release the bar overhead/rack, wrist falls to the side. Returns the end time."""
        side = SIDE - GRIP
        t1 = t0 + fall
        self.ov.to(t0 + 0.45 * fall, (self.ov.value + side[2]) / 2 + 0.05,
                   -1.25 * (self.ov.value - side[2]) / fall).to(t1, side[2])
        self.of.to(t1, side[0])
        self.ol.to(t1, side[1])
        self.theta.to(t0 + 0.6 * fall, 40 * DEG, -250 * DEG).to(t1 + 0.15, 0.0)
        self.splay.to(t1, 0.0)
        self.twist.to(t1 + 0.15, -90 * DEG)
        self.hold_all(t1 + 0.15)
        return t1 + 0.15

    # --- lifts (all times relative to the start of the pull) -------------------------------
    def snatch(self) -> LiftTruth:
        T = self.t
        self.hold_all(T)
        v = self.ov
        v.to(T + 0.40, 0.24, 0.95, 2.6)
        v.to(T + 0.80, 0.80, 1.86, 0.0)
        v.to(T + 1.25, 1.20, 0.0, -5.0)
        v.to(T + 1.55, 1.02).hold(T + 2.05)
        # recovery from the overhead squat: drive out of the hole, sticking point, lockout
        v.to(T + 2.45, 1.16, 0.60, -0.8).to(T + 2.85, 1.30, 0.22, 0.6).to(T + 3.20, 1.49, 0.45, -1.8)
        v.to(T + 3.45, 1.55).hold(T + 4.95)
        f = self.of
        f.to(T + 0.35, -0.04).to(T + 0.80, 0.03).to(T + 1.25, -0.035, -0.25).to(T + 1.55, -0.08)
        f.hold(T + 2.05).to(T + 3.45, -0.06).hold(T + 4.95)
        self.ol.to(T + 1.25, 0.004).to(T + 1.55, -0.006).to(T + 3.45, 0.0).hold(T + 4.95)
        th = self.theta
        th.hold(T + 0.80).to(T + 1.08, 85 * DEG, 9.0).to(T + 1.40, 158 * DEG, 1.0).to(T + 1.55, 160 * DEG)
        th.hold(T + 2.05).to(T + 3.45, 163 * DEG).hold(T + 4.95)
        self.splay.hold(T + 0.9).to(T + 1.45, 18 * DEG).hold(T + 2.05).to(T + 3.45, 15 * DEG).hold(T + 4.95)
        self.twist.hold(T + 0.85).to(T + 1.45, 12 * DEG).hold(T + 4.95)
        self.hold_all(T + 4.95)
        lt = LiftTruth("snatch", T, T + 1.55, T + 4.95, self.yaw.value)
        self.lifts.append(lt)
        self._drop_to_side(T + 4.95)
        return lt

    def clean_and_jerk(self) -> LiftTruth:
        T = self.t
        self.hold_all(T)
        v = self.ov
        v.to(T + 0.42, 0.24, 0.90, 2.4)
        v.to(T + 0.82, 0.74, 1.72, 0.0)
        v.to(T + 1.22, 1.10, 0.0, -4.5)
        v.to(T + 1.50, 0.95).hold(T + 2.00)
        # front-squat recovery with a sticking point
        v.to(T + 2.40, 1.06, 0.42, -0.6).to(T + 2.80, 1.14, 0.14, 0.6).to(T + 3.10, 1.225, 0.28, -1.6)
        v.to(T + 3.30, 1.25).hold(T + 4.80)
        # jerk: dip, drive, split catch, recover the feet in two steps
        v.to(T + 5.05, 1.13).to(T + 5.28, 1.38, 1.45, -2.0).to(T + 5.50, 1.63, 0.55, -4.0)
        v.to(T + 5.72, 1.69).to(T + 6.10, 1.72).hold(T + 6.20).to(T + 6.55, 1.75).hold(T + 8.00)
        f = self.of
        f.to(T + 0.35, -0.04).to(T + 0.82, 0.03).to(T + 1.22, -0.03, -0.2).to(T + 1.50, -0.06)
        f.hold(T + 2.00).to(T + 3.30, -0.05).hold(T + 4.80).to(T + 5.05, -0.048).to(T + 5.52, -0.065)
        f.to(T + 6.50, -0.07).hold(T + 8.00)
        self.ol.to(T + 1.5, -0.005).to(T + 3.3, 0.0).hold(T + 8.0)
        th = self.theta
        th.hold(T + 0.85).to(T + 1.08, 100 * DEG, 9.0).to(T + 1.38, 198 * DEG, 1.0).to(T + 1.50, 200 * DEG)
        th.hold(T + 5.15).to(T + 5.55, 172 * DEG).hold(T + 8.0)
        self.twist.hold(T + 0.85).to(T + 1.40, 25 * DEG).hold(T + 5.15).to(T + 5.55, 10 * DEG).hold(T + 8.0)
        self.splay.hold(T + 5.15).to(T + 5.55, 8 * DEG).hold(T + 8.0)
        self.hold_all(T + 8.0)
        lt = LiftTruth("cleanAndJerk", T, T + 1.50, T + 8.0, self.yaw.value)
        self.lifts.append(lt)
        self._drop_to_side(T + 8.0, fall=0.75)
        return lt

    # --- evaluation ------------------------------------------------------------------------
    def build(self) -> "Trajectory":
        self.hold_all(self.t)
        return Trajectory(self)


class Trajectory:
    """Callable ground truth: position(t) (N,3) m and attitude(t) (N,3,3) device→world."""

    def __init__(self, ch: Choreo):
        self.duration = ch.t
        self.lifts = ch.lifts
        self.s = {name: c.spline() for name, c in zip(
            ["cx", "cy", "yaw", "of", "ol", "ov", "theta", "splay", "twist", "walk"], ch.channels)}

    def _swing(self, t):
        env = self.s["walk"](t)
        phi = env * SWING_AMP * np.sin(np.pi * STEP_FREQ * t)
        return env, phi

    def position(self, t: np.ndarray) -> np.ndarray:
        t = np.asarray(t, dtype=float)
        s = self.s
        psi = s["yaw"](t)
        F = np.stack([np.cos(psi), np.sin(psi), np.zeros_like(t)], axis=-1)
        L = np.stack([-np.sin(psi), np.cos(psi), np.zeros_like(t)], axis=-1)
        U = np.array([0.0, 0.0, 1.0])
        env, phi = self._swing(t)
        fwd = s["of"](t) + ARM_LEN * np.sin(phi)
        lat = s["ol"](t) + env * 0.015 * np.sin(np.pi * STEP_FREQ * t + 0.4)
        vert = s["ov"](t) + ARM_LEN * (1 - np.cos(phi)) + env * 0.022 * np.sin(2 * np.pi * STEP_FREQ * t + 1.1)
        c = np.stack([s["cx"](t), s["cy"](t), np.zeros_like(t)], axis=-1)
        return c + fwd[:, None] * F + lat[:, None] * L + vert[:, None] * U

    def attitude(self, t: np.ndarray) -> np.ndarray:
        t = np.asarray(t, dtype=float)
        s = self.s
        _, phi = self._swing(t)
        B0 = np.array([[0.0, 0.0, 1.0], [0.0, 1.0, 0.0], [-1.0, 0.0, 0.0]])  # columns: dev x,y,z in body
        Rz = axis_angle_matrix(np.array([0.0, 0.0, 1.0]), s["yaw"](t))
        Rth = axis_angle_matrix(np.array([0.0, -1.0, 0.0]), s["theta"](t) + phi)
        Rsp = axis_angle_matrix(np.array([1.0, 0.0, 0.0]), s["splay"](t))
        Rtw = axis_angle_matrix(np.array([1.0, 0.0, 0.0]), s["twist"](t))
        return Rz @ Rth @ Rsp @ B0 @ Rtw

    def acceleration(self, t: np.ndarray, h: float = 2e-3) -> np.ndarray:
        p = self.position
        return (-p(t + 2 * h) + 16 * p(t + h) - 30 * p(t) + 16 * p(t - h) - p(t - 2 * h)) / (12 * h * h)

    def velocity(self, t: np.ndarray, h: float = 1e-4) -> np.ndarray:
        return (self.position(t + h) - self.position(t - h)) / (2 * h)

    def angular_rate_body(self, t: np.ndarray, h: float = 1e-4) -> np.ndarray:
        R = self.attitude(t)
        Rd = (self.attitude(t + h) - self.attitude(t - h)) / (2 * h)
        W = np.transpose(R, (0, 2, 1)) @ Rd
        return np.stack([W[:, 2, 1] - W[:, 1, 2], W[:, 0, 2] - W[:, 2, 0], W[:, 1, 0] - W[:, 0, 1]], axis=-1) / 2

    # --- ground truth metrics -----------------------------------------------------------------
    def lift_truth(self, lt: LiftTruth, dt: float = 1e-3) -> Dict[str, float]:
        t = np.arange(lt.t_homing, lt.t_end + dt / 2, dt)
        p = self.position(t)
        vz = self.velocity(t)[:, 2]
        F = np.array([np.cos(lt.heading), np.sin(lt.heading), 0.0])
        rel = p - p[0]
        vert = rel[:, 2]
        fwd = rel @ F
        ic = int(np.searchsorted(t, lt.t_catch_still))
        imax = int(np.argmax(vert[:ic + 1]))
        vals = {
            "maxHeight": float(vert[imax]),
            "peakVerticalVelocity": float(vz.max()),
            "timeToPeakVelocity": float(t[np.argmax(vz)] - lt.t_homing),
            "catchHeight": float(vert[imax:ic + 1].min()),
            "finalHeight": float(vert[-1]),
            "maxForward": float(fwd.max()),
            "maxBackward": float(fwd.min()),
        }
        lt.values = vals
        return vals


# --------------------------------------------------------------------------------------------
# Sensor model
# --------------------------------------------------------------------------------------------

@dataclass
class NoiseModel:
    accel_noise: float = 0.01        # g, white, per axis (both 200 Hz userAccel and 800 Hz raw)
    accel_bias: Tuple[float, float] = (0.003, 0.005)   # g, |bias| (vector norm), random direction
    gyro_noise: float = 0.01         # rad/s
    gyro_bias: float = 0.002         # rad/s
    gravity_noise: float = 0.0005    # g
    attitude_error_deg: float = 0.1  # rms per axis of a slowly varying fusion attitude error
    yaw_drift_deg_per_min: float = 0.5


def _smooth_noise(t: np.ndarray, rng, amp: float, n_comp: int = 4, fmin=0.03, fmax=0.4) -> np.ndarray:
    out = np.zeros_like(t)
    for _ in range(n_comp):
        f = rng.uniform(fmin, fmax)
        out += np.sin(2 * np.pi * f * t + rng.uniform(0, 2 * np.pi))
    return amp * out / np.sqrt(n_comp / 2)


@dataclass
class SensorData:
    motion: MotionSeries
    accel: AccelSeries


def sense(traj: Trajectory, t0: float, t1: float, rng: np.random.Generator,
          noise: NoiseModel = NoiseModel(), rate: float = 200.0, accel_rate: Optional[float] = 800.0,
          accel_offset: float = -0.0021, user_accel_sign: float = -1.0) -> SensorData:
    """Sample the trajectory on [t0, t1]; returned times are relative to t0.

    user_accel_sign=-1 (default) is the physical CoreMotion convention: raw = down - a/G,
    userAccel = -a/G, |raw| > 1 g while accelerating upward. +1 gives the old (pre-revision spec)
    inverted convention, kept only to test sign robustness."""
    nm = noise
    bdir = rng.normal(size=3)
    bias = rng.uniform(*nm.accel_bias) * bdir / np.linalg.norm(bdir)
    gbias = rng.normal(0, nm.gyro_bias, size=3)
    err_seed = rng.integers(1 << 31)
    down = np.array([0.0, 0.0, -1.0])

    def att_error(ts):
        r = np.random.default_rng(err_seed)
        amp = nm.attitude_error_deg * DEG
        ex, ey, ez = (_smooth_noise(ts, r, amp) for _ in range(3))
        yaw = nm.yaw_drift_deg_per_min * DEG / 60.0 * (ts - t0)
        E = (axis_angle_matrix(np.array([1.0, 0, 0]), ex) @ axis_angle_matrix(np.array([0, 1.0, 0]), ey)
             @ axis_angle_matrix(np.array([0, 0, 1.0]), ez))
        return axis_angle_matrix(np.array([0, 0, 1.0]), yaw), E

    def raw_true(ts):
        R = traj.attitude(ts)
        RT = np.transpose(R, (0, 2, 1))
        a = user_accel_sign * traj.acceleration(ts) / G
        return R, np.einsum("nij,nj->ni", RT, a + down)

    n = int(np.floor((t1 - t0) * rate + 1e-9)) + 1
    ts = t0 + np.arange(n) / rate
    R, raw = raw_true(ts)
    Yaw, E = att_error(ts)
    R_est = Yaw @ R @ E
    g_est = np.einsum("nji,j->ni", R_est, down)            # R_est^T @ down
    g_est = g_est + rng.normal(0, nm.gravity_noise, g_est.shape)
    g_est /= np.linalg.norm(g_est, axis=1, keepdims=True)
    ua = raw + bias + rng.normal(0, nm.accel_noise, raw.shape) - g_est
    rr = traj.angular_rate_body(ts) + gbias + rng.normal(0, nm.gyro_noise, raw.shape)
    q = matrix_to_quat(R_est)
    motion = MotionSeries(ts - t0, q, ua, g_est, rr)

    if accel_rate:
        na = int(np.floor((t1 - t0 - accel_offset) * accel_rate + 1e-9)) + 1
        ta = t0 + accel_offset + np.arange(na) / accel_rate
        _, raw_a = raw_true(ta)
        acc = raw_a + bias + rng.normal(0, nm.accel_noise, raw_a.shape)
        accel = AccelSeries(ta - t0, acc)
    else:
        accel = AccelSeries.empty()
    return SensorData(motion, accel)


# --------------------------------------------------------------------------------------------
# Scenarios
# --------------------------------------------------------------------------------------------

def _uuid(rng: np.random.Generator) -> str:
    return str(uuid.UUID(bytes=rng.bytes(16), version=4)).upper()


START_DATE = datetime(2026, 10, 25, 18, 3, 11, tzinfo=timezone.utc)


@dataclass
class SimLift:
    recording: LiftRecording
    truth: Dict[str, float]
    lift: LiftTruth
    trajectory: Trajectory
    t_offset: float          # trajectory time of motion.t == 0


def lift_choreo(lift_type: str, heading_deg: float = 37.0, set_still: float = 1.5,
                rest: float = 1.2) -> Choreo:
    c = Choreo(heading_deg=heading_deg, start_pose="grip")
    c.still(set_still)
    if lift_type == "snatch":
        c.snatch()
    elif lift_type == "cleanAndJerk":
        c.clean_and_jerk()
    else:
        raise ValueError(lift_type)
    c.still(rest)
    return c


def simulate_lift(lift_type: str = "snatch", seed: int = 1, heading_deg: float = 37.0,
                  conjugate: bool = False, noise: NoiseModel = NoiseModel(),
                  fill_detector_fields: bool = True) -> SimLift:
    rng = np.random.default_rng(seed)
    traj = lift_choreo(lift_type, heading_deg).build()
    lt = traj.lifts[0]
    truth = traj.lift_truth(lt)
    data = sense(traj, 0.0, traj.duration, rng, noise)
    motion = data.motion
    if conjugate:
        motion.q = quat_conj(motion.q)
    rec = LiftRecording(
        session_id=_uuid(rng),
        index=1, lift_type=lift_type, start_date=START_DATE, motion=motion, accel=data.accel,
        id=_uuid(rng))
    rec.homing_time, rec.end_time, rec.end_reason = lt.t_homing, lt.t_end, "drop"
    if fill_detector_fields:
        from .detector import detected_lifts
        ends = detected_lifts(motion)
        if ends:
            rec.homing_time, rec.end_time, rec.end_reason = ends[0].homingTime, ends[0].endTime, ends[0].reason
    return SimLift(rec, truth, lt, traj, 0.0)


def session_choreo(heading_deg: float = 37.0) -> Choreo:
    c = Choreo(heading_deg=heading_deg, start_pose="side")
    c.still(1.0)
    c.walk_straight(7.0)
    c.set_up()
    c.still(1.5)
    c.snatch()
    c.still(1.5)
    c.turn(180)
    c.walk_straight(5.0)
    c.turn(-180)
    c.walk_straight(5.0)
    c.set_up()
    c.still(1.5)
    c.clean_and_jerk()
    c.still(1.5)
    c.turn(150)
    c.walk_straight(6.0)
    c.still(1.0)
    return c


@dataclass
class SimSession:
    motion: MotionSeries
    trajectory: Trajectory
    lifts: List[LiftTruth]
    session_id: str
    start_date: datetime


def simulate_session(seed: int = 7, heading_deg: float = 37.0, noise: NoiseModel = NoiseModel()) -> SimSession:
    rng = np.random.default_rng(seed)
    traj = session_choreo(heading_deg).build()
    for lt in traj.lifts:
        traj.lift_truth(lt)
    data = sense(traj, 0.0, traj.duration, rng, noise, accel_rate=None)
    sid = _uuid(rng)
    return SimSession(data.motion, traj, traj.lifts, sid, START_DATE)
