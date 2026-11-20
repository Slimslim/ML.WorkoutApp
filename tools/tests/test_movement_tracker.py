"""tools/movement_tracker.py on invented labels (no real data)."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import movement_tracker as T  # noqa: E402


def seg(movement, start, end, source="motion", **kw):
    return dict(movement=movement, start=start, end=end, source=source, **kw)


def label(lid, segments, notes=()):
    return {"version": 1, "id": lid, "date": "2026-11-01", "kind": "workout", "name": lid,
            "files": {"csv": "c.csv", "result": "r.json"}, "notes": list(notes), "segments": segments}


LABELS = [
    label("2026-11-01-a", [
        seg("run", 0, 10, unit="meters", reps=200),
        seg("rest", 10, 12),
        seg("airBike", 12, 20, reps=10, unit="calories",
            console={"machine": "assault bike", "calories": 10}),
        seg("wallBalls", 20, 40, source="crown", reps=5, unit="reps",
            sets=[{"start": 21, "end": 28, "reps": 3, "repTimes": [22, 24, 26]},
                  {"start": 30, "end": 38, "reps": 2}]),
    ], notes=["rep times from the video"]),
    label("2026-11-02-b-tester-b", [
        seg("assaultBike", 0, 30, source="athlete", reps=15, unit="calories"),
        seg("run", 30, 60, source="crown"),
    ]),
    {"version": 1, "id": "2026-11-03-lifts", "date": "2026-11-03", "kind": "lifts", "name": "dl",
     "files": {}, "notes": [], "sets": [{"file": "x.json", "lift": "deadlift", "reps": 5}]},
]


def test_coverage_counts():
    cov = T.coverage(LABELS, ["run", "airBike", "wallBalls", "skiErg"])
    bike = cov["airBike"]
    assert "assaultBike" not in cov
    assert bike["sessions"] == 2 and bike["athletes"] == 2 and bike["segments"] == 2
    assert bike["tiers"] == {"A": 1, "B": 1, "C": 0, "D": 0}
    assert bike["dev_sessions"] == 1 and bike["test_sessions"] == 1 and bike["tier_a_sessions"] == 1
    assert bike["missing"] == ["sessions 2/10", "tier-A sessions 1/3"]
    wb = cov["wallBalls"]
    assert wb["segments"] == 1 and wb["sets"] == 2 and wb["timed_sets"] == 1
    assert wb["tiers"] == {"A": 1, "B": 0, "C": 0, "D": 1}
    run = cov["run"]
    assert run["tiers"] == {"A": 0, "B": 0, "C": 1, "D": 1} and run["test_sessions"] == 0
    assert cov["skiErg"]["sessions"] == 0 and len(cov["skiErg"]["missing"]) == 3
    dl = cov["deadlift"]
    assert dl["sets"] == 1 and dl["segments"] == 0 and dl["tiers"]["B"] == 1
    assert not dl["target"] and "missing" not in dl


def test_target_met():
    many = [label(f"2026-11-{i:02d}-s{'-tester-b' if i % 2 else ''}",
                  [seg("run", 0, 10, console={"machine": "treadmill", "meters": 400})])
            for i in range(1, 11)]
    assert T.coverage(many, ["run"])["run"]["missing"] == []


def test_main_markdown_and_json(tmp_path, capsys):
    ld = tmp_path / "labels"
    ld.mkdir()
    for d in LABELS:
        (ld / f"{d['id']}.json").write_text(json.dumps(d))
    out = tmp_path / "cov.json"
    assert T.main(["--labels", str(ld), "--json", str(out), "--targets", "run,assaultBike"]) == 0
    text = capsys.readouterr().out
    assert text.startswith("| movement |")
    assert "| **airBike** | 2 | 2 |" in text and "| **run** |" in text
    data = json.loads(out.read_text())
    assert data["targets"] == ["run", "assaultBike"]
    assert data["movements"]["airBike"]["target"] is True
    assert data["movements"]["wallBalls"]["target"] is False
