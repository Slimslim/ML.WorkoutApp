#!/usr/bin/env python3
"""Print a week of the gym's CrossFit class workouts from PushPress Train (main workout parts only).

    python3 tools/library/pushpress_week.py 11/23/2026          # the week containing that date

Only the class's scored workout is kept: warm-up, cool-down, optional accessory, GOWOD activation,
announcements, coach videos and strength pieces are skipped (owner, 17 Nov). Days still in DRAFT
are listed but marked. The text is then turned into library rows by hand (docs/WORKOUT_LIBRARY.md),
with the gym id (`--gym blue-republic`).

Auth: the request goes to trainapi.pushpress.com; in a cloud session the network proxy adds the
saved token (environment network secret). Never put a token in this file or the repo.
"""
import html
import json
import re
import sys
import urllib.request

URL = ("https://trainapi.pushpress.com/workout/workoutOfDay/week/v1"
       "?classTypeId={cls}&date={date}&programEntityType=WORKOUT_PROGRAM")
CROSSFIT_CLASS = 101805
SKIP = re.compile(r"warm ?up|cool ?down|accessory|gowod|announcement|coach video|if you are new", re.I)
KEEP_SCORES = {"FOR_TIME", "FOR_ROUNDS_REPS", "FOR_REPS", "FOR_CALORIES", "FOR_DISTANCE"}


def text(desc: str) -> str:
    t = re.sub(r"<[^>]+>", "\n", html.unescape(desc or ""))
    return re.sub(r"\n\s*\n+", "\n", t).strip()


def main_parts(day: dict) -> list:
    """The class's scored workout parts of one day."""
    return [p for p in sorted(day.get("partDtos") or [], key=lambda p: p.get("sortOrder") or "")
            if not SKIP.search(p.get("title") or "") and p.get("scoreType") in KEEP_SCORES
            and p.get("workoutType") == "METCON"]


def fetch(date: str, cls: int = CROSSFIT_CLASS) -> list:
    req = urllib.request.Request(URL.format(cls=cls, date=date), headers={
        "Content-Type": "application/json",  # required, even on GET (415 without it)
        "Accept": "application/json",
        "Authorization": "Bearer proxy-injected",  # replaced by the proxy's saved token
        "Origin": "https://train.pushpress.com", "Referer": "https://train.pushpress.com/"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    for day_list in fetch(sys.argv[1]):
        for day in day_list:
            state = "" if day.get("workoutState") == "PUBLISHED" else f"  [{day.get('workoutState')}]"
            print(f"\n=== {day.get('publishingDate', '')[:10]}{state}")
            for p in main_parts(day):
                print(f"--- {p.get('title')} ({p.get('scoreType')})\n{text(p.get('description'))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
