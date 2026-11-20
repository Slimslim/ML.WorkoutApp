"""#148: armed → in set → resting → (Crown) → armed, and the Crown gating the set tracker.

Invented signals only, no real recording. The cases and Python's results are the Swift parity
fixtures (LiftCycleTests): `lift_cycle_cases.json` (the state machine) and
`rest_arm_cases.json` (replays like the watch: 1 s batches, Crown turns at given times)."""
import json
import math
import pathlib

import numpy as np

from barpath.lift_cycle import ARMED_TIMEOUT, LiftCycle, run
from barpath.reps import SetTracker

FIX = pathlib.Path(__file__).resolve().parents[2] / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures"
CYCLE_FIXTURE = FIX / "lift_cycle_cases.json"
ARM_FIXTURE = FIX / "rest_arm_cases.json"
FS = 200.0

# --- the state machine ---

CYCLE_CASES = {
    "two_sets": [["start", 0.0], ["setStarted", 3.0], ["setEnded", 20.0],
                 ["arm", 140.5], ["setStarted", 143.0], ["setEnded", 160.0]],
    # nothing but a Crown turn leaves rest; a Crown turn while armed or in a set does nothing
    "rest_ignores_events": [["start", 0.0], ["setStarted", 2.0], ["setEnded", 10.0],
                            ["setStarted", 30.0], ["setEnded", 31.0], ["arm", 40.0],
                            ["arm", 41.0], ["setStarted", 42.0], ["arm", 43.0]],
    # set end before any rep (a flush with nothing) still goes to rest
    "end_while_armed": [["start", 5.0], ["setEnded", 9.0], ["arm", 9.0]],
    # armed 3 min with no set: back to rest, the rest counting from where it started; not while
    # a rep is under way; never in a set
    "armed_timeout": [["start", 0.0], ["expire", 179.0, False], ["expire", 200.0, True],
                      ["setStarted", 201.0], ["expire", 400.0, False], ["setEnded", 410.0],
                      ["arm", 470.0], ["expire", 649.0, False], ["expire", 650.0, False],
                      ["arm", 700.0]],
    "first_set_timeout": [["start", 10.0], ["expire", 190.0, False], ["arm", 200.0]],
}


def test_cycle_basics():
    c = LiftCycle.start(0.0)
    assert c.state == "armed" and c.is_listening and c.listening_from == 0.0 and c.can_show_end_page
    assert not c.arm(1.0)                     # already armed
    assert c.set_started(2.0) and not c.can_show_end_page
    assert c.set_ended(10.0) and c.state == "resting"
    assert not c.is_listening and c.listening_from == math.inf and c.can_show_end_page
    assert not c.set_started(12.0) and c.state == "resting"   # a "rep" at rest is ignored
    assert c.arm(100.0) and c.last_rest == 90.0 and c.listening_from == 100.0


def test_armed_timeout_rule():
    c = LiftCycle.start(0.0)
    assert ARMED_TIMEOUT == 180.0
    assert not c.expire_armed(ARMED_TIMEOUT - 0.1, False)
    assert not c.expire_armed(ARMED_TIMEOUT + 5, True)          # a rep under way
    assert c.expire_armed(ARMED_TIMEOUT, False) and c.state == "resting" and c.since == 0.0
    assert c.arm(300.0) and c.last_rest == 300.0
    assert c.expire_armed(480.0, False) and c.since == 0.0     # rest keeps counting from 0
    assert not c.expire_armed(700.0, False)                    # only while armed


def test_cycle_parity_fixture_is_current():
    fixture = json.loads(CYCLE_FIXTURE.read_text())
    assert set(fixture["cases"]) == set(CYCLE_CASES)
    for name, ops in CYCLE_CASES.items():
        assert fixture["cases"][name]["ops"] == ops, name
        assert fixture["cases"][name]["expected"] == run(ops), name


# --- the Crown gating the set tracker ---

