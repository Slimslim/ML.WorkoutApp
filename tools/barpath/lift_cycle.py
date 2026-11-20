"""Lifting block cycle on the watch (#148, stories L7–L9): armed → in set → resting → (Crown) → armed.

Reference for BarPathKit `LiftCycle` (parity fixture `lift_cycle_cases.json`). Times are on the
motion clock (s). Detection listens only while armed or in a set; while resting nothing the
athlete does can start a set, and when the Crown arms the next set only motion from that moment
counts (`listening_from`, fed to SetTracker as `armedFrom`; the lift detector is reset).

- The block starts armed (the athlete starts the watch at the bar).
- `set_started` (first rep counted / lift started) moves armed → in set.
- `set_ended(t)` (set saved / lift ended) moves to resting since `t` (the last rep's top or the
  lift's end, not the moment the set-end rule fired).
- `arm(t)` (a Crown turn) works only while resting; the rest just taken is kept in `last_rest`.
- Swiping to the End page is allowed except in a set.
- Armed time-out (owner, 20 Nov): armed with no set for `ARMED_TIMEOUT` s goes back to resting,
  unless a rep / lift is under way (`busy`); the rest keeps counting from where it started.
  A rep that had already started before the time-out still counts (review of #150): reps starting
  in [armed_at, late_until) stay listened to (`listening_until`), and the first one confirmed
  (`set_started(rep_start)`) turns the rest back into that set.
"""
import math
from dataclasses import dataclass
from typing import Optional

ARMED, IN_SET, RESTING = "armed", "inSet", "resting"
ARMED_TIMEOUT = 180.0   # s


@dataclass
class LiftCycle:
    state: str = ARMED
    since: float = 0.0              # armed: arm time; resting: rest start; in set: arm time
    armed_at: float = 0.0
    last_rest: Optional[float] = None
    rest_start_before_arm: Optional[float] = None
    late_until: Optional[float] = None   # after a time-out: reps starting before this still count

    @classmethod
    def start(cls, t: float) -> "LiftCycle":
        return cls(state=ARMED, since=t, armed_at=t)

    @property
    def is_listening(self) -> bool:
        return self.state != RESTING

    @property
    def listening_from(self) -> float:
        return self.armed_at if self.is_listening or self.late_until is not None else math.inf

    @property
    def listening_until(self) -> float:
        """Reps / lifts starting at or after this are not counted (+inf unless just timed out)."""
        return self.late_until if self.late_until is not None else math.inf

    @property
    def can_show_end_page(self) -> bool:
        return self.state != IN_SET

    def arm(self, t: float) -> bool:
        if self.state != RESTING:
            return False
        self.last_rest = max(0.0, t - self.since)
        self.rest_start_before_arm = self.since
        self.late_until = None
        self.state, self.since, self.armed_at = ARMED, t, t
        return True

    def set_started(self, t: float) -> bool:
        """`t`: the start of the first rep / lift."""
        if self.state == ARMED:
            self.state = IN_SET
            return True
        if self.state == RESTING and self.late_until is not None and self.armed_at <= t < self.late_until:
            # a rep under way at the time-out: the time-out is undone
            self.state, self.since, self.late_until = IN_SET, self.armed_at, None
            return True
        return False

    def set_ended(self, t: float) -> bool:
        if self.state == RESTING:
            return False
        self.state, self.since = RESTING, t
        self.rest_start_before_arm = None
        self.late_until = None
        return True

    def expire_armed(self, t: float, busy: bool) -> bool:
        if self.state != ARMED or busy or t - self.armed_at < ARMED_TIMEOUT:
            return False
        start = self.rest_start_before_arm
        self.state, self.since = RESTING, (start if start is not None else self.armed_at)
        self.rest_start_before_arm = None
        self.late_until = t
        return True

    def snapshot(self) -> dict:
        return {"state": self.state, "since": self.since, "armedAt": self.armed_at,
                "lastRest": self.last_rest, "listening": self.is_listening,
                "canShowEndPage": self.can_show_end_page,
                "listeningFrom": None if math.isinf(self.listening_from) else self.listening_from,
                "listeningUntil": None if math.isinf(self.listening_until) else self.listening_until}


def run(ops):
    """ops: [["start", t] | ["arm", t] | ["setStarted", t] | ["setEnded", t] | ["expire", t, busy]]
    → snapshots with each op's result (True if it changed the state)."""
    cycle = None
    out = []
    for op in ops:
        name, t = op[0], op[1]
        if name == "start":
            cycle = LiftCycle.start(t)
            ok = True
        elif name == "arm":
            ok = cycle.arm(t)
        elif name == "setStarted":
            ok = cycle.set_started(t)
        elif name == "setEnded":
            ok = cycle.set_ended(t)
        elif name == "expire":
            ok = cycle.expire_armed(t, bool(op[2]))
        else:
            raise ValueError(name)
        out.append(dict(cycle.snapshot(), ok=ok))
    return out
