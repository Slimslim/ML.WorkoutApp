"""The workout-engine parity fixtures on disk are exactly what the Python reference generates.

If this fails after a change to the engine, regenerate with `python3 tools/make_workout_fixtures.py`
and review the diff: BarPathKit's WorkoutEngine.swift must then produce the same results."""
import json

import workout_fixture_gen as gen


def test_fixtures_are_up_to_date():
    files = gen.generate()
    on_disk = {p.relative_to(gen.OUT).as_posix() for p in gen.OUT.rglob("*.json")}
    assert on_disk == set(files), "regenerate: python3 tools/make_workout_fixtures.py"
    for rel, text in files.items():
        assert (gen.OUT / rel).read_text(encoding="utf-8") == text, rel


def test_index_counts_every_case():
    index = json.loads((gen.OUT / "INDEX.json").read_text())
    assert len(index["cases"]) == len(gen.ALL) + len(gen.EXTRA) and index["scenarios"] >= 50
    assert index["planErrors"] >= 10


def test_late_scenario_moves_the_cut():
    res = json.loads((gen.OUT / "amrapShort/expected/lateCrownMovesTheCut.result.json").read_text())
    assert not [e for e in res["effects"] if e["kind"] == "hint"]   # the late turn was accepted
