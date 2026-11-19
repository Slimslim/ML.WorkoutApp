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
