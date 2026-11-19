"""The watch session on the engine (docs/WORKOUT_MODEL_RFC.md §11 step 4, §4.2, §8, §14.3 E6).

Python reference for BarPathKit's WorkoutEngineSession.swift; parity fixtures in
Fixtures/workouts/session.json. Pure: no clock, no files.

- `route(raw)`: which watch path runs a definition. Only a definition that carries a v2 structure
  goes to the engine; everything else keeps the old path, unchanged. A v2 definition the engine
  refuses (a draft, a feature this build doesn't know, too large to expand) is "refused"; its old
  keys may run only when the definition says `fidelity: "exact"` (RFC §14.3 A4).
- `decode_event(raw)`: an engine event read back from a checkpoint. Total: never raises. Times are
  clamped to 0..MAX_EVENT_MS (a corrupt `t` near the integer limit must not overflow `t + ms`;
  RFC §4.2.11) and keys this build doesn't know are kept (RFC §14.4 rule 5).
- `make_checkpoint(...)` / `checkpoint_text(cp)` / `recover(cp)`: the engine's crash checkpoint.
  The file is canonical JSON (sorted keys, no spaces, 40 never 40.0), so Swift and Python write
  the same bytes and a decode followed by an encode gives the bytes back. It stores the definition,
  the compiled plan and its hash, the planner version, `requires`, the plan options and every
  event the engine judged (ticks are not stored). Recovery replays only up to `savedAtMs`.
- `project(state)`: the engine state as the old flat segment list and its start times, so the
  watch's existing workout views (and the result's splits) show an engine run unchanged.
- `latest_ask(state)`: the one reps question the done screen shows (the latest; RFC §6.4).
- `next_bell(state)`: the clock that will end what the athlete is doing now, for the timer.
- `new_lines(state, written)`: the CSV step/input lines (workout_csv) not written yet.
"""
from __future__ import annotations

import copy
import math
from typing import Optional

from . import workout_csv as wc
from . import workout_engine as we
from . import workout_structure as ws

CHECKPOINT_VERSION = 1
# 7 days in ms: far past any workout, and it fits a 32-bit Int (arm64_32 watches) with room for
# a bell offset of up to 24 h added to it.
MAX_EVENT_MS = 7 * 24 * 3600 * 1000
EVENT_KEYS = ("kind", "t", "began", "step", "value")


def _is_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


# ---- routing ------------------------------------------------------------------------------------

def carries_v2(raw) -> bool:
    """A definition with a v2 structure: a `structure` key, or a schema version other than 1.
    Today's rows (no `schemaVersion`, or 1, and no `structure`) keep the old path."""
    if not isinstance(raw, dict):
        return False
    if "structure" in raw:
        return True
    sv = raw.get("schemaVersion")
    return _is_number(sv) and sv != 1


def route(raw, engine_features=(), scale=None, standard="M", choices=None) -> dict:
    """{"route": "legacy" | "engine" | "refused", ...}. "refused" has `reason` (draft,
    updateApp, invalid, tooLarge, empty, noScale) and `missing` (unknown features). A refused
    definition marked `fidelity: "exact"` that keeps its old `segments` routes to "legacy" with
    the refusal's reason (RFC §14.3 A4: the old keys are exact)."""
    if not carries_v2(raw):
        return {"route": "legacy"}
    if "structure" in raw and not isinstance(raw["structure"], dict):
        reason, missing = "invalid", []
    else:
        reason, missing = _plan_refusal(raw, engine_features, scale, standard, choices)
        if reason is None:
            return {"route": "engine"}
    if raw.get("fidelity") == "exact" and isinstance(raw.get("segments"), list) and raw["segments"]:
        return {"route": "legacy", "reason": reason, "missing": missing}
    return {"route": "refused", "reason": reason, "missing": missing}


def _plan_refusal(raw, engine_features, scale, standard, choices) -> tuple:
    """(None, []) when the engine plans it, else (reason, missing). Swift's reader is total; the
    Python reference can raise on malformed input, which counts as "invalid" here."""
    try:
        we.plan(raw, scale=scale, standard=standard, choices=choices, engine_features=engine_features)
        return None, []
    except we.NotRunnable as e:
        return e.reason, list(e.missing)
    except KeyError:
        return "noScale", [scale]
    except (TypeError, AttributeError, ValueError):
        return "invalid", []


# ---- events ---------------------------------------------------------------------------------------

def _ms(v) -> Optional[int]:
    """A time in ms, truncated toward zero and clamped to 0..MAX_EVENT_MS; None if not a number."""
    if not _is_number(v) or not math.isfinite(v):
        return None
    if v <= 0:
        return 0
    if v >= MAX_EVENT_MS:
        return MAX_EVENT_MS
    return int(v)


