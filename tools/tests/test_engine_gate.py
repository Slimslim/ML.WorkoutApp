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


def _run_classic(d, script):
    p = rb.start_progress(d, rb.ENGINE_LEGACY)
    rb.run_script(p, script)
    return p


def test_engine_test_workouts_run_every_pass_on_classic():
    """Classic (engine off): the listed-once test workouts are written out first, never one pass."""
    rounds = _run_classic(WorkoutLibrary.engineRounds5, [[0.0, "start"]] + [[30.0 * (k + 1), "crown"] for k in range(16)])
    assert rounds.is_finished and len(rounds.segment_starts) == 15 and rounds.finish_time == 450.0
    emom = _run_classic(WorkoutLibrary.engineEmom, [[0.0, "start"]] + [[60.0 * k + 30, "crown"] for k in range(6)]
                        + [[400.0, "tick"]])
    assert emom.is_finished and len(emom.segment_starts) == 12 and emom.finish_time == 360.0
    tabata = _run_classic(WorkoutLibrary.engineTabata, [[0.0, "start"]] + [[30.0 * k + 20, "crown"] for k in range(8)]
                          + [[300.0, "tick"]])
    assert tabata.is_finished and len(tabata.segment_starts) == 16 and tabata.finish_time == 240.0
    amrap = _run_classic(WorkoutLibrary.engineAmrap, [[0.0, "start"]] + [[40.0 * (k + 1), "crown"] for k in range(11)]
                         + [[500.0, "tick"]])
    assert amrap.finish_time == 480.0 and len(amrap.segment_starts) == 12


@pytest.mark.parametrize("d", WorkoutLibrary.engine_tests, ids=lambda d: d.id)
def test_every_listed_once_interval_test_workout_ends_with_a_rest(d):
    if d.listed_once and d.interval_seconds:
        assert d.segments[-1].kind == "rest", d.id


def test_cards_describe_listed_once_test_workouts_like_written_out_rows():
    from barpath.workout_card import WorkoutCard
    assert WorkoutCard.make(WorkoutLibrary.engineRounds5).time_domain_line == "5 rounds"
    assert WorkoutCard.make(WorkoutLibrary.engineEmom).time_domain_line == "Every 1:00 × 6"
    assert WorkoutCard.make(WorkoutLibrary.engineTabata).time_domain_line == "Every 0:30 × 8"
    for d in WorkoutLibrary.engine_tests:
        assert WorkoutCard.make(d) == WorkoutCard.make(rb.written_out(d)), d.id


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
