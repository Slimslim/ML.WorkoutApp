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


# Every built-in, by id, as stored today. None is marked listedOnce, so each takes the legacy route.
BUILT_IN_IDS = ["hyrox.solo", "hyrox.doubles", "hyrox.half", "partner.wod1", "partner.wod2", "wod.amrap40",
                "wod.helen", "wod.rowThrusters", "free.workout", "wod.nightmareAmrap", "quick.test"]


def test_the_built_in_list_is_complete():
    assert sorted(d.id for d in WorkoutLibrary.known) == sorted(BUILT_IN_IDS)


@pytest.mark.parametrize("bid", BUILT_IN_IDS)
def test_every_stored_built_in_takes_the_legacy_route(bid):
    d = next(x for x in WorkoutLibrary.known if x.id == bid)
    assert not d.listed_once
    assert rb.plan_for(d).kind == rb.LEGACY
    assert rb.engine_plan(d, rb.ENGINE_V2) is None
    assert rb.engine_plan(d, rb.ENGINE_LEGACY) is None


def _script_for(d: WorkoutDefinition) -> list:
    """A run that crosses every kind of step: Crowns every 37 s, an undo, the clock in between."""
    script = [[0.0, "start"]]
    t = 0.0
    for k in range(len(d.segments) + 4):
        t += 37.0
        script.append([t, "crown"])
        if k == 3:
            script.append([t + 5.0, "undo"])
            t += 5.0
    script.append([t + 4000.0, "tick"])
    return script


@pytest.mark.parametrize("bid", BUILT_IN_IDS)
def test_engine_on_routes_every_stored_built_in_to_today_s_progress(bid):
    """Routing only: a stored built-in never gets a block plan (the E4 gate compares behaviour)."""
    d = next(x for x in WorkoutLibrary.known if x.id == bid)
    assert rb.start_progress(d, rb.ENGINE_V2).block is None


# Marking Row + Thrusters makes another workout: its block does not end with a rest (legacy route).
MARKED_SAME_AS_TODAY = [i for i in BUILT_IN_IDS if i != "wod.rowThrusters"]


@pytest.mark.parametrize("bid", MARKED_SAME_AS_TODAY)
def test_a_built_in_marked_listed_once_runs_exactly_as_today_in_block_mode(bid):
    """Behaviour, not routing: the built-in marked listedOnce and run in block mode with the engine
    on (fixed lists as FIXED, the AMRAPs as REPEAT) gives the same events as the stored row today."""
    import dataclasses
    d = next(x for x in WorkoutLibrary.known if x.id == bid)
    marked = dataclasses.replace(d, listed_once=True)
    on = rb.start_progress(marked, rb.ENGINE_V2)
    assert on.block is not None
    assert on.block.kind in (rb.FIXED, rb.REPEAT)
    for script in (_script_for(d), [[0.0, "start"], [6000.0, "tick"]]):
        today = rb.start_progress(d, rb.ENGINE_LEGACY)
        block = rb.start_progress(marked, rb.ENGINE_V2)
        assert rb.run_script(block, script) == rb.run_script(today, script), bid
        assert block.segment_starts == today.segment_starts and block.finish_time == today.finish_time


def test_row_thrusters_marked_falls_back_to_the_legacy_route():
    import dataclasses
    marked = dataclasses.replace(WorkoutLibrary.rowThrusters, listed_once=True)
    assert rb.listed_once_problems(marked) == ["interval block does not end with a rest"]
    assert rb.start_progress(marked, rb.ENGINE_V2).block is None


def test_row_thrusters_window_targets_are_today_s():
    """The stored row (17 segments, roundSize 3, every 3:00): the clock still jumps by set."""
    d = WorkoutLibrary.rowThrusters
    assert len(d.segments) == 17 and d.round_size == 3
    p = WorkoutProgress(d, rb.engine_plan(d, rb.ENGINE_V2))
    p.start(0.0)
    targets = []
    for i in range(16):
        targets.append(p.auto_advance_target_index())
        p.advance(10.0 * (i + 1), "crown")
    assert targets == [3, 3, 3, 6, 6, 6, 9, 9, 9, 12, 12, 12, 15, 15, 15, 18]   # 18: past the end, finishes


def test_amrap40_score_is_today_s():
    """The stored AMRAP 40 after 12 steps: 2 rounds + 2 work parts (a block plan of the written-out
    list would say 0 passes + 10 parts)."""
    from barpath.workout import amrap_expanded
    d = amrap_expanded(WorkoutLibrary.amrap40)
    assert rb.plan_for(d).kind == rb.LEGACY
    assert divmod(12, d.round_size) == (2, 2)


