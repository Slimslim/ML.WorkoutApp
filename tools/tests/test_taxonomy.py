"""Workout taxonomy (tools/barpath/taxonomy.py, docs/WORKOUT_TAXONOMY.md). Every fixture here is
invented; none comes from a program or a gym."""
import pytest

from barpath import taxonomy as tx
from barpath.workout import WorkoutLibrary


def part(mid, unit=None, value=None, load=None, pid=None, who=None):
    c = {"movement": mid}
    if who:
        c["who"] = who
    if unit:
        c["target"] = {"unit": unit, "value": value}
    if load:
        c["load"] = load
    if pid:
        c["id"] = pid
    return {"part": c}


def rest(seconds):
    return {"rest": {"seconds": seconds}}


def repeat(times, body, vary=None):
    r = {"times": times, "body": body}
    if vary:
        r["vary"] = vary
    return {"repeat": r}


def timed(seconds, body, late="end"):
    return {"timed": {"seconds": seconds, "late": late, "body": body}}


def group(body, load=None, as_step=True):
    g = {"id": "cx", "asStep": as_step, "body": body}
    if load:
        g["load"] = load
    return {"group": g}


def ratio_rest(r):
    return {"rest": {"ratio": r}}


def v2(body, score, team="solo"):
    return {"schemaVersion": 2, "team": team, "structure": {"body": body, "score": {"type": score}}}


def values(doc, **kw):
    c = tx.classify_definition(doc, **kw)
    return {k: c[k]["value"] for k in AXES}


AXES = ("modality", "movements", "structure", "time_domain", "loading", "scoring")


def kg(v):
    return {"value": v, "unit": "kg"}


# ---- movements and structure ------------------------------------------------------------------

def test_movement_count_is_its_own_axis():
    single = v2([part("run", "meters", 1600)], "time")
    assert values(single)["movements"] == "single" and values(single)["structure"] == "for_time"
    couplet = v2([repeat(5, [part("pullUps", "reps", 10), part("pushUps", "reps", 20)])], "time")
    assert values(couplet)["movements"] == "couplet" and values(couplet)["structure"] == "rounds"
    triplet = v2([repeat(3, [part("run", "meters", 400), part("kettlebellSwings", "reps", 21),
                             part("pullUps", "reps", 12)])], "time")
    assert values(triplet)["movements"] == "triplet"
    amrap = v2([timed(1200, [repeat(None, [part("row", "calories", 10), part("wallBalls", "reps", 10),
                                           part("burpees", "reps", 10), part("sitUps", "reps", 10)])])],
               "roundsReps")
    assert values(amrap)["movements"] == "4plus" and values(amrap)["structure"] == "amrap"


def test_chipper_is_one_pass_of_four_or_more():
    chip = v2([part("row", "calories", 30), part("wallBalls", "reps", 40), part("boxJumps", "reps", 30),
               part("burpees", "reps", 20), part("run", "meters", 800)], "time")
    assert values(chip)["structure"] == "chipper"
    rounds = v2([repeat(4, [part("row", "calories", 10), part("wallBalls", "reps", 10),
                            part("burpees", "reps", 10), part("sitUps", "reps", 10)])], "time")
    assert values(rounds)["structure"] == "rounds" and values(rounds)["movements"] == "4plus"


def test_rep_schemes_are_modifiers_not_ladders():
    desc = v2([repeat(3, [part("thrusters", "reps", 21, pid="a"), part("pullUps", "reps", 21, pid="b")],
                      vary={"a": [21, 15, 9], "b": [21, 15, 9]})], "time")
    c = tx.classify_definition(desc)["structure"]
    assert c["value"] == "rounds" and "reps_descending" in c["modifiers"]
    asc = v2([repeat(10, [part("pushUps", "reps", 1, pid="a")], vary={"a": list(range(1, 11))})], "time")
    assert "reps_ascending" in tx.classify_definition(asc)["structure"]["modifiers"]
    pyr = v2([repeat(5, [part("burpees", "reps", 5, pid="a")], vary={"a": [5, 10, 15, 10, 5]})], "time")
    assert "pyramid" in tx.classify_definition(pyr)["structure"]["modifiers"]
    zigzag = v2([repeat(3, [part("burpees", "reps", 5, pid="a")], vary={"a": [10, 5, 10]})], "time")
    mods = tx.classify_definition(zigzag)["structure"]["modifiers"]
    assert not any(m.startswith("reps_") or m in ("pyramid", "open_ladder") for m in mods)


def test_open_ladder_climbs_until_the_clock():
    doc = v2([timed(600, [repeat(None, [part("thrusters", "reps", 2, pid="a"), part("pullUps", "reps", 2, pid="b")],
                                vary={"a": {"from": 2, "step": 2}, "b": {"from": 2, "step": 2}})])], "totalReps")
    v = values(doc)
    assert v["structure"] == "ladder" and v["time_domain"] == "medium"
    death_by = v2([repeat(None, [timed(60, [part("burpees", "reps", 1, pid="a")], late="cut")],
                          vary={"a": {"from": 1, "step": 1}})], "roundsReps")
    v = values(death_by)
    assert v["structure"] == "ladder" and v["scoring"] == "rounds_reps" and v["time_domain"] == tx.UNKNOWN


def test_intervals_emom_tabata_work_rest():
    emom = v2([repeat(10, [timed(60, [part("burpees", "reps", 8), part("kettlebellSwings", "reps", 10)],
                                 late="cut")])], "none")
    c = tx.classify_definition(emom)
    assert c["structure"]["value"] == "intervals" and c["scoring"]["value"] == "none"
    assert c["time_domain"]["value"] == "medium" and c["time_domain"]["work_bout"] == "short"
    tabata = v2([repeat(8, [timed(20, [part("airSquats", "reps", None)]), rest(10)])], "lowestReps")
    c = tx.classify_definition(tabata)
    assert c["structure"]["value"] == "intervals" and c["time_domain"]["seconds"] == 240
    assert c["loading"]["value"] == "bodyweight"
    work_rest = v2([repeat(5, [part("row", "meters", 500), rest(90)])], "time")
    c = tx.classify_definition(work_rest)
    assert c["structure"]["value"] == "intervals" and c["structure"]["reasons"] == ["intervals:work_rest"]
    assert c["time_domain"]["work_bout"] == "medium"


