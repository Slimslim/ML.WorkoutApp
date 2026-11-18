-- Build 17, item 1 (#70, docs/WORKOUT_MODEL_RFC.md 7.2 and 14.3 F2-F7): the v2 library table.
--
-- * workout_library_v2: one row per workout, `definition` is a schemaVersion 2 definition
--   (structure, scales, rawText, fidelity, plus the old keys compiled from the default scale).
--   It has ONE writer: tools/library/make_row.py and, later, the import (both write here only).
-- * The legacy copy: a trigger writes the old keys of a v2 row into workout_library, so builds
--   15/16 can run it, ONLY when the row is published and every scale is `fidelity: "exact"` (D5).
--   Otherwise there is no legacy row (an existing copy is removed). Nobody else may write an id
--   that belongs to a v2 row into workout_library.
-- * The database checks the JSON Schema only (pg_jsonschema). The schema below is a copy of
--   schemas/workout-definition.v2.schema.json; tools/tests/test_workout_library_v2.py fails when
--   they differ. Unknown fields pass through unchanged (jsonb keeps them; the schema is open).
-- * Revisions: `revision` goes up only when the definition changes; every revision is kept in
--   workout_library_v2_revisions (readable exactly when the row is). A rollback is a new revision.
-- * workout_custom_scales: an athlete's own "Mine" scale of a workout, user-only.
-- * Paging: workout_library_v2_page(after_id, page_size), keyset on id, at most 1000 rows a page.
--
-- The 29 published legacy rows are not touched (D5); their ids can't be taken by a v2 row until
-- the migration of those rows (build 17 item 5).
-- Rollback: supabase/rollback/20261118_backend_v2_rollback.sql.

-- Run as one transaction. Never queue behind a long reader of workout_library: fail fast, retry.
set local lock_timeout = '5s';

create extension if not exists pg_jsonschema with schema extensions;

-- The JSON Schema (copy of schemas/workout-definition.v2.schema.json, keep them equal).
create function public.workout_definition_v2_schema() returns json
language sql immutable parallel safe set search_path = '' as $fn$
select $schema$
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "Workout definition, schemaVersion 2 (docs/WORKOUT_MODEL_RFC.md 3.3, 3.6, 14.3)",
  "description": "Checked by the database (pg_jsonschema, migration 20261118000100) and by tools/library/make_row.py. Strict about the old keys and the engine fields; open (additionalProperties) everywhere else, so descriptive and future fields (note, rawText, tempo, x-*, resume, interrupt) pass through unchanged (RFC 3.2, 14.4). Rules the schema cannot express (nesting depth, step count, vary lengths, the compiled old keys) belong to the validator and compiler (RFC section 11, build 17 item 2).",
  "type": "object",
  "required": [
    "schemaVersion",
    "id",
    "name",
    "shortName",
    "format",
    "team",
    "healthKitActivity",
    "segments",
    "structure"
  ],
  "properties": {
    "schemaVersion": {
      "const": 2
    },
    "id": {
      "type": "string",
      "pattern": "^lib\\.[a-z0-9-]+(\\.[a-z0-9-]+)+$",
      "maxLength": 200
    },
    "name": {
      "$ref": "#/definitions/text"
    },
    "shortName": {
      "$ref": "#/definitions/text"
    },
    "format": {
      "enum": [
        "forTime",
        "amrap",
        "emom"
      ]
    },
    "team": {
      "enum": [
        "solo",
        "doubles",
        "team"
      ]
    },
    "healthKitActivity": {
      "type": "string",
      "minLength": 1
    },
    "segments": {
      "type": "array",
      "items": {
        "$ref": "#/definitions/segment"
      },
      "minItems": 1
    },
    "timeCapSeconds": {
      "type": "number",
      "exclusiveMinimum": 0
    },
    "intervalSeconds": {
      "type": "number",
      "exclusiveMinimum": 0
    },
    "roundSize": {
      "type": "integer",
      "minimum": 1
    },
    "requires": {
      "type": "array",
      "uniqueItems": true,
      "items": {
        "type": "string",
        "pattern": "^[a-zA-Z][a-zA-Z0-9]*$"
      }
    },
    "structure": {
      "$ref": "#/definitions/structure"
    },
    "scales": {
      "type": "array",
      "minItems": 1,
      "maxItems": 8,
      "items": {
        "$ref": "#/definitions/scale"
      }
    },
    "rawText": {
      "type": "string"
    },
    "fidelity": {
      "$ref": "#/definitions/fidelity"
    },
    "approx": {
      "$ref": "#/definitions/approx"
    },
    "stimulus": {
      "type": "object"
    }
  },
  "anyOf": [
    {
      "required": [
        "scales"
      ]
    },
    {
      "required": [
        "fidelity"
      ]
    }
  ],
  "definitions": {
    "text": {
      "type": "string",
      "minLength": 1,
      "pattern": "\\S"
    },
    "nodeId": {
      "type": "string",
      "pattern": "^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$"
    },
    "fidelity": {
      "enum": [
        "exact",
        "approx",
        "textOnly"
      ]
    },
    "approx": {
      "type": "array",
      "items": {
        "type": "string",
        "minLength": 1
      }
    },
    "positive": {
      "type": "number",
      "exclusiveMinimum": 0
    },
    "segment": {
      "type": "object",
      "required": [
        "kind",
        "movement",
        "name"
      ],
      "additionalProperties": false,
      "properties": {
        "kind": {
          "enum": [
            "run",
            "station",
            "transition",
            "rest"
          ]
        },
        "movement": {
          "type": "string",
          "minLength": 1
        },
        "name": {
          "type": "string",
          "minLength": 1
        },
        "target": {
          "type": "object",
          "required": [
            "value",
            "unit"
          ],
          "additionalProperties": false,
          "properties": {
            "value": {
              "$ref": "#/definitions/positive"
            },
            "unit": {
              "enum": [
                "meters",
                "reps",
                "calories",
                "seconds"
              ]
            }
          }
        },
        "load": {
          "type": "object",
          "required": [
            "value",
            "unit",
            "count"
          ],
          "additionalProperties": false,
          "properties": {
            "value": {
              "$ref": "#/definitions/positive"
            },
            "unit": {
              "enum": [
                "lb",
                "kg"
              ]
            },
            "count": {
              "type": "integer",
              "minimum": 1
            }
          }
        }
      }
    },
    "scaleFields": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "pattern": "^[a-z0-9][a-z0-9-]{0,31}$"
        },
        "label": {
          "$ref": "#/definitions/text"
        },
        "short": {
          "type": "string",
          "minLength": 1,
          "maxLength": 5
        },
        "rank": {
          "type": "integer"
        },
        "fidelity": {
          "$ref": "#/definitions/fidelity"
        },
        "approx": {
          "$ref": "#/definitions/approx"
        },
        "rawText": {
          "type": "string"
        },
        "basedOn": {
          "type": "string"
        },
        "structure": {
          "$ref": "#/definitions/structure"
        }
      }
    },
    "scale": {
      "allOf": [
        {
          "$ref": "#/definitions/scaleFields"
        },
        {
          "required": [
            "id",
            "label",
            "rank",
            "fidelity",
            "structure"
          ]
        }
      ]
    },
    "customScale": {
      "allOf": [
        {
          "$ref": "#/definitions/scaleFields"
        },
        {
          "required": [
            "id",
            "label",
            "basedOn",
            "structure"
          ],
          "properties": {
            "id": {
              "const": "custom"
            },
            "basedOn": {
              "type": "string",
              "minLength": 1
            }
          }
        }
      ]
    },
    "structure": {
      "type": "object",
      "required": [
        "body"
      ],
      "properties": {
        "score": {
          "$ref": "#/definitions/score"
        },
        "body": {
          "$ref": "#/definitions/body"
        }
      }
    },
    "score": {
      "type": "object",
      "required": [
        "type"
      ],
      "properties": {
        "type": {
          "type": "string",
          "minLength": 1
        },
        "better": {
          "enum": [
            "higher",
            "lower"
          ]
        },
        "parts": {
          "type": "array",
          "items": {
            "$ref": "#/definitions/nodeId"
          }
        },
        "of": {
          "$ref": "#/definitions/nodeId"
        }
      }
    },
    "body": {
      "type": "array",
      "minItems": 1,
      "items": {
        "$ref": "#/definitions/node"
      }
    },
    "node": {
      "type": "object",
      "minProperties": 1,
      "maxProperties": 1,
      "oneOf": [
        {
          "required": [
            "part"
          ],
          "properties": {
            "part": {
              "$ref": "#/definitions/part"
            }
          }
        },
        {
          "required": [
            "rest"
          ],
          "properties": {
            "rest": {
              "$ref": "#/definitions/rest"
            }
          }
        },
        {
          "required": [
            "group"
          ],
          "properties": {
            "group": {
              "$ref": "#/definitions/group"
            }
          }
        },
        {
          "required": [
            "repeat"
          ],
          "properties": {
            "repeat": {
              "$ref": "#/definitions/repeat"
            }
          }
        },
        {
          "required": [
            "timed"
          ],
          "properties": {
            "timed": {
              "$ref": "#/definitions/timed"
            }
          }
        }
      ]
    },
    "amount": {
      "type": "object",
      "properties": {
        "value": {
          "$ref": "#/definitions/positive"
        },
        "valueF": {
          "$ref": "#/definitions/positive"
        }
      }
    },
    "part": {
      "type": "object",
      "required": [
        "id",
        "movement"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/nodeId"
        },
        "kind": {
          "type": "string",
          "minLength": 1
        },
        "name": {
          "type": "string"
        },
        "movement": {
          "oneOf": [
            {
              "type": "string",
              "minLength": 1
            },
            {
              "type": "object",
              "required": [
                "choice"
              ],
              "properties": {
                "choice": {
                  "oneOf": [
                    {
                      "type": "string",
                      "minLength": 1
                    },
                    {
                      "type": "array",
                      "minItems": 1,
                      "items": {
                        "type": "string",
                        "minLength": 1
                      }
                    }
                  ]
                }
              }
            }
          ]
        },
        "target": {
          "allOf": [
            {
              "$ref": "#/definitions/amount"
            },
            {
              "type": "object",
              "required": [
                "unit"
              ],
              "properties": {
                "unit": {
                  "enum": [
                    "meters",
                    "reps",
                    "calories",
                    "seconds",
                    "ft",
                    "yd",
                    "mi"
                  ]
                },
                "max": {
                  "const": true
                },
                "each": {
                  "type": "object",
                  "required": [
                    "value",
                    "unit"
                  ],
                  "properties": {
                    "value": {
                      "$ref": "#/definitions/positive"
                    },
                    "unit": {
                      "type": "string",
                      "minLength": 1
                    }
                  }
                }
              },
              "anyOf": [
                {
                  "required": [
                    "value"
                  ]
                },
                {
                  "required": [
                    "max"
                  ]
                }
              ]
            }
          ]
        },
        "load": {
          "type": "object",
          "anyOf": [
            {
              "required": [
                "value",
                "unit"
              ],
              "properties": {
                "value": {
                  "$ref": "#/definitions/positive"
                },
                "valueF": {
                  "$ref": "#/definitions/positive"
                },
                "unit": {
                  "enum": [
                    "lb",
                    "kg"
                  ]
                },
                "count": {
                  "type": "integer",
                  "minimum": 1
                }
              }
            },
            {
              "required": [
                "percent"
              ],
              "properties": {
                "percent": {
                  "$ref": "#/definitions/positive"
                },
                "of": {
                  "type": "string",
                  "minLength": 1
                },
                "basis": {
                  "enum": [
                    "1RM",
                    "3RM",
                    "TM"
                  ]
                }
              }
            }
          ]
        },
        "height": {
          "allOf": [
            {
              "$ref": "#/definitions/amount"
            },
            {
              "type": "object",
              "required": [
                "value",
                "unit"
              ]
            }
          ]
        },
        "who": {
          "enum": [
            "me",
            "partner",
            "together",
            "shared"
          ]
        },
        "tempo": {
          "type": "string"
        },
        "note": {
          "type": "string"
        }
      }
    },
    "rest": {
      "type": "object",
      "properties": {
        "id": {
          "$ref": "#/definitions/nodeId"
        },
        "seconds": {
          "$ref": "#/definitions/positive"
        },
        "ratio": {
          "$ref": "#/definitions/positive"
        },
        "note": {
          "type": "string"
        }
      },
      "not": {
        "required": [
          "seconds",
          "ratio"
        ]
      }
    },
    "group": {
      "type": "object",
      "required": [
        "id",
        "body"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/nodeId"
        },
        "label": {
          "type": "string"
        },
        "asStep": {
          "type": "boolean"
        },
        "body": {
          "$ref": "#/definitions/body"
        },
        "note": {
          "type": "string"
        }
      }
    },
    "repeat": {
      "type": "object",
      "required": [
        "id",
        "body"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/nodeId"
        },
        "times": {
          "type": [
            "integer",
            "null"
          ],
          "minimum": 1
        },
        "until": {
          "const": "athlete"
        },
        "then": {
          "enum": [
            "repeatLast",
            "stop"
          ]
        },
        "vary": {
          "type": "object"
        },
        "override": {
          "type": "array",
          "items": {
            "type": "object"
          }
        },
        "body": {
          "$ref": "#/definitions/body"
        },
        "note": {
          "type": "string"
        }
      }
    },
    "timed": {
      "type": "object",
      "required": [
        "id",
        "seconds",
        "early",
        "late",
        "body"
      ],
      "properties": {
        "id": {
          "$ref": "#/definitions/nodeId"
        },
        "seconds": {
          "$ref": "#/definitions/positive"
        },
        "early": {
          "enum": [
            "wait",
            "next"
          ]
        },
        "late": {
          "enum": [
            "cut",
            "end",
            "continue"
          ]
        },
        "stops": {
          "$ref": "#/definitions/nodeId"
        },
        "startAt": {
          "type": "number",
          "minimum": 0
        },
        "body": {
          "$ref": "#/definitions/body"
        },
        "note": {
          "type": "string"
        }
      }
    }
  },
  "allOf": [
    {
      "if": {
        "properties": {
          "format": {
            "const": "amrap"
          }
        },
        "required": [
          "format"
        ]
      },
      "then": {
        "required": [
          "timeCapSeconds"
        ]
      }
    }
  ]
}
$schema$::json
$fn$;

