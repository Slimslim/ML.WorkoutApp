"""Repeating blocks and fixed lists (WORKOUT_SPEC 5c, #138): tools/barpath/repeat_block.py. The cases
are shared with RepeatBlockTests.swift (Fixtures/repeat_block_cases.json)."""
import json
from pathlib import Path

import pytest

from barpath import repeat_block as rb
from barpath.workout import WorkoutDefinition, WorkoutLibrary, WorkoutProgress

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/repeat_block_cases.json"


def cases():
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize("c", cases(), ids=lambda c: c["name"])
def test_fixture_case(c):
    d = WorkoutDefinition.from_dict(c["definition"])
    plan = rb.plan_for(d)
    expected = dict(c["plan"])
    assert plan.step_limit == expected.pop("stepLimit")
    assert plan.to_dict() == expected
    for step, p, part in c["positions"]:
        assert rb.position(plan, step) == (p, part), step
    for step in c["outOfRange"]:
        with pytest.raises(ValueError):
            rb.position(plan, step)
    for step in c["finishes"]:
        assert rb.advance_finishes(plan, step), step
    for step in c["noFinish"]:
        assert not rb.advance_finishes(plan, step), step
    for step, advanced, elapsed, reason in c["endReasons"]:
        assert rb.end_reason(plan, step, advanced, elapsed) == reason, (step, advanced, elapsed)
    for start, end in c["windowEnds"]:
        assert rb.window_end(plan, start) == pytest.approx(end), start
    if not c["windowEnds"]:
        assert rb.window_end(plan, 10.0) is None
    for step, target in c["windowTargets"]:
        assert rb.window_target_step(plan, step) == target, step
    if not c["windowTargets"]:
        assert rb.window_target_step(plan, 0) is None
    for completed, passes, work in c["scores"]:
        assert rb.score(plan, d, completed) == (passes, work), completed


def test_round_size_plays_no_part():
    """The block is the whole list: roundSize changes nothing in the plan, positions or windows."""
    for c in cases():
        base = WorkoutDefinition.from_dict(c["definition"])
        for rs in (None, 1, 2, len(base.segments)):
            d = WorkoutDefinition.from_dict(dict(c["definition"], roundSize=rs) if rs else
                                            {k: v for k, v in c["definition"].items() if k != "roundSize"})
            assert rb.plan_for(d) == rb.plan_for(base), (c["name"], rs)


def test_undo_crosses_a_pass_boundary():
    assert rb.previous_step(6) == 5     # pass 1 part 0 -> pass 0 last part
    assert rb.previous_step(1) == 0
    assert rb.previous_step(0) is None


def _progress_steps(d: WorkoutDefinition):
    """What today's WorkoutProgress does with Crown advances: steps started and the finishing step."""
    p = WorkoutProgress(d)
    p.start(0.0)
    t = 0.0
    while not p.is_finished:
        t += 10.0
        assert p.advance(t, "crown")
    return len(p.segment_starts), p.current_index


@pytest.mark.parametrize("d", [d for d in WorkoutLibrary.known if rb.plan_for(d).kind == rb.FIXED],
                         ids=lambda d: d.id)
def test_fixed_list_built_ins_step_exactly_as_today(d):
    """Hyrox and every other fixed-list built-in: same steps, same Finish, as WorkoutProgress."""
    plan = rb.plan_for(d)
    started, last = _progress_steps(d)
    assert plan.step_limit == started == len(d.segments)
    for s in range(len(d.segments)):
        assert rb.position(plan, s) == (0, s)
        assert rb.advance_finishes(plan, s) == (s == last)


def test_hyrox_is_a_fixed_list():
    for d in (WorkoutLibrary.hyroxSolo, WorkoutLibrary.hyroxDoubles, WorkoutLibrary.halfHyrox):
        assert rb.plan_for(d).kind == rb.FIXED


def test_rounds_key_round_trips_and_is_optional():
    c = next(c for c in cases() if c["definition"].get("rounds"))
    d = WorkoutDefinition.from_dict(c["definition"])
    assert d.rounds == c["definition"]["rounds"]
    assert WorkoutDefinition.from_dict(d.to_dict()) == d
    old = {k: v for k, v in c["definition"].items() if k != "rounds"}
    assert "rounds" not in WorkoutDefinition.from_dict(old).to_dict()


def test_today_s_interval_rows_keep_their_window():
    """Every interval built-in: the window target equals what WorkoutProgress does today (its
    roundSize is the block), so EMOM / Tabata timing doesn't change."""
    from barpath.workout import WorkoutLibrary
    checked = 0
    for d in WorkoutLibrary.known:
        if not d.interval_seconds or not d.round_size:
            continue
        # Today's rows list their sets out; as a block of one set they must step the same.
        block = WorkoutDefinition.from_dict(dict(d.to_dict(), segments=[s.to_dict() for s in d.segments[:d.round_size]],
                                                 rounds=-(-len(d.segments) // d.round_size)))
        plan = rb.plan_for(block)
        for step in range(len(d.segments) - 1):
            today = (step // d.round_size + 1) * d.round_size
            want = today if today < plan.step_limit else None
            assert rb.window_target_step(plan, step) == want, (d.id, step)
        checked += 1
    assert checked >= 1