def test_strength_is_structural():
    sets = v2([repeat(5, [part("backSquat", "reps", 5, load={"percent": 80, "basis": "1RM"})])], "load")
    v = values(sets)
    assert v["structure"] == "strength" and v["scoring"] == "load" and v["loading"] == "heavy"
    assert v["time_domain"] == tx.NA
    # a loaded low-rep EMOM is strength in an interval wrapper, even when nothing is scored
    emom = v2([repeat(10, [timed(90, [part("powerCleans", "reps", 2, load=kg(80))], late="cut")])], "none")
    c = tx.classify_definition(emom)["structure"]
    assert c["value"] == "strength" and "interval_wrapper" in c["modifiers"]
    # a heavy single scored by load
    single = v2([repeat(None, [part("deadlifts", "reps", 1)])], "load")
    c = tx.classify_definition(single)["structure"]
    assert c["value"] == "strength" and "max_effort" in c["modifiers"]
    # high reps of one loaded movement for time is not strength
    burner = v2([part("thrusters", "reps", 100, load=kg(20))], "time")
    assert values(burner)["structure"] == "for_time"


def test_complex_is_strength_with_one_implement():
    doc = v2([repeat(5, [group([part("powerCleans", "reps", 1), part("frontSquat", "reps", 1),
                                part("pushJerk", "reps", 1)], load={"percent": 75})])], "load")
    c = tx.classify_definition(doc)
    assert c["structure"]["value"] == "strength" and "complex" in c["structure"]["modifiers"]
    assert c["loading"]["value"] == "moderate"


def test_practice_has_no_time_domain_or_loading():
    doc = v2([part("handstandPushUps", "seconds", 600)], "none")
    v = values(doc)
    assert v["structure"] == "practice" and v["time_domain"] == tx.NA and v["loading"] == tx.NA
    assert tx.classify_definition(doc)["time_domain"]["confidence"] == "high"


def test_multi_part_classifies_each_piece():
    multi = {"schemaVersion": 2, "structure": {"score": {"type": "perPiece"}, "body": [
        timed(300, [repeat(None, [part("burpees", "reps", 5)])]),
        repeat(5, [part("backSquat", "reps", 3, load={"percent": 85})])]}}
    c = tx.classify_definition(multi)
    assert c["structure"]["value"] == "multi_part"
    assert c["structure"]["pieces"] == ["amrap", "strength"]
    assert [p["structure"]["value"] for p in c["pieces"]] == ["amrap", "strength"]
    assert c["scoring"]["value"] == "per_piece"


def test_buy_in_and_cash_out_do_not_count_as_movements():
    doc = v2([timed(900, [part("run", "meters", 800), repeat(None, [part("pullUps", "reps", 5),
                                                                    part("pushUps", "reps", 10)]),
                          part("run", "meters", 800)])], "roundsReps")
    c = tx.classify_definition(doc)
    assert "buy_in" in c["structure"]["modifiers"] and "cash_out" in c["structure"]["modifiers"]
    assert c["movements"]["value"] == "couplet"


def test_partner_split_halves_the_work():
    solo = v2([part("row", "meters", 2000), part("burpees", "reps", 100)], "time")
    shared = v2([part("row", "meters", 2000, who="shared"), part("burpees", "reps", 100, who="shared")],
                "time", team="doubles")
    a = tx.classify_definition(solo)["time_domain"]["seconds"]
    c = tx.classify_definition(shared)
    assert "partner:split_as_needed" in c["structure"]["modifiers"]
    assert c["time_domain"]["seconds"] == pytest.approx(a / 2, abs=1)


# ---- time domain ------------------------------------------------------------------------------

@pytest.mark.parametrize("seconds,domain", [(300, "short"), (480, "short"), (600, "medium"),
                                             (1200, "long"), (2400, "very_long")])
def test_time_domain_from_the_clock(seconds, domain):
    doc = v2([timed(seconds, [repeat(None, [part("burpees", "reps", 5)])])], "roundsReps")
    c = tx.classify_definition(doc)["time_domain"]
    assert c["value"] == domain and c["confidence"] == "high"


def test_time_domain_for_time_cap_is_an_upper_bound():
    # 3 x (400 m run, 21 KB swings, 12 pull-ups) under a 20:00 cap: estimated work, not the cap
    doc = v2([timed(1200, [repeat(3, [part("run", "meters", 400), part("kettlebellSwings", "reps", 21),
                                      part("pullUps", "reps", 12)])], late="continue")], "time")
    c = tx.classify_definition(doc)["time_domain"]
    assert c["value"] == "medium" and c["reasons"] == ["estimated_under_cap"]


def test_time_domain_unknown_without_clock_or_work():
    doc = v2([repeat(None, [part("pullUps", "reps", None)])], "totalReps")
    assert tx.classify_definition(doc)["time_domain"]["value"] == tx.UNKNOWN


def test_per_movement_pace():
    du = tx.element_seconds(tx.Element("doubleUnders", "reps", 100))
    mu = tx.element_seconds(tx.Element("muscleUps", "reps", 100))
    assert du < 100 < mu
    ski = tx.element_seconds(tx.Element("skiErg", "calories", 20))
    row = tx.element_seconds(tx.Element("row", "calories", 20))
    bike = tx.element_seconds(tx.Element("bike", "calories", 20))
    assert bike < row < ski
    sled = tx.element_seconds(tx.Element("sledPush", "meters", 50))
    assert 100 <= sled <= 200


