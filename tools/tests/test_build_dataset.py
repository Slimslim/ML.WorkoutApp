"""tools/build_dataset.py on invented labels and a synthetic recording (no real data)."""
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import build_dataset as B  # noqa: E402
from barpath import tiers  # noqa: E402
from barpath.recording import MotionSeries, save_session_csv  # noqa: E402

START = datetime(2026, 11, 1, 12, 0, 0, tzinfo=timezone.utc)


def motion(seconds=60.0, hz=100.0):
    t = np.arange(0.0, seconds, 1.0 / hz)
    n = len(t)
    q = np.tile([1.0, 0.0, 0.0, 0.0], (n, 1))
    acc = np.column_stack([0.1 * np.sin(t), np.zeros(n), np.zeros(n)])
    grav = np.tile([0.0, 0.0, -1.0], (n, 1))
    return MotionSeries(t, q, acc, grav, np.zeros((n, 3)))


def workout_label(lid="2026-11-01-test-amrap", **extra):
    d = {
        "version": 1, "id": lid, "date": "2026-11-01", "kind": "workout", "name": "test",
        "files": {"csv": "Debug/session-AAA.csv", "result": "Workouts/AAA.json"},
        "notes": ["a video exists"],
        "segments": [
            {"movement": "assaultBike", "round": 1, "start": 1.0, "end": 10.0, "reps": 10,
             "unit": "calories", "source": "motion",
             "console": {"machine": "assault bike", "calories": 10}},
            {"movement": "rest", "start": 10.0, "end": 12.0, "source": "motion"},
            {"movement": "wallBalls", "round": 1, "start": 12.0, "end": 30.0, "reps": 5,
             "unit": "reps", "loadLb": 20, "source": "crown",
             "sets": [{"start": 13.0, "end": 20.0, "reps": 3, "repTimes": [14.0, 16.0, 18.0], "video": True},
                      {"start": 22.0, "end": 29.0, "reps": 2}]},
            {"movement": "run", "round": 1, "start": 31.0, "end": 50.0, "source": "athlete",
             "flag": {"motion": 1, "athlete": 2, "reason": "x", "check": "athlete"},
             "training": False},
        ],
    }
    d.update(extra)
    return d


def lifts_label(lid="2026-11-02-deadlift"):
    return {"version": 1, "id": lid, "date": "2026-11-02", "kind": "lifts", "name": "dl",
            "files": {}, "notes": ["athlete counts"],
            "sets": [{"file": "Debug/session-LIFT1.csv", "lift": "deadlift", "loadLb": 225, "reps": 5},
                     {"file": "Debug/session-MISSING.csv", "lift": "deadlift", "loadLb": 245, "reps": 5}]}


def setup(tmp_path, labels):
    ld, cache = tmp_path / "labels", tmp_path / "cache"
    ld.mkdir()
    for d in labels:
        (ld / f"{d['id']}.json").write_text(json.dumps(d))
    return ld, cache


def cache_csv(cache, lid, name, seconds=60.0):
    (cache / lid).mkdir(parents=True, exist_ok=True)
    save_session_csv(cache / lid / name, motion(seconds), "S", START, "deadlift")


def read_csv(p):
    with open(p) as f:
        return list(csv.DictReader(f))


def test_tier_rule():
    lab = workout_label()
    units = list(tiers.work_units(lab))
    assert [u["movement"] for u in units] == ["airBike", "wallBalls", "wallBalls", "run"]
    assert [u["tier"] for u in units] == ["A", "A", "D", "B"]
    assert [u["split"] for u in units] == ["test", "test", "dev", "dev"]
    del lab["segments"][2]["sets"][0]["video"]      # a note about a video is not a check on it
    assert [u["tier"] for u in tiers.work_units(lab)] == ["A", "D", "D", "B"]
    assert {u["tier"] for u in tiers.work_units(lifts_label())} == {"B"}
    assert tiers.athlete({"id": "x-tester-b"}) == "B" and tiers.athlete({"id": "x"}) == "A"
    assert tiers.athlete({"id": "2026-11-20-row-tester-c"}) == "C"
    assert tiers.athlete({"id": "x", "athlete": "tester-d"}) == "D"


