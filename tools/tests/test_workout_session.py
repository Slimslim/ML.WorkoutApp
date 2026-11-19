"""The watch session on the engine (workout_session.py): routing, events, checkpoint, views, CSV."""
import json

import pytest

from barpath import workout_csv as wc
from barpath import workout_engine as we
from barpath import workout_session as wss
from barpath import workout_structure as ws
from barpath.workout_upgrade import upgrade
from engine_cases import ALL
from upgrade_cases import ALL as LEGACY
import workout_fixture_gen as gen

S = 1000


def _plan(name):
    return we.plan(ws.compile_definition(ALL[name]))


def _run(name, spec):
    p = _plan(name)
    st, eff = we.run(p, gen.expand_events(spec))
    return p, st, eff


# ---- routing ------------------------------------------------------------------------------------

@pytest.mark.parametrize("name", sorted(LEGACY))
def test_every_legacy_row_keeps_the_old_path(name):
    assert wss.route(LEGACY[name]) == {"route": "legacy"}


@pytest.mark.parametrize("name", sorted(ALL))
def test_every_v2_case_runs_on_the_engine(name):
    assert wss.route(ws.compile_definition(ALL[name])) == {"route": "engine"}


def test_upgraded_rows_carry_v2_and_route_by_what_the_engine_says():
    for name, old in LEGACY.items():
        doc = upgrade(old)["definition"]
        r = wss.route(doc)
        try:
            we.plan(doc)
            assert r == {"route": "engine"}, name
        except we.NotRunnable:
            assert r["route"] in ("refused", "legacy"), name


def test_refusals_never_fall_back_silently():
    hy = ws.compile_definition(ALL["hyrox"])
    unknown = dict(hy, requires=["teleport"])
    assert wss.route(unknown) == {"route": "refused", "reason": "updateApp", "missing": ["teleport"]}
    # Old keys only when the definition says they are exact (RFC 14.3 A4).
    assert wss.route(dict(unknown, fidelity="exact"))["route"] == "legacy"
    assert wss.route(dict(unknown, fidelity="approx"))["route"] == "refused"
    assert wss.route(dict(hy, schemaVersion=0))["reason"] == "draft"
    assert wss.route({"schemaVersion": 2, "structure": None})["reason"] == "invalid"
    assert wss.route({"schemaVersion": 2, "structure": {"body": [{"repeat": {"id": "r", "times": 401,
                      "body": [{"part": {"id": "a", "movement": "x", "target": {"value": 1, "unit": "reps"}}}]}}]}}
                     )["reason"] == "tooLarge"


# ---- events -------------------------------------------------------------------------------------

def test_event_times_are_clamped_and_unknown_keys_kept():
    e = wss.decode_event({"kind": "crown", "t": 9.3e18, "began": -4, "x": {"y": 1}})
    assert e == {"kind": "crown", "t": wss.MAX_EVENT_MS, "began": 0, "x": {"y": 1}}
    assert wss.decode_event({"kind": "undo", "t": float("nan")})["t"] == 0
    assert wss.decode_event({"kind": "undo", "t": float("inf")})["t"] == 0
    assert wss.decode_event({"t": True}) == {"kind": "", "t": 0}
    assert wss.MAX_EVENT_MS + 86400 * S < 2 ** 31          # fits a 32-bit Int with a bell added


def test_decoding_is_idempotent():
    for raw in gen.SESSION_EVENTS:
        once = wss.decode_event(raw)
        assert wss.decode_event(once) == once


# ---- checkpoint ---------------------------------------------------------------------------------

def _checkpoint(name, scen, saved):
    doc = ws.compile_definition(ALL[name])
    p = we.plan(doc)
    evs = gen.expand_events(gen.SCENARIOS[name][scen])
    live, _ = we.run(p, [e for e in evs if e["t"] <= saved])
    return doc, p, live, wss.make_checkpoint(doc, p, live, 1795000000000, saved, watch={"hr": [[1.5, 120]]})


def test_checkpoint_text_round_trips_byte_for_byte():
    _, _, _, cp = _checkpoint("windows3334", "gymTruth", 545 * S)
    text = wss.checkpoint_text(cp)
    assert wss.checkpoint_text(json.loads(text)) == text
    assert json.loads(text)["planHash"] == we.plan(cp["definition"]).hash


def test_recovery_replays_only_up_to_the_checkpoint():
    # An EMOM checkpoint at 3:25 must not invent the minutes after it (RFC 14.3 E6).
    doc, p, live, cp = _checkpoint("emom", "minute7Failed", 205 * S)
    rec = wss.recover(json.loads(wss.checkpoint_text(cp)))
    assert rec["status"] == "ok"
    st = rec["state"]
    assert st.now == 205 * S and not st.done
    assert wss.project(st) == wss.project(live)
    assert we.facts(st) == we.facts(live)


