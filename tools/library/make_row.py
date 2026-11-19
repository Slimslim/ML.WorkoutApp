#!/usr/bin/env python3
"""Print the SQL that adds (or updates) workouts in the Supabase workout library.

A definition with `"schemaVersion": 2` (docs/WORKOUT_MODEL_RFC.md) goes to `workout_library_v2`,
the only table it is written to: the database writes the legacy copy into `workout_library`
itself, only when every scale is `fidelity: "exact"` (migration 20261118000100). Any other
definition (today's flat format) goes to `workout_library` as before.

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
built-in version for a shared id). A v2 definition is also checked against
schemas/workout-definition.v2.schema.json (needs `pip install jsonschema`), and its old keys are
checked like a flat definition.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import uuid
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
SCHEMA_V2 = Path(__file__).resolve().parent.parent.parent / "schemas" / "workout-definition.v2.schema.json"
# The keys builds 15/16 read (BarPathKit's WorkoutDefinition): the legacy copy holds only these.
LEGACY_KEYS = ("id", "name", "shortName", "format", "team", "healthKitActivity", "segments",
               "timeCapSeconds", "intervalSeconds", "roundSize")


class LibraryError(ValueError):
    pass


def validate_definition(d: dict, owner: Optional[str] = None) -> WorkoutDefinition:
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
    if owner is not None:
        check_owner_id(definition.id, owner)
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


def is_v2(d) -> bool:
    return isinstance(d, dict) and d.get("schemaVersion") == 2


_v2_validator = None


def _schema_v2_validator():
    global _v2_validator
    if _v2_validator is None:
        try:
            import jsonschema
        except ImportError as e:  # pragma: no cover
            raise LibraryError("checking a schemaVersion 2 definition needs jsonschema "
                               "(pip install jsonschema)") from e
        schema = json.loads(SCHEMA_V2.read_text(encoding="utf-8"))
        _v2_validator = jsonschema.Draft7Validator(schema)
    return _v2_validator


def is_exact(d: dict) -> bool:
    """Every scale is `fidelity: "exact"` (without `scales`: the root `fidelity`)."""
    scales = d.get("scales")
    if isinstance(scales, list):
        return len(scales) > 0 and all(isinstance(s, dict) and s.get("fidelity") == "exact"
                                       for s in scales)
    return d.get("fidelity") == "exact"


def legacy_copy(d: dict) -> Optional[dict]:
    """What the database copies into workout_library for builds 15/16: the old keys of an exact
    definition, None otherwise. Mirror of public.workout_v2_legacy_definition (the database also
    needs the row to be published)."""
    if not is_exact(d):
        return None
    return {k: d[k] for k in LEGACY_KEYS if k in d}


def validate_v2(d: dict, owner: Optional[str] = None) -> dict:
    """A schemaVersion 2 definition as the database will accept it; raises LibraryError."""
    if not isinstance(d, dict):
        raise LibraryError("definition must be a JSON object")
    errors = list(_schema_v2_validator().iter_errors(d))
    if errors:
        from jsonschema.exceptions import best_match
        e = best_match(errors)
        where = "/".join(str(p) for p in e.absolute_path) or "(root)"
        raise LibraryError(f"does not match the v2 schema at {where}: {e.message[:200]}"
                           + (f" (+{len(errors) - 1} more)" if len(errors) > 1 else ""))
    # The old keys must still decode on today's apps, exactly like a flat definition.
    validate_definition({k: d[k] for k in LEGACY_KEYS if k in d}, owner)
    if len(json.dumps(d, ensure_ascii=False).encode("utf-8")) > 65536:
        raise LibraryError("definition is larger than 64 KB")
    return d


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


def parse_owner(owner) -> str:
    """The owner's user id as a lowercase, hyphenated UUID; raises LibraryError otherwise."""
    try:
        return str(uuid.UUID(str(owner)))
    except ValueError as e:
        raise LibraryError(f"owner {owner!r} must be a user id (a UUID)") from e


def owner_suffix(owner) -> str:
    """'.u' + the first 8 hex characters of the owner id: makes ids unique per tester."""
    return ".u" + parse_owner(owner).replace("-", "")[:8]


def check_owner_id(definition_id: str, owner) -> None:
    """A personal row's id must end with the owner's suffix (ids are global, testers can
    share a program, date and slug)."""
    suffix = owner_suffix(owner)
    if not definition_id.endswith(suffix):
        raise LibraryError(f"a personal workout (owner {parse_owner(owner)}) needs an id ending "
                           f"with {suffix!r}, e.g. {definition_id + suffix!r} (id is {definition_id!r})")