-- The same file, rooted at its customScale definition (for workout_custom_scales).
create function public.workout_custom_scale_schema() returns json
language sql immutable parallel safe set search_path = '' as $$
  select json_build_object(
    '$schema', public.workout_definition_v2_schema() -> '$schema',
    '$ref', '#/definitions/customScale',
    'definitions', public.workout_definition_v2_schema() -> 'definitions');
$$;

create table public.workout_library_v2 (
  id text primary key,                 -- = definition.id
  definition jsonb not null,           -- schemaVersion 2 definition, stored as written
  program text,
  scheduled_on date,
  published boolean not null default true,
  owner uuid references auth.users (id) on delete cascade,     -- personal workout
  gym_id text references public.gyms (id) on delete restrict,  -- gym programming
  revision integer not null default 1, -- set by the trigger, never by the writer
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workout_library_v2_id_matches check (definition ->> 'id' = id),
  constraint workout_library_v2_one_audience check (owner is null or gym_id is null),
  -- Personal ids end with .u<first 8 hex of the owner id> (ids are global; RFC 14.3 F6).
  constraint workout_library_v2_owner_suffix check (
    owner is null or right(id, 10) = '.u' || left(replace(owner::text, '-', ''), 8)),
  constraint workout_library_v2_schema_version check (definition -> 'schemaVersion' = '2'::jsonb),
  -- The largest real draft row is about 16.5 KB (4 scales); 64 KB leaves room, stops abuse.
  constraint workout_library_v2_size check (octet_length(definition::text) <= 65536),
  constraint workout_library_v2_schema check (
    extensions.jsonb_matches_schema(public.workout_definition_v2_schema(), definition))
);
create index workout_library_v2_scheduled_on_idx on public.workout_library_v2 (scheduled_on);
create index workout_library_v2_gym_idx on public.workout_library_v2 (gym_id);
create index workout_library_v2_owner_idx on public.workout_library_v2 (owner);

