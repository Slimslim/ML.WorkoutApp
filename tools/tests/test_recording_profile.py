"""barpath/recording_profile.py: which workouts need the high rate (shared cases with the Swift test)."""
import glob
import json
from pathlib import Path

import pytest

from barpath.recording_profile import (HIGH, STANDARD, profile_for, profile_for_segments, uses_location,
                                       uses_location_segments, words)
from barpath.workout import WorkoutLibrary

ROOT = Path(__file__).resolve().parent.parent.parent
FIXTURE = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/recording_profile_cases.json"
SEEDS = ROOT / "tools/library/seed"
DATA = json.loads(FIXTURE.read_text())


def tuples(segs):
    return [(s["kind"], s["movement"], s["name"], bool(s.get("load"))) for s in segs]


def test_words():
    assert words("powerCleanAndJerk") == ["power", "clean", "and", "jerk"]
    assert words("Bent-over row") == ["bent", "over", "row"]
    assert words("DB C&J") == ["db", "c", "j"]
    assert words("") == []


@pytest.mark.parametrize("case", DATA["cases"], ids=lambda c: c["name"])
def test_cases(case):
    assert profile_for_segments(tuples(case["segments"])) == case["profile"]


def test_every_built_in_is_pinned():
    pinned = {e["id"]: e["profile"] for e in DATA["library"] if e["source"] == "builtin"}
    assert set(pinned) == {d.id for d in WorkoutLibrary.known}
    for d in WorkoutLibrary.known:
        assert profile_for(d) == pinned[d.id], d.id
    assert pinned["free.workout"] == STANDARD and pinned["hyrox.solo"] == STANDARD
    assert pinned["wod.helen"] == HIGH       # kettlebell swings


def test_every_seed_is_pinned():
    entries = {e["file"]: e for e in DATA["library"] if e["source"] == "seed"}
    files = sorted(Path(f).name for f in glob.glob(str(SEEDS / "*.json")))
    assert sorted(entries) == files
    for f in files:
        d = json.loads((SEEDS / f).read_text())["definition"]
        # the fixture holds the distinct segments of the seed: same set as the file
        mine = {(s["kind"], s["movement"], s["name"], "load" in s) for s in d["segments"]}
        assert mine == set(tuples(entries[f]["segments"])), f
        got = profile_for_segments((s["kind"], s["movement"], s["name"], "load" in s) for s in d["segments"])
        assert got == entries[f]["profile"] == HIGH


@pytest.mark.parametrize("case", DATA["locationCases"], ids=lambda c: c["name"])
def test_location_cases(case):
    assert uses_location_segments(s["kind"] for s in case["segments"]) == case["gps"]


def test_location_pins_built_ins():
    pinned = {e["id"]: e["gps"] for e in DATA["locationLibrary"]}
    assert set(pinned) == {d.id for d in WorkoutLibrary.known}
    for d in WorkoutLibrary.known:
        assert uses_location(d) == pinned[d.id], d.id
    assert pinned["free.workout"] is False and pinned["hyrox.solo"] is True