def test_hyrox_takes_the_legacy_route():
    for d in (WorkoutLibrary.hyroxSolo, WorkoutLibrary.hyroxDoubles, WorkoutLibrary.halfHyrox):
        assert rb.plan_for(d).kind == rb.LEGACY
        assert rb.engine_plan(d, rb.ENGINE_V2) is None


def test_marked_definitions_need_the_engine_switch():
    c = next(c for c in cases() if c["definition"].get("rounds"))
    d = WorkoutDefinition.from_dict(c["definition"])
    assert rb.engine_plan(d, rb.ENGINE_V2).kind == rb.REPEAT
    assert rb.engine_plan(d, rb.ENGINE_LEGACY) is None
    assert rb.engine_plan(d, "anything else") is None


def test_an_interval_block_must_end_with_a_rest():
    c = next(c for c in cases() if c["definition"].get("intervalSeconds"))
    segs = [x for x in c["definition"]["segments"] if x["kind"] != "rest"]
    d = WorkoutDefinition.from_dict(dict(c["definition"], segments=segs))
    assert rb.listed_once_problems(d) == ["interval block does not end with a rest"]
    assert rb.plan_for(d).kind == rb.LEGACY


def test_listed_once_key_round_trips_and_is_optional():
    c = cases()[0]
    d = WorkoutDefinition.from_dict(c["definition"])
    assert d.listed_once and d.to_dict()["listedOnce"] is True
    old = {k: v for k, v in c["definition"].items() if k != "listedOnce"}
    assert "listedOnce" not in WorkoutDefinition.from_dict(old).to_dict()
    assert not WorkoutDefinition.from_dict(dict(old, listedOnce="yes")).listed_once


def test_rounds_key_round_trips_and_is_optional():
    c = next(c for c in cases() if c["definition"].get("rounds"))
    d = WorkoutDefinition.from_dict(c["definition"])
    assert d.rounds == c["definition"]["rounds"]
    assert WorkoutDefinition.from_dict(d.to_dict()) == d
    old = {k: v for k, v in c["definition"].items() if k != "rounds"}
    assert "rounds" not in WorkoutDefinition.from_dict(old).to_dict()


# ---- block mode in WorkoutProgress (shared with RepeatBlockProgressTests.swift) ----------------

PROGRESS = ROOT / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/repeat_block_progress_cases.json"


def progress_cases():
    return json.loads(PROGRESS.read_text(encoding="utf-8"))["cases"]


def test_progress_fixture_is_up_to_date():
    import sys
    sys.path.insert(0, str(ROOT / "tools"))
    import make_repeat_block_progress_cases as gen
    assert gen.main(["--check"]) == 0, "run python3 tools/make_repeat_block_progress_cases.py"


@pytest.mark.parametrize("c", progress_cases(), ids=lambda c: c["name"][:60])
def test_progress_case(c):
    d = WorkoutDefinition.from_dict(c["definition"])
    p = WorkoutProgress(d, rb.engine_plan(d, rb.ENGINE_V2))
    assert rb.run_script(p, c["script"]) == c["events"]
    assert p.is_finished == c["finished"] and p.finish_time == c["finishTime"]
    assert p.current_index == c["currentStep"] and len(p.segment_starts) == c["steps"]


def test_rounds_finish_after_round_n_and_undo_crosses_back():
    c = next(c for c in progress_cases() if c["definition"]["id"] == "p.roundsUnfinish")
    kinds = [e[1] for e in c["events"]]
    assert kinds.count("finish") == 2 and c["steps"] == 4
    amrap = next(c for c in progress_cases() if c["definition"]["id"] == "p.amrapUndo")
    undo = next(e for e in amrap["events"] if e[1] == "undo")
    assert undo[2] == 1          # from pass 1 part 0 back to pass 0 part 1


def test_tabata_is_16_steps_and_4_minutes_on_the_clock():
    for bid in ("p.tabata", "p.tabataCrown"):
        c = next(c for c in progress_cases() if c["definition"]["id"] == bid)
        assert c["steps"] == 16 and c["finishTime"] == 240.0
        starts = [e[0] for e in c["events"] if e[1] in ("start", "advance") and e[2] % 2 == 0]
        assert starts == [30.0 * k for k in range(8)]


def test_crown_in_the_window_wait_is_ignored():
    c = next(c for c in cases() if c["definition"]["id"].startswith("t.") and c["definition"].get("intervalSeconds")
             and c["definition"]["format"] == "emom" and len(c["definition"]["segments"]) == 2)
    d = WorkoutDefinition.from_dict(c["definition"])
    p = WorkoutProgress(d, rb.engine_plan(d, rb.ENGINE_V2))
    p.start(0.0)
    p.advance(15.0, "crown")              # work -> rest (the wait)
    assert p.waiting_for_window
    assert not p.advance(20.0, "crown")   # ignored
    assert p.current_index == 1
    assert p.advance(30.0, "auto")        # the clock moves on
    assert not p.waiting_for_window


