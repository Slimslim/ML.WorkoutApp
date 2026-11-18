"""Timeline engine: plan, reduce, replay (docs/WORKOUT_MODEL_RFC.md §4, §5, §10).

Times are integer milliseconds from the START tap."""
import random

import pytest

from barpath import workout_engine as we
from barpath import workout_structure as ws
from engine_cases import ALL

S = 1000


def P(name):
    return we.plan(ws.compile_definition(ALL[name]))


def events(crowns=(), until=0, tick=100, extra=()):
    """START at 0, a tick every `tick` ms up to `until`, Crown turns at the given times and any
    extra events, in time order (a Crown after the tick at the same time)."""
    evs = [(0, 0, {"kind": "start", "t": 0})]
    if tick:
        evs += [(t, 1, {"kind": "tick", "t": t}) for t in range(tick, until + 1, tick)]
    evs += [(c, 2, {"kind": "crown", "t": c}) for c in crowns]
    evs += [(e["t"], 3, e) for e in extra]
    return [e for _, _, e in sorted(evs, key=lambda x: (x[0], x[1]))]


def run(name, crowns=(), until=0, tick=100, extra=()):
    return we.run(P(name), events(crowns, until, tick, extra))


def by_id(st):
    return {f["id"]: f for f in we.facts(st)}


def kinds(effects, kind):
    return [e for e in effects if e["kind"] == kind]


# ---- Tabata -----------------------------------------------------------------------------------

TABATA_BELLS = sorted([30 * S * k + 20 * S for k in range(8)] + [30 * S * (k + 1) for k in range(8)])


def test_tabata_plan_is_sixteen_steps_all_anchored_to_the_start():
    p = P("tabata")
    assert len(p.steps) == 16
    assert [s.kind for s in p.steps] == ["part", "rest"] * 8
    assert all(b["anchor"] == "start" for b in p.bells)
    assert sorted(b["offsetMs"] for b in p.bells) == TABATA_BELLS
    assert p.steps[1].merged_window == "rp.1.work"           # automatic rest + 10 s rest = one step


def test_tabata_runs_on_the_clock_with_no_crown():
    st, eff = run("tabata", until=241 * S)
    assert st.done and st.ended_by == "clock" and st.done_t == 240 * S   # total 4:00
    assert we.boundaries(st) == TABATA_BELLS
    f = by_id(st)
    for k in range(1, 9):
        work, rest = f["rp.%d.sq" % k], f["rp.%d.r" % k]
        assert (work["start"], work["end"], work["endedBy"]) == (30 * S * (k - 1), 30 * S * (k - 1) + 20 * S, "clock")
        assert work["status"] == "done"                        # max: the bell is its planned ending
        assert rest["end"] - rest["start"] == 10 * S           # rest 10 s
    assert [e["t"] for e in kinds(eff, "go")] == [30 * S * k for k in range(1, 8)]
    assert [e["t"] for e in kinds(eff, "rest")] == [30 * S * k + 20 * S for k in range(8)]
    assert [e["t"] for e in kinds(eff, "time")] == [240 * S]
    assert len(kinds(eff, "ask")) == 8                         # each round's count is asked


def test_tabata_3_2_1_before_every_transition():
    _, eff = run("tabata", until=241 * S)
    cd = kinds(eff, "countdown")
    assert len(cd) == 3 * 16
    for b in TABATA_BELLS:
        assert [(e["n"], e["t"]) for e in cd if b - 3 * S <= e["t"] < b] == [(3, b - 3 * S), (2, b - 2 * S),
                                                                             (1, b - S)]


def test_tabata_crown_in_rest_is_ignored_and_i_stopped_keeps_the_clock():
    # 25 s: in round 1's rest. 41 s: "I stopped" in round 2 (work to 50 s). 47 s: in that rest.
    st, eff = run("tabata", crowns=[25 * S, 41 * S, 47 * S], until=241 * S)
    assert [h["reason"] for h in kinds(eff, "hint")] == ["clock", "clock"]
    assert we.boundaries(st) == sorted(set(TABATA_BELLS) - {50 * S})   # round 2 work ended by the athlete
    f = by_id(st)
    assert (f["rp.2.sq"]["end"], f["rp.2.sq"]["endedBy"]) == (41 * S, "athlete")
    assert (f["rp.2.r"]["start"], f["rp.2.r"]["end"]) == (41 * S, 60 * S)     # rest still ends at 1:00
    assert st.done_t == 240 * S


