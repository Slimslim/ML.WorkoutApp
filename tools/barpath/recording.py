"""LiftRecording JSON (spec §2) and debug session CSV (spec §2.1) I/O."""
from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import numpy as np

MOTION_KEYS = ("t", "qw", "qx", "qy", "qz", "ax", "ay", "az", "gx", "gy", "gz", "rx", "ry", "rz")
ACCEL_KEYS = ("t", "x", "y", "z")
END_REASONS = ("drop", "returned", "timeout", "manual", "sessionEnd")
LIFT_TYPES = ("snatch", "cleanAndJerk", "powerSnatch", "hangSnatch", "powerClean", "hangClean",
              "clean", "jerk", "other")


@dataclass
class MotionSeries:
    """Columnar CMDeviceMotion samples (all arrays equal length)."""
    t: np.ndarray
    q: np.ndarray            # (N,4) w,x,y,z  attitude.quaternion
    user_accel: np.ndarray   # (N,3) g
    gravity: np.ndarray      # (N,3) g
    rotation_rate: np.ndarray  # (N,3) rad/s

    def __len__(self) -> int:
        return len(self.t)

    @classmethod
    def empty(cls) -> "MotionSeries":
        z = np.zeros((0, 3))
        return cls(np.zeros(0), np.zeros((0, 4)), z, z.copy(), z.copy())

    @classmethod
    def from_columns(cls, d: dict) -> "MotionSeries":
        a = {k: np.asarray(d.get(k, []), dtype=float) for k in MOTION_KEYS}
        n = len(a["t"])
        for k in MOTION_KEYS:
            if len(a[k]) != n:
                raise ValueError(f"motion.{k} has length {len(a[k])}, expected {n}")
        return cls(a["t"],
                   np.column_stack([a["qw"], a["qx"], a["qy"], a["qz"]]).reshape(n, 4),
                   np.column_stack([a["ax"], a["ay"], a["az"]]).reshape(n, 3),
                   np.column_stack([a["gx"], a["gy"], a["gz"]]).reshape(n, 3),
                   np.column_stack([a["rx"], a["ry"], a["rz"]]).reshape(n, 3))

    def to_columns(self, decimals: Optional[int] = None) -> dict:
        cols = {
            "t": self.t,
            "qw": self.q[:, 0], "qx": self.q[:, 1], "qy": self.q[:, 2], "qz": self.q[:, 3],
            "ax": self.user_accel[:, 0], "ay": self.user_accel[:, 1], "az": self.user_accel[:, 2],
            "gx": self.gravity[:, 0], "gy": self.gravity[:, 1], "gz": self.gravity[:, 2],
            "rx": self.rotation_rate[:, 0], "ry": self.rotation_rate[:, 1], "rz": self.rotation_rate[:, 2],
        }
        return {k: _round_list(v, decimals) for k, v in cols.items()}

    def slice(self, i0: int, i1: int) -> "MotionSeries":
        return MotionSeries(self.t[i0:i1], self.q[i0:i1], self.user_accel[i0:i1],
                            self.gravity[i0:i1], self.rotation_rate[i0:i1])


@dataclass
class AccelSeries:
    """Raw accelerometer (g, includes gravity)."""
    t: np.ndarray
    accel: np.ndarray  # (N,3)

    def __len__(self) -> int:
        return len(self.t)

    @classmethod
    def empty(cls) -> "AccelSeries":
        return cls(np.zeros(0), np.zeros((0, 3)))

    @classmethod
    def from_columns(cls, d: Optional[dict]) -> "AccelSeries":
        d = d or {}
        a = {k: np.asarray(d.get(k, []), dtype=float) for k in ACCEL_KEYS}
        n = len(a["t"])
        for k in ACCEL_KEYS:
            if len(a[k]) != n:
                raise ValueError(f"accel.{k} has length {len(a[k])}, expected {n}")
        return cls(a["t"], np.column_stack([a["x"], a["y"], a["z"]]).reshape(n, 3))

    def to_columns(self, decimals: Optional[int] = None) -> dict:
        cols = {"t": self.t, "x": self.accel[:, 0], "y": self.accel[:, 1], "z": self.accel[:, 2]}
        return {k: _round_list(v, decimals) for k, v in cols.items()}


