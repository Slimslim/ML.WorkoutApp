# RFC: one workout structure for every format

Status: **approved by the owner on 15 Nov** (spike #55), after a team review and a red team (section
14). The approval covers the **structure and the engine**: schema, timeline rules, scoring,
migration, versioning. The visual parts (card designs, watch signals, wireframes) are **deferred to
Design build 17 and not part of this approval**. Nothing here is built.

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
| Library (25 rows on 14 Nov; 29 published by 15 Nov) | 3 Tabata rows and 2 "3-3-3-4" rows can't be expressed at all. AMRAPs are typed out 12 times, so a fast athlete runs off the end. "Max", "shared", "synchro" exist only in names. Strength sets and ski intervals are scored as total time. | Repetition, windows and scoring are flattened into the parts list. |

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

**Versioning** (section 14.3 A and 14.4 are the full rules):
- `schemaVersion` is a major version (absent = 1, `0` = a draft that never runs, `2` = this RFC).
- `requires: [feature, ...]` at the root is computed by the compiler. A reader that doesn't know a
  feature refuses the workout: "Update the app", with **"Run as stopwatch"** as the way out.
- Engine fields (timing or score) are in the frozen v2 list or named in `requires`. Descriptive
  fields (`note`, `rawText`, tempo, labels, `x-*`) never cause a refusal.
- The old keys run on an old build **only when the scale is `fidelity: "exact"`**. There is no
  silent fallback to them.
- Every hop (database, phone, watch, result, cloud correction) passes the raw JSON through unchanged.
- `rawText` (what the coach wrote) is mandatory on imported, synced and drafted scales; `fidelity`
  is `exact | approx | textOnly`, with the reasons.

