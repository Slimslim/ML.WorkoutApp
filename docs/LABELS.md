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
- `flag` (optional, on a segment): the motion and the athlete disagree, e.g.
  `{"motion": 13, "athlete": 12, "reason": "13th pull on the buzzer", "check": "video"}`. The
  athlete's count stays the label; nothing is decided from the motion alone. Flags are listed by
  `tools/score_labels.py` and settled later by video (owner, 2026-11-10), or by asking the athlete
  again when there is no video (`"check": "athlete"`).
- `console` (optional, on a segment): what the machine itself showed (an erg console or its app),
  truth that does not come from the watch's motion: `{"machine": "assault bike", "app": "ErgZone",
  "view": "summary", "timeSeconds": 91.4, "calories": 20, "distanceMeters": 945, "rpmAvg": 61,
  "calPerHour": 1631}`. Numbers exactly as shown (keys checked by `labels._check_console`); what the
  motion says goes next to it (`motion`), never into it. First use: `2026-11-19-bike-20cal`.
- **Sets, rests and what is discarded** (inside one working segment): the labelled `sets` are where
  the reps happen; the time between two sets is rest inside the movement (a dataset row of kind
  `rest`, `tools/barpath/tiers.rest_units`); the time before the first set and after the last
  (walking over, set-up, kick-up, coming down) is neither and is never used. So a set's start is
  its first rep and its end its last rep: for handstand push-ups the first press after the kick-up
  (hands planted, upside down) to the last before coming down; for cleans the first pull to the
  last stand-up. Label every set of a segment when any is known, or the rests are wrong.
- `video: true` (optional, on a segment or a set): its count and times were checked on a video
  (tier A in datasets, `tools/barpath/tiers.py`). A note that only says a video exists is not this.
- `training: false` (optional, on a segment): keep the segment for timing but do not use its reps
  as training data (the athlete is not sure of the count and it cannot be checked).
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

### Power snatch EMOM and Freedom (2026-11-09): every rep from the motion

A snatch (and a burpee to the bar) is a forearm rise from hanging to vertical in < 1.5 s with the
arm held overhead 1.3-2.0 s (catch / hand on the bar); a failed snatch comes straight down (0.1-0.6 s).
- **Power snatch every 1:00 x 10 (2 singles), 95-145 lb:** all 20 good reps; the missed rep at
  145 lb (0.6 s overhead) between the two good ones, as the athlete said.
- **Freedom 9-7-5, 135 lb + burpee chest-to-bar (scaled):** all 21 snatches and 20 burpees; the
  failed rep 7 in round 1 and the chalk break, the 33 s wristband break in round 2, 2 + 1 + 1 + 1
  in round 3; two athlete Marks, each just before walking to the bar. Capped at 10:00 with 38
  reps (1 burpee into the last 5). The Crown came at the next minute / after walking, never
  within 3 s of the set end.

### 2026-11-10: Freedom flipped, Tabata press and row

- **Freedom (flipped, scaled):** GHD 15 / 10 / 10 / 5 / 2 (cramp) + 8 floor sit-ups, AbMat 20 / 20 / 10:
  every set and rep from the wrist tilt, exactly as the athlete said. Runs start 2 s and 4 s after the
  Crown (run 2 inside first, the turn onto the road visible ~10 s after the Crown).
- **A press rep is a lockout:** dip at the shoulders, push, then the forearm fully vertical (gy between
  -0.3 and 0.12). With that rule the Tabata press counts all 8 sets exactly (56); a push without
  lockout (set 4) and racking the bar (wrist rolls, gy -0.57, set 7) are not reps. The MVP press
  counter should use the same rule.
- **Bent-over row:** pull right after the bottom reversal; 6 of 8 sets match. Rounds 1, 4 and 8 are
  flagged for video (two at the buzzer, one while getting set).
- Tabata timing: the watch row counted 30 s per interval (no timed work part yet: story W27); the
  work/rest windows in the labels are the gym's 20 / 10 clock.

Sections from 14 Nov on describe methods and detector scores only: no workouts as prescribed, no
loads, no athletes' scores or rep counts (those are in the private labels, `Corpus/labels/`).
Labels are named by their private ids.

### Clean warm-up (2026-11-14): first session labelled from video

Hang power cleans at increasing loads, Lifting mode at 200 Hz; every catch frame from the athlete's
video (30 fps) matches a forearm flip to the front rack in the watch motion within 1-10 frames
(`2026-11-14-clean-warmup`). Rep times are the rack onsets in the motion, so they test the count,
not the timing (data audit, 20 Nov).

| Detector (match window 0.5 s) | Reps found | False |
|---|---|---|
| Lifting mode (the watch's logged lifts) | about a quarter | 1 (a window with no catch) |
| catch-rule (`barpath.catches`: forearm into the rack >= 0.5 s) | all | 3 (plates, looking at the watch) |

Lifting mode needs a still moment before each lift: after the first hang rep the bar never rests,
and the heavy singles were set up without one. The catch rule was written on this session, so its
score here is not a test. Peak vertical speed from the watch's analyzer (started from the still
point at the hang) falls with load as expected; bar height is not reported (not checked on video).

### Partner cleans + synchro burpees (2026-11-14), from video

Two athletes' recordings of the same partner workout, synced to one video on the catches
(`2026-11-14-partner-hpc-burpees`, `2026-11-14-partner-hpc-burpees-tester-b`).
- **catch-rule, first session it was not written on:** every catch of the owner found (all within
  0.21-0.34 s of the video), 6 false (5 while the partner was on the bar, 1 in the rest). Tester B
  (Crown toward the hand, short holds): 43 / 53 found, 50 false (later: same with the canonical
  frame, below).
- The owner's Crown splits were right within 1 s except one (6.7 s early, before the partner's last
  set ended). An unplanned rest is labelled as rest.

### Squats vs lunges from the wrist (2026-11-15)

Done back to back with a barbell on the back (`2026-11-15-sunday-part2`). Squats are up-down:
horizontal movement is 0.14-0.24 of the vertical. Lunges step forward and back: 0.57-0.73 of the
vertical, 80-83% of it on one line. The difference holds in every round and does not depend on
speed, so it is the feature to tell them apart. Squat reps are clear (vertical descents every
2.6-2.8 s); lunge reps are not countable yet from forward-back bursts.

### One watch frame for everyone (2026-11-18, `barpath.orientation`)

Every recording is turned into one frame on load (`load_session_csv`, `canonical=True` by
default): left wrist, Crown left, the frame every detector was written on. The header's `wrist` /
`crown` (build 15+) pick the transform; older files are the owner's (unchanged). Crown toward the
hand (left wrist + Crown right, Apple's default) = a 180 degree turn about the screen axis,
(x, y, z) -> (-x, -y, z) for userAccel, gravity and rotation rate, and the attitude quaternion
turned the same way (checked: gravity rebuilt from the turned quaternion matches the turned
gravity exactly). Right wrist = a mirror (y flips; rotation rate -x, z); not seen on data yet, and
the attitude cannot be mirrored.
- Tester B's partner cleans with the default catch rule: 43 / 53, the same as the flipped rule on
  the raw frame, so no per-watch setting is needed. His bar hangs now read gx > 0.7 like the owner's.
- switch-v1 on the workouts with verified starts after round 1 (window 5 s): on sessions it was not
  tuned on, 10 / 32 with 31 false. The frame changed tester B's numbers little (switch-v1 learns
  from his own round 1). What it buys: one model over everyone's labelled stations later.

### Movement blocks after the workout (2026-11-18, `barpath.pattern_blocks`, experimental)

The owner's idea: every movement repeats a pattern; looked at after the workout, the session is a
chain of pattern blocks in the plan's order, pauses inside a block are rests, the time between two
patterns is the transition. Nothing is trained (each workout teaches itself: one pattern per
movement, shared by its rounds). Input: motion + the movements in the order done + the Crown taps
as hints by position (the k-th tap = the switch into movement k; a soft pull, never required).
Output per movement: first and last second of pattern and the rests inside. Scored by
`tools/score_pattern_blocks.py`.

What it took (developed on `2026-11-05-amrap20`, `2026-11-08-amrap40-run`,
`2026-11-09-snatch-burpee-c2b`):
- A minimum of 5 s of pattern per movement and several starting splits (one share of time per
  movement, the same each round): without them the chain locks in one movement off.
- The pause pattern learned once from the calmest 15% of seconds and kept: re-estimated, it
  swallowed a low-effort station and shifted every block.
- The last movement may be cut short by the clock.
- The Crown taps as anchors: on motion alone a repeating order can fit one movement off (right
  boundaries, wrong names).
- Walking is a transition: runs 2.5-3.2 steps/s with 2.4-3.0 g impacts (90th percentile of
  |userAccel|), walking between stations about 1-2 steps/s at 0.6-0.9 g; arm swings at stations
  count steps but hit 2-3 g. The pause after a movement is standing still OR walking, a planned run
  stays a movement. Box step-ups look like walking, so walking is learned only near Crown taps and
  the transition INTO a stepping movement is standing only. One more starting guess: the
  athlete's own Crown splits.
- Planned rests stay in the order (the watch's splits count them, so the hints stay aligned), and
  a rest ended by the watch's own timer (advance source `auto`) is pinned to its exact window.
- The "time" score counts only known working time (labelled sets, or segments whose start came
  from motion / the athlete): a Crown-only segment also holds the walk over and the set-up.

Results (first rep / last rep within 5 s where known; known working time in the right movement):
the 3 development workouts 22 / 26 first reps, 96-100%; held-out 18 / 32 first reps (data audit,
20 Nov; nothing here is a clean test: every session was seen while building it). Fails: squats
and lunges back to back (49%), pieces of 6-10 s (below the 4 s window: switch-v1's hang /
planted-hand signals stay the tool there), and the wait before a movement done in small sets.

### Bodyweight chipper with timed rests (2026-11-18, `2026-11-18-barbara`)

First workout recorded after the block finder was built (but used the same day to change it).
- Pull-up sets: each set is one hang (forearm up), each kipping rep one swing pair (~2 s per rep),
  confirmed by the athlete. A good first rep-counting candidate.
- Sit-ups: the forearm tilts with the torso (main axis of the gravity change), one clear cycle per
  rep at 2.4-2.8 s; one set the athlete remembered as split shows no pause over 3 s.
- Air squats with the arm hanging: count the upward SPEED (vertical acceleration integrated), one
  peak per squat; the acceleration itself gives two peaks per slow squat. At 2.2 s per squat the
  speed counter still adds about 2 small movements per set (settling in, a breath at the top).
- Block finder with the timed rests pinned: first rep within 5 s 11 / 12 (median 1.6 s), last rep
  11 / 12 (median 1.7 s; the athlete's Crown 12 / 12, median 2.2 s). Starts and ends there come from
  the motion (tier C), so this is agreement, not proof.

### Console values (2026-11-19, `2026-11-19-bike-20cal`)

First clap-synced session: one clap before and three after an air bike bout, 10-13 g spikes the
pedalling never reaches. The console's summary (ErgZone) is stored in the segment's `console`
block. Wrist cadence (one forearm cycle per revolution) agrees with the console's average within
1 rpm, revolutions within 2%; the console's time is 3-4 s shorter than the pedalling in the motion
(where its clock starts and stops is unknown without per-second data).