def test_tabata_score_is_total_with_the_lowest_round():
    reps = [12, 11, 10, 10, 9, 9, 8, 7]
    extra = [{"kind": "reps", "t": 241 * S, "step": "rp.%d.sq" % (k + 1), "value": n} for k, n in enumerate(reps)]
    st, _ = run("tabata", until=241 * S, extra=extra)
    sc = we.score(st)
    assert (sc["value"], sc["lowest"], sc["complete"]) == (76, 7, True)
    assert sc["perRound"] == reps
    st, _ = run("tabata", until=241 * S, extra=extra[:7])
    assert we.score(st)["complete"] is False                 # one round not entered: "?"


def test_a_late_tick_records_the_same_splits_and_plays_one_haptic():
    on_time, _ = run("tabata", until=100 * S)
    p = P("tabata")
    late, eff = we.run(p, [{"kind": "start", "t": 0}, {"kind": "tick", "t": 10 * S},
                           {"kind": "tick", "t": 100 * S}])
    assert we.facts(late) == we.facts(on_time)
    assert len([e for e in eff if e["kind"] in we.HAPTICS]) == 1   # only the state you are in now
    assert not kinds(eff, "countdown")                           # passed ticks are never replayed


# ---- windows (3-3-3-4) ------------------------------------------------------------------------

def test_3334_boundaries_are_on_the_gym_clock_whatever_the_crown_does():
    # Late turns like the 13 Nov recording (synthetic times) plus a double turn.
    crowns = [70 * S, 140 * S, 199 * S, 300 * S, 401 * S, 481 * S, 482 * S, 600 * S, 732 * S, 800 * S,
              900 * S, 1041 * S]
    st, eff = run("windows3334", crowns=crowns, until=1100 * S, tick=200)
    assert we.boundaries(st) == [180 * S, 240 * S, 420 * S, 480 * S, 660 * S, 720 * S, 960 * S]
    assert st.done_t == 960 * S and st.ended_by == "clock"
    reasons = [h["reason"] for h in kinds(eff, "hint")]
    assert reasons.count("clock") >= 1 and "done" in reasons           # 1041 s: after the end


def test_3334_cut_pull_ups_and_max_bench_score():
    # Round 1: bike 70 s, pull-ups 140 s, bench to the bell. Round 3: still on pull-ups at the bell.
    crowns = [70 * S, 140 * S, 300 * S, 370 * S, 540 * S, 760 * S, 830 * S]
    extra = [{"kind": "reps", "t": 1000 * S, "step": s, "value": v} for s, v in
             [("rp.1.bench", 12), ("rp.2.bench", 7), ("rp.3.pu", 12), ("rp.4.bench", 12)]]
    st, eff = run("windows3334", crowns=crowns, until=1000 * S, tick=200, extra=extra)
    f = by_id(st)
    assert (f["rp.3.pu"]["status"], f["rp.3.pu"]["reps"], f["rp.3.pu"]["end"]) == ("cut", 12, 660 * S)
    assert f["rp.3.bench"]["status"] == "skipped"
    assert set(st.asks) == set()
    assert [e["step"] for e in kinds(eff, "ask")] == ["rp.1.bench", "rp.2.bench", "rp.3.pu", "rp.4.bench"]
    assert we.score(st)["value"] == 31                         # bench 12 + 7 + 0 + 12


def test_3333_adds_the_900_s_boundary():
    st, _ = run("windows3333", until=1000 * S, tick=500)
    assert we.boundaries(st) == [180 * S, 240 * S, 420 * S, 480 * S, 660 * S, 720 * S, 900 * S, 960 * S]


# ---- EMOM -------------------------------------------------------------------------------------