def test_ratio_rest_counts_in_the_work():
    base = v2([repeat(5, [part("row", "calories", 15)])], "time")
    ratio = v2([repeat(5, [part("row", "calories", 15), ratio_rest(1)])], "time")
    a = tx.classify_definition(base)["time_domain"]["seconds"]
    c = tx.classify_definition(ratio)
    assert c["time_domain"]["seconds"] == pytest.approx(2 * a, abs=1)
    assert "ratio_rest" in c["structure"]["modifiers"]


# ---- loading ----------------------------------------------------------------------------------

def test_loading_percent_standard_and_athlete_max():
    pct = lambda p: v2([repeat(5, [part("deadlifts", "reps", 3, load={"percent": p})])], "load")
    assert values(pct(55))["loading"] == "light"
    assert values(pct(70))["loading"] == "moderate"
    assert values(pct(85))["loading"] == "heavy"
    std = lambda v: v2([repeat(5, [part("thrusters", "reps", 10, load=kg(v))])], "time")
    assert values(std(25))["loading"] == "light"
    assert values(std(43))["loading"] == "moderate"
    assert values(std(60))["loading"] == "heavy"
    c = tx.classify_definition(std(43))["loading"]
    assert c["confidence"] == "medium" and c["reasons"] == ["vs_standard"]   # a proxy
    c = tx.classify_definition(std(60), athlete_max_kg={"thrusters": 120})["loading"]
    assert c["value"] == "light" and c["reasons"] == ["athlete_max"] and c["confidence"] == "high"


def test_bodyweight_is_not_unknown():
    assert values(v2([part("burpees", "reps", 50)], "time"))["loading"] == "bodyweight"
    no_ref = v2([repeat(5, [part("backSquat", "reps", 8, load=kg(100))])], "time")
    c = tx.classify_definition(no_ref)["loading"]
    assert c["value"] == tx.UNKNOWN and "no_reference" in c["reasons"]


def test_women_value_of_a_gendered_load():
    cls = {"format": "rft", "flags": [], "scoring": ["time"],
           "parsed": [{"kind": "rft", "rounds": 3, "movements": [{"name": "Thrusters", "reps": "15", "load": "95/65 lbs"}]}]}
    w = tx.from_draft_piece(cls)
    assert w.elements[0].load_kg_f == pytest.approx(65 / tx.LB_PER_KG)
    assert tx.classify(w, sex="f")["loading"]["value"] == "moderate"
    assert tx.classify(w, sex="m")["loading"]["value"] == "moderate"
    one = v2([repeat(5, [part("thrusters", "reps", 10, load=kg(29))])], "time")
    assert values(one, sex="f")["loading"] == "moderate" and values(one, sex="m")["loading"] == "light"


def test_implement_decides_the_standard():
    def piece(name, load):
        return tx.from_draft_piece({"format": "rft", "flags": [], "scoring": ["time"], "parsed": [
            {"kind": "rft", "rounds": 3, "movements": [{"name": name, "reps": "12", "load": load}]}]})
    assert tx.implement_of("DB Thrusters") == "dumbbell_pair"
    assert tx.implement_of("Single-arm DB Snatch") == "dumbbell"
    assert tx.implement_of("Goblet Squat") == "kettlebell"
    assert tx.classify(piece("DB Thrusters", "50 lbs"))["loading"]["value"] == "moderate"
    assert tx.classify(piece("Barbell Thrusters", "50 lbs"))["loading"]["value"] == "light"
    sandbag = tx.classify(piece("Sandbag Cleans", "100 lbs"))["loading"]
    assert sandbag["value"] == tx.UNKNOWN and "no_reference" in sandbag["reasons"]


# ---- scoring ----------------------------------------------------------------------------------

@pytest.mark.parametrize("score,kind", [("time", "time"), ("roundsReps", "rounds_reps"),
                                        ("totalReps", "reps"), ("lowestReps", "reps"), ("load", "load"),
                                        ("distance", "calories_distance"), ("calories", "calories_distance"),
                                        ("windowsCompleted", "pass_fail"), ("none", "none")])
def test_scoring_kinds(score, kind):
    assert values(v2([repeat(3, [part("row", "calories", 10)])], score))["scoring"] == kind


def test_emom_scoring_defaults_to_none():
    flat = {"format": "emom", "intervalSeconds": 60, "timeCapSeconds": 600,
            "segments": [{"movement": "burpees", "target": {"unit": "reps", "value": 8}}]}
    assert tx.classify_definition(flat)["scoring"]["value"] == "none"
    max_window = {"format": "intervals_max_reps", "flags": [], "scoring": ["none"],
                  "parsed": [{"kind": "intervals_max_reps", "rounds": 5, "window_s": 60,
                              "movements": [{"name": "Burpees", "reps": "max"}]}]}
    assert tx.classify(tx.from_draft_piece(max_window))["scoring"]["value"] == "reps"


# ---- modality and the Hyrox stations ----------------------------------------------------------

def test_modalities_and_primary():
    assert values(v2([part("run", "meters", 5000)], "time"))["modality"] == "M"
    assert values(v2([part("pullUps", "reps", 50)], "time"))["modality"] == "G"
    assert values(v2([part("cleans", "reps", 30)], "time"))["modality"] == "W"
    mixed = v2([part("run", "meters", 1600), part("thrusters", "reps", 15), part("burpees", "reps", 10)], "time")
    c = tx.classify_definition(mixed)["modality"]
    assert c["value"] == "GWM" and c["primary"] == "M"


def test_weighted_bodyweight_stays_g():
    doc = v2([part("pullUps", "reps", 10, load=kg(10))], "time")
    c = tx.classify_definition(doc)
    assert c["modality"]["value"] == "G" and c["modality"]["loaded"] is True
    assert "loaded_bodyweight" in c["structure"]["modifiers"]


