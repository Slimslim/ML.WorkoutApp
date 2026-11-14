# RFC: one workout structure for every format

Status: **for the owner's review** (spike #55). Nothing here is built. Date: 14 Nov 2026.

For the owner: read section 1 (problem), section 3.1 (the five blocks), section 11 (what ships when)
and section 13 (your decisions). The rest is detail for the team.

**Words used here.** A *part* is one movement with a target. A *window* is a stretch of time the
clock owns (an EMOM minute, Tabata's 20 s, a 3:00 window, an AMRAP). The *bell* is the moment the
clock ends something. A *step* is one part or rest as the engine runs it (a workout of 8 rounds of
2 parts has 16 steps). `timed`, `repeat` etc. are the names in the JSON.

---

## 1. Problem

Today a workout is a flat list of parts plus four settings for the whole workout:
`format`, `intervalSeconds`, `roundSize` and `timeCapSeconds`. What a round, a window, a rest or a
score *is* is not stored anywhere. Each screen and each rule guesses it again: the watch clock, the
cap, the score, the summary, the card, the start tile. The architect counted about 45 such
format-specific branches in 14 files (61 places in all, Appendix B), and some disagree with each other.

What went wrong because of it:

| Evidence | What happened | Why |
|---|---|---|
| #31, build 15 test 2 | Tabata 20/10 was stored as "EMOM every 0:30, 2 parts per round". Work ran the full 30 s, the 10 s rest was never shown, the workout ended at 1:30 instead of 2:00. | There is no way to say "work 20 s, rest 10 s". The auto-advance target skips the rest, and a Crown turn in a clocked part uses up a round the clock never gives back (`WorkoutProgress.swift` 122-145). |
| #31, 3-3-3-4 on 13 Nov | Work windows ended at 199 / 481 / 732 / 1041 s instead of 180 / 420 / 660 / 960 s (+19, +61, +72, +81 s). No beep at 3:00. Two catch-up Crown turns skipped a part. | Stored as "for time + 1:00 rests". A work part never ends on the clock, and each rest's deadline is counted from when it started, which was the late Crown turn (`WorkoutProgress.swift` 122-135), so the delay grew every window. |
| #52 | The capped score had no round, and the cap asked for pull-up reps while the athlete was on bench. | The round number needs `roundSize`, which this row did not have (`WorkoutResultCap.swift` 72-77), while the summary infers rounds another way (`WorkoutSummary.swift` 608). The movement was wrong because the watch was 81 s behind the gym. |
| Library (25 rows) | 3 Tabata rows and 2 "3-3-3-4" rows can't be expressed at all. AMRAPs are typed out 12 times, so a fast athlete runs off the end. "Max", "shared", "synchro" exist only in names. Strength sets and ski intervals are scored as total time. | Repetition, windows and scoring are flattened into the parts list. |

The owner's worry is right: each fix so far has been a rule for one format. The next format
(ladders, death-by, every 3:00) would need another one.

## 2. Goals and non-goals

**Goals**
1. One small structure that describes every workout we have seen: the 25 library rows and about
   30 real formats from CrossFit and Hyrox gyms.
2. One timeline engine that runs any structure. No format names in the timing code.
3. The gym clock is the truth: **no clock boundary is ever counted from a Crown turn inside a
   clocked window.** Windows are fixed to the workout start.
4. The same watch behaviour in every format: same states, same Crown rules, same 3-2-1.
5. The score is declared in the workout, not guessed from `format`.
6. Old app builds and old results keep working. The Hyrox race (5 Dec) is not put at risk.
7. The build-17 photo/text import produces this structure, checked by the same validator.

**Non-goals (for now)**
- Pause, resume after a crash, partner "who did what" on the watch, multi-part class days
  (strength + metcon + cash-out as one session), automatic rep counting, live view on the phone.
  The structure leaves room for them; none is built here.
- Formulas, conditions or scripting inside a workout. Only lists and simple progressions.
- Changing the Hyrox screens.

## 3. The structure

### 3.1 Five building blocks

A workout's `structure` is a small tree. Each node is one of five kinds:

| Block | What it is | Who ends it |
|---|---|---|
| `part` | One movement with a target: `21 cal`, `15 reps`, `1000 m`, or `max` (as many as you can). Optional load and partner split (`who`). | The athlete (Crown). A clock can end it too. |
| `rest` | A rest: `seconds` (on the clock), `ratio` (1:1 = as long as the round or group it follows took), or nothing ("as needed", the athlete ends it). | Clock or athlete. |
| `group` | Several blocks in order (a round, a buy-in, a chipper). | When its last block ends. |
| `repeat` | Its body N times, or until a clock stops it. Targets can change per round (21-15-9, 3-6-9-..., Hyrox's 8 stations). Given rounds can be changed (the last window is 4:00). | After N rounds, or by a clock. |
| `timed` | A clock around its body: a window, an EMOM minute, Tabata's 20 s, an AMRAP, a time cap. Says what happens if you finish early and if time runs out. | The clock (or the athlete, see `early`). |

`timed` has two rules, and these two words replace most of today's format code:

- `early`: what happens when you finish the body before time is up.
  `wait` = an automatic rest until the window ends (EMOM, Tabata, 3-3-3-4). `next` = go on now (a
  for-time cap, an AMRAP).
- `late`: what happens when time is up and you are not done.
  - `cut`: the part you are on is cut at the bell and its reps asked; the rest of the window is
    skipped; the workout goes on (EMOM, windows, Tabata).
  - `end`: the same, and it also stops the `repeat` directly around it if that repeat has no
    count (death-by: miss a minute and you are out). What comes after still runs (a cash-out after an
    AMRAP); with nothing after, the workout is done.
  - `continue`: announce "TIME CAP, keep going", note where you were, change nothing else (today's
    for-time cap).

So **AMRAP** = `timed{late: end}` around a `repeat` with no count. **EMOM** = `repeat` of
`timed{early: wait, late: cut}`. **For time with cap** = `timed{early: next, late: continue}`.
`format` survives only as a label for the card.

**`max` parts.** A `max` part has no "done": the bell ends it, and that is its planned ending, not a
cut (bench "max until 3:00" is complete at 3:00). Its count is asked and is usually the score. A
Crown turn on a `max` part means "I stopped": the automatic rest starts and its count is asked. A
`max` part outside any clock (partner: "one runs 200 m, the other does max reps") is ended by the
Crown.

**Parts with a time target** (side plank 1:00, a 45 s recovery run inside an EMOM minute) are
ended by the clock without a `timed` around them: target unit `seconds`. This keeps nesting
shallow.

**Open-ended work the athlete closes** ("build to a heavy 3", "5-3-then max"): a `repeat` with no
count and `"until": "athlete"`. The athlete ends the block with "done with this block" (page 2), and
the score is usually the best load.

**Scheduled interruptions** (owner, 14 Nov; build 17 or later): "2 km row; every 4:00 from 0:00,
15 air squats". `interrupt` on a part, group or `timed` rings a start-anchored bell every `every`
seconds (3-2-1-GO). The main work pauses where it was, the athlete does the interrupt body and ends
it with the Crown, then the main work resumes. The score is the final time; the result records how
many interruptions were done and their reps.

The **score** is declared once at the top (section 5).

### 3.2 Where it lives

One optional key, `structure`, inside today's workout definition JSON, plus `schemaVersion: 2` at
the top. The old keys (`format`, `segments`, `intervalSeconds`, `roundSize`, `timeCapSeconds`) are
still written, **compiled from the structure**, so every screen, result and older app keeps reading
what it reads today. The structure is the source; the flat list is generated from it, never edited
by hand. `make_row.py` (and later the database) refuses a row whose old keys don't match what the
structure compiles to.

**Validator rules** (one JSON Schema file, plus a few checks it can't express, section 7):
- nesting at most 3 `timed`/`repeat` levels; at most 400 compiled steps; whole definition under 16 KB
  (checked when the phone sends too, because imports can be any size);
- `max` and `who` only on `part`; part ids unique;
- a `repeat` with no count must either sit inside (or contain) a `timed` with `late: end`, or say
  `"until": "athlete"`; it must be the last thing in its window and can't use `override "last"` (so
  rounds are only ever added at the end);
- an outer `repeat`'s `vary` may name a part inside an inner `repeat`; the value then holds for every
  inner round of that outer round (a ladder across sets: 3 × 12, rest, 3 × 10, rest, 3 × 8);
- `vary` may also name an inner `repeat`, giving its `times` per round ("round 1: complex × 1,
  round 2: × 2, ..."); `override` `set` may change `times` too;
- `listRounds` (how many rounds the flat list holds) is filled in by the compiler, not by the author.

### 3.3 Schema sketch

```jsonc
{
  "schemaVersion": 2,
  "id": "lib.example.20261114.tabata", "name": "Tabata Squats", "team": "solo",
  "healthKitActivity": "highIntensityIntervalTraining",
  "format": "emom", "segments": [ /* compiled */ ], "intervalSeconds": 30,   // compiled, old keys
  "structure": {
    "score": { "type": "totalReps", "parts": ["sq"], "show": "lowestReps" },
    "body": [ /* nodes */ ]
  }
}

// A node has exactly one of these keys:
{ "part":   { "id": "sq", "kind": "station", "movement": "airSquats", "name": "Air Squats",
              // or "movement": { "choice": ["row", "bike", "skiErg"] }, picked at START
              "target": { "value": 15, "valueF": 12, "unit": "calories" }   // M/F standard, picked at START
                      | { "max": true, "unit": "reps" } | { "value": 45, "unit": "seconds" },
              "load": { "value": 95, "valueF": 65, "unit": "lb", "count": 1 }
                    | { "percent": 83 },                                    // % of 1RM of this movement ("of" to name another lift)
              "height": { "value": 24, "valueF": 20, "unit": "in" },        // box, target
              "who": "me" | "partner" | "together" | "shared",
              "note": "free text the engine does not run" } }               // "note" is allowed on any node
{ "rest":   { "id": "r", "seconds": 60 }  |  { "ratio": 1 }  |  {} }
{ "group":  { "id": "g", "label": "round", "load": { ... }, "body": [ ... ] } }   // load of a lift complex
{ "repeat": { "id": "rp", "times": 8,                              // null = until a clock (or "until": "athlete")
              "resume": "<repeat id>",                             // later: carry on where that repeat stopped
              "vary": { "<part id>": [21, 15, 9] | { "from": 3, "step": 3 } | [ {patch}, ... ] },
              "override": [ { "rounds": [4] | ["last"], "id": "<id>", "set": {patch} | "omit": true } ],
              "body": [ ... ] } }
{ "timed":  { "id": "w", "seconds": 180, "early": "wait" | "next",
              "late": "cut" | "end" | "continue", "body": [ ... ] } }

// Later (build 17+): on a part, group or timed, a scheduled interruption
"interrupt": { "every": 240, "startAt": 0, "body": [ ... ] }
```

### 3.4 Examples

All examples are generic (no paid program is copied). Only `structure` is shown.

**Tabata 20/10 × 8** (#31). Work ends at 30k + 20 s, rest at 30(k+1) s, total 4:00, 16 steps.
```json
{"score":{"type":"totalReps","parts":["sq"],"show":"lowestReps"},"body":[
 {"repeat":{"times":8,"body":[
   {"timed":{"id":"work","seconds":20,"early":"wait","late":"cut","body":[
     {"part":{"id":"sq","movement":"airSquats","target":{"max":true,"unit":"reps"}}}]}},
   {"rest":{"id":"r","seconds":10}}]}}]}
```
(Compile rule: an automatic rest followed by a clocked rest becomes one rest step, so Tabata is 16
steps, not 24.)

**3-3-3-4, last window 4:00** (#31, owner's version). Boundaries 180, 240, 420, 480, 660, 720, 960 s,
all from the start.
```json
{"score":{"type":"totalReps","parts":["bench"]},"body":[
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
{"score":{"type":"totalReps","show":"roundsReps"},"body":[
 {"timed":{"seconds":720,"early":"next","late":"end","body":[
   {"repeat":{"times":null,
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

**Death by burpees** (minute n: n burpees; miss a minute and you are out). Score shown as
completed minutes + reps in the failed one, e.g. `10 + 6`.
```json
{"score":{"type":"roundsReps"},"body":[
 {"repeat":{"times":null,"vary":{"b":{"from":1,"step":1}},"body":[
   {"timed":{"seconds":60,"early":"wait","late":"end","body":[
     {"part":{"id":"b","movement":"burpees","target":{"value":1,"unit":"reps"}}}]}}]}}]}
```

**Partner, shared reps** (100 wall balls + 80 cal row split any way, then 800 m run together;
25:00 cap, keep going). `who` changes no timing; it labels the splits.
```json
{"score":{"type":"time","atCap":"totalReps"},"body":[
 {"timed":{"seconds":1500,"early":"next","late":"continue","body":[
   {"part":{"movement":"wallBalls","who":"shared","target":{"value":100,"unit":"reps"}}},
   {"part":{"movement":"row","who":"shared","target":{"value":80,"unit":"calories"}}},
   {"part":{"kind":"run","movement":"run","who":"together","target":{"value":800,"unit":"meters"}}}]}}]}
```

**Hyrox Solo** (8 × 1 km run + station). No `timed` node, so no clock. It compiles to exactly
today's 16 parts, and the engine behaves exactly as today. **Hyrox Doubles** is the same with
`"who": "together"` on the run and `"who": "shared"` on the stations.
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
{"score":{"type":"time","atCap":"totalReps"},"body":[
 {"timed":{"seconds":960,"early":"next","late":"continue","body":[
   {"repeat":{"times":3,"body":[
     {"part":{"kind":"run","movement":"run","target":{"value":400,"unit":"meters"}}},
     {"part":{"movement":"kettlebellSwings","target":{"value":21,"unit":"reps"}}},
     {"part":{"movement":"pullUps","target":{"value":12,"unit":"reps"}}}]}}]}}]}
```
A hard cap ("CAP + reps", the workout stops) is the same with `"late": "end"`.

**Work-based intervals** (5 × 250 m row, rest 1:00 from when you finish; scored per piece):
`{"score":{"type":"perPiece","metric":"time","show":"avg"}, "body":[{"repeat":{"times":5,"body":[{"part":{"movement":"row","target":{"value":250,"unit":"meters"}}},{"rest":{"seconds":60}}]}}]}`.
The rest follows a part you end, so it starts when you finish (rule 4.2.2).

**Rest as long as the round took** (owner's example, 14 Nov: 3 rounds of ski, step-overs and
alternating DB snatches; after each round, rest exactly as long as that round took; no rest after
the last round):
```json
{"score":{"type":"time"},"body":[
 {"repeat":{"times":3,"body":[
   {"group":{"id":"round","label":"round","body":[
     {"part":{"movement":"skiErg","target":{"value":15,"unit":"calories"}}},
     {"part":{"movement":"stepOvers","target":{"value":12,"unit":"reps"}}},
     {"part":{"movement":"alternatingDumbbellSnatch","target":{"value":16,"unit":"reps"}}}]}},
   {"rest":{"id":"r","ratio":1}}],
  "override":[{"rounds":["last"],"id":"r","omit":true}]}}]}
```
What the watch does: round 1 runs as today (you end each part with the Crown). The Crown turn that
ends the snatches ends the round, say at 2:35. The rest is now a clocked rest of exactly 2:35: the big
number counts **down** from 2:35 with `LEFT`, the Crown is ignored, 3-2-1 and GO at 0:00, and round 2
starts by itself. If round 2 takes 3:00, the next rest is 3:00. After round 3 the workout is done. The
round time is measured from the round's first part to the Crown turn that ends its last part.

### 3.5 Tested on a real program

A separate session encoded a real competition program the owner follows (17 weeks, 4 tracks,
1,315 workout pieces; kept in the owner's private storage, never in the repo) into this structure.
It took 62 pieces covering every family and every odd case, and checked them with the 3.2 rules.

- **33 clean:** EMOMs (also alternating 2-4 stations and "1 lift every minute"), Tabata and custom
  work/rest, buy-in + max windows (the 3-3-3-4 family, also 3 × 3:00 then 4:00), station rotation on
  a running clock, AMRAPs and AMRAP ladders, a run buy-in then an AMRAP in the time left, 21-15-9,
  ladders with two different steps, chipper + cap, rounds for time, each round for time + rest,
  repeat efforts with a 14-value list, max-rep sets, steady cardio, partner synchro.
- **24 awkward, now fixed in this draft:** men's/women's standards (in 20 % of pieces: `valueF`),
  rest inside a for-time clock (11 %: `score.includeRest`), time-target parts (5 %: unit `seconds`),
  load on a lift complex (`load` on `group`), load as % of 1RM, per-piece distance (`perPiece`),
  several scored pieces in one entry (`score.combine`), the athlete choosing the machine, rest ratio
  measured over the round, box heights and ft/in, `vary` across nested repeats, a buy-in window
  scored on its max part (`atCut`).
- **5 shapes could not be written** (about 2 % of pieces):
  - "build to a max" with open attempts (1 % of pieces) → fixed: `"until": "athlete"`;
  - an AMRAP split by rests that **continues** where you left off (the program says "continue" or
    "restart" explicitly) → `repeat.resume`, build 17 or later;
  - windows of different lengths with a ladder that continues across them → `resume` + `override`;
  - a lift on a fixed schedule interrupting a piece for time ("every 3:00, 10 bench") → the owner
    wants it: `interrupt` (3.1), build 17 or later;
  - a penalty on breaking ("every break, run 200 m") → out of scope, kept as a `note`.
- **Re-run on the revised draft:** 56 clean, 2 awkward, 4 cannot (about 1 % of the program). The
  last two awkward cases are fixed above (`show: sum` for timed segments scored by total time; mixed
  metrics scored `none`). Of the 4 left, `resume` (2) and `interrupt` (1) are planned; the break
  penalty stays a `note` until rep counting can detect breaks.
- **Owner's input on these shapes (14 Nov, via the corpus session; to confirm in this review):**
  scheduled interruptions are wanted (above); % sets should pre-fill each set's load from the
  athlete's PR × % (needs PRs stored in the app); a complex uses one bar and one load (`load` on
  `group`); in an alternating EMOM with time parts, the bell moves you on if you haven't finished
  (`early: wait, late: cut`).
- **Days are multi-part** (median 5 pieces: warm-up, strength, accessory, metcon, cash-out). The
  engine runs one piece at a time; the build-17 import must split a day into pieces.
- In this program, strength sets are 32 % of pieces and untimed "for quality" rounds 21 %; Tabata is
  under 1 % and death-by never appears. Both run on the same blocks with no clock.

### 3.6 Several scales, one workout

Owner requirement (14 Nov): the same workout at different scales is **one card with the scales**,
not 2-3 workouts in the day. A second real corpus checked it: a class gym where the owner's testers
train (19 months, 1,723 entries; the gym's text stays in the owner's private storage). It has up to
4 scales a day (Rx, a harder competitor scale, Level 2, sometimes Level 1). Of 376 Rx/Level-2 pairs,
267 change only numbers, but 108 change movements (chest-to-bar → pull-ups), the round count or the
distance. So a scale is a whole alternative structure, not a load patch:

```jsonc
"scales": [
  { "id": "rx", "label": "Rx",      "structure": { ... } },
  { "id": "l2", "label": "Level 2", "structure": { ... } }
]
```

- One workout id; `structure` alone = one scale. The largest pair seen is about 6 KB, well inside 16 KB.
- The athlete picks the scale at START (default: the last one used at that gym); the result stores
  the scale id. This is the storage for "Rx / scaled" in section 5.
- The card shows the scale chips and only the parts that differ. Card design goes to the Workouts and
  Navigation chats, mockups to the owner first.
- **Custom scale** (owner, 14 Nov): the athlete can make their own scale and edit it freely (any number,
  swap a movement, change the rounds or the cap). It starts as a copy of a posted scale and is stored
  as one more entry, `{ "id": "custom", "label": "Mine", "basedOn": "l2", "structure": {...} }`,
  checked by the same validator. It belongs to the athlete, not the gym's row: kept on the phone and
  as a personal row linked to the workout id, never written into the gym's row. The result stores the
  full structure that ran, so a custom result is always readable and compared only with the same
  scale.
- **Editing "Mine"** (owner, 14 Nov): reorder movements within a round, change a number, nudge the
  whole scale easier or harder in one step, and **swap a movement** (can't run → row or bike). A swap
  proposes the equivalent amount from a **movement-equivalence table** (e.g. a run distance → row metres,
  bike metres or calories) and records it on the part: `"swappedFrom": {"movement": "run", "value": 400,
  "unit": "meters"}`, so the result shows what was replaced. The table lives on the server next to the
  build-17 movement table, so it can be corrected without an app update.
- **What a public scaling guide looks like** (the owner shared one, 14 Nov; read, not copied). It has
  three kinds of rule, and each fits a small table:
  1. *Cardio conversions* are plain ratios per machine, with a men's and a women's factor: a run
     distance becomes row, ski or bike-erg metres, or calories on an air bike, and calories convert
     between machines the same way. A handful of numbers, then rounding.
  2. *Movement substitutions* are a list per movement, each with a rep ratio (e.g. one hard skill rep =
     a few strict reps of an easier movement; kipping pull-ups → more ring rows).
  3. *Principles*: keep the stimulus and the **time domain**, then cut reps, then load.
  So the server keeps `movement_equivalents` rows `{from, to, unit from → unit to, factorM, factorF,
  round to}` and `movement_substitutions` rows `{from, to, repRatio, note}`. We write our own rows; the
  ratios can be checked against public guides, but no brand's document is copied into this repo.
- **Stimulus**: a workout may declare its intended time domain, `"stimulus": {"minutes": [8, 12]}`. That is
  what the guide's key question ("can I finish in the Rx time domain?") needs, and what the recommended
  scale below compares your predicted time against.
- **Recommended scale (later, once there is data):** from the athlete's past results on similar
  workouts and the workout's `stimulus`, the card can suggest a scale ("Suggested: Rx, you finished Level 2 with time to spare the
  last 4 times") or warn ("Rx may cap you at about 15:40"). It never changes the scale by itself.
- All 34 structures encoded from 17 recent class workouts (every scale) pass the rules: E3MOM at % of
  1RM, 1:00 windows with buy-in then max calories, a growing chipper, "4 rounds each for time,
  start every 7:00", 21-15-9 with cap, AMRAP +2 ladder, buy-in + AMRAP cycles that restart, fixed-start
  segments, partner chipper with synchronized burpees.
- Import rules from this corpus: a class piece split into several entries ("0:00-24:00" and
  "on the 26:00", times scales) is merged into one workout; in a partner workout, parts with no `who`
  default to "each does all", and the import asks.

## 4. The timeline engine

### 4.1 Shape

One engine, written in Python first (`tools/barpath`), then ported to Swift (BarPathKit), with
shared test files proving they agree:

- `plan(definition)`: the list of steps (each knows its round and window) and every clock
  boundary as `{anchor, offset}`. Pure, no clock.
- `reduce(state, event)`: the state machine. Events: `start`, `tick`, `crown`, `undo`, `reps`,
  `end`. Time is an argument; nothing inside reads the watch clock. It returns effects (haptics,
  screen changes, questions) with their times, so the haptic rules are tested too.
- `replay(plan, events)`: rebuilds the state from the saved events (crash recovery, tests).

The watch only feeds events in and plays the effects. `WorkoutSessionModel` stops making timing
decisions. The Crown lockouts and grace live in `reduce`, not in the view, so they are tested.

### 4.2 Rules

1. **Who ends a step is declared.** The athlete ends a `part` (except `max` inside a clock and a
   `seconds` target) and a `rest` with no seconds. The clock ends a clocked or ratio `rest`, the
   automatic rest after an early finish, a `max` part inside a clock, a part with a `seconds` target,
   and any step cut by a bell.
2. **Anchoring.** A step starts at the *planned* end of the step before it if the clock ended that
   step, and at its *actual* end if the athlete ended it. A `timed` window ends at its own start plus
   its seconds.
   - 3-3-3-4 and Tabata: every boundary chains back to the start, so the watch matches the gym
     clock exactly (180 / 420 / 660 / 960 s) whatever the Crown does.
   - "5 × 250 m row, rest 1:00": each rest starts when you finish the row, which is what that
     workout means.
   - One rule gives both behaviours; no format check.
3. **Late ticks catch up, quietly.** Before handling any event at time t, every boundary up to t is
   applied at its planned time. A watch that wakes 40 s late records the same splits as one on time.
   Only the entry haptic of the state you are in now plays, once; a 3-2-1 plays only if at least 3 s
   are left; passed ticks are never replayed.
4. **Earliest boundary wins.** With nested clocks (a cap around windows) the first due boundary
   applies; an outer bell closes every inner window.
5. **Caps.** `late: end` and `continue` as in 3.1. At a `continue` cap the engine stores the step
   and reps you were on.
6. **Cut parts.** When a bell ends a part with an unfinished reps or calories target, that step is
   marked `cut` and its reps asked (6.4). The parts after it in that window are marked `skipped`
   (0 s), as today. A `reps` event names its step: if the athlete says they were on a later part of
   that window, the earlier parts become done and that part becomes the cut one. Reps are stored per
   step, not once per workout.
7. **Crown**, one rule table:

   | Situation | Crown forward |
   |---|---|
   | A part you end, outside any clock (Hyrox, for time) | done, next step; lockout 2 s from the last accepted turn (today) |
   | A part inside a window | done, next part of the window; after the last one, the automatic rest. The window end does not move. Lockout 4 s from the last accepted turn |
   | A `max` part inside a window | "I stopped": automatic rest, count asked |
   | A clocked rest or automatic rest | ignored, with the hint "Clock starts the next part" (no haptic) |
   | Within 3 s after a bell that cut an athlete-ended part (0 ≤ t − bell < 3 s) | **grace**: that part is marked done at the bell time and its reps question dropped. Nothing advances. Checked before the lockout. Not applied after a clock-ended step. |

   **Undo** (Crown back) works as today, except that it never crosses a bell that has already rung.
   Inside a window it can undo an early finish while that window is still running. After a bell,
   fixes go through the reps question or the phone. On the done screen, "unfinish" works only if
   you finished yourself; after a clock finish (AMRAP end, last window, death-by) it is allowed for
   10 s, then only on the phone.

   These replace today's lockout after an automatic advance and the suppress flags.
8. **Unbounded repeats.** AMRAP rounds are written into the flat list up to `listRounds`; the
   engine adds more at the end if the athlete keeps going, so nobody runs out of list. Step numbers
   in results never change.
9. **Get ready.** For workouts with a clock, the clock starts at GO (the end of get ready), not at
   the START tap. "Tap to go now" lets the athlete start on the gym's own 3-2-1. Get ready is an
   event, not a step.
10. **Pause** is not in build 16 or 17. The engine keeps a slot for it.

### 4.3 What it replaces

`autoAdvanceTime`, `autoAdvanceTargetIndex`, `autoAdvance`, `capTime`, `forTimeCapTime`,
`isFinishedByCap`, the suppress flags, `effectiveRoundSize`, `roundSize` arithmetic,
`CardShape.detect`, `capPositionText` and `EmomSet.all` (`WorkoutReportView.swift` 92, which also has a
likely bug: one set per station, so a 2-movement EMOM would show 12 sets). The map is in Appendix B.

## 5. Scoring

Principle: **record facts per step, derive the score.** The result never needs the definition
re-guessed to say where you were.

Per step the result records: round, window, start, end, ended by (athlete / clock / cap / end of
workout), target, reps done (for cut and `max` steps), load used. Per workout: Rx / scaled /
substitution (on the same workout id; a scaled version is not a new library row, see 3.6).

Score types: `time`, `roundsReps`, `totalReps`, `lowestReps`, `load`, `perPiece` (metric time,
distance or reps; show sum, avg, best or slowest), `distance`, `calories`, `none`. Options:
- `show`: a second line (Tabata's lowest round).
- `includeRest`: whether rests inside a for-time clock count in the time (default yes: it is the clock time).
- `atCap` / `atCut`: the score when a bell stops the work before it is done (`totalReps`, ranked below
  every finisher). `atCut` covers a buy-in window not finished before the bell.
- `combine`: `sum` or `perPiece` when one entry has several scored pieces (two AMRAPs, AMRAP cycles
  that restart). A sum of rounds + reps is the sum of total reps. An entry whose pieces are scored in different
  metrics (run time + max reps + row time) is mostly training with no time to beat (owner): score
  `none`, with the per-step facts recorded. Power output later.

Men's/women's standards, % loads and the machine choice are resolved at START and stored in the result.

| Format | Score | Shown with |
|---|---|---|
| For time | `12:34` | splits. **Capped: `CAP + 212`** (total reps, always below every finisher); `R4 · Pull-ups 12/15` and time past the cap as context |
| Rounds for time / 21-15-9 | `12:34` | splits per round |
| AMRAP, AMRAP ladder | total reps | `7 + 23` or `Rung 7 + 9` |
| EMOM / every X | `8/8`, or `load` if the parts carry a load | per window: done or partial, rest left |
| Windows (3-3-3-4) | `Bench 31` (sum of the `max` part) | per window: parts done, partial (12/15), max reps |
| Tabata | `96` | lowest round, 8 numbers |
| Work-based intervals, repeat efforts | `avg 0:58` per piece, or metres per piece | each piece |
| Strength sets | heaviest load × reps | load per set |
| Death by | `10 + 6` | minute reached |
| Hyrox | `1:12:34` | every run and station (Roxzone later), unchanged |

A buy-in inside an AMRAP counts in the total reps; only the `repeat` counts as rounds.
The capped score of #52 comes from the plan, with no `roundSize`.

## 6. Watch and phone

Proposed by the designer. **Anything that changes the approved screens needs a mockup the owner
approves before it is built** (`CLAUDE.md`, `docs/DESIGN_GUIDELINES.md`).

### 6.1 Watch states (the same in every format)

| State | Big number (the one signal) | Crown forward | Haptic on entry |
|---|---|---|---|
| Get ready (clocked workouts; build 17) | seconds to GO | nothing (tap = go now) | 3-2-1, GO |
| Work you end (Hyrox, for time) | part time, counting up, yellow (today) | done, next part | today's |
| Work the clock ends (window, Tabata, EMOM, AMRAP) | time **left** to the clock that ends it, with `LEFT` | done / "I stopped" (4.2.7) | GO if by clock |
| Rest (clocked, or early finish) | time left to GO | ignored, hint | rest haptic if by clock |
| Switch flash (1.8 s, today's) | `GO` / `REST` / `TIME` + part | grace rule | as above |
| Done | score | drives the reps question if open; back = unfinish (4.2.7) | TIME / success |

- The big number is always the clock that will end what you are doing. A for-time cap you can run
  past never takes it; it stays in the top line.
- **Wrist down:** same layout dimmed, the clock at 1 Hz, same haptics, the last 10 s at full
  brightness. The countdown is drawn with the system's timer text so it stays exact wrist down.
- **Taps:** page 1 ignores taps (a palm can't change anything). The only taps are "go now", the reps
  question (✓, change movement) and Save. A 1 s long-press = Crown forward (today).

### 6.2 3-2-1 and haptics

- 3-2-1 before every bell that changes what you do: end of a window, end of a rest, the AMRAP's end
  (and end of get ready, build 17).
- The haptic at 0 says what you go into: **GO** (`.start`) into work, **REST** into rest, **TIME**
  (today's) at the end. Today every clock change plays the same `.start`. The REST pattern must feel
  different from TIME (which starts with `.stop`); chosen on a device. Haptics stay at least 0.6 s apart.
- Optional single buzz at 10 s left, only for windows of 1:00 or more.
- Silent: anything only you can end (Hyrox, for-time parts); a for-time cap (today: TIME haptic only,
  no 3-2-1); a bell that changes nothing (you finished bench early and are already resting).
- When two bells are less than 4 s apart, only the later one ticks. The cap banner never interrupts
  a 3-2-1; it shows right after.

### 6.3 Wireframes (41 mm; name alone on the first line, round in the small line)

```
Tabata work            Tabata rest            3-3-3-4, bench window
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ SQUATS · MAX     │   │ REST             │   │ DB BENCH · MAX   │
│       0:14       │   │       0:07       │   │       0:41       │
│       LEFT       │   │       LEFT       │   │   LEFT TO 3:00   │
│ R3/8      ♥ 168  │   │ NEXT SQUATS · MAX│   │ ✓ ✓ ● Bench      │
│ Rest 0:10 next   │   │ R3/8      ♥ 171  │   │ W3/4      ♥ 162  │
└──────────────────┘   └──────────────────┘   └──────────────────┘

Ladder in an AMRAP     Hyrox run (unchanged)  Reps at the bell (in the rest, build 17)
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
│ THRUSTERS 6      │   │ RUN 4/8    38:12 │   │ REST 0:52  W3→W4 │
│       7:22       │   │       3:41       │   │ PULL-UPS 15  ▸   │
│       LEFT       │   │ 4:52/KM   ♥ 158  │   │        12        │
│ R3        ♥ 165  │   │ ● ● ● ◐ ○ ○ ○ ○  │   │   at the bell    │
│ Next: Pull-ups 6 │   │ Next: Row 1000 m │   │ saves at GO  [✓] │
└──────────────────┘   └──────────────────┘   └──────────────────┘
```

### 6.4 Reps when the clock ends a part

- Asked only for a cut part with reps/calories or a `max` part. Never for runs, metres, time or
  rests.
- The movement asked is the one the plan had at the bell. Its name is a button: tap to step to the
  next part of that window, if the athlete was further than the watch thought.
- **Build 16:** on the done screen (today's picker, at most 3 questions) and on the phone (Fix
  splits gets a reps cell per step; Tabata: 8 empty cells).
  **Build 17:** also in the next rest if it is 20 s or longer (the Crown is free there), saving
  itself at the next GO.
- Untouched = "not entered", never 0. **It never blocks the clock.**

### 6.5 Phone

- **Card**: one structure line made from the plan (`8 × 20 s on / 10 s off`;
  `4 windows: 3:00 work · 1:00 rest, last 4:00`), "until 3:00" on parts the clock ends, and (build 17)
  a thin to-scale bar of the workout.
- **Results**: one table, windows or rounds as rows and parts as columns. A cut part shows `12/15`
  with a clock mark; empty cells can be tapped to fill in. A `max` part ended by the bell shows its
  count with no mark. EMOM and Hyrox views stay as they are.
- **Before START (build 17):** one-tap edits the coach makes at the whiteboard (rounds, cap, window
  length, targets) and "started N s late" to line up with the gym clock, both stored in the result.

### 6.6 What the athlete must never have to do

Turn the Crown to start or end a rest or a window; turn it to catch up; turn it twice; answer a
question before the next part can start; enter 0 for "I don't know"; enter reps for a movement the
watch guessed wrong with no way to change it; scroll mid-set; feel a countdown before something only
they can end.

## 7. Backend (Supabase)

### 7.1 Today

`workout_library` has `id`, `definition` (jsonb, NOT NULL), `program`, `scheduled_on`, `published`,
`owner`, `gym_id`, timestamps, and a check that `definition->>'id' = id`. 25 rows (18 gym, 7
personal). Nothing checks the content except `make_row.py`, and the app can write personal rows
directly. Upserts overwrite in place; there is no history. Results are JSON files in Storage that
embed the full definition they ran.

### 7.2 Proposal, in steps

**Before build 16 ships (additive only, safe for build 15):** add an empty, nullable
`definition_v2` jsonb column. Build 16 selects it and prefers it over `definition`. (A build that
selects a column that does not exist fails its whole fetch, so the column must exist first.)

**Build 16 rows:** the re-written rows carry the same document in both columns: `definition` =
old keys compiled + `structure` (build 15 ignores `structure` and runs the old keys, exactly as
today: no worse), `definition_v2` = the same. `make_row.py` accepts `structure`, regenerates the old
keys and refuses a mismatch; `--diff-live` shows the owner what changes before upload. The rows are
uploaded only after build 16 is installed, and **none of them is a race workout.**

**After the race (build 17, before the import ships):**
- `definition_v2` becomes the source of truth for every row (backfill, 7.3).
- `revision` (bumped by a trigger) and a `workout_library_revisions` history table: a result can name
  exactly which version it ran; a bad edit can be rolled back. The revision is the identity; content
  hashes are never compared across languages (Swift writes `40`, Python `40.0`).
- **One JSON Schema file** in the repo (`schemas/workout-definition.v2.schema.json`) used by
  `make_row.py`, the Python and Swift tests and the database (a trigger with the `pg_jsonschema`
  extension), plus the few rules it can't express (3.2, and `compile(structure) == old keys`),
  written in Python, Swift and SQL against shared test cases. An RPC
  `validate_workout_definition(jsonb)` serves `make_row.py` and the import. The trigger must exist
  before the import function is deployed.
- RLS stays public / gym / personal. Personal writes now pass validation; users can't write the
  trigger's columns (column-level grants, since revoking one column does nothing while the table
  grant stays). Imports are written with the user's token, so they can only be personal. Index
  `owner`.
- `schemaVersion` rule: any new field whose omission would change the timeline or the score bumps it,
  so a build-16-or-later app refuses the workout ("Update the app") instead of running it wrong.
  Build 15 can't refuse, which is why D5 exists.

### 7.3 Migrating the 25 rows

A pure `upgrade(old definition)` function (Python, then Swift) labels each row:
**exact** (compiling the upgrade gives back the same parts and timing; about 17 rows),
**review** (a guess was made: the 3 AMRAP ladders with listed rounds), or **re-encode** (the 3 Tabata
and 2 "3-3-3-4" rows, plus any station with a seconds target, which #31 says must end on the clock).

1. Backfill `definition_v2` only: a dry run first, then one idempotent update per row that skips rows
   edited since export, inside a transaction. Undo = set `definition_v2` back to NULL. `definition` is
   not touched.
2. Separately, once build 17 is on TestFlight (D5): drop NOT NULL on `definition`, change the check to
   `coalesce(definition_v2, definition)->>'id' = id`, and set `definition` to NULL for the rows build 15
   would run wrong. The old values stay in the revisions table and the reverse SQL is written down.
   Build 15 then lists those rows under "Library rows not shown".

The new app also upgrades old rows on the device, so it runs every row before the backfill is done.

### 7.4 Results

New optional fields only: per-step `reps`, `cut`, `endedBy`, `round`, `load`; Rx/scaled; the definition
it ran (with `structure`); from build 17 `definitionRef {id, revision, schemaVersion}`. The old
`partialReps` / `repsAtCap` are still written. The result `version` stays 2 unless we prove no reader
branches on it.

- **Build-15 phones drop unknown keys.** If a build-15 phone edits a result in Fix splits, the cloud
  correction (W17) would wipe the new fields on a newer phone. So newer phones **merge** a correction
  (take its times and reps, keep their own new fields) instead of replacing the file. Tested by
  round-tripping a new result through the old decoder.
- Old results are read as today; when a view needs a structure, the same `upgrade` gives it one.
  Re-scoring an old result against a corrected workout is an explicit athlete action.

### 7.5 Build-17 import

The server function returns exactly a v2 definition, checked against the same schema and then the
database RPC. The import log keeps the returned definition, the validation errors, the saved row id
and what the athlete finally saved. The confirm screen shows the structure line and the score type,
because the parser will sometimes get "total reps" vs "lowest reps" wrong.

## 8. Watch, phone and old app versions

- **Phone → watch.** The definition already travels in the `selectWorkout` application context and
  as a message. It just grows (a structured Tabata is 1-3 KB; the biggest row today about 6 KB);
  budget 16 KB, checked by a test and when sending. No key is reused or removed: `type`/`selectWorkout`,
  `liftSelection` and `weightUnit` stay as they are.
- **Fix first, in its own commit (shared file):** `sendWorkout` in `iOS/PhoneLink.swift` (~164-173)
  rebuilds the context from scratch and keeps only `liftSelection` and `weightUnit`, so any future key
  would be wiped on every send. It must copy the existing context and change only its own keys. Not
  part of the race slice; it can go with the W28 follow-ups.
- **Old builds.** Swift ignores unknown keys but **fails on an unknown enum value** (new `format`,
  segment kind, unit, event kind) and the whole workout is dropped. So: add keys only; never add a case
  to an existing enum; new result data in optional fields. `structure` gets its own lenient decoder: if
  a build-16 watch can't read it (a build-17 node type), it sets it to nil, logs it, and runs the old
  keys. Fixture with an unknown node.
- **Silent failures today:** an old watch that can't decode a definition drops it while the phone
  shows "sent"; a stored workout that fails to decode falls back to Partner WOD 1
  (`Watch/WorkoutSessionModel.swift` 244-256). Build 17: the watch publishes `watchCaps` (schema
  version, build, `appliedWorkoutId` + `sentAt`) in **its own** context, the phone says "On your
  watch" only after that, and warns when no `watchCaps` arrives (build 15 or older). The fallback
  shows a message instead.
- **Crash recovery.** Today a crash ends the workout and saves it (W24); that stays for both engines.
  The checkpoint adds (optional fields): the definition, plan hash and planner version, the start
  time (wall clock), and every athlete event including reps and undo. The state is a replay of those,
  so "resume the running workout" is possible later with no new data. An unreadable checkpoint is
  moved aside, not deleted.
- **Timing.** The watch clock is already accurate to about 0.2 s; the drift was a model bug, not a
  timer bug. Boundaries are `start + planned offset`. The loop wakes at the next planned event (at
  most every second), a guard stops any effect firing twice. The 3-2-1 with the wrist down must be
  checked on a device.
- **Battery.** Planning costs nothing; the cost is waking up and redrawing. No 10 Hz; redraw only when
  the window changes.

## 9. Recording and analysis

- Keep today's `name=segment` CSV lines (`index=` = the flat list), including one per part the clock
  skips, and the result's `segments` and `events`.
- Add one `name=plan` line at start (schema version, plan hash computed by Swift only, `startEpoch`,
  `startUptime`) followed by the planned boundaries, one per line when there are many; one
  `name=step` line per step change (`step=`, ended by, partial reps, sequence number); and
  `name=input action=ignored reason=…` for Crown turns the engine ignored. Old parsers ignore unknown
  names.
- With a `plan` line the loader reads `step` lines; without one, `segment` lines by `index`. It sorts
  by time and sequence number (#50: event lines are not in time order).
- Fixes found by QA: today `clockAdvance` writes one line even when it skips several parts, so the
  Python replay falls one part behind; the CSV uses time since boot while the result uses wall time and
  nothing checks they agree.
- `tools/barpath` gets a "plan vs actual" report with a drift alarm. A test loads every workout CSV in
  `data/raw` and checks its segments still cover the session.

## 10. Test plan

Every algorithm test is data: Python writes the expected output, Swift reads the same file, and CI
fails if regenerating changes a file.

1. **Schema**: valid and invalid definitions, the same cases in Python, Swift and the database.
2. **Planner**: definition → steps and boundaries (`{anchor, offset}`, ended by), including step counts.
3. **State machine**: scripted event streams → steps, effects (time, kind) and score. Late, double
   and missing Crown; Crown in a rest; Crown 1 s before and 2 s after a bell; a tick 45 s late; crash
   and replay; cap mid-part; undo in an automatic rest; undo across a bell. Plus 1,000 random event
   streams with fixed seeds: steps never overlap, start-anchored boundaries are always on time, replay
   equals live, a late tick equals on-time ticks.
4. **Migration**: every built-in, seed row and a dump of the library upgraded, validated, and its plan
   equal to today's behaviour where today was right. Each intended change listed by name.
5. **Routing**: the route (old path or engine) for every built-in and all 25 rows.
6. **Scoring**: per fixture.
7. **Old results**: build-15 results frozen as files, must decode and render unchanged; a new result
   round-trips through the old decoder.
8. **Old path**: `expected/legacy.result.json` generated from today's Python `WorkoutProgress` (with
   double-Crown, undo and crash streams), so "Hyrox identical to build 15" has something to compare to.

Fixture folder (inside the Swift package, which can't read files from `tools/`):
`BarPath/BarPathKit/Tests/BarPathKitTests/Fixtures/workouts/<case>/` with `definition.json`,
`expected_plan.json`, `events/<scenario>.json`, `expected/<scenario>.result.json`, and an `INDEX.json`
with the case count, so a missing case fails instead of skipping (today a missing fixture skips).

| Case | Must show |
|---|---|
| Tabata 20/10 × 8 | 16 steps on the clock, no Crown needed, total 4:00; a Crown in a rest is ignored |
| 3-3-3-4, last 4:00 — `recorded-13nov` | the real Crown times (199, 481, 732, 1041 s and the double turn) replayed: boundaries exactly 180/240/420/480/660/720/960, no Crown moves a clock, a stated outcome for each turn. (Those turns reacted to a watch that was already behind, so this scenario checks the clock only.) |
| 3-3-3-4, last 4:00 — `gym-truth` | scripted to match what happened: round 3 pull-ups cut 12/15, bench 12/7/0/12 entered as reps, the 960 s bell asks bench round 4, score `Bench 31` |
| 3-3-3-4, 3:00 every round | adds the 900 s boundary |
| Ascending ladder | rounds past the list are added; score total reps |
| Descending ladder | 21-15-9 splits as today |
| Alternating EMOM | odd/even windows; one failed window cut with reps |
| Death by | ends at the missed minute; score `10 + 6` |
| AMRAP with buy-in and cash-out | buy-in reps in the total; cash-out runs after the AMRAP |
| For time, cap, partial | cap announced, position stored, `CAP + reps` if not finished |
| Work-based intervals | rest from the actual finish; time per piece |
| Rest = round time (1:1) | each rest equals the round before it (2:35, 3:00); counts down; no rest after the last round; a late Crown turn lengthens the round and the rest by the same amount |
| Build to a max | open attempts ended by "done with this block"; score best load |
| Time-target part in an EMOM | a 45 s part ends on the clock with no extra `timed` |
| Hyrox 8 × 1 km | identical to `legacy.result.json`, step by step |

**27 synthetic fixtures** approved by the owner (8 public benchmarks: Fran, Helen, Cindy, Chelsea,
Death by pull-ups, Tabata Something Else, Fight Gone Bad, Grace; and 19 invented look-alikes, one per
odd shape of the real program) are ready in the owner's storage, each with its structure and expected
score and record. They are safe for the repo and go in with the engine PR. 24 of 27 pass the rules
today; the 3 others need `resume` or `interrupt`.

The 62 encodings of the real program (3.5) stay in the owner's private storage and are re-run by
the corpus session against each draft of the schema; generic look-alikes of its odd shapes go into
the fixtures above.

The 13 Nov Crown times not quoted in the issues are taken from the build-15 recording's event lines
(no motion data in the repo) and marked synthetic until then.

## 11. Delivery

**First: the owner approves this RFC (D1).** The schema, the Python engine and the fixtures can then
start at once; they touch no app code.

### Build 16: W27 becomes "timeline engine for clocked workouts" (small slice)

1. Python: structure, validator, `plan`, `reduce`, `upgrade`, fixtures (section 10).
2. Swift port in BarPathKit + parity tests. `WorkoutDefinition` gains an optional, leniently decoded
   `structure`.
3. **Routing, on the received definition:** the engine runs only when the definition has a
   `structure` with a start-anchored window (`timed` with `early: wait`), and the engine switch is
   on. Built-ins never use it. Hyrox, for time, AMRAP, partner WODs and Free stay on build 15's code,
   unchanged, until after the race. The switch is read once at START and the chosen engine is saved in
   the checkpoint.
4. Watch, for those workouts only: time left as the big number, 3-2-1 and GO before every bell, the
   Crown table (4.2.7), per-step `cut`, reps on the done screen and on the phone.
5. `make_row.py` accepts `structure`; the Tabata, 3-3-3-4 and seconds-target rows re-written and
   uploaded after build 16 is installed; #52's round number from the plan; CSV `plan`/`step` lines;
   the new optional result fields; the empty `definition_v2` column.
6. Race guard: the routing test, and the three Hyrox built-ins plus a Hyrox row sent from the phone
   compared step by step with `legacy.result.json`.

**Moved to build 17** (to keep build 16 small): get ready, the REST haptic, the 10 s buzz, reps
in the rest, `watchCaps`, the phone's to-scale bar.

**Race gates** (the Scrum Master checks them):
- G1: all fixtures pass in Python and Swift with zero skipped tests, plus the random streams.
- G2: the library dump upgraded; every difference approved by the owner.
- G3: build-15 results render as today (golden files).
- G4: the engine switch tested on a device (off = build 15 behaviour).
- G5: a full Hyrox simulation on the exact TestFlight build (W28 included): 16 segments, events sort,
  watch clock within 1 s of the phone. Any later commit to the workout code or PhoneLink resets G5.
- **Freeze workout code Fri 27 Nov; owner go/no-go Mon 30 Nov.** If W27 isn't device-tested by then,
  the engine switch ships **off** and the race runs on build 15's Hyrox path.

The slice pushes build 16 by about a week against the proposed 20 Nov invites. The alternative (D4)
is to ship build 16 now with W28 and W23 only, and move the engine to build 17.

### Build 17 (after the race)

- Every workout through the engine, once replaying all stored results gives the same splits; then
  delete the old clock code.
- Supabase: backfill, revisions, server validation, then D5's NULLs.
- Photo/text import produces `structure` (why the schema must be settled now).
- Score types, cards and summaries from the plan; the per-window results table; Rx/scaled; partner
  `who` labels; edits before START; the items moved from build 16.

### Later

Pause, resume after a crash, multi-part class days, Roxzone parts, live view on the phone, `who` for
relays of 3-4 athletes.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Hyrox regression before the race | Hyrox stays on build 15's code path; routing test; legacy comparison; gates G1-G5; freeze 27 Nov |
| Build 16 slips | Small slice; engine switch ships off if the gate is missed; D4 |
| Two engines during build 16 | One adapter is the only interface; old code deleted in build 17 |
| The Crown behaves differently in clocked workouts | D2; hint on ignored turns; grace and lockouts tuned on a device |
| Structure grows too general | 5 blocks, lists and progressions only; nesting ≤ 3; strict validator |
| Build 15 runs re-written rows the old (wrong) way | No worse than today; rows uploaded after build 16 is out; hidden from build 15 later (D5) |
| Old phones wipe new result fields | Newer phones merge corrections instead of replacing |
| Late haptics with the wrist down | Data is right anyway (catch-up); device test of 3-2-1 wrist down |
| Summary/scoring code has no Python reference | Written in Python first in build 17, with parity tests |
| Race day, not caused by this work | A crash ends the workout (W24 saves it); a Hyrox plan turns GPS on, which at an indoor venue means an outdoor session searching for GPS; battery over 60 min is not measured. Owner to decide before the race. |

## 13. Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Adopt this structure (5 blocks + declared score, several scales per workout as in 3.6) as the one format for the library, the import and results. | **Yes.** |
| D2 | Crown in clocked workouts (4.2.7): forward = "I finished this part" (on a `max` part: "I stopped"); ignored in a clocked rest; never moves a clock; undo never crosses a bell; 3 s grace after a bell; 4 s lockout inside windows. | **Yes.** Answers the open question in #31. |
| D3 | Reps when the clock ends a part: asked on the done screen and the phone in build 16, also in rests ≥ 20 s from build 17; untouched = empty, never 0; never blocks the clock. | **Yes.** |
| D4 | Build 16 with the small engine slice (freeze 27 Nov, go/no-go 30 Nov, ships switched off if not ready), or build 16 now without W27 and the engine in build 17. | **The small slice in build 16.** Hyrox is untouched either way. |
| D5 | Rows build 15 would run wrong (Tabata, 3-3-3-4, seconds targets): keep showing them on build 15, or hide them from build 15 once build 17 is out. | **Show during build 16 (no worse than today); hide from build 15 once build 17 is out.** |
| D6 | Default scores: Tabata = total (lowest shown); windows = sum of the `max` part; capped for time = `CAP + total reps` (position as context), keep going as today; EMOM with loads = heaviest load; intervals = time per piece. Each workout can override. | **Yes.** |
| D7 | New watch signals, answer each: (a) a REST haptic different from GO; (b) the countdown white with `LEFT`, count-up stays yellow; (c) 10 s get ready, windows counted from GO; (d) a buzz at 10 s left in windows ≥ 1:00. | **(b) in build 16; (a), (c), (d) in build 17**, all as mockups first, tuned in the gym. |
| D8 | Backend after the race: `definition_v2` as the source of truth, revision history, server validation (enable `pg_jsonschema` on the project). Only the empty column before the race. | **Yes.** |

---

## Appendix A: the team review

Six independent reviewers each got the code, the docs, the library and the issues, not each other's
conclusions: a software architect, a CrossFit/Hyrox coach, a product designer, a backend engineer, a
watch/iOS engineer and a QA/data engineer. Three earlier read-only reviews (architect, coach,
designer) from the Scrum Master were used as extra input; they agreed on the root cause and the
"window clock" fix. Each reviewer then critiqued the merged draft; this version includes the fixes.

### First round: where they disagreed

| Topic | Positions | Resolved |
|---|---|---|
| Primitives | Architect: 5 node types (`part`, `rest`, `group`, `repeat`, `timed`). Coach: 6 (item, block, clock, rest, score, team). Earlier architect: 7 (adds `intervals`, `amrap`, `cap`). | 5 node types + a score. AMRAP, EMOM and caps are `timed` with two rules (`early`, `late`); team is the existing root field plus `who`. Fewer types = simpler validator and import parser. |
| Storage | Architect: one `structure` key inside `definition`, old keys compiled; build 15 runs the old keys. Backend: a separate `definition_v2` column; NULL `definition` where build 15 would run the row wrong. Watch: keep the flat keys, add an optional field. | Both, in steps. Build 16: `structure` inside `definition` and the same document in an empty-until-then `definition_v2` column (no worse than today for build 15). Build 17: `definition_v2` is the source of truth, then NULL for rows build 15 would run wrong (D5). |
| Rest anchoring | Designer: every clock from the workout start. Architect: from the start, or from the end of an athlete-ended part. | Architect's rule (4.2.2): "rest 1:00 after a 250 m row" must start when you finish. Goal 3 reworded: never from a Crown turn *inside a clocked window*. |
| Crown in a clocked rest | Architect: rejected with a "no" haptic. Designer: ignored, hint, no haptic. | Ignored with a hint, no haptic (one less signal). |
| Reps at the bell | Architect: done screen + phone in build 16. Designer: in the next rest. Coach: all windows on the done screen. | Build 16: done screen + phone. Build 17: also in rests ≥ 20 s (needs a mockup). |
| Version field | Architect: `structure.v`. Backend and watch: `schemaVersion` at the root. | `schemaVersion` at the root, one rule for bumping it. |
| Who uses the engine in build 16 | Architect: workouts with a fixed boundary. Watch: only definitions carrying `structure`, with a switch. | Both: received `structure` with a start-anchored window, and the switch on. |

### Critique round: main objections and what changed

**Architect**
- The `WorkoutProgress.swift` line numbers from the first report were 221 too high → corrected (the
  file is 229 lines).
- Tabata compiled to 24 steps (automatic rest + 10 s rest back to back) → compile rule merges them; a
  step-count fixture.
- Build 16 too big for the freeze → get ready, REST haptic, 10 s buzz, reps in rests and `watchCaps`
  moved to build 17; the PhoneLink fix out of the race slice.
- "Clocked boundary inside" also matched AMRAP 40's rest and a for-time cap → routing defined as "a
  start-anchored window", with a routing test over every row.
- "Undo only inside the window" removed undo from Hyrox → "undo never crosses a bell; otherwise as
  today".
- Unbounded repeats needed validator rules; storage needed NOT NULL dropped and the id check changed;
  get ready counts from GO; the 3-3-3-4 example's score type → all added.

**Coach**
- No score type for work-based intervals or strength sets → `perPiece`, `load`, load per step.
- A capped for-time score must rank below every finisher → `CAP + total reps`, position as context.
- `late: end` ended the whole workout, breaking a cash-out after an AMRAP → it closes its window and
  the unbounded repeat around it; what follows still runs.
- Rest as a ratio and partner "one runs, one does max" couldn't be written → `rest {ratio}`, `max` part
  outside a clock.
- Gym floor: start on the coach's 3-2-1, "started late by N s", whiteboard edits, Rx/scaled on the
  result → added (build 17; Rx/scaled fields now).
- Ladder AMRAP scored as total reps; death-by shown `10 + 6`; Hyrox Doubles example; `listRounds` out of
  the authored JSON → done.
- Not taken: `who: each` and member numbers for relays of 3-4 → "Later".

**Designer**
- Catch-up had no haptic rule (a late wake would fire a burst) → only the current state's haptic,
  once.
- A `max` part ended by the bell is not a "cut" → planned ending, no clock mark; Crown = "I stopped".
- Tap-to-change-movement conflicted with "skipped" → a `reps` event names its step.
- Lost rules restored: unfinish on the done screen, two quiet rules, wrist-down, palm-safe taps.
- Wireframes overflowed 41 mm → name alone on line 1, round in the small line.
- D7 split into four answers; a glossary added; get ready counts from GO.

**Backend**
- NULL `definition` would also hide rows from build 16 → the empty `definition_v2` column goes in before
  build 16, and build 16 prefers it.
- Build-15 phones drop new result fields and the correction would overwrite the good copy → newer phones
  merge corrections; round-trip test.
- 7.3 contradicted D5 → backfill first (reversible), NULLs as a separate later step with reverse SQL.
- `structure` and the old keys could drift → `make_row.py` regenerates and refuses mismatches; the
  database checks it from build 17.
- Re-written rows change what build 15 testers run → uploaded after build 16 is installed, owner
  sign-off with `--diff-live`; none is a race workout.
- Only the empty column before the race; revision is the identity, never a cross-language hash; RLS with
  column grants; index `owner` → added.

**Watch/iOS engineer**
- One unknown value inside `structure` would drop the whole workout on a build-16 watch → lenient decoder
  for `structure`, fall back to the old keys.
- Route on the received definition, never on `upgrade()` of a built-in; switch read at START and saved
  in the checkpoint → done.
- Schedule too tight → the slice was cut down and ships switched off if the gate is missed; D4 offers
  the alternative.
- Checkpoint needs plan hash, planner version, reps and undo events; move a bad checkpoint aside → added.
- REST must not feel like TIME; `watchCaps` goes in the watch's own context with an ack; budget enforced
  at send; CSV field names; result `version` stays 2; system timer text for the countdown; race risks
  (crash, indoor GPS, battery, exact build) → added.
- PR #57 does not change the `sendWorkout` finding (it still rebuilds the context). Its description
  lists `loadKg` as a context key; `loadKg` is a message key → passed to the Scrum Master.

**QA/data engineer**
- The 3-3-3-4 expected result could not come from the recorded Crown turns (they reacted to a watch
  already behind) → two scenarios: `recorded-13nov` checks the clock only, `gym-truth` checks reps and
  the score. "Cap question" reworded: the 960 s bell is the last window's end.
- Grace, lockout, catch-up and anchoring needed exact rules → 4.2 now states them (reference points,
  `<` vs `≤`, order), and expected results list effects.
- Death-by's score was ambiguous → `10 + 6` = completed minutes + reps in the missed one; unfinish for 10 s.
- Undo edge cases, loader reading `step` or `segment` lines (not both), every `data/raw` CSV still loads →
  added.
- The race gates were condensed too far → G1-G5 restored, go/no-go on 30 Nov.
- "Hyrox identical to build 15" had nothing to compare against → `legacy.result.json` from today's
  Python `WorkoutProgress`.

### Test on a real program (after the critique round)

A separate session encoded 62 pieces of a real 17-week program (section 3.5): 33 clean, 24 awkward,
5 could not be written; after the changes below, a re-run gave 56 clean, 2 awkward (then fixed), 4
cannot (about 1 % of the program: `resume` later, two kept as notes). What changed:
- Added to the schema: men's/women's standards (`valueF`), `seconds` targets, load on a group,
  % of 1RM, heights and ft/in, machine choice, `note` on any node, `"until": "athlete"` for "build to
  a max", `vary` across nested repeats, rest ratio measured over the round.
- Added to scoring: `perPiece` (time, distance or reps; sum, avg, best, slowest), `includeRest`,
  `atCut`, `combine`; mixed-metric entries are split by the import.
- Planned, not now: `repeat.resume` (AMRAP cycles that continue across rests) and `interrupt`
  (scheduled interruptions, which the owner wants).
- Kept as a `note`: penalties on breaking, until rep counting can detect breaks.
- 27 synthetic fixtures (benchmarks + invented look-alikes) approved by the owner for the engine PR.
- A second corpus (a class gym, 1,723 entries) passed in full (34 structures) and brought the owner's
  "one card, several scales" requirement: `scales` (3.6), `vary` on an inner repeat's count.
- Days are multi-part: the build-17 import splits a day into pieces.

## Appendix B: today's special cases

The architect's audit lists 61 places, each with file and line (kept in the review notes, outside the
repo). Where they go:

| Today | In the new design |
|---|---|
| `autoAdvanceTime` (`WorkoutProgress.swift` 122-135), `autoAdvanceTargetIndex` (139-145), `autoAdvance` (150-158) | plan boundaries + catch-up on tick |
| `capTime` (161-165), `forTimeCapTime` (169-173), `isFinishedByCap` | `timed.late` = end / continue |
| `capSegmentIndex` (189-194), `repsAtCapSegment`, `partialRepsSegment` | the step marked `cut`, or the step at the `continue` bell |
| `autoSuppressedStart`, `capSuppressed`, Crown lockout after an automatic advance | the Crown table (4.2.7) in `reduce` |
| `roundSize` arithmetic, `effectiveRoundSize` (`WorkoutSummary.swift` 608), `repeatPeriod`, `CardShape.detect`, `capPositionText` (`WorkoutResultCap.swift` 72-77) | `step.round` from the plan |
| `slotStart = k * interval` | the plan's real window start |
| `format` switches in summary, card, start tile; `EmomSet.all` (`WorkoutReportView.swift` 92) | `score.type`, a label derived from the tree, windows from the plan |
| one `partialReps` / `repsAtCap` per workout | `reps` per step (old fields still written) |

## Appendix C: formats covered

About 90 % of what athletes do in these gyms is 8 formats, and together they cover all 25 library rows:
for time (with or without cap), rounds for time (with ladders and pyramids), AMRAP, EMOM / every X:00,
strength sets for load, timed intervals (Tabata, work/rest, windows like 3-3-3-4), distance or calorie
intervals with rest, and a partner split on any of these. The coach's catalogue of 31 formats
(including death-by, buy-in/cash-out, fight-gone-bad style, team relay, Hyrox doubles and relay,
compromised running) maps onto the same five blocks, and so does a real 17-week program, except
a few rare shapes kept as notes (section 3.5). Not yet: relays of 3-4 athletes with named legs,
and anything that needs pause or a multi-part day.