**Validator rules** (one JSON Schema file, plus a few checks it can't express, section 7):
- nesting at most 3 `timed`/`repeat` levels; at most 400 steps in the plan; the watch payload (the
  default scale's structure plus the old keys) under 16 KB, which sets `listRounds` (14.3 D6);
  checked when the phone sends too;
- part ids are required; step ids are stable (`<repeat id>.<round>.<part id>`);
- in a team workout every part carries `who` (no silent default);
- `max` and `who` only on `part`; part ids unique;
- a `repeat` with no count must either sit inside (or contain) a `timed` with `late: end`, or say
  `"until": "athlete"`; it must be the last thing in its window and can't use `override "last"` (so
  rounds are only ever added at the end);
- an outer `repeat`'s `vary` may name a part inside an inner `repeat`; the value then holds for every
  inner round of that outer round (a ladder across sets: 3 × 12, rest, 3 × 10, rest, 3 × 8);
- `vary` may also name an inner `repeat`, giving its `times` per round ("round 1: complex × 1,
  round 2: × 2, ..."); `override` `set` may change `times` too;
- `listRounds` (how many rounds the flat list holds) is filled in by the compiler, not by the author;
- `late: end` stops only an unbounded repeat directly inside or around its window (`"stops"` names it
  when there are two); under a counted repeat it is refused, use `cut`;
- a `vary` list on a counted repeat has `times` entries; on an unbounded one it says
  `"then": "repeatLast" | "stop"`;
- the old keys are compiled from the default scale only.

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

// Added by the red team (14.3 C): units ft, yd, mi (structure only; old keys get metres);
// target "each" (distance per rep); target optional (no target = athlete ends it, nothing asked);
// group "asStep": true (a lift complex is one step); perSide, sameLoad, minReps (descriptive);
// movement {"choice": "anyCardio"}; tempo "3-1-1-0" (descriptive);
// load {"percent": 75, "of": "backSquat", "basis": "1RM" | "3RM" | "TM"};
// root: "requires": [...], each scale: "rawText", "fidelity", "approx": [reasons].

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

*What this approval covers here: a workout can carry several scales, each a full structure with
`label`, `short` and `rank`, and the result records which one the athlete picked. How the card shows
and switches them (the "Scales on one card" canvas) is deferred to Design build 17.*

Owner requirement (14 Nov): the same workout at different scales is **one card with the scales**,
not 2-3 workouts in the day. A second real corpus checked it: a class gym where the owner's testers
train (19 months, 1,723 entries; the gym's text stays in the owner's private storage). It has up to
4 scales a day (Rx, a harder competitor scale, Level 2, sometimes Level 1). Of 376 Rx/Level-2 pairs,
267 change only numbers, but 108 change movements (chest-to-bar → pull-ups), the round count or the
distance. So a scale is a whole alternative structure, not a load patch:

```jsonc
"scales": [
  { "id": "rx", "label": "Rx",      "short": "Rx", "rank": 3, "structure": { ... } },
  { "id": "l2", "label": "Level 2", "short": "L2", "rank": 2, "structure": { ... } }
]
```

- Level names belong to the programme, not the app: an Open-style workout has Foundations · Scaled ·
  Rx, a class gym Level 1 · Level 2 · Rx · Competitor, others named tracks. So `label` is free text,
  `short` (at most 5 characters) is what tight places show (the watch, a picker's neighbours), and
  `rank` orders the scales from easiest to hardest, so "harder / easier" and the picker's order never
  depend on the names.

- One workout id; `structure` alone = one scale. One scale's structure is a median 0.5 KB (largest
  5 KB); a whole row with all scales can reach 14 KB, so the watch gets only the chosen scale.
- The athlete picks the scale at START (default: the last one used at that gym); the result stores
  the scale id. This is the storage for "Rx / scaled" in section 5.
- The card shows the scale chips and only the parts that differ. Card design goes to the Workouts and
  Navigation chats, mockups to the owner first.
- **Custom scale** (owner, 14 Nov): the athlete can make their own scale and edit it freely (any number,
  swap a movement, change the rounds or the cap). It starts as a copy of a posted scale and is stored
  as `{ "id": "custom", "label": "Mine", "basedOn": "l2", "structure": {...} }`, checked by the same
  validator. It belongs to the athlete, not the gym's row: kept on the phone and in its own
  `workout_custom_scales` table (user-only, with `based_on_revision`), never written into the gym's
  row or listed as another workout. The result stores the
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
- (Red team, on all 1,723 entries of this gym: about 75 % encode cleanly, not "in full"; the rest
  are mostly feet/yards, unstated partner splits and distance per rep, fixed in 14.3 C.)
- All 34 structures encoded from 17 recent class workouts (every scale) pass the rules: E3MOM at % of
  1RM, 1:00 windows with buy-in then max calories, a growing chipper, "4 rounds each for time,
  start every 7:00", 21-15-9 with cap, AMRAP +2 ladder, buy-in + AMRAP cycles that restart, fixed-start
  segments, partner chipper with synchronized burpees.
- Import rules from this corpus: a class piece split into several entries ("0:00-24:00" and
  "on the 26:00", times scales) is merged into one workout; in a partner workout every part must say
  `who`, and the import asks when the text doesn't (the red team found "each does all" wrong for
  most partner chippers).

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
3. **Clock.** The clock starts at the START tap (or at GO once get-ready exists), never when
   HealthKit becomes ready (today up to about 5 s later). Bells use a monotonic clock that keeps
   counting while the watch sleeps; plan times are integer milliseconds in both languages. Each bell
   records what it is counted from (the start, or the end of an athlete-ended step).
4. **Late ticks catch up, quietly.** Before handling any event at time t, every boundary up to t is
   applied at its planned time. A watch that wakes 40 s late records the same splits as one on time.
   Only the entry haptic of the state you are in now plays, once; a 3-2-1 plays only if at least 3 s
   are left; passed ticks are never replayed.
5. **Earliest boundary wins.** With nested clocks (a cap around windows) the first due boundary
   applies; at equal times the outer bell applies first; an outer `cut`/`end` closes every inner
   window; `late: continue` closes nothing. Late Crown events are applied in time order during
   catch-up; a turn more than 5 s late is ignored.
6. **Caps.** `late: end` (with the 3.2 rule on what it stops) and `continue` as in 3.1. At a `continue` cap the engine stores the step
   and reps you were on.
7. **Cut parts.** When a bell ends a part with an unfinished reps or calories target, that step is
   marked `cut` and its reps asked (6.4). The parts after it in that window are marked `skipped`
   (0 s), as today. A `reps` event names its step: if the athlete says they were on a later part of
   that window, the earlier parts become done and that part becomes the cut one (re-labelled steps
   get no times). A `max` part never reached counts 0; a cut part left untouched stays "not
   entered". Reps are stored per step, not once per workout; phone edits are applied after replay.
8. **Crown**, one rule table (turns are stamped when the view receives them):

   | Situation | Crown forward |
   |---|---|
   | A part you end, outside any clock (Hyrox, for time) | done, next step; lockout 2 s from the last accepted turn (today) |
   | A part inside a window | done, next part of the window; after the last one, the automatic rest. The window end does not move. Lockout 4 s from the last accepted turn |
   | A `max` part inside a window | "I stopped": automatic rest, count asked |
   | A clocked rest or automatic rest inside a window | ignored, with the hint "Clock starts the next part" (no haptic) |
   | A clocked rest outside any window | as today |
   | A part with a `seconds` target | ignored (the clock ends it) |
   | **At every bell** | a turn that began before the bell, or arrives less than 2 s after it, is ignored with the hint, so a turn made before GO can never complete the new part. The 2 s is a constant tuned in the gym. |
   | A turn that began *before* a bell that cut an athlete-ended part | **grace**: that part is marked done at the bell time and its reps question dropped. Nothing advances. |

   The 4 s window lockout counts from the later of the last accepted turn and the last bell. A lift
   complex (`asStep`) is one step, so one turn ends the set.

   **Undo** (Crown back) works as today, except that it never crosses a bell that has already rung,
   and is refused once a bell counted from that turn is running.
   Inside a window it can undo an early finish while that window is still running. After a bell,
   fixes go through the reps question or the phone. On the done screen, "unfinish" works only if
   you finished yourself; after a clock finish (AMRAP end, last window, death-by) it is allowed for
   10 s, then only on the phone.

   These replace today's lockout after an automatic advance and the suppress flags.
9. **Unbounded repeats.** AMRAP rounds are written into the flat list up to `listRounds`; the
   engine adds more at the end (marked `extra`) if the athlete keeps going, so nobody runs out of
   list. Step ids in results never change.
10. **Ratio rest** = ratio × the actual duration of the previous sibling node (a group, a part or a
    window's actual work time), in whole seconds; never the window length.
11. **Crash replay** runs only up to the last checkpoint time, never "catching up" to the relaunch.
    The checkpoint stores the compiled plan, and a canonical plan hash is shared by Python and Swift.
12. **Get ready** (with its design, build 17). For workouts with a clock, the clock starts at GO (the end of get ready), not at
   the START tap. "Tap to go now" lets the athlete start on the gym's own 3-2-1. Get ready is an
   event, not a step.
13. **Pause, `interrupt`, `resume`** are not in build 17. Their rules are written before they enter
    the schema (14.3 E11): `interrupt` is forbidden inside `early: wait` windows; engine time = time
    minus pauses; `resume` says what a buy-in in a resumed cycle does.

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

Score types are a **closed list of presets**, not an expression language; an unknown preset shows the
per-step facts, never a guessed number: `time`, `roundsReps`, `totalReps`, `lowestReps`, `load`,
`perPiece` (metric time, distance or reps; show sum, avg, best or slowest), `windowsCompleted`
(EMOM `8/8`), `longestHold`, `maxHeight`, `distance`, `calories`, `none`. Definitions:
- a piece in `perPiece` is one round of the repeat named by `of` (default: the outermost); a cut
  piece scores what was done, flagged;
- `load` = the heaviest completed set, with its reps;
- `totalReps` counts only reps and calories of the parts in `score.parts`; metres never count unless
  named.

Options:
- `better`: `higher` or `lower`.
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

> **Deferred to Design build 17, not part of this approval** (owner, 15 Nov). This section records the
> designer's proposal so build 17's design work can start from it. What the engine needs is in
> section 4: the states (work you end, work the clock ends, rest, done), the Crown table, the bells
> and their effects, and when reps are asked. Every screen, colour, haptic pattern and wording here is
> a proposal; mockups go to the owner first (`CLAUDE.md`, `docs/DESIGN_GUIDELINES.md`). The design
> canvas "Scales on one card" holds the scale-picker and card explorations (rounds 1-8).

### 6.1 Watch states (the same in every format)

| State | Big number (the one signal) | Crown forward | Haptic on entry |
|---|---|---|---|
| Get ready (clocked workouts; build 17) | seconds to GO | nothing (tap = go now) | 3-2-1, GO |
| Work you end (Hyrox, for time) | part time, counting up, yellow (today) | done, next part | today's |
| Work the clock ends (window, Tabata, EMOM, AMRAP) | time **left** to the clock that ends it, with `LEFT` | done / "I stopped" (4.2.8) | GO if by clock |
| Rest (clocked, or early finish) | time left to GO | ignored, hint | rest haptic if by clock |
| Switch flash (1.8 s, today's) | `GO` / `REST` / `TIME` + part | grace rule | as above |
| Done | score | drives the reps question if open; back = unfinish (4.2.8) | TIME / success |

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
- **With the engine (build 17):** on the done screen (at most 3 questions, `?` on the score until the
  rest are entered) and on the phone (Fix splits gets a reps cell per step; Tabata: 8 empty cells).
  Asking in the next rest (if it is 20 s or longer) is a design option for later.
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
`owner`, `gym_id`, timestamps, and a check that `definition->>'id' = id`. It holds **29 published
rows** (20 gym, 9 personal) and **2,518 unpublished drafts** (the owner's paid programme and the
partner gym's class programming) that already use `schemaVersion: 0` and a `scales` array; only
`published = false` hides them. Nothing checks the content except `make_row.py`, and the app can
write personal rows directly. Upserts overwrite in place; there is no history. Results are JSON
files in Storage that embed the full definition they ran.

### 7.2 Proposal (all after the race, in build 17; section 14.3 F has the details)

1. **Drafts leave the library table first.** The 2,518 drafts move to an owner-only
   `workout_drafts` table. This is independent of the engine and should happen first.
2. **A v2 table with one writer**, instead of a second column. `make_row.py` and the import write v2;
   a server function writes the legacy copy into `workout_library`, compiled, **only when every scale
   is `fidelity: "exact"`**. One writer per row, so the two never drift, and old builds never receive
   a row they would run wrong. Today's **29 published rows stay as they are** until build 17 is on
   testers' phones.
3. **Schema-only checks in the database** (`pg_jsonschema`), from the one schema file in the repo
   (`schemas/workout-definition.v2.schema.json`), with a CI check that the migration's copy equals
   it. No compiler in SQL. Strict on write, lenient on read.
4. **Custom "Mine" scales** in `workout_custom_scales` (user-only RLS, `based_on_revision`).
5. **Revisions:** bumped only when the definition changes; the history table has the row's RLS; a
   rollback is a new revision; scale ids are stable. The revision is the identity; content hashes
   are never compared across languages.
6. **RLS:** public / gym / personal as today; personal writes check the user id suffix; users can't
   write the trigger's columns (column-level grants). Imports are written with the user's token, so
   they can only be personal.
7. **The library fetch pages** (Supabase returns at most 1,000 rows by default).
8. **Migration tests on production rows run as a private job**, never in the public CI.

### 7.3 Migrating the 29 published rows

A pure `upgrade(old definition)` function (Python, then Swift) labels each row **exact**, **review**
or **re-encode**:
- re-encode: the 3 Tabata rows and the 2 "3-3-3-4" rows (the owner checks which variant each is,
  from its cap);
- review: the 3 AMRAPs with listed rounds (same targets every round; the `listRounds` rule decides),
  two EMOMs that run correctly today but would move to the engine once upgraded, and one personal row
  with parts that have no target;
- the rest: exact.

None of the 29 has a station with a `seconds` target. 3 personal ids lack the user suffix (left as
they are, with a NOT VALID check). The new app also upgrades old rows on the device.

### 7.4 Results

New optional fields only: per-step `reps`, `cut`, `endedBy`, `round`, `load`, the step id, the scale
id, Rx/scaled; the definition it ran (with `structure`); `definitionRef {id, revision,
schemaVersion}`. The old `partialReps` / `repsAtCap` are still written. The result `version` stays 2
unless we prove no reader branches on it.

- **Build-15 phones drop unknown keys.** Newer phones **merge** a cloud correction instead of
  replacing the file: keyed by step id, keeping the newer embedded definition, comparing numbers by
  value (`40.0` = `40`) and treating absent and null as equal. A new result round-trips through the
  old decoder in a test.
- Old results are read as today; `upgrade` gives them a structure when a view needs one.

### 7.5 Build-17 import

The server function returns exactly a v2 definition with `rawText` and `fidelity` (and its `approx`
reasons), checked against the same schema. The confirm screen shows the structure line, the score
type, the reasons, and that a "time cap" means keep going unless the text says otherwise. The parser
was wrong on about 5 % of a regular export, so the athlete always confirms.

## 8. Watch, phone and old app versions

- **Phone → watch.** The definition travels in the `selectWorkout` application context and as a
  message. The watch gets only the chosen scale (median 0.5 KB, at most 5 KB) plus the old keys,
  within the 16 KB budget, checked when sending. No key is reused or removed: `type`/`selectWorkout`,
  `liftSelection` and `weightUnit` stay as they are.
- **Fix first, in its own commit (shared file):** `sendWorkout` in `iOS/PhoneLink.swift` (~164-173)
  rebuilds the context from scratch and keeps only `liftSelection` and `weightUnit`, so any new key
  would be wiped on every send (still true after W28). It must copy the existing context and change
  only its own keys. For the same reason an engine on/off switch lives on the watch, not in the
  context.
- **Raw pass-through.** The phone and the watch decode rows into the typed model and re-encode them
  (`iOS/WorkoutLibraryStore.swift` ~174, `iOS/PhoneLink.swift` ~158), which drops every key the build
  doesn't know. Every hop keeps the original JSON and sends it on unchanged; a golden round-trip test
  proves it.
- **Old and newer builds.** Swift ignores unknown keys but **fails on an unknown enum value**, so: add
  keys only, never a case to an existing enum (new units live inside `structure` and compile to
  metres). A reader checks `requires` (phone before Send, watch before START, crash recovery before
  replay); an unknown feature gives "Update the app to run this workout" with **"Run as stopwatch"**
  (athlete-paced, one part per line of the raw text, a `continue` cap if known, no automatic rests,
  the score typed by hand). The old keys run only when the scale is `fidelity: "exact"`.
- **Silent failures today:** an old watch that can't decode a definition drops it while the phone
  shows "sent"; a stored workout that fails to decode falls back to Partner WOD 1
  (`Watch/WorkoutSessionModel.swift` 244-256). Build 17: the watch publishes `watchCaps` (schema
  version, known features, build, `appliedWorkoutId` + `sentAt`) in its own context, the phone says
  "On your watch" only after that, and the fallback shows a message instead.
- **Crash recovery.** A crash still ends the workout and saves it (W24). The checkpoint adds
  (optional fields): the definition, the compiled plan and its canonical hash, the planner version,
  the `requires` list, the start time, and every athlete event including reps and undo. Replay runs
  only up to the checkpoint. An unreadable checkpoint is moved aside, not deleted.
- **Timing.** The clock starts at START, bells come from a monotonic clock, and the loop wakes at least
  every 200 ms in the last 3 s before a bell; the TIME haptic (about 2 s) must not overlap a following
  3-2-1. The 3-2-1 with the wrist down is checked on a device.
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
5. **Routing**: the route (old path or engine) for every built-in and all 29 published rows.
6. **Scoring**: per fixture.
7. **Old results**: build-15 results frozen as files, must decode and render unchanged; a new result
   round-trips through the old decoder.
8. **Versioning**: a definition naming an unknown feature is refused with "Update the app / Run as
   stopwatch"; a new result and a v2 row round-trip through every hop (database, phone, watch,
   result, cloud correction) byte-for-byte (the golden round-trip test); a non-`exact` scale never
   reaches an old build.
9. **Old path**: `expected/legacy.result.json` generated from today's Python `WorkoutProgress` (with
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

**The owner approved the structure and the engine on 15 Nov, with the red team's amendments.** The
schema, the Python engine and the fixtures can start now; they touch no app code.

### Build 16 (race build): no engine

Build 16 = W28 (#57) + W23 (#56) only. Nothing from this RFC ships in it, so the Hyrox race on 5 Dec
runs on build 15's workout code. Tabata and the 3-3-3-4 stay known issues for one more build. Small
optional exception: the `requires` check and the raw pass-through, only if the golden round-trip test
passes before 20 Nov; otherwise nothing.

### Build 17: the engine (W27, #31)

In order, Python first in each step:
1. **Backend groundwork:** the drafts move to `workout_drafts`; the v2 table with one writer; the
   schema file and `pg_jsonschema` check; `workout_custom_scales`; revisions; paging (section 7).
2. **Schema + validator + compiler**, with `requires`, `fidelity`, `rawText` and the 14.3 C fields,
   in Python with the fixture suite (section 10), then the Swift port and the parity tests.
3. **Engine** (`plan`, `reduce`, `replay`) with every rule of 4.2, Python then Swift, parity on the
   fixtures and on real recordings via the canonical plan hash.
4. **Watch:** a separate session model, view and checkpoint file for the engine, routed only for
   definitions that carry a v2 structure; the old path stays for everything else until a replay of
   all stored results gives the same splits, then the old clock code is deleted. The PhoneLink
   context fix; raw pass-through; "Update the app / Run as stopwatch".
5. **Migration** of the 29 rows (7.3), owner sign-off with `make_row.py --diff-live`.
6. **Scales** in the engine and the result (which scale was picked). The card design comes from Design
   build 17 (the canvas) and is built after the owner approves mockups (#61).
7. **The photo/text import** produces this structure (section 7.5).
8. Score presets in the headline, card and history; the per-window results table (design first).

### Later

Pause, `resume`, `interrupt`, resume after a crash, multi-part class days, Roxzone parts, live view on
the phone, athlete slots for relays of 3-4.

### Checked against the tickets of 14 Nov (updated after the red team)

- **Build 16** has W28 (#57) and W23 (#56) and nothing from this RFC (D4). W28 did not change
  `sendWorkout`, so the context-copy fix in section 8 is still needed, in build 17.
- **Partner gym (#60):** about 70 % of its recent class workouts run on today's app; the rest wait
  for the build-17 engine. The red team measured about 75 % of its scales as clean in this structure
  today and listed the fixes (feet, partner split, distance per rep), now in the schema.
- **One card, several scales (#61):** the data side is section 3.6 (approved); the card design is
  deferred to Design build 17.
- **Screen adapts to the movement (#62, #63):** no schema change; the engine always knows the current
  step's `movement` and `kind`.
- **Run pace pre-race (#66):** a layout change to the Hyrox run screen, not part of the engine; any
  change to the workout code before 5 Dec needs the owner's race-build decision.
- **Programming sync (#64) and scaling advice (#65):** a sync brings whole days with all scales and
  the coach's notes, kept as `rawText`, `note` and `stimulus`, checked by the same validator as the
  photo/text import. Synced rows land in the drafts table first, never straight in the library.

## 12. Risks

| Risk | Mitigation |
|---|---|
| Old builds run new workouts the wrong way | `requires` + `fidelity`; old keys only when `exact`; raw pass-through; "Update the app / Run as stopwatch" |
| Python and Swift implement a rule differently | The exact rules of 4.2 and 14.3 D-E; integer-ms plans; shared fixtures; canonical plan hash checked on real recordings |
| Two engines during build 17 | A separate session model and checkpoint for the engine; old code deleted once all stored results replay identically |
| The Crown behaves differently in clocked workouts | D2; hint on ignored turns; the 2 s bell lockout and 4 s window lockout tuned in the gym |
| Structure grows too general | 5 blocks, closed score presets, lists and progressions only; nesting ≤ 3; strict validator; conditions stay `textOnly` |
| The import misreads a workout | `rawText` always kept; `fidelity` + reasons on the confirm screen; the athlete confirms |
| Paid programming in the wrong place | Drafts out of the library table first; raw text only in private or gym rows; never in the repo |
| Late haptics with the wrist down | Data is right anyway (catch-up); device test of 3-2-1 wrist down |
| Race day, not caused by this work | A crash ends the workout (W24 saves it); a Hyrox plan turns GPS on, which indoors means an outdoor session searching for GPS; battery over 60 min is not measured |

## 13. Decisions for the owner

Approved by the owner on 15 Nov ("approve all, wait for red team results first"), re-confirmed after
the red team the same day (recorded on #55).

| # | Decision | Status |
|---|---|---|
| D1 | Adopt this structure (5 blocks + declared score, several scales per workout) as the one format for the library, the import and results, with the red team's versioning (`requires`, `fidelity`, raw text, raw pass-through), the real-data fields and the exact rules. | **Approved** |
| D2 | Crown in clocked workouts (4.2.8): forward = "I finished this part" ("I stopped" on a `max` part); ignored in a clocked rest and on a `seconds` part; never moves a clock; undo never crosses a bell; a lockout at every bell (2 s, tuned in the gym); 4 s lockout inside windows. | **Approved** |
| D3 | Reps when the clock ends a part: asked on the done screen (at most 3, `?` on the score until the rest are in) and on the phone; a `max` part never reached = 0; untouched = not entered; never blocks the clock. When to ask during rests is part of the build-17 design. | **Approved** |
| D4 | Build 16 = W28 + W23 only; the engine ships in build 17. | **Approved** (changed by the red team) |
| D5 | Old builds only ever receive rows the old engine runs exactly (`fidelity: exact`); no NULLing; today's 29 rows stay until build 17 is out. | **Approved** (changed by the red team) |
| D6 | Default scores as closed presets: Tabata = total (lowest shown); windows = sum of the `max` part; capped for time = `CAP + total reps`; EMOM = `windowsCompleted`, or heaviest load when the parts carry a load; intervals = per piece; plus `better` and the definitions in section 5. | **Approved** |
| D7 | Watch signals (REST haptic, countdown colour, get ready, 10 s buzz) and all card and watch visuals. | **Deferred to Design build 17**, not part of this approval |
| D8 | Backend after the race: drafts out of the library table, a v2 table with one writer, schema-only checks in the database, custom scales in their own table, revisions, paging. | **Approved** (changed by the red team) |

## 14. Red team review (15 Nov): amendments

*Folded into sections 1-13 after the owner's re-confirmation on 15 Nov. This section stays as the
record and as the detailed reference for the rules 3.2, 4.2, 7 and 8 point to; where the two differ,
sections 1-13 win.*

The owner asked a few engineers to challenge this structure, so it survives any future workout. Four
reviewers worked independently, each with the RFC and the code but not the others' conclusions:

- schema evolution and backend;
- watch runtime;
- a "format breaker" (coach and engineer);
- a data engineer who built a throwaway prototype of the schema, the validator and a parser, and ran
  it over every draft in the library.

Then each one challenged the other three. This section is the result. Nothing in sections 1-13 has
been edited yet: the amendments below are proposals for the owner, to be folded into the RFC once
the owner agrees.

**Overall: the structure holds; it needs change, not a redesign.** The five blocks, the
`early`/`late` window rules, the declared score and the plan/reduce/replay engine all stood up to
real data and to invented hard cases. What failed:

- versioning (old apps would silently run new workouts the wrong way);
- a dozen loose rules that two programmers would implement differently;
- a few missing units and fields that real programming uses every week;
- the build-16 timing.

### 14.1 Verdict per area

| Area | Verdict | In one line |
|---|---|---|
| Schema evolution and backend | **Needs change** | The "lenient decode → run the old keys" fallback contradicts "bump `schemaVersion` → refuse", and both miss a new key inside a known node. Needs a feature list, a fidelity flag, one writer per row, and the drafts out of the library table. |
| Watch runtime | **Needs change** (2 blockers) | In build 16 the clock starts when HealthKit is ready, not at START (0-5 s late). Removing today's post-bell lockout lets a turn begun before GO complete the new part. Nine further rules (clock source, nested bells, `late: end`, ratio rest, step ids, crash replay) must be exact before any Swift is written. |
| Formats | **Needs change** | 72 invented shapes: 30 clean, 26 awkward, 16 impossible (5 of them impossible by design). Weighted by real data, most gaps are rare; the ones that matter are listed in 14.3 C. |
| Real data (the hard test) | **Holds, needs change** | About 77 % of 3,038 real scales encode faithfully today, about 99 % at least approximately, about 1.2 % not at all. Four small additions take it to about 94 %. |
| Build-16 plan (D4) | **Needs change** | Three of four reviewers recommend the alternative: the engine moves to build 17. |

### 14.2 The coverage test on real data

**What was tested.** All 2,518 unpublished draft rows, which hold 3,038 scales. 1,315 come from the
owner's paid program and 1,723 from the partner gym's class programming. The data was read only;
nothing was copied into the repo.

A prototype was written in the session's scratch space and not committed. It has three parts:

- a validator with every rule in 3.2;
- a compiler to steps;
- a best-effort parser from each scale's raw text, helped by the earlier classifier.

Resume and interrupt were counted as *not available*.

| | Scales | Clean | Awkward | Impossible | Parser failed |
|---|---|---|---|---|---|
| All | 3,038 | 79.4 % | 18.5 % | 1.1 % | 1.0 % |
| Owner's program | 1,315 | 85.5 % | 11.9 % | 1.1 % | 1.5 % |
| Partner gym | 1,723 | 74.8 % | 23.5 % | 1.0 % | 0.6 % |

**Hand check.** 152 scales were read by hand: a random 80, a fresh random 40 after the parser fixes,
and 32 targeted non-clean cases. The parser was wrong on about 5 % of scales even on this regular
export. A photo or free-text import will do worse.

**Sample-corrected estimate:**

- clean about 77 % (range about 68-80 %);
- awkward about 22 %, of which 3-4 points come from the source text itself being ambiguous;
- impossible about 1.2 %, falling to about 0.5 % once `resume` and `interrupt` ship.

The partner gym is only 75 % clean. Section 3.6 ("passed in full") is optimistic.

**Clean rate by format:**

| Clean rate | Formats |
|---|---|
| 87-98 % | repeat efforts, station rotation, intervals, max tests, strength sets |
| 77-83 % | untimed quality work, rounds for time, EMOM, each round for time |
| 71-73 % | chippers, AMRAPs |
| About half | AMRAP ladders, steady distance |
| 15 % | AMRAP cycles split by rests |

**Top reasons a scale was not clean** (number of scales):

| Reason | Scales | Fix |
|---|---|---|
| Distance in feet (plus yards 9, miles 4) | 223 | C1 |
| Partner split not stated (the "each does all" default is wrong for most partner chippers) | 104 | C3 |
| Distance per rep (N shuttles of a fixed length) | 90 | C2 |
| Part with no target (skill, mobility) | 61 | C5 |
| Lift complex: each rep would become its own Crown step | 42 | C4 |
| Set constraints with no field (same load every set, "N or more" reps, per side) | 26 | C6 |
| Score not stated for fixed-start segments | 19 | C8 |
| Open machine choice; tempo only in the movement name | 17 + 17 | C7, C9 |
| "One set per window, or all sets in each window?" (the source is ambiguous) | 11 | B |
| Needs `resume` / `interrupt` (planned) | 11 + 8 | E11 |
| % of 1RM on a complex: of which lift? | 8 | C10 |
| Truly impossible by design: a penalty on each break, stopping at a cumulative rep total, a target equal to an earlier window's result | 7 + 6 + 6 | B (raw text only) |

**Held up well:**

- men's/women's number pairs (41 % of scales);
- % of the lift itself;
- rest inside a for-time piece;
- buy-in then max in the time left (up to 12 pieces);
- running-clock rotation;
- death-by, Tabata and 1:1 rest;
- build to a max;
- AMRAP cycles that restart.

**Facts measured:**

- **Size.** One scale's structure: median 0.5 KB, p95 1.8 KB, max 5.0 KB. Whole row with all
  scales: p95 7.5 KB.
  - 5 rows break 16 KB (up to 23.9 KB), all because of the compiled old flat list. With the old
    keys left out, none break it.
- **Steps.** Median 12, p95 60, max 241.
  - At about 100 bytes per compiled segment, 400 steps is about 40 KB, so the 400-step and 16 KB
    limits contradict each other.
- **Nesting.** 40 scales reach depth 3; none go deeper.
- **Scales on one card.** Of 520 scale pairs, 394 change numbers only, 124 change movements and 2
  change rounds or the clock. A scale must be a whole structure, as 3.6 says.
- **Men's and women's standards.** No scale has men and women doing different movements.
- **Multi-piece entries.** 124 (4 %), all of which fit one body with `combine`.

**The 10 hardest real shapes** (paraphrased):

1. AMRAP cycles split by rests, with the count continuing across cycles.
2. The same with a buy-in in each cycle (`resume` does not say what the buy-in does).
3. Unequal windows with a ladder continuing across them, under a cap.
4. Windows repeated until a cumulative max-rep total is reached, under a cap, with a longer last
   window.
5. The next window's target equals the count reached in the previous one.
6. A long machine piece with a lift every N minutes (interrupt).
7. A penalty movement on every break.
8. A pyramid chipper that grows each round.
9. "Until failure" over an explicit rising list of windows.
10. Per-round loads given in a separate men's/women's legend.

### 14.3 Amendments

**Severity:**

- **B** = blocker, before the owner approves D1.
- **M** = must-fix, before the schema is frozen for the build-17 import.
- **S** = should-fix.

#### A. Versioning and extension (B)

1. **`schemaVersion` is a major version.**
   - Absent = 1 (today's rows).
   - `0` = a draft, never runnable by any app.
   - `2` = this RFC.
   - It is bumped only for a change that old readers would misread even with `requires` (below).
2. **`requires: [feature, ...]` at the root**, computed by the compiler and never typed by hand. It is
   the union over all scales.
   - Any field or node with a timing or score meaning that is not in the frozen v2 list gets a
     feature name, for example `resume`, `interrupt`, `slots`, `distancePerRep`.
   - A reader refuses a workout naming a feature it doesn't know. The phone checks before Send; the
     watch checks before START.
   - The list is saved in the checkpoint, and crash recovery refuses an unknown feature.
   - This replaces "any new timing field bumps `schemaVersion`" (7.2), which would lock build 16 out
     of every later workout.
3. **Two kinds of field.**
   - *Engine fields* change timing or the score. They are in the frozen v2 list or named in
     `requires`.
   - *Descriptive fields* are `note`, `rawText`, tempo, RPE, `x-*` keys and labels. They never cause
     a refusal, and every reader passes them through unchanged.
   - Unknown values of cosmetic enums decode as "unknown" instead of failing the whole document.
     `score.type` and `late` are engine fields, not cosmetic.
4. **No silent fallback.** Section 8's rule ("if a build-16 watch can't read `structure`, run the old
   keys") is replaced. The old keys are a lossy compile, so they run only when the compiler marked
   the scale `fidelity: "exact"` (B2).
   - Otherwise the watch says "Update the app to run this workout", and offers **"Run as
     stopwatch"**.
   - A stopwatch run is athlete-paced: one part per line of the raw text, a `late: continue` cap if
     one is known, no automatic rests, no reps question, and the score typed in by hand.
   - The same rule covers an unknown node type: it falls back to an athlete-paced part showing the
     raw text, never to a guess.
5. **Raw pass-through.** The phone and the watch decode rows into the typed model and re-encode them
   (`iOS/WorkoutLibraryStore.swift` ~174, `iOS/PhoneLink.swift` ~158), and so does the definition
   embedded in a result. Each of these permanently drops any key the build doesn't know. Every hop
   must keep the original JSON and send it on unchanged. A round-trip golden test proves it.
6. **An unknown key inside a known node** (for example `resume` on a `repeat` read by build 16)
   decodes silently in Swift today. A1-A5 handle it: the compiler lists it in `requires`, so the
   reader refuses it.

#### B. Raw text and fidelity (B for the import)

1. **`rawText` is mandatory** on every scale that was imported, synced or drafted. It is optional
   only for workouts written by hand in the repo.
   - It stays on the phone and in the result; the watch gets only a "has notes" flag.
   - It does not count against the watch's 16 KB.
   - The card can always show what the coach wrote.
2. **`fidelity: "exact" | "approx" | "textOnly"` per scale**, plus `approx: [reasons]` (for example
   `"partnerSplitGuessed"`, `"scoreGuessed"`, `"conditionIgnored"`).
   - The confirm screen of the import shows the reasons.
   - Shapes that are impossible by design are stored as `textOnly` and run as a stopwatch (A4):
     penalties on breaks, cumulative-total stops, targets taken from an earlier result.
   - The backend's proposed `legacy: "exact"` flag is the same field.

#### C. Schema gaps found in real data (M, in the frozen v2 list)

The scale counts below come from 14.2.

1. **Distance units `ft`, `yd`, `mi`** (236 scales). They live only inside `structure`. The old keys
   get metres, so no case is added to an old enum (section 8).
2. **Distance per rep** (90): `"target": {"value": 10, "unit": "reps", "each": {"value": 25, "unit": "ft"}}`.
3. **Partner split** (104).
   - In a team workout, every part must carry `who`. There is no silent default; the import asks.
   - The names for 3-4 athlete slots are reserved in the feature list (`slots`). No fields are
     added until someone designs them, so no half-designed meaning gets frozen.
4. **A complex counts as one step** (42): `group` gets `"asStep": true`. One Crown turn ends the whole
   set, and the `load` on the group applies. This also stops the 4 s lockout from silently dropping
   real turns on 1-rep parts.
5. **`target` is optional** (61). No target means the athlete ends the part and nothing is asked.
6. **Set constraints** (26), descriptive only:
   - `perSide: true`, where reps are per side and the step count is unchanged;
   - `sameLoad: true`;
   - `minReps`.
7. **Open machine choice** (17): `"movement": {"choice": "anyCardio"}` as well as a list.
8. **Score fixes.**
   - Score types are a closed list of presets, not an expression language. An unknown preset shows
     the per-step facts, never a guessed number.
   - Add:
     - `better: "higher" | "lower"`;
     - `windowsCompleted` (EMOM `8/8`, already in 5's table but missing from the types);
     - `longestHold`;
     - `maxHeight`.
   - Define:
     - **Piece.** A piece in `perPiece` is one round of the repeat named by `of` (default: the
       outermost repeat).
     - **Cut piece.** A cut piece scores what was done, flagged.
     - **`load`.** `load` = the heaviest set completed, with its reps.
     - **`totalReps`.** `totalReps` counts only reps and calories of the parts named in
       `score.parts`. Metres never count unless named.
9. **Tempo** (17): a descriptive `tempo: "3-1-1-0"` on a part. It is shown, not timed.
10. **% of a named lift** (8): `"load": {"percent": 75, "of": "backSquat", "basis": "1RM" | "3RM" | "TM"}`.

#### D. Rules two programmers would implement differently (M)

1. **`late: end` names what it stops.**
   - It may stop only an unbounded repeat directly inside or directly around its window.
   - If there are two candidates, it must say `"stops": "<repeat id>"`.
   - Under a counted repeat it is refused; that case is `cut`. Without this rule, a "death-by, at
     most 20 minutes" written with `times: 20` keeps going after the missed minute.
2. **Ratio rest** = ratio × the actual duration of the previous *sibling* node, in whole seconds. That
   node is a group, a part or a window's actual work time; it is never the window length. In the
   data, all 15 ratio rests mean the whole previous round, which this rule gives when the round is a
   group.
3. **`vary` lists.**
   - On a counted repeat, the list length must equal `times`.
   - On an unbounded repeat, a list needs `"then": "repeatLast" | "stop"`.
   - A bare number changes `value` and scales `valueF` in the same ratio, rounded. Give
     `{"value", "valueF"}` pairs to set both.
4. **Part ids are required.** Step ids are stable: `<repeat id>.<round>.<part id>`. Extra AMRAP
   rounds are appended and marked `extra`, so step numbers never move and old readers keep working.
5. **The default `late` for a "time cap" is `continue`** (today's behaviour). The import must say so
   on the confirm screen.
6. **`listRounds` rule** (compiler, stored, compiler version stamped):
   - enough rounds to fill the window at 10 s per part;
   - then capped so that the watch payload (default scale's structure + old keys) fits 16 KB.
   - The 400-step limit becomes "≤ 400 steps in the plan". The engine adds rounds itself, so only
     the payload is limited.
7. **Old keys are compiled from the default scale only**, and the root `structure` always equals the
   default scale.

#### E. Watch runtime (B for E1-E2, M for the rest)

1. **The clock starts at the START tap**, or at GO once get-ready exists. It never starts when HealthKit
   becomes ready: today `beginRunning()` (`Watch/WorkoutSessionModel.swift` ~600) runs up to about
   5 s later. The delay is logged but never moves a bell.
2. **A lockout at every bell.**
   - A Crown turn is stamped when the view receives it, not when the model handles it.
   - A turn that began before the latest bell, or arrives less than 2 s after it, is ignored with
     the hint.
   - Grace (4.2.8) applies only to a turn that began *before* the bell.
   - The 4 s window lockout counts from the later of the last accepted turn and the last bell.
3. **Clock source.**
   - Boundaries use a monotonic clock that keeps counting while the watch sleeps, not `Date()`.
     Otherwise a time correction mid-Tabata makes one rest 7 s and every later bell early.
   - Wall time is used only for results and display.
   - All plan times are integer milliseconds, in both languages.
4. **Each bell names what it is counted from** (the workout start, or the end of an athlete-ended
   step).
   - An undo is refused once a bell counted from that turn is running or has rung.
   - Routing's "start-anchored" means every bell counts from the start.
   - Optional `startAt` on a `timed` fixes a window to the start even after an athlete-ended buy-in.
5. **Nested clocks.**
   - `late: continue` closes nothing.
   - At equal times, the outer bell applies first.
   - Section 4.2.4 is reworded to say this.
6. **Crash replay.**
   - Replay runs only up to the last checkpoint time, never "catches up" to the relaunch. A crash at
     3:25 of an EMOM must not invent 17 cut minutes.
   - The checkpoint stores the compiled plan, not just its hash.
   - A canonical plan (integer ms, `40` never `40.0`) is hashed by both Python and Swift, so real
     recordings check parity.
7. **Late Crown events** are applied in time order during catch-up. A turn more than 5 s late is
   ignored.
8. **Reps after a bell (D3).**
   - A `max` part that was skipped counts 0. A cut part left untouched stays "not entered".
   - Steps re-labelled by "I was further" get no times.
   - The done screen asks at most 3 questions, in a set order, and shows the score with a `?` until
     the rest are entered on the phone.
   - Phone edits are applied after replay, not as events.
9. **Crown table additions.**
   - A part with a `seconds` target ignores the Crown.
   - A clocked rest *outside* any window keeps today's behaviour.
   - "I stopped" on a `max` part in an `early: next` window goes to the next step, since that window
     has no automatic rest.
10. **3-2-1 timing.** The loop wakes at least every 200 ms (today's rate) in the last 3 s before a
    bell. The TIME haptic (about 2 s) must not overlap a following 3-2-1.
11. **Write the rules for `interrupt`, `resume` and pause before they appear in the schema sketch.**
    - `interrupt` is forbidden inside `early: wait` windows.
    - Engine time = time minus pauses.
    - `resume` says what a buy-in in a resumed cycle does.
12. **Race isolation**, if any engine work reaches a race build:
    - a separate session model, view and checkpoint file;
    - an engine switch kept on the watch (a switch in the phone↔watch context would be wiped by
      every `sendWorkout`);
    - a CI check that the Hyrox-path files are unchanged.

#### F. Backend (M, after the race)

1. **Drafts leave `workout_library`.**
   - The 2,518 drafts (the owner's paid program and the partner gym's text) sit today in the
     production library table. Only `published = false` hides them, and they would fail the
     validation trigger.
   - They move to an owner-only `workout_drafts` table.
2. **One table, not two columns, for v2.**
   - Replace the `definition_v2` column with a v2 table (or view) that only builds able to refuse
     read.
   - A v2 row is copied into the legacy table, compiled, only when every scale is
     `fidelity: "exact"`.
   - `make_row.py` and the import write v2; a server function writes the legacy copy. One writer per
     row, so the two can never drift.
   - Today `make_row.py` ~176-182 upserts only `definition`, so `definition_v2` would go stale after
     any re-upload.
   - This also replaces D5's NULLing: build 15 simply never gets rows it would run wrong.
3. **The database checks the schema only** (`pg_jsonschema`). There is no compiler in SQL. A CI check
   confirms that the schema copy in the migration equals the repo file. Be strict on write and
   lenient on read.
4. **Custom "Mine" scales** go in `workout_custom_scales` (user-only RLS, `based_on_revision`), not as
   library rows. Today `id` is the global key and the library fetch would list Mine as another
   workout.
5. **Revisions.**
   - The revision is bumped only when the definition changes.
   - The history table has the same RLS as the row.
   - An undo writes a new revision; it never decrements one.
   - Scale ids are stable.
6. **Personal writes check the id suffix**, so a user can't take a future gym id.
7. **The library fetch pages.** Supabase returns at most 1,000 rows by default, so a programming sync
   would silently truncate it.
8. **Migration tests on production rows run as a private job**, never in the public CI (test 4,
   gate G2).
9. **Result merge.**
   - It is keyed by step id, not by array index.
   - It keeps the newer embedded definition.
   - It compares numbers by value (Python `40.0` = Swift `40`) and treats absent and null as equal.

#### Considered and not taken

- An open score expression language (weights, tie-break formulas). Four implementations would
  drift. The presets plus `better` cover all but a handful of real scales.
- Athlete-slot fields and staggered rotation now. 0 real scales use them, so only the name is
  reserved (C3).
- "Accumulate a hold" (0 real scales; it would need a second meaning for the Crown).
- Geometric `vary` and "add load until failure" (0 real scales).
- Conditions: stop at a total, a target from an earlier result, a penalty on a break (19 scales,
  0.6 %). These are `textOnly` (B2) and stay out of the engine.

### 14.4 Versioning policy (one page)

1. Writers are strict and readers are lenient only about descriptive fields.
2. Anything with a timing or score meaning is either in the frozen v2 list or named in `requires`.
3. Unknown feature → refuse with "Update the app" and offer "Run as stopwatch". Never run the old keys
   unless `fidelity` is `exact`.
4. Never add a case to an enum an old build decodes strictly. New units and kinds live inside
   `structure` and are compiled to old values.
5. Every hop (database → phone → watch → result → cloud correction) passes unknown keys through
   unchanged. A golden round-trip test enforces this.
6. `schemaVersion` changes only for a break that `requires` cannot express. That should be never.
7. One writer per row. The revision is the identity. A rollback is a new revision.

### 14.5 What changes in the owner's decisions (section 13)

| # | Change? | New recommendation |
|---|---|---|
| D1 | **Amend** | Yes to the structure, on condition of A (versioning), B (raw text, fidelity), C1-C5 and D. |
| D2 | **Amend** | As written, plus E2 (lockout at every bell; grace only for a turn begun before the bell), E9 (seconds parts ignore the Crown; rests outside windows as today). |
| D3 | **Amend** | As written, plus E8: a skipped `max` = 0, at most 3 done-screen questions with `?` on the score, and distance, calories or time asked when the score needs them. |
| D4 | **Change** | **Build 16 now with W28 and W23 only; the engine in build 17.** The Crown rules aren't right on paper yet and need gym tuning; there are 8 days between freeze and race; and the slice touches the Hyrox session model. Build 16 may carry the `requires` check and the raw pass-through only if the golden round-trip test passes before 20 Nov. Otherwise it carries nothing from this RFC. |
| D5 | **Change** | No NULLing of `definition`. Build 15 never receives rows it would run wrong (F2). |
| D6 | **Amend** | Defaults stay, as presets, plus `windowsCompleted` (8/8), `better`, and C8's definitions of a piece, a load score and what counts in totals. |
| D7 | Small change | (b), (a), (c) and (d) move together to build 17. Starting the clock at START (E1) is required whenever the engine ships. |
| D8 | **Change** | F1-F9: drafts and custom scales in their own tables, a v2 table instead of a second column, schema-only checks in the database, revision rules, the id-suffix check and paging. |

### 14.6 Facts in this RFC that are wrong

- The library has **29** published rows (20 gym, 9 personal), not 25, plus 2,518 unpublished drafts
  that already use `schemaVersion: 0` and a `scales` array.
- Migration (7.3):
  - None of the 29 has a station with a `seconds` target.
  - The 3 "AMRAP ladders" have the same targets every round. They need review because of
    `listRounds`, not because of a ladder guess.
  - Two EMOMs that work today (every 60 s and every 90 s) would move to the new engine once
    upgraded, so they need review too.
  - Which 3-3-3-4 variant a row is can only be read from its cap. The owner must check it.
  - One personal row has parts with no target (C5).
  - 3 personal ids lack the user suffix.
- "Largest pair about 6 KB" (3.6): the full corpus has a 14.2 KB structure (3 scales) and rows up to
  23.9 KB with old keys.
- The 400-step limit and the 16 KB budget contradict each other (14.3 D6).

---

## Appendix A: the team review

*History of the first review (14 Nov). Where it differs from section 14 or the folded text, those win.*

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
| `autoSuppressedStart`, `capSuppressed`, Crown lockout after an automatic advance | the Crown table (4.2.8) in `reduce` |
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
