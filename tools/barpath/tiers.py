"""Units of work in a label file, and how trustworthy each one's count is (its tier).

Shared by tools/build_dataset.py (the dataset index) and tools/movement_tracker.py (coverage), so
both count the same things. No numpy: it only reads label dicts (docs/LABELS.md).

A unit of work is one row of a dataset index:
  - workout labels: one per set when the segment has `sets`, else one per working segment
    (movement not rest / transition);
  - lifts labels: one per set.

Tier of a unit (first rule that applies):
  A  the segment has a `console` block (the machine's own numbers), or the segment or the set
     says `"video": true` (its count and times were checked on a video);
  B  the count comes from the athlete: segment `source` == "athlete", or the label is a lifts label;
  C  the segment's `source` == "motion" (read from the motion data);
  D  anything else (Crown taps only).
Split: "test" for tier A, "dev" otherwise.

Athlete: the tester's letter when the label id contains "tester-<letter>" (or the label says
`"athlete": "tester-<letter>"`), else "A" (the owner). Movements are folded through ALIASES (assaultBike and airBike are one movement).
"""
from __future__ import annotations

from typing import Iterator, List, Optional

NON_WORK = ("rest", "transition")

# Different names for one movement -> the name used in datasets and coverage.
ALIASES = {
    "assaultBike": "airBike",
    "hangPowerClean": "hangPowerCleans",   # the lift id and the workout movement id
}

TIERS = ("A", "B", "C", "D")


def canonical_movement(name: str) -> str:
    return ALIASES.get(name, name)


def athlete(label: dict) -> str:
    """"A" for the owner, else the tester's letter: from `"athlete": "tester-c"` or a label id
    ending in "-tester-c" (any letter)."""
    import re
    m = re.search(r"tester-([a-z])\b", str(label.get("athlete") or label.get("id", "")))
    return m.group(1).upper() if m else "A"


def tier(label: dict, segment: Optional[dict] = None, set_: Optional[dict] = None) -> str:
    """Tier of one unit: a workout segment (with one of its sets, or none), or a lifts set
    (segment None). Rule in the module docstring."""
    if segment is not None and isinstance(segment.get("console"), dict):
        return "A"
    if (segment is not None and segment.get("video") is True) or (set_ is not None and set_.get("video") is True):
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
     segment (the segment dict or None), set (the set dict or None),
     rest_before (workout sets: seconds from the previous set's end in the same segment, else None)}.
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
                "file": x.get("file"), "segment": None, "set": x, "kind": "set",
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
        prev_end = None
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
                # rest inside the movement: from the previous set's end to this set's start
                "kind": "set",
                "rest_before": (round(float(x["start"]) - prev_end, 2)
                                if x is not None and prev_end is not None else None),
            }
            if x is not None:
                prev_end = float(x["end"])
            i += 1


MIN_REST = 1.0   # s: a shorter gap between two sets is not a rest


def rest_units(label: dict) -> Iterator[dict]:
    """The rests inside each movement: from the end of one labelled set to the start of the next
    set of the same segment (gaps of MIN_REST s or more). Inside a working segment, sets are where
    the reps happen, these gaps are rest, and the time before the first set and after the last
    (walking over, set-up, kick-up, coming down) belongs to neither and is never used. A rest's
    tier is the less certain of the two sets around it. Same dict shape as work_units, with
    kind "rest", unit "seconds" and amount = its length."""
    if label.get("kind") == "lifts":
        return
    i = 1000
    for s in label.get("segments", []) or []:
        mv = s.get("movement")
        sets = s.get("sets") or []
        if mv in NON_WORK or mv is None or len(sets) < 2:
            continue
        for a, b in zip(sets, sets[1:]):
            gap = float(b["start"]) - float(a["end"])
            if gap < MIN_REST:
                continue
            t = max(tier(label, s, a), tier(label, s, b))     # "D" is the least certain
            yield {
                "index": i, "movement": canonical_movement(mv), "round": s.get("round"),
                "start": float(a["end"]), "end": float(b["start"]),
                "amount": round(gap, 2), "unit": "seconds", "load_lb": None,
                "tier": t, "split": split(t), "training": bool(s.get("training", True)),
                "rep_times": None, "flagged": isinstance(s.get("flag"), dict),
                "file": None, "segment": s, "set": None, "kind": "rest", "rest_before": None,
            }
            i += 1


def working_segments(label: dict) -> List[dict]:
    """Working segments of a workout label (rest and transition left out); [] for lifts."""
    if label.get("kind") == "lifts":
        return []
    return [s for s in label.get("segments", []) or [] if s.get("movement") not in NON_WORK]
