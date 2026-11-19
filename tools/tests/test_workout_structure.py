"""v2 workout structure: validator, compiler, versioning (docs/WORKOUT_MODEL_RFC.md §3, §14)."""
import copy
import json

import pytest

from barpath import workout_engine as we
from barpath import workout_structure as ws
from barpath.workout import WorkoutLibrary
from engine_cases import ALL, EMOM, HYROX, PARTNER, TABATA, part


@pytest.mark.parametrize("name", sorted(ALL))
def test_every_case_is_valid_and_compiles_idempotently(name):
    doc = ALL[name]
    assert ws.validate(doc) == []
    once = ws.compile_definition(doc)
    assert ws.validate(once) == []
    assert ws.compile_definition(once) == once
    assert doc == ALL[name]                       # the input is never changed


def test_hyrox_compiles_to_todays_sixteen_segments():
    c = ws.compile_definition(HYROX)
    legacy = WorkoutLibrary.hyroxSolo.to_dict()
    assert c["format"] == "forTime"
    assert c["roundSize"] == 2
    assert "timeCapSeconds" not in c and "intervalSeconds" not in c
    assert c["segments"] == legacy["segments"]
    assert "fidelity" not in c                     # exact: nothing to report


def test_emom_compiles_exactly_to_the_old_interval_keys():
    c = ws.compile_definition(EMOM)
    assert (c["format"], c["intervalSeconds"], c["roundSize"], c["timeCapSeconds"]) == ("emom", 60, 2, 600)
    assert len(c["segments"]) == 19                # 10 x (swings + rest), no rest after the last
    assert c["segments"][1] == {"kind": "rest", "movement": "rest", "name": "Rest"}
    assert "fidelity" not in c


def test_tabata_old_keys_are_lossy_so_fidelity_is_lowered():
    c = ws.compile_definition(TABATA)
    assert c["fidelity"] == "approx"
    assert c["approx"] == ["oldKeysLossy"]
    # An author's textOnly stays textOnly.
    d = dict(TABATA, fidelity="textOnly", rawText="Tabata squats 20/10 x 8")
    assert ws.compile_definition(d)["fidelity"] == "textOnly"


def test_list_rounds_is_filled_by_the_compiler():
    c = ws.compile_definition(ALL["amrapLadder"])
    rp = c["structure"]["body"][0]["timed"]["body"][0]["repeat"]
    assert rp["listRounds"] == 36                  # 720 s at 10 s per part, 2 parts per round
    assert len(we.plan(c).steps) == 72


def test_unknown_descriptive_fields_pass_through_unchanged():
    doc = copy.deepcopy(EMOM)
    doc["x-coach"] = {"cue": "hips"}
    doc["rawText"] = "EMOM 10: 15 KB swings"
    doc["gymLogoUrl"] = "https://example.invalid/logo.png"       # unknown root key: never touched
    timed = doc["structure"]["body"][0]["repeat"]["body"][0]["timed"]
    timed["note"] = "breathe"
    timed["body"][0]["part"]["x-video"] = "v1"
    timed["body"][0]["part"]["tempo"] = "2-0-1-0"
    doc["structure"]["x-source"] = {"page": 3}
    doc["structure"]["body"][0]["x-colour"] = "blue"
    assert ws.validate(doc) == []
    c = ws.compile_definition(doc)
    assert c["x-coach"] == {"cue": "hips"}
    assert c["gymLogoUrl"] == doc["gymLogoUrl"]
    assert c["structure"] == doc["structure"]      # nothing to fill in here: byte-for-byte equal
    assert json.dumps(c["structure"], sort_keys=True) == json.dumps(doc["structure"], sort_keys=True)
    # The engine ignores them: the same plan as without.
    assert we.plan(c).hash == we.plan(ws.compile_definition(EMOM)).hash


def test_unknown_engine_field_needs_a_feature_in_requires():
    doc = copy.deepcopy(ALL["amrapShort"])
    rp = doc["structure"]["body"][0]["timed"]["body"][0]["repeat"]
    rp["resume"] = "rp0"
    # The writer refuses a feature not named in requires, and a reader refuses it even then.
    assert any(e.startswith("requires: missing") for e in ws.validate(doc))
    assert ws.check_runnable(doc) == ("updateApp", ["resume"])
    with pytest.raises(we.NotRunnable):
        we.plan(doc)
    c = ws.compile_definition(doc)
    assert c["requires"] == ["resume"]
    assert ws.validate(c) == []
    assert ws.check_runnable(c) == ("updateApp", ["resume"])
    with pytest.raises(we.NotRunnable) as e:
        we.plan(c)
    assert e.value.reason == "updateApp" and e.value.missing == ["resume"]
    # A requires list that doesn't match what is used is refused by the writer's check.
    c["requires"] = []
    assert any(e.startswith("requires") for e in ws.validate(c))


