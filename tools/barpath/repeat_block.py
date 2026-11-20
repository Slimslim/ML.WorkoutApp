"""Repeating blocks and fixed lists (docs/WORKOUT_SPEC.md 5c, #138): reference for BarPathKit's
RepeatBlock.swift. Pure functions only; nothing here is wired into the watch or the phone.

A *part* is one listed segment (`segments[p]`, `0 <= p < P`). A *step* is one part as it is actually
done, numbered from START. A *pass* is one time through the block. Step `s` is pass `s // P`,
part `s % P`. A fixed list has exactly `P` steps, so its step numbers are today's segment indices.

- Repeating block: AMRAP with a cap, EMOM/Tabata/"Go every" (format emom with a cap or a round
  count), and forTime with `rounds`. The whole listed list is the block; `roundSize` is display
  only and plays no part here.
- Fixed list: everything else, done once, exactly as `WorkoutProgress` does today.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

from .workout import WorkoutDefinition

FIXED = "fixed"
REPEAT = "repeat"

END_LIST_DONE = "listDone"       # fixed list: Crown on the last part
END_ROUNDS_DONE = "roundsDone"   # repeating block with N rounds: Crown on the last part of pass N
END_CAP = "cap"                  # AMRAP / EMOM: the clock


@dataclass(frozen=True)
class BlockPlan:
    kind: str                         # FIXED or REPEAT
    parts: int                        # P, the listed parts
    rounds: Optional[int]             # passes to do; None = until the clock (or End)
    cap_seconds: Optional[float]      # the definition's cap
    cap_ends: bool                    # the cap finishes the workout (AMRAP, EMOM); for time keeps going (5b)
    interval_seconds: Optional[float]  # one window = one pass of the block (owner, 5c Q3)

    @property
    def step_limit(self) -> Optional[int]:
        """Steps in the whole workout; None when only the clock (or End) stops it."""
        if self.kind == FIXED:
            return self.parts
        if self.rounds is None:
            return None
        return self.rounds * self.parts

    def to_dict(self) -> dict:
        return {"kind": self.kind, "parts": self.parts, "rounds": self.rounds,
                "capSeconds": self.cap_seconds, "capEnds": self.cap_ends,
                "intervalSeconds": self.interval_seconds}


def _positive(x) -> bool:
    return x is not None and x > 0


def plan_for(d: WorkoutDefinition) -> BlockPlan:
    """The kind of a definition (5c table). Anything not listed as repeating is a fixed list."""
    n = len(d.segments)
    cap = d.time_cap_seconds if _positive(d.time_cap_seconds) else None
    interval = d.interval_seconds if _positive(d.interval_seconds) else None
    rounds = d.rounds if _positive(d.rounds) else None
    if n > 0:
        if d.format == "amrap" and cap is not None:
            return BlockPlan(REPEAT, n, None, cap, True, interval)
        if d.format == "emom" and (cap is not None or rounds is not None):
            return BlockPlan(REPEAT, n, rounds, cap, cap is not None, interval)
        if d.format == "forTime" and rounds is not None:
            return BlockPlan(REPEAT, n, rounds, cap, False, interval)
    return BlockPlan(FIXED, n, 1, cap, False, interval)


def position(plan: BlockPlan, step: int) -> Tuple[int, int]:
    """(pass, part) of a step. ValueError for a step before START or past the workout's end."""
    if step < 0 or plan.parts == 0:
        raise ValueError(f"step {step} is not in the workout")
    limit = plan.step_limit
    if limit is not None and step >= limit:
        raise ValueError(f"step {step} is past the last step {limit - 1}")
    return step // plan.parts, step % plan.parts


def advance_finishes(plan: BlockPlan, step: int) -> bool:
    """A Crown advance from this step finishes the workout (instead of starting the next step)."""
    limit = plan.step_limit
    return limit is not None and step == limit - 1


def previous_step(step: int) -> Optional[int]:
    """Undo goes back one step, across a pass boundary too; nothing before step 0."""
    return step - 1 if step > 0 else None


def end_reason(plan: BlockPlan, step: int, advanced: bool, elapsed: float) -> Optional[str]:
    """Why the workout ends now, or None. `advanced`: the athlete just advanced from `step`;
    `elapsed`: seconds since START. The cap ends only AMRAP / EMOM (for time keeps going, 5b)."""
    if advanced and advance_finishes(plan, step):
        return END_LIST_DONE if plan.kind == FIXED else END_ROUNDS_DONE
    if plan.cap_ends and plan.cap_seconds is not None and elapsed >= plan.cap_seconds:
        return END_CAP
    return None


def window_end(plan: BlockPlan, step_start_elapsed: float) -> Optional[float]:
    """Interval workouts ("Go every ..."): the elapsed time at which the window holding this step
    ends, i.e. the next multiple of intervalSeconds after the step began. One window is one pass of
    the block (Q3); the window length comes from intervalSeconds, never from roundSize."""
    if plan.interval_seconds is None:
        return None
    i = plan.interval_seconds
    return (int(step_start_elapsed // i) + 1) * i


def window_target_step(plan: BlockPlan, step: int) -> Optional[int]:
    """Interval workouts: the step the clock moves to at the window's end, the first part of the
    next pass (what is left of this pass is skipped). None without an interval, or when that pass
    would be past the last one (the clock then finishes). Today's rows: their roundSize is the
    block, so this is what the watch does now (WorkoutProgress.autoAdvanceTargetIndex)."""
    if plan.interval_seconds is None or plan.parts == 0 or step < 0:
        return None
    nxt = (step // plan.parts + 1) * plan.parts
    limit = plan.step_limit
    if limit is not None and nxt >= limit:
        return None
    return nxt


def score(plan: BlockPlan, d: WorkoutDefinition, completed_steps: int) -> Tuple[int, int]:
    """(complete passes, work parts done in the cut pass) after `completed_steps` finished steps.
    A pass is complete once its work is done: rests at its end don't count (Q4, as today)."""
    if plan.parts == 0 or completed_steps <= 0:
        return 0, 0
    kinds = [s.kind for s in d.segments]
    last_work = max((i for i, k in enumerate(kinds) if k != "rest"), default=-1)
    full, done_in_pass = divmod(completed_steps, plan.parts)
    if last_work >= 0 and done_in_pass > last_work:
        full, done_in_pass = full + 1, 0
    work_in_cut = sum(1 for k in kinds[:done_in_pass] if k != "rest")
    if plan.rounds is not None:
        full = min(full, plan.rounds)
    return full, work_in_cut
