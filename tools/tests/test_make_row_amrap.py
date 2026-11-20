"""make_row.py refuses an AMRAP that does not list its rounds out (#138), and --repeat-rounds
writes one out. Synthetic definitions only."""
import json
import sys
from pathlib import Path

import pytest

TOOLS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TOOLS / "library"))
import make_row  # noqa: E402


def amrap(rounds=1, round_size=None, per_round=None):
    per_round = per_round or [
        {"kind": "run", "movement": "run", "name": "Run", "target": {"value": 200.0, "unit": "meters"}},
        {"kind": "station", "movement": "bike", "name": "Bike", "target": {"value": 20.0, "unit": "calories"}},
    ]
    d = {"id": "lib.test.20261120.amrap", "name": "Test AMRAP", "shortName": "AMRAP",
         "format": "amrap", "team": "solo", "healthKitActivity": "crossTraining",
         "segments": per_round * rounds, "timeCapSeconds": 1200.0}
    if round_size is not None:
        d["roundSize"] = round_size
    return d


def write(tmp_path, d, name="w.json"):
    f = tmp_path / name
    f.write_text(json.dumps(d))
    return str(f)


def test_check_amrap_rounds():
    with pytest.raises(make_row.LibraryError, match="needs roundSize"):
        make_row.check_amrap_rounds(amrap(rounds=12))
    with pytest.raises(make_row.LibraryError, match="lists 1"):
        make_row.check_amrap_rounds(amrap(rounds=1, round_size=2))
    with pytest.raises(make_row.LibraryError, match="lists 9"):
        make_row.check_amrap_rounds(amrap(rounds=9, round_size=2))
    make_row.check_amrap_rounds(amrap(rounds=10, round_size=2))
    make_row.check_amrap_rounds(dict(amrap(rounds=1), format="forTime"))   # not an AMRAP


def test_main_refuses_a_short_amrap(tmp_path, capsys):
    path = write(tmp_path, amrap(rounds=1))
    assert make_row.main([path]) == 1
    assert "--repeat-rounds" in capsys.readouterr().err
    assert make_row.main(["--rounds-listed-ok", path]) == 0
    assert make_row.main([write(tmp_path, amrap(rounds=12, round_size=2), "ok.json")]) == 0


def test_repeat_rounds_writes_the_list_out(tmp_path, capsys):
    one = amrap(rounds=1)
    out = make_row.repeat_rounds(one, 30)
    assert out["roundSize"] == 2
    assert len(out["segments"]) == 60
    assert out["segments"][58:] == one["segments"]
    make_row.check_amrap_rounds(out)
    # the last full round is repeated (a ladder keeps its top round)
    ladder = amrap(rounds=1, per_round=[
        {"kind": "station", "movement": "squat", "name": "Squat", "target": {"value": 5.0, "unit": "reps"}},
        {"kind": "station", "movement": "squat", "name": "Squat", "target": {"value": 10.0, "unit": "reps"}},
    ])
    ladder["roundSize"] = 1
    out = make_row.repeat_rounds(ladder, 10)
    assert [s["target"]["value"] for s in out["segments"]] == [5.0, 10.0] + [10.0] * 8
    # already long enough: unchanged apart from roundSize
    long = amrap(rounds=12, round_size=2)
    assert make_row.repeat_rounds(long, 10) == long
    # through main
    capsys.readouterr()
    assert make_row.main(["--repeat-rounds", "30", write(tmp_path, one)]) == 0
    assert capsys.readouterr().out.count('"kind":"run"') == 30


def test_repeat_rounds_refusals():
    with pytest.raises(make_row.LibraryError, match="AMRAPs only"):
        make_row.repeat_rounds(dict(amrap(), format="forTime"), 10)
    with pytest.raises(make_row.LibraryError, match="whole rounds"):
        make_row.repeat_rounds(dict(amrap(rounds=3), roundSize=4), 10)
    for bad in (0, -1, 7):
        with pytest.raises(make_row.LibraryError, match="between 1"):
            make_row.repeat_rounds(dict(amrap(rounds=3), roundSize=bad), 10)
    with pytest.raises(make_row.LibraryError, match="at most 30"):
        make_row.repeat_rounds(amrap(rounds=1), 31)
    distinct = [{"kind": "station", "movement": f"m{i}", "name": f"M{i}",
                 "target": {"value": 1.0, "unit": "reps"}} for i in range(50)]
    long_round = amrap(rounds=1, per_round=distinct)                          # one round of 50
    assert len(make_row.repeat_rounds(long_round, 30)["segments"]) == 600     # capped, as the watch
    make_row.check_amrap_rounds(make_row.repeat_rounds(long_round, 30))      # 12 rounds: passes
    # a round of 61: 9 rounds fit in 600, below the minimum; the hint says how to get it through
    r61 = amrap(rounds=1, per_round=[dict(s, movement=f"y{i}") for i, s in enumerate((distinct * 2)[:61])])
    out = make_row.repeat_rounds(r61, 30)
    assert len(out["segments"]) == 549 and out["roundSize"] == 61
    with pytest.raises(make_row.LibraryError, match="fits only 9 rounds.*--rounds-listed-ok"):
        make_row.check_amrap_rounds(out)
    # a list already longer than 600 is left as it is when nothing is added
    big = amrap(rounds=1, per_round=[dict(s, movement=f"x{i}") for i, s in enumerate(distinct * 13)])
    assert make_row.repeat_rounds(big, 1)["segments"] == big["segments"]
    with pytest.raises(make_row.LibraryError, match=">= 1"):
        make_row.repeat_rounds(amrap(), 0)
    with pytest.raises(make_row.LibraryError, match="flat"):
        make_row.repeat_rounds(dict(amrap(), schemaVersion=2), 10)