def _signal(pulls, shakes, total):
    """pulls: [t0, rom, up, down] (bar up, held 0.4 s, down); shakes: [t0, dur, rom, up] (a fast
    up/down wrist lobe with 5 Hz jitter on top: 1.0 g along the forearm, 0.8 g across). ĝ = -x."""
    t = np.arange(0, total, 1 / FS)
    v = np.zeros_like(t)

    def lobe(t0, rom, up, down):
        tr = t - t0
        m = (tr >= 0) & (tr < up)
        v[m] += np.pi * rom / (2 * up) * np.sin(np.pi * tr[m] / up)
        td = tr - (up + 0.4)
        m = (td >= 0) & (td < down)
        v[m] -= np.pi * rom / (2 * down) * np.sin(np.pi * td[m] / down)

    for t0, rom, up, down in pulls:
        lobe(t0, rom, up, down)
    for t0, _, rom, up in shakes:
        lobe(t0, rom, up, up)
    a_up = np.gradient(v, t)
    g = np.tile([-1.0, 0.0, 0.0], (len(t), 1))
    ua = g * (a_up / 9.80665)[:, None]
    for t0, dur, _, _ in shakes:
        m = (t >= t0) & (t < t0 + dur)
        ph = 2 * np.pi * 5.0 * (t[m] - t0)
        ua[m, 0] += -1.0 * np.sin(ph)
        ua[m, 1] += 0.8 * np.sin(ph + 1.0)
    return t, ua, g


def watch_replay(t, ua, g, arms):
    """Like MotionRecorder: 1 s batches; a Crown turn at time `a` is applied before the first
    batch starting at or after it; the tracker only counts reps from `listening_from`."""
    cycle = LiftCycle.start(float(t[0]))
    tr = SetTracker()
    todo = sorted(arms)
    sets, live, applied, expired = [], [], [], []
    for k in range(0, len(t), 200):
        while todo and todo[0] <= t[k]:
            a = todo.pop(0)
            applied.append([a, cycle.arm(a)])
        tr.armedFrom = cycle.listening_from
        for e in tr.process(t, ua, g, np.arange(k, min(len(t), k + 200))):
            if e[0] == "rep":
                live.append(e[1])
                cycle.set_started(e[2])
            else:
                sets.append(e)
                cycle.set_ended(e[3][-1].end)
        latest = float(t[min(len(t), k + 200) - 1])
        if cycle.expire_armed(latest, tr.detected):
            expired.append(round(latest, 4))
    tr.armedFrom = cycle.listening_from
    last = tr.flush(t, ua, g)
    if last:
        sets.append(last)
        cycle.set_ended(last[3][-1].end)
    return {"sets": [{"start": round(s[1], 4), "reps": [[round(r.start, 4), round(r.end, 4)] for r in s[3]]}
                     for s in sets],
            "live": live, "arms": applied, "rest": cycle.last_rest, "expired": expired}


def _pulls(n, period, t0, rom=0.6, up=1.0, down=1.0):
    return [[t0 + k * period, rom, up, down] for k in range(n)]


SHAKE = [0.8, 0.40, 0.35]   # dur, rom, up: passes RepCounter (ROM ≥ 0.30 m), like #147

ARM_CASES = {
    # #147: a set, then a hand shake at rest, no Crown turn: one set
    "shake_at_rest": dict(pulls=_pulls(8, 2.4, 8.0), shakes=[[60.0] + SHAKE], total=80.0, arms=[]),
    # even three real-looking pulls at rest don't count until the Crown is turned
    "pulls_at_rest_then_crown": dict(pulls=_pulls(5, 2.5, 8.0) + _pulls(3, 2.5, 40.0) + _pulls(5, 2.5, 80.0),
                                     shakes=[[60.0] + SHAKE], total=105.0, arms=[75.0]),
    # first rep 1 s after the Crown turn: counted, and the recording keeps 3 s of pre-roll
    "set_right_after_crown": dict(pulls=_pulls(5, 2.5, 8.0) + _pulls(5, 2.5, 51.0),
                                  shakes=[], total=75.0, arms=[50.0]),
    # a Crown turn mid-set does nothing
    "crown_mid_set": dict(pulls=_pulls(6, 2.5, 8.0), shakes=[], total=35.0, arms=[12.0]),
    # a real set at rest without the Crown: counts nothing
    "set_without_crown": dict(pulls=_pulls(5, 2.5, 8.0) + _pulls(5, 2.5, 45.0), shakes=[],
                              total=70.0, arms=[]),
    # two hand shakes 15 s apart: nothing
    "two_shakes_at_rest": dict(pulls=_pulls(5, 2.5, 8.0), shakes=[[45.0] + SHAKE, [60.0] + SHAKE],
                               total=80.0, arms=[]),
    # armed 3 min with no set: back to rest; then a set without the Crown counts nothing
    "armed_timeout": dict(pulls=_pulls(5, 2.5, 8.0) + _pulls(4, 2.5, 235.0), shakes=[],
                          total=260.0, arms=[40.0]),
}


