"""Insight rules for the results page (docs/RESULTS_INSIGHTS.md, story W47).

Reference for BarPathKit's ResultInsights.swift; the parity test runs both on the same JSON
fixtures (BarPathKitTests/Fixtures/result_insights_cases.json).

`insights(result, definition)` returns at most 3 insights plus at most 1 "next time" cue, each a
dict {"id": rule id, "text": ready-to-show string, "isCue": bool}. Silence beats an unsupported
insight: with nothing that passes the rules the list is empty.

Rules implemented (the "Today: Yes" ones): A1 (F2 for "for time"), A2, A3 and the cue; F1, F5;
L1; R1; E3. F3, F4, E1 and E2 are out of scope.

Data honesty (spec §3), applied before any rule:
- Only completed run and station segments are used: rest and transition segments never enter
  the numbers, and neither does the segment cut by the cap / end.
- A segment shorter than 5 s, or longer than 3x the median of its movement (per target unit when
  all of the movement's targets share a unit, so 21 thrusters are not an outlier next to 9), is
  ignored; "Check your timing on round N" is shown instead (id "CHECK").
- Wording says "segment time" things only: no speed, pace or cause; heart rate is not used.
"""
from __future__ import annotations

import math
from typing import Optional

MAX_INSIGHTS = 3
MIN_SEGMENT_SECONDS = 5.0
MAX_SEGMENT_SECONDS = 86400.0  # a segment of a day or more is broken data: never used
OUTLIER_FACTOR = 3.0
STEADY_FRACTION = 0.05      # A2: within +-5 % of round 1
DRIFT_MIN_SECONDS = 10.0    # A1: at least 10 s extra in total ...
DRIFT_MIN_FRACTION = 0.05   # ... and at least 5 % per round on average
A3_MIN_ROUND_FRACTION = 0.08
HALVES_MIN_FRACTION = 0.05  # F1
RUN_FADE_MIN_FRACTION = 0.05  # F5
STARTED_HARD_FRACTION = 0.08  # R1
LADDER_FRACTION = 0.20      # L1

WORK_KINDS = ("run", "station")

_ROUND_WORDS = [
    (0.1, "a tenth of a round"),
    (0.2, "a fifth of a round"),
    (0.25, "a quarter of a round"),
    (1.0 / 3.0, "a third of a round"),
    (0.5, "half a round"),
    (2.0 / 3.0, "two thirds of a round"),
    (0.75, "three quarters of a round"),
    (1.0, "a full round"),
]


# ---- formatting (shared with Swift: same rounding, half away from zero) ----------------------

def round_half_away(x: float) -> int:
    r = math.floor(abs(x) + 0.5)
    return int(-r if x < 0 else r)


def time_text(seconds: float) -> str:
    """m:ss (h:mm:ss from one hour), of the absolute value, rounded to the second."""
    total = round_half_away(abs(seconds))
    h = total // 3600
    m = (total % 3600) // 60
    s = total % 60
    if h > 0:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def percent_text(fraction: float) -> str:
    """'+22 %', '-6 %', '+0 %'."""
    p = round_half_away(fraction * 100.0)
    return f"+{p} %" if p >= 0 else f"-{-p} %"


def number_text(v: float) -> str:
    return str(int(v)) if v == round(v) else f"{v:.1f}"


def load_text(load) -> str:
    """'140 lb', '2 × 22.5 kg' (SegmentLoad.text in Swift)."""
    v = number_text(load.value) + " " + load.unit
    return f"{load.count} × {v}" if load.count > 1 else v


def join_and(items: list) -> str:
    if len(items) == 0:
        return ""
    if len(items) == 1:
        return items[0]
    return ", ".join(items[:-1]) + " and " + items[-1]