@dataclass
class LiftRecording:
    session_id: str
    index: int
    lift_type: str
    start_date: datetime
    motion: MotionSeries
    accel: AccelSeries = field(default_factory=AccelSeries.empty)
    homing_time: Optional[float] = None
    end_time: Optional[float] = None
    end_reason: Optional[str] = None
    load_kg: Optional[float] = None
    id: str = field(default_factory=lambda: str(uuid.uuid4()).upper())
    kind: str = "lift"
    version: int = 1

    # ---- JSON -------------------------------------------------------------------------
    def to_dict(self, decimals: Optional[int] = None, accel_decimals: Optional[int] = None) -> dict:
        return {
            "version": self.version,
            "id": self.id,
            "sessionId": self.session_id,
            "index": self.index,
            "kind": self.kind,
            "liftType": self.lift_type,
            "loadKg": self.load_kg,
            "startDate": format_iso8601(self.start_date),
            "homingTime": _opt_round(self.homing_time, decimals),
            "endTime": _opt_round(self.end_time, decimals),
            "endReason": self.end_reason,
            "motion": self.motion.to_columns(decimals),
            "accel": self.accel.to_columns(accel_decimals if accel_decimals is not None else decimals),
        }

    @classmethod
    def from_dict(cls, d: dict) -> "LiftRecording":
        version = int(d.get("version", 1))
        if version != 1:
            raise ValueError(f"unsupported LiftRecording version {version}")
        reason = d.get("endReason")
        if reason is not None and reason not in END_REASONS:
            raise ValueError(f"unknown endReason {reason!r}")
        return cls(
            session_id=d["sessionId"],
            index=int(d["index"]),
            lift_type=d["liftType"],
            start_date=parse_iso8601(d["startDate"]),
            motion=MotionSeries.from_columns(d["motion"]),
            accel=AccelSeries.from_columns(d.get("accel")),
            homing_time=_opt_float(d.get("homingTime")),
            end_time=_opt_float(d.get("endTime")),
            end_reason=reason,
            load_kg=_opt_float(d.get("loadKg")),
            id=d["id"],
            kind=d.get("kind", "lift"),
            version=version,
        )

    def save(self, path, decimals: Optional[int] = 6, accel_decimals: Optional[int] = None) -> None:
        with open(path, "w") as f:
            json.dump(self.to_dict(decimals, accel_decimals), f, separators=(",", ":"))

    @classmethod
    def load(cls, path) -> "LiftRecording":
        with open(path) as f:
            return cls.from_dict(json.load(f))


def load_recording(path) -> LiftRecording:
    return LiftRecording.load(path)


def save_recording(rec: LiftRecording, path, decimals: Optional[int] = 6) -> None:
    rec.save(path, decimals)


# ---- Session CSV (§2.1) -------------------------------------------------------------------

@dataclass
class SessionCSV:
    session_id: Optional[str]
    start_date: Optional[datetime]
    lift_type: Optional[str]
    motion: MotionSeries
    marks: list = field(default_factory=list)    # [{"t": float, "n": int, "label": str}]
    events: list = field(default_factory=list)   # [{"t": float, "name": str, "homing": .., ...}]
    workout: Optional[str] = None                # workout definition id (header 'workout=', no liftType)
    sample_rate: Optional[float] = None          # rate of .motion in Hz (after any resampling)
    source_rate: Optional[float] = None          # rate of the file (header sampleRate, else measured)
    plan_profile: Optional[str] = None           # header planProfile (build 15+): high | standard
    gps: Optional[str] = None                    # header gps (build 15+): on | off (location updates started)

    def gps_fixes(self) -> list:
        """The '# event ... name=gps' lines of this file as GpsFix records."""
        return parse_gps_events(self.events)


_HEADER_RE = re.compile(r"(\w+)=([^,\s]+)")


@dataclass
class GpsFix:
    """One accepted location fix of a workout session (build 15+). No coordinates, by design.

    Line: '# event t=<s> name=gps distance=<cum m> speed=<m/s> accuracy=<m> altitudeDelta=<m>'
    t is on the CSV time axis; distance is cumulative since the workout start (sum of the distances
    between consecutive accepted fixes); speed is omitted by the watch when unknown (-> None);
    accuracy is the horizontal accuracy; altitudeDelta is relative to the first fix."""
    t: float
    distance: float
    speed: Optional[float]
    accuracy: float
    altitude_delta: float


def parse_gps_events(events) -> list:
    """GpsFix list from the events of `load_session_csv` (other events and malformed gps lines are
    skipped), in file order."""
    out = []
    for e in events:
        if e.get("name") != "gps":
            continue
        vals = {k: e.get(k) for k in ("t", "distance", "accuracy", "altitudeDelta")}
        if not all(isinstance(v, float) for v in vals.values()):
            continue
        speed = e.get("speed")
        out.append(GpsFix(vals["t"], vals["distance"], speed if isinstance(speed, float) else None,
                          vals["accuracy"], vals["altitudeDelta"]))
    return out


def _num(x: str):
    try:
        return float(x)
    except ValueError:
        return x


WORKOUT_HZ = 100.0   # the workout detectors (switches, segments, transitions) are tuned for 100 Hz