def test_v2_hint_names_a_fix_that_works():
    with pytest.raises(make_row.LibraryError) as e:
        make_row.check_amrap_rounds(amrap(rounds=1), v2=True)
    assert "--repeat-rounds" not in str(e.value) and "by hand" in str(e.value)


def test_repeat_rounds_with_rounds_listed_ok_and_a_small_n(tmp_path):
    path = write(tmp_path, amrap(rounds=1))
    assert make_row.main(["--repeat-rounds", "3", path]) == 1          # 3 rounds: still short
    assert make_row.main(["--repeat-rounds", "3", "--rounds-listed-ok", path]) == 0


def test_v2_legacy_copy_is_checked(tmp_path, monkeypatch, capsys):
    """An exact v2 row is copied to builds 15/16, so its old keys are checked like a flat AMRAP.
    The v2 schema check is bypassed here: this test is about the legacy-copy path only."""
    monkeypatch.setattr(make_row, "validate_v2", lambda d, owner=None: d)
    v2 = dict(amrap(rounds=1), schemaVersion=2, fidelity="exact")
    path = write(tmp_path, v2)
    assert make_row.legacy_copy(v2) is not None
    assert make_row.main(["--trust-old-keys", path]) == 1
    err = capsys.readouterr().err
    assert "by hand" in err and "--repeat-rounds" not in err
    assert make_row.main(["--trust-old-keys", "--rounds-listed-ok", path]) == 0
    # not exact: no legacy copy, nothing for builds 15/16 to finish early
    approx = write(tmp_path, dict(v2, fidelity="approx"), "approx.json")
    assert make_row.main([approx]) == 0


def test_repeat_rounds_uses_the_exact_repeat_like_the_watch():
    """Without roundSize the round is the list's exact repeat (as expandedForAmrap): 3 identical
    rounds of 2 become 30 rounds of 2, not 30 rounds of 6."""
    three = amrap(rounds=3)
    out = make_row.repeat_rounds(three, 30)
    assert out["roundSize"] == 2 and len(out["segments"]) == 60
    # a ladder written once is one round
    ladder = amrap(rounds=1, per_round=[
        {"kind": "station", "movement": "squat", "name": "Squat", "target": {"value": 5.0, "unit": "reps"}},
        {"kind": "station", "movement": "squat", "name": "Squat", "target": {"value": 10.0, "unit": "reps"}},
    ])
    assert make_row.repeat_rounds(ladder, 10)["roundSize"] == 2


def test_parity_with_the_watch_expansion():
    """make_row's round choice matches barpath.workout.amrap_expanded on the shared cases."""
    from barpath.workout import WorkoutDefinition, amrap_expanded
    fixture = (TOOLS.parent / "BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures"
               / "amrap_expand_cases.json")
    checked = []
    for c in json.loads(fixture.read_text(encoding="utf-8"))["cases"]:
        d = dict(c["input"], segments=c["pattern"] * c["times"])
        if d["format"] != "amrap" or not d.get("timeCapSeconds"):
            continue
        rs = d.get("roundSize")
        if rs is not None and not 1 <= rs <= len(d["segments"]):
            continue                      # make_row refuses what the watch falls back on
        n = len(d["segments"])
        r = rs or make_row._exact_repeat_period(d["segments"])
        if n % r:
            continue                      # refused by make_row, left alone by the watch
        ours = make_row.repeat_rounds(d, 30)
        checked.append(c["name"])
        watch = amrap_expanded(WorkoutDefinition.from_dict(d)).to_dict()
        assert ours.get("roundSize") == watch.get("roundSize"), c["name"]
        assert ours["segments"] == watch["segments"], c["name"]
    assert "3 rounds of 4, no roundSize: rounds of 4" in checked
    assert "long round: capped at 600 segments" in checked
    assert len(checked) >= 10


def test_interval_amrap_without_round_size(tmp_path):
    """As the watch: an interval AMRAP keeps roundSize unset (setting it turns on the interval
    jump for work segments), and its listed rounds are counted by the exact repeat."""
    one = dict(amrap(rounds=1), intervalSeconds=180.0)
    out = make_row.repeat_rounds(one, 30)
    assert "roundSize" not in out and len(out["segments"]) == 60
    make_row.check_amrap_rounds(out)
    with pytest.raises(make_row.LibraryError, match="lists 1"):
        make_row.check_amrap_rounds(one)
    assert make_row.main(["--repeat-rounds", "30", write(tmp_path, one)]) == 0
