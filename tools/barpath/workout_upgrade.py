"""Legacy (schema 1) workout definitions to the v2 structure (docs/WORKOUT_MODEL_RFC.md §7.3).

`upgrade(old)` is pure: it returns the old definition with `schemaVersion: 2` and a `structure`
added (every old key, the old flat keys included, is kept unchanged, since that is what older
builds run), plus a label and the reasons for it:
- exact: the structure runs what the old keys ran, step for step (checked here: the planned steps
  reproduce the old segment list);
- review: it runs, but differently enough that the owner checks it (listed AMRAP rounds become an
  unbounded repeat, an EMOM moves to the engine, a part has no target, ...);
- reencode: the old keys can't say what the workout is (a rest inside an interval, as Tabata 20/10
  was stored; windows stored as for-time rests, as 3-3-3-4 was stored; an unknown format).
The label is also saved on the definition as `fidelity` ("exact", or "approx" with the reasons in
`approx`; RFC §14.3 B2). The Swift port is BarPathKit's WorkoutUpgrade.swift; parity fixtures in Fixtures/workouts/upgrade.json.
Informational reasons (they don't change the label) start with "note:".

Only legacy rows are upgraded (`schemaVersion` absent, null or 1). A draft (0), a v2 row or an
unknown version comes back unchanged with the label "notLegacy": its authored structure is the
truth (RFC §14.3 A1, A4). `upgrade()` is total: any JSON value gives a result, never an exception.
"""
from __future__ import annotations

import copy
import math

from . import workout_engine as we
from .workout_structure import LOAD_UNITS, TARGET_UNITS

LABELS = ("exact", "review", "reencode")
NOT_LEGACY = "notLegacy"
UPGRADE_REASON_PREFIX = "upgrade:"   # `approx` reasons written by upgrade() (RFC §14.3 B2)
_PART_KEYS = ("kind", "movement", "name", "target", "load")
_INT_LIMIT = 9.0e18          # Swift's JSONValue.intValue: larger magnitudes don't fit an Int


def _is_number(v) -> bool:
    """A finite JSON number (not a bool; not the Infinity / NaN Python's json accepts)."""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def _pos_int(v):
    """int(v) for a finite number >= 1 that fits an Int, else None (same as Swift `positiveInt`).
    Below 1 is refused: truncated, it would be 0 (a zero round size or interval)."""
    if not _is_number(v) or v < 1 or v >= _INT_LIMIT:
        return None
    return int(v)


def _whole(v) -> bool:
    return _is_number(v) and float(v) == int(v)


def _seconds_target(seg: dict):
    """The positive whole seconds of a seconds target, else None."""
    t = seg.get("target")
    if isinstance(t, dict) and t.get("unit") == "seconds":
        return _pos_int(t.get("value"))
    return None


def _invalid(seg: dict) -> bool:
    """A field the v2 validator refuses (Swift `invalid`): kind not text; a rest's seconds not a
    number >= 1 that fits an Int; a part's movement not a non-empty text, its target unit not one
    of TARGET_UNITS or its value not a number > 0; a load value not a number, its unit not lb or
    kg, or its count not a whole number >= 1."""
    if not isinstance(seg.get("kind"), str):
        return True
    t = seg.get("target")
    if seg.get("kind") == "rest":
        return isinstance(t, dict) and t.get("unit") == "seconds" and _pos_int(t.get("value")) is None
    mv = seg.get("movement")
    if not isinstance(mv, str) or not mv:
        return True
    if isinstance(t, dict) and (t.get("unit") not in TARGET_UNITS or not _is_number(t.get("value"))
                                or t["value"] <= 0):
        return True
    ld = seg.get("load")
    if isinstance(ld, dict):
        if not _is_number(ld.get("value")) or ld.get("unit") not in LOAD_UNITS:
            return True
        if "count" in ld and not (_whole(ld["count"]) and ld["count"] >= 1):
            return True
    return False


