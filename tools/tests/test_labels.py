"""Ground-truth labels (data/labels, docs/LABELS.md): every label file is well formed, and the
switch / set-end / matching rules the scores rely on. No recordings needed (they are not in git)."""
import pytest

from barpath import labels as L

FILES = L.all_label_files()


def test_there_are_labels():
    assert FILES, "data/labels/ is empty"


@pytest.mark.parametrize("path", FILES, ids=lambda p: p.stem)
def test_label_file_is_valid(path):
    d = L.load(path)
    assert L.validate(d) == []
    assert d["id"] == path.stem


def seg(mv, a, b, **kw):
    return dict(movement=mv, start=a, end=b, source="athlete", **kw)


def test_switches_skip_rest_and_same_movement():
    d = {"segments": [seg("pullUps", 0, 6), seg("pushUps", 6, 20), seg("rest", 20, 30),
                      seg("pullUps", 30, 36), seg("pullUps", 36, 40), seg("transition", 40, 45),
                      seg("run", 45, 300)]}
    assert [(x["t"], x["from"], x["to"]) for x in L.switches(d)] == [
        (6.0, "pullUps", "pushUps"), (30.0, "pushUps", "pullUps"), (45.0, "pullUps", "run")]


def test_set_ends_use_sets_inside_a_station():
    d = {"segments": [seg("wallBalls", 0, 40, reps=15, sets=[dict(start=2, end=19, reps=9),
                                                              dict(start=27, end=38, reps=6)]),
                      seg("rest", 40, 50), seg("run", 50, 300)]}
    assert L.set_ends(d) == [19.0, 38.0, 300.0]


def test_match_is_one_to_one_within_the_window():
    m = L.match([10.0, 20.0, 30.0], [10.5, 11.0, 26.0, 50.0], tol=3.0)
    assert (m["hits"], m["misses"], m["false"]) == (1, 2, 3)
    assert m["errors"] == [0.5]


def test_validate_catches_bad_labels():
    d = {"version": 1, "id": "x", "date": "2026-11-05", "name": "x", "kind": "workout",
         "files": {"csv": "a.csv", "result": "a.json"},
         "segments": [seg("wallBalls", 0, 40, reps=15, sets=[dict(start=2, end=19, reps=9)]),
                      seg("rest", 30, 50)]}
    errs = L.validate(d)
    assert any("sets add up to 9" in e for e in errs)
    assert any("starts before the previous segment ends" in e for e in errs)
