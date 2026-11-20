"""Workout taxonomy (tools/barpath/taxonomy.py, docs/WORKOUT_TAXONOMY.md). Every fixture here is
invented; none comes from a program or a gym."""
import pytest

from barpath import taxonomy as tx
from barpath.workout import WorkoutLibrary


def part(mid, unit=None, value=None, load=None, pid=None):
    c = {"movement": mid}
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


def v2(body, score, team="solo"):
    return {"schemaVersion": 2, "team": team, "structure": {"body": body, "score": {"type": score}}}


def values(doc, **kw):
    c = tx.classify_definition(doc, **kw)
    return {k: c[k]["value"] for k in ("modality", "shape", "time_domain", "loading", "scoring")}


# ---- shapes -----------------------------------------------------------------------------------

def test_single_couplet_triplet():
    single = v2([part("run", "meters", 1600)], "time")
    assert values(single)["shape"] == "single"
    couplet = v2([repeat(5, [part("pullUps", "reps", 10), part("pushUps", "reps", 20)])], "time")
    assert values(couplet)["shape"] == "couplet"
    triplet = v2([repeat(3, [part("run", "meters", 400), part("kettlebellSwings", "reps", 21),
                             part("pullUps", "reps", 12)])], "time")
    assert values(triplet)["shape"] == "triplet"


def test_chipper_and_rounds_of_four():
    chip = v2([part("row", "calories", 30), part("wallBalls", "reps", 40), part("boxJumps", "reps", 30),
               part("burpees", "reps", 20), part("run", "meters", 800)], "time")
    assert values(chip)["shape"] == "chipper"
    rounds = v2([timed(1200, [repeat(None, [part("row", "calories", 10), part("wallBalls", "reps", 10),
                                            part("burpees", "reps", 10), part("sitUps", "reps", 10)])])],
                "roundsReps")
    assert values(rounds)["shape"] == "rounds"


def test_ladders():
    asc = v2([timed(600, [repeat(None, [part("thrusters", "reps", 2, pid="a"), part("pullUps", "reps", 2, pid="b")],
                                vary={"a": {"from": 2, "step": 2}, "b": {"from": 2, "step": 2}})])], "totalReps")
    assert values(asc)["shape"] == "ladder"
    assert tx.classify_definition(asc)["shape"]["reasons"] == ["ladder:ascending"]
    desc = v2([repeat(3, [part("thrusters", "reps", 21, pid="a"), part("pullUps", "reps", 21, pid="b")],
                      vary={"a": [21, 15, 9], "b": [21, 15, 9]})], "time")
    assert tx.classify_definition(desc)["shape"]["reasons"] == ["ladder:descending"]


def test_intervals_emom_tabata_work_rest():
    emom = v2([repeat(10, [timed(60, [part("powerCleans", "reps", 3)], late="cut")])], "windowsCompleted")
    v = values(emom)
    assert v["shape"] == "intervals" and v["scoring"] == "pass_fail" and v["time_domain"] == "medium"
    tabata = v2([repeat(8, [timed(20, [part("airSquats", "reps", None)]), rest(10)])], "lowestReps")
    assert values(tabata)["shape"] == "intervals"
    work_rest = v2([repeat(5, [part("row", "meters", 500), rest(90)])], "perPiece")
    assert values(work_rest)["shape"] == "intervals"


def test_strength_sets_and_multi_part():
    sets = v2([repeat(5, [part("backSquat", "reps", 5, load={"percent": 80, "basis": "1RM"})])], "load")
    v = values(sets)
    assert v["shape"] == "strength_sets" and v["scoring"] == "load" and v["loading"] == "heavy"
    multi = {"schemaVersion": 2, "structure": {"score": {"type": "perPiece"}, "body": [
        timed(300, [repeat(None, [part("burpees", "reps", 5)])]),
        timed(300, [repeat(None, [part("row", "calories", 10)])])]}}
    assert values(multi)["shape"] == "multi_part"


def test_buy_in_and_cash_out_modifiers():
    doc = v2([timed(900, [part("run", "meters", 800), repeat(None, [part("pullUps", "reps", 5),
                                                                    part("pushUps", "reps", 10)]),
                          part("run", "meters", 800)])], "roundsReps")
    mods = tx.classify_definition(doc)["shape"]["modifiers"]
    assert "buy_in" in mods and "cash_out" in mods


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


# ---- loading ----------------------------------------------------------------------------------

def test_loading_percent_rx_and_athlete_max():
    pct = lambda p: v2([repeat(5, [part("deadlifts", "reps", 3, load={"percent": p})])], "load")
    assert values(pct(55))["loading"] == "light"
    assert values(pct(70))["loading"] == "moderate"
    assert values(pct(85))["loading"] == "heavy"
    rx = lambda kg: v2([repeat(5, [part("thrusters", "reps", 10, load={"value": kg, "unit": "kg"})])], "time")
    assert values(rx(25))["loading"] == "light"
    assert values(rx(43))["loading"] == "moderate"
    assert values(rx(60))["loading"] == "heavy"
    assert tx.classify_definition(rx(43))["loading"]["confidence"] == "medium"   # RX is a proxy
    # relative to the athlete: 60 kg is light for a 120 kg thruster max
    c = tx.classify_definition(rx(60), athlete_max_kg={"thrusters": 120})["loading"]
    assert c["value"] == "light" and c["reasons"] == ["athlete_max"] and c["confidence"] == "high"


def test_loading_unknown_without_load_or_reference():
    assert values(v2([part("burpees", "reps", 50)], "time"))["loading"] == tx.UNKNOWN
    no_ref = v2([repeat(5, [part("backSquat", "reps", 5, load={"value": 100, "unit": "kg"})])], "load")
    c = tx.classify_definition(no_ref)["loading"]
    assert c["value"] == tx.UNKNOWN and "no_reference" in c["reasons"]


