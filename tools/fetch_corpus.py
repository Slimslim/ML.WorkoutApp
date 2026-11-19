#!/usr/bin/env python3
"""Download the owner's older recordings (the corpus that used to be in data/raw/) back into
data/raw/, for the tools and tests that read them.

The corpus lives in the owner's private Supabase Storage folder (bucket `uploads`,
`<user id>/Corpus/raw/<session folder>/<file>`, stored plain) with a checksum list
`Corpus/raw/MANIFEST.sha256`: one line per file, `<sha256>  <bytes>  <path relative to Corpus/raw/>`
(plain sha256sum lines without the size are accepted too). Only the owner's account and the
service role can read the folder. Reading it needs the project's secret key, exactly like
tools/fetch_sessions.py:

    BARPATH_USER_ID=<user id> BARPATH_SUPABASE_KEY=<secret key> python3 tools/fetch_corpus.py

In a Claude cloud session the network proxy adds the key; pass any placeholder as the key.
Every file is checked against the manifest (size and sha256); a file already in data/raw/ with the
right checksum is skipped (--force downloads again). data/raw/ is ignored by git: recordings never go into the
repository (CLAUDE.md). Without the corpus, the tests that need it are skipped.

    python3 tools/fetch_corpus.py 2026-10-29-helen     # only the folders whose path starts so
"""
from __future__ import annotations

import argparse
import hashlib
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

PROJECT_URL = "https://wgxhbifmjepjbqfqefmd.supabase.co"   # = BarPath/iOS/Cloud/CloudConfig.swift
BUCKET = "uploads"
PREFIX = "Corpus/raw"
REPO = Path(__file__).resolve().parents[1]
RAW_DIR = REPO / "data" / "raw"


class CorpusError(Exception):
    pass


def parse_manifest(text: str) -> list:
    """[(sha256, bytes or None, relative path)] from `<sha256>  <bytes>  <path>` lines (or plain
    sha256sum lines); refuses paths that leave the folder."""
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        # `<sha256>  <bytes>  <path>` (the Data chat's manifest). Plain sha256sum lines
        # (`<sha256>  <path>`) are read as such only when the second field is not a number, so
        # a 2-field path starting with a number-only word is read as a size: use 3 fields.
        parts = line.split(None, 2)
        size = None
        if len(parts) == 3 and parts[1].isdigit():
            size = int(parts[1])
            parts = [parts[0], parts[2]]
        else:
            parts = line.split(None, 1)
        if len(parts) != 2 or len(parts[0]) != 64:
            raise CorpusError(f"manifest line {n}: not '<sha256>  <bytes>  <path>'")
        digest, rel = parts[0].lower(), parts[1].strip()
        if rel.startswith("*"):            # sha256sum binary-mode marker
            rel = rel[1:]
        if rel.startswith("./"):
            rel = rel[2:]
        p = Path(rel)
        if not rel or p.is_absolute() or ".." in p.parts:
            raise CorpusError(f"manifest line {n}: unsafe path {rel!r}")
        if any(c not in "0123456789abcdef" for c in digest):
            raise CorpusError(f"manifest line {n}: the checksum is not hex")
        out.append((digest, size, rel))
    if not out:
        raise CorpusError("manifest is empty")
    return out


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def download(user: str, key: str, rel: str) -> bytes:
    object_path = "/".join(urllib.parse.quote(part) for part in f"{user}/{PREFIX}/{rel}".split("/"))
    url = f"{PROJECT_URL}/storage/v1/object/authenticated/{BUCKET}/{object_path}"
    req = urllib.request.Request(url, headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("only", nargs="*", help="only paths starting with one of these (e.g. 2026-10-29-helen)")
    ap.add_argument("--force", action="store_true", help="download again even when the checksum matches")
    args = ap.parse_args(argv)
    user = os.environ.get("BARPATH_USER_ID")
    key = os.environ.get("BARPATH_SUPABASE_KEY")
    if not user or not key:
        print("Set BARPATH_USER_ID and BARPATH_SUPABASE_KEY (see the docstring).", file=sys.stderr)
        return 2
    try:
        entries = parse_manifest(download(user, key, "MANIFEST.sha256").decode("utf-8"))
    except (OSError, CorpusError, UnicodeDecodeError) as e:   # URLError and timeouts are OSErrors
        print(f"FAILED  manifest: {e}", file=sys.stderr)
        return 1
    if args.only:
        entries = [e for e in entries if any(e[2].startswith(o.rstrip("/")) for o in args.only)]
        if not entries:
            print(f"FAILED  no manifest path starts with {', '.join(args.only)}", file=sys.stderr)
            return 1
    failed = 0
    for digest, size, rel in entries:
        dest = RAW_DIR / rel
        if (dest.exists() and not args.force and (size is None or dest.stat().st_size == size)
                and sha256_of(dest) == digest):
            print(f"ok      {rel}")
            continue
        try:
            data = download(user, key, rel)
        except OSError as e:          # URLError, HTTPError, timeouts
            failed += 1
            print(f"FAILED  {rel}: {e}", file=sys.stderr)
            continue
        if size is not None and len(data) != size:
            failed += 1
            print(f"FAILED  {rel}: {len(data)} bytes, manifest says {size}", file=sys.stderr)
            continue
        if hashlib.sha256(data).hexdigest() != digest:
            failed += 1
            print(f"FAILED  {rel}: checksum mismatch", file=sys.stderr)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(dest.name + ".part")
        tmp.write_bytes(data)
        tmp.replace(dest)
        print(f"fetched {rel} ({len(data) // 1024} KB)")
    print(f"{len(entries) - failed} of {len(entries)} files in {RAW_DIR.relative_to(REPO)}/")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
