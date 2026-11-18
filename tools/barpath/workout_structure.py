"""Workout structure v2: schema, validator and compiler (docs/WORKOUT_MODEL_RFC.md §3, §14).

A workout definition carries an optional `structure` (a small tree of five node kinds: part, rest,
group, repeat, timed) plus a declared `score`. This module checks a definition against the rules
of RFC §3.2 / §14.3 and compiles it: `listRounds` for unbounded repeats, the root `requires` list,
and the old flat keys (`format`, `segments`, `intervalSeconds`, `roundSize`, `timeCapSeconds`) that
older builds read. The timeline engine (plan / reduce / replay) is in `workout_engine`.

Rules for unknown fields (RFC §14.4):
- descriptive fields (`note`, `label`, `name`, `tempo`, `rawText`, `x-*`, ...) never cause a
  refusal and are passed through unchanged;
- engine fields not in the frozen v2 list are features (`resume`, `interrupt`, `startAt`); the
  compiler lists them in `requires` and a reader that does not run them refuses the workout;
- the compiler never removes or rewrites a key it does not own.
"""
from __future__ import annotations

import copy
import json
import math
from typing import Optional

SCHEMA_VERSION = 2
DRAFT_SCHEMA_VERSION = 0

NODE_KINDS = ("part", "rest", "group", "repeat", "timed")
EARLY = ("wait", "next")
LATE = ("cut", "end", "continue")
WHO = ("me", "partner", "together", "shared")
TARGET_UNITS = ("reps", "calories", "meters", "seconds", "ft", "yd", "mi")
COUNT_UNITS = ("reps", "calories")
DISTANCE_METERS = {"meters": 1.0, "ft": 0.3048, "yd": 0.9144, "mi": 1609.344}
LOAD_UNITS = ("lb", "kg")
LOAD_BASIS = ("1RM", "3RM", "TM")
SCORE_TYPES = ("time", "roundsReps", "totalReps", "lowestReps", "load", "perPiece",
               "windowsCompleted", "longestHold", "maxHeight", "distance", "calories", "none")
SCORE_SHOW = ("lowestReps", "roundsReps", "sum", "avg", "best", "slowest")
PER_PIECE_METRICS = ("time", "distance", "reps")
FIDELITY = ("exact", "approx", "textOnly")
LEGACY_KINDS = ("run", "station", "transition")

# Engine fields outside the frozen v2 list: the compiler names them in `requires` (RFC §14.3 A2).
# `slots` is reserved (§14.3 C3) and has no key yet.
FEATURE_KEYS = {
    "repeat": ("resume",),
    "timed": ("startAt", "interrupt"),
    "part": ("interrupt",),
    "group": ("interrupt",),
}
KNOWN_FEATURES = ("interrupt", "resume", "slots", "startAt")

# Frozen v2 engine keys per node kind (descriptive keys are allowed anywhere, see is_descriptive).
ENGINE_KEYS = {
    "part": {"id", "kind", "movement", "target", "load", "height", "who"},
    "rest": {"id", "seconds", "ratio"},
    "group": {"id", "load", "asStep", "body"},
    "repeat": {"id", "times", "until", "then", "vary", "override", "body", "listRounds"},
    "timed": {"id", "seconds", "early", "late", "stops", "body"},
}
DESCRIPTIVE_KEYS = {"note", "label", "name", "tempo", "perSide", "sameLoad", "minReps", "swappedFrom",
                    "rpe", "rawText"}

MAX_DEPTH = 3                  # timed/repeat levels on any path
MAX_STEPS = 400                # steps in the plan (unbounded repeats at listRounds)
MAX_PAYLOAD_BYTES = 16 * 1024  # watch payload: default structure + old keys
DEFAULT_LIST_ROUNDS = 20       # unbounded repeat with no window around it (death-by, until athlete)
SECONDS_PER_PART = 10          # listRounds: enough rounds to fill the window at 10 s per part


def is_descriptive(key: str) -> bool:
    return key in DESCRIPTIVE_KEYS or key.startswith("x-")


def node_kind(wrapper) -> tuple:
    """(kind, content) of a node wrapper `{"part": {...}}`, or (None, None)."""
    if not isinstance(wrapper, dict):
        return None, None
    kinds = [k for k in wrapper if k in NODE_KINDS]
    if len(kinds) != 1 or not isinstance(wrapper[kinds[0]], dict):
        return None, None
    return kinds[0], wrapper[kinds[0]]