def _measured_rate(t: np.ndarray) -> Optional[float]:
    if len(t) < 3:
        return None
    dt = float(np.median(np.diff(t)))
    return 1.0 / dt if dt > 0 else None


def decimate_motion(motion: MotionSeries, factor: int) -> MotionSeries:
    """Every `factor`-th sample, starting with the first (exact values and timestamps)."""
    if factor <= 1:
        return motion
    return MotionSeries(motion.t[::factor], motion.q[::factor], motion.user_accel[::factor],
                        motion.gravity[::factor], motion.rotation_rate[::factor])


def load_session_csv(path, workout_hz: Optional[float] = WORKOUT_HZ) -> SessionCSV:
    """Reads a debug session CSV.

    Workout recordings (header 'workout=') made at 200 Hz (build 15+, CMBatchedSensorManager) are
    decimated to `workout_hz` (default 100) on load, so every workout detector sees 100 Hz as before;
    pass workout_hz=None to keep the file's own rate. Lifting CSVs are never resampled. The rate is
    the header 'sampleRate' when present, else measured from the timestamps.
     Comment lines are skipped anywhere in the file; the watch's
    '# mark t=.. n=.. label=..' and '# event t=.. name=.. homing=.. end=.. reason=..' lines are
    collected into .marks / .events."""
    meta: dict = {}
    marks, events = [], []
    cols = None
    rows = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith("#"):
                body = line[1:].strip()
                kv = dict(_HEADER_RE.findall(body))
                if body.startswith("barpath-session"):
                    meta = kv
                elif body.startswith("mark"):
                    marks.append({k: (_num(v) if k in ("t", "n") else v) for k, v in kv.items()})
                elif body.startswith("event"):
                    events.append({k: (v if k in ("name", "reason") else _num(v)) for k, v in kv.items()})
                continue
            if cols is None:
                cols = [c.strip() for c in line.split(",")]
                continue
            rows.append([float(x) for x in line.split(",")])
    if cols is None:
        cols = list(MOTION_KEYS)
    data = np.array(rows, dtype=float).reshape(len(rows), len(cols))
    d = {c: data[:, i] for i, c in enumerate(cols)}
    start = parse_iso8601(meta["startDate"]) if "startDate" in meta else None
    for m in marks:
        if "n" in m and isinstance(m["n"], float):
            m["n"] = int(m["n"])
    motion = MotionSeries.from_columns(d)
    rate = _num(meta["sampleRate"]) if "sampleRate" in meta else None
    if not isinstance(rate, float) or rate <= 0:
        rate = _measured_rate(motion.t)
    source_rate = rate
    if meta.get("workout") is not None and workout_hz and rate is not None:
        factor = int(round(rate / workout_hz))
        if factor >= 2 and rate / workout_hz >= 1.5:
            motion = decimate_motion(motion, factor)
            rate = rate / factor
    return SessionCSV(meta.get("sessionId"), start, meta.get("liftType"), motion,
                      marks, events, meta.get("workout"), rate, source_rate, meta.get("planProfile"),
                      meta.get("gps"))


def save_session_csv(path, motion: MotionSeries, session_id: str, start_date: datetime,
                     lift_type: str) -> None:
    c = motion.to_columns()
    with open(path, "w") as f:
        f.write(f"# barpath-session v1, sessionId={session_id}, startDate={format_iso8601(start_date)}, "
                f"liftType={lift_type}\n")
        f.write(",".join(MOTION_KEYS) + "\n")
        cols = [np.asarray(c[k]) for k in MOTION_KEYS]
        for i in range(len(motion)):
            f.write(f"{cols[0][i]:.6f}," + ",".join(f"{cols[j][i]:.5f}" for j in range(1, 14)) + "\n")


# ---- helpers --------------------------------------------------------------------------------

def format_iso8601(d: datetime) -> str:
    """Whole-second UTC ISO8601 ('2026-10-25T18:03:11Z').

    Swift's JSONDecoder.DateDecodingStrategy.iso8601 rejects fractional seconds, so we never
    write them (the 'startDate' example in §2 with '.250Z' would not decode in Swift)."""
    d = d.astimezone(timezone.utc) if d.tzinfo else d.replace(tzinfo=timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso8601(s: str) -> datetime:
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    d = datetime.fromisoformat(s)
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def _round_list(v, decimals):
    v = np.asarray(v, dtype=float)
    if decimals is not None:
        v = np.round(v, decimals)
        if decimals <= 0:
            return [float(x) for x in v]
    return v.tolist()


def _opt_round(x, decimals):
    if x is None:
        return None
    return round(float(x), decimals) if decimals is not None else float(x)


def _opt_float(x):
    return None if x is None else float(x)