def test_emom_waits_for_the_minute_and_cuts_a_failed_one():
    crowns = [60 * S * k + 40 * S for k in range(10) if k != 6]      # minute 7 not finished
    extra = [{"kind": "reps", "t": 610 * S, "step": "rp.7.kb", "value": 11}]
    st, eff = run("emom", crowns=crowns, until=610 * S, extra=extra)
    assert we.boundaries(st) == [60 * S * k for k in range(1, 11)]
    f = by_id(st)
    assert f["rp.1.m.wait"]["start"] == 40 * S and f["rp.1.m.wait"]["end"] == 60 * S
    assert (f["rp.7.kb"]["status"], f["rp.7.kb"]["reps"]) == ("cut", 11)
    assert f["rp.7.m.wait"]["status"] == "skipped"
    assert we.score(st)["text"] == "9/10"


def test_alternating_emom_has_odd_and_even_windows():
    p = P("emomAlt")
    assert [s.part["movement"] for s in p.steps if s.kind == "part"][:4] == [
        "kettlebellSwings", "burpees", "kettlebellSwings", "burpees"]
    st, _ = run("emomAlt", crowns=[30 * S, 90 * S, 150 * S], until=601 * S, tick=500)
    assert we.boundaries(st) == [60 * S * k for k in range(1, 11)]
    assert we.score(st)["text"] == "3/10"


def test_a_seconds_part_in_an_emom_ends_on_the_clock():
    st, eff = run("emomHold", crowns=[10 * S], until=241 * S, tick=500)
    f = by_id(st)
    assert (f["rp.1.plank"]["end"], f["rp.1.plank"]["endedBy"]) == (45 * S, "clock")
    assert kinds(eff, "hint")[0]["reason"] == "clock"            # the Crown can't end it
    assert we.boundaries(st) == sorted([60 * S * k for k in range(1, 5)] + [60 * S * k + 45 * S for k in range(4)])


# ---- AMRAP ------------------------------------------------------------------------------------

def test_amrap_with_cap_ends_at_the_bell_and_scores_rounds_and_reps():
    crowns = list(range(20 * S, 711 * S, 20 * S))          # a part every 20 s: 35 parts by 700 s
    extra = [{"kind": "reps", "t": 730 * S, "step": "rp.18.c2b", "value": 30}]
    st, eff = run("amrapLadder", crowns=crowns, until=730 * S, tick=500, extra=extra)
    assert st.done_t == 720 * S and st.ended_by == "clock"
    f = by_id(st)
    assert f["rp.18.c2b"]["status"] == "cut"
    sc = we.score(st)
    # 17 full rounds of the 3-6-9 ladder: 2 x 3 x (1 + ... + 17) = 918, round 18: 54 thrusters + 30.
    assert sc["value"] == 918 + 54 + 30
    assert sc["roundsReps"] == {"rounds": 17, "reps": 84, "complete": True}
    assert kinds(eff, "time")[0]["t"] == 720 * S


def test_amrap_adds_rounds_past_the_list():
    p = P("amrapShort")
    assert len(p.steps) == 12                               # listRounds 6
    crowns = list(range(4500, 120 * S, 4500))               # faster than the list: 26 parts
    st, _ = run("amrapShort", crowns=crowns, until=121 * S, tick=500)
    f = we.facts(st)
    assert len(f) > 12
    assert all(x.get("extra") for x in f[12:]) and not any(x.get("extra") for x in f[:12])
    assert [x["id"] for x in f[12:14]] == ["rp.7.a", "rp.7.b"]
    assert we.score(st)["rounds"] == 13
    assert len({x["id"] for x in f}) == len(f)              # step ids stay unique


def test_amrap_buy_in_counts_and_cash_out_runs_after():
    crowns = [60 * S] + list(range(80 * S, 300 * S, 20 * S)) + [400 * S]
    st, eff = run("amrapBuyCash", crowns=crowns, until=401 * S, tick=500,
                  extra=[{"kind": "reps", "t": 300 * S + 500, "step": "rp.6.b", "value": 4}])
    f = by_id(st)
    assert f["cash"]["start"] == 300 * S and f["cash"]["end"] == 400 * S
    assert st.done and st.ended_by == "athlete"
    # 20 cal buy-in + 5 rounds of 10 + 5, round 6: 10 wall balls + 4 burpees at the bell
    # (the cash-out's metres never count).
    assert we.score(st)["value"] == 20 + 5 * 15 + 10 + 4