def test_recovery_refuses_what_it_cannot_replay():
    _, _, _, cp = _checkpoint("tabata", "noCrown", 30 * S)
    assert wss.recover(dict(cp, version=2))["reason"] == "version"
    assert wss.recover(dict(cp, version=True))["reason"] == "version"
    assert wss.recover(dict(cp, planHash="0"))["reason"] == "planChanged"
    assert wss.recover(dict(cp, definition=dict(cp["definition"], requires=["teleport"])))["reason"] == "updateApp"
    assert wss.recover(dict(cp, definition="x"))["reason"] == "invalid"
    assert wss.recover(None)["reason"] == "version"


# ---- views --------------------------------------------------------------------------------------

def test_projection_of_hyrox_is_the_old_segment_list():
    doc = ws.compile_definition(ALL["hyrox"])
    p = we.plan(doc)
    st, _ = we.run(p, gen.expand_events(gen.SCENARIOS["hyrox"]["race"]))
    pr = wss.project(st)
    assert pr["segments"] == doc["segments"]
    assert pr["starts"] == [240 * S * k for k in range(16)]
    assert pr["sources"] == ["crown"] * 15
    assert pr["finish"] == 16 * 240 * S and pr["finishSource"] == "crown"


def test_projection_after_end_is_not_a_finish():
    _, st, _ = _run("hyrox", gen.SCENARIOS["hyrox"]["endEarly"])
    pr = wss.project(st)
    assert st.done and st.ended_by == "end"
    assert pr["finish"] is None and len(pr["starts"]) == 2


def test_tabata_runs_on_the_clock_and_the_timer_counts_down_to_each_bell():
    p = _plan("tabata")
    st, _ = we.run(p, gen.expand_events(gen.ticked(1000, 5 * S)))
    assert wss.next_bell(st) == {"t": 20 * S, "finish": False}
    st, _ = we.run(p, gen.expand_events(gen.ticked(1000, 25 * S)))
    assert wss.next_bell(st) == {"t": 30 * S, "finish": False}
    st, _ = we.run(p, gen.expand_events(gen.SCENARIOS["tabata"]["noCrown"]))
    pr = wss.project(st)
    assert len(pr["starts"]) == 16 and pr["starts"][:4] == [0, 20 * S, 30 * S, 50 * S]
    assert pr["finish"] == 240 * S and pr["finishSource"] == "auto"
    assert set(pr["sources"]) == {"auto"}


def test_a_hard_cap_counts_up_like_todays_amrap():
    p = _plan("hardCap")
    st, _ = we.run(p, gen.expand_events(gen.ticked(1000, 10 * S)))
    assert wss.next_bell(st)["finish"] is True


def test_only_the_latest_reps_question_is_shown():
    _, st, _ = _run("amrapShort", gen.SCENARIOS["amrapShort"]["lateCrownMovesTheCut"])
    assert wss.latest_ask(st) == st.asks[-1]
    assert wss.latest_ask(we.initial(_plan("tabata"))) is None


def test_crown_in_a_clocked_rest_outside_a_window_ends_it_early():
    """Owner decision (W27 PR3): as today."""
    p, st, _ = _run("intervals", gen.SCENARIOS["intervals"]["crownEndsRest"])
    rest = next(s for s in st.steps if s.kind == "rest")
    r = st.rec[rest.index]
    assert r["endedBy"] == "athlete" and r["end"] == 90 * S
    assert wss.project(st)["starts"][:3] == [0, 58 * S, 90 * S]


def test_crown_in_a_rest_inside_a_window_is_ignored():
    p = _plan("tabata")
    st, _ = we.run(p, gen.expand_events(gen.ticked(500, 26 * S, gen.crowns(25 * S))))
    assert st.current.kind == "rest"
    assert st.ignored[-1]["reason"] == "clock"


# ---- CSV ----------------------------------------------------------------------------------------

def test_lines_written_as_the_run_goes_hold_every_final_line():
    p = _plan("windows3334")
    st = we.initial(p)
    written, out = {}, []
    for e in gen.expand_events(gen.SCENARIOS["windows3334"]["gymTruth"]):
        st, _ = we.reduce(st, e)
        out += wss.new_lines(st, written)
    final = {wss._key(text) for _, text in wc.event_lines(st)}
    assert final <= {wss._key(text) for _, text in out}
    # The reps entered at the end are written again on their step line.
    assert any("reps=" in text for _, text in out)
    assert wss.new_lines(st, written) == []
