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


# ---- E5: engine test workouts ------------------------------------------------------------------

ENGINE_TEST_IDS = ["engine.amrap", "engine.emom", "engine.tabata", "engine.rounds5", "engine.hyroxSim"]


def test_engine_tests_resolve_but_stay_off_the_grid_and_known():
    assert [d.id for d in WorkoutLibrary.engine_tests] == ENGINE_TEST_IDS
    for i in ENGINE_TEST_IDS:
        assert WorkoutLibrary.definition(i) is not None
        assert i not in {d.id for d in WorkoutLibrary.known}


@pytest.mark.parametrize("d", [d for d in WorkoutLibrary.engine_tests if d.listed_once], ids=lambda d: d.id)
def test_listed_once_test_workouts_run_as_a_block_with_the_engine_on(d):
    assert rb.listed_once_problems(d) == []
    assert rb.plan_for(d).kind == rb.REPEAT
    assert rb.start_progress(d, rb.ENGINE_V2).block is not None
    assert rb.start_progress(d, rb.ENGINE_LEGACY).block is None


def test_hyrox_simulation_is_a_fixed_list_identical_with_the_engine_on():
    d = WorkoutLibrary.engineHyroxSim
    assert not d.listed_once and rb.plan_for(d).kind == rb.LEGACY
    assert gate.compare(d) == []


def _run_on(d, script):
    p = rb.start_progress(d, rb.ENGINE_V2)
    rb.run_script(p, script)
    return p


def test_engine_test_workouts_end_as_designed():
    tabata = _run_on(WorkoutLibrary.engineTabata, [[0.0, "start"], [300.0, "tick"]])
    assert len(tabata.segment_starts) == 16 and tabata.finish_time == 240.0
    emom = _run_on(WorkoutLibrary.engineEmom, [[0.0, "start"]] + [[60.0 * k + 30, "crown"] for k in range(6)]
                   + [[400.0, "tick"]])
    assert len(emom.segment_starts) == 12 and emom.finish_time == 360.0
    rounds = _run_on(WorkoutLibrary.engineRounds5, [[0.0, "start"]] + [[30.0 * (k + 1), "crown"] for k in range(15)])
    assert len(rounds.segment_starts) == 15 and rounds.finish_time == 450.0
    amrap = _run_on(WorkoutLibrary.engineAmrap, [[0.0, "start"]] + [[40.0 * (k + 1), "crown"] for k in range(11)]
                    + [[500.0, "tick"]])
    assert amrap.finish_time == 480.0 and len(amrap.segment_starts) == 12   # 4 passes, still going at the cap