# ---- for time with cap ------------------------------------------------------------------------

def test_for_time_finished_before_the_cap():
    crowns = [90 * S * k for k in range(1, 10)]
    st, eff = run("forTimeCap", crowns=crowns, until=810 * S, tick=1000)
    sc = we.score(st)
    assert (sc["value"], sc["text"]) == (810 * S, "13:30")
    assert not kinds(eff, "cap")


def test_for_time_cap_is_announced_and_scored_cap_plus_reps():
    crowns = [130 * S * k for k in range(1, 10)]           # 9 parts at 2:10 each: 19:30
    extra = [{"kind": "reps", "t": 961 * S, "step": "rp.3.kb", "value": 15}]
    st, eff = run("forTimeCap", crowns=crowns, until=1170 * S, tick=1000, extra=extra)
    cap = kinds(eff, "cap")
    assert cap == [{"kind": "cap", "t": 960 * S, "step": "rp.3.kb"}]
    assert not [e for e in kinds(eff, "countdown") if 950 * S <= e["t"] <= 960 * S]   # no 3-2-1 for a cap
    assert st.done and st.done_t == 1170 * S                # kept going past the cap
    sc = we.score(st)
    assert sc["capped"] and sc["text"] == "CAP + %d" % (2 * 33 + 15)
    assert sc["afterCapMs"] == 210 * S
    # Not entered yet: the score shows "?".
    st, _ = run("forTimeCap", crowns=crowns, until=1170 * S, tick=1000)
    assert we.score(st)["complete"] is False and "rp.3.kb" in st.asks


def test_hard_cap_stops_the_workout():
    st, eff = run("hardCap", crowns=[100 * S, 200 * S], until=310 * S, tick=1000)
    assert st.done_t == 300 * S and st.ended_by == "clock"
    assert by_id(st)["rp.2.a"]["status"] == "cut"


# ---- death by, partner, intervals, ratio rest, Hyrox ------------------------------------------

def test_death_by_ends_at_the_missed_minute():
    crowns = [60 * S * k + 10 * S for k in range(10)]       # minutes 1-10 done, minute 11 missed
    extra = [{"kind": "reps", "t": 661 * S, "step": "rp.11.b", "value": 6}]
    st, _ = run("deathBy", crowns=crowns, until=700 * S, tick=1000, extra=extra)
    assert st.done_t == 660 * S and st.ended_by == "clock"
    assert we.score(st)["text"] == "10 + 6"
    assert st.step_by_id("rp.11.b").target["value"] == 11      # minute n: n burpees
    assert by_id(st)["rp.12.b"]["status"] == "skipped"         # the rest of the list never runs


def test_partner_steps_are_labelled_and_athlete_paced():
    st, _ = run("partner", crowns=[300 * S, 600 * S, 800 * S], until=800 * S, tick=1000)
    assert [st.steps[i].part["who"] for i in st.seq] == ["shared", "shared", "together"]
    assert we.score(st)["text"] == "13:20"


def test_work_based_intervals_rest_from_the_actual_finish():
    crowns = []
    t = 0
    for piece in [58, 61, 57, 60, 59]:
        t += piece * S
        crowns.append(t)
        t += 60 * S
    st, _ = run("intervals", crowns=crowns, until=t, tick=500)
    f = by_id(st)
    assert (f["rp.1.r"]["start"], f["rp.1.r"]["end"]) == (58 * S, 118 * S)
    assert f["rp.2.row"]["start"] == 118 * S
    sc = we.score(st)
    assert [p["ms"] for p in sc["pieces"]] == [58 * S, 61 * S, 57 * S, 60 * S, 59 * S]
    assert sc["value"] == 59 * S
    bells = {b["id"]: b for b in P("intervals").bells}
    assert bells["rp.1.r.end"] == {"id": "rp.1.r.end", "anchor": "rp.1.row", "offsetMs": 60 * S}


