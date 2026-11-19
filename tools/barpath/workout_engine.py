"""Workout timeline engine: plan, reduce, replay (docs/WORKOUT_MODEL_RFC.md §4, §5).

- `plan(definition)` expands a v2 `structure` into steps (each knows its rounds and windows) and the
  clock boundaries as {anchor, offsetMs}. Pure, no clock.
- `reduce(state, event)` is the state machine. Events: start, tick, crown, undo, reps, end (and
  blockDone for "done with this block"). Time is an argument (integer milliseconds); nothing reads
  a clock. It returns (new state, effects); the state passed in is not changed.
- `replay(plan, events)` rebuilds the state from saved events (crash recovery, tests).

Clocks are start-anchored (RFC §4.2.2): a step starts at the *planned* end of the step before it
when the clock ended that step, and at its *actual* end when the athlete ended it; a window ends
at its own start plus its seconds. So no boundary inside a clocked window is ever counted from a
Crown turn. Before any event at time t, every boundary up to t is applied at its planned time
(§4.2.4), earliest first, outer window first at equal times (§4.2.5).

No format names appear in this file: Tabata, EMOM, AMRAP, caps and Hyrox are all the same five
blocks.
"""
from __future__ import annotations

import copy
import hashlib
import json
from dataclasses import dataclass
from typing import Optional

from .workout_structure import (COUNT_UNITS, MAX_STEPS, check_runnable, iter_nodes, node_kind, unbounded)

PLANNER_VERSION = 1

BELL_LOCKOUT_MS = 2000      # a turn less than 2 s after a bell is ignored (§4.2.8, tuned in the gym)
WINDOW_LOCKOUT_MS = 4000    # inside a window: from the later of the last accepted turn and bell
CROWN_LOCKOUT_MS = 2000     # outside any clock: from the last accepted turn (today's rule)
LATE_EVENT_MS = 5000        # a Crown turn more than 5 s late is ignored (§4.2.5)
COUNTDOWN_MS = 3000         # 3-2-1 only if at least 3 s are left (§4.2.4)
MAX_EXTRA_ROUNDS = 1000     # safety bound on rounds added past listRounds

HAPTICS = ("go", "rest", "time")

# The reader is total (RFC 14.4: lenient on read): a value the engine would consume out of these
# bounds, or a plan past MAX_STEPS, refuses the workout ("invalid" / "tooLarge" / "empty") instead
# of crashing or expanding without end. The Swift port uses the same bounds.
MAX_SECONDS = 86400         # a window, rest or seconds target: at most 24 h
MAX_TIMES = 10000           # repeat times and listRounds
MAX_RATIO = 100             # a ratio rest


def _bounded(v, lo, hi):
    """int(v) when v is a number (not a bool) with lo <= v <= hi, else None."""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return None
    if v != v or v < lo or v > hi:
        return None
    return int(v)


class NotRunnable(Exception):
    """The definition can't run on this engine: "Update the app" / "Run as stopwatch"."""

    def __init__(self, reason: str, missing: list):
        super().__init__("%s: %s" % (reason, ", ".join(missing)) if missing else reason)
        self.reason = reason
        self.missing = missing


# ---- expansion --------------------------------------------------------------------------------

@dataclass(frozen=True)
class Step:
    index: int
    id: str
    kind: str                       # part | rest
    node: str                       # id of the node it comes from
    part: Optional[dict] = None     # resolved part content (vary/override/standard applied)
    rest_seconds: Optional[int] = None
    ratio: Optional[float] = None
    ratio_of: Optional[str] = None  # instance key of the node a ratio rest measures
    auto: bool = False              # automatic rest after an early finish (early: wait)
    wait_window: Optional[str] = None
    merged_window: Optional[str] = None  # a clocked rest that also holds that window's automatic rest
    windows: tuple = ()             # enclosing window keys, outer to inner
    rounds: tuple = ()              # ((repeat key, round), ...), outer to inner
    repeats: tuple = ()             # enclosing repeat keys
    scopes: tuple = ()              # every enclosing instance key (repeats, rounds, groups, windows)
    extra: bool = False             # a round added past listRounds
    as_step: bool = False           # a lift complex run as one step

    @property
    def target(self) -> Optional[dict]:
        return (self.part or {}).get("target")

    @property
    def is_max(self) -> bool:
        return self.kind == "part" and bool((self.target or {}).get("max"))

    @property
    def seconds_target(self) -> Optional[int]:
        t = self.target or {}
        if self.kind == "part" and t.get("unit") == "seconds" and "value" in t:
            return int(round(t["value"]))
        return None

    @property
    def counts_reps(self) -> bool:
        """A part whose count is asked when the clock ends it (reps or calories)."""
        return self.kind == "part" and (self.target or {}).get("unit") in COUNT_UNITS

    @property
    def ends(self) -> str:
        """Who ends this step, as declared (§4.2.1). A bell can still cut an athlete step."""
        if self.kind == "rest":
            if self.rest_seconds is not None or self.ratio is not None or self.auto:
                return "clock"
            return "athlete"
        if self.seconds_target is not None or (self.is_max and self.windows):
            return "clock"
        return "athlete"

    def to_dict(self) -> dict:
        d = {"index": self.index, "id": self.id, "kind": self.kind, "node": self.node,
             "ends": self.ends}
        if self.part is not None:
            for k in ("movement", "kind", "name", "target", "load", "who"):
                if k in self.part:
                    d["part" + k[0].upper() + k[1:]] = self.part[k]
        if self.rest_seconds is not None:
            d["restSeconds"] = self.rest_seconds
        if self.ratio is not None:
            d["ratio"] = self.ratio
            d["ratioOf"] = self.ratio_of
        for k, v in (("auto", self.auto), ("extra", self.extra), ("asStep", self.as_step)):
            if v:
                d[k] = True
        if self.wait_window:
            d["waitWindow"] = self.wait_window
        if self.merged_window:
            d["mergedWindow"] = self.merged_window
        d["windows"] = list(self.windows)
        d["rounds"] = [[k, r] for k, r in self.rounds]
        return d


@dataclass(frozen=True)
class Window:
    key: str
    id: str
    seconds_ms: int
    early: str
    late: str
    depth: int                      # 1 = outermost
    ancestors: tuple = ()           # enclosing window keys
    stops: Optional[str] = None     # repeat key a late: end stops

    def to_dict(self) -> dict:
        d = {"key": self.key, "id": self.id, "seconds": self.seconds_ms // 1000, "early": self.early,
             "late": self.late, "depth": self.depth}
        if self.stops:
            d["stops"] = self.stops
        return d


@dataclass(frozen=True)
class RepeatInst:
    key: str
    id: str
    content: dict                   # patched repeat content
    ctx: "Ctx"
    times: Optional[int]
    list_rounds: int
    until: Optional[str]