def test_block_mode_is_never_on_without_a_plan():
    d = WorkoutLibrary.rowThrusters
    p = WorkoutProgress(d)
    p.start(0.0)
    p.advance(10.0, "crown")
    p.advance(20.0, "crown")
    assert not p.waiting_for_window


# ---- E3: results of block mode (index = step, with pass) ---------------------------------------

def _capped_amrap():
    from barpath.workout import split_stats
    c = next(c for c in progress_cases() if c["definition"]["id"] == "p.amrapUndo")
    d = WorkoutDefinition.from_dict(c["definition"])
    p = WorkoutProgress(d, rb.engine_plan(d, rb.ENGINE_V2))
    rb.run_script(p, c["script"])
    return d, p, split_stats(p, p.finish_time, [], [])


def test_block_splits_store_steps_with_pass_and_part():
    d, p, segs = _capped_amrap()
    assert [s.index for s in segs] == [0, 1, 2, 3]
    assert [s.pass_ for s in segs] == [0, 0, 1, 1]
    assert [s.movement for s in segs] == ["burpees", "airSquats", "burpees", "airSquats"]
    assert segs[0].to_dict()["pass"] == 0


def test_block_result_display_definition_and_round_trip():
    from datetime import datetime, timezone
    from barpath.workout import WorkoutResult
    d, p, segs = _capped_amrap()
    t0 = datetime.fromtimestamp(p.start_time, tz=timezone.utc)
    r = WorkoutResult(d, t0, t0, t0, 300.0, segs, p.events, engine="new", passes=2)
    assert r.is_block_result and r.definition_segment(3).movement == "airSquats"
    shown = r.display_definition
    assert len(shown.segments) == 4 and shown.round_size == 2 and not shown.listed_once
    back = WorkoutResult.from_dict(r.to_dict())
    assert back.passes == 2 and [s.pass_ for s in back.segments] == [0, 0, 1, 1]


def test_today_s_results_have_no_pass_and_show_their_definition():
    from barpath.workout import split_stats
    p = WorkoutProgress(WorkoutLibrary.helen)
    p.start(0.0)
    p.advance(60.0, "crown")
    segs = split_stats(p, 90.0, [], [])
    assert all(s.pass_ is None for s in segs) and "pass" not in segs[0].to_dict()


def test_block_result_partial_reps_limit_is_the_part_target():
    from datetime import datetime, timezone
    from barpath.workout import WorkoutResult
    d, p, segs = _capped_amrap()
    t0 = datetime.fromtimestamp(p.start_time, tz=timezone.utc)
    r = WorkoutResult(d, t0, t0, t0, 300.0, segs, p.events, passes=2)
    assert r.partial_reps_limit == 20


# ---- Classic route for listed-once definitions (written out like today's rows) ------------------

def _case(cid):
    return WorkoutDefinition.from_dict(next(c for c in cases() if c["definition"]["id"] == cid)["definition"])


@pytest.mark.parametrize("cid,segments,round_size", [
    ("t.ladder", 6, 6),          # AMRAP: unmarked with roundSize = P; the 5a expansion at START
    ("t.every3", 18, 3),         # Every 3:00 x 6: six windows, the last keeps its rest
    ("t.tabata", 16, 2),         # Tabata 8 x 30 s: 16 segments
    ("t.rft", 15, 3),            # Rounds for time x 5
    ("t.roundsRest", 8, 3),      # x 3 with a rest after each round: none after the last
    ("t.fixed", 4, 2),           # a marked fixed list: unchanged except the mark (its roundSize kept)
])
def test_classic_writes_a_listed_once_block_out(cid, segments, round_size):
    d = _case(cid)
    out = rb.written_out(d)
    assert len(out.segments) == segments and out.round_size == round_size
    assert not out.listed_once and out.rounds is None
    assert rb.written_out(out) == out                      # unmarked: unchanged


