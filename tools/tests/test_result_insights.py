"""barpath/result_insights.py: results-page insight rules (docs/RESULTS_INSIGHTS.md, W47)."""
import json

import pytest

import result_insight_cases as cases
from barpath.result_insights import (insights, percent_text, round_half_away, round_size, time_text)

EXPECTED = {
    "amrap_bike_drift": [
        ("A1", "Bike: 1:29 in round 1, then 1:48-1:51 (+23 %), 1:22 in total.", False),
        ("A3", "That drift added 1:22, about a third of a round.", False),
        ("A2", "Step-ups and Wall Balls held within 5 %.", False),
        ("CUE", "Next time: hold the bike nearer 1:30.", True),
    ],
    "barbara_for_time": [
        ("F2", "Push-ups: 0:45 in round 1, then 0:55-1:20 (+51 %), 1:32 in total.", False),
        ("F1", "Rounds 4-5 took 1:29 longer than rounds 1-2 (+18 %).", False),
        ("A3", "That drift added 1:32, about a third of a round.", False),
        ("CUE", "Next time: hold the push-ups nearer 0:45.", True),
    ],
    "ladder_21_15_9": [
        ("L1", "Thrusters 9: 1:10, expected about 0:45 from your 21 and 15.", False),
    ],
    "runs_started_hard": [
        ("R1", "Started hard, then faded: run 1 in 3:50, the rest 4:18-4:30 (+14 % at the median).", False),
    ],
    "runs_fade_last": [
        ("F5", "Runs: first 4:00, last 4:22 (+9 %).", False),
    ],
    "emom_loads": [
        ("E3", "Power Snatch: heaviest 140 lb. Loads 95 → 115 → 135 → 140 lb.", False),
    ],
    "amrap_check_timing": [
        ("A1", "Burpees: 0:40 in round 1, then 0:44-0:51 (+18 %), 0:29 in total.", False),
        ("A3", "That drift added 0:29, about a fifth of a round.", False),
        ("CHECK", "Check your timing on round 2.", False),
        ("CUE", "Next time: hold the burpees nearer 0:40.", True),
    ],
    "silence_two_steady_rounds": [],
    "silence_chipper": [],
    "runs_mixed_distances": [
        ("R1", "Started hard, then faded: run 1 at 3:20 /km, the rest 3:50-4:04 /km (+19 % at the median).",
         False),
    ],
    "check_outlier_chipper": [
        ("CHECK", "Check your timing on segments 5 and 6.", False),
    ],
    "silence_free_workout": [],
    "silence_free_workout_long_first_part": [],
}

NEVER = ("pace", "speed", "calorie", "effort", "zone", "heart", "bpm", "fatigue", "tired", "because")


@pytest.mark.parametrize("name,make", cases.CASES)
def test_case_texts(name, make):
    r = make()
    got = [(i["id"], i["text"], i["isCue"]) for i in insights(r, r.definition)]
    assert got == EXPECTED[name]


@pytest.mark.parametrize("name,make", cases.CASES)
def test_limits_and_never_shown(name, make):
    r = make()
    got = insights(r, r.definition)
    assert len([i for i in got if not i["isCue"]]) <= 3
    assert len([i for i in got if i["isCue"]]) <= 1
    if any(i["isCue"] for i in got):
        assert got[-1]["isCue"]
        assert any(i["id"] in ("A1", "F2") for i in got)
    for i in got:
        low = i["text"].lower()
        for word in NEVER:
            assert word not in low, (name, i["text"])


def test_fixture_is_up_to_date():
    """The shared JSON (Swift parity test input) matches the cases and the Python output."""
    on_disk = json.loads(cases.FIXTURE.read_text(encoding="utf-8"))
    assert on_disk == json.loads(cases.dump(cases.build())), \
        "run: python3 tools/tests/result_insight_cases.py"
    assert [c["name"] for c in on_disk] == list(EXPECTED)


def test_fixture_round_trips_through_result_json():
    from barpath.workout import WorkoutResult
    for c in json.loads(cases.FIXTURE.read_text(encoding="utf-8")):
        r = WorkoutResult.from_dict(c["result"])
        assert insights(r, r.definition) == c["expected"], c["name"]


