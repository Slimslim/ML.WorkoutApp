"""Repeating blocks and fixed lists (docs/WORKOUT_SPEC.md 5c, #138): reference for BarPathKit's
RepeatBlock.swift. Pure functions; WorkoutProgress takes a plan from here in block mode.

A *part* is one listed segment (`segments[p]`, `0 <= p < P`). A *step* is one part as it is actually
done, numbered from START. A *pass* is one time through the block. Step `s` is pass `s // P`,
part `s % P`. A fixed list has exactly `P` steps, so its step numbers are today's segment indices.

Only a definition **marked `listedOnce`** may repeat. Every row stored today is unmarked: it lists
its rounds or windows out, and it takes the legacy route (today's WorkoutProgress, with the §5a AMRAP
expansion), whatever the engine switch says. For a marked definition:
- Repeating block: AMRAP with a cap, EMOM / Tabata / "Go every" (format emom with a cap or a round
  count), and forTime with `rounds`. The whole listed list is the block; `roundSize` is display
  only and plays no part here.
- Fixed list: everything else, done once, exactly as `WorkoutProgress` does today.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional, Tuple

from .workout import WorkoutDefinition

LEGACY = "legacy"
FIXED = "fixed"
REPEAT = "repeat"

ENGINE_V2 = "v2"
ENGINE_LEGACY = "legacy"

END_LIST_DONE = "listDone"       # fixed list: Crown on the last part
END_ROUNDS_DONE = "roundsDone"   # repeating block with N rounds: Crown on the last work part of pass N
END_CAP = "cap"                  # AMRAP / EMOM: the clock


@dataclass(frozen=True)
class BlockPlan:
    kind: str                         # LEGACY, FIXED or REPEAT
    parts: int                        # P, the listed parts
    rounds: Optional[int]             # passes to do; None = until the clock (or End)
    cap_seconds: Optional[float]      # the definition's cap
    cap_ends: bool                    # the cap finishes the workout (AMRAP, EMOM); for time keeps going (5b)
    interval_seconds: Optional[float]  # one window = one pass of the block (owner, 5c Q3)
    trailing_rests: int = 0           # rests after the last work part, skipped on the last pass (no interval)

    @property
    def step_limit(self) -> Optional[int]:
        """Steps in the whole workout; None when only the clock (or End) stops it. Without an
        interval the last pass ends on its last work part (a rest after the last round is not done);
        with one, the last window keeps its rest and the clock ends it."""
        if self.kind != REPEAT:
            return self.parts
        if self.rounds is None:
            return None
        return self.rounds * self.parts - self.trailing_rests

    def to_dict(self) -> dict:
        return {"kind": self.kind, "parts": self.parts, "rounds": self.rounds,
                "capSeconds": self.cap_seconds, "capEnds": self.cap_ends,
                "intervalSeconds": self.interval_seconds, "trailingRests": self.trailing_rests}


def _positive(x) -> bool:
    return x is not None and x > 0


def _trailing_rests(d: WorkoutDefinition) -> int:
    n = 0
    for s in reversed(d.segments):
        if s.kind != "rest":
            break
        n += 1
    return n if n < len(d.segments) else 0


def listed_once_problems(d: WorkoutDefinition) -> list:
    """Why a definition marked listedOnce cannot run as a block (it then takes the legacy route).
    An interval block must end with a rest: that rest is the wait until the next window, so an
    early Crown never starts the next pass before its window (EMOM windows start on the clock)."""
    out = []
    if not d.segments:
        out.append("no segments")
    elif all(s.kind == "rest" for s in d.segments):
        out.append("only rests")
    elif _positive(d.interval_seconds) and d.segments[-1].kind != "rest":
        out.append("interval block does not end with a rest")
    return out


def plan_for(d: WorkoutDefinition) -> BlockPlan:
    """The kind of a definition (5c table). Unmarked (every row stored today): LEGACY. Marked
    `listedOnce`: REPEAT for the repeating formats, else FIXED."""
    n = len(d.segments)
    cap = d.time_cap_seconds if _positive(d.time_cap_seconds) else None
    interval = d.interval_seconds if _positive(d.interval_seconds) else None
    rounds = d.rounds if _positive(d.rounds) else None
    if not d.listed_once or listed_once_problems(d):
        return BlockPlan(LEGACY, n, 1, cap, False, interval)
    if n > 0 and _trailing_rests(d) < n:
        # Rounds for time: the last pass ends on its last work part. With an interval the clock
        # ends the workout, so the last window keeps its rest (Tabata: 16 steps, 4:00 exactly).
        tr = 0 if interval is not None else _trailing_rests(d)
        if d.format == "amrap" and cap is not None:
            return BlockPlan(REPEAT, n, None, cap, True, interval, tr)
        if d.format == "emom" and (cap is not None or rounds is not None):
            return BlockPlan(REPEAT, n, rounds, cap, cap is not None, interval, tr)
        if d.format == "forTime" and rounds is not None:
            return BlockPlan(REPEAT, n, rounds, cap, False, interval, tr)
    if interval is not None:
        # A marked fixed list with an interval ("Go every" done once) keeps today's path: block mode
        # would end it at the first window (E3 review).
        return BlockPlan(LEGACY, n, 1, cap, False, interval)
    return BlockPlan(FIXED, n, 1, cap, False, interval)


MAX_PLANNED_PASSES = 1000   # RepeatBlock.maxPlannedPasses


def planned_steps(d: WorkoutDefinition) -> Optional[int]:
    """Steps a repeating block plans to do: its step limit, else ceil(cap / interval) windows of
    an interval block; None for an AMRAP (only the clock ends it) and for anything not repeating."""
    import math
    plan = plan_for(d)
    if plan.kind != REPEAT or plan.parts <= 0:
        return None
    steps = None
    if plan.rounds is not None:
        steps = float(plan.rounds) * plan.parts - plan.trailing_rests
    elif plan.interval_seconds is not None and plan.cap_seconds is not None and d.format == "emom":
        windows = math.ceil(plan.cap_seconds / plan.interval_seconds - 1e-9) \
            if math.isfinite(plan.cap_seconds / plan.interval_seconds) else None
        steps = None if windows is None else max(1, windows) * plan.parts
    if steps is None or not math.isfinite(steps):
        return None
    # Bounded (a corrupt-file guard): a huge `rounds` or cap must not build a huge list.
    return int(min(max(steps, 0), plan.parts * MAX_PLANNED_PASSES))


def engine_plan(d: WorkoutDefinition, engine: str) -> Optional[BlockPlan]:
    """The plan WorkoutProgress runs in block mode, or None for today's path. Block mode needs both
    the engine switch on ("v2") and a definition marked listedOnce; anything else is today's path."""
    if engine != ENGINE_V2:
        return None
    plan = plan_for(d)
    return None if plan.kind == LEGACY else plan


