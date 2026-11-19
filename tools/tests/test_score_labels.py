"""tools/score_labels.py end to end on the invented fixture labels (tools/tests/fixtures/labels):
the real labels and recordings live in private Storage, so CI scores synthetic ones. The
recordings are built here from barpath.simulate; nothing recorded is in the repo."""
import json
import sys
from datetime import timedelta
from pathlib import Path

import pytest

from barpath import labels as L
from barpath.recording import save_session_csv
from barpath.simulate import simulate_lift, simulate_session

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import score_labels  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "labels"


@pytest.fixture
def cache(tmp_path, monkeypatch):
    """data/cache/ for the two fixture labels, from simulated motion."""
    monkeypatch.setattr(L, "CACHE_DIR", L.CACHE_DIR)          # restored after the test
    workout = L.load(FIXTURES / "2026-01-01-example-workout.json")
    ses = simulate_session(seed=7)
    csv = tmp_path / workout["id"] / Path(workout["files"]["csv"]).name
    csv.parent.mkdir(parents=True)
    save_session_csv(csv, ses.motion, ses.session_id, ses.start_date, "snatch")
    t0 = ses.start_date
    crown = [{"movement": s["movement"], "kind": "rest" if s["movement"] == "rest" else "station",
              "start": (t0 + timedelta(seconds=s["start"])).timestamp(),
              "end": (t0 + timedelta(seconds=s["end"])).timestamp()} for s in workout["segments"]]
    (csv.parent / Path(workout["files"]["result"]).name).write_text(json.dumps({"segments": crown}))

    lifts = L.load(FIXTURES / "2026-01-01-example-lifts.json")
    rec = tmp_path / lifts["id"] / Path(lifts["sets"][0]["file"]).name
    rec.parent.mkdir(parents=True)
    simulate_lift("snatch", seed=1).recording.save(rec)
    return tmp_path


def test_fixture_labels_are_valid():
    files = L.all_label_files(FIXTURES)
    assert len(files) == 2
    for p in files:
        d = L.load(p)
        assert L.validate(d) == [] and d["id"] == p.stem


def test_scores_the_fixture_labels(cache, capsys):
    assert score_labels.main(["--labels", str(FIXTURES), "--cache", str(cache)]) == 0
    out = capsys.readouterr().out
    assert "Not scored" not in out
    assert "| 2026-01-01-example-workout | crown |" in out
    assert "| 2026-01-01-example-workout | onset |" in out
    # crown taps at the true segment ends: both set ends of the label are found
    crown_row = next(ln for ln in out.splitlines() if "| 2026-01-01-example-workout | crown |" in ln)
    assert "2/2" in crown_row
    assert "| 2026-01-01-example-lifts | snatch 95 lb | 1 |" in out


def test_without_recordings_the_labels_are_listed_not_scored(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(L, "CACHE_DIR", L.CACHE_DIR)
    assert score_labels.main(["--labels", str(FIXTURES), "--cache", str(tmp_path)]) == 0
    assert "Not scored" in capsys.readouterr().out


def test_no_labels_is_a_clean_exit(tmp_path, capsys):
    assert score_labels.main(["--labels", str(tmp_path)]) == 0
    assert "fetch_corpus.py --kind labels" in capsys.readouterr().out