def test_hyrox_is_a_chipper_with_runs_interleaved():
    stations = ["skiErg", "sledPush", "sledPull", "burpeeBroadJumps", "row", "farmersCarry",
                "sandbagLunges", "wallBalls"]
    doc = v2([repeat(8, [part("run", "meters", 1000), part("st", pid="st")],
                     vary={"st": [{"movement": m} for m in stations]})], "time")
    c = tx.classify_definition(doc)
    assert c["modality"]["stations"] == stations and c["modality"]["value"] == "GWM"
    assert c["structure"]["value"] == "chipper" and "run_interleaved" in c["structure"]["modifiers"]


def test_hyrox_loads_use_the_divisions_only_in_hyrox():
    race = [part("run", "meters", 1000) for _ in range(4)] + [
        part("sledPush", "meters", 50, load=kg(152)), part("sledPull", "meters", 50, load=kg(103)),
        part("wallBalls", "reps", 100, load=kg(6)), part("farmersCarry", "meters", 200, load=kg(24))]
    c = tx.classify_definition(v2(race, "time"))["loading"]
    assert c["value"] == "moderate" and "hyrox_division" in c["reasons"]
    crossfit = v2([repeat(3, [part("wallBalls", "reps", 20, load=kg(9)), part("burpees", "reps", 10)])], "time")
    c = tx.classify_definition(crossfit)["loading"]
    assert c["value"] == "moderate" and c["reasons"] == ["vs_standard"]


def test_built_ins_classify_without_unknown_scoring():
    for d in WorkoutLibrary.all:
        c = tx.classify_definition(d.to_dict())
        assert c["scoring"]["value"] != tx.UNKNOWN, d.id
    hyrox = tx.classify_definition(WorkoutLibrary.hyroxSolo.to_dict())
    assert hyrox["structure"]["value"] == "chipper" and hyrox["time_domain"]["value"] == "very_long"
    assert 70 * 60 <= hyrox["time_domain"]["seconds"] <= 100 * 60   # coach: Open about 75-100 min
    assert len(hyrox["modality"]["stations"]) == 8


# ---- free-text names and the import's parse (corpus adapter) -----------------------------------

@pytest.mark.parametrize("name,mid", [("Echo Bike", "bike"), ("Ski Erg", "skiErg"),
                                      ("Chest-to-Bar Pull-ups", "chestToBar"), ("DB Snatch", "dumbbellSnatch"),
                                      ("Kettlebell Swings", "kettlebellSwings"), ("Wall-Ball Shots", "wallBalls"),
                                      ("Double-Unders", "doubleUnders"), ("Sled Push", "sledPush"),
                                      ("Ring Rows", "ringRows"), ("Bent-over Row", "barbellRow"),
                                      ("SDHP", "sumoDeadliftHighPull"), ("GHD Sit-ups", "ghdSitUps"),
                                      ("Wall Walks", "wallWalks"), ("Toes-to-Ring", "toesToRing"),
                                      ("Sandbag to Shoulder", "sandbagToShoulder"), ("Yoke Carry", "yokeCarry"),
                                      ("Bear Crawl", "bearCrawl"), ("Shuttle Runs", "shuttleRun"),
                                      ("Front-Rack Lunges", "frontRackLunges"), ("Goblet Squats", "gobletSquats")])
def test_movement_names(name, mid):
    assert tx.movement_id(name) == mid


@pytest.mark.parametrize("name,mid", [("400m Runs", "run"), ("Running", "run"), ("Rowing", "row"),
                                      ("Assault Bikes", "bike")])
def test_plurals_and_ing(name, mid):
    assert tx.movement_id(name) == mid


def test_keyword_fallback_plurals():
    assert tx.modality_of("Invented Walks")[0] == "G"
    assert tx.modality_of("Invented Jumping")[0] == "G"


@pytest.mark.parametrize("text,expect", [("95/65 lbs", {"load_kg": 95 / tx.LB_PER_KG, "load_kg_f": 65 / tx.LB_PER_KG}),
                                         ("24/16 kg", {"load_kg": 24.0, "load_kg_f": 16.0}),
                                         ("75% 1RM", {"load_pct": 75.0, "load_basis": "1RM"}),
                                         ("pick load", {"pick_load": True}), ("", {}),
                                         ({"value": 43, "valueF": 29, "unit": "kg"}, {"load_kg": 43.0, "load_kg_f": 29.0})])
def test_parse_load(text, expect):
    got = tx.parse_load(text)
    assert set(got) == set(expect)
    for k, v in expect.items():
        assert got[k] == pytest.approx(v) if isinstance(v, float) else got[k] == v


def test_draft_piece_adapter():
    cls = {"format": "emom", "flags": [], "scoring": ["none or max reps"],
           "parsed": [{"kind": "emom", "rounds": 12, "window_s": 60, "header": "Every minute",
                       "movements": [{"name": "Power Clean", "reps": "3", "load": "135/95 lbs"}]}]}
    c = tx.classify(tx.from_draft_piece(cls))
    assert c["structure"]["value"] == "strength" and "interval_wrapper" in c["structure"]["modifiers"]
    assert c["time_domain"]["value"] == tx.NA
    assert c["modality"]["value"] == "W" and c["loading"]["value"] == "moderate"
    amrap = {"format": "amrap_rounds", "flags": ["ladder_ascending"], "scoring": ["rounds+reps"],
             "parsed": [{"kind": "amrap_rounds", "rounds": None, "header": "AMRAP 14",
                         "movements": [{"name": "Burpees", "reps": "5"}, {"name": "Row", "reps": "10", "unit": "cal"}]}]}
    c = tx.classify(tx.from_draft_piece(amrap))
    assert c["structure"]["value"] == "ladder" and c["time_domain"]["value"] == "medium"
    assert c["scoring"]["value"] == "rounds_reps" and c["modality"]["value"] == "GM"
    unknown = {"format": "for_time", "flags": [], "scoring": ["invented unknown label"],
               "parsed": [{"kind": "for_time", "movements": [{"name": "Zorbing", "reps": "10"}]}]}
    c = tx.classify(tx.from_draft_piece(unknown))
    assert c["scoring"]["value"] == tx.UNKNOWN and c["modality"]["value"] == tx.UNKNOWN


