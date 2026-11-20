"""E4 (0.18) engine gate (tools/engine_gate.py): every built-in and every fixed-list fixture row runs
identically with the workout engine off and on. CI fails on any difference."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import engine_gate as gate  # noqa: E402
from barpath import repeat_block as rb  # noqa: E402
from barpath.workout import WorkoutDefinition, WorkoutLibrary  # noqa: E402


def test_fixture_is_up_to_date():
    assert gate.main(["--check-fixture"]) == 0, "run python3 tools/engine_gate.py --write-fixture"


@pytest.mark.parametrize("d", WorkoutLibrary.known, ids=lambda d: d.id)
def test_every_built_in_is_identical_with_the_engine_on(d):
    assert rb.plan_for(d).kind == rb.LEGACY
    assert gate.compare(d) == []
    for s in gate.scripts(d):
        assert not gate.run(d, rb.ENGINE_V2, s)["block"]


def _cases():
    return json.loads(gate.FIXTURE.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("c", _cases(), ids=lambda c: c["name"][:50])
def test_every_fixed_list_row_is_identical_with_the_engine_on(c):
    d = WorkoutDefinition.from_dict(c["definition"])
    assert gate.compare(d) == []
    for script, want in zip(c["scripts"], c["expected"]):
        got = gate.run(d, rb.ENGINE_V2, script)
        assert got["events"] == want["events"] and got["finish"] == want["finish"]
        assert len(got["starts"]) == want["steps"]


def test_the_gate_catches_a_difference():
    """A row marked listedOnce takes block mode with the engine on, so the gate must see it."""
    c = next(c for c in _cases() if c["definition"]["id"] == "gate.amrapOne")
    d = WorkoutDefinition.from_dict(dict(c["definition"], listedOnce=True))
    assert gate.compare(d) != []


def test_export_prints_aggregates_and_ids_only_on_request(tmp_path, capsys):
    rows = [{"id": "lib.invented.a", "definition": c["definition"]} for c in _cases()[:3]]
    rows.append({"id": "lib.invented.bad", "definition": {"segments": "x"}})
    marked = dict(_cases()[8]["definition"], listedOnce=True)
    rows.append({"id": "lib.invented.marked", "definition": marked})
    p = tmp_path / "rows.json"
    p.write_text(json.dumps(rows))
    assert gate.main(["--export", str(p)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"rows": 5, "checked": 4, "unreadable": 1, "markedListedOnce": 1, "differing": 0,
                   "differingIds": []}
    assert "lib.invented" not in json.dumps(out)
