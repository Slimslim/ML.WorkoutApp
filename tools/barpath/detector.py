"""Online lift detector — Python mirror of BarPathKit's OnlineLiftDetector (spec §4).

Feed every 200 Hz device-motion sample, in order, to ``process``. It returns at most one
event per sample.

Interpretations of points the spec leaves open (the Swift port must match):
  * rotEMA, accEMA, stillDur, v, h start at 0; the first sample has dt = 0 (so alpha = 0).
  * The per-sample block (dt, EMAs, isStill, stillDur, armVertical) runs on *every* sample,
    in every state, including cooldown.
  * At most one state transition per sample: the sample that changes state is not
    re-evaluated by the new state's rules.
  * On idle -> armed: v = 0, motionTime = 0.
  * On armed -> lifting: h = v*dt (this sample's v), maxH = max(0, h); end checks start with
    the next sample.
  * Leaving cooldown resets stillDur = 0 and v = 0 (EMAs are kept).

Sign convention (agreed change to §4): CoreMotion's userAcceleration is the negative of the
device's acceleration (raw = gravity + userAccel, gravity points down, |raw| = 1 + a_up/G),
so aUp = +(userAccel · ĝ) · G.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Iterable, List, Optional, Sequence, Tuple

import numpy as np

from .geometry import G


@dataclass(frozen=True)
class DetectorConfig:
    emaTau: float = 0.08
    stillRot: float = 0.5
    stillAcc: float = 0.06
    armMinStill: float = 0.3
    armVerticalMin: float = 0.7
    rehomeStill: float = 0.15
    startVelocity: float = 0.5
    startWindow: float = 1.0
    anchorStill: float = 0.3
    dropDistance: float = 0.5
    returnHeight: float = 0.15
    returnStill: float = 0.5
    noAnchorTimeout: float = 4.0
    maxLiftDuration: float = 15.0
    cooldown: float = 1.5


# Events are small tuples-like dataclasses mirroring the Swift enum cases.
@dataclass(frozen=True)
class Armed:
    homingTime: float


@dataclass(frozen=True)
class Disarmed:
    pass


@dataclass(frozen=True)
class LiftStarted:
    homingTime: float


@dataclass(frozen=True)
class LiftEnded:
    homingTime: float
    endTime: float
    reason: str  # EndReason raw value


DetectorEvent = object  # Armed | Disarmed | LiftStarted | LiftEnded


class OnlineLiftDetector:
    IDLE, ARMED, LIFTING, COOLDOWN = "idle", "armed", "lifting", "cooldown"

    def __init__(self, config: DetectorConfig = DetectorConfig()):
        self.config = config
        self.reset()

    def reset(self) -> None:
        self.state = self.IDLE
        self.t_prev: Optional[float] = None
        self.rot_ema = 0.0
        self.acc_ema = 0.0
        self.still_dur = 0.0
        self.is_still = False
        self.arm_vertical = False
        self.homing_time = 0.0
        self.v = 0.0
        self.motion_time = 0.0
        self.h = 0.0
        self.max_h = 0.0
        self.had_anchor = False
        self.anchor_time = 0.0
        self.anchor_h = 0.0
        self.lift_start = 0.0
        self.cooldown_until = 0.0

    # ----------------------------------------------------------------------------------
    def process(self, t: float, user_accel: Sequence[float], gravity: Sequence[float],
                rotation_rate: Sequence[float]) -> Optional[DetectorEvent]:
        c = self.config
        if self.t_prev is None:
            dt = 0.0
        else:
            dt = min(max(t - self.t_prev, 0.0), 0.05)
        self.t_prev = t

        gx, gy, gz = gravity
        gn = math.sqrt(gx * gx + gy * gy + gz * gz)
        if gn < 1e-12:
            ghat = (0.0, 0.0, 0.0)
        else:
            ghat = (gx / gn, gy / gn, gz / gn)
        ux, uy, uz = user_accel
        # physical CoreMotion convention: userAccel = -a/G, so userAccel·ĝ = a_up/G (ĝ points down)
        a_up = (ux * ghat[0] + uy * ghat[1] + uz * ghat[2]) * G
        alpha = min(1.0, dt / c.emaTau) if c.emaTau > 0 else 1.0
        rx, ry, rz = rotation_rate
        self.rot_ema += alpha * (math.sqrt(rx * rx + ry * ry + rz * rz) - self.rot_ema)
        self.acc_ema += alpha * (math.sqrt(ux * ux + uy * uy + uz * uz) - self.acc_ema)
        self.is_still = self.rot_ema < c.stillRot and self.acc_ema < c.stillAcc
        self.still_dur = self.still_dur + dt if self.is_still else 0.0
        self.arm_vertical = abs(ghat[0]) >= c.armVerticalMin

        st = self.state
        if st == self.IDLE:
            if self.still_dur >= c.armMinStill and self.arm_vertical:
                self.state = self.ARMED
                self.homing_time = t
                self.v = 0.0
                self.motion_time = 0.0
                return Armed(t)
            return None

        if st == self.ARMED:
            if self.still_dur >= c.rehomeStill:
                self.homing_time = t
                self.v = 0.0
                self.motion_time = 0.0
                if not self.arm_vertical:
                    self.state = self.IDLE
                    return Disarmed()
                return None
            self.v += a_up * dt
            self.motion_time += dt
            if self.v >= c.startVelocity:
                self.state = self.LIFTING
                self.h = self.v * dt
                self.max_h = max(0.0, self.h)
                self.had_anchor = False
                self.lift_start = self.homing_time
                return LiftStarted(self.homing_time)
            if self.motion_time > c.startWindow:
                self.state = self.IDLE
                return Disarmed()
            return None

        if st == self.LIFTING:
            self.v += a_up * dt
            self.h += self.v * dt
            self.max_h = max(self.max_h, self.h)
            if self.still_dur >= c.anchorStill:
                self.v = 0.0
                self.had_anchor = True
                self.anchor_time = t
                self.anchor_h = self.h
            end: Optional[Tuple[float, str]] = None
            if self.had_anchor and self.anchor_h - self.h > c.dropDistance:
                end = (self.anchor_time, "drop")
            elif (self.had_anchor and self.still_dur >= c.returnStill and abs(self.h) < c.returnHeight
                  and t - self.lift_start > 1.0):
                end = (t, "returned")
            elif not self.had_anchor and t - self.lift_start > c.noAnchorTimeout:
                end = (t, "timeout")
            elif t - self.lift_start > c.maxLiftDuration:
                end = (self.anchor_time if self.had_anchor else t, "timeout")
            if end is not None:
                self.state = self.COOLDOWN
                self.cooldown_until = t + c.cooldown
                return LiftEnded(self.homing_time, end[0], end[1])
            return None

        # cooldown
        if t >= self.cooldown_until:
            self.state = self.IDLE
            self.still_dur = 0.0
            self.v = 0.0
        return None


def run_detector(motion, config: DetectorConfig = DetectorConfig()) -> List[Tuple[int, float, DetectorEvent]]:
    """Replay a MotionSeries; returns [(sample index, t, event), ...]."""
    det = OnlineLiftDetector(config)
    out = []
    ua, gr, rr, t = motion.user_accel, motion.gravity, motion.rotation_rate, motion.t
    for i in range(len(t)):
        ev = det.process(float(t[i]), ua[i], gr[i], rr[i])
        if ev is not None:
            out.append((i, float(t[i]), ev))
    return out


def detected_lifts(motion, config: DetectorConfig = DetectorConfig()) -> List[LiftEnded]:
    return [ev for _, _, ev in run_detector(motion, config) if isinstance(ev, LiftEnded)]
