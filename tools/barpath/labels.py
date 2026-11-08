"""Ground-truth labels for recorded sessions (docs/LABELS.md).

A label file (data/labels/<id>.json) says what the athlete really did in one recording: each
movement with its real start and end (session seconds, i.e. the watch CSV's `t`), reps, load,
sets inside a station (15 wall balls as 9 + 6), and for lifting sessions the reps of each set.
The recordings themselves stay in the owner's Supabase Storage folder (tools/fetch_sessions.py
downloads them into data/cache/, which git ignores).

This module only reads, checks and scores labels; it has no numpy dependency so the label files
can be checked in CI without the recordings.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Iterable, List, Optional, Sequence

LABEL_VERSION = 1
KINDS = ("workout", "lifts")
SOURCES = ("crown", "motion", "athlete")
UNITS = ("reps", "calories", "meters", "seconds")
NON_WORK = ("rest", "transition")

REPO = Path(__file__).resolve().parents[2]
LABELS_DIR = REPO / "data" / "labels"
CACHE_DIR = REPO / "data" / "cache"


def load(path) -> dict:
    with open(path) as f:
        return json.load(f)


def all_label_files(folder: Path = LABELS_DIR) -> List[Path]:
    return sorted(Path(folder).glob("*.json"))


def validate(d: dict) -> List[str]:
    """Problems with a label file; empty when it is well formed."""
    errs: List[str] = []

    def need(key, typ, where=d, ctx="file"):
        if key not in where:
            errs.append(f"{ctx}: missing '{key}'")
            return None
        if not isinstance(where[key], typ):
            errs.append(f"{ctx}: '{key}' should be {typ}")
            return None
        return where[key]

    if d.get("version") != LABEL_VERSION:
        errs.append(f"file: version must be {LABEL_VERSION}")
    need("id", str)
    need("date", str)
    need("name", str)
    kind = need("kind", str)
    files = need("files", dict)
    if kind not in KINDS:
        errs.append(f"file: kind must be one of {KINDS}")
        return errs
    if kind == "workout":
        if files is not None:
            for k in ("csv", "result"):
                if not isinstance(files.get(k), str):
                    errs.append(f"files: missing '{k}'")
        segs = need("segments", list) or []
        prev_end = None
        for i, s in enumerate(segs):
            ctx = f"segment {i}"
            mv = need("movement", str, s, ctx)
            st = need("start", (int, float), s, ctx)
            en = need("end", (int, float), s, ctx)
            src = need("source", str, s, ctx)
            if src is not None and src not in SOURCES:
                errs.append(f"{ctx}: source must be one of {SOURCES}")
            if st is None or en is None:
                continue
            if not en > st:
                errs.append(f"{ctx}: end must be after start")
            if prev_end is not None and st < prev_end - 0.05:
                errs.append(f"{ctx}: starts before the previous segment ends")
            prev_end = en
            if "unit" in s and s["unit"] not in UNITS:
                errs.append(f"{ctx}: unit must be one of {UNITS}")
            if mv in NON_WORK and s.get("reps"):
                errs.append(f"{ctx}: {mv} has reps")
            for j, x in enumerate(s.get("sets", [])):
                c2 = f"{ctx} set {j}"
                a = need("start", (int, float), x, c2)
                b = need("end", (int, float), x, c2)
                need("reps", int, x, c2)
                if a is not None and b is not None and not (st - 0.05 <= a < b <= en + 0.05):
                    errs.append(f"{c2}: must lie inside the segment and end after it starts")
                rt = x.get("repTimes")
                if rt is not None:
                    if not isinstance(rt, list) or len(rt) != x.get("reps"):
                        errs.append(f"{c2}: repTimes must have one time per rep")
                    elif a is not None and b is not None and (
                            any(q <= p for p, q in zip(rt, rt[1:])) or rt[0] < a - 0.05 or rt[-1] > b + 0.05):
                        errs.append(f"{c2}: repTimes must increase and lie inside the set")
            if s.get("sets") and isinstance(s.get("reps"), int):
                total = sum(x.get("reps", 0) for x in s["sets"])
                if total != s["reps"]:
                    errs.append(f"{ctx}: sets add up to {total}, segment says {s['reps']}")
    else:
        sets = need("sets", list) or []
        for i, x in enumerate(sets):
            ctx = f"set {i}"
            need("file", str, x, ctx)
            need("lift", str, x, ctx)
            if not isinstance(x.get("reps"), int):
                errs.append(f"{ctx}: missing 'reps' (int)")
            if "loadLb" in x and not isinstance(x["loadLb"], (int, float)):
                errs.append(f"{ctx}: 'loadLb' should be a number")
    return errs


# ---- what a detector is scored on ---------------------------------------------------------------

def switches(d: dict, unverified: bool = False) -> List[dict]:
    """Real changes of movement: {t, from, to} at the start of every working segment whose
    movement differs from the previous working one (rest and transition in between are skipped,
    so wall balls -> rest -> run is one switch, at the run's start). When the segment has labelled
    sets, the switch is the first set's start: the first rep, not the Crown tap before the walk
    to the ball.

    The Crown marks the END of a movement; the next start is only known from motion, the athlete
    or a mark. A switch whose start is only a Crown tap (`source: crown` and no sets) is not truth:
    it is left out, or returned alone with unverified=True (to report how many are missing)."""
    out: List[dict] = []
    prev: Optional[str] = None
    for s in d.get("segments", []):
        mv = s["movement"]
        if mv in NON_WORK:
            continue
        if prev is not None and mv != prev:
            known = bool(s.get("sets")) or s.get("source") != "crown"
            if known != unverified:
                t = s["sets"][0]["start"] if s.get("sets") else s["start"]
                out.append({"t": float(t), "from": prev, "to": mv})
        prev = mv
    return out


def unknown_windows(d: dict) -> List[tuple]:
    """Where a switch prediction can be neither right nor wrong: the first half of every working
    segment whose start is only a Crown tap (the real start is somewhere after the tap)."""
    out: List[tuple] = []
    prev: Optional[str] = None
    for s in d.get("segments", []):
        mv = s["movement"]
        if mv in NON_WORK:
            continue
        if prev is not None and mv != prev and not s.get("sets") and s.get("source") == "crown":
            out.append((float(s["start"]), float(s["start"] + 0.5 * (s["end"] - s["start"]))))
        prev = mv
    return out


def drop_unknown(d: dict, predicted: Iterable[float]) -> List[float]:
    """Predicted switch times outside unknown_windows(d)."""
    win = unknown_windows(d)
    return [p for p in predicted if not any(a <= p <= b for a, b in win)]


def set_ends(d: dict) -> List[float]:
    """Every moment a set ends inside a station (the end of 9 in 9 + 6), plus the end of every
    working segment: where the watch should say "set done"."""
    out: List[float] = []
    for s in d.get("segments", []):
        if s["movement"] in NON_WORK:
            continue
        for x in s.get("sets", []):
            out.append(float(x["end"]))
        if not s.get("sets"):
            out.append(float(s["end"]))
    return sorted(out)


def match(truth: Sequence[float], predicted: Iterable[float], tol: float = 3.0) -> dict:
    """Greedy one-to-one matching of predicted times to true times within `tol` seconds.
    Returns {hits, misses, false, errors} (errors = predicted - true for each hit)."""
    pred = sorted(float(p) for p in predicted)
    used = [False] * len(pred)
    errors: List[float] = []
    misses = 0
    for t in sorted(truth):
        best, best_i = None, None
        for i, p in enumerate(pred):
            if used[i]:
                continue
            e = p - t
            if abs(e) <= tol and (best is None or abs(e) < abs(best)):
                best, best_i = e, i
        if best_i is None:
            misses += 1
        else:
            used[best_i] = True
            errors.append(best)
    return {"hits": len(errors), "misses": misses, "false": used.count(False), "errors": errors}


def cache_path(d: dict, key: str) -> Path:
    """Local copy of a label's file (`files[key]`) under data/cache/<id>/."""
    return CACHE_DIR / d["id"] / Path(d["files"][key]).name