def iter_nodes(body, ancestors=()):
    """Yields (kind, content, ancestors, index, body) depth first; ancestors are (kind, content)."""
    if not isinstance(body, list):
        return
    for i, w in enumerate(body):
        kind, c = node_kind(w)
        yield kind, c, ancestors, i, body
        if c is not None and isinstance(c.get("body"), list):
            yield from iter_nodes(c["body"], ancestors + ((kind, c),))


def structures(doc: dict) -> list:
    """[(label, structure)] for the root structure and every scale."""
    out = []
    if isinstance(doc.get("structure"), dict):
        out.append(("structure", doc["structure"]))
    for i, s in enumerate(doc.get("scales") or []):
        if isinstance(s, dict) and isinstance(s.get("structure"), dict):
            out.append(("scales[%d]" % i, s["structure"]))
    return out


def features(doc: dict) -> list:
    """Sorted feature names used anywhere in the definition (the compiled `requires`)."""
    found = set()
    for _, st in structures(doc):
        for kind, c, _, _, _ in iter_nodes(st.get("body")):
            if c is None:
                continue
            for key in FEATURE_KEYS.get(kind, ()):
                if key in c:
                    found.add(key)
    return sorted(found)


def _is_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _is_int(v) -> bool:
    return _is_number(v) and float(v) == int(v)


def unbounded(repeat: dict) -> bool:
    return repeat.get("times") is None


# ---- validator --------------------------------------------------------------------------------

def validate(doc: dict, strict: bool = True) -> list:
    """Errors (strings) for a workout definition; [] when valid.

    strict=True is the writer's check (make_row, import, compiler output). strict=False is the
    reader's: unknown keys are tolerated (they are passed through) and only the engine rules are
    checked. Size limits (steps, payload) need the compiled document and are checked in both."""
    errs = []
    if not isinstance(doc, dict):
        return ["definition: not an object"]
    version = doc.get("schemaVersion")
    has_structure = "structure" in doc or "scales" in doc
    if has_structure and version not in (SCHEMA_VERSION, DRAFT_SCHEMA_VERSION):
        errs.append("schemaVersion: must be 2 (or 0 for a draft) when a structure is present")
    if not isinstance(doc.get("structure"), dict):
        errs.append("structure: missing")
        return errs
    team = doc.get("team", "solo")
    _validate_scales(doc, errs, strict)
    for where, st in structures(doc):
        _validate_structure(st, team, where, errs, strict)
    _validate_fidelity(doc, "", errs)
    if "requires" in doc:
        req = doc["requires"]
        if not isinstance(req, list) or not all(isinstance(r, str) for r in req):
            errs.append("requires: must be a list of feature names")
        elif strict and sorted(set(req)) != features(doc):
            errs.append("requires: %s does not match the features used %s" % (sorted(req), features(doc)))
    if errs:
        return errs
    # Size limits (RFC §3.2, §14.3 D6) on the compiled form.
    from . import workout_engine
    compiled = compile_definition(doc)
    for where, st in structures(compiled):
        n = len(workout_engine.expand(st).steps)
        if n > MAX_STEPS:
            errs.append("%s: %d steps in the plan (at most %d)" % (where, n, MAX_STEPS))
    size = payload_bytes(compiled)
    if size > MAX_PAYLOAD_BYTES:
        errs.append("payload: %d bytes for the watch (at most %d)" % (size, MAX_PAYLOAD_BYTES))
    return errs


def _validate_fidelity(holder: dict, where: str, errs: list):
    fid = holder.get("fidelity")
    if fid is None:
        return
    if fid not in FIDELITY:
        errs.append("%sfidelity: %r is not one of %s" % (where, fid, list(FIDELITY)))
        return
    approx = holder.get("approx")
    if approx is not None and (not isinstance(approx, list) or not all(isinstance(a, str) for a in approx)):
        errs.append("%sapprox: must be a list of reasons" % where)
    # The text the structure came from must be kept whenever the structure is not faithful to it;
    # "oldKeysLossy" alone (set by the compiler) is about the old keys, not the text.
    from_text = fid == "textOnly" or any(a != "oldKeysLossy" for a in (approx or [])) or (
        fid == "approx" and not approx)
    if from_text and not isinstance(holder.get("rawText"), str):
        errs.append("%srawText: required when fidelity is %r" % (where, fid))


