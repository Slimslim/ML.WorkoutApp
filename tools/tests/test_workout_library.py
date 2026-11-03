"""tools/library/make_row.py: validation of library workouts and the SQL it prints."""
import json
import sys
from pathlib import Path

import pytest

from barpath.workout import WorkoutDefinition, WorkoutLibrary

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS / "library"))
import make_row  # noqa: E402

SEED = TOOLS / "library" / "seed"


def seed_files():
    return sorted(SEED.glob("*.json"))


def test_json_round_trip_of_every_built_in():
    for d in WorkoutLibrary.known:
        again = WorkoutDefinition.from_json(d.to_json())
        assert again == d
        assert json.loads(d.to_json()) == d.to_dict()


def test_seed_files_validate():
    files = seed_files()
    assert len(files) >= 2
    ids = set()
    for f in files:
        d, program, day, published = make_row.load_file(f)
        definition = make_row.validate_definition(d)
        assert definition.id.startswith("lib.")
        assert WorkoutLibrary.definition(definition.id) is None
        assert program and day and published
        ids.add(definition.id)
    assert len(ids) == len(files)


def test_seed_definitions():
    by_id = {}
    for f in seed_files():
        d, _, _, _ = make_row.load_file(f)
        definition = make_row.validate_definition(d)
        by_id[definition.id] = definition
    freedom = by_id["lib.pitfire.20261102.freedom"]
    assert freedom.format == "forTime" and freedom.time_cap_seconds == 1200
    assert [s.target.value for s in freedom.segments if s.movement == "row"] == [40, 30, 20, 30, 40]
    cleans = [s for s in freedom.segments if s.movement == "powerCleans"]
    assert len(cleans) == 5 and all(s.target.value == 7 and s.load.value == 155 and s.load.unit == "lb"
                                    for s in cleans)
    emom = by_id["lib.pitfire.20261102.pcj-emom"]
    assert emom.format == "emom" and emom.interval_seconds == 60 and emom.round_size == 2
    assert len(emom.segments) == 15
    assert sum(1 for s in emom.segments if s.kind == "station" and s.target.value == 2) == 8
    assert [s.kind for s in emom.segments[:2]] == ["station", "rest"]


def test_seed_sql_is_up_to_date(capsys):
    # Paths in the comments are relative to the repo root, as in the regenerate command.
    import os
    here = os.getcwd()
    try:
        os.chdir(TOOLS.parent)
        capsys.readouterr()
        assert make_row.main([str(f.relative_to(TOOLS.parent)) for f in seed_files()]) == 0
        out = capsys.readouterr().out
    finally:
        os.chdir(here)
    assert out == (SEED / "seed.sql").read_text(encoding="utf-8"), \
        "regenerate: python3 tools/library/make_row.py tools/library/seed/*.json > tools/library/seed/seed.sql"


def base():
    return WorkoutLibrary.helen.to_dict() | {"id": "lib.benchmark.20261110.helen"}


def test_rejects_built_in_and_bad_ids():
    with pytest.raises(make_row.LibraryError, match="built-in"):
        make_row.validate_definition(dict(base(), id="wod.helen"))
    for bad in ("helen", "lib.", "lib.Mayhem.20261110.x", "lib.only", "lib.a b.c"):
        with pytest.raises(make_row.LibraryError):
            make_row.validate_definition(dict(base(), id=bad))
    make_row.validate_definition(base())


def test_rejects_unknown_and_missing_keys():
    with pytest.raises(make_row.LibraryError, match="unknown keys timecapSeconds"):
        make_row.validate_definition(dict(base(), timecapSeconds=600))
    d = base()
    d["segments"] = [dict(s) for s in d["segments"]]
    d["segments"][1]["load"] = {"value": 24, "unit": "kg"}   # Swift needs "count"
    with pytest.raises(make_row.LibraryError, match="missing keys"):
        make_row.validate_definition(d)
    d = base()
    del d["shortName"]
    with pytest.raises(make_row.LibraryError, match="does not decode"):
        make_row.validate_definition(d)


def test_rejects_bad_values():
    for change in ({"format": "forTme"}, {"team": "pairs"}, {"segments": []}, {"roundSize": 99},
                   {"intervalSeconds": 0}):
        with pytest.raises(make_row.LibraryError):
            make_row.validate_definition(dict(base(), **change))
    d = base()
    d["segments"] = [dict(d["segments"][0], kind="sprint")] + d["segments"][1:]
    with pytest.raises(make_row.LibraryError, match="kind"):
        make_row.validate_definition(d)


def test_sql_quotes_and_upserts():
    d = dict(base(), name="Murph's day")
    sql = make_row.make_row(make_row.validate_definition(d), "Blue Republic", "2026-11-10")
    assert "Murph''s day" in sql
    assert "on conflict (id) do update" in sql
    assert "'2026-11-10'::date" in sql
    sql = make_row.make_row(make_row.validate_definition(d), None, None, published=False)
    assert ", null, null, false)" in sql
    with pytest.raises(make_row.LibraryError):
        make_row.make_row(make_row.validate_definition(d), "X", "11/10/2026")


def test_builtin_option(capsys):
    assert make_row.main(["--builtin", "wod.helen", "--id", "lib.benchmark.20261110.helen",
                          "--program", "Benchmark", "--date", "2026-11-10"]) == 0
    out = capsys.readouterr().out
    assert "'lib.benchmark.20261110.helen'" in out and "'Benchmark'" in out
    assert make_row.main(["--builtin", "wod.helen"]) == 1
