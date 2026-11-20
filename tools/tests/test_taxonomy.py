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
                                      ("Ring Rows", "ringRows"), ("Bent-over Row", None),
                                      ("SDHP", "sumoDeadliftHighPull"), ("GHD Sit-ups", "ghdSitUps"),
                                      ("Wall Walks", "wallWalks"), ("Toes-to-Ring", "toesToRing"),
                                      ("Sandbag to Shoulder", "sandbagToShoulder"), ("Yoke Carry", "yokeCarry"),
                                      ("Bear Crawl", "bearCrawl"), ("Shuttle Runs", "shuttleRun"),
                                      ("Front-Rack Lunges", "frontRackLunges"), ("Goblet Squats", "gobletSquats")])
def test_movement_names(name, mid):
    got = tx.movement_id(name)
    if mid is None:
        assert got != "row"
    else:
        assert got == mid


@pytest.mark.parametrize("text,expect", [("95/65 lbs", {"load_kg": 95 / tx.LB_PER_KG, "load_kg_f": 65 / tx.LB_PER_KG}),
                                         ("24/16 kg", {"load_kg": 24.0}),
                                         ("75% 1RM", {"load_pct": 75.0, "load_basis": "1RM"}),
                                         ("pick load", {"pick_load": True}), ("", {})])
def test_parse_load(text, expect):
    got = tx.parse_load(text)
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
    unknown = {"format": "for_time", "flags": [], "scoring": ["time or load"],
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