def test_every_axis_has_value_confidence_reasons():
    c = tx.classify_definition(v2([part("burpees", "reps", 100)], "time"))
    for axis in AXES:
        assert set(c[axis]) >= {"value", "confidence", "reasons"}
        if c[axis]["value"] == tx.UNKNOWN:
            assert c[axis]["confidence"] == tx.UNKNOWN
        if c[axis]["value"] == tx.NA:
            assert c[axis]["confidence"] == "high"


@pytest.mark.parametrize("text,total,window", [("AMRAP 12", 720, None), ("Every 3 mins for 15 mins", 900, 180),
                                               ("E2MOM", None, 120), ("Every 1:30", None, 90),
                                               ("20 min cap", 1200, None), ("For time:", None, None)])
def test_header_clock(text, total, window):
    assert tx.header_clock(text) == (total, window)


def test_instruction_lines_are_not_movements():
    cls = {"format": "emom", "flags": [], "scoring": ["none or max reps"],
           "parsed": [{"kind": "emom", "rounds": None, "header": "5 sets",
                       "movements": [{"name": "Every 2 mins for 10 mins."},
                                     {"name": "Front Squat", "reps": "3", "load": "80% 1RM"}]}]}
    w = tx.from_draft_piece(cls)
    assert [e.movement for e in w.elements] == ["Front Squat"]
    assert w.cap_s == 600
    c = tx.classify(w)
    assert c["structure"]["value"] == "strength" and c["loading"]["value"] == "heavy"


def test_corpus_script_prints_aggregates_only(tmp_path, capsys):
    import json
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import taxonomy_corpus
    secret = "Invented Secret Movement Name"
    rows = [{"id": "lib.test.20260101.a", "definition": {"scales": [{"rawText": secret, "classification": {
                "format": "for_time", "flags": [], "scoring": ["time"],
                "parsed": [{"kind": "for_time", "header": "For time", "movements": [
                    {"name": "Run", "distance": "800 m"}, {"name": secret, "reps": "10"}]}]}}]}},
            {"id": "lib.test.20260102.b", "definition": {"scales": [{"classification": {
                "format": "emom", "flags": [], "scoring": ["none"],
                "parsed": [{"kind": "emom", "rounds": 10, "window_s": 60, "header": "",
                            "movements": [{"name": "Burpees", "reps": "8"}]}]}}]}}]
    p = tmp_path / "export.json"
    p.write_text(json.dumps(rows))
    assert taxonomy_corpus.main(["--export", str(p), "--ids", "0"]) == 0
    out = capsys.readouterr().out
    assert "Pieces classified: 2" in out
    assert secret not in out and "lib.test" not in out
    stats = taxonomy_corpus.run([(r["id"], r["definition"]) for r in rows], 20)
    assert stats["counts"]["structure"] == {"for_time": 1, "intervals": 1}
    assert stats["counts"]["movements"] == {"couplet": 1, "single": 1}
    assert stats["movements"]["unknown"] == 1


# ---- architect review: RFC-valid inputs, v1 rule, determinism ----------------------------------

def test_movement_choice_never_throws():
    cardio = v2([repeat(5, [{"part": {"movement": {"choice": ["row", "bike", "skiErg"]},
                                      "target": {"unit": "calories", "value": 15}}}])], "time")
    c = tx.classify_definition(cardio)
    assert c["modality"]["value"] == "M" and "movement_choice" in c["notes"]
    any_cardio = v2([part("burpees", "reps", 10), {"part": {"movement": {"choice": "anyCardio"},
                                                             "target": {"unit": "calories", "value": 10}}}], "time")
    assert tx.classify_definition(any_cardio)["modality"]["value"] == "GM"
    mixed = v2([{"part": {"movement": {"choice": ["row", "thrusters"]}, "target": {"unit": "reps", "value": 10}}}], "time")
    c = tx.classify_definition(mixed)["modality"]
    assert c["value"] == tx.UNKNOWN and "movement_choice" in c["reasons"]


def test_pieces_come_from_the_body_not_the_score_type():
    two = {"schemaVersion": 2, "structure": {"score": {"type": "none", "combine": "sum"}, "body": [
        timed(300, [repeat(None, [part("burpees", "reps", 5)])]),
        timed(300, [repeat(None, [part("pullUps", "reps", 5)])])]}}
    c = tx.classify_definition(two)
    assert c["structure"]["value"] == "multi_part" and c["structure"]["pieces"] == ["amrap", "amrap"]
    assert c["scoring"]["value"] == "per_piece" and "combine:sum" in c["scoring"]["reasons"]


def test_per_piece_uses_the_metric():
    doc = {"schemaVersion": 2, "structure": {"score": {"type": "perPiece", "of": "r", "metric": "distance"},
                                             "body": [{"repeat": {"id": "r", "times": 5, "body": [
                                                 timed(120, [part("row", "meters", None)]), rest(60)]}}]}}
    assert tx.classify_definition(doc)["scoring"]["value"] == "calories_distance"


def test_v1_chipper_is_not_a_ladder():
    segs = [{"movement": m, "target": {"unit": "reps", "value": v}}
            for m, v in (("wallBalls", 50), ("boxJumps", 40), ("burpees", 30), ("pullUps", 20))]
    c = tx.classify_definition({"format": "forTime", "segments": segs, "roundSize": 2})
    assert c["structure"]["value"] == "chipper" and c["structure"]["modifiers"] == []
    assert "legacy_written_out" not in c["notes"]


