#!/usr/bin/env python3
"""Corpus coverage for the workout taxonomy (docs/WORKOUT_TAXONOMY.md): runs the classifier
(tools/barpath/taxonomy.py) on every piece of `workout_drafts` and prints **aggregate stats only**:
counts per axis value, the unknown rate per axis, the top reason codes, and likely
misclassifications identified by draft id. It never prints workout text, movement names, programs
or gyms.

Read-only. Two ways to feed it:

    # 1. a JSON export (array of {"id", "definition"}), e.g. from the SQL editor:
    #    select id, definition from public.workout_drafts;
    python3 tools/taxonomy_corpus.py --export drafts.json

    # 2. straight from Postgres (needs psycopg 3 or psycopg2); the session is read-only:
    PGURL=postgres://... python3 tools/taxonomy_corpus.py --pg

Options: --markdown (default) or --json; --ids N caps the draft ids listed per check (default 20);
--ids 0 leaves the ids out. Draft ids embed program slugs, so only an `--ids 0` summary may be
committed; keep the export and the id lists outside the repo.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import taxonomy as tx  # noqa: E402

AXES = ("modality", "movements", "structure", "time_domain", "loading", "scoring")
SQL = "select id, definition from public.workout_drafts"

# The import's format -> what the taxonomy should say (checked, not trusted: a mismatch is listed).
# A loaded low-rep EMOM is strength (structure wins over the clock), so strength is accepted there.
EXPECT_STRUCTURE = {
    "emom": ("intervals", "strength"), "tabata": ("intervals",), "intervals_max_reps": ("intervals",),
    "repeat_windows_max_reps": ("intervals",), "window_buyin_max_reps": ("intervals",),
    "station_rotation": ("intervals",), "strength_sets": ("strength",), "death_by": ("ladder",),
    "quality": ("practice",), "amrap_rounds": ("amrap", "ladder"), "amrap_reps": ("amrap", "ladder"),
    "max_effort_test": ("strength", "for_time", "amrap"),
}
EXPECT_SCORING = {
    "for_time": "time", "rft": "time", "amrap_rounds": "rounds_reps", "amrap_reps": "reps",
    "strength_sets": "load", "rft_each_round_timed": "time", "death_by": "rounds_reps",
}
TIMED_FORMATS = ("emom", "tabata", "amrap_rounds", "amrap_reps", "intervals_max_reps",
                 "repeat_windows_max_reps", "cycles_continued_amrap")   # death-by ends on failure


def load_rows(args) -> list:
    if args.export:
        rows = json.loads(Path(args.export).read_text(encoding="utf-8"))
        return [(r["id"], r["definition"]) for r in rows]
    url = os.environ.get("PGURL")
    if not url:
        sys.exit("set PGURL or pass --export")
    try:
        import psycopg  # type: ignore
        conn = psycopg.connect(url)
    except ImportError:
        import psycopg2 as psycopg  # type: ignore
        conn = psycopg.connect(url)
    with conn:
        with conn.cursor() as cur:
            cur.execute("set transaction read only")
            cur.execute(SQL)
            out = []
            for rid, definition in cur.fetchall():
                out.append((rid, definition if isinstance(definition, dict) else json.loads(definition)))
    conn.close()
    return out


def pieces(definition: dict):
    """(scale index, classification) for each scale of a draft that carries one."""
    for i, scale in enumerate(definition.get("scales") or []):
        cls = scale.get("classification") if isinstance(scale, dict) else None
        if isinstance(cls, dict):
            yield i, cls


def base_format(cls: dict) -> str:
    return str(cls.get("format") or "").split("(")[0].replace("multi_part:", "").split("+")[0]


def run(rows, max_ids: int) -> dict:
    counts = {a: Counter() for a in AXES}
    confidence = {a: Counter() for a in AXES}
    unknown_reasons = {a: Counter() for a in AXES}
    checks = defaultdict(list)
    unknown_movements = 0
    total_movements = 0
    n = 0
    stations = Counter()
    for rid, definition in rows:
        for i, cls in pieces(definition):
            n += 1
            ref = "%s#%d" % (rid, i)
            w = tx.from_draft_piece(cls)
            c = tx.classify(w)
            for a in AXES:
                counts[a][c[a]["value"]] += 1
                confidence[a][c[a]["confidence"]] += 1
                if c[a]["value"] == tx.UNKNOWN:
                    for r in c[a]["reasons"] or ["(none)"]:
                        unknown_reasons[a][r.split(":")[0]] += 1
            for s in c["modality"].get("stations", []):
                stations[s] += 1
            for e in w.elements:
                total_movements += 1
                if tx.modality_of(e.movement)[0] is None:
                    unknown_movements += 1
            fmt = base_format(cls)
            want = EXPECT_STRUCTURE.get(fmt)
            if want and c["structure"]["value"] not in want + ("multi_part",):
                checks["structure_vs_format:%s->%s" % (fmt, c["structure"]["value"])].append(ref)
            want = EXPECT_SCORING.get(fmt)
            if want and c["scoring"]["value"] not in (want, tx.UNKNOWN):
                checks["scoring_vs_format:%s->%s" % (fmt, c["scoring"]["value"])].append(ref)
            if fmt in TIMED_FORMATS and c["time_domain"]["value"] != tx.NA \
                    and c["time_domain"]["reasons"][:1] not in (["clock"], ["sum_of_pieces"]):
                checks["timed_format_without_clock:%s" % fmt].append(ref)
            if c["modality"]["value"] == tx.UNKNOWN and w.elements:
                checks["all_movements_unknown"].append(ref)
    return {
        "pieces": n,
        "counts": {a: dict(counts[a].most_common()) for a in AXES},
        "unknown_rate": {a: round(counts[a][tx.UNKNOWN] / n, 3) if n else 0.0 for a in AXES},
        "confidence": {a: dict(confidence[a].most_common()) for a in AXES},
        "top_unknown_reasons": {a: dict(unknown_reasons[a].most_common(8)) for a in AXES},
        "movements": {"total": total_movements, "unknown": unknown_movements,
                      "unknown_rate": round(unknown_movements / total_movements, 3) if total_movements else 0.0},
        "hyrox_stations": dict(stations.most_common()),
        "checks": {k: {"count": len(v), "ids": v[:max_ids]}
                   for k, v in sorted(checks.items(), key=lambda kv: -len(kv[1]))},
    }


def markdown(stats: dict) -> str:
    out = ["# Taxonomy corpus coverage (aggregate only)", "",
           "Pieces classified: %d" % stats["pieces"], ""]
    for a in AXES:
        out.append("## %s (unknown %.1f%%)" % (a, 100 * stats["unknown_rate"][a]))
        out.append("")
        out.append("| value | pieces |")
        out.append("|---|---|")
        for v, k in stats["counts"][a].items():
            out.append("| %s | %d |" % (v, k))
        if stats["top_unknown_reasons"][a]:
            out.append("")
            out.append("Unknown reasons: " + ", ".join("%s %d" % kv for kv in stats["top_unknown_reasons"][a].items()))
        out.append("")
    m = stats["movements"]
    out.append("Movements: %d, unknown to the lexicon %d (%.1f%%)" % (m["total"], m["unknown"], 100 * m["unknown_rate"]))
    out.append("")
    out.append("Hyrox stations seen: " + (", ".join("%s %d" % kv for kv in stats["hyrox_stations"].items()) or "none"))
    out.append("")
    out.append("## Checks (likely misclassifications, by draft id#scale)")
    out.append("")
    out.append("| check | pieces | first ids |")
    out.append("|---|---|---|")
    for k, v in stats["checks"].items():
        out.append("| %s | %d | %s |" % (k, v["count"], " ".join(v["ids"][:5]) or "-"))
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--export", help="JSON export: [{\"id\", \"definition\"}] (%s)" % SQL)
    src.add_argument("--pg", action="store_true", help="read PGURL (read-only transaction)")
    ap.add_argument("--json", action="store_true", help="print JSON instead of markdown")
    ap.add_argument("--ids", type=int, default=20, help="draft ids listed per check")
    args = ap.parse_args(argv)
    stats = run(load_rows(args), args.ids)
    sys.stdout.write(json.dumps(stats, indent=1) + "\n" if args.json else markdown(stats))
    return 0


if __name__ == "__main__":
    sys.exit(main())