def _validate_scales(doc: dict, errs: list, strict: bool):
    scales = doc.get("scales")
    if scales is None:
        return
    if not isinstance(scales, list) or not scales:
        errs.append("scales: must be a non-empty list")
        return
    ids = set()
    root = doc.get("structure")
    matches_root = False
    for i, s in enumerate(scales):
        w = "scales[%d]." % i
        if not isinstance(s, dict):
            errs.append(w[:-1] + ": not an object")
            continue
        sid = s.get("id")
        if not isinstance(sid, str) or not sid:
            errs.append(w + "id: required")
        elif sid in ids:
            errs.append(w + "id: duplicate %r" % sid)
        else:
            ids.add(sid)
        if not isinstance(s.get("label"), str):
            errs.append(w + "label: required")
        short = s.get("short")
        if short is not None and (not isinstance(short, str) or len(short) > 5):
            errs.append(w + "short: at most 5 characters")
        if s.get("rank") is not None and not _is_int(s.get("rank")):
            errs.append(w + "rank: must be an integer")
        if not isinstance(s.get("structure"), dict):
            errs.append(w + "structure: required")
        elif s["structure"] == root:
            matches_root = True
        _validate_fidelity(s, w, errs)
    if root is not None and not matches_root:
        errs.append("structure: must equal the default scale's structure")


def _validate_structure(st: dict, team: str, where: str, errs: list, strict: bool):
    def err(path, msg):
        errs.append("%s.%s: %s" % (where, path, msg))

    body = st.get("body")
    if not isinstance(body, list) or not body:
        err("body", "must be a non-empty list")
        return
    for key in st:
        if key not in ("score", "body") and not is_descriptive(key) and strict:
            err(key, "unknown field")
    ids = {}
    part_ids = set()
    _collect_ids(body, "body", ids, part_ids, err)
    _validate_score(st.get("score"), part_ids, err)
    _validate_body(body, "body", (), team, ids, err, strict)


def _collect_ids(body, path, ids, part_ids, err):
    for i, w in enumerate(body):
        kind, c = node_kind(w)
        if c is None:
            continue
        p = "%s[%d].%s" % (path, i, kind)
        nid = c.get("id")
        if nid is not None:
            if not isinstance(nid, str) or not nid or "." in nid:
                err(p + ".id", "must be a non-empty string without '.'")
            elif nid in ids:
                err(p + ".id", "duplicate id %r" % nid)
            else:
                ids[nid] = kind
                if kind == "part":
                    part_ids.add(nid)
        if isinstance(c.get("body"), list):
            _collect_ids(c["body"], p + ".body", ids, part_ids, err)


def _validate_score(score, part_ids, err):
    if score is None:
        err("score", "required (the score is declared, RFC §5)")
        return
    if not isinstance(score, dict):
        err("score", "must be an object")
        return
    if score.get("type") not in SCORE_TYPES:
        err("score.type", "%r is not a preset %s" % (score.get("type"), list(SCORE_TYPES)))
    for key in ("atCap", "atCut"):
        if key in score and score[key] not in SCORE_TYPES:
            err("score." + key, "%r is not a preset" % score[key])
    if "better" in score and score["better"] not in ("higher", "lower"):
        err("score.better", "must be higher or lower")
    if "show" in score and score["show"] not in SCORE_SHOW:
        err("score.show", "%r is not one of %s" % (score["show"], list(SCORE_SHOW)))
    if "metric" in score and score["metric"] not in PER_PIECE_METRICS:
        err("score.metric", "%r is not one of %s" % (score["metric"], list(PER_PIECE_METRICS)))
    if "combine" in score and score["combine"] not in ("sum", "perPiece"):
        err("score.combine", "must be sum or perPiece")
    if "includeRest" in score and not isinstance(score["includeRest"], bool):
        err("score.includeRest", "must be true or false")
    parts = score.get("parts")
    if parts is not None:
        if not isinstance(parts, list):
            err("score.parts", "must be a list of part ids")
        else:
            for p in parts:
                if p not in part_ids:
                    err("score.parts", "unknown part id %r" % p)