def test_v1_written_out_rounds_fold_without_round_size():
    one = [("run", "meters", 400), ("kettlebellSwings", "reps", 21), ("pullUps", "reps", 12)]
    segs = [{"movement": m, "target": {"unit": u, "value": v}} for _ in range(3) for m, u, v in one]
    c = tx.classify_definition({"format": "forTime", "segments": segs, "roundSize": 1})
    assert c["structure"]["value"] == "rounds" and c["movements"]["value"] == "triplet"
    assert c["structure"]["confidence"] == "medium" and "legacy_written_out" in c["structure"]["reasons"]
    ladder = [{"movement": m, "target": {"unit": "reps", "value": v}}
              for v in (21, 15, 9) for m in ("thrusters", "pullUps")]
    c = tx.classify_definition({"format": "forTime", "segments": ladder})
    assert "reps_descending" in c["structure"]["modifiers"]


def test_counted_climb_uses_times():
    doc = v2([repeat(10, [part("pushUps", "reps", 1, pid="a")], vary={"a": {"from": 1, "step": 1}})], "time")
    w = tx.from_v2(doc)
    assert w.elements[0].value == pytest.approx(5.5)
    assert "reps_ascending" in tx.classify(w)["structure"]["modifiers"]


def test_women_value_from_v2_value_f():
    doc = v2([repeat(5, [part("thrusters", "reps", 10, load={"value": 43, "valueF": 29, "unit": "kg"})])], "time")
    assert values(doc, sex="f")["loading"] == "moderate" and values(doc, sex="m")["loading"] == "moderate"


def test_loading_confidence_drops_with_an_unreferenced_load():
    doc = v2([part("thrusters", "reps", 30, load=kg(43)), part("backSquat", "reps", 30, load=kg(100))], "time")
    c = tx.classify_definition(doc)["loading"]
    assert c["value"] == "moderate" and c["confidence"] == "low"


def test_all_unknown_movements_say_so():
    c = tx.classify_definition(v2([part("inventedMove", "reps", 10), part("otherMove", "reps", 5)], "time"))
    assert c["modality"]["reasons"] == ["unknown_movements:2"]


def test_rfc_features_leave_a_trace():
    doc = v2([{"repeat": {"times": 3, "override": [{"round": 3}], "body": [part("run", "ft", 600)]}}], "time")
    c = tx.classify_definition(doc)
    assert "override_ignored" in c["notes"] and "distance_converted" in c["notes"]
    w = tx.from_v2(doc)
    assert w.elements[0].unit == "meters" and w.elements[0].value == pytest.approx(182.88)


def test_classification_is_deterministic():
    import json
    doc = v2([timed(900, [part("run", "meters", 800), repeat(None, [part("pullUps", "reps", 5),
                                                                    part("thrusters", "reps", 10, load=kg(40))])])],
             "roundsReps")
    a = json.dumps(tx.classify_definition(doc), sort_keys=True)
    b = json.dumps(tx.classify_definition(doc), sort_keys=True)
    shuffled = json.loads(json.dumps(doc), object_pairs_hook=lambda kv: dict(reversed(kv)))
    assert a == b == json.dumps(tx.classify_definition(shuffled), sort_keys=True)


@pytest.mark.parametrize("doc", [
    {}, {"schemaVersion": 2}, {"schemaVersion": 2, "structure": {"body": "x"}},
    {"schemaVersion": 2, "structure": {"body": [None, 3, {"part": None}, {"part": {"movement": 7}}]}},
    {"schemaVersion": 2, "structure": {"body": [{"repeat": {"times": "x", "body": [{"timed": {"seconds": "1:00"}}]}}]}},
    {"schemaVersion": 2, "structure": {"body": [{"repeat": {"until": "athlete", "vary": {"a": {"step": "x"}},
                                                            "body": [part("burpees", "reps", "ten", pid="a")]}}]}},
    {"schemaVersion": 2, "structure": {"body": [{"group": {"asStep": True, "load": {"percent": "x"},
                                                           "body": [part("cleans", "reps", 1)]}}]}},
    {"format": "amrap", "segments": [None, {"movement": {"choice": "anyCardio"}}], "timeCapSeconds": "x"},
])
def test_never_throws(doc):
    c = tx.classify_definition(doc)
    assert set(c) >= set(AXES)


# ---- Data chat corpus findings (invented equivalents) ------------------------------------------

def draft(kind, movements, header="", rounds=None, window_s=None, scoring="time", flags=(), clock=(), rest=(), fmt=None):
    piece = {"kind": kind, "rounds": rounds, "header": header, "movements": movements}
    if window_s is not None:
        piece["window_s"] = window_s
    return {"format": fmt or kind, "flags": list(flags), "scoring": [scoring], "clock": list(clock),
            "rest": list(rest), "parsed": [piece]}


def test_amrap_window_is_its_clock():
    c = tx.classify(tx.from_draft_piece(draft("amrap_rounds", [{"name": "Burpees", "reps": "10"}],
                                              window_s=720, scoring="rounds+reps")))
    assert c["structure"]["value"] == "amrap" and c["time_domain"]["seconds"] == 720
    assert c["time_domain"]["reasons"] == ["clock"]


def test_interval_windows_from_header_total():
    c = tx.classify(tx.from_draft_piece(draft("intervals_max_reps", [{"name": "Burpees", "reps": "max"}],
                                              header="Every 2 mins for 12 mins", window_s=120, scoring="reps")))
    assert c["structure"]["value"] == "intervals" and c["time_domain"]["seconds"] == 720


def test_strength_movement_from_the_header():
    w = tx.from_draft_piece(draft("strength_sets", [{"name": "Build across the sets, rest as needed between each one"}],
                                  header="Back Squat 5-5-3-3-1", scoring="load", clock=["none (rest between sets)"]))
    assert [tx.movement_id(e.movement) for e in w.elements] == ["backSquat"]
    assert w.passes == 5 and w.elements[0].value == pytest.approx(3.4)
    c = tx.classify(w)
    assert c["modality"]["value"] == "W" and c["structure"]["value"] == "strength"


