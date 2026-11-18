"""One watch frame for every wearer (canonical orientation).

Core Motion gives every vector in the watch's own frame, and that frame turns with the way the
watch is worn: on the owner's watch (left wrist, Crown left) the forearm in the front rack reads
gravity.x ~ +0.85, on tester B's (left wrist, Crown right, Apple's default) ~ -0.85. watchOS does not
undo the Crown setting in the data. Every detector here was built on the owner's watch, so each
recording is turned into that frame first and the same detector (and later the same model) works
for everyone.

Canonical frame = left wrist, Crown left (Crown toward the elbow). Two operations cover the four
ways to wear the watch; both are fixed 3x3 matrices M applied to every sample:

  Crown toward the hand (left wrist + Crown right, right wrist + Crown left)
      = the watch turned 180 degrees about its screen axis z: M = diag(-1, -1, 1).
      Applies to userAccel, gravity and rotation rate alike (a proper rotation); the attitude
      quaternion becomes q * r with r = 180 degrees about z, (w, x, y, z) = (0, 0, 0, 1).
  Right wrist = the mirror image of the left: x stays along the forearm, z out of the screen, y
      (across the wrist) flips: M = diag(1, -1, 1) for userAccel and gravity. Rotation rate is a
      pseudovector, so it gets det(M) * M = diag(-1, 1, -1). A mirror is not a rotation, so the
      attitude cannot be mirrored: `q_valid` is False and the quaternion is left as recorded.

The headers' `wrist` and `crown` say how the watch was worn (build 15+). Files without them are
older recordings, all from the owner's watch: treated as canonical (override with wrist=/crown=).
No right-wrist recording exists yet: that case follows from the geometry and is not yet checked
on data.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import numpy as np

from .recording import MotionSeries

CANONICAL = ("left", "left")      # (wrist, crown) of the frame every detector expects
DEFAULT = CANONICAL               # files without the header (before build 15): the owner's watch

TURN = np.diag([-1.0, -1.0, 1.0])     # 180 degrees about z
MIRROR = np.diag([1.0, -1.0, 1.0])    # right wrist -> left wrist


@dataclass(frozen=True)
class Orientation:
    wrist: str
    crown: str
    vector: np.ndarray        # 3x3 for userAccel and gravity
    rotation: np.ndarray      # 3x3 for rotation rate
    turn: bool                # quaternion turned 180 degrees about z
    q_valid: bool             # False after a mirror: the attitude is still the recorded one

    @property
    def is_identity(self) -> bool:
        return not self.turn and self.q_valid


def _side(v: Optional[str], default: str) -> str:
    v = (v or "").strip().lower()
    return v if v in ("left", "right") else default


def orientation(wrist: Optional[str] = None, crown: Optional[str] = None) -> Orientation:
    """The transform from a watch worn on `wrist` with the Crown on `crown` (as the athlete sees
    it, Apple's setting) into the canonical frame. Missing / unknown values: the owner's left/left."""
    w = _side(wrist, DEFAULT[0])
    c = _side(crown, DEFAULT[1])
    toward_hand = (w == "left") == (c == "right")
    m = np.eye(3)
    mirror = w == "right"
    if mirror:
        m = MIRROR @ m
    if toward_hand:
        m = TURN @ m
    det = float(np.linalg.det(m))
    return Orientation(w, c, m, det * m, toward_hand, not mirror)


def _q_turn(q: np.ndarray) -> np.ndarray:
    """q * r, r = 180 degrees about z = (0, 0, 0, 1); q as (w, x, y, z) rows."""
    w, x, y, z = q[:, 0], q[:, 1], q[:, 2], q[:, 3]
    return np.column_stack([-z, y, -x, w])


def canonicalize(motion: MotionSeries, wrist: Optional[str] = None,
                 crown: Optional[str] = None) -> MotionSeries:
    """The same samples in the canonical frame (a new MotionSeries; the input is not changed)."""
    o = orientation(wrist, crown)
    if o.is_identity:
        return motion
    q = _q_turn(motion.q) if o.turn and len(motion.q) else motion.q.copy()
    return MotionSeries(motion.t.copy(), q,
                        motion.user_accel @ o.vector.T,
                        motion.gravity @ o.vector.T,
                        motion.rotation_rate @ o.rotation.T)


def from_header(header: dict) -> Orientation:
    return orientation(header.get("wrist"), header.get("crown"))
