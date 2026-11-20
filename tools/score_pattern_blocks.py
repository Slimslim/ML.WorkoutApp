#!/usr/bin/env python3
"""Score barpath.pattern_blocks (movement blocks found after the workout) against the labels.

    python3 tools/score_pattern_blocks.py                 # every labelled workout with movements in order
    python3 tools/score_pattern_blocks.py <label id> ...  # others
    python3 tools/score_pattern_blocks.py -v              # every movement, one line each

The detector gets the motion, the movements in the order they were done (plan + score) and the
Crown taps as hints (--no-crown: motion only); never the label's times. Per movement it is scored on:
  start  its first rep: only where the label knows it (first labelled set, or a start found from
         motion / told by the athlete); the Crown only marks the END of a movement.
  end    its last rep (end of the last labelled set), else the Crown tap that ended it (approximate:
         the athlete may tap a few seconds after the last rep).
  time   share of the known working time (labelled sets; whole segments only where the start came
         from motion or the athlete) that the detector gives to the right movement. A segment
         known only from Crown taps also holds the walk over and the set-up, so it is left out.
The Crown's own taps are shown on the same ends for comparison.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import labels as L  # noqa: E402
from barpath import pattern_blocks as PB  # noqa: E402

TESTS = ["2026-11-05-amrap20", "2026-11-08-amrap40-run", "2026-11-09-snatch-burpee-c2b",
         "2026-11-10-situps-runs", "2026-11-14-partner-hpc-burpees",
         "2026-11-14-partner-hpc-burpees-tester-b", "2026-11-15-sunday-part1-tester-b",
         "2026-11-15-sunday-part2", "2026-11-16-row-hspu-lunges", "2026-11-04-november-challenge", "2026-11-18-barbara"]
TOL = 5.0


def truth(d: dict):
    """Working segments in order with their known start (or None) and end, and end kind."""
    out = []
    for s in d["segments"]:
        if s["movement"] in L.NON_WORK:
            continue
        sets = s.get("sets") or []
        start = sets[0]["start"] if sets else (s["start"] if s.get("source") != "crown" else None)
        end = sets[-1]["end"] if sets else s["end"]
        work = ([(x["start"], x["end"]) for x in sets] if sets else
                [(s["start"], s["end"])] if s.get("source") != "crown" else [])
        out.append({"movement": s["movement"], "round": s.get("round"), "seg": (s["start"], s["end"]), "work": work,
                    "start": start, "end": end, "end_kind": "set" if sets else "crown", "crown": s["end"]})
    return out


def score(lid: str, verbose: bool = False, cfg: PB.Config = PB.Config(), use_crown: bool = True):
    import score_labels as S
    d = L.load(L.LABELS_DIR / f"{lid}.json")
    motion, segs = S.crown_segments(d)
    hints = [s["start"] for s in segs[1:]] if use_crown else []
    tr = truth(d)
    # the order as the watch had it: planned rests included (the Crown hints are by position, and
    # the watch's splits count rests), transitions (label only) left out
    full = [s["movement"] for s in d["segments"] if s["movement"] != "transition"]
    # timed rests: the watch's timer ended them (advance source 'auto'), so their windows are exact
    wk = json.load(open(L.cache_path(d, "result")))
    auto = {e["segmentIndex"] for e in wk.get("events", []) if e.get("source") == "auto"}
    fixed = {k: (s["start"], s["end"]) for k, s in enumerate(segs)
             if s["movement"] == PB.REST and k + 1 in auto and len(segs) == len(full)}
    allb = PB.blocks(motion, full, steps=S.pedometer(d), cfg=cfg, hints=hints, fixed=fixed)
    bl = [b for b in allb if b.movement != PB.REST]
    nxt_start = {id(b): (allb[i + 1].start if i + 1 < len(allb) else None) for i, b in enumerate(allb)}
    st_err, end_err, end_set_err, crown_set_err = [], [], [], []
    for x, b in zip(tr, bl):
        if x["start"] is not None and x is not tr[0]:
            st_err.append(b.start - x["start"])
        if x is not tr[-1]:
            end_err.append(b.end - x["end"])
            if x["end_kind"] == "set":
                end_set_err.append(b.end - x["end"])
                crown_set_err.append(x["crown"] - x["end"])
        if verbose:
            s = f"{x['start']:7.1f}" if x["start"] is not None else "      ?"
            print(f"  r{x['round'] or '-'} {x['movement']:<17} start {s} found {b.start:7.1f}   "
                  f"end {x['end']:7.1f} ({x['end_kind']}) found {b.end:7.1f}   pauses {len(b.pauses)}")
    # time share: every labelled second of movement k given to block k (work or pause inside it)
    tt = np.arange(0.0, max(x["seg"][1] for x in tr), 1.0)
    lab = np.full(len(tt), -1)
    for k, x in enumerate(tr):
        # known working time only (see the module doc)
        for a0, a1 in x["work"]:
            lab[(tt >= a0) & (tt < a1)] = k
    pred = np.full(len(tt), -1)
    for k, b in enumerate(bl):
        nxt = nxt_start[id(b)] if nxt_start[id(b)] is not None else tt[-1] + 1
        pred[(tt >= b.start) & (tt < nxt)] = k
    m = lab >= 0
    share = float((pred[m] == lab[m]).mean()) if m.any() else float("nan")
    # boundaries whatever their names: block starts against known starts
    starts_any = [min((b.start for b in bl[1:]), key=lambda v: abs(v - x["start"])) - x["start"]
                  for x in tr[1:] if x["start"] is not None]
    return {"id": lid, "any": starts_any, "movements": len(tr), "starts": st_err, "ends": end_err,
            "ends_set": end_set_err, "crown_set": crown_set_err, "share": share}


def fmt(errs):
    if not errs:
        return "-"
    hit = sum(abs(e) <= TOL for e in errs)
    return f"{hit}/{len(errs)} (median {statistics.median(abs(e) for e in errs):.1f} s)"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ids", nargs="*", default=TESTS)
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--no-crown", action="store_true", help="motion only, no Crown taps as hints")
    ap.add_argument("--no-walking", action="store_true", help="transitions are standing only")
    a = ap.parse_args()
    rows = []
    for lid in a.ids:
        if a.v:
            print(lid)
        rows.append(score(lid, a.v, PB.Config(walking=not a.no_walking), use_crown=not a.no_crown))
    print(f"\n| workout | movements | starts within {TOL:g} s | ends within {TOL:g} s | "
          f"ends at a labelled last rep: blocks / Crown | known working time in the right movement | starts, any name |")
    print("|---|---:|---|---|---|---:|---|")
    for r in rows:
        print(f"| {r['id']} | {r['movements']} | {fmt(r['starts'])} | {fmt(r['ends'])} | "
              f"{fmt(r['ends_set'])} / {fmt(r['crown_set'])} | {'-' if r['share'] != r['share'] else f"{100 * r['share']:.0f}%"} | {fmt(r['any'])} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