def _depth(ancestors) -> int:
    return sum(1 for k, _ in ancestors if k in ("repeat", "timed"))


def _ids_in(body) -> set:
    out = set()
    for kind, c, _, _, _ in iter_nodes(body):
        if c is not None and isinstance(c.get("id"), str):
            out.add(c["id"])
    return out


def _validate_body(body, path, ancestors, team, ids, err, strict):
    for i, w in enumerate(body):
        p = "%s[%d]" % (path, i)
        if not isinstance(w, dict):
            err(p, "node must be an object")
            continue
        kinds = [k for k in w if k in NODE_KINDS]
        others = [k for k in w if k not in NODE_KINDS and not is_descriptive(k)]
        if len(kinds) != 1:
            err(p, "a node has exactly one of %s (found %s)" % (list(NODE_KINDS), kinds or others))
            continue
        if others and strict:
            err(p, "unknown node keys %s" % others)
        kind = kinds[0]
        c = w[kind]
        p = p + "." + kind
        if not isinstance(c, dict):
            err(p, "must be an object")
            continue
        if strict:
            allowed = ENGINE_KEYS[kind] | set(FEATURE_KEYS.get(kind, ()))
            for key in c:
                if key not in allowed and not is_descriptive(key):
                    err(p + "." + key, "unknown field (an engine field needs a feature in requires)")
        here = ancestors + ((kind, c),)
        if kind in ("repeat", "timed") and _depth(here) > MAX_DEPTH:
            err(p, "nesting deeper than %d timed/repeat levels" % MAX_DEPTH)
        if kind == "part":
            _validate_part(c, p, team, err)
        elif kind == "rest":
            _validate_rest(c, p, i, err)
        elif kind == "group":
            if "asStep" in c and not isinstance(c["asStep"], bool):
                err(p + ".asStep", "must be true or false")
            if "load" in c:
                _validate_load(c["load"], p + ".load", err)
        elif kind == "repeat":
            _validate_repeat(c, p, i, body, ancestors, ids, err)
        elif kind == "timed":
            _validate_timed(c, p, ancestors, err)
        if kind in ("group", "repeat", "timed"):
            b = c.get("body")
            if not isinstance(b, list) or not b:
                err(p + ".body", "must be a non-empty list")
            else:
                _validate_body(b, p + ".body", here, team, ids, err, strict)


def _validate_part(c, p, team, err):
    if not isinstance(c.get("id"), str):
        err(p + ".id", "required on every part")
    mv = c.get("movement")
    if isinstance(mv, dict):
        choice = mv.get("choice")
        if not (choice == "anyCardio" or (isinstance(choice, list) and choice
                                          and all(isinstance(m, str) for m in choice))):
            err(p + ".movement.choice", "must be a list of movements or \"anyCardio\"")
    elif not isinstance(mv, str) or not mv:
        err(p + ".movement", "required")
    if "kind" in c and not isinstance(c["kind"], str):
        err(p + ".kind", "must be a string")
    t = c.get("target")
    if t is not None:
        if not isinstance(t, dict):
            err(p + ".target", "must be an object")
        else:
            if t.get("unit") not in TARGET_UNITS:
                err(p + ".target.unit", "%r is not one of %s" % (t.get("unit"), list(TARGET_UNITS)))
            if "max" in t:
                if t["max"] is not True:
                    err(p + ".target.max", "must be true")
                if "value" in t:
                    err(p + ".target", "max and value are exclusive")
                if t.get("unit") == "seconds":
                    err(p + ".target", "a max part counts reps, calories or distance, not seconds")
            elif not (_is_number(t.get("value")) and t["value"] > 0):
                err(p + ".target.value", "must be a positive number (or max: true)")
            if "valueF" in t and not (_is_number(t["valueF"]) and t["valueF"] > 0):
                err(p + ".target.valueF", "must be a positive number")
            each = t.get("each")
            if each is not None:
                if t.get("unit") != "reps":
                    err(p + ".target.each", "distance per rep needs unit reps")
                if not (isinstance(each, dict) and _is_number(each.get("value"))
                        and each.get("unit") in DISTANCE_METERS):
                    err(p + ".target.each", "must be {value, unit: meters|ft|yd|mi}")
    if "load" in c:
        _validate_load(c["load"], p + ".load", err)
    h = c.get("height")
    if h is not None and not (isinstance(h, dict) and _is_number(h.get("value"))
                              and h.get("unit") in ("in", "cm")):
        err(p + ".height", "must be {value, unit: in|cm}")
    who = c.get("who")
    if who is not None and who not in WHO:
        err(p + ".who", "%r is not one of %s" % (who, list(WHO)))
    if team in ("doubles", "team") and who is None:
        err(p + ".who", "required on every part of a team workout (no silent default)")