def decode_event(raw) -> dict:
    """An engine event from JSON. Never raises: a missing or bad `kind` is "" (the engine ignores
    it), a missing or bad `t` is 0, a bad `began` or `step` is dropped. Unknown keys are kept."""
    if not isinstance(raw, dict):
        raw = {}
    out = {k: copy.deepcopy(v) for k, v in raw.items() if k not in EVENT_KEYS}
    out["kind"] = raw["kind"] if isinstance(raw.get("kind"), str) else ""
    t = _ms(raw.get("t"))
    out["t"] = 0 if t is None else t
    b = _ms(raw.get("began"))
    if b is not None:
        out["began"] = b
    if isinstance(raw.get("step"), str):
        out["step"] = raw["step"]
    if "value" in raw:
        out["value"] = copy.deepcopy(raw["value"])
    return out


# ---- checkpoint -----------------------------------------------------------------------------------

def options_dict(scale=None, standard="M", choices=None) -> dict:
    d = {"standard": standard, "choices": dict(choices or {})}
    if scale is not None:
        d["scale"] = scale
    return d


def make_checkpoint(definition: dict, p, state, start_epoch_ms: int, saved_at_ms: int,
                    options: Optional[dict] = None, watch: Optional[dict] = None) -> dict:
    """The checkpoint for `state` (planned from `definition` with `options`). `saved_at_ms` is
    engine time (ms from START's timebase) when it was written; `watch` holds what the watch adds
    (heart rate, pedometer, ids), carried unchanged."""
    req = definition.get("requires") if isinstance(definition, dict) else None
    return {
        "version": CHECKPOINT_VERSION,
        "definition": definition,
        "options": options if options is not None else options_dict(),
        "plan": p.to_dict(),
        "planHash": p.hash,
        "planner": we.PLANNER_VERSION,
        "requires": sorted(r for r in (req or []) if isinstance(r, str)),
        "startEpochMs": int(start_epoch_ms),
        "savedAtMs": int(saved_at_ms),
        "events": [decode_event(e) for e in state.log],
        "watch": watch if watch is not None else {},
    }


def checkpoint_text(cp: dict) -> str:
    return we.canonical_json(cp)


def recover(cp, engine_features=()) -> dict:
    """{"status": "ok", "plan": Plan, "state": State} replayed up to savedAtMs, or
    {"status": "refused", "reason": ...}: version (unknown checkpoint version), draft / updateApp /
    invalid / tooLarge / empty / noScale (the definition no longer plans), planChanged (this build
    plans it differently than the build that started it). A refused checkpoint is moved aside by
    the watch, never deleted (RFC §8)."""
    if not isinstance(cp, dict) or cp.get("version") != CHECKPOINT_VERSION or isinstance(cp.get("version"), bool):
        return {"status": "refused", "reason": "version"}
    definition = cp.get("definition")
    opts = cp.get("options") if isinstance(cp.get("options"), dict) else {}
    if not isinstance(definition, dict):
        return {"status": "refused", "reason": "invalid"}
    choices = opts.get("choices") if isinstance(opts.get("choices"), dict) else {}
    choices = {k: v for k, v in choices.items() if isinstance(v, str)}
    scale = opts.get("scale") if isinstance(opts.get("scale"), str) else None
    standard = opts.get("standard") if isinstance(opts.get("standard"), str) else "M"
    try:
        p = we.plan(definition, scale=scale, standard=standard, choices=choices,
                    engine_features=engine_features)
    except we.NotRunnable as e:
        return {"status": "refused", "reason": e.reason}
    except KeyError:
        return {"status": "refused", "reason": "noScale"}
    if p.hash != cp.get("planHash"):
        return {"status": "refused", "reason": "planChanged"}
    raw_events = cp.get("events") if isinstance(cp.get("events"), list) else []
    events = [decode_event(e) for e in raw_events]
    saved = _ms(cp.get("savedAtMs"))
    st = we.replay(p, events, until=saved)
    return {"status": "ok", "plan": p, "state": st}


# ---- what the existing watch views show -------------------------------------------------------------

def project(st) -> dict:
    """The old flat view of an engine run: `segments` (one legacy segment per step, in run order,
    rounds added past listRounds included), `starts` (ms from START of each step reached, 0 s for a
    step the clock skipped; never decreasing), `sources` ("crown" or "auto" for each start after
    the first: how the step before it ended), `finish` (ms from START, or None: not finished, or
    ended with End) and `finishSource`."""
    segs = [ws.legacy_segment(st.steps[i]) for i in st.seq]
    out = {"segments": segs, "starts": [], "sources": [], "finish": None, "finishSource": None}
    if st.t0 is None or st.pos < 0 or not st.seq:
        return out
    t0 = st.t0
    upto = min(st.pos, len(st.seq) - 1)
    last = 0
    for p in range(upto + 1):
        r = st.rec.get(st.seq[p])
        s = r.get("start") if r else None
        v = last if s is None else max(s - t0, last)
        out["starts"].append(v)
        last = v
        if p > 0:
            prev = st.rec.get(st.seq[p - 1]) or {}
            out["sources"].append("crown" if prev.get("endedBy") == "athlete" else "auto")
    if st.done and st.ended_by != "end" and st.done_t is not None:
        out["finish"] = max(st.done_t - t0, last)
        out["finishSource"] = "crown" if st.ended_by == "athlete" else "auto"
    return out


def latest_ask(st) -> Optional[str]:
    """The step whose count the done screen asks: only the latest question (an earlier one that a
    late Crown made stale is never shown); None when nothing is asked."""
    return st.asks[-1] if st.asks else None