def median(values: list) -> float:
    v = sorted(values)
    n = len(v)
    if n % 2 == 1:
        return v[n // 2]
    return (v[n // 2 - 1] + v[n // 2]) / 2.0


def range_text(values: list, suffix: str = "") -> str:
    """'1:48-1:51' (one value when both ends read the same), then the suffix."""
    a = time_text(min(values))
    b = time_text(max(values))
    return (a if a == b else f"{a}-{b}") + suffix


def _round_fraction_text(f: float) -> str:
    if f < 1.25:
        best = _ROUND_WORDS[0]
        best_diff = abs(f - best[0])
        for item in _ROUND_WORDS[1:]:
            d = abs(f - item[0])
            if d < best_diff:
                best = item
                best_diff = d
        return best[1]
    halves = round_half_away(f * 2.0)
    return number_text(halves / 2.0) + " rounds"


def cue_name(name: str) -> str:
    """Movement name inside the cue: lowercase ("the bike"), unless a word has a capital after its
    first letter (a brand or an acronym: "SkiErg", "KB Swings", "Alt. DB Snatch" keep their case)."""
    for word in name.split(" "):
        if any(c.isupper() for c in word[1:]):
            return name
    return name.lower()


# ---- definition structure --------------------------------------------------------------------

def _same_target(a, b) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return a.value == b.value and a.unit == b.unit


def _same_load(a, b) -> bool:
    if a is None or b is None:
        return a is None and b is None
    return a.value == b.value and a.unit == b.unit and a.count == b.count


UNKNOWN_MOVEMENTS = ("part", "")


def is_known(seg) -> bool:
    """A work segment says which movement it is. Free Workout "part" segments do not: two parts
    are usually different movements, so they are never compared and never grouped."""
    return seg.kind not in WORK_KINDS or seg.movement not in UNKNOWN_MOVEMENTS


def _same_movement(a, b) -> bool:
    return is_known(a) and is_known(b) and a.kind == b.kind and a.movement == b.movement


def _comparable(a, b) -> bool:
    return _same_movement(a, b) and _same_target(a.target, b.target) and _same_load(a.load, b.load)


def _repeats(segments: list, period: int, eq) -> bool:
    """segments[i] eq segments[i % period] for every i, and at least two full rounds."""
    if period <= 0 or len(segments) < 2 * period:
        return False
    for i in range(period, len(segments)):
        if not eq(segments[i], segments[i % period]):
            return False
    return True


def round_size(definition) -> Optional[int]:
    """Segments per round when the (kind, movement) list repeats: the definition's roundSize if it
    repeats, else the shortest repeating period. Nil for chippers and Hyrox-style lists."""
    segs = definition.segments
    if definition.round_size is not None and definition.round_size > 0:
        if _repeats(segs, definition.round_size, _same_movement):
            return definition.round_size
        return None
    n = len(segs)
    for p in range(1, n // 2 + 1):
        if _repeats(segs, p, _same_movement):
            return p
    return None


def is_ladder(definition) -> bool:
    """Some movement appears with different rep targets (21-15-9, 2-4-6 ...)."""
    seen = {}
    for s in definition.segments:
        if s.kind not in WORK_KINDS or not is_known(s) or s.target is None or s.target.unit != "reps":
            continue
        key = s.kind + "|" + s.movement
        if key in seen and seen[key] != s.target.value:
            return True
        if key not in seen:
            seen[key] = s.target.value
    return False


def last_segment_complete(result, definition, recorded: int) -> bool:
    """The last recorded segment counts: every planned segment was done, or the athlete finished
    by hand (Crown, press, button or a phone edit) in a for-time / Free Workout. An AMRAP stopped
    by its cap (finish source "auto") or a workout ended without a finish leaves it partial."""
    if result.finish_date is None:
        return False
    if recorded >= len(definition.segments):
        return True
    if definition.format == "amrap":
        return False
    source = None
    for e in result.events:
        if e.kind == "finish":
            source = e.source
    return source is not None and source != "auto"


# ---- engine ----------------------------------------------------------------------------------

class _Context:
    def __init__(self, result, definition):
        self.result = result
        self.definition = definition
        self.segments = sorted(result.segments, key=lambda s: s.index)
        self.finished = last_segment_complete(result, definition, len(self.segments))
        self.last_index = self.segments[-1].index if self.segments else -1

        # Completed work segments that match their definition segment.
        self.usable = []
        for s in self.segments:
            d = self.def_seg(s.index)
            if d is None or s.kind not in WORK_KINDS or d.kind != s.kind or d.movement != s.movement:
                continue
            if not is_known(d) or not math.isfinite(s.duration) or s.duration < 0 \
                    or s.duration >= MAX_SEGMENT_SECONDS:
                continue
            if not self.finished and s.index == self.last_index:
                continue
            self.usable.append(s)

        self.flagged = self._honesty_filter()
        flagged_idx = set(s.index for s in self.flagged)
        self.clean = {s.index: s for s in self.usable if s.index not in flagged_idx}

        self.round_size = round_size(definition)
        self.ladder = is_ladder(definition)
        self.rounds_ok = (self.round_size is not None and not self.ladder
                          and _repeats(definition.segments, self.round_size, _comparable))
        self.round_count = 0
        if self.round_size is not None:
            self.round_count = (len(definition.segments) + self.round_size - 1) // self.round_size

    def def_seg(self, index: int):
        if 0 <= index < len(self.definition.segments):
            return self.definition.segments[index]
        return None

    def _honesty_filter(self) -> list:
        groups = {}
        order = []
        for s in self.usable:
            key = s.kind + "|" + s.movement
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(s)
        flagged = []
        for m in order:
            group = groups[m]
            targets = [self.def_seg(s.index).target for s in group]
            per_unit = all(t is not None and t.value > 0 for t in targets) and \
                all(t.unit == targets[0].unit for t in targets)
            values = []
            for s, t in zip(group, targets):
                values.append(s.duration / t.value if per_unit else s.duration)
            med = median(values)
            for s, v in zip(group, values):
                if s.duration < MIN_SEGMENT_SECONDS or (med > 0 and v > OUTLIER_FACTOR * med):
                    flagged.append(s)
        flagged.sort(key=lambda s: s.index)
        return flagged

    # Movements in order of first appearance in the definition: (kind|movement key, name).
    def movements(self) -> list:
        out = []
        seen = set()
        for d in self.definition.segments:
            if d.kind not in WORK_KINDS or not is_known(d):
                continue
            key = d.kind + "|" + d.movement
            if key not in seen:
                seen.add(key)
                out.append((key, d.name))
        return out

    def round_indices(self, r: int) -> list:
        lo = r * self.round_size
        hi = min(len(self.definition.segments), lo + self.round_size)
        return list(range(lo, hi))

    def movement_round_time(self, key: str, r: int) -> Optional[float]:
        """Sum of the movement's segment times in round r; None unless all are clean."""
        total = 0.0
        found = False
        for i in self.round_indices(r):
            d = self.definition.segments[i]
            if d.kind not in WORK_KINDS or d.kind + "|" + d.movement != key:
                continue
            s = self.clean.get(i)
            if s is None:
                return None
            total += s.duration
            found = True
        return total if found else None

    def round_work_time(self, r: int) -> Optional[float]:
        """Work time of round r (rest excluded); None unless every work segment is clean."""
        total = 0.0
        found = False
        for i in self.round_indices(r):
            d = self.definition.segments[i]
            if d.kind not in WORK_KINDS:
                continue
            s = self.clean.get(i)
            if s is None:
                return None
            total += s.duration
            found = True
        return total if found else None


def _insight(rule_id: str, text: str, is_cue: bool = False) -> dict:
    return {"id": rule_id, "text": text, "isCue": is_cue}


def _drift(ctx: _Context) -> Optional[dict]:
    """A1 / F2: the movement whose segment time cost the most extra seconds vs its own round 1."""
    best = None
    for key, name in ctx.movements():
        t0 = ctx.movement_round_time(key, 0)
        if t0 is None or t0 <= 0:
            continue
        later = []
        for r in range(1, ctx.round_count):
            t = ctx.movement_round_time(key, r)
            if t is not None:
                later.append(t)
        if not later:
            continue
        extra = 0.0
        for t in later:
            extra += t - t0
        fraction = (extra / len(later)) / t0
        if best is None or extra > best["extra"]:
            best = {"key": key, "name": name, "t0": t0, "later": later, "extra": extra, "fraction": fraction}
    if best is None or best["extra"] < DRIFT_MIN_SECONDS or best["fraction"] < DRIFT_MIN_FRACTION:
        return None
    return best


def _drift_text(d: dict) -> str:
    return (f"{d['name']}: {time_text(d['t0'])} in round 1, then {range_text(d['later'])} "
            f"({percent_text(d['fraction'])}), {time_text(d['extra'])} in total.")


def _steady(ctx: _Context, drift_key: Optional[str]) -> Optional[dict]:
    """A2: movements within +-5 % of their round-1 time in every later round (2+ later rounds)."""
    names = []
    for key, name in ctx.movements():
        if key == drift_key:
            continue
        t0 = ctx.movement_round_time(key, 0)
        if t0 is None or t0 <= 0:
            continue
        later = []
        for r in range(1, ctx.round_count):
            t = ctx.movement_round_time(key, r)
            if t is not None:
                later.append(t)
        if len(later) < 2:
            continue
        if all(abs(t - t0) / t0 <= STEADY_FRACTION for t in later):
            names.append(name)
    if not names:
        return None
    return _insight("A2", f"{join_and(names)} held within 5 %.")


def _into_score(ctx: _Context, drift: dict) -> Optional[dict]:
    """A3: the drift's extra seconds as a share of the average round work time."""
    works = []
    for r in range(ctx.round_count):
        w = ctx.round_work_time(r)
        if w is not None:
            works.append(w)
    if not works:
        return None
    total = 0.0
    for w in works:
        total += w
    avg = total / len(works)
    if avg <= 0:
        return None
    f = drift["extra"] / avg
    if f < A3_MIN_ROUND_FRACTION:
        return None
    return _insight("A3", f"That drift added {time_text(drift['extra'])}, about {_round_fraction_text(f)}.")


def _rounds_label(a: int, b: int, capital: bool) -> str:
    word = "Round" if capital else "round"
    if a == b:
        return f"{word} {a}"
    return f"{word}s {a}-{b}"


def _halves(ctx: _Context) -> Optional[dict]:
    """F1: second half vs first half of the rounds, work time only."""
    n = ctx.round_count
    h = n // 2
    if h < 1:
        return None
    works = []
    for r in range(n):
        w = ctx.round_work_time(r)
        if w is None:
            return None
        works.append(w)
    first = 0.0
    for r in range(h):
        first += works[r]
    second = 0.0
    for r in range(n - h, n):
        second += works[r]
    if first <= 0:
        return None
    diff = second - first
    fraction = diff / first
    if abs(fraction) < HALVES_MIN_FRACTION:
        return None
    later = _rounds_label(n - h + 1, n, True)
    earlier = _rounds_label(1, h, False)
    word = "longer" if diff > 0 else "less"
    return _insight("F1", f"{later} took {time_text(diff)} {word} than {earlier} ({percent_text(fraction)}).")


def _ladder(ctx: _Context) -> Optional[dict]:
    """L1: a ladder segment whose time is more than 20 % off its share of the movement's reps."""
    best = None
    for key, name in ctx.movements():
        entries = []
        for s in ctx.segments:
            if s.index not in ctx.clean:
                continue
            d = ctx.def_seg(s.index)
            if d.kind + "|" + d.movement != key or d.target is None or d.target.unit != "reps" \
                    or d.target.value <= 0:
                continue
            entries.append((s, d.target.value))
        if len(entries) < 2:
            continue
        total_reps = 0.0
        total_time = 0.0
        for s, reps in entries:
            total_reps += reps
            total_time += s.duration
        if total_time <= 0:
            continue
        for i, (s, reps) in enumerate(entries):
            deviation = (s.duration / total_time) / (reps / total_reps) - 1.0
            if best is None or abs(deviation) > abs(best["deviation"]):
                others = [number_text(r) for j, (_, r) in enumerate(entries) if j != i]
                expected = reps * (total_time - s.duration) / (total_reps - reps)
                best = {"deviation": deviation, "name": name, "reps": reps, "time": s.duration,
                        "expected": expected, "others": others}
    if best is None or abs(best["deviation"]) <= LADDER_FRACTION:
        return None
    expected5 = round_half_away(best["expected"] / 5.0) * 5.0
    return _insight("L1", f"{best['name']} {number_text(best['reps'])}: {time_text(best['time'])}, "
                          f"expected about {time_text(expected5)} from your {join_and(best['others'])}.")


def _runs(ctx: _Context, target_only: bool) -> list:
    """Clean runs in order as (segment, meters): target distance, else measured (> 50 m)."""
    out = []
    for s in ctx.segments:
        if s.index not in ctx.clean or s.kind != "run":
            continue
        d = ctx.def_seg(s.index)
        if d.target is not None and d.target.unit == "meters" and d.target.value > 0:
            out.append((s, d.target.value))
        elif not target_only and s.distance is not None and s.distance > 50:
            out.append((s, s.distance))
    return out


def _started_hard(ctx: _Context) -> Optional[dict]:
    """R1: "started hard, then faded", both halves strictly more than 8 %: run 1 is faster than the
    median of the other runs, and that median is slower than run 1."""
    runs = _runs(ctx, target_only=False)
    if len(runs) < 3:
        return None
    same = all(m == runs[0][1] for _, m in runs)
    values = [s.duration if same else s.duration / (m / 1000.0) for s, m in runs]
    first = values[0]
    rest = values[1:]
    med = median(rest)
    # Both halves of "started hard, then faded", strictly more than 8 %: run 1 faster than the
    # median of the rest, and the rest slower than run 1.
    if first <= 0 or med <= 0:
        return None
    if not ((med - first) / med > STARTED_HARD_FRACTION and (med - first) / first > STARTED_HARD_FRACTION):
        return None
    pct = percent_text(med / first - 1.0)
    if same:
        return _insight("R1", f"Started hard, then faded: run 1 in {time_text(first)}, "
                              f"the rest {range_text(rest)} ({pct} at the median).")
    return _insight("R1", f"Started hard, then faded: run 1 at {time_text(first)} /km, "
                          f"the rest {range_text(rest, ' /km')} ({pct} at the median).")


def _run_fade(ctx: _Context) -> Optional[dict]:
    """F5: last run vs first run, from the target distance."""
    runs = _runs(ctx, target_only=True)
    if len(runs) < 2:
        return None
    (s0, m0), (s1, m1) = runs[0], runs[-1]
    same = all(m == m0 for _, m in runs)
    first = s0.duration if same else s0.duration / (m0 / 1000.0)
    last = s1.duration if same else s1.duration / (m1 / 1000.0)
    if first <= 0:
        return None
    fraction = last / first - 1.0
    if abs(fraction) < RUN_FADE_MIN_FRACTION:
        return None
    unit = "" if same else " /km"
    return _insight("F5", f"Runs: first {time_text(first)}{unit}, last {time_text(last)}{unit} "
                          f"({percent_text(fraction)}).")


def _heaviest(ctx: _Context) -> Optional[dict]:
    """E3: heaviest completed load and the loads ladder, for a movement done at 2+ loads."""
    for key, name in ctx.movements():
        loads = []
        for s in ctx.segments:
            if s.index not in ctx.clean:
                continue
            d = ctx.def_seg(s.index)
            if d.kind + "|" + d.movement != key or d.load is None:
                continue
            if not any(_same_load(d.load, x) for x in loads):
                loads.append(d.load)
        if len(loads) < 2:
            continue
        heaviest = loads[0]
        for x in loads[1:]:
            if x.kilograms > heaviest.kilograms:
                heaviest = x
        if all(x.unit == loads[0].unit and x.count == 1 for x in loads):
            ladder = " → ".join(number_text(x.value) for x in loads) + " " + loads[0].unit
        else:
            ladder = " → ".join(load_text(x) for x in loads)
        return _insight("E3", f"{name}: heaviest {load_text(heaviest)}. Loads {ladder}.")
    return None


def _check(ctx: _Context) -> Optional[dict]:
    if not ctx.flagged:
        return None
    if ctx.round_size is not None:
        rounds = []
        for s in ctx.flagged:
            r = s.index // ctx.round_size + 1
            if r not in rounds:
                rounds.append(r)
        word = "round" if len(rounds) == 1 else "rounds"
        return _insight("CHECK", f"Check your timing on {word} {join_and([str(r) for r in rounds])}.")
    if len(ctx.flagged) == 1:
        s = ctx.flagged[0]
        return _insight("CHECK", f"Check your timing on {ctx.def_seg(s.index).title} (segment {s.index + 1}).")
    numbers = [str(s.index + 1) for s in ctx.flagged]
    return _insight("CHECK", f"Check your timing on segments {join_and(numbers)}.")


def insights(result, definition=None) -> list:
    """Up to 3 insights plus at most 1 cue (last), as dicts {"id", "text", "isCue"}."""
    if definition is None or (getattr(result, "is_block_result", False) and definition == result.definition):
        # A block result (5c) indexes steps: use the block written out to the steps done.
        definition = result.display_definition if getattr(result, "is_block_result", False) else result.definition
    ctx = _Context(result, definition)
    fmt = definition.format

    check = _check(ctx)
    budget = MAX_INSIGHTS - (1 if check is not None else 0)
    out = []
    drift = None
    run_rule_done = False

    if fmt == "emom":
        order = ["E3"]
    elif ctx.ladder:
        order = ["L1", "R1", "F5", "E3"]
    elif ctx.rounds_ok:
        if fmt == "amrap":
            order = ["DRIFT", "A3", "A2", "R1", "F5", "E3"]
        else:
            order = ["DRIFT", "F1", "A3", "A2", "R1", "F5", "E3"]
    else:
        order = ["R1", "F5", "E3"]

    for rule in order:
        if len(out) >= budget:
            break
        item = None
        if rule == "DRIFT":
            drift = _drift(ctx)
            if drift is not None:
                item = _insight("A1" if fmt == "amrap" else "F2", _drift_text(drift))
                if drift["key"].startswith("run|"):
                    run_rule_done = True
        elif rule == "A3":
            if drift is not None:
                item = _into_score(ctx, drift)
        elif rule == "A2":
            item = _steady(ctx, drift["key"] if drift is not None else None)
        elif rule == "F1":
            item = _halves(ctx)
        elif rule == "L1":
            item = _ladder(ctx)
        elif rule == "R1":
            if not run_rule_done:
                item = _started_hard(ctx)
                if item is not None:
                    run_rule_done = True
        elif rule == "F5":
            if not run_rule_done and fmt == "forTime":
                item = _run_fade(ctx)
        elif rule == "E3":
            item = _heaviest(ctx)
        if item is not None:
            out.append(item)

    if check is not None:
        out.append(check)
    if drift is not None and any(i["id"] in ("A1", "F2") for i in out):
        cue_time = round_half_away(drift["t0"] / 5.0) * 5.0
        out.append(_insight("CUE", f"Next time: hold the {cue_name(drift['name'])} nearer {time_text(cue_time)}.",
                            is_cue=True))
    return out