def _validate_load(ld, p, err):
    if not isinstance(ld, dict):
        err(p, "must be an object")
    elif "percent" in ld:
        if not (_is_number(ld["percent"]) and 0 < ld["percent"] <= 200):
            err(p + ".percent", "must be a number in (0, 200]")
        if "basis" in ld and ld["basis"] not in LOAD_BASIS:
            err(p + ".basis", "must be one of %s" % list(LOAD_BASIS))
    else:
        if not _is_number(ld.get("value")):
            err(p + ".value", "required (or percent)")
        if ld.get("unit") not in LOAD_UNITS:
            err(p + ".unit", "must be lb or kg")
        if "count" in ld and not (_is_int(ld["count"]) and ld["count"] >= 1):
            err(p + ".count", "must be a positive integer")


def _validate_rest(c, p, index, err):
    has_s, has_r = "seconds" in c, "ratio" in c
    if has_s and has_r:
        err(p, "seconds and ratio are exclusive")
    if has_s and not (_is_int(c["seconds"]) and c["seconds"] > 0):
        err(p + ".seconds", "must be a positive whole number")
    if has_r:
        if not (_is_number(c["ratio"]) and c["ratio"] > 0):
            err(p + ".ratio", "must be a positive number")
        if index == 0:
            err(p + ".ratio", "a ratio rest needs a node before it to measure")


def _validate_repeat(c, p, index, body, ancestors, ids, err):
    times = c.get("times")
    if times is not None and not (_is_int(times) and times >= 1):
        err(p + ".times", "must be a positive integer or null")
    if "until" in c and c["until"] != "athlete":
        err(p + ".until", "must be \"athlete\"")
    inner = _ids_in(c.get("body") or [])
    if times is None:
        parent = ancestors[-1] if ancestors else (None, None)
        child_end = any(node_kind(w)[0] == "timed" and node_kind(w)[1].get("late") == "end"
                        for w in (c.get("body") or []))
        parent_end = parent[0] == "timed" and parent[1].get("late") == "end"
        if not (c.get("until") == "athlete" or child_end or parent_end):
            err(p, "a repeat with no count needs a timed with late: end directly around or inside "
                   "it, or until: athlete")
        if parent[0] == "timed" and index != len(body) - 1:
            err(p, "a repeat with no count must be the last thing in its window")
        if any(k == "repeat" and unbounded(a) for k, a in ancestors):
            err(p, "a repeat with no count inside another one")
        if "then" in c and c["then"] not in ("repeatLast", "stop"):
            err(p + ".then", "must be repeatLast or stop")
    elif "then" in c:
        err(p + ".then", "only on a repeat with no count")
    vary = c.get("vary")
    if vary is not None:
        if not isinstance(vary, dict):
            err(p + ".vary", "must be an object keyed by id")
        else:
            for vid, spec in vary.items():
                vp = "%s.vary.%s" % (p, vid)
                if vid not in inner:
                    err(vp, "names no node inside this repeat")
                if isinstance(spec, list):
                    if not spec:
                        err(vp, "empty list")
                    if times is not None and len(spec) != times:
                        err(vp, "%d values for %d rounds" % (len(spec), times))
                    if times is None and c.get("then") not in ("repeatLast", "stop"):
                        err(vp, "a list on a repeat with no count needs then: repeatLast | stop")
                    for v in spec:
                        if not (_is_number(v) or isinstance(v, dict)):
                            err(vp, "values are numbers or patches")
                elif isinstance(spec, dict):
                    if not (_is_number(spec.get("from")) and _is_number(spec.get("step"))):
                        err(vp, "a progression is {from, step}")
                else:
                    err(vp, "must be a list or {from, step}")
    ov = c.get("override")
    if ov is not None:
        if not isinstance(ov, list):
            err(p + ".override", "must be a list")
        else:
            for j, o in enumerate(ov):
                op = "%s.override[%d]" % (p, j)
                if not isinstance(o, dict):
                    err(op, "must be an object")
                    continue
                if o.get("id") not in inner:
                    err(op + ".id", "names no node inside this repeat")
                rounds = o.get("rounds")
                if not isinstance(rounds, list) or not rounds:
                    err(op + ".rounds", "must be a non-empty list")
                else:
                    for r in rounds:
                        if r == "last":
                            if times is None:
                                err(op + ".rounds", "\"last\" on a repeat with no count")
                        elif not (_is_int(r) and r >= 1 and (times is None or r <= times)):
                            err(op + ".rounds", "%r is not a round of this repeat" % (r,))
                if ("set" in o) == bool(o.get("omit")):
                    err(op, "needs exactly one of set or omit: true")
                if "set" in o and not (_is_number(o["set"]) or isinstance(o["set"], dict)):
                    err(op + ".set", "must be a number or a patch")


