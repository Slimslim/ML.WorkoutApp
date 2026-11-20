#!/usr/bin/env python3
"""Build a versioned per-movement dataset from the local labels and cached recordings.

    python3 tools/build_dataset.py --out data/datasets --version v1 [--labels data/labels] [--cache data/cache]

Writes data/datasets/<version>/ (an existing version folder is never overwritten):
  manifest.json          version, created (UTC), builder commit ("+changes" when the tree is
                         dirty), sha256 of every source label file, label ids used and skipped
                         (with the reason), counts per movement, rows without a cached recording
  <movement>/index.csv   one row per unit of work (barpath.tiers.work_units): workout labels one
                         per set where the segment has sets, else one per working segment; lifts
                         labels one per set. Columns: INDEX_COLUMNS.
  <movement>/motion.npz  per row the motion from start - 2 s to end + 2 s (clipped to the recording),
                         keys "<row_id>/t" (seconds relative to the row start), "<row_id>/q",
                         "<row_id>/user_accel", "<row_id>/gravity", "<row_id>/rotation_rate".
                         Rows whose recording is not cached have no motion (counted in the manifest).
  <movement>/reps.csv    row_id, rep_index, time (session seconds) for rows with repTimes.
  CHANGELOG.md           labels added / removed / changed against the previous version folder.

Tier (how far the count can be trusted), from barpath.tiers:
  A  the segment has a `console` block, or the set has `repTimes` and the label's notes mention
     "video";
  B  the count is the athlete's (segment `source` == "athlete", or a lifts label);
  C  segment `source` == "motion";
  D  otherwise (Crown taps only).
Split: "test" when tier A, else "dev". Athlete: "B" when the label id contains "tester-b", else "A".

Lifts sets have no session times in the label: start / end are the first and last sample of the
set's own recording (lift .json or Lifting-mode .csv), empty when it is not cached.
Motion is the canonical watch frame of barpath.recording.load_session_csv (workouts at 100 Hz).

Everything under data/ is private and git-ignored: never commit a dataset.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np  # noqa: E402

from barpath import labels as L  # noqa: E402
from barpath import tiers  # noqa: E402
from barpath.recording import MotionSeries, load_recording, load_session_csv  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
PAD = 2.0  # seconds of motion kept before the start and after the end of every row

INDEX_COLUMNS = ("row_id", "label_id", "athlete", "date", "movement", "round", "start", "end",
                 "amount", "unit", "load_lb", "tier", "split", "training", "has_rep_times", "flagged")
MOTION_FIELDS = ("q", "user_accel", "gravity", "rotation_rate")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def git_commit(repo: Path = REPO) -> str:
    """Short HEAD of the builder's repo, with "+changes" when tracked files are modified."""
    try:
        head = subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=repo, capture_output=True,
                              text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "--untracked-files=no"], cwd=repo,
                               capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return head + ("+changes" if dirty else "")


class RecordingCache:
    """Loads each cached recording once. Path -> MotionSeries, or None when not cached."""

    def __init__(self) -> None:
        self._m: Dict[Path, Optional[MotionSeries]] = {}

    def get(self, path: Path) -> Optional[MotionSeries]:
        if path not in self._m:
            if not path.is_file():
                self._m[path] = None
            elif path.suffix.lower() == ".csv":
                self._m[path] = load_session_csv(path).motion
            else:
                self._m[path] = load_recording(path).motion
        return self._m[path]


def recording_path(label: dict, unit: dict, cache: Path) -> Optional[Path]:
    """The cached file a unit's motion comes from: the label's session CSV for workouts, the
    set's own file for lifts."""
    name = unit["file"] if label.get("kind") == "lifts" else (label.get("files") or {}).get("csv")
    if not name:
        return None
    return cache / label["id"] / Path(name).name


def window(motion: MotionSeries, start: float, end: float, pad: float = PAD) -> dict:
    """Samples from start - pad to end + pad, t relative to start."""
    i0, i1 = np.searchsorted(motion.t, [start - pad, end + pad + 1e-9])
    m = motion.slice(int(i0), int(i1))
    return {"t": m.t - start, "q": m.q.astype(np.float32),
            "user_accel": m.user_accel.astype(np.float32), "gravity": m.gravity.astype(np.float32),
            "rotation_rate": m.rotation_rate.astype(np.float32)}


def _cell(v) -> str:
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, float):
        return f"{v:.3f}".rstrip("0").rstrip(".")
    return str(v)


def previous_manifest(out: Path, version: str) -> Tuple[Optional[str], Optional[dict]]:
    """The most recently created other version folder in `out` with a manifest."""
    best: Tuple[str, Optional[str], Optional[dict]] = ("", None, None)
    if not out.is_dir():
        return None, None
    for d in out.iterdir():
        mf = d / "manifest.json"
        if d.name == version or not mf.is_file():
            continue
        try:
            m = json.loads(mf.read_text())
        except (OSError, ValueError):
            continue
        key = str(m.get("created", ""))
        if best[1] is None or key > best[0]:
            best = (key, d.name, m)
    return best[1], best[2]


def changelog(version: str, manifest: dict, prev_version: Optional[str], prev: Optional[dict]) -> str:
    lines = [f"# Dataset {version}", "", f"Created {manifest['created']} by commit {manifest['commit']}.",
             f"{len(manifest['labels_used'])} labels used, {len(manifest['labels_skipped'])} skipped, "
             f"{sum(c['rows'] for c in manifest['movements'].values())} rows.", ""]
    if prev is None:
        lines.append("First version: no previous version folder to compare with.")
        return "\n".join(lines) + "\n"
    new, old = manifest["label_sha256"], prev.get("label_sha256", {})
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = sorted(k for k in set(new) & set(old) if new[k] != old[k])
    lines.append(f"Compared with {prev_version} (label files by sha256):")
    lines.append("")
    for title, ids in (("Added", added), ("Removed", removed), ("Changed", changed)):
        lines.append(f"- {title} ({len(ids)}): " + (", ".join(ids) if ids else "none"))
    return "\n".join(lines) + "\n"


