#!/usr/bin/env python3
"""Print the SQL that adds (or updates) workouts in the Supabase `workout_library` table.

Paste the output into the Supabase dashboard -> SQL editor -> Run. See docs/WORKOUT_LIBRARY.md.

    # one or more JSON files: a bare WorkoutDefinition, or
    # {"program": ..., "scheduled_on": "YYYY-MM-DD", "published": true, "definition": {...}}
    python3 tools/library/make_row.py tools/library/seed/*.json > tools/library/seed/seed.sql

    # a built-in definition from tools/barpath/workout.py under a library id
    python3 tools/library/make_row.py --builtin wod.helen --id lib.benchmark.20261110.helen \
        --program Benchmark --date 2026-11-10

Every definition is checked against the Python mirror of BarPathKit's WorkoutDefinition: it must
round-trip unchanged (no unknown or misspelled keys, every required key present), use known
kinds/units/formats, and have a `lib.` id that no built-in workout uses (the watch prefers its
built-in version for a shared id).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import date
from pathlib import Path
from typing import Optional

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from barpath.workout import (  # noqa: E402
    SEGMENT_KINDS, TARGET_UNITS, WorkoutDefinition, WorkoutLibrary)

FORMATS = ("forTime", "amrap", "emom")
TEAMS = ("solo", "doubles", "team")
LOAD_UNITS = ("lb", "kg")
ID_PATTERN = re.compile(r"^lib\.[a-z0-9-]+(\.[a-z0-9-]+)+$")


class LibraryError(ValueError):
    pass


def validate_definition(d: dict) -> WorkoutDefinition:
    """The definition as the app will decode it; raises LibraryError when it would not decode
    the same way (or would not run sensibly)."""
    if not isinstance(d, dict):
        raise LibraryError("definition must be a JSON object")
    try:
        definition = WorkoutDefinition.from_dict(d)
    except (KeyError, TypeError, ValueError, AttributeError) as e:
        raise LibraryError(f"does not decode as a WorkoutDefinition: {e!r}") from e
    again = definition.to_dict()
    if again != d:
        extra = sorted(set(_flat_keys(d)) - set(_flat_keys(again)))
        missing = sorted(set(_flat_keys(again)) - set(_flat_keys(d)))
        detail = []
        if extra:
            detail.append("unknown keys " + ", ".join(extra))
        if missing:
            detail.append("missing keys " + ", ".join(missing))
        raise LibraryError("does not round-trip through WorkoutDefinition"
                           + (": " + "; ".join(detail) if detail else " (a value changed type)"))
    if WorkoutDefinition.from_json(definition.to_json()) != definition:
        raise LibraryError("JSON round trip changed the definition")

    if WorkoutLibrary.definition(definition.id) is not None:
        raise LibraryError(f"id {definition.id!r} is a built-in workout id")
    if not ID_PATTERN.match(definition.id):
        raise LibraryError(f"id {definition.id!r} must look like lib.<program>.<yyyymmdd>.<slug> "
                           "(lowercase letters, digits, '-')")
    if not definition.name.strip() or not definition.short_name.strip():
        raise LibraryError("name and shortName must not be empty")
    if definition.format not in FORMATS:
        raise LibraryError(f"format {definition.format!r} is not one of {FORMATS}")
    if definition.team not in TEAMS:
        raise LibraryError(f"team {definition.team!r} is not one of {TEAMS}")
    if not definition.segments:
        raise LibraryError("segments must not be empty")
    for i, s in enumerate(definition.segments, start=1):
        if s.kind not in SEGMENT_KINDS:
            raise LibraryError(f"segment {i}: kind {s.kind!r} is not one of {SEGMENT_KINDS}")
        if not s.movement or not s.name:
            raise LibraryError(f"segment {i}: movement and name must not be empty")
        if s.target is not None:
            if s.target.unit not in TARGET_UNITS:
                raise LibraryError(f"segment {i}: unit {s.target.unit!r} is not one of {TARGET_UNITS}")
            if not s.target.value > 0:
                raise LibraryError(f"segment {i}: target must be > 0")
        if s.load is not None:
            if s.load.unit not in LOAD_UNITS:
                raise LibraryError(f"segment {i}: load unit {s.load.unit!r} is not one of {LOAD_UNITS}")
            if not s.load.value > 0 or s.load.count < 1:
                raise LibraryError(f"segment {i}: load value must be > 0 and count >= 1")
    if definition.time_cap_seconds is not None and not definition.time_cap_seconds > 0:
        raise LibraryError("timeCapSeconds must be > 0")
    if definition.interval_seconds is not None and not definition.interval_seconds > 0:
        raise LibraryError("intervalSeconds must be > 0")
    if definition.round_size is not None and not 1 <= definition.round_size <= len(definition.segments):
        raise LibraryError("roundSize must be between 1 and the number of segments")
    if definition.format == "amrap" and definition.time_cap_seconds is None:
        raise LibraryError("an AMRAP needs timeCapSeconds")
    return definition


def _flat_keys(value, prefix: str = "") -> list:
    out = []
    if isinstance(value, dict):
        for k, v in value.items():
            out.append(prefix + k)
            out.extend(_flat_keys(v, prefix + k + "."))
    elif isinstance(value, list):
        for v in value:
            out.extend(_flat_keys(v, prefix + "[]."))
    return out


def _sql_text(value) -> str:
    if value is None:
        return "null"
    return "'" + str(value).replace("'", "''") + "'"


GYM_PATTERN = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")


def make_row(definition: WorkoutDefinition, program, scheduled_on, published: bool = True,
             gym: Optional[str] = None) -> str:
    """`insert … on conflict (id) do update` for one workout. With `gym` (e.g. 'blue-republic',
    migration 20261110000000_gyms.sql) the row is that gym's programming, seen by its members;
    without, the statement is unchanged (a public row: owner and gym_id stay null)."""
    if gym is not None and not GYM_PATTERN.match(str(gym)):
        raise LibraryError(f"gym {gym!r} must be a slug like blue-republic")
    if scheduled_on is not None:
        try:
            scheduled_on = date.fromisoformat(str(scheduled_on)).isoformat()
        except ValueError as e:
            raise LibraryError(f"scheduled_on {scheduled_on!r} is not YYYY-MM-DD") from e
    if program is not None and not str(program).strip():
        program = None
    cols = "id, definition, program, scheduled_on, published" + (", gym_id" if gym else "")
    vals = (f"{_sql_text(definition.id)}, {_sql_text(definition.to_json())}::jsonb, "
            f"{_sql_text(program)}, {_sql_text(scheduled_on)}"
            f"{'::date' if scheduled_on is not None else ''}, {'true' if published else 'false'}"
            + (f", {_sql_text(gym)}" if gym else ""))
    return (
        f"insert into public.workout_library ({cols})\n"
        f"values ({vals})\n"
        "on conflict (id) do update set definition = excluded.definition,\n"
        "  program = excluded.program, scheduled_on = excluded.scheduled_on,\n"
        "  published = excluded.published" + (", gym_id = excluded.gym_id" if gym else "") + ";\n")


def load_file(path) -> tuple:
    """(definition dict, program, scheduled_on, published, gym) from a seed-style or bare JSON file."""
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict) and "definition" in raw:
        unknown = set(raw) - {"definition", "program", "scheduled_on", "published", "gym"}
        if unknown:
            raise LibraryError(f"{path}: unknown keys {sorted(unknown)}")
        return (raw["definition"], raw.get("program"), raw.get("scheduled_on"),
                bool(raw.get("published", True)), raw.get("gym"))
    return raw, None, None, True, None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", help="WorkoutDefinition JSON files")
    ap.add_argument("--builtin", help="use this built-in definition from tools/barpath/workout.py")
    ap.add_argument("--id", help="library id (required with --builtin; renames a file's definition)")
    ap.add_argument("--program", help="program name, e.g. Mayhem (overrides the file)")
    ap.add_argument("--date", help="scheduled_on, YYYY-MM-DD (overrides the file)")
    ap.add_argument("--unpublished", action="store_true", help="add it hidden (published = false)")
    ap.add_argument("--gym", help="gym id, e.g. blue-republic: the gym's programming (overrides the file)")
    args = ap.parse_args(argv)

    items = []
    try:
        if args.builtin:
            builtin = WorkoutLibrary.definition(args.builtin)
            if builtin is None:
                raise LibraryError(f"no built-in workout {args.builtin!r}")
            if not args.id:
                raise LibraryError("--builtin needs --id lib.<program>.<yyyymmdd>.<slug>")
            items.append(("--builtin " + args.builtin, builtin.to_dict(), None, None, True, None))
        for f in args.files:
            items.append((f,) + load_file(f))
        if not items:
            ap.error("give JSON files or --builtin")
        if args.id and len(items) > 1:
            raise LibraryError("--id works with one workout at a time")

        out = ["-- Generated by tools/library/make_row.py. Paste into Supabase -> SQL editor -> Run.\n"]
        seen = set()
        for source, d, program, day, published, gym in items:
            if args.id:
                d = dict(d, id=args.id)
            try:
                definition = validate_definition(d)
            except LibraryError as e:
                raise LibraryError(f"{source}: {e}") from e
            if definition.id in seen:
                raise LibraryError(f"{source}: id {definition.id!r} appears twice")
            seen.add(definition.id)
            out.append(f"\n-- {definition.name} ({source})\n")
            out.append(make_row(definition,
                                args.program if args.program is not None else program,
                                args.date if args.date is not None else day,
                                published and not args.unpublished,
                                args.gym if args.gym is not None else gym))
    except LibraryError as e:
        print(f"make_row: {e}", file=sys.stderr)
        return 1
    sys.stdout.write("".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