def _validate_timed(c, p, ancestors, err):
    if not (_is_int(c.get("seconds")) and c["seconds"] > 0):
        err(p + ".seconds", "must be a positive whole number")
    if c.get("early") not in EARLY:
        err(p + ".early", "must be one of %s" % list(EARLY))
    if c.get("late") not in LATE:
        err(p + ".late", "must be one of %s" % list(LATE))
    if c.get("late") == "end":
        candidates = [node_kind(w)[1].get("id") for w in (c.get("body") or [])
                      if node_kind(w)[0] == "repeat" and unbounded(node_kind(w)[1])]
        parent = ancestors[-1] if ancestors else (None, None)
        if parent[0] == "repeat":
            if unbounded(parent[1]):
                candidates.append(parent[1].get("id"))
            elif not candidates:
                err(p + ".late", "late: end under a counted repeat stops nothing; use cut")
        stops = c.get("stops")
        if len(candidates) > 1 and stops is None:
            err(p + ".stops", "two repeats could stop here; name one")
        if stops is not None and stops not in candidates:
            err(p + ".stops", "%r is not an unbounded repeat directly inside or around this window"
                % (stops,))
    elif "stops" in c:
        err(p + ".stops", "only with late: end")


# ---- compiler ---------------------------------------------------------------------------------

def compile_definition(doc: dict) -> dict:
    """A compiled copy of `doc`: listRounds filled in, `requires` computed, the old flat keys
    generated from the default (root) structure, and `fidelity` lowered to approx (reason
    `oldKeysLossy`) when the old keys cannot run the structure exactly (RFC §3.2, §14.3 A4, D6).
    Every other key is passed through unchanged. Idempotent."""
    out = copy.deepcopy(doc)
    for _, st in structures(out):
        _fill_list_rounds(st)
    req = features(out)
    if req or "requires" in out:
        out["requires"] = req
    _write_legacy(out)
    # Cap listRounds so the watch payload fits (RFC §14.3 D6).
    for _ in range(40):
        if payload_bytes(out) <= MAX_PAYLOAD_BYTES:
            break
        if not _shrink_list_rounds(out):
            break
        _write_legacy(out)
    return out


def payload_bytes(doc: dict) -> int:
    """Bytes the watch receives for the default scale: its structure plus the old keys
    (rawText and the other scales stay on the phone, RFC §14.3 B1)."""
    keep = {k: doc[k] for k in ("schemaVersion", "id", "name", "team", "format", "segments",
                                "intervalSeconds", "roundSize", "timeCapSeconds", "requires",
                                "structure") if k in doc}
    return len(json.dumps(keep, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))


def _parts_per_round(body) -> int:
    return max(1, sum(1 for k, _, _, _, _ in iter_nodes(body) if k == "part"))


def _fill_list_rounds(st: dict):
    for kind, c, ancestors, _, _ in iter_nodes(st.get("body")):
        if kind != "repeat" or not unbounded(c):
            continue
        window = next((a for k, a in reversed(ancestors) if k == "timed"), None)
        if window is not None and _is_int(window.get("seconds")):
            n = math.ceil(window["seconds"] / (SECONDS_PER_PART * _parts_per_round(c.get("body"))))
        else:
            n = DEFAULT_LIST_ROUNDS
        vary = c.get("vary") or {}
        if c.get("then") == "stop":
            lists = [len(v) for v in vary.values() if isinstance(v, list)]
            if lists:
                n = min(n, min(lists))
        c["listRounds"] = max(1, int(n))


