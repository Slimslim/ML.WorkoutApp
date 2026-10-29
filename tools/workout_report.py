#!/usr/bin/env python3
"""Prints a split table for a workout session CSV or a workout-<id>.json result.

    python3 tools/workout_report.py session-<id>.csv
    python3 tools/workout_report.py workout-<uuid>.json
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath.workout import WorkoutResult, load_workout_csv, split_stats  # noqa: E402


def fmt_time(seconds) -> str:
    if seconds is None:
        return "-"
    total = int(round(seconds))
    return f"{total // 60}:{total % 60:02d}"


def format_table(title: str, segments: list, total: float, hr_avg=None, hr_max=None) -> str:
    lines = [title,
             f"{'#':>2}  {'segment':<26} {'time':>7} {'cumul':>7} {'HR':>4}  run pace / cadence"]
    cumulative = 0.0
    run_s = station_s = 0.0
    for s in segments:
        cumulative += s.duration
        if s.kind == "run":
            run_s += s.duration
        else:
            station_s += s.duration
        extra = ""
        if s.kind == "run":
            if s.pace_seconds_per_km is not None:
                extra += f"{fmt_time(s.pace_seconds_per_km)}/km"
            if s.cadence is not None:
                extra += f"  {s.cadence:.0f} spm"
        hr = f"{s.heart_rate_avg:.0f}" if s.heart_rate_avg is not None else "-"
        lines.append(f"{s.index + 1:>2}  {s.title:<26} {fmt_time(s.duration):>7} "
                     f"{fmt_time(cumulative):>7} {hr:>4}  {extra.strip()}")
    lines.append(f"Total {fmt_time(total)}   runs {fmt_time(run_s)}   stations {fmt_time(station_s)}"
                 + (f"   HR avg {hr_avg:.0f}" if hr_avg is not None else "")
                 + (f" max {hr_max:.0f}" if hr_max is not None else ""))
    return "\n".join(lines)


def report(path) -> str:
    path = Path(path)
    if path.suffix.lower() == ".json":
        r = WorkoutResult.load(path)
        return format_table(r.definition.name, r.segments, r.total_seconds, r.heart_rate_avg, r.heart_rate_max)
    w = load_workout_csv(path)
    if w.definition is None or w.progress is None:
        raise SystemExit(f"unknown or missing workout id in header: {w.workout_id!r}")
    if not w.progress.is_started:
        raise SystemExit("no segment events found in CSV")
    segs = split_stats(w.progress, w.end_time, w.heart_rates, w.pedometer)
    total = w.progress.total_elapsed(w.end_time)
    hrs = [h.value for h in w.heart_rates]
    return format_table(w.definition.name, segs, total,
                        sum(hrs) / len(hrs) if hrs else None, max(hrs) if hrs else None)


def main(argv=None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print(__doc__)
        return 2
    print(report(argv[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