create table public.workout_library_v2_revisions (
  workout_id text not null references public.workout_library_v2 (id) on delete cascade,
  revision integer not null,
  definition jsonb not null,
  created_at timestamptz not null default now(),
  primary key (workout_id, revision)
);

-- What builds 15/16 may run: the old keys of a published v2 definition whose every scale is
-- `fidelity: "exact"` (a definition without `scales` uses its root `fidelity`); null otherwise.
-- Mirrored by legacy_copy() in tools/library/make_row.py.
create function public.workout_v2_legacy_definition(d jsonb) returns jsonb
language sql immutable parallel safe set search_path = '' as $$
  select case
    when (case
            when jsonb_typeof(d -> 'scales') = 'array'
              then jsonb_array_length(d -> 'scales') > 0
                   and not exists (select 1 from jsonb_array_elements(d -> 'scales') s
                                   where (s ->> 'fidelity') is distinct from 'exact')
            else (d ->> 'fidelity') is not distinct from 'exact'
          end)
    then (select jsonb_object_agg(e.key, e.value) from jsonb_each(d) e
          where e.key in ('id', 'name', 'shortName', 'format', 'team', 'healthKitActivity',
                          'segments', 'timeCapSeconds', 'intervalSeconds', 'roundSize'))
  end;
$$;

