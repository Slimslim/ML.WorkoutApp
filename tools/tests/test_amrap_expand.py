"""AMRAP expansion at workout start (#138): Python mirror of BarPathKit's
WorkoutDefinition.expandedForAmrap(). The cases are shared with the Swift tests
(Fixtures/amrap_expand_cases.json), so both sides check the same expectations."""
import json
from pathlib import Path

from barpath.workout import (AMRAP_MAX_SEGMENTS, AMRAP_MIN_LISTED_ROUNDS, WorkoutDefinition,
                             WorkoutLibrary, WorkoutProgress, amrap_expanded)

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/amrap_expand_cases.json"


def cases():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]


def case_input(c) -> WorkoutDefinition:
    d = dict(c["input"])
    d["segments"] = c["pattern"] * c["times"]
    return WorkoutDefinition.from_dict(d)


def test_fixture_cases():
    assert len(cases()) >= 10
    for c in cases():
        before = case_input(c)
        after = amrap_expanded(before)
        name = c["name"]
        if c["unchanged"]:
            assert after == before, name
            continue
        assert len(after.segments) == c["segmentCount"], name
        assert after.round_size == c["roundSize"], name
        n = len(before.segments)
        r = c["roundSize"]
        start = c["blockStart"]
        assert after.segments[:n] == before.segments, name
        for i in range(n, len(after.segments)):
            assert after.segments[i] == before.segments[start + (i - n) % r], (name, i)
        # everything else is kept
        assert after.id == before.id and after.time_cap_seconds == before.time_cap_seconds, name


def test_idempotent():
    for c in cases():
        once = amrap_expanded(case_input(c))
        assert amrap_expanded(once) == once, c["name"]


def test_bounds():
    for c in cases():
        after = amrap_expanded(case_input(c))
        before = case_input(c)
        assert len(after.segments) <= max(len(before.segments), AMRAP_MAX_SEGMENTS)
        if after.format == "amrap" and after.round_size and not c["unchanged"]:
            rounds = len(after.segments) // after.round_size
            assert rounds >= min(AMRAP_MIN_LISTED_ROUNDS, max(1, AMRAP_MAX_SEGMENTS // after.round_size))


def test_one_pass_amrap_no_longer_finishes_after_one_pass():
    """The #138 scenario: 6 advances on a one-pass AMRAP finished it; expanded it keeps going."""
    c = cases()[0]
    d = amrap_expanded(case_input(c))
    p = WorkoutProgress(d)
    p.start(0.0)
    for k in range(1, 7):
        assert p.advance(float(k * 100), "crown")
    assert not p.is_finished
    assert p.current_index == 6


def test_builtins_unchanged_except_amraps():
    for d in WorkoutLibrary.all:
        after = amrap_expanded(d)
        if d.format != "amrap":
            assert after == d, d.id
        else:
            assert len(after.segments) >= len(d.segments)
            assert after.segments[:len(d.segments)] == d.segments


def test_history_matches_an_expanded_result_to_its_library_amrap():
    from barpath.workout_history import is_same_workout
    lib = case_input(cases()[0])
    renamed = WorkoutDefinition.from_dict(dict(lib.to_dict(), id="t.other"))
    ran = amrap_expanded(renamed)
    assert len(ran.segments) != len(lib.segments)
    assert is_same_workout(lib, ran)
    assert is_same_workout(ran, lib)
