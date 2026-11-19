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
The Swift port is BarPathKit's WorkoutUpgrade.swift; parity fixtures in Fixtures/workouts/upgrade.json.
Informational reasons (they don't change the label) start with "note:".
"""
from __future__ import annotations

import copy

LABELS = ("exact", "review", "reencode")
_PART_KEYS = ("kind", "movement", "name", "target", "load")




def _node(seg: dict, pid: str, team: str, notes: list) -> dict:
    """The v2 node for one old segment."""
    if seg.get("kind") == "rest":
        rest = {"id": pid}
        t = seg.get("target")
        if isinstance(t, dict) and t.get("unit") == "seconds" and isinstance(t.get("value"), (int, float)) \
                and t["value"] > 0:
            rest["seconds"] = int(t["value"])
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
        if all(c == contents[0] for c in contents):
            continue
        keys0 = set(contents[0])
        if any(set(c) != keys0 for c in contents):
            return None, None              # a patch can't remove a key: not expressible as vary
        vary[pid] = [{k: v for k, v in c.items() if k != "id"} for c in contents]
    return body, vary


def _chunks(segs: list, size: int) -> list:
    return [segs[i:i + size] for i in range(0, len(segs), size)]


def upgrade(old: dict) -> dict:
    """{"definition": the v2 definition, "label": exact | review | reencode, "reasons": [...]}."""
    segs = [s for s in (old.get("segments") or []) if isinstance(s, dict)]
    fmt = old.get("format")
    team = old.get("team", "solo")
    cap = old.get("timeCapSeconds")
    cap = int(cap) if isinstance(cap, (int, float)) and not isinstance(cap, bool) and cap > 0 else None
    r = old.get("roundSize")
    r = int(r) if isinstance(r, (int, float)) and not isinstance(r, bool) and r > 0 else None
    interval = old.get("intervalSeconds")
    interval = int(interval) if isinstance(interval, (int, float)) and not isinstance(interval, bool) \
        and interval > 0 else None
    reasons, notes = [], []
    label = "exact"

    def flag(lab: str, reason: str):
        nonlocal label
        if LABELS.index(lab) > LABELS.index(label):
            label = lab
        if reason not in reasons:
            reasons.append(reason)

    for s in segs:
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
        if cap is not None and interval is not None and cap != interval * n_windows:
            flag("review", "capNotWindows")
        score = {"type": "windowsCompleted"}
    else:
        flag("reencode", "unknownFormat")
        body = [_node(s, "s%d" % (i + 1), team, notes) for i, s in enumerate(segs)]

    out = copy.deepcopy(old)
    out["schemaVersion"] = 2
    out["structure"] = {"score": score, "body": body}
    if label == "exact" and not _steps_match(out, segs):
        flag("review", "stepsDiffer")
    return {"definition": out, "label": label, "reasons": reasons + notes}


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


def _steps_match(doc: dict, segs: list) -> bool:
    """The planned (non-automatic) steps reproduce the old segments in order: kind, movement,
    name, target and load, rests with the same seconds."""
    from . import workout_engine as we
    try:
        p = we.plan(doc)
    except we.NotRunnable:
        return False
    steps = [s for s in p.steps if not s.auto]
    if len(steps) != len(segs):
        return False
    for st, seg in zip(steps, segs):
        if seg.get("kind") == "rest":
            t = seg.get("target")
            want = int(t["value"]) if isinstance(t, dict) and t.get("unit") == "seconds" else None
            if st.kind != "rest" or st.rest_seconds != want:
                return False
            continue
        if st.kind != "part":
            return False
        part = st.part
        for k in ("kind", "movement", "name"):
            if part.get(k) != seg.get(k):
                return False
        t, pt = seg.get("target"), part.get("target")
        if (t is None) != (pt is None):
            return False
        if t is not None and (t.get("unit") != pt.get("unit") or not _same_number(t.get("value"), pt.get("value"))):
            return False
        ld, pl = seg.get("load"), part.get("load")
        if (ld is None) != (pl is None):
            return False
        if ld is not None and (ld.get("unit") != pl.get("unit") or not _same_number(ld.get("value"), pl.get("value"))
                               or not _same_number(ld.get("count", 1), pl.get("count", 1))):
            return False
    return True
