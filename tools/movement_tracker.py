#!/usr/bin/env python3
"""Label coverage per movement: how much ground truth there is, and what is still missing.

    python3 tools/movement_tracker.py [--labels data/labels] [--json out.json] [--targets run,airBike,wallBalls]

Reads the label files only (no recordings). Per movement:
  sessions, athletes          label files / athletes with at least one unit of that movement
  segments                    working segments (workout labels; rest and transition left out)
  sets, timed sets            labelled sets (segment sets and lifts sets), and those with repTimes
  A / B / C / D               units of work per tier (barpath.tiers: the same rule and units as
                              tools/build_dataset.py's index rows)
  dev / test sessions         sessions with at least one dev / test unit (test = tier A); one
                              session can count in both
For every target movement, "missing" lists what is short of TARGET: >= 10 sessions, >= 2
athletes, >= 3 sessions with a tier-A unit. Movement names go through barpath.tiers.ALIASES
(assaultBike counts as airBike). Prints a markdown table; --json writes the same data.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import labels as L  # noqa: E402
from barpath import tiers  # noqa: E402

DEFAULT_TARGETS = ("run", "airBike", "wallBalls")
TARGET = {"sessions": 10, "athletes": 2, "tier_a_sessions": 3}
TARGET_NAMES = {"sessions": "sessions", "athletes": "athletes", "tier_a_sessions": "tier-A sessions"}


def coverage(labels: Iterable[dict], targets: Iterable[str] = DEFAULT_TARGETS) -> Dict[str, dict]:
    """Per movement coverage (see the module docstring), sorted by movement name."""
    acc: Dict[str, dict] = {}

    def entry(mv: str) -> dict:
        return acc.setdefault(mv, {"sessions": set(), "athletes": set(), "segments": 0, "sets": 0,
                                   "timed_sets": 0, "tiers": {t: 0 for t in tiers.TIERS},
                                   "dev_sessions": set(), "test_sessions": set(),
                                   "tier_a_sessions": set()})

    for d in labels:
        lid = str(d.get("id"))
        who = tiers.athlete(d)
        for s in tiers.working_segments(d):
            entry(tiers.canonical_movement(s["movement"]))["segments"] += 1
        for u in tiers.work_units(d):
            e = entry(u["movement"])
            e["sessions"].add(lid)
            e["athletes"].add(who)
            if u["set"] is not None:
                e["sets"] += 1
                if u["rep_times"]:
                    e["timed_sets"] += 1
            e["tiers"][u["tier"]] += 1
            e[f"{u['split']}_sessions"].add(lid)
            if u["tier"] == "A":
                e["tier_a_sessions"].add(lid)

    targets = [tiers.canonical_movement(t) for t in targets]
    for t in targets:
        entry(t)
    out: Dict[str, dict] = {}
    for mv in sorted(acc):
        e = acc[mv]
        row = {"sessions": len(e["sessions"]), "athletes": len(e["athletes"]),
               "segments": e["segments"], "sets": e["sets"], "timed_sets": e["timed_sets"],
               "tiers": e["tiers"], "dev_sessions": len(e["dev_sessions"]),
               "test_sessions": len(e["test_sessions"]),
               "tier_a_sessions": len(e["tier_a_sessions"]), "target": mv in targets}
        if mv in targets:
            row["missing"] = [f"{TARGET_NAMES[k]} {row[k]}/{need}" for k, need in TARGET.items()
                              if row[k] < need]
        out[mv] = row
    return out


def markdown(cov: Dict[str, dict]) -> str:
    head = ["movement", "sessions", "athletes", "segments", "sets", "timed sets", "A", "B", "C", "D",
            "dev sess", "test sess", "missing (targets)"]
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    order = sorted(cov, key=lambda m: (not cov[m]["target"], m))
    for mv in order:
        r = cov[mv]
        miss = ("ok" if not r["missing"] else ", ".join(r["missing"])) if r["target"] else ""
        cells = [f"**{mv}**" if r["target"] else mv, r["sessions"], r["athletes"], r["segments"],
                 r["sets"], r["timed_sets"], *(r["tiers"][t] for t in tiers.TIERS),
                 r["dev_sessions"], r["test_sessions"], miss]
        lines.append("| " + " | ".join(str(c) for c in cells) + " |")
    return "\n".join(lines)


def load_labels(folder: Path) -> List[dict]:
    out = []
    for p in L.all_label_files(folder):
        try:
            d = L.load(p)
        except (OSError, ValueError) as e:
            print(f"skipped {p.name}: {e}", file=sys.stderr)
            continue
        d.setdefault("id", p.stem)
        out.append(d)
    return out


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--labels", type=Path, default=L.LABELS_DIR)
    ap.add_argument("--json", type=Path, help="also write the coverage as JSON here")
    ap.add_argument("--targets", default=",".join(DEFAULT_TARGETS),
                    help="comma-separated target movements (default %(default)s)")
    a = ap.parse_args(argv)
    targets = [t.strip() for t in a.targets.split(",") if t.strip()]
    cov = coverage(load_labels(a.labels), targets)
    print(markdown(cov))
    if a.json:
        a.json.write_text(json.dumps({"targets": targets, "target": TARGET, "movements": cov},
                                     indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
