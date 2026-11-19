# Results page: insight rules (owner, 19 Nov)

**Goal until the race (5 Dec):** after each workout, a tester has a "that's useful" moment and records
the next one because of it. First test: tester C records a Free Workout, sends the WOD photo, we
attach the workout by hand (Data chat), and she opens a result with real insights.

Uses the current design (`docs/LIVE_WORKOUT_OVERVIEW.md` hero card). This file decides **what the
page is allowed to say**. Stories: W46-W48 in `docs/USER_STORIES.md`.

## 1. Page order

1. **Score** (big): rounds + reps, or final time, or "CAP + reps", with Rx / Scaled.
2. **Vs last time** (one line under the score), only when comparable (section 2).
3. **Up to 3 insights**, each with a number in it; at most one "next time" cue.
4. Splits table (as today).

**Silence beats an unsupported insight.** With nothing that passes the rules, show no insight block.

## 2. Vs last time

| Case | Line |
|---|---|
| Same workout id, same scale and loads, both finished | "2:04 faster" / "0:38 slower" |
| AMRAP, same scale and loads | "+12 reps" / "-1 round" (rounds+reps as total reps) |
| One finished, one capped | the finish wins: "Finished (last time capped at 12:00 + 84)" |
| Both capped | compare reps at the cap: "+9 reps at the cap" |
| Different scale or loads | "Different scale, not compared" |
| No earlier result | nothing |

Needs: workout id, Rx/Scaled and loads on the result (W19 #39 for Rx/Scaled; loads are in the
definition today). **Measurable today:** yes for time and rounds+reps; Rx/Scaled only if entered.

## 3. Data honesty filters (applied before any insight)

- A Crown segment = work + transition + any rest, with no reps. Say **"segment time"**, never
  "speed" or "pace", and never give a cause.
- Ignore a segment < 5 s or > 3x the median of its movement; if one exists, show "Check your timing
  on round N" instead of an insight about it.
- Heart rate lags 20-40 s: trends over whole rounds or halves only; never judge one short movement.
- Rest segments are never in an insight's numbers.

## 4. Insights per workout type

Each rule: what it says, the data it needs, and whether it is measurable in the app today.

### AMRAP and rounds for time
| # | Insight | Data | Today |
|---|---|---|---|
| A1 | **Biggest drift:** the movement whose segment time **cost the most extra seconds** vs its own round 1, summed over the rounds (owner, 19 Nov: ranking by % picked a short movement that felt steady). Show the seconds and the %: "Bike: 1:29 in round 1, then 1:48-1:51 (+22 %), 1:41 in total." Never compares two movements. | Crown segments per round | Yes |
| A2 | **What stayed steady:** movements within ±5 % of their round-1 time across rounds. "Step-ups and wall balls held within 5 %." | same | Yes |
| A3 | **Into the score:** the drift's extra seconds, summed, divided by the average round time. "That drift added 1:41, about half a round." | same + round time | Yes |
| Cue | One "next time" cue, only from A1: "Next time: hold the bike nearer 1:30." | A1 | Yes |

### For time and chippers
| # | Insight | Data | Today |
|---|---|---|---|
| F1 | **Second half vs first half** (work time only, rests excluded): "Rounds 3-4 took 2:54 longer than rounds 1-2 (+22 %)." | Crown segments | Yes |
| F2 | **Biggest drift per movement** (as A1: most extra seconds, % shown) when the workout has rounds. | same | Yes |
| F3 | **Movement vs your normal:** only with 3+ earlier results of the same movement and load. | history | Not yet (few results) |
| F4 | **Total transition time:** needs work/transition split. | motion or a second Crown turn | Not yet (Crown segments include transitions) |
| F5 | **Run fade:** run segment times or pace per run, first vs last. | runs with a target distance | Yes for runs with a target |

### Ladders (21-15-9, 2-4-6 ...)
| # | Insight | Data | Today |
|---|---|---|---|
| L1 | **Out of proportion:** each segment's time vs its share of reps (e.g. 21 reps = 46.7 % of the movement's 45). Flag a segment more than 20 % off its share. "Thrusters 9: 1:10, expected about 0:50 from your 21 and 15." | Crown segments + target reps | Yes |

### Runs
| # | Insight | Data | Today |
|---|---|---|---|
| R1 | **Started hard, then faded:** first run vs the median of the rest, > 8 % faster then > 8 % slower. Shows the splits. | run segments with target or pedometer distance | Yes (pace from target distance) |

### EMOM and Olympic lifting
| # | Insight | Data | Today |
|---|---|---|---|
| E1 | **When each rep happened inside the minute**, by load: a strip per minute with a dot per rep, and the rest left. "Rep 2 at 0:10 at 95 lb, 0:35 at 140 lb; rest left 48 s → 15 s." (owner, 19 Nov: the favourite view) | rep times per minute (motion) | Not in the app: rep detection runs only offline (labels) |
| E2 | **Bar speed by load**, paired with the bar path: "Speed dropped 15 % at 80 kg." Never "you're fatigued". | Lifting analysis inside a workout | Not yet (#35, strength sets in a workout) |
| E3 | **Heaviest successful load** and the loads ladder. | definition loads + score | Yes |

## 5. Never shown
Calories or effort scores; comparisons between different movements; rep-based explanations;
heart-rate zone judgments without a measured max heart rate; trends from fewer than 3 comparable
workouts.

## 6. Later (roadmap note)
Telling a pacing limit from a strength limit needs set and rep patterns: touch-and-go sets point to an
aerobic limit, singles with long rests to a strength limit. EMOM singles are planned. That is why rep
detection matters later (`docs/LABELS.md`, #43).