def test_formatting():
    assert time_text(89.4) == "1:29"
    assert time_text(89.5) == "1:30"
    assert time_text(-38) == "0:38"
    assert time_text(3725) == "1:02:05"
    assert percent_text(0.2) == "+20 %"
    assert percent_text(-0.06) == "-6 %"
    assert percent_text(0.001) == "+0 %"
    assert round_half_away(2.5) == 3
    assert round_half_away(-2.5) == -3


def test_round_size_needs_repeating_movements():
    assert round_size(cases.amrap_bike_drift().definition) == 3
    assert round_size(cases.barbara_for_time().definition) == 5
    # Run + different stations: roundSize 2 in the definition, but nothing repeats but the run.
    assert round_size(cases.runs_started_hard().definition) is None
    assert round_size(cases.silence_chipper().definition) is None


def test_rest_never_counts():
    """Making the Barbara rests longer changes nothing."""
    r = cases.barbara_for_time()
    before = insights(r, r.definition)
    shift = 0.0
    for s in r.segments:
        s.start += shift
        if s.kind == "rest":
            s.duration += 100
            shift += 100
        s.end = s.start + s.duration
    assert insights(r, r.definition) == before


def test_partial_segment_is_ignored():
    """AMRAP: the segment cut by the cap never enters the numbers (even when very short)."""
    r = cases.amrap_bike_drift()
    r.segments[-1].duration = 2.0
    assert [i["id"] for i in insights(r, r.definition)] == ["A1", "A3", "A2", "CUE"]


def test_small_drift_is_silent():
    """Under 10 s extra in total, no drift, no A3, no cue."""
    r = cases.amrap_bike_drift()
    for s in r.segments:
        if s.movement == "bike" and s.index > 0 and s.index != r.segments[-1].index:
            s.duration = 91.0
    ids = [i["id"] for i in insights(r, r.definition)]
    assert "A1" not in ids and "A3" not in ids and "CUE" not in ids
    assert ids == ["A2"]


def test_r1_needs_strictly_more_than_8_percent():
    """Median of the rest exactly +8 % over run 1: silent."""
    r = cases.runs_started_hard()
    runs = [s for s in r.segments if s.kind == "run"]
    runs[0].duration = 250.0
    for s, d in zip(runs[1:], (270.0, 270.0, 270.0)):
        s.duration = d
    assert "R1" not in [i["id"] for i in insights(r, r.definition)]


def test_non_finite_duration_is_ignored():
    r = cases.barbara_for_time()
    r.segments[0].duration = float("nan")
    got = insights(r, r.definition)   # must not raise
    assert all(i["id"] != "F1" for i in got)   # round 1 is incomplete without its pull-ups


def test_last_segment_complete():
    from barpath.result_insights import last_segment_complete
    # Free Workout ended by hand after 9 of 60 parts: the 9th part counts.
    r = cases.silence_free_workout()
    assert last_segment_complete(r, r.definition, len(r.segments))
    # Same, but the finish came from the cap (auto): partial.
    r.events[-1].source = "auto"
    assert not last_segment_complete(r, r.definition, len(r.segments))
    # No finish at all (ended): partial.
    r.finish_date = None
    assert not last_segment_complete(r, r.definition, len(r.segments))
    # AMRAP stopped by the cap: always partial.
    a = cases.amrap_bike_drift()
    assert not last_segment_complete(a, a.definition, len(a.segments))


def test_ended_early_by_hand_keeps_last_segment():
    """For time ended with the Crown after round 3 of Barbara: rounds 1-3 are all complete."""
    r = cases.barbara_for_time()
    r.segments = r.segments[:14]          # 3 rounds (4 work + rest) minus the last rest
    r.events[-1].segment_index = 13
    got = [i["id"] for i in insights(r, r.definition)]
    assert got[0] == "F2" and "CUE" in got


def test_e3_ignores_flagged_sets():
    r = cases.emom_loads()
    r.segments[6].duration = 2.0          # both 140 lb sets with a broken timing: not "successful"
    r.segments[7].duration = 2.0
    texts = [i["text"] for i in insights(r, r.definition)]
    assert "Power Snatch: heaviest 135 lb. Loads 95 → 115 → 135 lb." in texts
