"""Engine lines in the recording CSV (docs/WORKOUT_MODEL_RFC.md §9).

The watch writes each line as '# event t=<s> <description>'; this module makes the descriptions
and reads them back. Old parsers ignore unknown names, so these sit beside today's `segment` lines:
- 'name=plan schema=2 planner=1 hash=<sha256> startEpochMs=<ms> startUptimeMs=<ms> steps=<n> bells=<n>'
  once at START, then one 'name=bell id=<id> anchor=<anchor> offsetMs=<ms>' per planned boundary;
- 'name=step step=<id> status=<s> endedBy=<who> seq=<n> [reps=<n>]' each time a step ends;
- 'name=input action=ignored input=<crown|undo|...> reason=<r> seq=<n>' for each input the engine ignored.
`seq` orders lines written at the same time (#50: event lines are not in time order in the file).
Text values (ids, anchors, inputs, reasons) are percent-encoded: every UTF-8 byte outside
[A-Za-z0-9._:-] becomes %XX, so no whitespace of any kind or comma reaches the loader's
`key=([^,\\s]+)`. The loader also turns anything float() accepts into a number, so a value that
starts like a number (a digit, '.' or '-') or spells inf / infinity / nan has its first character
encoded too: 'step=007' is written 'step=%3007' and reads back as "007". Times are integer
milliseconds from START. Swift port: WorkoutEngineCSV.swift.
"""
from __future__ import annotations

from urllib.parse import unquote

PLAN_SCHEMA = 2
_SAFE = frozenset(b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
_NUMBER_START = frozenset(b"0123456789.-")
_NUMBER_WORDS = ("inf", "infinity", "nan")


def enc(v) -> str:
    """Percent-encode a text value for a 'key=value' token (see the module notes)."""
    data = str(v).encode("utf-8")
    out = []
    for i, b in enumerate(data):
        first_numeric = i == 0 and (b in _NUMBER_START or str(v).lower() in _NUMBER_WORDS)
        out.append(chr(b) if b in _SAFE and not first_numeric else "%%%02X" % b)
    return "".join(out)


def dec(s: str) -> str:
    return unquote(s, errors="replace")


def plan_lines(plan, start_epoch_ms: int, start_uptime_ms: int) -> list:
    """The 'plan' line and one 'bell' line per planned boundary."""
    out = ["name=plan schema=%d planner=%d hash=%s startEpochMs=%d startUptimeMs=%d steps=%d bells=%d" % (
        PLAN_SCHEMA, plan.to_dict()["planner"], plan.hash, start_epoch_ms, start_uptime_ms,
        len(plan.steps), len(plan.bells))]
    for b in plan.bells:
        out.append("name=bell id=%s anchor=%s offsetMs=%d" % (enc(b["id"]), enc(b["anchor"]), b["offsetMs"]))
    return out


def _reps_text(v) -> str:
    """Reps as written: a whole number without a decimal point, other numbers as repr, anything
    else as encoded text (Swift `repsText`)."""
    if isinstance(v, bool):
        return enc(str(v).lower())
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return str(int(v)) if v.is_integer() else repr(v)
    return enc(v)


def event_lines(state) -> list:
    """[(ms from START, description)] for every step that ended and every input the engine
    ignored, in time order, numbered by `seq`."""
    t0 = state.t0 or 0
    rows = []
    order = 0
    for idx in state.seq:
        r = state.rec.get(idx)
        if r is None or r["end"] is None:
            continue
        s = state.steps[idx]
        line = "name=step step=%s status=%s endedBy=%s" % (enc(s.id), r["status"], r["endedBy"] or "none")
        rows.append((r["end"] - t0, order, line, r.get("reps")))
        order += 1
    for x in state.ignored:
        line = "name=input action=ignored input=%s reason=%s" % (enc(x["action"]), enc(x["reason"]))
        rows.append((x["t"] - t0, order, line, None))
        order += 1
    rows.sort(key=lambda r: (r[0], r[1]))
    out = []
    for seq, (t, _, line, reps) in enumerate(rows, start=1):
        line = "%s seq=%d" % (line, seq)
        if reps is not None:
            line += " reps=%s" % _reps_text(reps)
        out.append((t, line))
    return out


def _text(v) -> str:
    """A value the CSV loader turned into a float back into its text (step ids are text)."""
    if isinstance(v, float):     # written by an older encoder: best effort, never raises
        return str(int(v)) if v.is_integer() else repr(v)
    return dec(str(v))


def timeline(events: list) -> dict:
    """What the loader reads from a session's '# event' lines (load_session_csv(...).events):
    with a 'plan' line, the 'step' lines sorted by (t, seq); without one, today's 'segment' lines
    by index. {"source": "plan" | "segments", "plan": {...} or None, "items": [...]}."""
    plan = next((e for e in events if e.get("name") == "plan"), None)
    if plan is not None:
        steps = []
        for e in events:
            if e.get("name") != "step":
                continue
            item = {"t": float(e.get("t", 0.0)), "step": _text(e.get("step")),
                    "status": _text(e.get("status")), "endedBy": _text(e.get("endedBy")),
                    "seq": int(e.get("seq", 0))}
            if "reps" in e:
                item["reps"] = e["reps"]
            steps.append(item)
        steps.sort(key=lambda x: (x["t"], x["seq"]))
        return {"source": "plan", "plan": {k: (_text(v) if k == "hash" else v) for k, v in plan.items()},
                "items": steps}
    segs = [e for e in events if e.get("name") == "segment"]
    items = [{"t": float(e.get("t", 0.0)), "index": int(e["index"]) if isinstance(e.get("index"), float) else None,
              "kind": e.get("kind"), "source": e.get("source")} for e in segs]
    items.sort(key=lambda x: x["t"])
    return {"source": "segments", "plan": None, "items": items}