def test_rest_as_long_as_the_round_took():
    # Round 1 ends at 2:35, round 2 takes 3:00; a Crown in the rest is ignored.
    r1 = [50 * S, 100 * S, 155 * S]
    r2 = [155 * S * 2 + 60 * S, 155 * S * 2 + 120 * S, 155 * S * 2 + 180 * S]
    r3 = [r2[-1] + 180 * S + 30 * S, r2[-1] + 180 * S + 60 * S, r2[-1] + 180 * S + 90 * S]
    st, eff = run("ratioRest", crowns=r1 + [200 * S] + r2 + r3, until=r3[-1], tick=500)
    f = by_id(st)
    assert f["rp.1.r"]["end"] - f["rp.1.r"]["start"] == 155 * S
    assert f["rp.2.r"]["end"] - f["rp.2.r"]["start"] == 180 * S
    assert "rp.3.r" not in f                                 # no rest after the last round
    assert kinds(eff, "hint")[0]["reason"] == "clock"
    assert st.done and st.ended_by == "athlete"


def test_hyrox_is_athlete_paced_with_no_bells():
    p = P("hyrox")
    assert p.bells == []
    assert [s.part["movement"] for s in p.steps][:4] == ["run", "skiErg", "run", "sledPush"]
    crowns = [240 * S * k for k in range(1, 17)]
    st, eff = run("hyrox", crowns=crowns + [240 * S + 1500], until=0, tick=0)
    assert st.done and st.ended_by == "athlete"
    assert kinds(eff, "hint") == [{"kind": "hint", "t": 240 * S + 1500, "reason": "lockout"}]
    assert not [e for e in eff if e["kind"] in we.HAPTICS + ("countdown",)]
    assert we.score(st)["value"] == 16 * 240 * S


def test_build_to_a_max_until_the_athlete_says_done():
    extra = [{"kind": "blockDone", "t": 300 * S}]
    st, _ = run("buildMax", crowns=[60 * S, 120 * S, 180 * S, 400 * S], until=0, tick=0, extra=extra)
    f = we.facts(st)
    assert [x["status"] for x in f[:4]] == ["done", "done", "done", "skipped"]
    assert f[-1]["id"] == "cool" and f[-1]["status"] == "done"
    assert st.done


# ---- Crown rules ------------------------------------------------------------------------------

def test_turn_less_than_2_s_after_a_bell_is_ignored_and_a_turn_begun_before_gets_grace():
    # EMOM minute 1 not finished; a turn at 61.5 s is ignored (bell lockout).
    st, eff = run("emom", crowns=[61500], until=62 * S)
    assert kinds(eff, "hint")[0]["reason"] == "bell"
    assert by_id(st)["rp.1.kb"]["status"] == "cut"
    # A turn that began at 59.6 s and arrived at 60.3 s: the part was done at the bell.
    p = P("emom")
    evs = events(until=61 * S) + [{"kind": "crown", "t": 60300, "began": 59600}]
    evs = sorted(evs, key=lambda e: e["t"])
    st, eff = we.run(p, evs)
    f = by_id(st)
    assert (f["rp.1.kb"]["status"], f["rp.1.kb"]["endedBy"], f["rp.1.kb"]["end"]) == ("done", "athlete", 60 * S)
    assert "rp.1.kb" not in st.asks and kinds(eff, "grace")
    assert st.current.id == "rp.2.kb"                        # nothing advances


def test_window_lockout_4_s():
    st, eff = run("windows3334", crowns=[10 * S, 13 * S, 15 * S], until=16 * S)
    assert [h["reason"] for h in kinds(eff, "hint")] == ["lockout"]
    assert st.current.id == "rp.1.bench"


def test_undo_inside_a_window_and_never_across_a_bell():
    p = P("emom")
    evs = events(crowns=[40 * S], until=50 * S) + [{"kind": "undo", "t": 50 * S}]
    st, eff = we.run(p, evs)
    assert st.current.id == "rp.1.kb" and kinds(eff, "undo")
    evs = events(crowns=[40 * S], until=65 * S) + [{"kind": "undo", "t": 65 * S}]
    st, eff = we.run(p, evs)
    assert kinds(eff, "hint")[-1]["reason"] == "bell"
    assert st.current.id == "rp.2.kb"