def test_classic_runs_every_pass_not_one():
    """The #138 bug must not come back on Classic: rounds x 5 finishes after the 15th part, an
    AMRAP repeats until its cap, a Tabata runs its 8 windows."""
    rounds = rb.start_progress(_case("t.rft"), rb.ENGINE_LEGACY)
    rb.run_script(rounds, [[0.0, "start"]] + [[30.0 * (k + 1), "crown"] for k in range(16)])
    assert rounds.is_finished and len(rounds.segment_starts) == 15 and rounds.finish_time == 450.0
    amrap = rb.start_progress(_case("t.ladder"), rb.ENGINE_LEGACY)
    rb.run_script(amrap, [[0.0, "start"]] + [[60.0 * (k + 1), "crown"] for k in range(20)] + [[2000.0, "tick"]])
    assert amrap.finish_time == 1440.0 and len(amrap.segment_starts) == 21
    tabata = rb.start_progress(_case("t.tabata"), rb.ENGINE_LEGACY)
    rb.run_script(tabata, [[0.0, "start"]] + [[30.0 * k + 20, "crown"] for k in range(8)] + [[300.0, "tick"]])
    assert tabata.is_finished and len(tabata.segment_starts) == 16


def test_insights_of_a_block_result_use_its_parts():
    from datetime import datetime, timezone
    from barpath.result_insights import insights
    from barpath.workout import WorkoutResult
    d, p, segs = _capped_amrap()
    t0 = datetime.fromtimestamp(p.start_time, tz=timezone.utc)
    r = WorkoutResult(d, t0, t0, t0, 300.0, segs, p.events, passes=2)
    assert insights(r) == insights(r, r.display_definition)


def test_marked_amrap_with_an_interval_keeps_round_size_unset():
    import dataclasses
    d = dataclasses.replace(_case("t.ladder"), interval_seconds=60.0)
    assert rb.written_out(d).round_size is None


def test_marked_row_thrusters_is_written_out_on_the_fallback():
    import dataclasses
    marked = dataclasses.replace(WorkoutLibrary.rowThrusters, listed_once=True)
    p = rb.start_progress(marked, rb.ENGINE_V2)
    assert p.block is None and len(p.definition.segments) == 6 * 17 and p.definition.round_size == 17


def test_a_marked_fixed_list_stores_today_s_result_on_the_new_engine():
    import dataclasses
    from barpath.workout import split_stats
    marked = dataclasses.replace(WorkoutLibrary.hyroxSolo, listed_once=True)
    on_new = rb.start_progress(marked, rb.ENGINE_V2)
    classic = rb.start_progress(WorkoutLibrary.hyroxSolo, rb.ENGINE_LEGACY)
    assert on_new.block.kind == rb.FIXED and not on_new.is_repeating_block
    for p in (on_new, classic):
        p.start(0.0)
        for k in range(1, 6):
            p.advance(60.0 * k, "crown")
    assert on_new.passes_started is None and on_new.part_index(5) == 5
    a = [s.to_dict() for s in split_stats(on_new, 400.0, [], [])]
    b = [s.to_dict() for s in split_stats(classic, 400.0, [], [])]
    assert a == b and all("pass" not in s for s in a)


def test_part_index_and_passes_of_a_repeating_block():
    d, p, segs = _capped_amrap()
    assert p.is_repeating_block and p.part_index(3) == 1 and p.passes_started == 2


def _block_result(cid, crowns):
    from datetime import datetime, timezone
    from barpath.workout import WorkoutResult, split_stats
    d = _case(cid)
    p = rb.start_progress(d, rb.ENGINE_V2)
    rb.run_script(p, [[0.0, "start"]] + [[20.0 * (k + 1), "crown"] for k in range(crowns)] + [[20.0 * crowns + 1, "end"]])
    t0 = datetime.fromtimestamp(0, tz=timezone.utc)
    return WorkoutResult(d, t0, t0, t0, 100.0, split_stats(p, p.finish_time, [], []), p.events,
                         passes=p.passes_started)


def test_planned_rounds_and_sets_show_as_planned_not_as_done():
    emom = _block_result("t.every3", 4)            # Every 3:00 x 6, ended in window 1 or 2
    assert len(emom.display_definition.segments) == 18 and emom.display_definition.round_size == 3
    rft = _block_result("t.rft", 8)                # 5 rounds for time, ended in round 3
    assert len(rft.display_definition.segments) == 15
    amrap = _block_result("t.ladder", 8)           # AMRAP: no planned length, the steps done
    assert len(amrap.display_definition.segments) == 9    # 8 Crowns: steps 0..8
    assert rb.planned_steps(_case("t.ladder")) is None and rb.planned_steps(_case("t.every3")) == 18


def test_a_marked_fixed_list_with_an_interval_keeps_today_s_path():
    import dataclasses
    d = dataclasses.replace(_case("t.fixed"), interval_seconds=60.0)
    assert rb.plan_for(d).kind == rb.LEGACY and rb.start_progress(d, rb.ENGINE_V2).block is None