def written_out(d: WorkoutDefinition) -> WorkoutDefinition:
    """The Classic route for a definition marked listedOnce: its block written out the way today's
    stored rows are, so the legacy progress runs it fully (not one pass, the #138 bug). Rounds for
    time x N: N passes, no rest after the last round. EMOM / Tabata: the round count, else
    ceil(cap / interval) windows. AMRAP: unmarked with roundSize = P, then the 5a expansion at
    START. A repeating block gets roundSize = P; a marked fixed list keeps its own. The mark and
    `rounds` are dropped. Unmarked definitions are unchanged."""
    import dataclasses
    import math
    if not d.listed_once or not d.segments:
        return d
    n = len(d.segments)
    cap = d.time_cap_seconds if _positive(d.time_cap_seconds) else None
    interval = d.interval_seconds if _positive(d.interval_seconds) else None
    rounds = d.rounds if _positive(d.rounds) else None
    passes = None
    if d.format == "forTime" and rounds is not None:
        passes = rounds
    elif d.format == "emom":
        if rounds is not None:
            passes = rounds
        elif interval is not None and cap is not None:
            passes = max(1, math.ceil(cap / interval - 1e-9))
    segs = list(d.segments)
    if passes is not None:
        segs = segs * passes
        if interval is None:
            tr = _trailing_rests(d)
            if tr:
                segs = segs[:-tr]
    # An AMRAP with an interval keeps roundSize unset, as the 5a expansion does (work segments then
    # don't jump at the window).
    repeats = passes is not None or (d.format == "amrap" and cap is not None and interval is None)
    return dataclasses.replace(d, segments=segs, round_size=n if repeats else d.round_size,
                               listed_once=False, rounds=None)