def test_undo_refused_while_a_rest_counted_from_that_turn_runs():
    p = P("intervals")
    st, eff = we.run(p, events(crowns=[58 * S], until=70 * S) + [{"kind": "undo", "t": 70 * S}])
    assert kinds(eff, "hint")[-1]["reason"] == "clockRunning"
    # Outside any clock (Hyrox) undo works as today.
    st, eff = we.run(P("hyrox"), events(crowns=[240 * S], tick=0) + [{"kind": "undo", "t": 250 * S}])
    assert st.current.id == "rp.1.run" and st.rec[st.seq[0]]["end"] is None


def test_i_was_further_relabels_the_window():
    # 3-3-3-4 round 1: the watch thinks bike at the bell; the athlete was on bench with 5 reps.
    extra = [{"kind": "reps", "t": 181 * S, "step": "rp.1.bench", "value": 5}]
    st, _ = run("windows3334", until=181 * S, extra=extra)
    f = by_id(st)
    assert f["rp.1.bike"]["status"] == "done" and f["rp.1.pu"]["status"] == "done"
    assert f["rp.1.pu"]["start"] is None                     # re-labelled steps get no times
    assert (f["rp.1.bench"]["status"], f["rp.1.bench"]["reps"]) == ("cut", 5)
    assert "rp.1.bike" not in st.asks


def test_late_crown_within_5_s_is_applied_in_time_order_and_older_ones_ignored():
    p = P("hyrox")
    st, _ = we.run(p, [{"kind": "start", "t": 0}, {"kind": "tick", "t": 100 * S},
                       {"kind": "crown", "t": 97 * S}])
    assert by_id(st)["rp.1.run"]["end"] == 97 * S
    st, eff = we.run(p, [{"kind": "start", "t": 0}, {"kind": "tick", "t": 100 * S},
                         {"kind": "crown", "t": 90 * S}])
    assert st.current.id == "rp.1.run" and kinds(eff, "hint")[0]["reason"] == "late"


# ---- replay and properties --------------------------------------------------------------------

@pytest.mark.parametrize("name", ["tabata", "windows3334", "emom", "amrapLadder", "forTimeCap", "deathBy",
                                  "intervals", "ratioRest", "hyrox"])
def test_random_crowns_replay_equals_live_and_clocks_stay_on_time(name):
    p = P(name)
    for seed in range(20):
        rng = random.Random(seed)
        horizon = 1500 * S
        crowns = sorted(rng.sample(range(500, horizon, 100), rng.randint(5, 80)))
        evs = events(crowns, until=horizon, tick=rng.choice([100, 200, 1000]))
        live, _ = we.run(p, evs)
        non_ticks = [e for e in evs if e["kind"] != "tick"]
        replayed = we.replay(p, non_ticks, until=horizon)
        assert we.facts(replayed) == we.facts(live), seed
        assert we.score(replayed) == we.score(live)
        # Steps never overlap and follow each other.
        prev_end = 0
        for f in we.facts(live):
            if f["status"] == "notReached" or f.get("start") is None:
                continue
            assert f["end"] is None or f["end"] >= f["start"]
            assert f["start"] == prev_end or f["status"] == "skipped", (seed, f)
            prev_end = f["end"] if f["end"] is not None else prev_end
        # Every start-anchored change of step happens exactly on time (a window bell followed by
        # a merged rest, or a cap you keep going past, changes nothing: not a transition).
        silent = {s.merged_window + ".end" for s in p.steps if s.merged_window}
        silent |= {w.key + ".end" for w in p.windows.values() if w.late == "continue"}
        transitions = [b["offsetMs"] for b in p.bells if b["anchor"] == "start" and b["id"] not in silent]
        starts = {f["start"] for f in we.facts(live) if f.get("start") is not None and f["status"] != "skipped"}
        if live.done_t is not None:
            starts.add(live.done_t)
        for b in transitions:
            if b <= horizon and (live.done_t is None or b <= live.done_t):
                assert b in starts, (seed, b)


def test_plan_hash_is_canonical_and_stable():
    p = P("tabata")
    assert p.hash == P("tabata").hash
    assert ".0" not in p.canonical_json().split('"ratio"')[0]
    assert p.hash != P("windows3334").hash
    d = p.to_dict()
    assert d["planner"] == we.PLANNER_VERSION and len(d["steps"]) == 16