-- Before a write: revision, timestamps, and no v2 row over a legacy row that is not its copy.
-- Security definer so the check sees every legacy row, not only the writer's.
create function public.workout_v2_before_write() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    -- (An upsert of an existing v2 row also runs this branch: its own copy is not a conflict.)
    if exists (select 1 from public.workout_library l where l.id = new.id)
       and not exists (select 1 from public.workout_library_v2 v where v.id = new.id) then
      raise exception 'workout id % is already used by a legacy library row', new.id
        using errcode = 'unique_violation',
              hint = 'Legacy rows move to v2 with the migration of the published rows (build 17 item 5).';
    end if;
    new.revision := 1;
    new.created_at := now();
    new.updated_at := now();
  else
    if new.id <> old.id then
      raise exception 'the id of a v2 workout never changes (a different workout gets a new id)';
    end if;
    new.created_at := old.created_at;
    new.revision := old.revision + (case when new.definition is distinct from old.definition then 1 else 0 end);
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- After a write: keep the revision history and the legacy copy (the server function of RFC 7.2).
create function public.workout_v2_after_write() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  legacy jsonb;
begin
  if tg_op = 'DELETE' then
    delete from public.workout_library where id = old.id;
  else
    if tg_op = 'INSERT' or new.revision <> old.revision then
      insert into public.workout_library_v2_revisions (workout_id, revision, definition)
      values (new.id, new.revision, new.definition);
    end if;
    legacy := case when new.published then public.workout_v2_legacy_definition(new.definition) end;
    if legacy is null then
      delete from public.workout_library where id = new.id;
    else
      insert into public.workout_library (id, definition, program, scheduled_on, published, owner, gym_id)
      values (new.id, legacy, new.program, new.scheduled_on, true, new.owner, new.gym_id)
      on conflict (id) do update set
        definition = excluded.definition, program = excluded.program,
        scheduled_on = excluded.scheduled_on, published = true,
        owner = excluded.owner, gym_id = excluded.gym_id
      where (public.workout_library.definition, public.workout_library.program,
             public.workout_library.scheduled_on, public.workout_library.published,
             public.workout_library.owner, public.workout_library.gym_id)
        is distinct from (excluded.definition, excluded.program, excluded.scheduled_on, true,
                          excluded.owner, excluded.gym_id);
    end if;
  end if;
  return null;
