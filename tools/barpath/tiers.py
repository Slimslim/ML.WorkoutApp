"""Units of work in a label file, and how trustworthy each one's count is (its tier).

Shared by tools/build_dataset.py (the dataset index) and tools/movement_tracker.py (coverage), so
both count the same things. No numpy: it only reads label dicts (docs/LABELS.md).

A unit of work is one row of a dataset index:
  - workout labels: one per set when the segment has `sets`, else one per working segment
    (movement not rest / transition);
  - lifts labels: one per set.

Tier of a unit (first rule that applies):
  A  the segment has a `console` block (the machine's own numbers), or the set has `repTimes`
     and the label's notes mention "video" (rep times checked against video);
  B  the count comes from the athlete: segment `source` == "athlete", or the label is a lifts label;
  C  the segment's `source` == "motion" (read from the motion data);
  D  anything else (Crown taps only).
Split: "test" for tier A, "dev" otherwise.

Athlete: "B" when the label id contains "tester-b" (or the label says `"athlete": "tester-b"`),
else "A". Movements are folded through ALIASES (assaultBike and airBike are one movement).
"""
from __future__ import annotations

from typing import Iterator, List, Optional

NON_WORK = ("rest", "transition")

# Different names for one movement -> the name used in datasets and coverage.
ALIASES = {
    "assaultBike": "airBike",
}

TIERS = ("A", "B", "C", "D")


def canonical_movement(name: str) -> str:
    return ALIASES.get(name, name)


def athlete(label: dict) -> str:
    lid = str(label.get("id", ""))
    if "tester-b" in lid or label.get("athlete") == "tester-b":
        return "B"
    return "A"


def notes_mention_video(label: dict) -> bool:
    return any("video" in str(n).lower() for n in label.get("notes", []) or [])


def tier(label: dict, segment: Optional[dict] = None, set_: Optional[dict] = None) -> str:
    """Tier of one unit: a workout segment (with one of its sets, or none), or a lifts set
    (segment None). Rule in the module docstring."""
    if segment is not None and isinstance(segment.get("console"), dict):
        return "A"
    if set_ is not None and set_.get("repTimes") and notes_mention_video(label):
        return "A"
    if label.get("kind") == "lifts" or (segment is not None and segment.get("source") == "athlete"):
        return "B"
    if segment is not None and segment.get("source") == "motion":
        return "C"
    return "D"


def split(t: str) -> str:
    return "test" if t == "A" else "dev"


def work_units(label: dict) -> Iterator[dict]:
    """Every unit of work in a label, in order, as a dict:
    {index, movement, round, start, end, amount, unit, load_lb, tier, split, training,
     rep_times (list or None), flagged, file (lifts: the set's file; workouts: None),
     segment (the segment dict or None), set (the set dict or None)}.
    start / end are session seconds (None for a lifts set: they come from its recording)."""
    i = 0
    if label.get("kind") == "lifts":
        for x in label.get("sets", []) or []:
            t = tier(label, None, x)
            yield {
                "index": i, "movement": canonical_movement(str(x.get("lift", "unknown"))),
                "round": x.get("round"), "start": None, "end": None,
                "amount": x.get("reps"), "unit": "reps", "load_lb": x.get("loadLb"),
                "tier": t, "split": split(t), "training": bool(x.get("training", True)),
                "rep_times": x.get("repTimes") or None, "flagged": isinstance(x.get("flag"), dict),
                "file": x.get("file"), "segment": None, "set": x,
            }
            i += 1
        return
    for s in label.get("segments", []) or []:
        mv = s.get("movement")
        if mv in NON_WORK or mv is None:
            continue
        seg_training = bool(s.get("training", True))
        flagged = isinstance(s.get("flag"), dict)
        sets = s.get("sets") or [None]
        for x in sets:
            t = tier(label, s, x)
            src = x if x is not None else s
            yield {
                "index": i, "movement": canonical_movement(mv), "round": s.get("round"),
                "start": float(src["start"]), "end": float(src["end"]),
                "amount": src.get("reps"), "unit": s.get("unit"),
                "load_lb": (x or {}).get("loadLb", s.get("loadLb")),
                "tier": t, "split": split(t),
                "training": seg_training and bool((x or {}).get("training", True)),
                "rep_times": (x or {}).get("repTimes") or None, "flagged": flagged,
                "file": None, "segment": s, "set": x,
            }
            i += 1


def working_segments(label: dict) -> List[dict]:
    """Working segments of a workout label (rest and transition left out); [] for lifts."""
    if label.get("kind") == "lifts":
        return []
    return [s for s in label.get("segments", []) or [] if s.get("movement") not in NON_WORK]
