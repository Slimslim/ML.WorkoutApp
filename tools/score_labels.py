#!/usr/bin/env python3
"""Score detectors against the ground-truth labels in data/labels/ (docs/LABELS.md).

    python3 tools/score_labels.py            # every label whose recordings are in data/cache/
    python3 tools/score_labels.py --tol 5    # match window in seconds (default 3)

Workout sessions, two questions:
  switches  - does the detector put a "new movement" boundary where the athlete really changed
              movement (pull-ups -> push-ups, bike -> step-ups)?
  set ends  - does it put "set done" where a set really ended (including the 9 of 9 + 6)?
Detectors:
  crown      the athlete's own Crown taps from the watch result (the untouched copy).
  onset      crown taps moved to the first rep by barpath.transitions.work_onset.
  switch-v0  barpath.switches (plan-aware, learns round 1).
  switch-v1  the same with 6 movement signals added (hang, overhead, throws, planted hand,
             rhythm, step rate). Only on labels with rounds, and only
             switches after round 1; crown and onset are also shown on that same part
             ("after round 1" rows) so the three compare like with like.
--record appends this run's scores to data/eval/history.jsonl (commit, date, every number), so
each new detector version can be compared with the previous ones (docs/LABELS.md, "Eval").
Lifting sessions: barpath.reps.count_reps against the labelled reps of each set.

Fetch the recordings first: tools/fetch_sessions.py. Labels without recordings are listed and
skipped.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import labels as L  # noqa: E402


def crown_segments(d: dict):
    """(motion, [{movement, start, end}]) from the cached CSV and watch result, session seconds."""
    from barpath.recording import load_session_csv
    csv = load_session_csv(L.cache_path(d, "csv"))
    wk = json.load(open(L.cache_path(d, "result")))
    t0 = csv.start_date.timestamp()
    segs = [{"movement": "run" if s.get("kind") == "run" else s.get("movement") or s.get("kind"),
             "start": s["start"] - t0, "end": s["end"] - t0} for s in wk["segments"]]
    return csv.motion, segs


def predicted(name: str, motion, segs):
    """(switch times, set-end times) the detector `name` reports. Its segments go through the
    same rules as the labels (labels.switches / labels.set_ends): a tap into a rest or into the
    same movement is not a switch, and the end of a rest is not a set end."""
    if name == "crown":
        guess = segs
    elif name == "onset":
        from barpath.transitions import work_onset
        guess = []
        for i, s in enumerate(segs):
            o = work_onset(s["movement"], motion, s["start"], s["end"]) if i else None
            start = s["start"] + ((o.onset or 0.0) if o else 0.0)
            guess.append(dict(s, start=min(start, s["end"])))
    else:
        raise ValueError(name)
    d = {"segments": guess}
    return [x["t"] for x in L.switches(d)], L.set_ends(d)


def fmt(m: dict) -> str:
    n = m["hits"] + m["misses"]
    err = f"median {statistics.median(abs(e) for e in m['errors']):.1f} s" if m["errors"] else "-"
    return f"{m['hits']}/{n} ({m['false']} false, {err})"


def score_workout(d: dict, tol: float, records: list) -> list:
    motion, segs = crown_segments(d)
    truth_sw = [x["t"] for x in L.switches(d)]
    truth_end = L.set_ends(d)
    rows = []

    def add(name, part, sw_m, end_m):
        rows.append((d["id"], name if part == "all" else f"{name} (after round 1)", fmt(sw_m),
                     fmt(end_m) if end_m else "-"))
        records.append({"session": d["id"], "detector": name, "part": part,
                        "switches": {k: v for k, v in sw_m.items() if k != "errors"},
                        "switchErrorMedian": median_abs(sw_m["errors"]),
                        "setEnds": None if end_m is None else {k: v for k, v in end_m.items() if k != "errors"}})

    for name in ("crown", "onset"):
        sw, ends = predicted(name, motion, segs)
        add(name, "all", L.match(truth_sw, sw, tol), L.match(truth_end, ends, tol))
    if any(s.get("round") for s in d["segments"]):
        from barpath import switches as SW
        plan, known = SW.round1(d)
        after = max(s["end"] for s in known)
        truth_after = [t for t in truth_sw if t > after]
        for name in ("crown", "onset"):
            sw, _ = predicted(name, motion, segs)
            add(name, "after-round-1", L.match(truth_after, [t for t in sw if t > after], tol), None)
        add(SW.VERSION, "after-round-1", L.match(truth_after, SW.detect(motion, plan, known), tol), None)
        steps = pedometer(d)
        add(SW.VERSION_V1, "after-round-1",
            L.match(truth_after, SW.detect(motion, plan, known, SW.Config(features="v1"), steps=steps), tol), None)
    return rows


def pedometer(d: dict):
    """(times, cumulative steps) from the CSV's '# event name=pedometer' lines, session seconds."""
    from barpath.recording import load_session_csv
    ev = [e for e in load_session_csv(L.cache_path(d, "csv")).events
          if e.get("name") == "pedometer" and "steps" in e]
    if not ev:
        return None
    return [float(e["t"]) for e in ev], [float(e["steps"]) for e in ev]