end;
$$;

create trigger workout_library_v2_before before insert or update on public.workout_library_v2
  for each row execute function public.workout_v2_before_write();
create trigger workout_library_v2_after after insert or update or delete on public.workout_library_v2
  for each row execute function public.workout_v2_after_write();

-- One writer per row: a legacy row whose id belongs to a v2 row is written only by the trigger
-- above (recognised by pg_trigger_depth() > 1: it writes from inside the v2 trigger, which no
-- API caller can fake). (Deletes stay allowed: a deleted copy is rewritten by the next v2 write, and deleting a
-- user cascades through both tables.)
create function public.workout_library_guard_v2() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if pg_trigger_depth() <= 1
     and exists (select 1 from public.workout_library_v2 v where v.id = new.id) then
    raise exception 'workout % is a v2 workout: write it to workout_library_v2 (tools/library/make_row.py)', new.id
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;
create trigger workout_library_guard_v2 before insert or update on public.workout_library
  for each row execute function public.workout_library_guard_v2();

-- Helpers are not API endpoints either (Supabase grants execute on new functions by default).
revoke execute on function public.workout_definition_v2_schema(), public.workout_custom_scale_schema(),
  public.workout_v2_legacy_definition(jsonb) from public, anon;
-- (The schema checks run as the writing user, so signed-in users keep execute on them.)
grant execute on function public.workout_definition_v2_schema(), public.workout_custom_scale_schema(),
  public.workout_v2_legacy_definition(jsonb) to authenticated, service_role;

-- The trigger functions are not API endpoints.
revoke execute on function public.workout_v2_before_write(), public.workout_v2_after_write(),
  public.workout_library_guard_v2() from public, anon, authenticated;

-- RLS: who reads and writes v2 rows is the same as for workout_library (gyms migration).
alter table public.workout_library_v2 enable row level security;
alter table public.workout_library_v2_revisions enable row level security;

-- Revoke first: Supabase's default privileges may grant everything on new tables, which would
-- make the column grants below meaningless.
revoke all on public.workout_library_v2, public.workout_library_v2_revisions from anon, authenticated;
grant select on public.workout_library_v2, public.workout_library_v2_revisions to authenticated;
-- Users write only their personal rows, and never the columns the trigger owns (RFC 7.2.6).
grant insert (id, definition, program, scheduled_on, published, owner) on public.workout_library_v2 to authenticated;
grant update (definition, program, scheduled_on, published) on public.workout_library_v2 to authenticated;
grant delete on public.workout_library_v2 to authenticated;
grant select, insert, update, delete on public.workout_library_v2, public.workout_library_v2_revisions to service_role;