def _shrink_list_rounds(doc: dict) -> bool:
    changed = False
    for _, st in structures(doc):
        for kind, c, _, _, _ in iter_nodes(st.get("body")):
            if kind == "repeat" and unbounded(c) and c.get("listRounds", 1) > 1:
                c["listRounds"] = max(1, int(c["listRounds"] * 0.8))
                changed = True
    return changed


def _legacy_target(part: dict) -> Optional[dict]:
    t = part.get("target")
    if not t or t.get("max") or "value" not in t:
        return None
    unit = t["unit"]
    if unit in DISTANCE_METERS:
        return {"value": round(t["value"] * DISTANCE_METERS[unit], 1) if unit != "meters" else t["value"],
                "unit": "meters"}
    return {"value": t["value"], "unit": unit}


def legacy_segment(step) -> dict:
    """One old flat segment for a plan step (engine Step)."""
    if step.kind == "rest":
        seg = {"kind": "rest", "movement": "rest", "name": "Rest"}
        if step.rest_seconds is not None and not step.auto:
            seg["target"] = {"value": step.rest_seconds, "unit": "seconds"}
        return seg
    part = step.part
    from .workout import Movement
    mv = part.get("movement")
    movement = mv if isinstance(mv, str) else "part"
    kind = part.get("kind", "station")
    seg = {"kind": kind if kind in LEGACY_KINDS else "station", "movement": movement,
           "name": part.get("name") or Movement.display_name(movement)}
    t = _legacy_target(part)
    if t is not None:
        seg["target"] = t
    ld = part.get("load")
    if isinstance(ld, dict) and "value" in ld:
        seg["load"] = {"value": ld["value"], "unit": ld["unit"], "count": ld.get("count", 1)}
    return seg


def _simple(body, allow_rest: bool = True) -> bool:
    """True if the old for-time engine runs these nodes exactly: athlete-ended parts with a
    value target (or none), counted repeats, plain groups, rests on seconds or as needed."""
    for kind, c, _, _, _ in iter_nodes(body):
        if kind is None or kind == "timed":
            return False
        if kind == "part":
            t = c.get("target") or {}
            if t.get("max") or t.get("unit") == "seconds" or not isinstance(c.get("movement"), str):
                return False
        if kind == "rest" and (not allow_rest or "ratio" in c):
            return False
        if kind == "group" and c.get("asStep"):
            return False
        if kind == "repeat" and (unbounded(c) or "until" in c):
            return False
    return True