def test_bracketed_complex_line():
    w = tx.from_draft_piece(draft("strength_sets", [{"name": "4x [Power Clean + Front Squat + Push Jerk]",
                                                     "load": "70% 1RM"}], scoring="load"))
    assert len(w.elements) == 3 and w.complex and w.passes == 4
    c = tx.classify(w)
    assert c["structure"]["value"] == "strength" and "complex" in c["structure"]["modifiers"]


def test_two_movements_on_one_line():
    w = tx.from_draft_piece(draft("for_time", [{"name": "Thrusters + Pull-ups", "reps": "15"}]))
    assert [tx.movement_id(e.movement) for e in w.elements] == ["thrusters", "pullUps"]


def test_every_n_minutes_is_intervals_not_ratio_rest():
    c = tx.classify(tx.from_draft_piece(draft("rft_each_round_timed", [
        {"name": "Row", "reps": "15", "unit": "cal"}, {"name": "Burpees", "reps": "10"}],
        header="Every 3 mins x 5", rounds=5, clock=["athlete per round; rest ratio from clock"])))
    assert c["structure"]["value"] == "intervals" and "ratio_rest" not in c["structure"]["modifiers"]
    assert c["time_domain"]["seconds"] == 900


def test_combined_scoring_labels_are_split():
    hold = tx.from_draft_piece(draft("max_effort_test", [{"name": "Plank", "time": "max"}],
                                     scoring="load, reps or hold time"))
    hold.elements[0].unit = "seconds"
    assert tx._draft_score("load, reps or hold time", "max_effort_test", hold, False) == "longestHold"
    lift = draft("max_effort_test", [{"name": "Deadlift", "reps": "1", "load": "pick load"}], scoring="time or load")
    assert tx.classify(tx.from_draft_piece(lift))["scoring"]["value"] == "load"
    metcon = draft("for_time", [{"name": "Burpees", "reps": "50"}], scoring="time or load")
    assert tx.classify(tx.from_draft_piece(metcon))["scoring"]["value"] == "time"
    fail_out = draft("emom", [{"name": "Burpees", "reps": "10"}], rounds=10, window_s=60, scoring="none",
                     clock=["clock (miss a minute and you are out)"])
    assert tx.classify(tx.from_draft_piece(fail_out))["scoring"]["value"] == "pass_fail"


def test_repeated_timed_pieces_are_one_set_of_windows():
    piece = {"kind": "amrap_reps", "rounds": None, "header": "AMRAP 4", "movements": [{"name": "Burpees", "reps": "5"}]}
    cls = {"format": "amrap_reps", "flags": [], "scoring": ["reps"], "parsed": [dict(piece), dict(piece), dict(piece)]}
    c = tx.classify(tx.from_draft_piece(cls))
    assert c["structure"]["value"] == "intervals" and c["time_domain"]["seconds"] == 720


def test_single_buy_in_window_is_an_amrap_with_a_buy_in():
    c = tx.classify(tx.from_draft_piece(draft("window_buyin_max_reps", [
        {"name": "Run", "distance": "400 m"}, {"name": "Wall Balls", "reps": "max"}], window_s=600, scoring="reps")))
    assert c["structure"]["value"] == "amrap" and "buy_in" in c["structure"]["modifiers"]


def test_rest_lines_and_target_heights():
    w = tx.from_draft_piece(draft("rft", [{"name": "Wall Balls", "reps": "20", "distance": "10/9 ft"},
                                          {"name": "Rest", "time": "60 secs"}], rounds=3))
    assert [e.unit for e in w.elements] == ["reps"] and w.rest_s == 180
    assert "height_not_distance" in w.notes


def test_corpus_ids_are_opt_in_and_errors_counted(capsys):
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    import taxonomy_corpus
    rows = [("lib.test.a", {"scales": [{"classification": draft("for_time", [{"name": "Burpees", "reps": "5"}])}]}),
            ("lib.test.b", "not a dict"),
            ("lib.test.c", {"scales": [{"classification": {"format": "emom", "parsed": [{"window_s": {"x": 1}}]}}]})]
    for n in (-1, -5, 0):
        stats = taxonomy_corpus.run(rows, n)
        assert "lib.test" not in str(stats)
    stats = taxonomy_corpus.run(rows)
    assert stats["pieces"] >= 1 and stats["classifier_error"]["count"] >= 1
    assert "lib.test" not in str(stats)


# ---- corpus rerun at a9fda39 (Data chat, 20 Nov): regressions and top patterns ----------------
# Every fixture is invented: no draft ids, programme names or programme text.

def test_strength_sets_without_a_parsed_load_stay_strength():
    # an unknown accessory in sets, scored by load, no load parsed: strength, loaded (not bodyweight)
    w = tx.from_draft_piece(draft("strength_sets", [], header="Zottman curl 10-10-10-10", scoring="load",
                                  clock=["none (rest between sets)"]))
    assert len(w.elements) == 1 and w.passes == 4
    c = tx.classify(w)
    assert c["structure"]["value"] == "strength" and c["movements"]["value"] == "single"
    assert c["loading"]["value"] == tx.UNKNOWN and c["loading"]["value"] != "bodyweight"
    # the import's strength kind alone, even scored by time
    k = tx.classify(tx.from_draft_piece(draft("strength_sets", [{"name": "Goblet Squat", "reps": "8"}],
                                              rounds=4, scoring="time")))
    assert k["structure"]["value"] == "strength"


def test_implement_word_means_loaded_and_w():
    c = tx.classify(tx.from_draft_piece(draft("strength_sets", [{"name": "DB Bulgarian Split Squat", "reps": "10"}],
                                              rounds=3, scoring="load")))
    assert c["modality"]["value"] == "W" and c["loading"]["value"] != "bodyweight"
    assert tx.modality_of("Kettlebell Squat")[0] == "W"
    assert tx.modality_of("Sandbag Squat")[0] == "W"
    # a vest or "weighted" gymnastics stays G
    assert tx.modality_of("Weighted Pull-ups")[0] == "G"
    assert tx.modality_of("Vest Push-ups")[0] == "G"


