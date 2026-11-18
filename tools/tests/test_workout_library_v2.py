"""#70: make_row.py writes schemaVersion 2 rows to workout_library_v2; the legacy copy is only
for exact rows; the database's schema copy equals schemas/workout-definition.v2.schema.json.

The SQL side (RLS, schema refusal in the database, the legacy-copy trigger, revisions, paging, the
29 published rows untouched, rollback) is tested by supabase/tests/run.sh in CI.
"""
import json
import re
import sys
from pathlib import Path

import pytest

pytest.importorskip("jsonschema")

from barpath.workout import WorkoutDefinition

TOOLS = Path(__file__).resolve().parent.parent
REPO = TOOLS.parent
sys.path.insert(0, str(TOOLS / "library"))
import make_row  # noqa: E402

FIXTURES = TOOLS / "library" / "fixtures" / "v2"
SCHEMA = REPO / "schemas" / "workout-definition.v2.schema.json"
MIGRATIONS = REPO / "supabase" / "migrations"
EXACT = {"exact_emom.json", "exact_personal.json", "scales_all_exact.json"}


def valid_files():
    return sorted((FIXTURES / "valid").glob("*.json"))


def invalid_files():
    return sorted((FIXTURES / "invalid").glob("*.json"))


def definition_of(path):
    raw = json.loads(path.read_text(encoding="utf-8"))
    return raw.get("definition", raw)


def sql_json_literal(sql: str) -> dict:
    """The definition JSON inside make_row_v2's SQL."""
    m = re.search(r"values \('[^']*', '((?:[^']|'')*)'::jsonb", sql)
    assert m, sql
    return json.loads(m.group(1).replace("''", "'"))


def test_migration_schema_copy_equals_the_repo_file():
    """RFC 7.2.3: the schema in the newest migration that defines it equals the repo file."""
    defining = [p for p in sorted(MIGRATIONS.glob("*.sql"))
                if "function public.workout_definition_v2_schema()" in p.read_text(encoding="utf-8")]
    assert defining, "no migration defines public.workout_definition_v2_schema()"
    text = defining[-1].read_text(encoding="utf-8")
    m = re.search(r"\$schema\$(.*?)\$schema\$", text, re.S)
    assert m, f"{defining[-1].name}: no $schema$ ... $schema$ block"
    assert json.loads(m.group(1)) == json.loads(SCHEMA.read_text(encoding="utf-8")), (
        f"{defining[-1].name} has a different schema than {SCHEMA.relative_to(REPO)}: "
        "a schema change needs a new migration that replaces the function")


def test_fixtures_exist():
    assert len(valid_files()) >= 5 and len(invalid_files()) >= 5


@pytest.mark.parametrize("path", valid_files(), ids=lambda p: p.name)
def test_valid_fixture_is_accepted(path):
    raw = json.loads(path.read_text(encoding="utf-8"))
    d = definition_of(path)
    assert make_row.is_v2(d)
    make_row.validate_v2(d, raw.get("owner"))


@pytest.mark.parametrize("path", invalid_files(), ids=lambda p: p.name)
def test_invalid_fixture_is_refused(path):
    with pytest.raises(make_row.LibraryError):
        make_row.validate_v2(definition_of(path))


@pytest.mark.parametrize("path", valid_files(), ids=lambda p: p.name)
def test_legacy_copy_only_for_exact(path):
    d = definition_of(path)
    copy = make_row.legacy_copy(d)
    if path.name in EXACT:
        assert copy is not None
        assert set(copy) <= set(make_row.LEGACY_KEYS)
        # What builds 15/16 receive decodes as today's WorkoutDefinition and round-trips.
        assert WorkoutDefinition.from_dict(copy).to_dict() == copy
        assert copy["segments"] == d["segments"]
    else:
        assert copy is None


def test_one_inexact_scale_means_no_copy():
    d = definition_of(FIXTURES / "valid" / "scales_mixed.json")
    assert [s["fidelity"] for s in d["scales"]] == ["exact", "approx"]
    assert make_row.legacy_copy(d) is None
    d2 = json.loads(json.dumps(d))
    d2["scales"][1]["fidelity"] = "exact"
    assert make_row.legacy_copy(d2) is not None
    d2["scales"] = []
    assert make_row.legacy_copy(d2) is None


def test_v2_rows_go_to_the_v2_table_only(capsys):
    assert make_row.main([str(p) for p in valid_files()]) == 0
    out = capsys.readouterr().out
    assert out.count("insert into public.workout_library_v2 ") == len(valid_files())
    assert "insert into public.workout_library " not in out
    assert "insert into public.workout_library (" not in out


def test_v2_sql_passes_unknown_fields_through():
    path = FIXTURES / "valid" / "future_fields.json"
    raw = json.loads(path.read_text(encoding="utf-8"))
    d = make_row.validate_v2(raw["definition"])
    sql = make_row.make_row_v2(d, raw["program"], raw["scheduled_on"])
    assert sql_json_literal(sql) == raw["definition"]
    stored = sql_json_literal(sql)
    assert stored["structure"]["body"][1]["repeat"]["resume"] == "min"
    assert stored["structure"]["body"][1]["repeat"]["body"][0]["part"]["interrupt"]["every"] == 240
    assert stored["x-futureRoot"] == {"anything": [1, 2.5, "three", None]}


def test_v2_personal_row_needs_the_owner_suffix():
    raw = json.loads((FIXTURES / "valid" / "exact_personal.json").read_text(encoding="utf-8"))
    d = raw["definition"]
    sql = make_row.make_row_v2(make_row.validate_v2(d, raw["owner"]), "Mine", None, owner=raw["owner"])
    assert "where public.workout_library_v2.owner = excluded.owner" in sql
    with pytest.raises(make_row.LibraryError, match="needs an id ending"):
        make_row.validate_v2(d, "12345678-0000-4000-8000-000000000000")
    with pytest.raises(make_row.LibraryError, match="owner or a gym"):
        make_row.make_row_v2(d, None, None, gym="test-gym", owner=raw["owner"])


def test_v2_public_upsert_never_overwrites_a_personal_row():
    d = definition_of(FIXTURES / "valid" / "exact_emom.json")
    assert "where public.workout_library_v2.owner is null" in make_row.make_row_v2(d, None, None)


def test_v2_old_keys_must_still_decode():
    d = definition_of(FIXTURES / "valid" / "exact_emom.json")
    bad = json.loads(json.dumps(d))
    bad["id"] = "wod.helen"
    with pytest.raises(make_row.LibraryError):
        make_row.validate_v2(bad)
    bad = json.loads(json.dumps(d))
    bad["roundSize"] = 99
    with pytest.raises(make_row.LibraryError, match="roundSize"):
        make_row.validate_v2(bad)


def test_main_refuses_an_invalid_v2_file(capsys):
    assert make_row.main([str(FIXTURES / "invalid" / "bad_late.json")]) == 1
    assert "late" in capsys.readouterr().err


def test_sql_legacy_keys_match_python():
    """public.workout_v2_legacy_definition keeps exactly make_row.LEGACY_KEYS."""
    text = (MIGRATIONS / "20261118000100_workout_library_v2.sql").read_text(encoding="utf-8")
    m = re.search(r"where e\.key in \(([^)]*)\)", text)
    assert m
    keys = tuple(k.strip().strip("'") for k in m.group(1).replace("\n", " ").split(","))
    assert keys == make_row.LEGACY_KEYS
