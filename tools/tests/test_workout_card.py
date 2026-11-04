"""Workout card text (tools/barpath/workout_card.py), the reference for WorkoutCard.swift."""
import json

from barpath.workout import SegmentLoad, SegmentTarget, WorkoutDefinition, WorkoutLibrary, WorkoutSegment
from barpath.workout_card import FIXTURE, WorkoutCard, fixture_definitions, fixture_text


def card_of(definition_id: str) -> WorkoutCard:
    for d in fixture_definitions():
        if d.id == definition_id:
            return WorkoutCard.make(d)
    raise KeyError(definition_id)


def texts(card: WorkoutCard) -> list:
    return [ln.full for ln in card.lines]


def test_parity_fixture_is_current():
    """The Swift test reads this file: regenerate with `cd tools && python3 -m barpath.workout_card`."""
    assert FIXTURE.read_text() == fixture_text()
    cards = json.loads(FIXTURE.read_text())["cards"]
    assert len(cards) == len(WorkoutLibrary.known) + 2


def test_helen_rounds_for_time():
    c = card_of("wod.helen")
    assert (c.name, c.type_label, c.block_label) == ("Helen", "RFT", "Metcon")
    assert c.time_domain_line == "3 rounds"
    assert c.rep_scheme_line is None
    assert texts(c) == ["400 m Run", "21 KB Swings", "12 Pull-ups"]
    assert c.cap_line == "16 min cap"
    assert c.summary_line == "400 m Run · 21 KB Swings · 12 Pull-ups"


def test_freedom_mixed_scheme():
    c = card_of("lib.pitfire.20261102.freedom")
    assert (c.name, c.type_label) == ("Freedom", "RFT")
    assert c.time_domain_line == "5 rounds"
    assert c.rep_scheme_line == "40-30-20-30-40 Cal"
    assert texts(c) == ["Row", "7 Power Cleans @155 lb"]
    assert c.lines[1].text == "7 Power Cleans" and c.lines[1].load == "155 lb"
    assert c.cap_line == "20 min cap"
    assert c.summary_line == "40-30-20-30-40 Cal Row · 7 Power Cleans @155 lb"


def test_emom_names_drop_the_format_prefix():
    c = card_of("lib.pitfire.20261102.pcj-emom")
    assert (c.name, c.name_is_format, c.type_label, c.block_label) == ("Power C&J", False, "EMOM", "Strength")
    assert c.time_domain_line == "Every 1:00 × 8"
    assert texts(c) == ["2 Power C&J"]
    assert c.cap_line is None  # EMOM: the cap is the clock, not a for-time cap
    rt = card_of("wod.rowThrusters")
    assert rt.name == "Row + Thrusters" and rt.time_domain_line == "Every 3:00 × 6"
    assert texts(rt) == ["15 Cal Row", "12 Thrusters"]  # rest is not a movement line


def test_amrap_with_rest():
    c = card_of("wod.amrap40")
    assert (c.name, c.name_is_format, c.type_label) == ("AMRAP 40", True, "AMRAP")
    assert c.time_domain_line == "40 min AMRAP · rest 1 min between rounds"
    assert texts(c) == ["12 Cal Row / Bike", "15 Push-ups / Pull-ups", "12 DB C&J / Snatch",
                        "15 Burpees / Wall Walks"]
    assert c.cap_line is None
    n = card_of("wod.nightmareAmrap")
    assert n.name == "Nightmare AMRAP 20" and n.time_domain_line == "20 min AMRAP"
    assert texts(n) == ["10 Lateral Burpees Over DB", "31 DU", "10 ALT DB Snatches", "31 DU"]


def test_hyrox_run_before_each_station():
    c = card_of("hyrox.solo")
    assert c.type_label == "Chipper" and c.time_domain_line is None
    assert c.rep_scheme_line == "8 × (1000 m Run + station)"
    assert texts(c)[0] == "1000 m SkiErg" and texts(c)[-1] == "100 Wall Balls" and len(c.lines) == 8
    shown, hidden = c.visible_lines()
    assert len(shown) == 4 and hidden == 4
    assert card_of("hyrox.half").rep_scheme_line == "8 × (500 m Run + station)"


def test_chipper_lists_everything_with_loads():
    c = card_of("partner.wod1")
    assert c.type_label == "Chipper" and c.time_domain_line is None and c.cap_line == "30 min cap"
    assert texts(c)[:2] == ["800 m Run", "80 Wall Balls @14 lb"]
    assert texts(c)[-1] == "10 Devil Press @2 × 40 lb"
    shown, hidden = c.visible_lines()
    assert len(shown) == 4 and hidden == 6


def test_free_workout():
    c = card_of("free.workout")
    assert (c.name, c.type_tag, c.block_tag, c.time_domain_line) == ("Free Workout", None, None, None)
    assert texts(c) == ["Turn the Crown at each change"]


def test_shared_scheme_for_every_movement_and_no_name():
    """Diane-like: 21-15-9 on both movements, no name → the format is the name."""
    dl = WorkoutSegment("station", "deadlift", "Deadlift", SegmentTarget(21, "reps"), SegmentLoad(225, "lb"))
    hs = WorkoutSegment("station", "hspu", "HSPU", SegmentTarget(21, "reps"))
    segs = []
    for v in (21, 15, 9):
        a = WorkoutSegment(dl.kind, dl.movement, dl.name, SegmentTarget(v, "reps"), dl.load)
        b = WorkoutSegment(hs.kind, hs.movement, hs.name, SegmentTarget(v, "reps"))
        segs += [a, b]
    d = WorkoutDefinition("x", "", "", "forTime", "solo", 480.0, "crossTraining", segs, round_size=2)
    c = WorkoutCard.make(d)
    assert c.rep_scheme_line == "21-15-9"
    assert texts(c) == ["Deadlift @225 lb", "HSPU"]
    assert c.type_label == "RFT" and c.time_domain_line == "3 rounds"
    assert (c.name, c.name_is_format) == ("3 rounds", True)
    assert c.cap_line == "8 min cap"
    assert c.summary_line == "21-15-9 Deadlift @225 lb · HSPU"


def test_single_rep_is_singular_and_odd_durations():
    seg = WorkoutSegment("station", "pullUps", "Pull-ups", SegmentTarget(1, "reps"))
    d = WorkoutDefinition("y", "Odd", "Odd", "amrap", "solo", 450.0, "crossTraining", [seg])
    c = WorkoutCard.make(d)
    assert texts(c) == ["1 Pull-up"]
    assert c.time_domain_line == "7:30 AMRAP"