@dataclass(frozen=True)
class Ctx:
    prefix: str = ""
    windows: tuple = ()
    rounds: tuple = ()
    repeats: tuple = ()
    scopes: tuple = ()
    patches: tuple = ()             # ((node id, patch), ...) outer first
    omitted: frozenset = frozenset()
    direct_repeat: Optional[str] = None
    direct_unbounded: bool = False
    extra: bool = False


class Sink:
    def __init__(self, offset: int = 0):
        self.offset = offset
        self.steps = []
        self.windows = {}
        self.repeats = {}
        self.invalid = None              # "invalid" or "tooLarge": the expansion stopped there

    def add(self, **kw) -> Optional[Step]:
        if self.invalid is not None:
            return None
        if len(self.steps) >= MAX_STEPS:
            self.invalid = "tooLarge"
            return None
        s = Step(index=self.offset + len(self.steps), **kw)
        self.steps.append(s)
        return s

    def fail(self, reason: str = "invalid"):
        if self.invalid is None:
            self.invalid = reason


class Expansion:
    """The structure expanded into steps (unbounded repeats at listRounds), with its windows and
    repeat instances. Rounds past listRounds are generated on demand by `round_steps`."""

    def __init__(self, structure: dict, standard: str = "M", choices: Optional[dict] = None):
        self.structure = structure
        self.standard = standard
        self.choices = choices or {}
        self._ids = {}
        n = 0
        self._unknown = {}
        for kind, c, _, i, body in iter_nodes(structure.get("body")):
            if c is None:
                n += 1
                self._unknown[id(body[i])] = "_unknown%d" % n
                continue
            if isinstance(c.get("id"), str):
                self._ids[id(c)] = c["id"]
            else:
                n += 1
                self._ids[id(c)] = "_%s%d" % (kind, n)
        sink = Sink()
        self._body(structure.get("body") or [], Ctx(), sink)
        self.steps = sink.steps
        self.windows = sink.windows
        self.repeats = sink.repeats
        self.invalid = sink.invalid

    def node_id(self, content: dict) -> str:
        return self._ids[id(content)]

    # -- patches --

    def _patches_for(self, nid: str, ctx: Ctx) -> list:
        return [p for k, p in ctx.patches if k == nid]

    def _apply(self, kind: str, content: dict, patches: list) -> dict:
        if not patches:
            return content
        c = dict(content)                   # shallow: children keep their identity (node ids)
        base = (content.get("target") or {}).get("value")
        base_f = (content.get("target") or {}).get("valueF")
        for p in patches:
            if isinstance(p, (int, float)) or (isinstance(p, dict) and set(p) <= {"value", "valueF"} and p):
                value = p if isinstance(p, (int, float)) else p.get("value")
                if kind == "part":
                    t = dict(c.get("target") or {"unit": "reps"})
                    t.pop("max", None)
                    if value is not None:
                        t["value"] = value
                    if isinstance(p, dict) and "valueF" in p:
                        t["valueF"] = p["valueF"]
                    elif base_f is not None and base and value is not None:
                        t["valueF"] = int(base_f * value / base + 0.5)
                    c["target"] = t
                elif kind == "repeat":
                    c["times"] = value
                elif kind in ("timed", "rest"):
                    c["seconds"] = value
            elif isinstance(p, dict):
                for k, v in p.items():
                    c[k] = copy.deepcopy(v)
        return c

    def _resolve_part(self, content: dict, nid: str) -> dict:
        p = dict(content)
        p["id"] = nid
        if self.standard == "F":
            t = p.get("target")
            if isinstance(t, dict) and "valueF" in t:
                t = dict(t)
                t["value"] = t["valueF"]
                p["target"] = t
            ld = p.get("load")
            if isinstance(ld, dict) and "valueF" in ld:
                ld = dict(ld)
                ld["value"] = ld["valueF"]
                p["load"] = ld
        mv = p.get("movement")
        if isinstance(mv, dict):
            chosen = self.choices.get(nid)
            choice = mv.get("choice")
            p["movement"] = chosen or (choice[0] if isinstance(choice, list) else "part")
        return p

    # -- body --

    def _body(self, body: list, ctx: Ctx, sink: Sink):
        items = []
        for i, w in enumerate(body):
            kind, c = node_kind(w)
            if c is None:
                # An unknown node falls back to an athlete-paced part showing its text, never a
                # guess (RFC 14.3 A4).
                nid = self._unknown.get(id(w), "_unknown")
                text = (w.get("rawText") or w.get("note")) if isinstance(w, dict) else None
                items.append(("part", {"movement": "part", "name": text or "Unknown block",
                                       "unknown": True}, nid))
                continue
            nid = self.node_id(c)
            if nid in ctx.omitted:
                continue
            items.append((kind, self._apply(kind, c, self._patches_for(nid, ctx)), nid))
        prev_key = None
        merged = None
        for i, (kind, c, nid) in enumerate(items):
            if sink.invalid is not None:
                return
            key = ctx.prefix + nid
            if kind == "part":
                t = c.get("target")
                if isinstance(t, dict) and t.get("unit") == "seconds" and "value" in t \
                        and _bounded(t["value"], 0, MAX_SECONDS) is None:
                    sink.fail()
                    return
                sink.add(id=key, kind="part", node=nid, part=self._resolve_part(c, nid),
                         windows=ctx.windows, rounds=ctx.rounds, repeats=ctx.repeats,
                         scopes=ctx.scopes + (key,), extra=ctx.extra)
            elif kind == "rest":
                seconds = c.get("seconds")
                if seconds is not None:
                    seconds = _bounded(seconds, 1, MAX_SECONDS)
                    if seconds is None:
                        sink.fail()
                        return
                ratio = c.get("ratio")
                if ratio is not None and (isinstance(ratio, bool) or not isinstance(ratio, (int, float))
                                          or not 0 < ratio <= MAX_RATIO):
                    sink.fail()
                    return
                sink.add(id=key, kind="rest", node=nid,
                         rest_seconds=seconds,
                         ratio=c.get("ratio"), ratio_of=prev_key if "ratio" in c else None,
                         merged_window=merged if seconds is not None else None,
                         windows=ctx.windows, rounds=ctx.rounds, repeats=ctx.repeats,
                         scopes=ctx.scopes + (key,), extra=ctx.extra)
            elif kind == "group":
                if c.get("asStep"):
                    part = {"id": nid, "movement": "complex", "name": c.get("label") or nid}
                    if "load" in c:
                        part["load"] = c["load"]
                    sink.add(id=key, kind="part", node=nid, part=self._resolve_part(part, nid),
                             windows=ctx.windows, rounds=ctx.rounds, repeats=ctx.repeats,
                             scopes=ctx.scopes + (key,), extra=ctx.extra, as_step=True)
                else:
                    self._body(c.get("body") or [], Ctx(
                        ctx.prefix, ctx.windows, ctx.rounds, ctx.repeats, ctx.scopes + (key,),
                        ctx.patches, ctx.omitted, None, False, ctx.extra), sink)
            elif kind == "repeat":
                self._repeat(c, nid, key, ctx, sink)
            elif kind == "timed":
                nxt = items[i + 1] if i + 1 < len(items) else None
                merge = (c.get("early") == "wait" and nxt is not None and nxt[0] == "rest"
                         and nxt[1].get("seconds") is not None)
                self._timed(c, nid, key, ctx, sink, merge)
            merged = key if kind == "timed" and c.get("early") == "wait" else None
            prev_key = key

    def _timed(self, c: dict, nid: str, key: str, ctx: Ctx, sink: Sink, merge: bool):
        stops = None
        if c.get("late") == "end":
            candidates = []
            for w in c.get("body") or []:
                k, cc = node_kind(w)
                if k == "repeat" and unbounded(cc):
                    candidates.append((self.node_id(cc), ctx.prefix + self.node_id(cc)))
            if ctx.direct_repeat is not None and ctx.direct_unbounded:
                candidates.append((ctx.direct_repeat.rsplit(".", 1)[-1], ctx.direct_repeat))
            named = c.get("stops")
            for cid, ckey in candidates:
                if named is None or named == cid or ckey.endswith("." + named) or ckey == named:
                    stops = ckey
                    break
        seconds = _bounded(c.get("seconds"), 1, MAX_SECONDS)
        if seconds is None:
            sink.fail()
            return
        w = Window(key=key, id=nid, seconds_ms=seconds * 1000, early=c.get("early") or "",
                   late=c.get("late") or "", depth=len(ctx.windows) + 1, ancestors=ctx.windows, stops=stops)
        sink.windows[key] = w
        inner = Ctx(ctx.prefix, ctx.windows + (key,), ctx.rounds, ctx.repeats, ctx.scopes + (key,),
                    ctx.patches, ctx.omitted, None, False, ctx.extra)
        self._body(c.get("body") or [], inner, sink)
        if c.get("early") == "wait" and not merge:
            sink.add(id=key + ".wait", kind="rest", node=nid, auto=True, wait_window=key,
                     windows=ctx.windows + (key,), rounds=ctx.rounds, repeats=ctx.repeats,
                     scopes=ctx.scopes + (key,), extra=ctx.extra)

    def _repeat(self, c: dict, nid: str, key: str, ctx: Ctx, sink: Sink):
        times = c.get("times")
        if times is not None:
            times = _bounded(times, 0, MAX_TIMES)
            if times is None:
                sink.fail()
                return
            lr = times
        else:
            lr = _bounded(c.get("listRounds") or 1, 1, MAX_TIMES)
            if lr is None:
                sink.fail()
                return
        inst = RepeatInst(key=key, id=nid, content=c, ctx=ctx, times=times,
                          list_rounds=lr, until=c.get("until"))
        sink.repeats[key] = inst
        for r in range(1, lr + 1):
            if sink.invalid is not None or not self._round(inst, r, sink):
                break

    def _vary_value(self, spec, r: int, inst: RepeatInst):
        """The vary value for round r, or the marker STOP when an unbounded list stops."""
        if isinstance(spec, list):
            if r <= len(spec):
                return spec[r - 1]
            if inst.content.get("then") == "stop":
                return _STOP
            return spec[-1]
        return spec["from"] + spec["step"] * (r - 1)

    def _round(self, inst: RepeatInst, r: int, sink: Sink) -> bool:
        """Expands round r of a repeat into sink; False when a vary list stops the repeat."""
        ctx = inst.ctx
        patches = list(ctx.patches)
        for vid, spec in (inst.content.get("vary") or {}).items():
            v = self._vary_value(spec, r, inst)
            if v is _STOP:
                return False
            patches.append((vid, v))
        omitted = set(ctx.omitted)
        for o in inst.content.get("override") or []:
            rounds = o.get("rounds") or []
            hit = r in rounds or ("last" in rounds and inst.times is not None and r == inst.times)
            if not hit:
                continue
            if o.get("omit"):
                omitted.add(o["id"])
            elif "set" in o:
                patches.append((o["id"], o["set"]))
        rkey = "%s.%d" % (inst.key, r)
        inner = Ctx(prefix=rkey + ".", windows=ctx.windows, rounds=ctx.rounds + ((inst.key, r),),
                    repeats=ctx.repeats + (inst.key,), scopes=ctx.scopes + (inst.key, rkey),
                    patches=tuple(patches), omitted=frozenset(omitted), direct_repeat=inst.key,
                    direct_unbounded=inst.times is None,
                    extra=ctx.extra or (inst.times is None and r > inst.list_rounds))
        self._body(inst.content.get("body") or [], inner, sink)
        return True

    def round_steps(self, key: str, r: int, offset: int) -> Optional[Sink]:
        """Round r of the unbounded repeat `key` (past listRounds), indexed from offset; None when
        the repeat has no more rounds."""
        inst = self.repeats[key]
        sink = Sink(offset)
        if not self._round(inst, r, sink) or not sink.steps or sink.invalid is not None:
            return None
        return sink