def next_bell(st) -> Optional[dict]:
    """{"t": ms from START, "finish": bool}: the earliest clock that will end the step running now
    (its own time, or a window around it whose bell cuts or ends), or None when only the athlete
    ends it. `finish` = that bell ends the whole workout (an outermost `late: end` window), which
    the timer shows counting up, as today's AMRAP."""
    s = st.current
    if s is None or st.t0 is None:
        return None
    cands = []
    if st.due is not None:
        cands.append((st.due, False))
    keys = list(s.windows) + [k for k in (s.wait_window, s.merged_window) if k]
    for k in keys:
        w = st.windows.get(k)
        wsx = st.wstate.get(k)
        if w is None or wsx is None or not wsx.get("open") or w.late == "continue":
            continue
        cands.append((wsx["end"], w.depth == 1 and w.late == "end"))
    if not cands:
        return None
    t, fin = min(cands)
    return {"t": t - st.t0, "finish": fin}


# ---- CSV lines written as the run goes ------------------------------------------------------------

def _key(text: str) -> str:
    """A line without its ` seq=<n>` token: the same step line keeps its key when a later line
    moves its sequence number. `new_lines` pairs it with the line's time."""
    return " ".join(tok for tok in text.split(" ") if not tok.startswith("seq="))


def new_lines(st, written: dict) -> list:
    """[(ms from START, description)] of the step and ignored-input lines (workout_csv.event_lines)
    not written yet; `written` ((t, key) -> count) is updated. A step line whose reps change later
    (entered on the done screen) is written again with them: the loader keeps the last line per
    step. A late Crown that rewrites an earlier step adds its new line; nothing is ever removed."""
    out = []
    seen = {}
    for t, text in wc.event_lines(st):
        k = (t, _key(text))     # with its time: an undone end and the real one differ only in t
        seen[k] = seen.get(k, 0) + 1
        if seen[k] > written.get(k, 0):
            written[k] = seen[k]
            out.append((t, text))
    return out


# ---- the phone: what it sends to the watch (W27 PR3b) ---------------------------------------------

PHONE_V2_KEY = "workoutDefinitionV2"   # new application-context / message key (RFC §8 raw pass-through)


def phone_route(raw, engine_features=(), max_bytes=None) -> dict:
    """What the phone sends with a library row: {"send": "engine"} puts the row's v2 JSON in the
    new `workoutDefinitionV2` key (beside today's typed `workoutDefinition`, which stays), or
    {"send": "legacy", "reason": r} sends only the old keys, as today. Reasons:
    - notV2: a legacy row (it is upgraded on the phone only to store its fidelity; a Swift
      `exact` is not trusted until the validator is ported, so it never goes to the engine);
    - needsOwner: a row the Python upgrade labelled review or reencode (`approx` holds
      "upgrade:<reason>"), or whose `approx` is present but not a list: never on the engine until
      the owner signs it off (RFC §7.3);
    - textOnly: runs as a stopwatch, a screen that waits for design;
    - refused: the watch engine would refuse it (`refusal` says why);
    - tooBig: its JSON is over the watch payload budget (16 KB)."""
    if not carries_v2(raw):
        return {"send": "legacy", "reason": "notV2"}
    approx = raw.get("approx")
    if approx is not None and not isinstance(approx, list):
        return {"send": "legacy", "reason": "needsOwner"}    # malformed: not trusted (#116 review)
    if isinstance(approx, list) and any(isinstance(a, str) and a.startswith("upgrade:") for a in approx):
        return {"send": "legacy", "reason": "needsOwner"}
    if raw.get("fidelity") == "textOnly":
        return {"send": "legacy", "reason": "textOnly"}
    r = route(raw, engine_features)
    if r["route"] != "engine":
        return {"send": "legacy", "reason": "refused", "refusal": r.get("reason", "legacy")}
    limit = ws.MAX_PAYLOAD_BYTES if max_bytes is None else max_bytes
    if len(we.canonical_json(raw).encode("utf-8")) > limit:
        return {"send": "legacy", "reason": "tooBig"}
    return {"send": "engine"}


def phone_fidelity(raw) -> dict:
    """The fidelity the phone stores for a row (RFC §14.3 B2): a v2 row's own `fidelity` and
    `approx`; a legacy row is upgraded on the phone (`upgrade()`, never on the watch) and its
    label saved the same way. {"fidelity": str or None, "approx": [str], "label": str or None}."""
    from .workout_upgrade import upgrade
    if not isinstance(raw, dict):
        return {"fidelity": None, "approx": [], "label": None}
    if carries_v2(raw):
        fid = raw.get("fidelity") if isinstance(raw.get("fidelity"), str) else None
        approx = [a for a in (raw.get("approx") or []) if isinstance(a, str)] \
            if isinstance(raw.get("approx"), list) else []
        return {"fidelity": fid, "approx": approx, "label": None}
    u = upgrade(raw)
    d = u["definition"]
    return {"fidelity": d.get("fidelity"), "approx": list(d.get("approx") or []), "label": u["label"]}
