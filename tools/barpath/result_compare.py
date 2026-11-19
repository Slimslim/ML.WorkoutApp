"""W46: how a result compares with the last time (docs/RESULTS_INSIGHTS.md section 2).

Reference for BarPathKit's ResultCompare.swift. Parity fixture:
BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/result_compare_cases.json.

A comparison is made only when the two results are the same workout at the same scale:
- same definition id, format and time cap;
- the same segments (kind, movement, target and load), so a scaled version or other loads are
  not compared;
- the same Rx / Scaled answer when both results have one (W19; `None` = not answered).

Cases (section 2):
| both finished              | "2:04 faster" / "0:38 slower" / "Same time"                   |
| AMRAP                      | "+12 reps" / "-1 round" (total reps; whole rounds as rounds)  |
| finished vs capped         | "Finished (last time capped at 12:00 + 84)"                   |
| capped vs finished         | "Capped (last time finished in 11:48)"                        |
| both capped                | "+9 reps at the cap"                                          |
| other scale or loads       | "Different scale, not compared"                               |
| no earlier result          | None                                                          |
Anything that cannot be scored honestly (ended early, reps at the cap unknown, an interval
workout) gives None: silence beats an unsupported line.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

from .workout import WorkoutDefinition, WorkoutResult

MINUS = "−"
NOT_COMPARED = "Different scale, not compared"

# Tones: how the UI colours the line.
BETTER, WORSE, SAME, NEUTRAL = "better", "worse", "same", "neutral"

# Kinds (one per row of the table above).
TIME, FINISHED_VS_CAPPED, CAPPED_VS_FINISHED, BOTH_CAPPED, AMRAP, NOT_COMPARABLE = (
    "time", "finishedVsCapped", "cappedVsFinished", "bothCapped", "amrap", "notCompared")


def _whole(v: float) -> int:
    """Swift's Int(x.rounded()): halves away from zero."""
    return int(math.floor(abs(v) + 0.5)) * (1 if v >= 0 else -1)


def clock(seconds: float) -> str:
    """'2:04', '1:02:03' (as SummaryFormat.clock, no sign)."""
    total = abs(_whole(seconds))
    h, m, s = total // 3600, (total % 3600) // 60, total % 60
    return f"{h}:{m:02d}:{s:02d}" if h > 0 else f"{m}:{s:02d}"


def _signed(n: int) -> str:
    return ("+" if n >= 0 else MINUS) + str(abs(n))


def _count(n: int, word: str) -> str:
    """'+1 round', '-3 reps' (with the sign)."""
    return _signed(n) + " " + word + ("" if abs(n) == 1 else "s")


# ---- scale ----

def _same_number(a: Optional[float], b: Optional[float]) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) < 1e-6


def _same_segment(a, b) -> bool:
    if a.kind != b.kind or a.movement != b.movement:
        return False
    if (a.target is None) != (b.target is None):
        return False
    if a.target is not None and (a.target.unit != b.target.unit
                                 or not _same_number(a.target.value, b.target.value)):
        return False
    if (a.load is None) != (b.load is None):
        return False
    if a.load is not None and abs(a.load.kilograms - b.load.kilograms) > 0.25:
        return False
    return True


def same_scale(a: WorkoutDefinition, b: WorkoutDefinition, rx_a: Optional[bool] = None,
               rx_b: Optional[bool] = None) -> bool:
    """Same workout at the same scale: id, format, cap, every segment (kind, movement, target,
    load within 0.25 kg) and, when both are answered, Rx / Scaled."""
    if a.id != b.id or a.format != b.format:
        return False
    if not _same_number(a.time_cap_seconds or None, b.time_cap_seconds or None):
        return False
    if len(a.segments) != len(b.segments):
        return False
    if not all(_same_segment(x, y) for x, y in zip(a.segments, b.segments)):
        return False
    if rx_a is not None and rx_b is not None and rx_a != rx_b:
        return False
    return True


def _countable(seg) -> Optional[int]:
    """Reps a segment counts for in a score: reps and Cal targets (Cal counts as reps, as on the
    whiteboard); 0 for a rest; None for anything else (a distance, a time, no target)."""
    if seg.kind == "rest":
        return 0
    t = seg.target
    if t is not None and t.unit in ("reps", "calories"):
        return _whole(t.value)
    return None


def reps_per_round(d: WorkoutDefinition, round_size: Optional[int]) -> Optional[int]:
    """Reps of one full round (the first `round_size` segments), None when a work segment has no
    rep count or there is no round size."""
    if round_size is None or round_size < 1 or round_size > len(d.segments):
        return None
    total = 0
    for seg in d.segments[:round_size]:
        n = _countable(seg)
        if n is None:
            return None
        total += n
    return total if total > 0 else None


def reps_done_at_cap(result: WorkoutResult) -> Optional[int]:
    """For time past the cap: reps of the segments finished by the cap plus `reps_at_cap` of the
    segment running then. None when not capped, when reps at the cap were not entered, or when a
    finished work segment has no rep count (a run)."""
    d = result.definition
    cap = d.time_cap_seconds
    if d.format != "forTime" or cap is None or cap <= 0 or result.total_seconds <= cap:
        return None
    if result.reps_at_cap is None:
        return None
    at = result.start_date.timestamp() + cap
    total = 0
    for s in result.segments:
        if s.end > at:
            continue
        if s.index < 0 or s.index >= len(d.segments):
            return None
        n = _countable(d.segments[s.index])
        if n is None:
            return None
        total += n
    return total + result.reps_at_cap