def test_rest_and_crown_cases():
    r = watch_replay(*_signal(**{k: v for k, v in ARM_CASES["shake_at_rest"].items() if k != "arms"}), [])
    assert [len(s["reps"]) for s in r["sets"]] == [8] and r["live"] == list(range(1, 9))

    c = ARM_CASES["pulls_at_rest_then_crown"]
    r = watch_replay(*_signal(c["pulls"], c["shakes"], c["total"]), c["arms"])
    assert [len(s["reps"]) for s in r["sets"]] == [5, 5]
    assert r["sets"][1]["reps"][0][0] > 75.0
    assert r["arms"] == [[75.0, True]] and r["rest"] > 50

    c = ARM_CASES["set_right_after_crown"]
    r = watch_replay(*_signal(c["pulls"], c["shakes"], c["total"]), c["arms"])
    assert [len(s["reps"]) for s in r["sets"]] == [5, 5]
    assert r["sets"][1]["start"] < 50.0          # pre-roll from before the Crown turn

    c = ARM_CASES["crown_mid_set"]
    r = watch_replay(*_signal(c["pulls"], c["shakes"], c["total"]), c["arms"])
    assert [len(s["reps"]) for s in r["sets"]] == [6] and r["arms"] == [[12.0, False]]
    assert r["expired"] == []


def test_nothing_at_rest_counts():
    r = _run_arm_case(ARM_CASES["set_without_crown"])
    assert [len(s["reps"]) for s in r["sets"]] == [5] and r["live"] == [1, 2, 3, 4, 5]
    r = _run_arm_case(ARM_CASES["two_shakes_at_rest"])
    assert [len(s["reps"]) for s in r["sets"]] == [5] and r["live"] == [1, 2, 3, 4, 5]


def test_armed_timeout_goes_back_to_rest():
    r = _run_arm_case(ARM_CASES["armed_timeout"])
    assert r["arms"] == [[40.0, True]]
    assert len(r["expired"]) == 1 and 220.0 <= r["expired"][0] < 221.5
    assert [len(s["reps"]) for s in r["sets"]] == [5]          # the pulls after it: not a set


def test_resting_tracker_counts_nothing():
    t, ua, g = _signal(_pulls(6, 2.5, 8.0), [], 35.0)
    tr = SetTracker(armedFrom=math.inf)
    ev = []
    for k in range(0, len(t), 200):
        ev += tr.process(t, ua, g, np.arange(k, min(len(t), k + 200)))
    assert ev == [] and tr.flush(t, ua, g) is None


def _run_arm_case(c):
    return watch_replay(*_signal(c["pulls"], c["shakes"], c["total"]), c["arms"])


def test_rest_arm_parity_fixture_is_current():
    fixture = json.loads(ARM_FIXTURE.read_text())
    assert set(fixture["cases"]) == set(ARM_CASES)
    for name, c in ARM_CASES.items():
        assert fixture["cases"][name]["input"] == c, name
        assert fixture["cases"][name]["expected"] == _run_arm_case(c), name


def write_fixtures():   # cd tools && python3 -c "import tests.test_lift_cycle as T; T.write_fixtures()"
    CYCLE_FIXTURE.write_text(json.dumps(
        {"note": "LiftCycle cases (#148), from tools/tests/test_lift_cycle.py.",
         "cases": {n: {"ops": ops, "expected": run(ops)} for n, ops in CYCLE_CASES.items()}},
        indent=1) + "\n")
    ARM_FIXTURE.write_text(json.dumps(
        {"note": "Invented signals (#148), from tools/tests/test_lift_cycle.py; no real data.",
         "tolerance": 0.006,
         "cases": {n: {"input": c, "expected": _run_arm_case(c)} for n, c in ARM_CASES.items()}},
        indent=1) + "\n")