def make_row(definition: WorkoutDefinition, program, scheduled_on, published: bool = True,
             gym: Optional[str] = None, owner: Optional[str] = None) -> str:
    """`insert … on conflict (id) do update` for one workout. With `gym` (e.g. 'test-gym',
    migration 20261110000000_gyms.sql) the row is that gym's programming, seen by its members;
    without, the statement is unchanged (a public row: owner and gym_id stay null). With `owner`
    (a user id) the row is that user's personal workout: the id must end with the owner's
    suffix, and the upsert only updates a row that already has the same owner, so one tester's
    row is never overwritten by another's."""
    if owner is not None:
        if gym is not None:
            raise LibraryError("a row has an owner or a gym, never both")
        owner = parse_owner(owner)
        check_owner_id(definition.id, owner)
    if gym is not None and not GYM_PATTERN.match(str(gym)):
        raise LibraryError(f"gym {gym!r} must be a slug like test-gym")
    if scheduled_on is not None:
        try:
            scheduled_on = date.fromisoformat(str(scheduled_on)).isoformat()
        except ValueError as e:
            raise LibraryError(f"scheduled_on {scheduled_on!r} is not YYYY-MM-DD") from e
    if program is not None and not str(program).strip():
        program = None
    cols = "id, definition, program, scheduled_on, published" + (", gym_id" if gym else "") + (", owner" if owner else "")
    vals = (f"{_sql_text(definition.id)}, {_sql_text(definition.to_json())}::jsonb, "
            f"{_sql_text(program)}, {_sql_text(scheduled_on)}"
            f"{'::date' if scheduled_on is not None else ''}, {'true' if published else 'false'}"
            + (f", {_sql_text(gym)}" if gym else "")
            + (f", {_sql_text(owner)}::uuid" if owner else ""))
    if owner:
        return (
            f"insert into public.workout_library ({cols})\n"
            f"values ({vals})\n"
            "on conflict (id) do update set definition = excluded.definition,\n"
            "  program = excluded.program, scheduled_on = excluded.scheduled_on,\n"
            "  published = excluded.published\n"
            "  where public.workout_library.owner = excluded.owner;\n")
    return (
        f"insert into public.workout_library ({cols})\n"
        f"values ({vals})\n"
        "on conflict (id) do update set definition = excluded.definition,\n"
        "  program = excluded.program, scheduled_on = excluded.scheduled_on,\n"
        "  published = excluded.published" + (", gym_id = excluded.gym_id" if gym else "") + ";\n")


def make_row_v2(d: dict, program, scheduled_on, published: bool = True,
                gym: Optional[str] = None, owner: Optional[str] = None) -> str:
    """`insert … on conflict (id) do update` into workout_library_v2 for one checked v2
    definition (see validate_v2). The JSON is written as given, so unknown keys pass through.
    The database sets the revision and writes (or removes) the legacy copy."""
    if owner is not None:
        if gym is not None:
            raise LibraryError("a row has an owner or a gym, never both")
        owner = parse_owner(owner)
        check_owner_id(d["id"], owner)
    if gym is not None and not GYM_PATTERN.match(str(gym)):
        raise LibraryError(f"gym {gym!r} must be a slug like test-gym")
    if scheduled_on is not None:
        try:
            scheduled_on = date.fromisoformat(str(scheduled_on)).isoformat()
        except ValueError as e:
            raise LibraryError(f"scheduled_on {scheduled_on!r} is not YYYY-MM-DD") from e
    if program is not None and not str(program).strip():
        program = None
    text = json.dumps(d, ensure_ascii=False)
    vals = (f"{_sql_text(d['id'])}, {_sql_text(text)}::jsonb, {_sql_text(program)}, "
            f"{_sql_text(scheduled_on)}{'::date' if scheduled_on is not None else ''}, "
            f"{'true' if published else 'false'}, {_sql_text(gym)}, "
            f"{_sql_text(owner)}{'::uuid' if owner else ''}")
    # Every value goes inside the $mr$ … $mr$ block: none may contain its delimiter (the
    # definition, and the free text program; id, gym and owner are checked above, but cheap).
    for name, value in (("definition", text), ("program", program), ("id", d["id"]),
                        ("gym", gym), ("owner", owner), ("scheduled_on", scheduled_on)):
        if value is not None and "$mr$" in str(value):
            raise LibraryError(f"{name} must not contain the text $mr$")
    sql = ("do $mr$\nbegin\n"
           "insert into public.workout_library_v2 (id, definition, program, scheduled_on, published, gym_id, owner)\n"
           f"values ({vals})\n"
           "on conflict (id) do update set definition = excluded.definition,\n"
           "  program = excluded.program, scheduled_on = excluded.scheduled_on,\n"
           "  published = excluded.published" + (", gym_id = excluded.gym_id" if gym else ""))
    if owner:
        sql += "\n  where public.workout_library_v2.owner = excluded.owner"
    else:
        sql += "\n  where public.workout_library_v2.owner is null"
    # An upsert the WHERE skips writes nothing and reports success: make that an error.
    return (sql + ";\n"
            f"if not found then raise exception 'make_row: % was not written: the id belongs to another owner or audience', {_sql_text(d['id'])}; end if;\n"
            "end\n$mr$;\n")