def _node(seg: dict, pid: str, team: str, notes: list) -> dict:
    """The v2 node for one old segment."""
    if seg.get("kind") == "rest":
        rest = {"id": pid}
        secs = _seconds_target(seg)
        if secs is not None:
            rest["seconds"] = secs
        return {"rest": rest}
    part = {"id": pid}
    for k in ("kind", "movement", "name"):
        if k in seg:
            part[k] = seg[k]
    t = seg.get("target")
    if isinstance(t, dict):
        part["target"] = {"value": t.get("value"), "unit": t.get("unit")}
    ld = seg.get("load")
    if isinstance(ld, dict):
        part["load"] = {"value": ld.get("value"), "unit": ld.get("unit"), "count": ld.get("count", 1)}
    if team in ("doubles", "team"):
        part["who"] = "together" if seg.get("kind") == "run" else "shared"
        if "note:partnerSplitAssumed" not in notes:
            notes.append("note:partnerSplitAssumed")
    return {"part": part}


def _content(node: dict) -> tuple:
    kind = "rest" if "rest" in node else "part"
    return kind, node[kind]


def _rounds_body(rounds: list, team: str, notes: list, prefix: str = "p") -> tuple:
    """(body of round 1, vary) when every round has the same shape, else (None, None). Positions
    whose content differs between rounds get a `vary` list of full patches."""
    shape = [s.get("kind") == "rest" for s in rounds[0]]
    if any(len(r) != len(shape) or [s.get("kind") == "rest" for s in r] != shape for r in rounds):
        return None, None
    body, vary = [], {}
    for j in range(len(shape)):
        pid = "%s%d" % (prefix, j + 1)
        nodes = [_node(r[j], pid, team, notes) for r in rounds]
        body.append(nodes[0])
        contents = [_content(n)[1] for n in nodes]
        if all(we.canonical_json(c) == we.canonical_json(contents[0]) for c in contents):
            continue
        keys0 = set(contents[0])
        if any(set(c) != keys0 for c in contents):
            return None, None              # a patch can't remove a key: not expressible as vary
        vary[pid] = [{k: v for k, v in c.items() if k != "id"} for c in contents]
    return body, vary


def _chunks(segs: list, size: int) -> list:
    return [segs[i:i + size] for i in range(0, len(segs), size)]


