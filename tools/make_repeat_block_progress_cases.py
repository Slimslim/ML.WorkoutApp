#!/usr/bin/env python3
"""Write Fixtures/repeat_block_progress_cases.json: scripted runs of WorkoutProgress in block mode
(WORKOUT_SPEC 5c) for listed-once definitions, with the events the Python reference produces.
RepeatBlockProgressTests.swift replays the same scripts and must produce the same events.
All definitions are invented. Usage: python3 tools/make_repeat_block_progress_cases.py [--check]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import repeat_block as rb  # noqa: E402
from barpath.workout import WorkoutDefinition, WorkoutProgress  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "BarPath" / "BarPathKit" / "Tests" / "BarPathKitTests" / "Fixtures" / "repeat_block_progress_cases.json"


def seg(kind, movement, name, value=None, unit=None):
    s = {"kind": kind, "movement": movement, "name": name}
    if value is not None:
        s["target"] = {"value": float(value), "unit": unit}
    return s


def rest(seconds=None):
    return seg("rest", "rest", "Rest", seconds, "seconds" if seconds else None)


def definition(id_, fmt, segments, cap=None, interval=None, rounds=None):
    d = {"id": id_, "name": "Test " + id_, "shortName": "T", "format": fmt, "team": "solo",
         "healthKitActivity": "crossTraining", "segments": segments, "listedOnce": True}
    if cap is not None:
        d["timeCapSeconds"] = float(cap)
    if interval is not None:
        d["intervalSeconds"] = float(interval)
    if rounds is not None:
        d["rounds"] = rounds
    return d


def crowns(start, every, n):
    return [[start + every * (k + 1), "crown"] for k in range(n)]


CASES = [
    ("AMRAP 6:00 of a couplet: the Crown on the last part starts the next pass; the cap ends it in "
     "the current step",
     definition("p.amrap", "amrap", [seg("station", "burpees", "Burpees", 10, "reps"),
                                     seg("station", "airSquats", "Air Squats", 20, "reps")], cap=360),
     [[0, "start"]] + crowns(0, 40, 8) + [[400, "tick"]]),
    ("AMRAP: undo across a pass boundary, then the Crown starts that step again",
     definition("p.amrapUndo", "amrap", [seg("station", "burpees", "Burpees", 10, "reps"),
                                         seg("station", "airSquats", "Air Squats", 20, "reps")], cap=300),
     [[0, "start"], [40, "crown"], [80, "crown"], [90, "undo"], [100, "crown"], [130, "crown"], [300, "tick"]]),
    ("Rounds for time x 3 with a timed rest after each round: the rest ends by itself, Finish on the "
     "last work part of round 3 (no rest after it)",
     definition("p.roundsRest", "forTime", [seg("run", "run", "Run", 400, "meters"),
                                            seg("station", "burpees", "Burpees", 15, "reps"), rest(60)],
                rounds=3),
     [[0, "start"], [100, "crown"], [160, "crown"], [300, "crown"], [360, "crown"], [500, "crown"],
      [560, "crown"]]),
    ("Rounds for time x 2: undo after the Finish unfinishes, the Crown finishes again",
     definition("p.roundsUnfinish", "forTime", [seg("station", "pullUps", "Pull-ups", 10, "reps"),
                                                seg("station", "pushUps", "Push-ups", 20, "reps")], rounds=2,
                cap=600),
     [[0, "start"], [30, "crown"], [60, "crown"], [90, "crown"], [120, "crown"], [125, "undo"], [130, "crown"]]),
    ("Every 3:00 x 6 (row, thrusters, rest): one window = one pass; a set not finished jumps to the "
     "next window; the last window keeps its rest and the cap ends it",
     definition("p.every3", "emom", [seg("station", "row", "Row", 15, "calories"),
                                     seg("station", "thrusters", "Thrusters", 12, "reps"), rest()],
                cap=1080, interval=180, rounds=6),
     [[0, "start"], [60, "crown"], [110, "crown"], [250, "crown"], [400, "crown"], [450, "crown"],
      [600, "crown"], [700, "crown"], [940, "crown"], [990, "crown"], [1100, "tick"]]),
    ("Tabata 8 x (20 s work, 10 s rest) every 0:30, no Crown: 16 steps on the clock, 4:00 exactly",
     definition("p.tabata", "emom", [seg("station", "airSquats", "Air Squats", 20, "seconds"), rest(10)],
                cap=240, interval=30, rounds=8),
     [[0, "start"], [260, "tick"]]),
    ("Tabata with an early Crown in the work and in the rest: the window still starts on the clock",
     definition("p.tabataCrown", "emom", [seg("station", "airSquats", "Air Squats", 20, "seconds"), rest(10)],
                cap=240, interval=30, rounds=8),
     [[0, "start"], [15, "crown"], [40, "crown"], [45, "crown"], [260, "tick"]]),
    ("Tabata: undo back into a rest whose window has passed, then the Crown moves on (never stuck)",
     definition("p.tabataUndoPast", "emom", [seg("station", "airSquats", "Air Squats", 20, "seconds"), rest(10)],
                cap=240, interval=30, rounds=8),
     [[0, "start"], [35, "tick"], [36, "undo"], [40, "crown"], [260, "tick"]]),
    ("Every 1:00 with an early Crown on the work: rest until the window, the next pass starts on the clock",
     definition("p.emomEarly", "emom", [seg("station", "powerCleans", "Power Cleans", 3, "reps"), rest()],
                cap=180, interval=60, rounds=3),
     [[0, "start"], [20, "crown"], [70, "crown"], [75, "undo"], [80, "crown"], [130, "crown"], [200, "tick"]]),
    ("EMOM with a timed rest in the middle of the block: the rest hands over to the next part",
     definition("p.midRestTimed", "emom", [seg("station", "burpees", "Burpees", 10, "reps"), rest(30),
                                           seg("station", "airSquats", "Air Squats", 15, "reps"), rest()],
                cap=240, interval=120, rounds=2),
     [[0, "start"], [40, "crown"], [100, "crown"], [160, "crown"], [190, "crown"], [250, "tick"]]),
    ("EMOM with an untimed rest in the middle: the window end skips the rest of the pass (5c, "
     "differs from today's next-segment rule)",
     definition("p.midRestOpen", "emom", [seg("station", "burpees", "Burpees", 10, "reps"), rest(),
                                          seg("station", "airSquats", "Air Squats", 15, "reps"), rest()],
                cap=240, interval=120, rounds=2),
     [[0, "start"], [40, "crown"], [250, "tick"]]),
    ("EMOM 10:00 every 1:00, no round count: windows until the cap",
     definition("p.emomCap", "emom", [seg("station", "kettlebellSwings", "KB Swings", 15, "reps"), rest()],
                cap=600, interval=60),
     [[0, "start"], [30, "crown"], [95, "crown"], [150, "crown"], [620, "tick"]]),
    ("Fixed list marked listedOnce (for time, no rounds): done once, as today",
     definition("p.fixed", "forTime", [seg("run", "run", "Run", 800, "meters"),
                                       seg("station", "burpees", "Burpees", 30, "reps"),
                                       seg("run", "run", "Run", 800, "meters")]),
     [[0, "start"], [200, "crown"], [300, "crown"], [310, "undo"], [320, "crown"], [500, "crown"]]),
]


def build() -> dict:
    out = []
    for name, d_dict, script in CASES:
        d = WorkoutDefinition.from_dict(d_dict)
        plan = rb.engine_plan(d, rb.ENGINE_V2)
        assert plan is not None, name
        p = WorkoutProgress(d, plan)
        events = rb.run_script(p, script)
        out.append({"name": name, "definition": d_dict, "script": script, "events": events,
                    "finished": p.is_finished, "finishTime": p.finish_time, "currentStep": p.current_index,
                    "steps": len(p.segment_starts)})
    return {"note": "Scripted WorkoutProgress runs in block mode (WORKOUT_SPEC 5c), written by "
                    "tools/make_repeat_block_progress_cases.py from the Python reference. script: "
                    "[t, start|crown|undo|end|tick], the clock runs between actions (cap first on a "
                    "tie). events: [t, kind, step, source].",
            "cases": out}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if the file is not up to date")
    args = ap.parse_args(argv)
    text = json.dumps(build(), indent=1, ensure_ascii=False) + "\n"
    if args.check:
        return 0 if OUT.exists() and OUT.read_text(encoding="utf-8") == text else 1
    OUT.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