create policy "Users read their own, their gyms' and public v2 workouts" on public.workout_library_v2
  for select to authenticated
  using (
    owner = (select auth.uid())   -- a user's own rows, published or not (so they can change them)
    or (published and (
      (owner is null and gym_id is null)
      or gym_id in (select m.gym_id from public.gym_members m where m.user_id = (select auth.uid()))
    ))
  );
create policy "Users add their own v2 workouts" on public.workout_library_v2
  for insert to authenticated with check (owner = (select auth.uid()) and gym_id is null);
create policy "Users change their own v2 workouts" on public.workout_library_v2
  for update to authenticated
  using (owner = (select auth.uid()))
  with check (owner = (select auth.uid()) and gym_id is null);
create policy "Users delete their own v2 workouts" on public.workout_library_v2
  for delete to authenticated using (owner = (select auth.uid()));

-- A revision is readable exactly when its workout is (the subquery runs under the row's RLS).
create policy "Users read revisions of the workouts they can read" on public.workout_library_v2_revisions
  for select to authenticated
  using (exists (select 1 from public.workout_library_v2 w where w.id = workout_id));

-- Personal legacy rows: the id suffix rule too (RFC 14.3 F6), so a user can't take an id the owner
-- will need (a v2 id, a gym's, a moved draft's). Policies only change writes: reads, and so the
-- 29 published rows and builds 15/16, are unaffected (D5). The app never writes this table.
drop policy "Users add their own workouts" on public.workout_library;
create policy "Users add their own workouts" on public.workout_library
  for insert to authenticated with check (
    owner = (select auth.uid()) and gym_id is null
    and right(id, 10) = '.u' || left(replace((select auth.uid())::text, '-', ''), 8));
drop policy "Users change their own workouts" on public.workout_library;
create policy "Users change their own workouts" on public.workout_library
  for update to authenticated
  using (owner = (select auth.uid()))
  with check (
    owner = (select auth.uid()) and gym_id is null
    and right(id, 10) = '.u' || left(replace((select auth.uid())::text, '-', ''), 8));

-- Library paging (RFC 7.2.7): the API returns at most 1000 rows per request. Keyset on id:
-- call with after_id = the last id of the previous page until a page comes back short.
-- Security invoker: the caller's RLS applies.
create function public.workout_library_v2_page(after_id text default null, page_size integer default 500)
returns setof public.workout_library_v2
language sql stable security invoker set search_path = '' as $$
  select w.* from public.workout_library_v2 w
  where after_id is null or w.id > after_id
  order by w.id
  limit least(greatest(coalesce(page_size, 500), 1), 1000);
$$;
revoke execute on function public.workout_library_v2_page(text, integer) from public, anon;
grant execute on function public.workout_library_v2_page(text, integer) to authenticated, service_role;

-- Custom "Mine" scales (RFC 3.6): one per athlete and workout, never a library row.
create table public.workout_custom_scales (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  workout_id text not null,             -- a library id (v2 or legacy); no FK: the workout may go away
  scale jsonb not null,                 -- {"id": "custom", "label": "Mine", "basedOn": "l2", "structure": {...}}
  based_on_revision integer check (based_on_revision >= 1),  -- the v2 revision it was copied from
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, workout_id),
  constraint workout_custom_scales_size check (octet_length(scale::text) <= 32768),
  constraint workout_custom_scales_schema check (
    extensions.jsonb_matches_schema(public.workout_custom_scale_schema(), scale))
);
alter table public.workout_custom_scales enable row level security;
revoke all on public.workout_custom_scales from anon, authenticated;
grant select, insert, update, delete on public.workout_custom_scales to authenticated;
grant select, insert, update, delete on public.workout_custom_scales to service_role;
create policy "Users read their own scales" on public.workout_custom_scales
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Users add their own scales" on public.workout_custom_scales
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Users change their own scales" on public.workout_custom_scales
  for update to authenticated using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "Users delete their own scales" on public.workout_custom_scales
  for delete to authenticated using (user_id = (select auth.uid()));
create trigger workout_custom_scales_touch before update on public.workout_custom_scales
  for each row execute function public.touch_updated_at();
