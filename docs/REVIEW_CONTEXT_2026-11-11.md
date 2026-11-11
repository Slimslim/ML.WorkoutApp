# Context for a reviewer (state on 2026-11-11)

Paste this into a review session that started before these decisions. Read with `CLAUDE.md`,
`docs/MVP.md`, `docs/USER_STORIES.md` (W17-W23), `docs/LABELS.md`, `docs/RECORDING_PLAN.md`.

## Goal and direction
- The product goal: the watch follows the planned workout by itself. Phase 1 switches to the next
  movement, phase 2 recognises the movement, phase 3 counts reps. Recordings are training data;
  every detector is scored against labelled sessions (`tools/score_labels.py --record`,
  `data/eval/history.jsonl`). The Crown marks the **end** of a movement, never the start.
- Corrections change **the recording only, never the planned workout**. Cloud corrections:
  `<id>.original.json` backup, edited `<id>.json` with a later `editedAt`, the phone takes it (W17).

## MVP (docs/MVP.md)
- 4-5 testers, one stable TestFlight build, Nov 23 - Dec 6, invites Nov 20.
- New code only: **strict press and bench press rep counting** (`LiftType` strictPress/benchPress,
  `countsReps`; shared `Models.swift`, separate commit), and **W22 practice workout + W23
  permission banner** (mockups in `docs/concepts/first-workout.html`, awaiting owner approval).
- Why W22/W23: the first tester's HR prompt came mid-run (`WorkoutManager` requests HealthKit
  authorization at workout start). He dismissed it, so no HR and no steps were recorded, and he
  never found the Crown, so the whole workout was one part.
- Rule for now: barbell lift piece -> Lifting mode; metcon -> Workout mode. No supersets.

## Data model (Supabase)
- Recordings and results are private per user (`uploads/<user id>/...`).
- `supabase/migrations/20261110000000_gyms.sql` (written, **not yet run**): `gyms`, `gym_members`,
  `workout_library.gym_id`; a row is public (owner and gym null), gym programming (gym_id), or
  personal (owner). RLS decides visibility; the app fetches all rows it may read.
  Known gap: the library cache is not cleared when the signed-in user changes.
- Gym programming is never committed to the repo (it is entered in the DB from screenshots).

## Later (W21, docs/RECORDING_PLAN.md)
- Recording follows the plan: Olympic lifts 200 Hz + 800 Hz with bar speed/height/catch (and
  `LiftAnalyzer` without the homing requirement: 6 of 20 snatches analysable at 100 Hz today),
  strength lifts reps + speed, runs GPS outdoors, ergs low rate without GPS, metcon 100 Hz, rest low
  rate. Apple Fitness must show **one workout per session**.

## Open PR
- Branch `claude/amazing-fermi-2lev62`: labels, eval tools, switch detector v0/v1, W17 cloud
  corrections, gyms migration, MVP doc, these mockups. CI green before this commit.
