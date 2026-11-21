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
    """The routing fixture only (off == on). Today's behaviour is pinned by the 0.17.2 golden below."""
    assert gate.main(["--check-fixture"]) == 0, (
        "routing fixture stale: if only scripts or rows changed, run python3 tools/engine_gate.py "
        "--write-fixture; if `expected` changed, today's rows run differently (see the golden test)")


def test_every_row_runs_exactly_as_0_17_2_on_both_engines():
    """Behaviour, not routing: the full trace (events, step starts, finish, every split field) of
    every built-in and gate row under every script, written by running the v0.17.2 code itself."""
    golden = json.loads(gate.GOLDEN.read_text(encoding="utf-8"))
    assert golden["ref"] == gate.GOLDEN_REF
    ids = {c["name"] for c in golden["cases"]}
    assert {d.id for d in WorkoutLibrary.known} <= ids
    assert all(len(c["traces"]) == len(c["scripts"]) == 7 for c in golden["cases"])
    diffs = gate.golden_diffs(golden)
    assert diffs == [], (
        "Today's rows (Hyrox included) run differently from 0.17.2. Do NOT regenerate the golden to "
        "get green: this needs the owner's sign-off. First differences: %s" % diffs[:5])


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


def _case_by_id(cid):
    return next(c for c in _cases() if c["definition"]["id"] == cid)


def test_export_prints_aggregates_and_ids_only_on_request(tmp_path, capsys):
    rows = [{"id": "lib.invented.a", "definition": c["definition"]} for c in _cases()[:3]]
    marked = dict(_case_by_id("gate.amrapOne")["definition"], listedOnce=True)
    rows.append({"id": "lib.invented.marked", "definition": marked})
    p = tmp_path / "rows.json"
    p.write_text(json.dumps(rows))
    assert gate.main(["--export", str(p)]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out == {"rows": 4, "checked": 4, "unreadable": 0, "markedListedOnce": 1, "differing": 0,
                   "differingIds": []}
    assert "lib.invented" not in json.dumps(out)


def test_export_fails_when_a_row_is_unreadable_or_nothing_was_checked(tmp_path, capsys):
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps([{"id": "lib.invented.a", "definition": _cases()[0]["definition"]},
                               {"id": "lib.invented.bad", "definition": {"segments": "x"}}]))
    assert gate.main(["--export", str(bad)]) == 1
    empty = tmp_path / "empty.json"
    empty.write_text("[]")
    assert gate.main(["--export", str(empty)]) == 1
    wrong = tmp_path / "wrong.json"
    wrong.write_text(json.dumps({"rows": []}))
    with pytest.raises(SystemExit):
        gate.main(["--export", str(wrong)])
    capsys.readouterr()