def test_unknown_key_in_a_node_is_refused_by_the_writer_but_tolerated_by_a_reader():
    doc = copy.deepcopy(EMOM)
    doc["structure"]["body"][0]["repeat"]["body"][0]["timed"]["body"][0]["part"]["bogus"] = 1
    assert any("bogus" in e for e in ws.validate(doc))
    assert ws.validate(doc, strict=False) == []


def test_drafts_and_other_schema_versions_never_run():
    with pytest.raises(we.NotRunnable) as e:
        we.plan(dict(EMOM, schemaVersion=0))
    assert e.value.reason == "draft"
    with pytest.raises(we.NotRunnable):
        we.plan(dict(EMOM, schemaVersion=3))
    assert ws.check_runnable(EMOM) == ("ok", [])


def test_partner_parts_carry_who_and_it_changes_no_timing():
    p = we.plan(PARTNER)
    assert [s.part["who"] for s in p.steps] == ["shared", "shared", "together"]
    solo = copy.deepcopy(PARTNER)
    solo["team"] = "solo"
    for w in solo["structure"]["body"][0]["timed"]["body"]:
        del w["part"]["who"]
    assert ws.validate(solo) == []
    assert we.plan(solo).bells == p.bells


def test_scales_and_womens_standard():
    doc = ALL["scaled"]
    assert we.plan(doc).steps[0].target["value"] == 30
    assert we.plan(doc, standard="F").steps[0].target["value"] == 20
    assert we.plan(doc, scale="l1").steps[0].part["movement"] == "ringRows"


def test_stopwatch_fallback_is_athlete_paced():
    doc = dict(EMOM, rawText="15 KB swings\n\n10 burpees\n", timeCapSeconds=600)
    st = ws.stopwatch_structure(doc)
    assert ws.validate({"schemaVersion": 2, "structure": st}) == []
    p = we.plan(st)
    assert [s.part["name"] for s in p.steps] == ["15 KB swings", "10 burpees"]
    assert [s.ends for s in p.steps] == ["athlete", "athlete"]
    assert p.windows["cap"].late == "continue"


def _with_body(body, score=None, team="solo"):
    return {"schemaVersion": 2, "id": "test.bad", "name": "Bad", "team": team,
            "structure": {"score": score or {"type": "time"}, "body": body}}


TIMED_END_COUNTED = [{"repeat": {"id": "rp", "times": 20, "vary": {"b": {"from": 1, "step": 1}}, "body": [
    {"timed": {"id": "m", "seconds": 60, "early": "wait", "late": "end", "body": [part("b", "burpees", 1)]}}]}}]

