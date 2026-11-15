#!/usr/bin/env python3
"""How a session CSV was made (W29, build 16+): battery, power, settings, phone, end reason.

  python tools/recording_info.py data/raw/<date>-<name>/session-*.csv

Prints one block per file: watch and phone devices and builds, battery at start and end, the
drain in % per hour, Low Power Mode and thermal state, units, heart-rate zone source and how the
recording ended. Files from before build 16 print the keys they have; the rest show '-'."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from barpath import recording  # noqa: E402


def _v(x) -> str:
    if x is None:
        return "-"
    if isinstance(x, float):
        return f"{x:g}"
    return str(x)


def report(path) -> str:
    s = recording.load_session_csv(path, workout_hz=None)
    h = s.header
    info = s.recording_info()
    rate = info.battery_per_hour()
    events = {}
    for e in s.events:
        if e.get("name") in ("thermal", "lowPower"):
            events.setdefault(e["name"], []).append(f"{_v(e.get('t'))}s:{_v(e.get('state'))}")
    end = info.end_reason if info.end_reason is not None else "missing (app stopped: crash or killed)"
    lines = [
        os.path.basename(str(path)),
        f"  watch      {_v(h.get('watchModel'))}, watchOS {_v(h.get('watchOS'))}, app build {_v(h.get('appBuild'))}",
        f"  phone      {_v(info.phone_model)}, iOS {_v(info.phone_os)}, app build {_v(info.phone_build)}",
        f"  battery    start {_v(info.battery_start)}%, end {_v(info.battery_end)}%, "
        f"{len(info.battery)} minute lines, "
        + (f"{rate:.1f} %/h" if rate is not None else "-- %/h"),
        f"  power      charging {_v(info.charging)}, low power {_v(info.low_power)}, thermal {_v(info.thermal)}",
        f"  changes    thermal {', '.join(events.get('thermal', [])) or '-'}; "
        f"low power {', '.join(events.get('lowPower', [])) or '-'}",
        f"  settings   units {_v(info.units)}, HR zones {_v(info.hr_zone_source)}, "
        f"rate {_v(s.source_rate)} Hz, gps {_v(s.gps)}",
        f"  end        {end}, duration {_v(info.duration)} s",
    ]
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+")
    args = ap.parse_args(argv)
    for p in args.files:
        print(report(p))
    return 0


if __name__ == "__main__":
    sys.exit(main())
