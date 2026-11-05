"""Which results belong to a workout (tools/barpath/workout_history.py, reference for
WorkoutHistory.swift; WorkoutHistoryTests.swift checks the same cases)."""
import copy
import json
from datetime import datetime, timedelta, timezone

from barpath.workout import SegmentLoad, WorkoutDefinition, WorkoutLibrary, WorkoutResult
from barpath.workout_card import SEED, movement_line
from barpath.workout_history import (has_alias, is_same_workout, latest_of, movement_sequence, normalized_name,
                                     results_of)


def seed(name: str) -> WorkoutDefinition:
    return WorkoutDefinition.from_dict(json.loads((SEED / f"{name}.json").read_text())["definition"])


def renamed(d: WorkoutDefinition, new_id: str) -> WorkoutDefinition:
    out = copy.deepcopy(d)
    out.id = new_id
    return out


def result(d: WorkoutDefinition, day: int, seconds: float = 600.0) -> WorkoutResult:
    start = datetime(2026, 11, day, 18, 0, tzinfo=timezone.utc)
    end = start + timedelta(seconds=seconds)
    return WorkoutResult(definition=d, start_date=start, finish_date=end, end_date=end,
                         total_seconds=seconds, segments=[], events=[])


def test_normalized_name():
    assert normalized_name("Every 1:00 × 8: Power C&J") == "every 1 00 8 power c j"
    assert normalized_name("  FREEDOM ") == "freedom"
    assert normalized_name("Café  “Game Over”") == "cafe game over"
    assert normalized_name("") == ""


def test_freedom_built_in_id_matches_library_row():
    lib = seed("freedom")
    # The owner's result: id of a built-in that was never merged, loads written as 85 kg.
    old = renamed(lib, "wod.freedom")
    for s in old.segments:
        if s.load is not None:
            s.load = SegmentLoad(85, "kg", 1)
    assert lib.id == "lib.pitfire.20261102.freedom"
    assert is_same_workout(lib, old)
    assert is_same_workout(old, lib)


def test_pcj_emom_built_in_id_matches_library_row():
    lib = seed("pcj_emom")
    assert is_same_workout(lib, renamed(lib, "wod.pcjEmom"))


def test_same_name_other_movements_do_not_match():
    lib = seed("freedom")
    other = renamed(lib, "wod.other")
    other.segments[1].movement = "thrusters"
    assert not is_same_workout(lib, other)
    shorter = renamed(lib, "wod.short")
    shorter.segments = shorter.segments[:-2]
    assert not is_same_workout(lib, shorter)


def test_same_movements_other_name_do_not_match():
    lib = seed("freedom")
    other = renamed(lib, "wod.liberty")
    other.name = "Liberty"
    assert not is_same_workout(lib, other)


def test_same_id_always_matches():
    helen = WorkoutLibrary.definition("wod.helen")
    edited = copy.deepcopy(helen)
    edited.name = "Helen (old)"
    assert is_same_workout(helen, edited)


def test_movement_sequence():
    assert movement_sequence(seed("pcj_emom"))[:2] == ["station:powerCleanAndJerk", "rest:rest"]


def test_results_newest_first():
    lib = seed("freedom")
    a = result(renamed(lib, "wod.freedom"), 2)
    b = result(lib, 9)
    helen = result(WorkoutLibrary.definition("wod.helen"), 5)
    found = results_of(lib, [a, helen, b])
    assert [r.id for r in found] == [b.id, a.id]
    assert latest_of(lib, [a, helen, b]).id == b.id


def test_segment_lines_quantity_first():
    """The preview's "All segments" list uses the card line (WorkoutCard.segmentLine in Swift)."""
    pcj = seed("pcj_emom")
    assert [movement_line(s).full for s in pcj.segments[:2]] == ["2 Power C&J", "Rest"]
    helen = WorkoutLibrary.definition("wod.helen")
    assert [movement_line(s).full for s in helen.segments[:3]] == ["400 m Run", "21 KB Swings", "12 Pull-ups"]
    freedom = seed("freedom")
    assert [movement_line(s).full for s in freedom.segments[:2]] == ["40 Cal Row", "7 Power Cleans @155 lb"]


def test_alias_links_a_result_after_the_library_rename():
    """The real case: the result was recorded as wod.freedom "Freedom"; the library row was renamed
    "For Time" (Freedom was only the RX level label) and lists wod.freedom as an alias."""
    lib = seed("freedom")
    assert (lib.name, lib.aliases) == ("For Time", ["wod.freedom"])
    old = renamed(lib, "wod.freedom")
    old.name = "Freedom"
    old.short_name = "Freedom"
    old.aliases = None
    assert has_alias(lib, "wod.freedom") and not has_alias(old, lib.id)
    assert is_same_workout(lib, old)
    assert is_same_workout(old, lib)
    # Without the alias the rename breaks the name + movements rule.
    plain = copy.deepcopy(lib)
    plain.aliases = None
    assert not is_same_workout(plain, old)
    # Results and the "last" score follow the alias.
    a = result(old, 2)
    helen = result(WorkoutLibrary.definition("wod.helen"), 5)
    assert [r.id for r in results_of(lib, [a, helen])] == [a.id]
    assert latest_of(lib, [helen, a]).id == a.id


def test_alias_on_either_side_and_only_for_listed_ids():
    lib = seed("pcj_emom")
    old = renamed(lib, "wod.pcjEmom")
    old.name = "PCJ EMOM (old)"
    old.aliases = None
    assert is_same_workout(lib, old) and is_same_workout(old, lib)
    # Reverse: the result lists the library id (a row moved to a new id later).
    newer = renamed(lib, "lib.pitfire.20261109.pcj-emom")
    newer.name = "Something else"
    newer.aliases = None
    back = copy.deepcopy(lib)
    back.aliases = ["lib.pitfire.20261109.pcj-emom"]
    assert is_same_workout(newer, back) and is_same_workout(back, newer)
    stranger = renamed(lib, "wod.other")
    stranger.name = "Other"
    stranger.aliases = None
    assert not is_same_workout(lib, stranger)