def median_abs(errors):
    return round(statistics.median(abs(e) for e in errors), 2) if errors else None


def score_lifts(d: dict) -> list:
    import numpy as np
    from barpath.reps import count_reps
    rows = []
    for x in d["sets"]:
        p = L.CACHE_DIR / d["id"] / Path(x["file"]).name
        m = json.load(open(p))["motion"]
        t = np.array(m["t"])
        ua = np.c_[m["ax"], m["ay"], m["az"]]
        g = np.c_[m["gx"], m["gy"], m["gz"]]
        n = count_reps(t, ua, g).count
        rows.append((d["id"], f"{x['lift']} {x.get('loadLb', '?')} lb", x["reps"], n, n - x["reps"]))
    return rows


def has_cache(d: dict) -> bool:
    if d["kind"] == "lifts":
        return all((L.CACHE_DIR / d["id"] / Path(x["file"]).name).exists() for x in d["sets"])
    return all(L.cache_path(d, k).exists() for k in ("csv", "result"))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tol", type=float, default=3.0, help="match window, seconds")
    ap.add_argument("--record", action="store_true", help="append the scores to data/eval/history.jsonl")
    args = ap.parse_args()
    work, lifts, missing, records = [], [], [], []
    for p in L.all_label_files():
        d = L.load(p)
        errs = L.validate(d)
        if errs:
            print(f"{p.name}: invalid label: {errs[0]}", file=sys.stderr)
            return 1
        if not has_cache(d):
            missing.append(d["id"])
        elif d["kind"] == "workout":
            work += score_workout(d, args.tol, records)
        else:
            lifts += score_lifts(d)
    if work:
        print(f"### Workouts (match window {args.tol:g} s)\n")
        print("| session | detector | switches found | set ends found |")
        print("|---|---|---|---|")
        for r in work:
            print("| " + " | ".join(str(c) for c in r) + " |")
        print()
    if lifts:
        print("### Lifting sets (barpath.reps.count_reps)\n")
        print("| session | set | labelled reps | counted | diff |")
        print("|---|---|---:|---:|---:|")
        for r in lifts:
            print("| " + " | ".join(str(c) for c in r) + " |")
            records.append({"session": r[0], "detector": "count_reps", "set": r[1], "labelled": r[2], "counted": r[3]})
        print()
    if missing:
        print("Not scored (recordings not in data/cache, run tools/fetch_sessions.py): " + ", ".join(missing))
    if args.record:
        record(records, args.tol, missing)
    return 0


def record(records: list, tol: float, missing: list) -> None:
    """One line per run in data/eval/history.jsonl: when, which commit, the match window, the
    labelled sessions that were scored (and the ones that were not), and every score."""
    import datetime
    import subprocess
    out = L.REPO / "data" / "eval" / "history.jsonl"
    out.parent.mkdir(parents=True, exist_ok=True)
    try:
        commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=L.REPO, capture_output=True,
                                text=True, check=True).stdout.strip()
        dirty = bool(subprocess.run(["git", "status", "--porcelain", "--", "tools"], cwd=L.REPO,
                                    capture_output=True, text=True).stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        commit, dirty = "unknown", True
    line = {"date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "commit": commit + ("+changes" if dirty else ""), "tol": tol,
            "sessions": sorted({r["session"] for r in records}), "notScored": missing, "scores": records}
    with open(out, "a") as f:
        f.write(json.dumps(line) + "\n")
    print(f"Recorded in {out.relative_to(L.REPO)}")


if __name__ == "__main__":
    sys.exit(main())
