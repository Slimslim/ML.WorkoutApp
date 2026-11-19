"""tools/fetch_corpus.py: the manifest parser (no network)."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fetch_corpus as F  # noqa: E402

H = "a" * 64


def test_manifest_with_sizes():
    text = f"{H}  1234  2026-10-29-helen/README.md\n{'B' * 64}  98765  2026-10-29-gym/video_paths/a b.csv\n"
    assert F.parse_manifest(text) == [(H, 1234, "2026-10-29-helen/README.md"),
                                      ("b" * 64, 98765, "2026-10-29-gym/video_paths/a b.csv")]


def test_plain_sha256sum_format():
    text = f"{H}  2026-10-29-helen/README.md\n{'B' * 64} *./2026-10-29-helen/session-x.csv\n\n# note\n"
    assert F.parse_manifest(text) == [(H, None, "2026-10-29-helen/README.md"),
                                      ("b" * 64, None, "2026-10-29-helen/session-x.csv")]


@pytest.mark.parametrize("line", [f"{H}  ../escape", f"{H}  12  ../escape", f"{H}  /abs/path", f"{H}  a/../../b",
                                  "short  a.csv", f"{H}", f"{'z' * 64}  a.csv"])
def test_refuses_bad_lines(line):
    with pytest.raises((F.CorpusError, ValueError)):
        F.parse_manifest(line)


def test_refuses_empty_manifest():
    with pytest.raises(F.CorpusError):
        F.parse_manifest("\n# nothing\n")


def test_needs_credentials(monkeypatch):
    monkeypatch.delenv("BARPATH_USER_ID", raising=False)
    monkeypatch.delenv("BARPATH_SUPABASE_KEY", raising=False)
    assert F.main([]) == 2


# ---- main() with the HTTP layer replaced (no network) -------------------------------------------

import hashlib  # noqa: E402
import urllib.error  # noqa: E402

FILES = {"2026-10-29-helen/README.md": b"helen notes\n",
         "2026-10-29-gym/session-a.csv": b"t,ax\n0,1\n"}
LABEL_FILES = {"2026-01-01-x.json": b'{"version": 1}\n'}


def manifest(files, sizes=True, override=None):
    lines = []
    for rel, data in files.items():
        digest = hashlib.sha256(data).hexdigest()
        size = len(data)
        if override and rel in override:
            digest, size = override[rel].get("sha", digest), override[rel].get("size", size)
        lines.append(f"{digest}  {size}  {rel}" if sizes else f"{digest}  {rel}")
    return ("\n".join(lines) + "\n").encode()


@pytest.fixture
def store(monkeypatch, tmp_path):
    """A fake Storage: {path: bytes}; records every download."""
    objects = {"MANIFEST.sha256": manifest(FILES), **FILES}
    calls = []

    labels = {"MANIFEST.sha256": manifest(LABEL_FILES), **LABEL_FILES}

    def download(user, key, rel, kind="raw"):
        calls.append(rel if kind == "raw" else f"{kind}:{rel}")
        store = objects if kind == "raw" else labels if kind == "labels" else {}
        if rel not in store:
            raise urllib.error.HTTPError(rel, 404, "not found", {}, None)
        return store[rel]

    monkeypatch.setattr(F, "download", download)
    monkeypatch.setattr(F, "RAW_DIR", tmp_path / "data" / "raw")
    monkeypatch.setattr(F, "LABELS_DIR", tmp_path / "data" / "labels")
    monkeypatch.setattr(F, "EVAL_DIR", tmp_path / "data" / "eval")
    monkeypatch.setattr(F, "REPO", tmp_path)
    monkeypatch.setenv("BARPATH_USER_ID", "user")
    monkeypatch.setenv("BARPATH_SUPABASE_KEY", "placeholder")
    return objects, calls, tmp_path / "data" / "raw"


def leftovers(raw):
    return sorted(str(p.relative_to(raw)) for p in raw.rglob("*") if p.is_file())


def test_downloads_and_verifies(store):
    objects, calls, raw = store
    assert F.main([]) == 0
    assert leftovers(raw) == sorted(FILES)
    assert all((raw / rel).read_bytes() == data for rel, data in FILES.items())


@pytest.mark.parametrize("bad", [{"size": 999}, {"sha": "0" * 64}])
def test_wrong_size_or_checksum_fails_and_leaves_nothing(store, bad):
    objects, calls, raw = store
    objects["MANIFEST.sha256"] = manifest(FILES, override={"2026-10-29-gym/session-a.csv": bad})
    assert F.main([]) == 1
    assert leftovers(raw) == ["2026-10-29-helen/README.md"]   # no bad file, no .part


def test_existing_correct_file_is_skipped_and_force_downloads_again(store):
    objects, calls, raw = store
    assert F.main([]) == 0
    calls.clear()
    assert F.main([]) == 0
    assert calls == ["MANIFEST.sha256"]
    calls.clear()
    assert F.main(["--force"]) == 0
    assert sorted(calls) == sorted(["MANIFEST.sha256", *FILES])


def test_folder_filter(store):
    objects, calls, raw = store
    assert F.main(["2026-10-29-helen"]) == 0
    assert leftovers(raw) == ["2026-10-29-helen/README.md"]
    assert F.main(["2026-10-29-typo"]) == 1


def test_missing_object_and_bad_manifest_fail_cleanly(store):
    objects, calls, raw = store
    del objects["2026-10-29-gym/session-a.csv"]
    assert F.main([]) == 1
    objects["MANIFEST.sha256"] = b"not a manifest\n"
    assert F.main([]) == 1
    objects["MANIFEST.sha256"] = f"{'g' * 64}  3  a.csv\n".encode()
    assert F.main([]) == 1


def test_labels_kind_goes_to_data_labels(store):
    objects, calls, raw = store
    assert F.main(["--kind", "labels"]) == 0
    labels = raw.parent / "labels"
    assert (labels / "2026-01-01-x.json").read_bytes() == LABEL_FILES["2026-01-01-x.json"]
    assert not raw.exists()
    assert calls == ["labels:MANIFEST.sha256", "labels:2026-01-01-x.json"]


def test_all_kinds_fail_when_one_manifest_is_missing(store):
    objects, calls, raw = store
    assert F.main(["--kind", "all"]) == 1          # the fake Storage has no eval manifest
    assert (raw / "2026-10-29-helen/README.md").exists()
    assert (raw.parent / "labels" / "2026-01-01-x.json").exists()
