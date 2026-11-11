# Recording follows the plan (what the watch measures, per planned movement)

Owner discussion of 2026-11-09/10, after the power snatch EMOM and Freedom. Story: **W21**
(`docs/USER_STORIES.md`, Later). Nothing here is built yet; this is the reasoning and the open
questions, so the build starts from the same place.

## The problem

Today the athlete picks a mode up front and the whole session is recorded one way:

| Mode | Sensors | Analysis |
|---|---|---|
| Workout (metcons) | device motion 100 Hz, HR, pedometer, Crown/segment events | splits, HR, (offline) switches and reps |
| Lifting | device motion 200 Hz + raw accel 800 Hz (`CMBatchedSensorManager`) | `LiftAnalyzer`: peak pull speed, max bar height, catch height, drop under the bar; `RepCounter` |

On 2026-11-09 the power snatch EMOM (every 1:00 x 10, 95 -> 145 lb) was programmed as a workout,
so it was recorded in Workout mode. Every rep is visible in the 100 Hz data (20 good reps and the
miss), but `LiftAnalyzer` could analyse only **6 of 20** snatches: it needs a still "homing" moment
before the pull, and 100 Hz is below what it was tuned for. Those six already hint at what the
athlete wants to see: max height ~1.41 m at 125 lb down to ~1.28 m at 145 lb (not verified).

The owner's view: that EMOM was a lifting piece inside a class, not a metcon. The plan already says
what comes next, so the watch should measure each part the way that part needs, without the
athlete choosing a mode.

## Rule for now (MVP)

- A **barbell lift piece** (sets x reps x weight, EMOM of singles) -> **Lifting** mode.
- A **metcon** (score is time or reps under a clock) -> **Workout** mode.
- One Fitness workout per mode used.

## Profile per planned movement (target, W21)

| Planned part | Motion | Other sensors | What the athlete gets |
|---|---|---|---|
| Olympic lift (snatch, clean, jerk) | 200 Hz + 800 Hz accel | HR | per lift: peak pull speed, max bar height, catch height, made / missed |
| Strength lift (deadlift, press, bench, squat) | 200 Hz | HR | reps per set, speed per rep (velocity-based training) |
| Run outdoors | 100 Hz or lower | **GPS on**, pedometer, HR | distance, pace, route |
| Run indoors / treadmill | 100 Hz or lower | pedometer, HR, GPS off | distance from steps (calibrated) |
| Erg / bike (row, ski, air bike, bike erg) | low rate (25-50 Hz) | HR, GPS off | stroke / cadence rate, time |
| Metcon station (wall balls, burpees, pull-ups, ...) | 100 Hz | HR | splits now; switches and reps later (phases 1-3, `docs/LABELS.md`) |
| Rest / transition | low rate | HR | recovery HR; must still see the next set start within 1 s |

- **GPS:** turned on just before a planned run (so the fix is ready when the athlete walks out),
  off for movements that stay in the gym. A route only when there was an outdoor run.
- **Rest at a low rate** saves battery, but the eval needs the real start of the next set (the
  Crown marks the end of a movement, not the start). So the rate drops only after the set is clearly
  over, and comes back up on the first movement.

## Requirements the owner set

1. **Apple Fitness stays clean: one session is one workout** in Fitness/Health. One activity type,
   never one workout per part or per lift; HR and calories continuous across the session.
2. **No data lost at a switch:** no gap over 0.1 s in the CSV or the result when the profile changes.
3. **Battery and size measured** on a 60-min session; no worse than today's Workout mode
   (~30 MB per 40 min of CSV).
4. **One start screen** later: the program says what comes next (lift pieces included), so there is
   one START, not two modes.

## Work it needs, in order

1. Lift pieces in the program (sets x reps x weight) and recorded as lifts (no supersets for now).
2. `LiftAnalyzer` without the homing requirement (find the start of the pull from the motion), and
   checked at 100 Hz against the labelled snatches (`data/labels/2026-11-09-power-snatch-emom.json`,
   20 reps, and Freedom's 21 snatches).
3. Profile switching on the watch in one `HKWorkoutSession` (sensor rates and GPS change, the
   session does not).
4. Battery / size test, then a gym test, before it replaces the two modes.

## Open questions

- Can `CMBatchedSensorManager` (800 Hz) start and stop inside a running workout session without a
  gap, and what does it cost in battery?
- Which Fitness activity type for a mixed session (lift + metcon + run)? Today the watch maps
  mixedCardio, crossTraining, functionalStrengthTraining, HIIT, running; others fall back to
  crossTraining.
- Is a low rate during rest good enough to see the first rep of the next set within 1 s?
- Indoor run distance from steps: calibrate per athlete from outdoor runs?