def legacy_keys(st: dict) -> tuple:
    """(old keys, exact, reasons) for a structure (listRounds already filled)."""
    from . import workout_engine
    exp = workout_engine.expand(st)
    body = st["body"]
    top = node_kind(body[0]) if len(body) == 1 else (None, None)
    keys = {"format": "forTime"}
    exact = False
    timed_any = any(k == "timed" for k, _, _, _, _ in iter_nodes(body))
    work_steps = [s for s in exp.steps if not s.auto]
    round_size = None
    first_repeat = next(((k, c) for k, c, a, _, _ in iter_nodes(body) if k == "repeat"), None)
    if not timed_any:
        exact = _simple(body)
    elif top[0] == "timed" and top[1].get("early") == "next" and top[1].get("late") == "continue":
        keys["timeCapSeconds"] = top[1]["seconds"]
        exact = _simple(top[1]["body"])
    elif (top[0] == "timed" and top[1].get("late") == "end" and len(top[1]["body"]) == 1
          and node_kind(top[1]["body"][0])[0] == "repeat" and unbounded(node_kind(top[1]["body"][0])[1])):
        keys["format"] = "amrap"
        keys["timeCapSeconds"] = top[1]["seconds"]
        inner = node_kind(top[1]["body"][0])[1]
        exact = top[1].get("early") == "next" and _simple(inner["body"]) and "until" not in inner
    else:
        windows = list(exp.windows.values())
        all_windows = all(k != "rest" for k, _, _, _, _ in iter_nodes(body)) and windows and all(
            w.early == "wait" and w.late == "cut" and w.depth == 1 for w in windows)
        if all_windows:
            keys["format"] = "emom"
            secs = {w.seconds_ms for w in windows}
            counts = {sum(1 for s in work_steps if w.key in s.windows) for w in windows}
            parts_ok = all(_simple(c["body"], allow_rest=False)
                           for k, c, _, _, _ in iter_nodes(body) if k == "timed")
            shape_ok = all(node_kind(w)[0] == "timed" or (
                node_kind(w)[0] == "repeat" and not unbounded(node_kind(w)[1])
                and all(node_kind(x)[0] == "timed" for x in node_kind(w)[1]["body"])) for w in body)
            if len(secs) == 1 and len(counts) == 1 and parts_ok and shape_ok:
                interval = secs.pop() // 1000
                keys["intervalSeconds"] = interval
                keys["timeCapSeconds"] = interval * len(windows)
                round_size = counts.pop() + 1
                exact = True
        else:
            keys["format"] = "amrap" if top[0] == "timed" and top[1].get("late") == "end" else (
                "emom" if any(w.early == "wait" for w in exp.windows.values()) else "forTime")
            if top[0] == "timed":
                keys["timeCapSeconds"] = top[1]["seconds"]
    # Old flat list: parts and explicit rests; in an exact EMOM each automatic rest becomes the
    # rest segment that ends the old round (the old clock moves it on at the interval).
    segments = []
    for s in exp.steps:
        if s.auto:
            if keys["format"] == "emom" and exact:
                segments.append({"kind": "rest", "movement": "rest", "name": "Rest"})
            continue
        segments.append(legacy_segment(s))
    if keys["format"] == "emom" and exact and segments and segments[-1]["kind"] == "rest":
        segments.pop()
    keys["segments"] = segments
    if round_size is None and first_repeat is not None:
        rid = exp.node_id(first_repeat[1])
        n = sum(1 for s in exp.steps if not s.auto and (rid, 1) in s.rounds)
        if n:
            round_size = n
    if round_size is not None:
        keys["roundSize"] = round_size
    reasons = [] if exact else ["oldKeysLossy"]
    return keys, exact, reasons


def _write_legacy(out: dict):
    st = out.get("structure")
    if not isinstance(st, dict):
        return
    keys, exact, reasons = legacy_keys(st)
    for k in ("intervalSeconds", "roundSize", "timeCapSeconds"):
        out.pop(k, None)
    out.update(keys)
    if not exact:
        fid = out.get("fidelity", "exact")
        if fid == "exact":
            out["fidelity"] = "approx"
        if out["fidelity"] == "approx":
            approx = list(out.get("approx") or [])
            for r in reasons:
                if r not in approx:
                    approx.append(r)
            out["approx"] = approx


def check_runnable(doc: dict, engine_features=()) -> tuple:
    """("ok", []) if this engine may run the definition; otherwise ("draft", []) for a draft, or
    ("updateApp", [missing features]) - the watch shows "Update the app" with "Run as stopwatch"
    (RFC §14.3 A2, A4)."""
    version = doc.get("schemaVersion")
    if version == DRAFT_SCHEMA_VERSION:
        return "draft", []
    if version != SCHEMA_VERSION:
        return "updateApp", ["schemaVersion %r" % (version,)]
    missing = [f for f in (doc.get("requires") or []) if f not in engine_features]
    if missing:
        return "updateApp", missing
    return "ok", []


def stopwatch_structure(doc: dict) -> dict:
    """The "Run as stopwatch" fallback (RFC §14.3 A4): athlete-paced, one part per line of the raw
    text, a `late: continue` cap if one is known, no automatic rests, score typed by hand."""
    text = doc.get("rawText")
    if not isinstance(text, str):
        for s in doc.get("scales") or []:
            if isinstance(s, dict) and isinstance(s.get("rawText"), str):
                text = s["rawText"]
                break
    lines = [ln.strip() for ln in (text or "").splitlines() if ln.strip()] or [doc.get("name") or "Workout"]
    parts = [{"part": {"id": "l%d" % (i + 1), "movement": "part", "name": ln}} for i, ln in enumerate(lines)]
    cap = doc.get("timeCapSeconds")
    body = parts
    if _is_int(cap) and cap > 0:
        body = [{"timed": {"id": "cap", "seconds": int(cap), "early": "next", "late": "continue",
                           "body": parts}}]
    return {"score": {"type": "none"}, "body": body}
