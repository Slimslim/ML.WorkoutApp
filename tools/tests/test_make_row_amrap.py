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
    with pytest.raises(make_row.LibraryError, match=">= 1"):
        make_row.repeat_rounds(amrap(), 0)
    with pytest.raises(make_row.LibraryError, match="flat"):
        make_row.repeat_rounds(dict(amrap(), schemaVersion=2), 10)