def start_progress(d: WorkoutDefinition, engine: str):
    """The progress the watch starts a workout with (RepeatBlock.startProgress): block mode with
    the engine on and a listed-once definition; otherwise today's progress (Classic), on the
    definition written out (`written_out`, listed-once only) with the 5a AMRAP expansion."""
    from .workout import WorkoutProgress, amrap_expanded
    plan = engine_plan(d, engine)
    if plan is not None:
        return WorkoutProgress(d, plan)
    return WorkoutProgress(amrap_expanded(written_out(d)))


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
    return limit is not None and step >= limit - 1


def previous_step(step: int) -> Optional[int]:
    """Undo goes back one step, across a pass boundary too; nothing before step 0."""
    return step - 1 if step > 0 else None


def end_reason(plan: BlockPlan, step: int, advanced: bool, elapsed: float) -> Optional[str]:
    """Why the workout ends now, or None. `advanced`: the athlete just advanced from `step`;
    `elapsed`: seconds since START. The cap ends only AMRAP / EMOM (for time keeps going, 5b)."""
    if advanced and advance_finishes(plan, step):
        return END_ROUNDS_DONE if plan.kind == REPEAT else END_LIST_DONE
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
    would be past the last one (the clock then finishes).

    Not quite today's WorkoutProgress.autoAdvanceTargetIndex: today a rest goes to the next segment
    and roundSize is the set. Here the window end always goes to the next pass, so a rest in the
    middle of the block that has no timer of its own skips the rest of the pass. A rest with a
    seconds target still ends by itself and hands over to the next part (WorkoutProgress in block
    mode). When the rests are the block's last parts, as in every interval row today, both agree."""
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


# ---- script driver (tests, shared progress fixtures, the E4 engine gate) -----------------------

class _Suppress:
    """What the watch's undo suppresses (WorkoutSessionModel.undo): an auto change whose time has
    already passed (`autoSuppressedStart`, per step start) and a cap already passed (`capSuppressed`)."""

    def __init__(self):
        self.auto_start = None
        self.cap = False


def tick(progress, now: float, suppress: "Optional[_Suppress]" = None) -> None:
    """Applies everything the clock does up to `now`, in time order: the cap that finishes the
    workout (`cap_time`) and the segment changes (`auto_advance_time`). The cap wins a tie. Mirrors
    WorkoutSessionModel.nextClockEvent, including what an undo suppressed."""
    sup = suppress or _Suppress()
    for _ in range(10000):
        if not progress.is_started or progress.is_finished:
            return
        cap = None if sup.cap else progress.cap_time
        auto = progress.auto_advance_time()
        if auto is not None and progress.segment_starts[-1] == sup.auto_start:
            auto = None
        if cap is not None and cap <= now and (auto is None or cap <= auto):
            progress.finish(max(cap, progress.segment_starts[-1]), "auto")
            return
        if auto is None or auto > now:
            return
        if not progress.auto_advance(auto):
            return
    raise RuntimeError("clock loop did not settle")


def run_script(progress, script) -> list:
    """Replays [[t, action], ...] (start / crown / undo / end / tick) on a WorkoutProgress, letting
    the clock run between actions. Returns the events as [t, kind, index, source] lists."""
    sup = _Suppress()
    for t, action in script:
        tick(progress, t, sup)
        if action == "start":
            progress.start(t)
        elif action == "crown":
            progress.advance(t, "crown")
        elif action == "undo":
            if progress.undo(t, "crown"):
                auto = progress.auto_advance_time()
                if auto is not None and auto <= t:
                    sup.auto_start = progress.segment_starts[-1]
                cap = progress.cap_time
                if cap is not None and cap <= t:
                    sup.cap = True
        elif action == "end":
            progress.finish(t, "button")
        elif action != "tick":
            raise ValueError(action)
    return [[e.t, e.kind, e.segment_index, e.source] for e in progress.events]