def upgrade(old: dict) -> dict:
    """{"definition": the v2 definition, "label": exact | review | reencode | notLegacy,
    "reasons": [...]}."""
    if not isinstance(old, dict):
        old = {}
    sv = old.get("schemaVersion")
    if sv is not None and not (_is_number(sv) and sv == 1):
        why = "draft" if _is_number(sv) and sv == 0 else ("alreadyV2" if _is_number(sv) and sv >= 2
                                                           else "unknownSchemaVersion")
        return {"definition": copy.deepcopy(old), "label": NOT_LEGACY, "reasons": [why]}
    raw = old.get("segments")
    segs = [s for s in raw if isinstance(s, dict)] if isinstance(raw, list) else []
    fmt = old.get("format")
    team = old.get("team", "solo")
    cap = _pos_int(old.get("timeCapSeconds"))
    r = _pos_int(old.get("roundSize"))
    interval = _pos_int(old.get("intervalSeconds"))
    reasons, notes = [], []
    label = "exact"

    def flag(lab: str, reason: str):
        nonlocal label
        if LABELS.index(lab) > LABELS.index(label):
            label = lab
        if reason not in reasons:
            reasons.append(reason)

    for k in ("timeCapSeconds", "roundSize", "intervalSeconds"):
        v = old.get(k)
        if v is not None and (_pos_int(v) is None or not _whole(v)):
            flag("reencode", "invalidField")      # e.g. 0, 0.5, 600.5, -1, "x" or Infinity
    for s in segs:
        if _invalid(s):
            flag("reencode", "invalidField")
        t = s.get("target")
        if s.get("kind") == "rest" and isinstance(t, dict) and t.get("unit") == "seconds" \
                and _seconds_target(s) is not None and t.get("value") != _seconds_target(s):
            flag("review", "restSecondsRounded")
        if s.get("kind") == "rest" and isinstance(t, dict) and t.get("unit") != "seconds":
            flag("review", "restTargetDropped")        # a rest keeps only seconds
        if any(k not in _PART_KEYS for k in s) and "note:segmentKeysNotCopied" not in notes:
            notes.append("note:segmentKeysNotCopied")   # they stay in the old `segments`
        if s.get("kind") != "rest" and not isinstance(s.get("target"), dict):
            flag("review", "partWithoutTarget")
        t = s.get("target")
        if s.get("kind") != "rest" and isinstance(t, dict) and t.get("unit") == "seconds":
            flag("review", "secondsTargetPart")   # the old app let the athlete end it; the engine's clock will

    body = []
    score = {"type": "none"}
    if not segs:
        flag("reencode", "noSegments")
    elif fmt == "forTime":
        timed_rests = sum(1 for s in segs if s.get("kind") == "rest" and isinstance(s.get("target"), dict)
                          and s["target"].get("unit") == "seconds")
        if cap is not None and timed_rests >= 2:
            flag("reencode", "windowsStoredAsRests")
        body = _for_time_body(segs, r, team, notes)
        if cap is not None:
            body = [{"timed": {"id": "cap", "seconds": cap, "early": "next", "late": "continue", "body": body}}]
        score = {"type": "time", "atCap": "totalReps"} if cap is not None else {"type": "time"}
    elif fmt == "amrap" and cap is None:
        flag("reencode", "amrapWithoutCap")    # the old app ran the list and stopped: keep that
        body = [_node(s, "s%d" % (i + 1), team, notes) for i, s in enumerate(segs)]
        score = {"type": "roundsReps"}
    elif fmt == "amrap":
        flag("review", "listedRounds")
        size = r or len(segs)
        rounds = _chunks(segs, size)
        if len(rounds[-1]) != size and len(rounds) > 1:
            rounds = rounds[:-1]
            flag("review", "partialLastRound")
        rbody, vary = _rounds_body(rounds, team, notes)
        if rbody is None:
            flag("reencode", "roundsDiffer")
            rbody, vary = [_node(s, "p%d" % (i + 1), team, notes) for i, s in enumerate(rounds[0])], {}
        rep = {"id": "rp", "times": None, "listRounds": len(rounds), "body": rbody}
        if vary:
            rep["vary"] = vary
            rep["then"] = "repeatLast"
            flag("review", "listedRoundsVary")
        body = [{"timed": {"id": "amrap", "seconds": cap, "early": "next", "late": "end",
                           "body": [{"repeat": rep}]}}]
        score = {"type": "roundsReps"}
    elif fmt == "emom":
        flag("review", "movesToEngine")
        if interval is None or r is None:
            flag("reencode", "emomWithoutRounds")
        body = _emom_body(segs, interval or 60, r or len(segs), team, notes, flag)
        n_windows = len(_chunks(segs, r or len(segs)))
        if cap is not None and interval is not None and (interval * n_windows >= 2 ** 63
                                                         or cap != interval * n_windows):
            flag("review", "capNotWindows")
        score = {"type": "windowsCompleted"}
    else:
        flag("reencode", "unknownFormat")
        body = [_node(s, "s%d" % (i + 1), team, notes) for i, s in enumerate(segs)]

    out = copy.deepcopy(old)
    out["schemaVersion"] = 2
    out["structure"] = {"score": score, "body": body}
    try:
        p = we.plan(out)
    except we.NotRunnable:
        flag("reencode", "notRunnable")
        p = None
    if p is not None and label == "exact" and not _steps_match(p, segs):
        flag("review", "stepsDiffer")
    _set_fidelity(out, label, reasons)
    return {"definition": out, "label": label, "reasons": reasons + notes}