_STOP = object()


def expand(structure: dict, standard: str = "M", choices: Optional[dict] = None) -> Expansion:
    return Expansion(structure, standard, choices)


# ---- plan -------------------------------------------------------------------------------------

class Plan:
    def __init__(self, definition: dict, structure: dict, exp: Expansion, scale: Optional[str]):
        self.definition = definition
        self.structure = structure
        self.exp = exp
        self.scale = scale
        self.score = structure.get("score") or {"type": "none"}
        self.steps = exp.steps
        self.windows = exp.windows
        self.bells = _static_bells(exp)

    def to_dict(self) -> dict:
        return {"planner": PLANNER_VERSION,
                "steps": [s.to_dict() for s in self.steps],
                "windows": [w.to_dict() for w in self.windows.values()],
                "bells": self.bells}

    def canonical_json(self) -> str:
        return canonical_json(self.to_dict())

    @property
    def hash(self) -> str:
        return hashlib.sha256(self.canonical_json().encode("utf-8")).hexdigest()


def _canon(v):
    if isinstance(v, float) and v == int(v):
        return int(v)
    if isinstance(v, dict):
        return {k: _canon(x) for k, x in v.items()}
    if isinstance(v, (list, tuple)):
        return [_canon(x) for x in v]
    return v


def canonical_json(v) -> str:
    """Sorted keys, no spaces, whole numbers as integers (40 never 40.0), RFC §14.3 E6."""
    return json.dumps(_canon(v), sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def plan(definition: dict, scale: Optional[str] = None, standard: str = "M",
         choices: Optional[dict] = None, engine_features=()) -> Plan:
    """Plans a v2 definition (or a bare structure). Raises NotRunnable for a draft, an unknown
    schema version or a feature this engine doesn't run."""
    if "body" in definition and "structure" not in definition:
        definition = {"schemaVersion": 2, "structure": definition}
    status, missing = check_runnable(definition, engine_features)
    if status != "ok":
        raise NotRunnable(status, missing)
    structure = definition["structure"]
    if scale is not None:
        for s in definition.get("scales") or []:
            if s.get("id") == scale:
                structure = s["structure"]
                break
        else:
            raise KeyError("no scale %r" % scale)
    exp = expand(structure, standard, choices)
    if exp.invalid is not None:
        raise NotRunnable(exp.invalid, [])
    if not exp.steps:
        raise NotRunnable("empty", [])
    return Plan(definition, structure, exp, scale)


def _static_bells(exp: Expansion) -> list:
    """Every clock boundary of the listed steps as {id, anchor, offsetMs}. The anchor is "start"
    (the START tap) or the id of the step / window whose actual end it is counted from."""
    bells = []
    cur = ("start", 0)
    opened = {}
    steps = exp.steps
    for i, s in enumerate(steps):
        for wk in s.windows:
            if wk not in opened:
                w = exp.windows[wk]
                opened[wk] = (cur[0], cur[1] + w.seconds_ms)
                bells.append({"id": wk + ".end", "anchor": cur[0], "offsetMs": cur[1] + w.seconds_ms})
        if s.auto:
            end = opened[s.wait_window]
        elif s.merged_window is not None:
            wb = opened[s.merged_window]
            end = (wb[0], wb[1] + s.rest_seconds * 1000)
            bells.append({"id": s.id + ".end", "anchor": end[0], "offsetMs": end[1]})
        elif s.kind == "rest" and s.rest_seconds is not None:
            end = (cur[0], cur[1] + s.rest_seconds * 1000)
            bells.append({"id": s.id + ".end", "anchor": end[0], "offsetMs": end[1]})
        elif s.seconds_target is not None:
            end = (cur[0], cur[1] + s.seconds_target * 1000)
            bells.append({"id": s.id + ".end", "anchor": end[0], "offsetMs": end[1]})
        else:
            end = (s.id, 0)        # the athlete (or a ratio of the athlete's time) ends it
        cur = end
        nxt = steps[i + 1].windows if i + 1 < len(steps) else ()
        for wk in reversed(s.windows):
            if wk in nxt:
                continue
            w = exp.windows[wk]
            if w.early == "wait":
                cur = opened[wk]
            else:
                cur = (wk, 0)      # ends when the athlete finishes or at its bell
    return bells


# ---- state ------------------------------------------------------------------------------------

class State:
    def __init__(self, p: Plan):
        self.plan = p
        self.steps = list(p.steps)
        self.windows = dict(p.windows)
        self.seq = [s.index for s in p.steps]
        self.pos = -1
        self.t0 = None
        self.now = None
        self.rec = {}            # step index -> {start, end, endedBy, status, reps}
        self.wstate = {}         # window key -> {start, end, open, fired}
        self.due = None          # when the clock ends the current step, or None
        self.repeats = {}        # unbounded repeat key -> {rounds, last, stopped}
        for key, inst in p.exp.repeats.items():
            if inst.times is None:
                last = None
                for s in p.steps:
                    if key in s.repeats:
                        last = s.index
                self.repeats[key] = {"rounds": inst.list_rounds, "last": last, "stopped": False,
                                     "until": inst.until}
        self.last_bell = None
        self.last_cut = None     # step a bell cut at last_bell (for grace)
        self.last_crown = None
        self.cap = None          # {step, t, window, reps} at a late: continue bell
        self.asks = []           # step ids whose count is asked
        self.done = False
        self.done_t = None
        self.ended_by = None     # athlete | clock | end
        self.snaps = []          # [(crown time, snapshot)] for undo
        self.log = []            # events that changed or were judged (no ticks)
        self.ignored = []        # [{t, action, reason}] for name=input action=ignored
        self.cd = None           # countdown {bell, armed, next}

    def clone(self, with_snaps: bool = True) -> "State":
        """A copy that shares only immutable parts (plan, steps, windows)."""
        c = State.__new__(State)
        c.__dict__.update(self.__dict__)
        c.steps = list(self.steps)
        c.windows = dict(self.windows)
        c.seq = list(self.seq)
        c.rec = {k: dict(v) for k, v in self.rec.items()}
        c.wstate = {k: dict(v) for k, v in self.wstate.items()}
        c.repeats = {k: dict(v) for k, v in self.repeats.items()}
        c.cap = None if self.cap is None else dict(self.cap)
        c.asks = list(self.asks)
        c.snaps = list(self.snaps) if with_snaps else []
        c.log = list(self.log)
        c.ignored = list(self.ignored)
        c.cd = None if self.cd is None else dict(self.cd)
        return c

    @property
    def current(self) -> Optional[Step]:
        if self.pos < 0 or self.done or self.pos >= len(self.seq):
            return None
        return self.steps[self.seq[self.pos]]

    def step_by_id(self, sid: str) -> Optional[Step]:
        for s in self.steps:
            if s.id == sid:
                return s
        return None


def initial(p: Plan) -> State:
    return State(p)


# ---- reduce -----------------------------------------------------------------------------------

def reduce(state: State, event: dict) -> tuple:
    """(new state, effects) after one event {kind, t[, began, step, value]} at integer ms."""
    kind = event["kind"]
    t = int(event["t"])
    st = state.clone()
    effects = []
    if kind == "start":
        if st.t0 is not None:
            return st, []
        st.t0 = t
        st.now = t
        st.pos = 0
        st.log.append(dict(event))
        _enter(st, t, effects, by_clock=False)
        effects.append({"kind": "start", "t": t})
        _countdown(st, t, effects)
        return st, effects
    if st.t0 is None:
        return st, []
    if t < st.now:
        if kind == "tick":
            return st, []
        if st.now - t > LATE_EVENT_MS:
            st.ignored.append({"t": t, "action": kind, "reason": "late"})
            return st, [{"kind": "hint", "t": st.now, "reason": "late"}]
        return _late(st, dict(event))
    _catch_up(st, t, effects)
    st.now = t
    if kind == "crown":
        st.log.append(dict(event))
        _crown(st, t, int(event.get("began", t)), effects)
    elif kind == "undo":
        st.log.append(dict(event))
        st = _undo(st, t, effects)
    elif kind == "reps":
        st.log.append(dict(event))
        _reps(st, event["step"], event.get("value"))
    elif kind == "end":
        st.log.append(dict(event))
        _end(st, t, effects)
    elif kind == "blockDone":
        st.log.append(dict(event))
        _block_done(st, t, effects)
    _countdown(st, t, effects)
    return st, effects


def _effect_key(e: dict) -> tuple:
    """What an effect says, without its time: a late event can move an effect in time (an "I
    stopped" ask at 19.9 s instead of the bell's at 20 s) without making it new."""
    return (e["kind"], e.get("step"), e.get("n"), e.get("reason"))


def _timeline(p: Plan, log: list, t: int, now: int, extra: Optional[dict] = None) -> tuple:
    """(state, effects from t to now) for `log`, optionally with `extra` applied at t. Everything
    up to t is caught up first and its effects discarded: they already played live."""
    st = replay(p, [e for e in log if int(e["t"]) <= t], until=t)
    out = []
    if extra is not None:
        st, eff = reduce(st, extra)
        out.extend(eff)
    for e in [e for e in log if int(e["t"]) > t]:
        st, eff = reduce(st, e)
        out.extend(eff)
    st, eff = reduce(st, {"kind": "tick", "t": now})
    out.extend(eff)
    return st, out


def _late(st: State, event: dict) -> tuple:
    """A late event within 5 s is applied in time order: rebuild from the log. Only what the new
    timeline adds to what already played is returned (the event's own hint, ask, grace, done...),
    with at most the current state's haptic, and only if the step changed (§4.2.4)."""
    t = int(event["t"])
    _, played = _timeline(st.plan, st.log, t, st.now)
    rebuilt, fresh = _timeline(st.plan, st.log, t, st.now, event)
    rebuilt.ignored = st.ignored + [x for x in rebuilt.ignored if x not in st.ignored]
    remaining = {}
    for e in played:
        k = _effect_key(e)
        remaining[k] = remaining.get(k, 0) + 1
    new = []
    for e in fresh:
        k = _effect_key(e)
        if remaining.get(k, 0) > 0:
            remaining[k] -= 1
            continue
        new.append(e)
    effects = [e for e in new if e["kind"] not in HAPTICS and e["kind"] != "countdown"]
    before = st.current.id if st.current else None
    after = rebuilt.current.id if rebuilt.current else None
    haptics = [e for e in new if e["kind"] in HAPTICS]
    if haptics and (before != after or rebuilt.done != st.done):
        effects.append(haptics[-1])
    return rebuilt, effects


def replay(p: Plan, events: list, until: Optional[int] = None) -> State:
    """The state after `events` (sorted by time, stable). With `until`, a final tick there; replay
    never catches up past it (crash recovery replays only to the last checkpoint, §4.2.11)."""
    st = initial(p)
    for e in sorted(events, key=lambda e: int(e["t"])):
        st, _ = reduce(st, e)
    if until is not None and st.t0 is not None and until >= st.now:
        st, _ = reduce(st, {"kind": "tick", "t": until})
    return st


def run(p: Plan, events: list) -> tuple:
    """(final state, every effect) feeding `events` in the given order (ticks included)."""
    st = initial(p)
    out = []
    for e in events:
        st, eff = reduce(st, e)
        out.extend(eff)
    return st, out


# ---- engine internals ---------------------------------------------------------------------------

def _rec(st: State, idx: int) -> dict:
    return st.rec.setdefault(idx, {"start": None, "end": None, "endedBy": None, "status": "running",
                                   "reps": None})


def _finish(st: State, idx: int, t: int, by: str, status: str):
    r = _rec(st, idx)
    r["end"] = t
    r["endedBy"] = by
    r["status"] = status


def _ask(st: State, step: Step):
    if step.id not in st.asks:
        st.asks.append(step.id)


def _scope_ms(st: State, key: str) -> int:
    starts, ends = [], []
    for idx, r in st.rec.items():
        s = st.steps[idx]
        if key in s.scopes and not s.auto and r["start"] is not None and r["end"] is not None \
                and r["status"] in ("done", "cut"):
            starts.append(r["start"])
            ends.append(r["end"])
    return max(ends) - min(starts) if starts else 0


def _enter(st: State, t: int, effects: list, by_clock: bool):
    idx = st.seq[st.pos]
    s = st.steps[idx]
    st.rec[idx] = {"start": t, "end": None, "endedBy": None, "status": "running", "reps": None}
    for wk in s.windows:
        if wk not in st.wstate:
            st.wstate[wk] = {"start": t, "end": t + st.windows[wk].seconds_ms, "open": True, "fired": False}
    due = None
    if s.auto:
        due = None                                     # the window's bell ends it
    elif s.merged_window is not None:
        due = st.wstate[s.merged_window]["end"] + s.rest_seconds * 1000
    elif s.kind == "rest" and s.rest_seconds is not None:
        due = t + s.rest_seconds * 1000
    elif s.kind == "rest" and s.ratio is not None:
        milli = int(round(s.ratio * 1000))          # ratio in thousandths: integer maths only
        seconds = (milli * _scope_ms(st, s.ratio_of) + 500000) // 1000000
        due = t + seconds * 1000
    elif s.seconds_target is not None:
        due = t + s.seconds_target * 1000
    st.due = due
    if by_clock:
        effects.append({"kind": "go" if s.kind == "part" else "rest", "t": t, "step": s.id})


def _next_index(st: State) -> Optional[int]:
    """The next step in order, adding a round to an unbounded repeat at the end of its list."""
    cur = st.seq[st.pos]
    for key, rs in st.repeats.items():
        if rs["stopped"] or rs["last"] != cur:
            continue
        if rs["rounds"] - st.plan.exp.repeats[key].list_rounds >= MAX_EXTRA_ROUNDS:
            rs["stopped"] = True
            continue
        sink = st.plan.exp.round_steps(key, rs["rounds"] + 1, len(st.steps))
        if sink is None:
            rs["stopped"] = True
            continue
        st.steps.extend(sink.steps)
        st.windows.update(sink.windows)
        st.seq[st.pos + 1:st.pos + 1] = [s.index for s in sink.steps]
        rs["rounds"] += 1
        rs["last"] = sink.steps[-1].index
    if st.pos + 1 < len(st.seq):
        return st.seq[st.pos + 1]
    return None


def _advance(st: State, t: int, effects: list, by_clock: bool):
    old = st.steps[st.seq[st.pos]]
    nxt = _next_index(st)
    if nxt is None:
        for ws in st.wstate.values():
            ws["open"] = False
        st.done = True
        st.done_t = t
        st.ended_by = "clock" if by_clock else "athlete"
        st.due = None
        if by_clock:
            effects.append({"kind": "time", "t": t})
        effects.append({"kind": "done", "t": t})
        return
    new = st.steps[nxt]
    for wk in old.windows:
        if wk not in new.windows and wk in st.wstate:
            st.wstate[wk]["open"] = False
    st.pos += 1
    _enter(st, t, effects, by_clock)


def _bells(st: State) -> list:
    """Pending boundaries as (time, depth, kind, key), earliest first, outer first at equal times."""
    if st.done or st.pos < 0:
        return []
    out = []
    for wk, ws in st.wstate.items():
        if ws["open"] and not ws["fired"]:
            out.append((ws["end"], st.windows[wk].depth, "window", wk))
    if st.due is not None:
        out.append((st.due, 1000, "step", st.seq[st.pos]))
    out.sort(key=lambda b: (b[0], b[1]))
    return out


def _catch_up(st: State, t: int, effects: list):
    applied = []
    guard = 0
    while True:
        bells = _bells(st)
        if not bells or bells[0][0] > t:
            break
        b = bells[0]
        _apply_bell(st, b[0], b[2], b[3], applied)
        guard += 1
        if guard > 100000:
            raise RuntimeError("catch-up did not converge")
    # Only the entry haptic of the state you are in now plays, once (§4.2.4).
    last_haptic = None
    for i, e in enumerate(applied):
        if e["kind"] in HAPTICS:
            last_haptic = i
    for i, e in enumerate(applied):
        if e["kind"] in HAPTICS and i != last_haptic:
            continue
        effects.append(e)


def _apply_bell(st: State, b: int, kind: str, key, effects: list):
    st.last_bell = b
    st.last_cut = None
    idx = st.seq[st.pos]
    s = st.steps[idx]
    if kind == "step":
        _finish(st, idx, b, "clock", "done")
        _advance(st, b, effects, by_clock=True)
        return
    w = st.windows[key]
    ws = st.wstate[key]
    if w.late == "continue":
        ws["fired"] = True
        st.cap = {"step": s.id, "t": b, "window": key, "reps": None}
        if s.counts_reps:
            _ask(st, s)
        effects.append({"kind": "time", "t": b})
        effects.append({"kind": "cap", "t": b, "step": s.id})
        return
    if s.auto:
        # Finished early: the bell only ends the automatic rest. A late: end stops nothing here,
        # since the work was done in time.
        _finish(st, idx, b, "clock", "done")
        ws["open"] = False
        _advance(st, b, effects, by_clock=True)
        return
    planned_end = s.seconds_target is not None and st.due == b
    if w.late == "end" and w.stops is None and st.plan.score.get("type") == "time" \
            and st.cap is None and not (planned_end and _last_in_window(st, key)):
        # A hard cap: the workout's time is CAP + reps, ranked below every finisher (RFC 3.4, D6).
        st.cap = {"step": s.id, "t": b, "window": key, "reps": None, "hard": True}
        effects.append({"kind": "cap", "t": b, "step": s.id})
    if s.kind == "rest":
        _finish(st, idx, b, "clock", "done")
    elif planned_end:
        _finish(st, idx, b, "clock", "done")        # a seconds part ending on the bell: as planned
    elif s.is_max:
        _finish(st, idx, b, "clock", "done")        # the bell is a max part's planned ending
        _ask(st, s)
        effects.append({"kind": "ask", "t": b, "step": s.id})
    else:
        _finish(st, idx, b, "clock", "cut")
        st.last_cut = idx
        if s.counts_reps:
            _ask(st, s)
            effects.append({"kind": "ask", "t": b, "step": s.id})
    stop = w.stops if w.late == "end" else None
    if stop is not None and stop in st.repeats:
        st.repeats[stop]["stopped"] = True
    # Skip what is left of the window (and of the repeat a late: end stops).
    while True:
        nxt = _next_index(st)
        if nxt is None:
            break
        n = st.steps[nxt]
        if key in n.windows or (stop is not None and stop in n.repeats):
            st.pos += 1
            st.rec[nxt] = {"start": b, "end": b, "endedBy": "clock", "status": "skipped", "reps": None}
            continue
        break
    for wk, other in st.wstate.items():
        if other["open"] and (wk == key or key in st.windows[wk].ancestors):
            other["open"] = False
    _advance(st, b, effects, by_clock=True)


def _last_in_window(st: State, key: str) -> bool:
    nxt = _next_index(st)
    return nxt is None or key not in st.steps[nxt].windows


def _ignore(st: State, t: int, reason: str, effects: list, action: str = "crown"):
    st.ignored.append({"t": t, "action": action, "reason": reason})
    effects.append({"kind": "hint", "t": t, "reason": reason})


def _crown(st: State, t: int, began: int, effects: list):
    s = st.current
    if s is None:
        _ignore(st, t, "done" if st.done else "notStarted", effects)
        return
    lb = st.last_bell
    if lb is not None and began < lb <= t:
        if st.last_cut is not None:
            # Grace: the turn began before the bell that cut this part: it was done at the bell.
            r = st.rec[st.last_cut]
            r["status"] = "done"
            r["endedBy"] = "athlete"
            cut = st.steps[st.last_cut]
            if cut.id in st.asks:
                st.asks.remove(cut.id)
            st.last_cut = None
            effects.append({"kind": "grace", "t": t, "step": cut.id})
            return
        _ignore(st, t, "bell", effects)
        return
    if lb is not None and t - lb < BELL_LOCKOUT_MS:
        _ignore(st, t, "bell", effects)
        return
    clocked = _clocked_windows(st, s)
    in_window = bool(clocked) or s.merged_window is not None
    if in_window:
        refs = [x for x in (st.last_crown, lb) if x is not None]
        if refs and t - max(refs) < WINDOW_LOCKOUT_MS:
            _ignore(st, t, "lockout", effects)
            return
    elif st.last_crown is not None and t - st.last_crown < CROWN_LOCKOUT_MS:
        _ignore(st, t, "lockout", effects)
        return
    if s.kind == "rest":
        if s.auto or s.merged_window is not None or s.ratio is not None or (
                s.rest_seconds is not None and clocked):
            _ignore(st, t, "clock", effects)    # "Clock starts the next part"
            return
    elif s.seconds_target is not None:
        _ignore(st, t, "clock", effects)
        return
    st.snaps.append((t, st.clone(with_snaps=False)))
    st.last_crown = t
    idx = st.seq[st.pos]
    _finish(st, idx, t, "athlete", "done")
    if s.is_max:
        _ask(st, s)                               # "I stopped": its count is asked
        effects.append({"kind": "ask", "t": t, "step": s.id})
    _advance(st, t, effects, by_clock=False)


def _clocked_windows(st: State, s: Step) -> list:
    """The windows around a step whose clock ends work. A `late: continue` cap closes nothing
    (§4.2.5), so a part under it is "a part you end, outside any clock" (§4.2.8)."""
    return [wk for wk in s.windows if st.windows[wk].late != "continue"]


def _undo(st: State, t: int, effects: list) -> State:
    if not st.snaps:
        _ignore(st, t, "nothingToUndo", effects, "undo")
        return st
    ct, snap = st.snaps[-1]
    if st.last_bell is not None and st.last_bell >= ct:
        _ignore(st, t, "bell", effects, "undo")   # undo never crosses a bell
        return st
    if not st.done:
        idx = st.seq[st.pos]
        s = st.steps[idx]
        if st.due is not None and st.rec[idx]["start"] == ct and s.merged_window is None:
            _ignore(st, t, "clockRunning", effects, "undo")   # a bell counted from that turn runs
            return st
        for wk, ws in st.wstate.items():
            if ws["open"] and ws["start"] == ct and wk not in snap.wstate:
                _ignore(st, t, "clockRunning", effects, "undo")
                return st
    new = snap.clone(with_snaps=False)
    new.snaps = st.snaps[:-1]
    new.log = st.log
    new.ignored = st.ignored
    new.now = t
    new.cd = None
    eff = {"kind": "undo", "t": t}
    if new.current is not None:
        eff["step"] = new.current.id
    effects.append(eff)
    return new


def _reps(st: State, sid: str, value):
    s = st.step_by_id(sid)
    if s is None:
        st.ignored.append({"t": st.now, "action": "reps", "reason": "unknownStep"})
        return
    if st.cap is not None and st.cap["step"] == sid and st.rec.get(s.index, {}).get("status") != "cut":
        st.cap["reps"] = value
        if sid in st.asks:
            st.asks.remove(sid)
        return
    r = st.rec.get(s.index)
    if r is not None and r["status"] == "skipped" and s.windows:
        # "I was further": the athlete was on a later part of the window than the watch thought.
        w = s.windows[-1]
        order = st.seq
        pos_named = order.index(s.index)
        cut_pos = None
        for p in range(pos_named - 1, -1, -1):
            o = st.steps[order[p]]
            if w not in o.windows:
                break
            if st.rec.get(o.index, {}).get("status") == "cut":
                cut_pos = p
                break
        if cut_pos is not None:
            cut = st.steps[order[cut_pos]]
            st.rec[cut.index].update({"status": "done", "end": None, "relabeled": True})
            for p in range(cut_pos + 1, pos_named):
                st.rec[order[p]].update({"status": "done", "start": None, "end": None,
                                         "endedBy": "athlete", "relabeled": True})
            r.update({"status": "cut", "start": None, "end": None, "reps": value, "relabeled": True})
            if cut.id in st.asks:
                st.asks.remove(cut.id)
            return
    if r is None:
        st.ignored.append({"t": st.now, "action": "reps", "reason": "notReached"})
        return
    r["reps"] = value
    if sid in st.asks:
        st.asks.remove(sid)


def _end(st: State, t: int, effects: list):
    s = st.current
    if s is None:
        _ignore(st, t, "done", effects, "end")
        return
    idx = st.seq[st.pos]
    _finish(st, idx, t, "end", "cut" if s.kind == "part" else "done")
    st.done = True
    st.done_t = t
    st.ended_by = "end"
    st.due = None
    for ws in st.wstate.values():
        ws["open"] = False
    effects.append({"kind": "done", "t": t})


def _block_done(st: State, t: int, effects: list):
    s = st.current
    key = None
    if s is not None:
        for k in reversed(s.repeats):
            if k in st.repeats and st.repeats[k]["until"] == "athlete":
                key = k
                break
    if key is None:
        _ignore(st, t, "noBlock", effects, "blockDone")
        return
    st.repeats[key]["stopped"] = True
    idx = st.seq[st.pos]
    _finish(st, idx, t, "athlete", "skipped")
    while True:
        nxt = _next_index(st)
        if nxt is None or key not in st.steps[nxt].repeats:
            break
        st.pos += 1
        st.rec[nxt] = {"start": t, "end": t, "endedBy": "athlete", "status": "skipped", "reps": None}
    st.last_crown = t
    _advance(st, t, effects, by_clock=False)


def _countdown(st: State, t: int, effects: list):
    """3-2-1 before a bell that changes what you do, only if at least 3 s were left when it was
    first seen; a mark passed late plays only the latest one (§4.2.4, §6.2)."""
    bells = _bells(st)
    signal = None
    for b in bells:
        if not (b[2] == "window" and st.windows[b[3]].late == "continue"):
            signal = b[0]
            break
    if signal is None:
        st.cd = None
        return
    if st.cd is None or st.cd["bell"] != signal:
        st.cd = {"bell": signal, "armed": signal - t >= COUNTDOWN_MS, "next": 3}
    cd = st.cd
    if not cd["armed"]:
        return
    passed = [n for n in (3, 2, 1) if n <= cd["next"] and signal - n * 1000 <= t]
    if passed:
        n = min(passed)
        effects.append({"kind": "countdown", "n": n, "t": signal - n * 1000})
        cd["next"] = n - 1


# ---- results and score ------------------------------------------------------------------------

def facts(st: State) -> list:
    """Per-step facts (RFC §5): times in ms from the start; status done | cut | skipped |
    running | notReached."""
    out = []
    for p, idx in enumerate(st.seq):
        s = st.steps[idx]
        r = st.rec.get(idx)
        d = {"id": s.id, "kind": s.kind, "rounds": [[k, n] for k, n in s.rounds]}
        if s.auto:
            d["auto"] = True
        if s.extra:
            d["extra"] = True
        if r is None:
            d["status"] = "notReached"
        else:
            d["status"] = r["status"]
            for k in ("start", "end"):
                d[k] = None if r[k] is None else r[k] - st.t0
            d["endedBy"] = r["endedBy"]
            if r["reps"] is not None:
                d["reps"] = r["reps"]
        out.append(d)
    return out


def boundaries(st: State) -> list:
    """Actual times (ms from the start) at which the clock ended a step: for tests and the
    plan-vs-actual report."""
    out = []
    for idx in st.seq:
        r = st.rec.get(idx)
        if r and r["endedBy"] == "clock" and r["end"] is not None and r["status"] != "skipped":
            out.append(r["end"] - st.t0)
    return sorted(set(out))


def _step_reps(st: State, s: Step) -> tuple:
    """(reps, entered) a step contributes to a count score."""
    r = st.rec.get(s.index)
    if r is None or r["status"] in ("skipped", "notReached"):
        if r is not None and r["status"] == "skipped" and r.get("reps") is not None:
            return r["reps"], True
        return 0, True                             # a part never reached counts 0
    if s.is_max or r["status"] == "cut":
        if r["reps"] is None:
            return 0, False                        # not entered: shown with "?"
        return r["reps"], True
    if r["status"] == "done":
        t = s.target or {}
        return (t.get("value") or 0), True
    return 0, True


def _counted(st: State, s: Step, parts) -> bool:
    if s.kind != "part" or s.auto:
        return False
    if parts is not None:
        return s.node in parts
    return s.counts_reps


def _reps_until(st: State, parts, cap: Optional[dict]) -> tuple:
    total, complete = 0, True
    for idx in st.seq:
        s = st.steps[idx]
        if not _counted(st, s, parts):
            continue
        if cap is not None:
            r = st.rec.get(idx)
            if s.id == cap["step"]:
                n = cap.get("reps")
                if n is None and r is not None and r["status"] == "cut":
                    n = r["reps"]                  # a hard cap: the cut step's own count
                if n is None:
                    complete = False
                else:
                    total += n
                break
            if r is None:
                break
        n, ok = _step_reps(st, s)
        total += n
        complete = complete and ok
    return total, complete


def _score_repeat(st: State) -> Optional[str]:
    for key, inst in st.plan.exp.repeats.items():
        if inst.times is None:
            return key
    return next(iter(st.plan.exp.repeats), None)


def _rounds(st: State, key: str) -> list:
    """[(round, [steps])] of a repeat, in order."""
    out = {}
    for idx in st.seq:
        s = st.steps[idx]
        for k, r in s.rounds:
            if k == key:
                out.setdefault(r, []).append(s)
    return sorted(out.items())


def score(st: State) -> dict:
    """The declared score (RFC §5), derived from the per-step facts. `complete` is False while a
    count it needs is not entered (the score shows "?")."""
    sc = st.plan.score
    typ = sc.get("type", "none")
    parts = sc.get("parts")
    out = {"type": typ}
    if typ == "none":
        return out
    if typ == "time":
        if st.cap is not None:
            reps, ok = _reps_until(st, parts, st.cap)
            out.update({"capped": True, "reps": reps, "complete": ok, "text": "CAP + %d" % reps,
                        "type": sc.get("atCap", "totalReps"), "afterCapMs":
                        None if st.done_t is None else st.done_t - st.cap["t"]})
            return out
        if not st.done or st.ended_by == "end":
            out.update({"value": None, "complete": False})
            return out
        ms = st.done_t - st.t0
        if sc.get("includeRest") is False:
            for idx in st.seq:
                s, r = st.steps[idx], st.rec.get(idx)
                if s.kind == "rest" and r and r["end"] is not None:
                    ms -= r["end"] - r["start"]
        out.update({"value": ms, "complete": True, "text": _clock(ms)})
        return out
    if typ == "totalReps":
        reps, ok = _reps_until(st, parts, None)
        out.update({"value": reps, "complete": ok, "text": str(reps)})
        key = _score_repeat(st)
        if sc.get("show") == "lowestReps" and key is not None:
            per = []
            for _, steps in _rounds(st, key):
                per.append(sum(_step_reps(st, s)[0] for s in steps if _counted(st, s, parts)))
            out["perRound"] = per
            out["lowest"] = min(per) if per else None
        if sc.get("show") == "roundsReps" and key is not None:
            out["roundsReps"] = _rounds_reps(st, key, parts)
        return out
    if typ == "roundsReps":
        key = _score_repeat(st)
        rr = _rounds_reps(st, key, parts) if key else {"rounds": 0, "reps": 0, "complete": True}
        out.update(rr)
        out["text"] = "%d + %d" % (rr["rounds"], rr["reps"])
        return out
    if typ == "windowsCompleted":
        total, ok = 0, 0
        for wk, w in st.windows.items():
            work = [s for s in st.steps if wk in s.windows and not s.auto and s.kind == "part"]
            if not work or not any(s.index in st.rec for s in work):
                if wk in st.plan.windows:
                    total += 1
                continue
            total += 1
            if all(st.rec.get(s.index, {}).get("status") == "done" for s in work):
                ok += 1
        out.update({"value": ok, "of": total, "text": "%d/%d" % (ok, total)})
        return out
    if typ == "load":
        best = None
        for idx in st.seq:
            s, r = st.steps[idx], st.rec.get(idx)
            ld = (s.part or {}).get("load") or {}
            if r and r["status"] == "done" and "value" in ld:
                kg = ld["value"] * (1.0 if ld.get("unit") == "kg" else 0.45359237) * ld.get("count", 1)
                if best is None or kg > best[0]:
                    best = (kg, ld, (s.target or {}).get("value"))
        out["value"] = None if best is None else {"load": best[1], "reps": best[2]}
        return out
    if typ == "perPiece" and sc.get("metric", "time") != "time":
        out["factsOnly"] = True                   # distance / reps per piece: not yet implemented
        return out
    if typ == "perPiece":
        key = sc.get("of") or next(iter(st.plan.exp.repeats), None)
        if key not in st.plan.exp.repeats:
            key = next((k for k, i in st.plan.exp.repeats.items() if i.id == key), None)
        pieces = []
        for _, steps in _rounds(st, key) if key else []:
            work = [st.rec.get(s.index) for s in steps if s.kind == "part"]
            work = [r for r in work if r and r["start"] is not None and r["end"] is not None]
            if not work:
                continue
            ms = max(r["end"] for r in work) - min(r["start"] for r in work)
            pieces.append({"ms": ms, "cut": any(r["status"] == "cut" for r in work)})
        vals = [p["ms"] for p in pieces]
        show = sc.get("show", "avg")
        agg = None
        if vals:
            agg = {"sum": sum(vals), "avg": int(sum(vals) / len(vals) + 0.5), "best": min(vals),
                   "slowest": max(vals)}.get(show)
        out.update({"pieces": pieces, "show": show, "value": agg})
        return out
    out["factsOnly"] = True                       # an unknown preset never guesses a number
    return out


def _rounds_reps(st: State, key: str, parts) -> dict:
    rounds, reps, ok = 0, 0, True
    for _, steps in _rounds(st, key):
        work = [s for s in steps if s.kind == "part"]
        if work and all(st.rec.get(s.index, {}).get("status") == "done" for s in work):
            rounds += 1
            continue
        for s in work:
            if not _counted(st, s, parts):
                continue
            n, entered = _step_reps(st, s)
            reps += n
            ok = ok and entered
        break
    return {"rounds": rounds, "reps": reps, "complete": ok}


def _clock(ms: int) -> str:
    s = ms // 1000
    if s >= 3600:
        return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)
    return "%d:%02d" % (s // 60, s % 60)