def test_women_rx_standard():
    doc = v2([repeat(5, [part("thrusters", "reps", 10, load={"value": 29, "unit": "kg"})])], "time")
    assert values(doc, sex="f")["loading"] == "moderate"
    assert values(doc, sex="m")["loading"] == "light"


# ---- scoring ----------------------------------------------------------------------------------

@pytest.mark.parametrize("score,kind", [("time", "time"), ("roundsReps", "rounds_reps"),
                                        ("totalReps", "reps"), ("lowestReps", "reps"), ("load", "load"),
                                        ("distance", "calories_distance"), ("calories", "calories_distance"),
                                        ("windowsCompleted", "pass_fail"), ("none", "none")])
def test_scoring_kinds(score, kind):
    assert values(v2([repeat(3, [part("row", "calories", 10)])], score))["scoring"] == kind


# ---- modality and the Hyrox stations ----------------------------------------------------------

def test_modalities():
    assert values(v2([part("run", "meters", 5000)], "time"))["modality"] == "M"
    assert values(v2([part("pullUps", "reps", 50)], "time"))["modality"] == "G"
    assert values(v2([part("cleans", "reps", 30)], "time"))["modality"] == "W"
    mixed = v2([part("row", "calories", 20), part("thrusters", "reps", 15), part("burpees", "reps", 10)], "time")
    assert values(mixed)["modality"] == "GWM"


def test_loaded_bodyweight_counts_as_w():
    doc = v2([part("pullUps", "reps", 10, load={"value": 10, "unit": "kg"})], "time")
    c = tx.classify_definition(doc)["modality"]
    assert c["value"] == "W" and "loaded_bodyweight" in c["reasons"]


def test_hyrox_stations_are_tagged():
    stations = ["skiErg", "sledPush", "sledPull", "burpeeBroadJumps", "row", "farmersCarry",
                "sandbagLunges", "wallBalls"]
    doc = v2([repeat(8, [part("run", "meters", 1000), part("st", pid="st")],
                     vary={"st": [{"movement": m} for m in stations]})], "time")
    c = tx.classify_definition(doc)
    assert c["modality"]["stations"] == stations
    assert c["modality"]["value"] == "GWM"
    assert c["shape"]["value"] == "chipper"      # a different station each round: one pass


def test_built_ins_classify_without_unknown_scoring():
    for d in WorkoutLibrary.all:
        c = tx.classify_definition(d.to_dict())
        assert c["scoring"]["value"] != tx.UNKNOWN, d.id
    hyrox = tx.classify_definition(WorkoutLibrary.hyroxSolo.to_dict())
    assert hyrox["shape"]["value"] == "chipper" and hyrox["time_domain"]["value"] == "very_long"
    assert len(hyrox["modality"]["stations"]) == 8


# ---- free-text names and the import's parse (corpus adapter) -----------------------------------

@pytest.mark.parametrize("name,mid", [("Echo Bike", "bike"), ("Ski Erg", "skiErg"),
                                      ("Chest-to-Bar Pull-ups", "chestToBar"), ("DB Snatch", "dumbbellSnatch"),
                                      ("Kettlebell Swings", "kettlebellSwings"), ("Wall-Ball Shots", "wallBalls"),
                                      ("Double-Unders", "doubleUnders"), ("Sled Push", "sledPush"),
                                      ("Ring Rows", "ringRows"), ("Bent-over Row", None)])
def test_movement_names(name, mid):
    got = tx.movement_id(name)
    if mid is None:
        assert got != "row"
    else:
        assert got == mid


@pytest.mark.parametrize("text,expect", [("95/65 lbs", {"load_kg": 95 / tx.LB_PER_KG}),
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
    assert c["shape"]["value"] == "intervals"
    assert c["time_domain"]["value"] == "medium" and c["time_domain"]["seconds"] == 720
    assert c["modality"]["value"] == "W" and c["loading"]["value"] == "moderate"
    amrap = {"format": "amrap_rounds", "flags": ["ladder_ascending"], "scoring": ["rounds+reps"],
             "parsed": [{"kind": "amrap_rounds", "rounds": None, "header": "AMRAP 14",
                         "movements": [{"name": "Burpees", "reps": "5"}, {"name": "Row", "reps": "10", "unit": "cal"}]}]}
    c = tx.classify(tx.from_draft_piece(amrap))
    assert c["shape"]["value"] == "ladder" and c["time_domain"]["value"] == "medium"
    assert c["scoring"]["value"] == "rounds_reps" and c["modality"]["value"] == "GM"
    unknown = {"format": "for_time", "flags": [], "scoring": ["time or load"],
               "parsed": [{"kind": "for_time", "movements": [{"name": "Zorbing", "reps": "10"}]}]}
    c = tx.classify(tx.from_draft_piece(unknown))
    assert c["scoring"]["value"] == tx.UNKNOWN and c["modality"]["value"] == tx.UNKNOWN


def test_every_axis_has_value_confidence_reasons():
    c = tx.classify_definition(v2([part("burpees", "reps", 100)], "time"))
    for axis in ("modality", "shape", "time_domain", "loading", "scoring"):
        assert set(c[axis]) >= {"value", "confidence", "reasons"}
        if c[axis]["value"] == tx.UNKNOWN:
            assert c[axis]["confidence"] == tx.UNKNOWN


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
    c = tx.classify(w)
    assert c["time_domain"]["seconds"] == 600 and c["loading"]["value"] == "heavy"


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
    assert stats["counts"]["shape"] == {"couplet": 1, "intervals": 1}
    assert stats["movements"]["unknown"] == 1
