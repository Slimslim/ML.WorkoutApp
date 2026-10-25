#!/usr/bin/env python3
"""Write the Swift test fixtures of spec §6 into BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/.

Expected values are simulator ground truth (from the trajectory), never analyzer output.
Usage: python tools/make_fixtures.py [--out DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath.recording import save_session_csv  # noqa: E402
from barpath.simulate import simulate_lift, simulate_session  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
DEFAULT_OUT = REPO / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures"
TOLERANCE = {"height": 0.04, "velocity": 0.08, "horizontal": 0.04}
MAX_BYTES = 3_000_000

# (fixture name, lift type, seed, conjugate quaternions)
LIFTS = [
    ("sim_snatch", "snatch", 1, False),
    ("sim_clean_and_jerk", "cleanAndJerk", 1, False),
    ("sim_snatch_conjugate", "snatch", 2, True),
]
SESSION_SEED = 7


def expected(truth: dict) -> dict:
    keys = ["maxHeight", "peakVerticalVelocity", "catchHeight", "finalHeight", "maxBackward"]
    d = {k: round(truth[k], 4) for k in keys}
    d["tolerance"] = TOLERANCE
    return d


def write_json(path: Path, obj) -> None:
    with open(path, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = ap.parse_args(argv)
    out: Path = args.out
    out.mkdir(parents=True, exist_ok=True)

    for name, lift_type, seed, conj in LIFTS:
        sim = simulate_lift(lift_type, seed=seed, conjugate=conj)
        path = out / f"{name}.json"
        for decimals in (6, 5, 4):
            sim.recording.save(path, decimals=decimals)
            if os.path.getsize(path) <= MAX_BYTES:
                break
        write_json(out / f"{name}.expected.json", expected(sim.truth))
        print(f"{path.name}: {os.path.getsize(path) / 1e6:.2f} MB, truth "
              + ", ".join(f"{k}={v:.3f}" for k, v in sim.truth.items()))

    ses = simulate_session(seed=SESSION_SEED)
    csv_path = out / "sim_session.csv"
    save_session_csv(csv_path, ses.motion, ses.session_id, ses.start_date, "snatch")
    write_json(out / "sim_session.expected.json", {
        "liftCount": len(ses.lifts),
        "lifts": [{"homingTime": round(l.t_homing, 3), "endTime": round(l.t_end, 3)} for l in ses.lifts],
        "tolerance": {"time": 0.5},
    })
    print(f"{csv_path.name}: {os.path.getsize(csv_path) / 1e6:.2f} MB, lifts "
          + ", ".join(f"[{l.t_homing:.2f}, {l.t_end:.2f}]" for l in ses.lifts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
