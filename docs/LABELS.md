# Ground-truth labels (training and test data)

**Goal:** the watch moves to the next movement by itself when the athlete does (wall balls → run:
the set is marked and the run starts without a Crown turn), and later counts reps. Every detector
for that is judged against what really happened in the owner's recorded sessions. A label file
says what really happened; `tools/score_labels.py` scores detectors against all of them.

## Where things live

| What | Where | In git? |
|---|---|---|
| Recordings (watch CSV at 100 Hz, result JSON, lift JSON) | Supabase Storage, bucket `uploads`, `<user id>/Debug/…`, `Workouts/…`, `Lifts/…` (uploaded by the phone) | **No** |
| Local copies for scoring | `data/cache/<label id>/` (`tools/fetch_sessions.py`) | No (git-ignored) |
| Labels | `data/labels/<label id>.json` | Yes |
| Older sessions with prose notes | `data/raw/*/README.md` (recordings committed before this) | Yes (to be converted) |

Recordings stay out of git from now on (`data/raw` is already 127 MB). Paths in a label are
relative to the owner's Storage folder; the user id is not in the repo.

```bash
BARPATH_USER_ID=<user id> BARPATH_SUPABASE_KEY=<secret key> python3 tools/fetch_sessions.py
python3 tools/score_labels.py
```

## How a session gets labelled

1. The athlete records as usual and afterwards says what really happened: the scheme, how sets
   were split (15 wall balls as 9 + 6), loads, Rx, anything odd (a Crown turn too early).
2. Claude lines that up with the motion data (forearm overhead, hanging from a bar, steps from the
   pedometer, …), writes `data/labels/<date>-<name>.json`, and asks about anything that does not fit.
3. The athlete confirms. `python3 -m pytest tools/tests/test_labels.py` checks the file.

The recording and the watch result are never changed for a label: the label points at the watch's
untouched result (`<id>.original.json` when the result was corrected).

## Format (version 1)

Times are **session seconds**: the watch CSV's `t` column (0 = START on the watch).

```json
{
 "version": 1,
 "id": "2026-11-05-amrap20",            // = file name
 "date": "2026-11-05",                   // local date of the workout
 "kind": "workout",                      // or "lifts"
 "name": "20 min AMRAP",
 "format": "amrap",                      // optional: forTime / amrap / emom
 "rx": true,                             // optional
 "files": {"csv": "Debug/session-<id>.csv", "result": "Workouts/<id>.json"},
 "score": "6 rounds + 0",
 "notes": ["…what the athlete said…"],
 "segments": [
  {"movement": "airBike", "round": 1, "start": 0.0, "end": 83.5, "reps": 15, "unit": "calories",
   "source": "motion"},
  {"movement": "wallBalls", "round": 1, "start": 146.5, "end": 187.1, "reps": 15, "unit": "reps",
   "loadLb": 20, "source": "crown",
   "sets": [{"start": 147.9, "end": 165.0, "reps": 9}, {"start": 173.0, "end": 184.2, "reps": 6}]},
  {"movement": "rest", "start": 20.0, "end": 30.0, "source": "motion"}
 ]
}
```

- `movement`: the watch's movement id (`pullUps`, `wallBalls`, `airBike`, `run`, …), or `rest` /
  `transition` (no reps). Segments are in order and do not overlap.
- `source`: how the times were found. `crown` = the athlete's Crown taps (not checked against
  motion), `motion` = read from the motion data, `athlete` = told by the athlete. Prefer `motion`.
