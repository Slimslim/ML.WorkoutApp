#!/usr/bin/env python3
"""Download the recordings that data/labels/*.json refer to into data/cache/<label id>/.

The recordings live in the owner's private Supabase Storage folder (bucket `uploads`,
`<user id>/<path>`), uploaded by the phone. Reading them needs the project's secret key:

    BARPATH_USER_ID=<user id> BARPATH_SUPABASE_KEY=<secret key> python3 tools/fetch_sessions.py

In a Claude cloud session the network proxy adds the key; pass any placeholder as the key.
Files already in the cache are skipped (use --force to download again). data/cache/ is ignored
by git: recordings never go into the repository.
"""
from __future__ import annotations

import argparse
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from barpath import labels as L  # noqa: E402

PROJECT_URL = "https://wgxhbifmjepjbqfqefmd.supabase.co"   # = BarPath/iOS/Cloud/CloudConfig.swift
BUCKET = "uploads"


def files_of(d: dict) -> list:
    if d["kind"] == "lifts":
        return [x["file"] for x in d["sets"]]
    return [v for v in d["files"].values() if isinstance(v, str)]


def fetch(user: str, key: str, path: str, dest: Path) -> None:
    url = f"{PROJECT_URL}/storage/v1/object/{BUCKET}/{user}/{path}"
    req = urllib.request.Request(url, headers={"apikey": key, "Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    tmp.write_bytes(data)
    tmp.replace(dest)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("labels", nargs="*", help="label files (default: every file in data/labels)")
    ap.add_argument("--force", action="store_true", help="download again even when cached")
    args = ap.parse_args()
    user = os.environ.get("BARPATH_USER_ID")
    key = os.environ.get("BARPATH_SUPABASE_KEY")
    if not user or not key:
        print("Set BARPATH_USER_ID and BARPATH_SUPABASE_KEY (see the docstring).", file=sys.stderr)
        return 2
    paths = [Path(p) for p in args.labels] or L.all_label_files()
    failed = 0
    for p in paths:
        d = L.load(p)
        for f in files_of(d):
            dest = L.CACHE_DIR / d["id"] / Path(f).name
            if dest.exists() and not args.force:
                print(f"cached  {d['id']}/{dest.name}")
                continue
            try:
                fetch(user, key, f, dest)
                print(f"fetched {d['id']}/{dest.name} ({dest.stat().st_size // 1024} KB)")
            except urllib.error.URLError as e:
                failed += 1
                print(f"FAILED  {d['id']}/{f}: {e}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