def _set_fidelity(out: dict, label: str, reasons: list):
    """The label, saved on the definition (RFC §14.3 B2, A4): `fidelity: "exact"` only when the
    structure runs what the old keys ran; otherwise `fidelity: "approx"` with the reasons in
    `approx` as "upgrade:<reason>" (notes are informational and stay out). The prefix tells the
    validator these came from the old keys, which the row keeps, not from a coach's text, so no
    `rawText` is required. Older builds run the old keys only when fidelity is exact."""
    out.pop("approx", None)
    if label == "exact":
        out["fidelity"] = "exact"
    else:
        out["fidelity"] = "approx"
        out["approx"] = [UPGRADE_REASON_PREFIX + r for r in reasons]


def _for_time_body(segs: list, r, team: str, notes: list) -> list:
    if r and len(segs) % r == 0 and len(segs) // r >= 2:
        rounds = _chunks(segs, r)
        rbody, vary = _rounds_body(rounds, team, notes)
        if rbody is not None:
            rep = {"id": "rp", "times": len(rounds), "body": rbody}
            if vary:
                rep["vary"] = vary
            return [{"repeat": rep}]
    return [_node(s, "s%d" % (i + 1), team, notes) for i, s in enumerate(segs)]


def _emom_body(segs: list, interval: int, r: int, team: str, notes: list, flag) -> list:
    """One window per old round: its work parts; the rest segment that ends an old round (no
    target) is the automatic rest. A rest with seconds inside an interval can't be said in the old
    keys' meaning (Tabata 20/10 was stored that way): re-encode."""
    windows = []
    for chunk in _chunks(segs, r):
        work = list(chunk)
        while work and work[-1].get("kind") == "rest" and not isinstance(work[-1].get("target"), dict):
            work.pop()
        if any(s.get("kind") == "rest" for s in work):
            flag("reencode", "restInsideInterval")
            work = [s for s in work if s.get("kind") != "rest"]
        windows.append(work)
    windows = [w for w in windows if w]
    if not windows:
        return []
    rbody, vary = _rounds_body(windows, team, notes)

    def timed(wbody):
        return {"timed": {"id": "w", "seconds": interval, "early": "wait", "late": "cut", "body": wbody}}
    if rbody is not None:
        rep = {"id": "rp", "times": len(windows), "body": [timed(rbody)]}
        if vary:
            rep["vary"] = vary
        return [{"repeat": rep}]
    out = []
    for k, w in enumerate(windows):
        nodes = [_node(s, "w%dp%d" % (k + 1, i + 1), team, notes) for i, s in enumerate(w)]
        out.append({"timed": {"id": "w%d" % (k + 1), "seconds": interval, "early": "wait", "late": "cut",
                              "body": nodes}})
    return out


def _same_number(a, b) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return a == b
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return float(a) == float(b)
    return a == b


def _steps_match(p, segs: list) -> bool:
    """The planned (non-automatic) steps reproduce the old segments in order: kind, movement,
    name, target and load, rests with the same seconds."""
    steps = [s for s in p.steps if not s.auto]
    if len(steps) != len(segs):
        return False
    for st, seg in zip(steps, segs):
        if seg.get("kind") == "rest":
            want = _seconds_target(seg)
            if st.kind != "rest" or st.rest_seconds != want:
                return False
            continue
        if st.kind != "part":
            return False
        part = st.part
        for k in ("kind", "movement", "name"):
            if part.get(k) != seg.get(k):
                return False
        t = seg.get("target") if isinstance(seg.get("target"), dict) else None
        pt = part.get("target")
        if (t is None) != (pt is None):
            return False
        if t is not None and (t.get("unit") != pt.get("unit") or not _same_number(t.get("value"), pt.get("value"))):
            return False
        ld = seg.get("load") if isinstance(seg.get("load"), dict) else None
        pl = part.get("load")
        if (ld is None) != (pl is None):
            return False
        if ld is not None and (ld.get("unit") != pl.get("unit") or not _same_number(ld.get("value"), pl.get("value"))
                               or not _same_number(ld.get("count", 1), pl.get("count", 1))):
            return False
    return True