- `sets`: sets inside one station, with their reps (they must add up to the segment's `reps`).
  Optional `repTimes`: one time per rep (session seconds, increasing, inside the set), for rep
  counting. From motion they are the peak of each cycle in the named `signal` (`gx`, `gy`, `gz`,
  `vert`) with its rep `period`, and are kept **only when the count equals the athlete's reps**.
- Lifting sessions (`"kind": "lifts"`) have `sets` instead of `segments`: `{file, lift, loadLb,
  reps, note}` per lift recording (`reps: 0` for a false start).

## What is scored

- **Switches**: the start of every working segment whose movement differs from the previous
  working one (rest and transition skipped). Found = a predicted switch within ±3 s (`--tol`).
- **Set ends**: the end of every set (or of the segment when it has no sets). This is where the
  watch should say "set done".
- **Lifting reps**: `barpath.reps.count_reps` per set against the labelled reps.

## Baseline (2026-11-06, 5 labelled sessions)

| | Switches found | Set ends found |
|---|---|---|
| Crown taps, November challenge (2 taps for 25 rounds) | 0 / 50 | 2 / 51 |
| Crown taps, AMRAP 20 | 16 / 18 | 17 / 24 (misses the 9 of each 9 + 6) |
| Crown taps moved to the first rep (`transitions.work_onset`), AMRAP 20 | 9 / 18 (9 false) | 17 / 24 |

Deadlift reps (`count_reps`): 13 / 12 / 12 for 12 / 12 / 12 (the extra rep in set 1 is the first
slow pull), and 1 rep in a 4 s false start.

A detector that changes movement by itself has to beat the Crown on the AMRAP and find the 50
pull-up ↔ push-up switches the Crown never had.

## Phases

1. **Switches (now)**: plan-aware. The watch knows the plan, so it only decides "current movement,
   rest, or the next planned movement?" (`tools/barpath/switches.py`).
2. **Which movement**: recognise the movement without a plan (Free Workout).
3. **Reps**: count reps inside a movement (deadlift already has `barpath.reps`).

## Eval

`python3 tools/score_labels.py --record` scores every detector on every labelled session and
appends one line to `data/eval/history.jsonl` (date, commit, match window, every score). Rules:

- **Score every new version and record it** before deciding it is better. Better = more switches
  found **and** fewer false switches, on the same sessions, at the same window (3 s).
- **Freeze settings, then test on new sessions.** v0 was tuned on the AMRAP 20 and the November
  challenge, so its scores there are optimistic. Every session labelled after a version is frozen
  is a real test of that version; say which sessions a version was tuned on.
- **Compare like with like.** v0 starts after round 1, so it is compared with the Crown and onset
  on the part after round 1 ("after round 1" rows).
- The real switch is the first rep (the first labelled set's start), not the Crown tap.
- **The Crown marks the end of a movement, never the start** (athlete, 2026-11-08: he often rests
  after the turn; on the strict press the turn came 7-10 s after the last rep). So: Crown taps are
  scored as **set ends only**; a switch is truth only when its start is known from motion, the
  athlete or a mark; switches whose start is only a Crown tap are listed as "unverified starts"
  and not scored, and a predicted switch in the first half of such a movement is set aside
  (neither found nor false). Better labels (motion, notes, marks, race splits, video) shrink the
  unverified count. Rule in force from 2026-11-08; earlier history lines used the old rule.

### switch-v0 baseline (2026-11-06, tuned on these two sessions)

| Session, after round 1 | Crown taps | Crown + first rep (`work_onset`) | switch-v0 (no taps) |
|---|---|---|---|
| AMRAP 20 (15 switches) | 10 (5 false) | 12 (4 false) | 10 (6 false), median 1.2 s off |
| November challenge (47 switches) | 0 (Crown tapped twice) | 0 | 27 (21 false), median 1.3 s off |

v0 needs no taps after round 1 but is not yet as good as taps + `work_onset` where the athlete
tapped. It loses track on short sets (6 s of pull-ups) and confuses bike / step-ups. Next: add the
movement-specific signals from `transitions.py` (hang, overhead, cyclic rhythm) as features, and
learn templates from past sessions of the same movement, not only from round 1.

### switch-v1 (2026-11-06): + 6 movement signals

Hang, overhead, throws, planted hand, rhythm strength, step rate (`Config(features="v1")`).
Challenge label updated the same day: the push-ups start at the first planted-hand rep, not when the
hands leave the bar (confirmed by the athlete, see below). That check is close to v1's planted-hand signal, so v1's challenge score
is partly self-agreement.

| Session, after round 1 | Crown + first rep | switch-v0 | switch-v1 |
|---|---|---|---|
| AMRAP 20 (15) | 12 (4 false) | 10 (6 false) | 9 (7 false) |
| November challenge (47) | 0 | 37 (11 false) | 41 (7 false), median 0.5 s |

Challenge label confirmed by the athlete the same day ("when I hold the bar I do pull-ups, when my
hands hit the floor I do push-ups"; down on the knees, sometimes sitting, before the push-ups;
standing rest and chalk after). Push-ups now end when the hands leave the floor; the rest after
them is labelled. Rescored: v0 41/47 (7 false), **v1 46/47 (2 false), median 0.3 s**.

Tried and reverted: relabelling the AMRAP bike starts with the `transitions` bike check (it put the
first stroke 8-14 s after the Crown, too late to be true). Labels must not copy a detector.
AMRAP misses: bike starts come 4-9 s after the Crown tap (unverified label), and one bike ->
step-ups confusion fires 17 s early.

### First held-out test: SunYay AMRAP 40 (2026-11-08, labelled after v1 was frozen)

Ball slams, dual DB thrusters, GHD sit-ups, dual DB lunges, 400 m run; labels are the Crown taps.

| After round 1 (24 switches) | Crown taps | Crown + first rep | switch-v0 | switch-v1 |
|---|---|---|---|---|
| SunYay | 24 (by construction) | 8 (17 false) | 3 (22 false) | 4 (21 false) |

v1 is in step for round 2 (thrusters 0 s, sit-ups -2 s, lunges +2 s), then sees the run 14 s after
the Crown tap (walking to the door before running) and never recovers: it only waits for the *next*
planned movement. For v2: resync when the motion clearly shows another planned movement, and label
run starts from the step rate (the tap is before the run really starts).

### SunYay as training data (2026-11-08)

The athlete gave the reps (thrusters, GHD sit-ups, lunges unbroken; ball slams with a few breaks).
From the motion: 8 of 24 stations got sets with one time per rep (86 rep times; ball slams rounds
1-2 at ~3.5 s per rep from the arm angle, thrusters round 1 at 2.2 s from vertical accel, GHD
sit-ups rounds 1, 2, 3, 5 at 2.5 s from the wrist tilt, lunges round 1); the rest stay on the Crown
taps, not verified. Runs start at the first 6 s at >= 2.2 steps/s: 5-28 s after the Crown (walking
out), so the taps themselves match only 17 of 25 real switches after round 1. Rescored: v0 5/25,
v1 7/25 (18 false): v1 still loses sync after the first late run.

### Strict press and SkiErg (2026-11-08, recorded for training data)

- **Strict press 3 x 10 @ 65 / 75 / 75 lb:** every rep is a sharp upward push of the wrist
  (vertical accel > 0.2 g with the forearm vertical): exactly 10 per set, 30 rep times (set 1 also
  shows the push that takes the bar out of the rack, dropped). 2.7-3.0 s per rep in set 1; sets 2-3
  start at 2.2-2.5 s and slow to ~3 s. The Crown comes 7-10 s after the last rep (rack, then the
  watch): it marks the end of the set, late; the start is not marked.
- **SkiErg 5 x 250 m:** 1.6-1.8 s per stroke (34-39/min), ~38-44 strokes per 250 m (not
  verified). In 4 of 5 intervals skiing started ~4 s before the watch's 1:00 rest ran out; the Crown
  matches the last stroke.