def test_load_on_an_unknown_name_is_w():
    c = tx.classify(tx.from_draft_piece(draft("for_time", [{"name": "Zorb toss", "reps": "20", "load": "20 kg"}])))
    assert c["modality"]["value"] == "W"


def test_heaviest_means_loaded():
    w = tx.from_draft_piece(draft("for_time", [{"name": "Zorb lift", "reps": "1"}], header="Find your heaviest single",
                                  scoring="time"))
    assert tx.classify(w)["loading"]["value"] == tx.UNKNOWN


def test_nothing_loaded_and_unknown_is_bodyweight():
    c = tx.classify(tx.from_draft_piece(draft("for_time", [{"name": "Zorbing", "reps": "30"}])))
    assert c["loading"]["value"] == "bodyweight" and c["loading"]["confidence"] == "low"


def test_for_distance_minutes_are_a_clock_not_a_cap():
    # 30 min for distance: 30 min, even though the work estimate is shorter
    w = tx.from_draft_piece(draft("for_distance", [{"name": "Row", "distance": "1000 m"}],
                                  header="30 min for distance", scoring="distance"))
    c = tx.classify(w)["time_domain"]
    assert c["seconds"] == 1800 and c["value"] == "long" and c["reasons"] == ["clock_not_cap"]
    # a time-scored piece keeps the cap as an upper bound
    t = tx.classify(tx.from_draft_piece(draft("for_time", [{"name": "Burpees", "reps": "30"}],
                                              header="30 min cap", scoring="time")))["time_domain"]
    assert t["reasons"] == ["estimated_under_cap"]


def test_rounds_each_window():
    c = tx.classify(tx.from_draft_piece(draft("repeat_windows_max_reps", [{"name": "Burpees", "reps": "max"}],
                                              header="5 rounds, 1 min each", rounds=5, scoring="reps")))
    assert c["structure"]["value"] == "intervals" and c["time_domain"]["seconds"] == 300


def test_tabata_defaults_and_custom():
    c = tx.classify(tx.from_draft_piece(draft("tabata", [{"name": "Air Squats", "reps": "max"}], scoring="reps")))
    assert c["time_domain"]["seconds"] == 240 and c["time_domain"]["work_bout"] == "short"
    custom = tx.from_draft_piece(draft("tabata", [{"name": "Air Squats", "reps": "max"}], rounds=6,
                                       header="Tabata 40 sec on / 20 sec rest", scoring="reps"))
    assert custom.window_s == 60 and custom.work_s_per_window == 40 and custom.windows == 6
    assert tx.classify(custom)["time_domain"]["seconds"] == 360


def test_death_by_rule_lines_are_not_movements():
    w = tx.from_draft_piece(draft("death_by", [{"name": "Burpees"}, {"name": "1 rep in the 1st minute"},
                                                {"name": "2 reps in the 2nd minute"}], window_s=60,
                                  scoring="rounds+reps"))
    c = tx.classify(w)
    assert c["movements"]["value"] == "single" and "death_by_line" in w.notes


def test_cardio_is_m_and_drag_curl_is_known():
    assert tx.modality_of("Cardio of choice")[0] == "M"
    assert tx.modality_of("Swim")[0] == "M"
    assert tx.movement_id("Drag Curl") == "dragCurl" and tx.modality_of("Drag Curl")[0] == "W"


def test_db_clean_and_jerk_standard():
    c = tx.classify(tx.from_draft_piece(draft("for_time", [{"name": "DB Clean and Jerk", "reps": "30",
                                                           "load": "50/35 lbs"}])))
    assert c["loading"]["value"] == "moderate" and "vs_standard" in c["loading"]["reasons"]


def test_header_distance_gives_a_time_estimate():
    w = tx.from_draft_piece(draft("for_time", [{"name": "Run 5k"}]))
    assert w.elements[0].unit == "meters" and w.elements[0].value == 5000
    assert tx.classify(w)["time_domain"]["value"] != tx.UNKNOWN


def test_repeated_amrap_segments_are_intervals():
    cls = draft("amrap_rounds", [], scoring="rounds+reps")
    cls["parsed"][0]["segments"] = [
        {"header": "AMRAP 4", "movements": [{"name": "Burpees", "reps": "5"}, {"name": "Air Squats", "reps": "10"}]},
        {"header": "AMRAP 4", "movements": [{"name": "Push-ups", "reps": "10"}, {"name": "Sit-ups", "reps": "10"}]},
        {"header": "AMRAP 4", "movements": [{"name": "Lunges", "reps": "10"}, {"name": "Box Jumps", "reps": "10"}]}]
    c = tx.classify(tx.from_draft_piece(cls))
    assert c["structure"]["value"] == "intervals" and c["time_domain"]["seconds"] == 720


def test_until_failure_emom_is_an_open_ladder():
    c = tx.classify(tx.from_draft_piece(draft("emom", [{"name": "Burpees", "reps": "3"}], window_s=60,
                                              header="EMOM until failure, add a rep each minute",
                                              scoring="rounds+reps")))
    assert c["structure"]["value"] == "ladder"


def test_hold_is_scored_by_time():
    c = tx.classify(tx.from_draft_piece(draft("max_effort_test", [{"name": "Plank hold", "time": "max"}],
                                              scoring="load")))
    assert c["scoring"]["value"] == "time"


def test_amrap_buy_in_is_not_a_movement():
    w = tx.from_draft_piece(draft("amrap_rounds", [{"name": "Run", "distance": "800 m"},
                                                    {"name": "Burpees", "reps": "10"},
                                                    {"name": "Air Squats", "reps": "15"}],
                                  window_s=900, scoring="rounds+reps", flags=["buyin_cashout_named"]))
    c = tx.classify(w)
    assert c["movements"]["value"] == "couplet" and "buy_in" in c["structure"]["modifiers"]
