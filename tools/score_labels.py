#!/usr/bin/env python3
"""Score detectors against the ground-truth labels in data/labels/ (docs/LABELS.md).

    python3 tools/score_labels.py            # every label whose recordings are in data/cache/
    python3 tools/score_labels.py --tol 5    # match window in seconds (default 3)

Workout sessions, two questions:
  switches  - does the detector put a "new movement" boundary where the athlete really changed
              movement (pull-ups -> push-ups, bike -> step-ups)?
  set ends  - does it put "set done" where a set really ended (including the 9 of 9 + 6)?
Detectors scored today (baselines, to beat):
  crown     the athlete's own Crown taps from the watch result (the untouched copy).
  onset     crown taps moved to the first rep by barpath.transitions.work_onset.
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


def score_workout(d: dict, tol: float) -> list:
    motion, segs = crown_segments(d)
    truth_sw = [x["t"] for x in L.switches(d)]
    truth_end = L.set_ends(d)
    rows = []
    for name in ("crown", "onset"):
        sw, ends = predicted(name, motion, segs)
        rows.append((d["id"], name, fmt(L.match(truth_sw, sw, tol)), fmt(L.match(truth_end, ends, tol))))
    return rows


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
    args = ap.parse_args()
    work, lifts, missing = [], [], []
    for p in L.all_label_files():
        d = L.load(p)
        errs = L.validate(d)
        if errs:
            print(f"{p.name}: invalid label: {errs[0]}", file=sys.stderr)
            return 1
        if not has_cache(d):
            missing.append(d["id"])
        elif d["kind"] == "workout":
            work += score_workout(d, args.tol)
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
        print()
    if missing:
        print("Not scored (recordings not in data/cache, run tools/fetch_sessions.py): " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    sys.exit(main())