def load_file(path) -> tuple:
    """(definition dict, program, scheduled_on, published, gym) from a seed-style or bare JSON file."""
    return load_file_with_owner(path)[:5]


def load_file_with_owner(path) -> tuple:
    """Like load_file, with the file's "owner" (or None) as a sixth item."""
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    if isinstance(raw, dict) and "definition" in raw:
        unknown = set(raw) - {"definition", "program", "scheduled_on", "published", "gym", "owner"}
        if unknown:
            raise LibraryError(f"{path}: unknown keys {sorted(unknown)}")
        return (raw["definition"], raw.get("program"), raw.get("scheduled_on"),
                bool(raw.get("published", True)), raw.get("gym"), raw.get("owner"))
    return raw, None, None, True, None, None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", help="WorkoutDefinition JSON files")
    ap.add_argument("--builtin", help="use this built-in definition from tools/barpath/workout.py")
    ap.add_argument("--id", help="library id (required with --builtin; renames a file's definition)")
    ap.add_argument("--program", help="program name, e.g. Example (overrides the file)")
    ap.add_argument("--date", help="scheduled_on, YYYY-MM-DD (overrides the file)")
    ap.add_argument("--unpublished", action="store_true", help="add it hidden (published = false)")
    ap.add_argument("--gym", help="gym id, e.g. test-gym: the gym's programming (overrides the file)")
    ap.add_argument("--trust-old-keys", action="store_true",
                    help="allow a published, exact v2 row (its old keys are copied to builds 15/16). Until the "
                         "compiler checks them (build 17 item 2), check the old keys against the structure by hand first")
    ap.add_argument("--owner", help="user id (UUID): that user's personal workout, seen only by them; "
                    "the id must end with .u<first 8 hex of the user id> (overrides the file)")
    args = ap.parse_args(argv)

    items = []
    try:
        if args.builtin:
            builtin = WorkoutLibrary.definition(args.builtin)
            if builtin is None:
                raise LibraryError(f"no built-in workout {args.builtin!r}")
            if not args.id:
                raise LibraryError("--builtin needs --id lib.<program>.<yyyymmdd>.<slug>")
            items.append(("--builtin " + args.builtin, builtin.to_dict(), None, None, True, None, None))
        for f in args.files:
            items.append((f,) + load_file_with_owner(f))
        if not items:
            ap.error("give JSON files or --builtin")
        if args.id and len(items) > 1:
            raise LibraryError("--id works with one workout at a time")

        out = ["-- Generated by tools/library/make_row.py. Paste into Supabase -> SQL editor -> Run.\n"]
        seen = set()
        for source, d, program, day, published, gym, file_owner in items:
            owner = args.owner if args.owner is not None else file_owner
            gym = args.gym if args.gym is not None else gym
            if args.id:
                d = dict(d, id=args.id)
            program = args.program if args.program is not None else program
            day = args.date if args.date is not None else day
            published = published and not args.unpublished
            try:
                if owner is not None and gym is not None:
                    raise LibraryError("a row has an owner or a gym, never both")
                if is_v2(d):
                    validate_v2(d, owner)
                    the_id, name = d["id"], d["name"]
                    copy = "legacy copy for builds 15/16" if legacy_copy(d) is not None else "no legacy copy (not exact)"
                    if published and legacy_copy(d) is not None and not args.trust_old_keys:
                        raise LibraryError("a published, exact v2 row is copied to builds 15/16, and nothing "
                                           "checks its old keys against the structure yet (build 17 item 2): "
                                           "check them by hand, then pass --trust-old-keys")
                    row = make_row_v2(d, program, day, published, gym, owner)
                else:
                    definition = validate_definition(d, owner)
                    the_id, name, copy = definition.id, definition.name, None
                    row = make_row(definition, program, day, published, gym, owner)
            except LibraryError as e:
                raise LibraryError(f"{source}: {e}") from e
            if the_id in seen:
                raise LibraryError(f"{source}: id {the_id!r} appears twice")
            seen.add(the_id)
            out.append(f"\n-- {name} ({source}{'; v2, ' + copy if copy else ''})\n")
            out.append(row)
    except LibraryError as e:
        print(f"make_row: {e}", file=sys.stderr)
        return 1
    sys.stdout.write("".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