def test_build(tmp_path):
    w, lf = workout_label(), lifts_label()
    skipped = workout_label("2026-11-03-not-cached")
    ld, cache = setup(tmp_path, [w, lf, skipped])
    cache_csv(cache, w["id"], "session-AAA.csv")
    cache_csv(cache, lf["id"], "session-LIFT1.csv", seconds=12.0)
    out = tmp_path / "datasets"
    m = B.build(out, "v1", ld, cache, commit="abc1234")
    dest = out / "v1"

    assert m["commit"] == "abc1234"
    assert set(m["label_sha256"]) == {w["id"], lf["id"], skipped["id"]}
    assert m["labels_used"] == [w["id"], lf["id"]]
    assert m["labels_skipped"] == [{"id": skipped["id"], "reason": "recording not cached"}]
    assert m["rows_without_motion"] == 1
    assert m["movements"]["deadlift"]["rows_without_motion"] == 1
    assert sorted(p.name for p in dest.iterdir()) == ["CHANGELOG.md", "airBike", "deadlift",
                                                     "manifest.json", "run", "wallBalls"]

    wb = read_csv(dest / "wallBalls" / "index.csv")
    assert [r["row_id"] for r in wb] == [f"{w['id']}-001", f"{w['id']}-002"]
    assert wb[0]["tier"] == "A" and wb[0]["split"] == "test" and wb[0]["has_rep_times"] == "true"
    assert wb[1]["tier"] == "D" and wb[1]["amount"] == "2" and wb[1]["load_lb"] == "20"
    assert wb[0]["start"] == "13" and wb[0]["end"] == "20" and wb[0]["athlete"] == "A"
    run = read_csv(dest / "run" / "index.csv")[0]
    assert run["tier"] == "B" and run["training"] == "false" and run["flagged"] == "true"
    reps = read_csv(dest / "wallBalls" / "reps.csv")
    assert [(r["rep_index"], r["time"]) for r in reps] == [("0", "14"), ("1", "16"), ("2", "18")]

    z = np.load(dest / "wallBalls" / "motion.npz")
    rid = f"{w['id']}-001"
    t = z[f"{rid}/t"]
    assert t[0] == pytest.approx(-2.0, abs=0.011) and t[-1] == pytest.approx(9.0, abs=0.011)
    for k in ("q", "user_accel", "gravity", "rotation_rate"):
        assert len(z[f"{rid}/{k}"]) == len(t)
    assert f"{w['id']}-002/t" in z.files

    dl = read_csv(dest / "deadlift" / "index.csv")
    assert dl[0]["tier"] == "B" and dl[0]["start"] == "0" and float(dl[0]["end"]) == pytest.approx(11.99)
    assert dl[1]["start"] == "" and dl[1]["end"] == ""
    zd = np.load(dest / "deadlift" / "motion.npz")
    assert f"{lf['id']}-000/t" in zd.files and f"{lf['id']}-001/t" not in zd.files
    assert "First version" in (dest / "CHANGELOG.md").read_text()

    with pytest.raises(FileExistsError):
        B.build(out, "v1", ld, cache, commit="abc1234")


def test_changelog_against_previous(tmp_path):
    w, lf = workout_label(), lifts_label()
    ld, cache = setup(tmp_path, [w, lf])
    cache_csv(cache, w["id"], "session-AAA.csv")
    cache_csv(cache, lf["id"], "session-LIFT1.csv", seconds=5.0)
    out = tmp_path / "datasets"
    B.build(out, "v1", ld, cache, commit="a")
    w["notes"] = ["changed"]
    (ld / f"{w['id']}.json").write_text(json.dumps(w))
    (ld / f"{lf['id']}.json").unlink()
    new = lifts_label("2026-11-04-new")
    (ld / f"{new['id']}.json").write_text(json.dumps(new))
    cache_csv(cache, new["id"], "session-LIFT1.csv", seconds=5.0)
    B.build(out, "v2", ld, cache, commit="b")
    text = (out / "v2" / "CHANGELOG.md").read_text()
    assert "Compared with v1" in text
    assert f"Added (1): {new['id']}" in text
    assert f"Removed (1): {lf['id']}" in text
    assert f"Changed (1): {w['id']}" in text


def test_invalid_label_is_skipped(tmp_path):
    bad = workout_label("2026-11-05-bad")
    del bad["segments"][0]["end"]
    ld, cache = setup(tmp_path, [bad])
    m = B.build(tmp_path / "ds", "v1", ld, cache, commit="x")
    assert m["labels_used"] == [] and m["labels_skipped"][0]["reason"].startswith("invalid")


def test_main_refuses_existing_version(tmp_path, capsys):
    (tmp_path / "ds" / "v1").mkdir(parents=True)
    ld, cache = setup(tmp_path, [])
    assert B.main(["--out", str(tmp_path / "ds"), "--version", "v1", "--labels", str(ld),
                   "--cache", str(cache)]) == 1
