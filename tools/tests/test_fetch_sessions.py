import gzip

import fetch_sessions as F


def test_candidate_paths_csv_tries_gz_first():
    assert F.candidate_paths("Debug/session-1.csv") == ["Debug/session-1.csv.gz", "Debug/session-1.csv"]


def test_candidate_paths_json_is_plain_only():
    assert F.candidate_paths("Workouts/abc.json") == ["Workouts/abc.json"]


def test_decode_body_gunzips_gz_objects_only():
    raw = b"t,ax,ay\n0,1,2\n" * 100
    assert F.decode_body("Debug/a.csv.gz", gzip.compress(raw)) == raw
    assert F.decode_body("Debug/a.csv", raw) == raw