def build(out: Path, version: str, labels_dir: Path, cache: Path, commit: Optional[str] = None) -> dict:
    """Builds the dataset folder out/version and returns its manifest."""
    dest = out / version
    if dest.exists():
        raise FileExistsError(f"{dest} already exists; pick a new --version")
    prev_version, prev = previous_manifest(out, version)

    rec = RecordingCache()
    shas: Dict[str, str] = {}
    used: List[str] = []
    skipped: List[dict] = []
    rows: Dict[str, List[dict]] = {}
    motion: Dict[str, Dict[str, np.ndarray]] = {}
    reps: Dict[str, List[tuple]] = {}
    no_motion: Dict[str, int] = {}

    for path in L.all_label_files(labels_dir):
        shas[path.stem] = sha256(path)
        try:
            label = L.load(path)
        except (OSError, ValueError) as e:
            skipped.append({"id": path.stem, "reason": f"unreadable: {e}"})
            continue
        lid = str(label.get("id", path.stem))
        errs = L.validate(label)
        if errs:
            skipped.append({"id": lid, "reason": f"invalid: {errs[0]}"})
            continue
        units = list(tiers.work_units(label))
        if not units:
            skipped.append({"id": lid, "reason": "no units of work"})
            continue
        paths = [recording_path(label, u, cache) for u in units]
        if not any(p is not None and p.is_file() for p in paths):
            skipped.append({"id": lid, "reason": "recording not cached"})
            continue
        used.append(lid)
        who = tiers.athlete(label)
        for u, p in zip(units, paths):
            mv = u["movement"]
            row_id = f"{lid}-{u['index']:03d}"
            m = rec.get(p) if p is not None else None
            start, end = u["start"], u["end"]
            if label.get("kind") == "lifts" and m is not None and len(m):
                start, end = float(m.t[0]), float(m.t[-1])
            if m is not None and start is not None:
                w = window(m, start, end)
                bucket = motion.setdefault(mv, {})
                for k, v in w.items():
                    bucket[f"{row_id}/{k}"] = v
            else:
                no_motion[mv] = no_motion.get(mv, 0) + 1
            for j, t in enumerate(u["rep_times"] or []):
                reps.setdefault(mv, []).append((row_id, j, float(t)))
            rows.setdefault(mv, []).append({
                "row_id": row_id, "label_id": lid, "athlete": who, "date": label.get("date"),
                "movement": mv, "round": u["round"], "start": start, "end": end,
                "amount": u["amount"], "unit": u["unit"], "load_lb": u["load_lb"],
                "tier": u["tier"], "split": u["split"], "training": u["training"],
                "has_rep_times": bool(u["rep_times"]), "flagged": u["flagged"],
            })

    dest.mkdir(parents=True)
    counts = {}
    for mv in sorted(rows):
        d = dest / mv
        d.mkdir()
        with open(d / "index.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(INDEX_COLUMNS)
            for r in rows[mv]:
                w.writerow([_cell(r[c]) for c in INDEX_COLUMNS])
        np.savez_compressed(d / "motion.npz", **motion.get(mv, {}))
        with open(d / "reps.csv", "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(("row_id", "rep_index", "time"))
            for row_id, j, t in reps.get(mv, []):
                w.writerow((row_id, j, _cell(t)))
        tier_counts = {t: sum(r["tier"] == t for r in rows[mv]) for t in tiers.TIERS}
        counts[mv] = {
            "rows": len(rows[mv]), "rows_without_motion": no_motion.get(mv, 0),
            "sessions": len({r["label_id"] for r in rows[mv]}),
            "rows_with_rep_times": sum(r["has_rep_times"] for r in rows[mv]),
            "reps_timed": len(reps.get(mv, [])), "tiers": tier_counts,
            "test_rows": sum(r["split"] == "test" for r in rows[mv]),
        }

    manifest = {
        "version": version,
        "created": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "commit": commit if commit is not None else git_commit(),
        "builder": "tools/build_dataset.py",
        "pad_seconds": PAD,
        "label_sha256": shas,
        "labels_used": used,
        "labels_skipped": skipped,
        "rows_without_motion": sum(no_motion.values()),
        "movements": counts,
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    (dest / "CHANGELOG.md").write_text(changelog(version, manifest, prev_version, prev))
    return manifest


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--out", type=Path, required=True, help="datasets folder, e.g. data/datasets")
    ap.add_argument("--version", required=True, help="version folder name, e.g. v1")
    ap.add_argument("--labels", type=Path, default=L.LABELS_DIR)
    ap.add_argument("--cache", type=Path, default=L.CACHE_DIR)
    a = ap.parse_args(argv)
    try:
        m = build(a.out, a.version, a.labels, a.cache)
    except FileExistsError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"{a.out / a.version}: {len(m['labels_used'])} labels used, {len(m['labels_skipped'])} skipped, "
          f"{m['rows_without_motion']} rows without motion")
    for s in m["labels_skipped"]:
        print(f"  skipped {s['id']}: {s['reason']}")
    for mv, c in m["movements"].items():
        t = c["tiers"]
        print(f"  {mv:28s} rows {c['rows']:3d}  sessions {c['sessions']:2d}  "
              f"A{t['A']} B{t['B']} C{t['C']} D{t['D']}  timed reps {c['reps_timed']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
