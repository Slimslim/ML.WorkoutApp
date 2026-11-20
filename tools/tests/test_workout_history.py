"""Which results belong to a workout (tools/barpath/workout_history.py, reference for
WorkoutHistory.swift; WorkoutHistoryTests.swift checks the same cases)."""
import copy
import json
from datetime import datetime, timedelta, timezone

from barpath.workout import SegmentLoad, WorkoutDefinition, WorkoutLibrary, WorkoutResult
from barpath.workout_card import SEED, movement_line
from barpath.workout_history import (is_same_workout, latest_of, movement_sequence, normalized_name,
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
    assert normalized_name("  SEESAW ") == "seesaw"
    assert normalized_name("Café  “Game Over”") == "cafe game over"
    assert normalized_name("") == ""


def test_built_in_id_matches_library_row():
    lib = seed("seesaw")
    # A result saved under the id of a built-in that was never merged, loads written in kg.
    old = renamed(lib, "wod.seesaw")
    for s in old.segments:
        if s.load is not None:
            s.load = SegmentLoad(85, "kg", 1)
    assert lib.id == "lib.example.20261101.seesaw"
    assert is_same_workout(lib, old)
    assert is_same_workout(old, lib)


def test_pcj_emom_built_in_id_matches_library_row():
    lib = seed("power_cj_emom")
    assert is_same_workout(lib, renamed(lib, "wod.pcjEmom"))


def test_same_name_other_movements_do_not_match():
    lib = seed("seesaw")
    other = renamed(lib, "wod.other")
    other.segments[1].movement = "thrusters"
    assert not is_same_workout(lib, other)
    shorter = renamed(lib, "wod.short")
    shorter.segments = shorter.segments[:-2]
    assert not is_same_workout(lib, shorter)


def test_same_movements_other_name_do_not_match():
    lib = seed("seesaw")
    other = renamed(lib, "wod.liberty")
    other.name = "Liberty"
    assert not is_same_workout(lib, other)


def test_same_id_always_matches():
    helen = WorkoutLibrary.definition("wod.helen")
    edited = copy.deepcopy(helen)
    edited.name = "Helen (old)"
    assert is_same_workout(helen, edited)


def test_movement_sequence():
    assert movement_sequence(seed("power_cj_emom"))[:2] == ["station:powerCleanAndJerk", "rest:rest"]


def test_results_newest_first():
    lib = seed("seesaw")
    a = result(renamed(lib, "wod.seesaw"), 2)
    b = result(lib, 9)
    helen = result(WorkoutLibrary.definition("wod.helen"), 5)
    found = results_of(lib, [a, helen, b])
    assert [r.id for r in found] == [b.id, a.id]
    assert latest_of(lib, [a, helen, b]).id == b.id


def test_segment_lines_quantity_first():
    """The preview's "All segments" list uses the card line (WorkoutCard.segmentLine in Swift)."""
    pcj = seed("power_cj_emom")
    assert [movement_line(s).full for s in pcj.segments[:2]] == ["3 Power C&J", "Rest"]
    helen = WorkoutLibrary.definition("wod.helen")
    assert [movement_line(s).full for s in helen.segments[:3]] == ["400 m Run", "21 KB Swings", "12 Pull-ups"]
    seesaw = seed("seesaw")
    assert [movement_line(s).full for s in seesaw.segments[:2]] == ["30 Cal Row", "5 Power Cleans @135 lb"]


def test_library_index_for_calendar_page():
    """#137: which library workout a recorded result opens from the calendar, and its history
    always contains that result."""
    from barpath.workout_history import library_index
    seesaw, pcj = seed("seesaw"), seed("power_cj_emom")
    library = [pcj, seesaw]
    # same id
    assert library_index(seesaw, library) == 1
    # an old id that is no built-in, same workout -> the library row
    assert library_index(renamed(seesaw, "wod.seesaw"), library) == 1
    # a built-in id is never swapped for a library row, even if it looks the same
    helen = WorkoutLibrary.definition("wod.helen")
    assert library_index(helen, library + [renamed(helen, "lib.x.20261101.helen")]) is None
    # Free Workout, a deleted or personal row (not in the library): its own definition
    assert library_index(WorkoutLibrary.free, library) is None
    gone = WorkoutDefinition.from_dict(dict(seesaw.to_dict(), id="lib.gone.20261101.x", name="Deleted"))
    assert library_index(gone, library) is None
    # whichever definition is used, the result is in its history
    for recorded in [seesaw, renamed(seesaw, "wod.seesaw"), helen,
                     WorkoutLibrary.free, gone]:
        r = result(recorded, 10)
        i = library_index(recorded, library)
        page = library[i] if i is not None else recorded
        assert r in results_of(page, [r]), recorded.id
