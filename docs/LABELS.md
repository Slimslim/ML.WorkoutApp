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

### switch-v0 baseline (2026-11-06, tuned on these two sessions)

| Session, after round 1 | Crown taps | Crown + first rep (`work_onset`) | switch-v0 (no taps) |
|---|---|---|---|
| AMRAP 20 (15 switches) | 10 (5 false) | 12 (4 false) | 10 (6 false), median 1.2 s off |
| November challenge (47 switches) | 0 (Crown tapped twice) | 0 | 27 (21 false), median 1.3 s off |

v0 needs no taps after round 1 but is not yet as good as taps + `work_onset` where the athlete
tapped. It loses track on short sets (6 s of pull-ups) and confuses bike / step-ups. Next: add the
movement-specific signals from `transitions.py` (hang, overhead, cyclic rhythm) as features, and
learn templates from past sessions of the same movement, not only from round 1.