# ---- the score of one result ----

@dataclass
class ResultScore:
    """What the comparison needs from one result. In the app it is built from the result and its
    WorkoutSummary (rounds and extra reps of an AMRAP come from the summary's clock)."""
    definition: WorkoutDefinition
    total_seconds: float
    finished: bool                       # reached the last segment
    capped: bool = False                 # for time past the cap
    reps_at_cap: Optional[int] = None    # total reps done by the cap (reps_done_at_cap)
    rounds: Optional[int] = None         # AMRAP
    extra_reps: Optional[int] = None     # AMRAP: reps of the unfinished round
    round_size: Optional[int] = None
    rx: Optional[bool] = None            # W19, None = not answered

    def to_dict(self) -> dict:
        return {"definition": self.definition.to_dict(), "totalSeconds": self.total_seconds,
                "finished": self.finished, "capped": self.capped, "repsAtCap": self.reps_at_cap,
                "rounds": self.rounds, "extraReps": self.extra_reps, "roundSize": self.round_size,
                "rx": self.rx}

    @classmethod
    def from_dict(cls, d: dict) -> "ResultScore":
        return cls(WorkoutDefinition.from_dict(d["definition"]), float(d["totalSeconds"]),
                   bool(d["finished"]), bool(d.get("capped", False)), d.get("repsAtCap"),
                   d.get("rounds"), d.get("extraReps"), d.get("roundSize"), d.get("rx"))


@dataclass
class Comparison:
    kind: str
    text: str
    tone: str
    seconds: Optional[float] = None   # time: current - previous (negative = faster)
    reps: Optional[int] = None        # amrap / both capped: current - previous total reps

    def to_dict(self) -> dict:
        return {"kind": self.kind, "text": self.text, "tone": self.tone}


def _tone(diff: float, higher_is_better: bool) -> str:
    if diff == 0:
        return SAME
    return BETTER if (diff > 0) == higher_is_better else WORSE


def _amrap(cur: ResultScore, prev: ResultScore) -> Optional[Comparison]:
    if cur.rounds is None or prev.rounds is None:
        return None
    ce, pe = cur.extra_reps or 0, prev.extra_reps or 0
    per = reps_per_round(cur.definition, cur.round_size)
    if per is not None:
        diff = (cur.rounds * per + ce) - (prev.rounds * per + pe)
        if diff == 0:
            return Comparison(AMRAP, "Same score", SAME, reps=0)
        if diff % per == 0:
            text = _count(diff // per, "round")
        else:
            text = _count(diff, "rep")
        return Comparison(AMRAP, text, _tone(diff, True), reps=diff)
    # A round with a distance: rounds and reps can't be added up.
    dr, de = cur.rounds - prev.rounds, ce - pe
    if dr == 0 and de == 0:
        return Comparison(AMRAP, "Same score", SAME)
    if dr == 0:
        return Comparison(AMRAP, _count(de, "rep"), _tone(de, True))
    text = _count(dr, "round") if de == 0 else _count(dr, "round") + ", " + _count(de, "rep")
    return Comparison(AMRAP, text, _tone(dr, True))


def _for_time(cur: ResultScore, prev: ResultScore) -> Optional[Comparison]:
    cap = cur.definition.time_cap_seconds
    cur_done = cur.finished and not cur.capped
    prev_done = prev.finished and not prev.capped
    if cur_done and prev_done:
        diff = cur.total_seconds - prev.total_seconds
        whole = _whole(diff)
        if whole == 0:
            return Comparison(TIME, "Same time", SAME, seconds=diff)
        word = "faster" if whole < 0 else "slower"
        return Comparison(TIME, clock(diff) + " " + word, BETTER if whole < 0 else WORSE, seconds=diff)
    if cur_done and prev.capped and cap:
        text = "Finished (last time capped at " + clock(cap)
        if prev.reps_at_cap is not None:
            text += " + " + str(prev.reps_at_cap)
        return Comparison(FINISHED_VS_CAPPED, text + ")", BETTER)
    if cur.capped and prev_done:
        return Comparison(CAPPED_VS_FINISHED,
                          "Capped (last time finished in " + clock(prev.total_seconds) + ")", WORSE)
    if cur.capped and prev.capped:
        if cur.reps_at_cap is None or prev.reps_at_cap is None:
            return None
        diff = cur.reps_at_cap - prev.reps_at_cap
        if diff == 0:
            return Comparison(BOTH_CAPPED, "Same reps at the cap", SAME, reps=0)
        return Comparison(BOTH_CAPPED, _count(diff, "rep") + " at the cap", _tone(diff, True), reps=diff)
    return None   # ended early on one side: nothing honest to say


def compare(current: ResultScore, previous: Optional[ResultScore]) -> Optional[Comparison]:
    """The 'vs last time' line, or None when there is nothing to say."""
    if previous is None:
        return None
    if current.definition.id != previous.definition.id:
        return None   # not the same workout: no earlier result of this one
    if not same_scale(current.definition, previous.definition, current.rx, previous.rx):
        return Comparison(NOT_COMPARABLE, NOT_COMPARED, NEUTRAL)
    fmt = current.definition.format
    if fmt == "amrap":
        return _amrap(current, previous)
    if fmt == "forTime":
        return _for_time(current, previous)
    return None   # interval workouts (emom): sets, no single score to compare
