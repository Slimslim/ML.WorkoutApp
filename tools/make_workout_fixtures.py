#!/usr/bin/env python3
"""Writes the workout-engine parity fixtures for BarPathKit (see tools/tests/workout_fixture_gen.py).

    python3 tools/make_workout_fixtures.py
"""
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE / "tests"))

import workout_fixture_gen as gen  # noqa: E402

if __name__ == "__main__":
    if gen.OUT.exists():
        shutil.rmtree(gen.OUT)
    n = gen.write()
    print("wrote %d files to %s" % (n, gen.OUT.relative_to(gen.ROOT)))
