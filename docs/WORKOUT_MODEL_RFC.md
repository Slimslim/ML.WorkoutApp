# RFC: one workout structure for every format

Status: **draft for the owner's review** (spike #55). Nothing here is built. Date: 14 Nov 2026.

Read this first: section 1 (problem), section 3 (the structure), section 12 (decisions for you).
The rest is detail for the team.

---

## 1. Problem

Today a workout is a flat list of parts plus four settings for the whole workout:
`format`, `intervalSeconds`, `roundSize` and `timeCapSeconds`. What a round, a window, a rest or a
score *is* is not stored anywhere. Each screen and each rule guesses it again: the watch clock, the
cap, the score, the summary, the card, the start tile. The architect counted about 45 such
format-specific branches in 14 files, and some of them disagree with each other.

What went wrong because of it:

| Evidence | What happened | Why |
|---|---|---|
| #31, build 15 test 2 | Tabata 20/10 was stored as "EMOM every 0:30, 2 parts per round". Work ran the full 30 s, the 10 s rest was never shown, the workout ended at 1:30 instead of 2:00. | There is no way to say "work 20 s, rest 10 s". A Crown turn in a clocked part jumps a round the clock never gives back (`WorkoutProgress.swift` ~139-145, 298-309, 360-366). |
| #31, 3-3-3-4 on 13 Nov | Work windows ended at 199 / 481 / 732 / 1041 s instead of 180 / 420 / 660 / 960 s (+19, +61, +72, +81 s). No beep at 3:00. Two catch-up Crown turns skipped a part. | Stored as "for time + 1:00 rests". Each rest started from the late Crown turn, so the delay grew every window (`WorkoutProgress.swift` 346-353). A work part never ends on the clock. |
| #52 | The capped score had no round, and the cap asked for pull-up reps while the athlete was on bench. | The round number needs `roundSize`, which this row did not have (`WorkoutResultCap.swift` 72-77), while the summary infers rounds another way (`WorkoutSummary.swift` 608). The movement asked was wrong because the watch was 81 s behind the gym. |
| Library (25 rows) | 3 Tabata rows and 2 "3-3-3-4" rows cannot be expressed at all. AMRAPs are typed out 12 times, so a fast athlete runs off the end. "Max", "shared", "synchro" exist only in names. | Repetition, windows and scoring are flattened into the parts list. |

The owner's worry is right: each fix so far has been a rule for one format. The next format
(ladders, death-by, every 3:00) would need another one.

## 2. Goals and non-goals

**Goals**
1. One small structure that describes every workout we have seen: the 25 library rows and about
   30 real formats from CrossFit and Hyrox gyms.
2. One timeline engine that runs any structure. No format names in the timing code.
3. The gym clock is the truth: every clocked boundary is fixed to the workout start. A Crown turn
   can never move it.
4. The same watch behaviour in every format: same states, same Crown rules, same 3-2-1.
5. The score is declared in the workout, not guessed from `format`.
6. Old app builds and old results keep working. The Hyrox race (5 Dec) is not put at risk.
7. The build-17 photo/text import produces this structure, checked by the same validator.

**Non-goals (for now)**
- Pause, resume after a crash, partner "who did what" on the watch, multi-part class days
  (strength + metcon + cash-out as one session), automatic rep counting. The structure leaves room
  for them; none is built here.
- Formulas, conditions or scripting inside a workout. Only lists and simple progressions.
- Changing what the Hyrox screens look like.

## 3. The structure

### 3.1 Five building blocks

A workout's `structure` is a small tree. Each node is one of five kinds:

| Block | What it is | Who ends it |
|---|---|---|
| `part` | One movement with a target: `21 cal`, `15 reps`, `1000 m`, or `max` (as many as you can). Optional load and partner split (`who`). | The athlete (Crown), unless a clock cuts it. |
| `rest` | A rest. With `seconds` it is on the clock; without, the athlete ends it ("rest as needed"). | Clock or athlete. |
| `group` | Several blocks in order (a round, a buy-in, a chipper). | When its last block ends. |
| `repeat` | Its body N times, or until a clock stops it. Targets can change per round (21-15-9, 3-6-9-..., Hyrox's 8 stations). Given rounds can be changed (the last window is 4:00). | After N rounds, or by a clock. |
| `timed` | A clock around its body: a window, an EMOM minute, Tabata's 20 s, an AMRAP, a time cap. Says what happens if you finish early and if time runs out. | The clock (or the athlete, see `early`). |

`timed` has two rules, and these two words replace most of today's format code:

- `early`: what happens when you finish the body before time is up.
  `wait` = automatic rest until the window ends (EMOM, Tabata, 3-3-3-4). `next` = go on now (a
  for-time cap).
- `late`: what happens when time is up and you are not done.
  `cut` = the running part is cut and its reps asked, the rest of the window is skipped, the
  workout goes on (EMOM, windows). `end` = the same, then the workout ends (AMRAP, death-by, hard
  cap). `continue` = announce "TIME CAP, keep going", note where you were, change nothing else
  (today's for-time cap).

So **AMRAP** = `timed{late: end}` around a `repeat` with no count. **EMOM** = `repeat` of
`timed{early: wait, late: cut}`. **For time with cap** = `timed{early: next, late: continue}`.
`format` survives only as a label for the card.

The score is declared once at the top: `time`, `roundsReps`, `totalReps`, `lowestReps`, `load`,
`distance`, `calories`, `perWindow` or `none`, which parts count, and what to do at a cap.

### 3.2 Where it lives

One optional key, `structure`, inside today's workout definition JSON, plus `schemaVersion: 2` at
the top. The old keys (`format`, `segments`, `intervalSeconds`, `roundSize`, `timeCapSeconds`) are
still written, **compiled from the structure**, so every screen, result and older app keeps reading
what it reads today. The structure is the source; the flat list is generated from it, never edited
by hand.

Limits (checked by the validator): nesting at most 3 `timed`/`repeat` levels; at most 400 compiled
steps; `max` and `who` only on `part`; the whole definition under 16 KB (the phone sends it to the
watch).

### 3.3 Schema sketch

```jsonc
{
  "schemaVersion": 2,
  "id": "lib.example.20261114.tabata", "name": "Tabata Squats", "team": "solo",
  "healthKitActivity": "highIntensityIntervalTraining",
  "format": "emom", "segments": [ /* compiled */ ], "intervalSeconds": 30,   // compiled, legacy
  "structure": {
    "score": { "type": "totalReps", "parts": ["sq"], "atCap": "repsAtCap" },
    "body": [ /* nodes */ ]
  }
}

// A node has exactly one of these keys:
{ "part":   { "id": "sq", "kind": "station", "movement": "airSquats", "name": "Air Squats",
              "target": { "value": 21, "unit": "reps" }  |  { "max": true, "unit": "reps" },
              "load": { "value": 50, "unit": "lb", "count": 2 },
              "who": "me" | "partner" | "together" | "shared" } }
{ "rest":   { "id": "r", "seconds": 60 } }                       // no seconds = as needed
{ "group":  { "id": "g", "label": "round", "body": [ ... ] } }
{ "repeat": { "id": "rp", "times": 8,                              // null = until a clock stops it
              "listRounds": 12,                                    // rounds written into the flat list
              "vary": { "<part id>": [21, 15, 9] | { "from": 3, "step": 3 } | [ {patch}, ... ] },
              "override": [ { "rounds": ["last"], "id": "<id>", "set": {patch} | "omit": true } ],
              "body": [ ... ] } }
{ "timed":  { "id": "w", "seconds": 180, "early": "wait" | "next",
              "late": "cut" | "end" | "continue", "body": [ ... ] } }
```

### 3.4 Examples

All examples are generic (no paid program is copied). Only `structure` is shown.

**Tabata 20/10 × 8** (#31). Work ends at 30k + 20 s, rest at 30(k+1) s, total 4:00.
```json
{"score":{"type":"totalReps","parts":["sq"]},"body":[
 {"repeat":{"times":8,"body":[
   {"timed":{"id":"work","seconds":20,"early":"wait","late":"cut","body":[
     {"part":{"id":"sq","movement":"airSquats","target":{"max":true,"unit":"reps"}}}]}},
   {"rest":{"id":"r","seconds":10}}]}}]}
```

**3-3-3-4, last window 4:00** (#31, owner's version). Boundaries 180, 240, 420, 480, 660, 720, 960 s,
all from the start.
```json
{"score":{"type":"perWindow","parts":["bench"],"atCap":"none"},"body":[
 {"repeat":{"times":4,"body":[
   {"timed":{"id":"w","seconds":180,"early":"wait","late":"cut","body":[
     {"part":{"id":"bike","movement":"bike","target":{"value":21,"unit":"calories"}}},
     {"part":{"id":"pu","movement":"strictPullUps","target":{"value":15,"unit":"reps"}}},
     {"part":{"id":"bench","movement":"dumbbellBenchPress","target":{"max":true,"unit":"reps"}}}]}},
   {"rest":{"id":"r","seconds":60}}],
  "override":[{"rounds":["last"],"id":"w","set":{"seconds":240}},
              {"rounds":["last"],"id":"r","omit":true}]}}]}
```

**3-3-3-4, 3:00 in every round** (the common variant): the same without `override`. Boundaries
180, 240, ..., 900, 960; the last rest is simply the end. The definition says which one, not the code.

**Ascending ladder** (12:00 AMRAP of 3-6-9-... thrusters + chest-to-bar):
```json
{"score":{"type":"roundsReps"},"body":[
 {"timed":{"seconds":720,"early":"next","late":"end","body":[
   {"repeat":{"times":null,"listRounds":12,
     "vary":{"thr":{"from":3,"step":3},"c2b":{"from":3,"step":3}},
     "body":[{"part":{"id":"thr","movement":"thrusters","target":{"value":3,"unit":"reps"}}},
             {"part":{"id":"c2b","movement":"chestToBar","target":{"value":3,"unit":"reps"}}}]}}]}}]}
```

**Descending ladder** (21-15-9 for time):
```json
{"score":{"type":"time"},"body":[
 {"repeat":{"times":3,"vary":{"thr":[21,15,9],"pu":[21,15,9]},
   "body":[{"part":{"id":"thr","movement":"thrusters","target":{"value":21,"unit":"reps"}}},
           {"part":{"id":"pu","movement":"pullUps","target":{"value":21,"unit":"reps"}}}]}}]}
```

**Alternating EMOM** (10:00; odd minutes A, even minutes B):
```json
{"score":{"type":"none"},"body":[
 {"repeat":{"times":5,"body":[
   {"timed":{"seconds":60,"early":"wait","late":"cut","body":[
     {"part":{"movement":"kettlebellSwings","target":{"value":15,"unit":"reps"}}}]}},
   {"timed":{"seconds":60,"early":"wait","late":"cut","body":[
     {"part":{"movement":"burpees","target":{"value":10,"unit":"reps"}}}]}}]}}]}
```

**Death by burpees** (minute n: n burpees; miss a minute and you are done):
```json
{"score":{"type":"roundsReps"},"body":[
 {"repeat":{"times":null,"listRounds":20,"vary":{"b":{"from":1,"step":1}},"body":[
   {"timed":{"seconds":60,"early":"wait","late":"end","body":[
     {"part":{"id":"b","movement":"burpees","target":{"value":1,"unit":"reps"}}}]}}]}}]}
```

**Partner, shared reps** (100 wall balls + 80 cal row split any way, then 800 m run together;
25:00 cap, keep going). `who` changes no timing; it labels the splits.
```json
{"score":{"type":"time","atCap":"repsAtCap"},"body":[
 {"timed":{"seconds":1500,"early":"next","late":"continue","body":[
   {"part":{"movement":"wallBalls","who":"shared","target":{"value":100,"unit":"reps"}}},
   {"part":{"movement":"row","who":"shared","target":{"value":80,"unit":"calories"}}},
   {"part":{"kind":"run","movement":"run","who":"together","target":{"value":800,"unit":"meters"}}}]}}]}
```

**Hyrox Solo** (8 × 1 km run + station). No `timed` node, so no clock. It compiles to exactly
today's 16 parts, and the engine behaves exactly as today.
```json
{"score":{"type":"time"},"body":[
 {"repeat":{"times":8,"body":[
   {"part":{"id":"run","kind":"run","movement":"run","target":{"value":1000,"unit":"meters"}}},
   {"part":{"id":"st","kind":"station","movement":"skiErg"}}],
  "vary":{"st":[
   {"movement":"skiErg","target":{"value":1000,"unit":"meters"}},
   {"movement":"sledPush","target":{"value":50,"unit":"meters"}},
   {"movement":"sledPull","target":{"value":50,"unit":"meters"}},
   {"movement":"burpeeBroadJumps","target":{"value":80,"unit":"meters"}},
   {"movement":"row","target":{"value":1000,"unit":"meters"}},
   {"movement":"farmersCarry","target":{"value":200,"unit":"meters"}},
   {"movement":"sandbagLunges","target":{"value":100,"unit":"meters"}},
   {"movement":"wallBalls","target":{"value":100,"unit":"reps"}}]}}}]}
```
(Roxzone later = a `part` of kind `transition` between run and station; no engine change.)

**For time with cap and partial score** (3 rounds: 400 m run, 21 KB swings, 12 pull-ups; 16:00
cap, keep going as today):
```json
{"score":{"type":"time","atCap":"repsAtCap"},"body":[
 {"timed":{"seconds":960,"early":"next","late":"continue","body":[
   {"repeat":{"times":3,"body":[
     {"part":{"kind":"run","movement":"run","target":{"value":400,"unit":"meters"}}},
     {"part":{"movement":"kettlebellSwings","target":{"value":21,"unit":"reps"}}},
     {"part":{"movement":"pullUps","target":{"value":12,"unit":"reps"}}}]}}]}}]}
```
A hard cap ("CAP + reps") is the same with `"late": "end"`.

## 4. The timeline engine

### 4.1 Shape

One engine, written in Python first (`tools/barpath`), then ported to Swift (BarPathKit), with
shared test files proving they agree:

- `plan(definition)`: the list of steps (each knows its round and window) and every clock
  boundary with its planned time. Pure, no clock.
- `reduce(state, event)`: the state machine. Events: `start`, `tick`, `crown`, `undo`, `reps`,
  `end`. Time is an argument; nothing inside reads the watch clock.
- `replay(plan, events)`: rebuilds the state from the saved events (crash recovery, tests).

The watch only feeds events in and plays the effects (haptics, screen). `WorkoutSessionModel`
stops making timing decisions.

### 4.2 Rules

1. **Who ends a step is declared.** A step is ended by the athlete (a `part`, a `rest` without
   seconds) or by the clock (a clocked `rest`, the automatic rest after an early finish, any step
   cut by a `timed`).
2. **Clock anchoring.** Every boundary is "anchor + offset". The anchor is the workout start, or
   the moment an athlete-ended step really ended. **Never a Crown turn inside a clocked window.**
   - 3-3-3-4 and Tabata: every boundary is anchored to the start, so the watch matches the gym
     clock exactly (180 / 420 / 660 / 960 s), whatever the Crown does.
   - "5 × 250 m row, rest 1:00": each rest starts when you finish the row, which is what that
     workout means.
   - The same rule gives both behaviours; no format check.
3. **Late ticks catch up.** If the watch wakes up late (wrist down), every boundary that passed is
   applied at its planned time, not at the tick. The result is the same whether the watch ticks
   every 200 ms or wakes 40 s late.
4. **Earliest boundary wins.** With nested clocks (a cap around windows), the first due boundary
   applies; an outer `cut`/`end` closes every inner window.
5. **Caps.** `late: end` finishes the workout at the boundary. `late: continue` announces the cap,
   stores where you were (round, part), and changes nothing else.
6. **Partials.** When a clock cuts a part with a countable target (reps, calories) or a `max` part,
   the step is marked `cut` and its reps are asked (section 6.4). Parts left in that window are
   marked `skipped` (0 s), as today. Reps are stored per step, not once per workout.
7. **Crown.**
   - In a step the athlete ends: done, go to the next step. If that closes a window with
     `early: wait`, the automatic rest starts and still ends at the planned boundary.
   - In a step the clock ends (clocked rest, automatic rest): **ignored**, with a short hint. The
     Crown never moves a clock forward.
   - A Crown turn within 3 s after a boundary counts for the step that was running before it
     (you finished at 2:59, turned at 3:01). It never advances the new step.
   - Inside a window, the lockout after a "done" is 4 s (two turns 4 s apart skipped pull-ups on
     13 Nov). Outside windows it stays 2 s (Hyrox needs quick switching).
   - Undo goes back only inside the current window. A clock boundary that has passed can't be
     undone; fixes after a bell go through the reps prompt or the phone.
8. **Unbounded repeats.** AMRAP rounds are written into the flat list up to `listRounds`; the
   engine adds more rounds at the end if the athlete keeps going, so nobody runs out of list.
   Rounds are only ever added at the end, so step numbers in results never change.
9. **Pause** is not in build 16 or 17. The engine keeps a slot for it.

### 4.3 What it replaces

`autoAdvanceTime`, `autoAdvanceTargetIndex`, `capTime`, `forTimeCapTime`, `isFinishedByCap`, the
suppress flags, `effectiveRoundSize`, `roundSize` arithmetic, `CardShape.detect`, `capPositionText`
and `EmomSet.all` (which also has a likely bug: one set per station, so a 2-movement EMOM would
show 12 sets). The full list of 61 branches with file and line is in the architect's appendix
(Appendix B).

## 5. Scoring

Principle: **record facts per step, derive the score.** The result never needs the definition
re-guessed to say where you were.

Per step the result records: round, window, start, end, ended by (athlete / clock / cap / end),
target, reps done (for cut and `max` steps), and later load and scaled.

| Format | Score shown | Recorded |
|---|---|---|
| For time | `12:34` | splits; if capped: `CAP · R3 Pull-ups 12/15` and time past the cap |
| Rounds / ladder | `12:34` or `Rung 7 (21) + 9` | splits per round |
| AMRAP | `7 + 23` | rounds, part and reps of the unfinished round |
| EMOM / every X | `8/8` or load | per window: done or partial, rest left |
| Windows (3-3-3-4) | `Bench 31` (sum of the `max` part) | per window: parts done, partial (12/15), max reps |
| Tabata | `96 · low 10` | 8 numbers |
| Hyrox | `1:12:34` | every run, station (and Roxzone later), unchanged |

The capped score of #52 becomes "R4 · Strict Pull-ups 12/15" from the plan, with no `roundSize`.

## 6. Watch and phone

Proposed by the designer; **anything that changes the approved screens needs a mockup the owner
approves before it is built** (Design rule in `CLAUDE.md`).

### 6.1 Watch states (the same in every format)

| State | Big number (the one signal) | Crown forward | Haptic on entry |
|---|---|---|---|
| Get ready (clocked workouts only, new) | seconds to GO | nothing (tap = go now) | 3-2-1, GO |
| Work you end (Hyrox, for time) | part time, counting up, yellow (today) | done, next part | today's |
| Work the clock ends (window, Tabata, EMOM, AMRAP) | time **left** to the clock that ends it, white, `LEFT` | done, next part in this window; window end does not move | GO if by clock |
| Rest (clocked, or early finish) | time left to GO | nothing (hint "Clock starts the next part") | STOP if by clock |
| Switch flash (1.8 s, today's) | `GO` / `REST` / `TIME` + part | ignored for 3 s | as above |
| Done | score | drives the reps prompt if open | TIME / success |

The big number is always the clock that will end what you are doing. A for-time cap you can run
past never takes it; it stays in the top line.

### 6.2 3-2-1 and haptics

- 3-2-1 before every clock boundary that changes what you do: end of a window, end of a rest, end
  of get ready, an AMRAP's end.
- The haptic at 0 says what you go into: **GO** (`.start`) into work, **STOP** (`.stop`, new) into
  rest, **TIME** (today's) at the end.
- Optional single buzz at 10 s left, only for windows of 1:00 or more.
- Silent: anything only you can end (Hyrox, for-time parts), a for-time cap (today's rule), and a
  boundary that changes nothing (you finished bench early and are already resting).

### 6.3 Wireframes (41 mm)

```
Tabata work            Tabata rest            3-3-3-4, bench window
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ SQUATS · MAX R3/8│   │ REST        R3/8 │   │ DB BENCH·MAX W3/4│
│       0:14       │   │       0:07       │   │       0:41       │
│       LEFT       │   │       LEFT       │   │   LEFT TO 3:00   │
│ ♥ 168            │   │ NEXT SQUATS·MAX  │   │ ✓Bike ✓Pull ●Ben │
│ Rest 0:10 next   │   │ ♥ 171            │   │ ♥ 162 9:19 total │
└──────────────────┘   └──────────────────┘   └──────────────────┘

Ladder in an AMRAP     Hyrox run (unchanged)  Reps at the bell (in the rest)
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ THRUSTERS 6   R3 │   │ RUN 4/8    38:12 │   │ REST 0:52  W3→W4 │
│       7:22       │   │       3:41       │   │ PULL-UPS 15  ▸   │
│       LEFT       │   │ 4:52/KM   ♥ 158  │   │        12        │
│ ♥ 165            │   │ ● ● ● ◐ ○ ○ ○ ○  │   │   at the bell    │
│ Next: Pull-ups 6 │   │ Next: Row 1000 m │   │ saves at GO  [✓] │
└──────────────────┘   └──────────────────┘   └──────────────────┘
```

### 6.4 Reps when the clock cuts a part

- Asked only for a cut part with reps/calories or a `max` part. Never for runs, metres, time or
  rests.
- The movement asked is the one the plan had at the bell. Its name is a button: tap to step to the
  next part of that window (if the athlete was further than the watch thought).
- Where: in the next rest if it is 20 s or longer (the Crown is free there); otherwise on the done
  screen (at most 3 questions); otherwise on the phone (Tabata: 8 empty cells).
- It saves itself at the next GO. Untouched = "not entered", never 0. **It never blocks the clock.**

### 6.5 Phone

- **Card**: one structure line made from the plan (`8 × 20 s on / 10 s off`;
  `4 windows: 3:00 work · 1:00 rest, last 4:00`), "until 3:00" on parts the clock ends, and a
  thin to-scale bar of the workout (new).
- **Results**: one table, windows or rounds as rows and parts as columns. A cut part shows `12/15`
  with a clock mark; empty cells can be tapped to fill in. EMOM and Hyrox views stay as they are.
- **Live view from 2 m**: needs watch mirroring, which does not exist yet. Not in this work.

### 6.6 What the athlete must never have to do

Turn the Crown to start or end a rest or a window; turn it to catch up; turn it twice; answer a
question before the next part can start; enter 0 for "I don't know"; enter reps for a movement the
watch guessed wrong with no way to change it; scroll mid-set; feel a countdown before something only
they can end.

## 7. Backend (Supabase)

### 7.1 Today

`workout_library` has `id`, `definition` (jsonb), `program`, `scheduled_on`, `published`, `owner`,
`gym_id`, timestamps, and a check that `definition->>'id' = id`. 25 rows (18 gym, 7 personal).
Nothing checks the content except `make_row.py`, and the app can write personal rows directly.
Upserts overwrite in place; there is no version history. Results are JSON files in Storage that
embed the full definition they ran.

### 7.2 Proposal, in two steps

**Build 16: no schema change.** `structure` and `schemaVersion` go inside `definition`. Build 15
ignores them and runs the compiled old keys, exactly as it does today (no worse). `make_row.py`
accepts `structure`, validates it, and writes the compiled old keys next to it. The 5 rows that
can't be expressed today (3 Tabata, 2 "3-3-3-4") are re-written by hand and checked by the owner.

**Build 17 (with the import):**
- New column `definition_v2` (the same document shape) becomes the source of truth.
  `definition` keeps the old contract and is filled only when an old build would run the workout
  the same way; otherwise it is NULL, and old builds skip the row cleanly (decision D5).
- `revision` (bumped by a trigger) and a `workout_library_revisions` history table, so a result
  can name exactly which version it ran, and a bad edit can be rolled back.
- **One JSON Schema file** in the repo (`schemas/workout-definition.v2.schema.json`) used by
  `make_row.py`, the Python and Swift decoders' tests, and the database (a trigger using the
  `pg_jsonschema` extension), plus a few rules JSON Schema can't express (ids unique, compiled
  steps under 400), written in Python, Swift and SQL against shared test cases. An RPC
  `validate_workout_definition(jsonb)` is used by `make_row.py` and the import function.
- RLS stays public / gym / personal. Personal writes now pass validation; users can't write the
  columns the trigger owns. Imports are written with the user's token, so they can only be personal.
- Rule for `schemaVersion`: any new field whose omission would change the timeline or the score
  bumps it, so an older app refuses the workout ("Update the app") instead of running it wrong.

### 7.3 Migrating the 25 rows

A pure `upgrade(old definition)` function (Python, then Swift) labels each row:
**exact** (compiling the upgrade gives back the same parts and timing; about 17 rows),
**review** (a guess was made: the 3 AMRAP ladders with listed rounds), or **re-encode** (the 3 Tabata
and 2 "3-3-3-4" rows). The backfill is a dry run first, then one idempotent update per row that skips
rows edited since export, inside a transaction. `definition` is never touched by the backfill;
undoing it is setting `definition_v2` back to NULL. The new app also upgrades old rows on the device,
so it runs every row before the backfill is done.

### 7.4 Results

Result version 3 adds optional fields only: per-step `reps`, `cut`, `endedBy`, `round`; the
definition it ran (with `structure`); `definitionRef {id, revision, schemaVersion}` from build 17.
The old `partialReps` / `repsAtCap` are still written, so build-15 phones reading corrections from
the cloud still decode. Old results (version 1 and 2) are read as today; when a view needs a
structure, the same `upgrade` gives it one. Re-scoring an old result against a corrected workout is
an explicit athlete action.

### 7.5 Build-17 import

The server function returns exactly a v2 definition, checked against the same schema and then the
database RPC. The import log keeps the returned definition, the validation errors, the saved row id
and what the athlete finally saved. The confirm screen shows the structure line and the score type,
because the parser will sometimes get "total reps" vs "lowest reps" wrong.

## 8. Watch, phone and old app versions

- **Phone → watch.** The definition already travels in the `selectWorkout` application context and
  as a message. It just grows (a structured Tabata is 1-3 KB; the biggest row today is about 6 KB);
  budget 16 KB, checked by a test. No key is reused or removed: `type`/`selectWorkout`,
  `liftSelection` and `weightUnit` stay as they are.
- **Fix first (shared file, own commit):** `sendWorkout` in `iOS/PhoneLink.swift` (~164-173) rebuilds
  the context from scratch and keeps only `liftSelection` and `weightUnit`. Any future key would be
  wiped on every send. It must copy the existing context and change only its own keys.
- **Old builds.** Swift ignores unknown keys but **fails on an unknown enum value** (new `format`,
  segment kind, unit, event kind). So: add keys only; never add a case to an existing enum; new
  result data goes in optional fields. An old watch that can't decode a definition today drops it
  silently while the phone shows "sent"; a stored workout that fails to decode falls back to Partner
  WOD 1 (`Watch/WorkoutSessionModel.swift` 244-256). Build 16 adds a `watchCaps` reply key
  (schema version, build), so the phone can say "Update the watch app" instead.
- **Crash recovery.** Today a crash ends the workout and saves it (W24). The engine only needs the
  definition, the start time (wall clock) and the athlete's events in the checkpoint; the state is a
  replay of those. "Resume the running workout" becomes possible later with no new data.
- **Timing.** The watch clock is already accurate to about 0.2 s; the drift was a model bug, not a
  timer bug. Boundaries are `start + planned offset`. The loop wakes at the next planned event (at
  most every second), a guard stops any effect firing twice, haptics stay at least 0.6 s apart. The
  3-2-1 with the wrist down must be checked on a device.
- **Battery.** Planning costs nothing; the cost is waking up and redrawing. No 10 Hz; redraw only when
  the window changes.

## 9. Recording and analysis

- Keep today's `name=segment` CSV lines and the result's `segments` and `events`.
- Add one `name=plan` line at start (schema version, plan hash, planned boundaries) and one
  `name=step` line per step change with the step index, ended by, partial reps and a sequence
  number. Old parsers ignore unknown names.
- Fixes found by QA: today `clockAdvance` writes one line even when it skips several parts, so the
  Python replay falls one part behind; event lines are not in time order (#50); the CSV uses time
  since boot while the result uses wall time, and nothing checks they agree. The loader sorts by
  time and sequence number; the replay uses the step index.
- `tools/barpath` gets a "plan vs actual" report with a drift alarm.

## 10. Test plan

Every algorithm test is data: Python writes the expected output, Swift reads the same file, and CI
fails if regenerating changes a file.

1. **Schema**: valid and invalid definitions, the same cases in Python, Swift and the database.
2. **Planner**: definition → planned steps and boundaries (start, end, ended by).
3. **State machine**: scripted event streams → steps and score. Late, double and missing Crown;
   Crown in a rest; Crown 1 s before a boundary; a tick 45 s late; crash and replay; cap mid-part;
   undo after a clock boundary. Plus random event streams with fixed seeds: splits never overlap,
   start-anchored boundaries are always on time, replay equals live.
4. **Migration**: every built-in, seed row and a dump of the library upgraded, validated, and its
   plan equal to today's behaviour where today was right. Each intended change listed by name.
5. **Scoring**: per fixture.
6. **Old results**: build-15 results frozen as files, must decode and render unchanged.

Fixture folder (inside the Swift package, which can't read files from `tools/`):
`BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/workouts/<case>/` with `definition.json`,
`expected_plan.json`, `events/<scenario>.json`, `expected/<scenario>.result.json`, and an
`INDEX.json` with the case count, so a missing case fails instead of skipping (today a missing
fixture silently skips).

| Case | Must show |
|---|---|
| Tabata 20/10 × 8 | 16 steps on the clock, no Crown needed, total 4:00; a Crown in a rest is ignored |
| 3-3-3-4, last 4:00 | the 13 Nov Crown times replayed: work ends 180/420/660/960, no drift, round-3 pull-ups kept as 12/15, cap question names bench, bench 12/7/0/12 |
| 3-3-3-4, 3:00 every round | adds the 900 s boundary |
| Ascending ladder | rounds past `listRounds` are added; score rung + reps |
| Descending ladder | 21-15-9 splits as today |
| Alternating EMOM | odd/even windows; one failed window cut with reps |
| Death by | ends at the failed minute; score "minute 11 + 6" |
| For time, cap, partial | cap announced, position stored, keeps going |
| Hyrox 8 × 1 km | identical to build 15, step by step |

Only some Crown times of 13 Nov are in the issues; the rest are taken from the build-15 recording's
event lines (no motion data in the repo) and marked synthetic until then.

## 11. Delivery

### Before anything: owner approves this RFC (decision D1). The schema and the Python engine can then start at once.

### Build 16: W27 becomes "timeline engine for clocked workouts"

1. Python: structure, validator, `plan`, `reduce`, `upgrade`, fixture suite (section 10).
2. Swift port in BarPathKit + parity tests. `WorkoutDefinition` gains an optional `structure`.
3. Watch routing: the engine runs **only for workouts with a clocked boundary inside**: Tabata,
   3-3-3-4, EMOMs, timed parts. Hyrox, for time, AMRAP, partner WODs and Free stay on build 15's
   code, unchanged, until after the race. A setting on the watch turns the engine off (back to
   build 15 behaviour) if it misbehaves.
4. Watch screens for those workouts: time left as the big number, 3-2-1, GO/STOP, Crown rules,
   reps at the bell (mockups approved first).
5. `make_row.py` accepts `structure`; the 5 rows re-written; #52's round number from the plan.
6. CSV `plan`/`step` lines; result v3 optional fields; the PhoneLink context fix (own commit).
7. Race guard: a test that runs the three Hyrox definitions through both paths and asserts identical
   parts and routing (legacy).

**Gate: freeze workout code on Fri 27 Nov.** If W27 is not device-tested by then, build 16 ships
without it (engine switched off) and the race runs on build 15's Hyrox path. Before racing, the owner
runs one full Hyrox simulation on the exact race build.

This pushes build 16 by about a week against the proposed 20 Nov invites. Alternative (decision D4):
ship build 16 now with W28 and W23 only, and put the engine in build 17.

### Build 17 (after the race)

- Every workout through the engine, after replaying all stored results gives the same splits; then
  delete the old clock code.
- Supabase step 2 (section 7.2): `definition_v2`, revisions, server validation, backfill.
- Photo/text import produces `structure` (why the schema must be settled now).
- Score types, cards and summaries from the plan; per-window results table; partner `who` labels.

### Later

Pause, resume after a crash, multi-part class days, Roxzone parts, live view on the phone.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Hyrox regression before the race | Hyrox stays on build 15's code path; golden routing test; freeze 27 Nov; full simulation on the race build |
| Two engines during build 16 | One adapter is the only interface; old code deleted in build 17 |
| The Crown behaves differently in clocked workouts | Owner decision D2; clear hint and haptic; tuned on a device |
| Structure grows too general | 5 blocks, lists and progressions only; nesting ≤ 3; strict validator |
| Build 15 runs re-written rows the old (wrong) way | No worse than today; hidden from old builds in build 17 (D5) |
| Late haptics with the wrist down | Data is right anyway (catch-up rule); device test of 3-2-1 wrist down |
| Reps entry on the watch without scrolling | Prompt in rests ≥ 20 s, else done screen, else phone |
| Summary/scoring code has no Python reference | Written in Python first in build 17, with parity tests |
| Build 16 slips | Gate and fallback above (D4) |

## 13. Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Adopt this structure (5 blocks + declared score) as the one format for the library, the import and results. | **Yes.** |
| D2 | Crown in clocked workouts: forward = "I finished this part"; ignored in a clocked rest; never moves a clock; undo only inside the current window; 3 s grace after a bell; 4 s lockout inside windows. | **Yes.** (Closes the open question in #31.) |
| D3 | Reps when the clock cuts a part: asked in the next rest if ≥ 20 s, else on the done screen (max 3), else on the phone; untouched = empty, never 0; never blocks the clock. | **Yes.** |
| D4 | Build 16: W27 = engine for clocked workouts only, freeze 27 Nov, ship without it if not device-tested; or ship build 16 now without W27. | **Engine in build 16 with the 27 Nov gate**, Hyrox untouched either way. |
| D5 | Old builds and rows they would run wrong (3 Tabata, 2 "3-3-3-4"): keep showing them (wrong, as today) or hide them from builds ≤ 16 once build 17 is out. | **Show in build 16 (no worse than today), hide from old builds from build 17.** |
| D6 | Default scores: Tabata = total (lowest shown); windows = sum of the `max` part; capped for time = position + reps at the cap, keep going (today). Each workout can override. | **Yes.** |
| D7 | New watch signals: STOP haptic into rest, white `LEFT` countdown vs yellow count-up, 10 s get-ready for clocked workouts, 10 s heads-up buzz for windows ≥ 1:00. | **Yes, as mockups in the W27 PR**, tuned in the gym. |
| D8 | Build 17 backend: separate `definition_v2` column, revision history, server validation (enable `pg_jsonschema` on the project). | **Yes.** |

---

## Appendix A: the team review

Six independent reviewers each got the code, the docs, the library and the issues, not each other's
conclusions: a software architect, a CrossFit/Hyrox coach, a product designer, a backend engineer, a
watch/iOS engineer and a QA/data engineer. Three earlier read-only reviews (architect, coach,
designer) from the Scrum Master were used as extra input. Each reviewer then critiqued this draft.

### Main objections and how they were resolved

_(filled in after the critique round)_

## Appendix B: today's special cases

The architect's full list (61 branches with file and line) is summarised here by where each goes:

| Today | In the new design |
|---|---|
| `autoAdvanceTime`, `autoAdvanceTargetIndex`, `autoAdvance` | plan boundaries + catch-up on tick |
| `capTime`, `forTimeCapTime`, `isFinishedByCap` | `timed.late` = end / continue |
| `capSegmentIndex`, `repsAtCapSegment`, `partialRepsSegment` | the step marked `cut`, or the step at the `continue` boundary |
| `autoSuppressedStart`, `capSuppressed`, Crown lockout after auto | undo never crosses a boundary; Crown ignored in clocked steps |
| `roundSize` arithmetic, `effectiveRoundSize`, `repeatPeriod`, `CardShape.detect` | `step.round` from the plan |
| `slotStart = k * interval` | the plan's real window start |
| `format` switches in summary, card, start tile | `score.type` and a label derived from the tree |
| one `partialReps` / `repsAtCap` per workout | `reps` per step (old fields still written) |

## Appendix C: formats covered

About 90 % of what athletes do in these gyms is 8 formats, and together they cover all 25 library rows:
for time (with or without cap), rounds for time (with ladders and pyramids), AMRAP, EMOM / every X:00,
strength sets for load, timed intervals (Tabata, work/rest, windows like 3-3-3-4), distance or calorie
intervals with rest, and a partner split on any of these. The coach's catalogue of 31 formats
(including death-by, buy-in/cash-out, fight-gone-bad style, team relay, Hyrox doubles and relay,
compromised running) maps onto the same five blocks; the ones not built soon are pause-dependent
or multi-part days.