INVALID = {
    "missing part id": (_with_body([{"part": {"movement": "run"}}]), "required on every part"),
    "duplicate id": (_with_body([part("a", "run", 400, "meters"), part("a", "row", 500, "meters")]), "duplicate id"),
    "two node kinds": (_with_body([{"part": {"id": "a", "movement": "run"}, "rest": {}}]), "exactly one of"),
    "unknown node kind": (_with_body([{"loop": {"id": "a"}}]), "exactly one of"),
    "empty body": (_with_body([]), "non-empty"),
    "unknown score": (_with_body([part("a", "run")], {"type": "fastest"}), "not a preset"),
    "score part unknown": (_with_body([part("a", "run")], {"type": "totalReps", "parts": ["zz"]}), "unknown part id"),
    "vary length": (_with_body([{"repeat": {"id": "rp", "times": 3, "vary": {"a": [21, 15]},
                                            "body": [part("a", "thrusters", 21)]}}]), "2 values for 3 rounds"),
    "vary unknown id": (_with_body([{"repeat": {"id": "rp", "times": 2, "vary": {"zz": [1, 2]},
                                                "body": [part("a", "thrusters", 21)]}}]), "names no node"),
    "unbounded with no end": (_with_body([{"repeat": {"id": "rp", "times": None, "body": [part("a", "run")]}}]),
                              "needs a timed with late: end"),
    "unbounded not last": (_with_body([{"timed": {"id": "t", "seconds": 600, "early": "next", "late": "end", "body": [
        {"repeat": {"id": "rp", "times": None, "body": [part("a", "run")]}}, part("b", "row", 10, "calories")]}}]),
        "last thing in its window"),
    "unbounded list without then": (_with_body([{"timed": {"id": "t", "seconds": 600, "early": "next", "late": "end",
                                                           "body": [{"repeat": {"id": "rp", "times": None,
                                                                                "vary": {"a": [1, 2, 3]},
                                                                                "body": [part("a", "run")]}}]}}]),
                                    "then: repeatLast"),
    "override last on unbounded": (_with_body([{"timed": {"id": "t", "seconds": 600, "early": "next", "late": "end",
                                                          "body": [{"repeat": {"id": "rp", "times": None,
                                                                               "override": [{"rounds": ["last"], "id": "a",
                                                                                             "omit": True}],
                                                                               "body": [part("a", "run")]}}]}}]),
                                   "\"last\" on a repeat with no count"),
    "late end under a counted repeat": (_with_body(TIMED_END_COUNTED), "use cut"),
    "bad early": (_with_body([{"timed": {"id": "t", "seconds": 60, "early": "soon", "late": "cut",
                                         "body": [part("a", "run")]}}]), "early"),
    "zero seconds": (_with_body([{"timed": {"id": "t", "seconds": 0, "early": "wait", "late": "cut",
                                            "body": [part("a", "run")]}}]), "positive whole number"),
    "ratio rest first": (_with_body([{"rest": {"id": "r", "ratio": 1}}, part("a", "run")]), "needs a node before"),
    "rest seconds and ratio": (_with_body([part("a", "run"), {"rest": {"id": "r", "ratio": 1, "seconds": 5}}]),
                               "exclusive"),
    "max and value": (_with_body([{"part": {"id": "a", "movement": "run",
                                            "target": {"max": True, "value": 3, "unit": "reps"}}}]), "exclusive"),
    "bad unit": (_with_body([part("a", "run", 400, "furlongs")]), "not one of"),
    "who on a team part missing": (_with_body([part("a", "run", 400, "meters")], team="doubles"), "no silent default"),
    "bad who": (_with_body([part("a", "run", 400, "meters", who="everyone")]), "not one of"),
    "too deep": (_with_body([{"repeat": {"id": "r1", "times": 2, "body": [
        {"repeat": {"id": "r2", "times": 2, "body": [
            {"repeat": {"id": "r3", "times": 2, "body": [
                {"timed": {"id": "t", "seconds": 60, "early": "wait", "late": "cut",
                           "body": [part("a", "run")]}}]}}]}}]}}]), "nesting deeper"),
    "too many steps": (_with_body([{"repeat": {"id": "rp", "times": 401, "body": [part("a", "run")]}}]),
                       "steps in the plan"),
    "missing schemaVersion": ({k: v for k, v in EMOM.items() if k != "schemaVersion"}, "schemaVersion"),
    "approx without rawText": (dict(EMOM, fidelity="approx"), "rawText: required"),
    "scale short too long": (dict(ALL["scaled"], scales=[dict(ALL["scaled"]["scales"][0], short="Level1")]),
                             "at most 5"),
    "root is not a scale": (dict(ALL["scaled"], scales=[ALL["scaled"]["scales"][1]]), "default scale"),
    "stops names nothing": (_with_body([{"timed": {"id": "t", "seconds": 600, "early": "next", "late": "end",
                                                   "stops": "zz",
                                                   "body": [{"repeat": {"id": "rp", "times": None,
                                                                        "body": [part("a", "run")]}}]}}]),
                            "not an unbounded repeat"),
}


@pytest.mark.parametrize("name", sorted(INVALID))
def test_invalid_documents_are_rejected(name):
    doc, needle = INVALID[name]
    errs = ws.validate(doc)
    assert errs, name
    assert any(needle in e for e in errs), errs


def test_payload_limit():
    big = _with_body([{"repeat": {"id": "rp", "times": 300, "body": [
        part("a", "row", 10, "calories", note="x" * 40)]}}])
    errs = ws.validate(big)
    assert any(e.startswith("payload") for e in errs), errs


def test_hard_cap_at_the_top_is_allowed():
    assert ws.validate(ALL["hardCap"]) == []


def test_fidelity_is_lowered_on_the_default_scale_too_and_taken_back():
    tab = copy.deepcopy(TABATA)
    tab["scales"] = [{"id": "rx", "label": "Rx", "short": "Rx", "rank": 1, "fidelity": "exact",
                      "structure": tab["structure"]}]
    errs = ws.validate(tab)
    assert any("scales[0].fidelity" in e for e in errs), errs      # a lossy default scale isn't exact
    del tab["scales"][0]["fidelity"]
    c = ws.compile_definition(tab)
    assert c["scales"][0]["fidelity"] == "approx" and c["scales"][0]["approx"] == ["oldKeysLossy"]
    assert c["fidelity"] == "approx"
    assert ws.validate(c) == []
    # Edited so the old keys are exact again: the compiler takes its reason back.
    c["structure"] = copy.deepcopy(EMOM["structure"])
    c["scales"][0]["structure"] = c["structure"]
    again = ws.compile_definition(c)
    assert again["fidelity"] == "exact" and "approx" not in again
    assert again["scales"][0]["fidelity"] == "exact" and "approx" not in again["scales"][0]
    # Other reasons stay.
    d = dict(copy.deepcopy(EMOM), fidelity="approx", approx=["partnerSplitGuessed", "oldKeysLossy"],
             rawText="EMOM 10")
    assert ws.compile_definition(d)["approx"] == ["partnerSplitGuessed"]


def test_compiled_rows_carry_the_compiler_version_and_a_hard_cap_is_for_time():
    c = ws.compile_definition(ALL["hardCap"])
    assert c["compilerVersion"] == ws.COMPILER_VERSION
    assert (c["format"], c["timeCapSeconds"]) == ("forTime", 300)


def test_unknown_node_runs_as_an_athlete_paced_part():
    doc = copy.deepcopy(EMOM)
    doc["structure"]["body"].append({"chant": {"id": "x"}, "rawText": "3 rounds of a future block"})
    assert ws.validate(doc, strict=False)                 # the writer and reader checks refuse it
    p = we.plan(doc)                                      # but an engine handed one never guesses
    last = p.steps[-1]
    assert last.part["name"] == "3 rounds of a future block" and last.ends == "athlete"


def test_list_rounds_is_capped_so_a_long_amrap_fits_the_step_limit():
    doc = {"schemaVersion": 2, "id": "test.long", "name": "Long", "team": "solo", "structure": {
        "score": {"type": "roundsReps"},
        "body": [{"timed": {"id": "t", "seconds": 7200, "early": "next", "late": "end", "body": [
            {"repeat": {"id": "rp", "times": None, "body": [part("a", "burpees", 1)]}}]}}]}}
    c = ws.compile_definition(doc)
    assert ws.validate(c) == []
    assert len(we.plan(c).steps) <= ws.MAX_STEPS


PLAN_ERRORS = {
    "tooManySteps": ({"repeat": {"id": "rp", "times": 401, "body": [part("a", "run")]}}, "tooLarge"),
    "hugeTimes": ({"repeat": {"id": "rp", "times": 1e20, "body": [part("a", "run")]}}, "invalid"),
    "hugeSeconds": ({"timed": {"id": "t", "seconds": 1e19, "early": "next", "late": "cut",
                               "body": [part("a", "run")]}}, "invalid"),
    "hugeRestSeconds": ({"rest": {"id": "r", "seconds": 10 ** 12}}, "invalid"),
    "hugeRatio": ({"rest": {"id": "r", "ratio": 1e9}}, "invalid"),
    "hugeSecondsTarget": ({"part": {"id": "a", "movement": "plank",
                                    "target": {"value": 1e19, "unit": "seconds"}}}, "invalid"),
    "zeroTimes": ({"repeat": {"id": "rp", "times": 0, "body": [part("a", "run")]}}, "empty"),
    "varyHugeSeconds": ({"repeat": {"id": "rp", "times": 2, "vary": {"t": [60, 10 ** 12]}, "body": [
        {"timed": {"id": "t", "seconds": 60, "early": "wait", "late": "cut", "body": [part("a", "run")]}}]}},
                        "invalid"),
}


@pytest.mark.parametrize("name", sorted(PLAN_ERRORS))
def test_the_reader_refuses_out_of_range_numbers_instead_of_crashing(name):
    node, reason = PLAN_ERRORS[name]
    body = [part("w", "run"), node] if node.get("rest") else [node]
    with pytest.raises(we.NotRunnable) as e:
        we.plan({"schemaVersion": 2, "structure": {"score": {"type": "none"}, "body": body}})
    assert e.value.reason == reason
    with pytest.raises(we.NotRunnable) as e:
        we.plan({"schemaVersion": 2, "structure": {"score": {"type": "none"}, "body": []}})
    assert e.value.reason == "empty"
