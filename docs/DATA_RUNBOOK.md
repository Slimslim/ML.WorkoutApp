# Data runbook: recordings, labels, datasets

Owner's setup of 20 Nov. The **Data chat** ("Data: recordings & labels") coordinates; each workout
is labelled in its own short-lived side chat ("Label: <date> <workout>") so the Data chat's context
stays short. Format of a label: `docs/LABELS.md`. Nothing here goes into the repo except code and
this text: recordings, labels, datasets, videos and notes stay in private Storage.

## Private Storage (bucket `uploads`, the owner's folder)

| Path | What | Written by |
|---|---|---|
| `Workouts/`, `Debug/`, `Lifts/` | watch results, session CSVs (.csv.gz), lift/set files | the phone |
| `Corpus/inbox/<date>/` | the owner's extra data for a day: console exports (ErgZone ...), nRF logs, video-derived times, a `notes.md` | the owner or a chat |
| `Corpus/labels/drafts/<label id>.json` | a labeller's draft | labellers |
| `Corpus/labels/<label id>.json` + `MANIFEST.sha256` | accepted labels (`<sha256>  <bytes>  <name>` per line) | the Data chat only |
| `Corpus/eval/` | score history | the Data chat |
| `Corpus/datasets/v<N>/` | versioned datasets (`tools/build_dataset.py`); never overwritten | the Data chat |
| `Corpus/tracker/movements.json` | coverage per movement (`tools/movement_tracker.py`) | the Data chat |
| `Corpus/state/last_check.json` | `{"checkedAt": ISO time, "done": [result ids]}` | the Data chat |

Videos are deleted from the inbox once their times are in a label.

## Evening check (scheduled, 9:17 pm Los Angeles, in the Data chat)

1. List `Workouts/` and `Debug/` (and `Lifts/<session>/`) for files newer than `checkedAt`. Group
   them per workout (result id = session id; Lifting-mode sessions have no result).
2. For each new workout, start a labeller side chat (at most 2 at once), named
   `Label: <date> <workout>`, with the brief below, the file paths, the owner's notes for it (from
   the Data chat since the last check and `Corpus/inbox/<date>/notes.md`) and any inbox data.
3. When a labeller reports its draft: check it (`labels.validate`, the id, the files, flags), move
   it to `Corpus/labels/`, add its manifest line, verify the checksum, archive the labeller.
4. Update `last_check.json`, rebuild the tracker, and send Delivery the day's flags (at most 3,
   most important first; the rest wait for the next days).
5. Sundays: the weekly coverage report (below).

## Labeller brief (what a "Label:" chat does)

- Download the files, label the workout per `docs/LABELS.md` (one label per recording; private ids
  without gym workout names), using the owner's notes, the Crown / marks / timer, console and video
  data, and the motion (the canonical frame from `load_session_csv`).
- Keep each value's source: tier A video or console, B the owner's count / Crown / timer / mark,
  C motion, D unverified. A start or end from motion is C even when it looks clean.
- **Clear** (no flag): every count the owner gave matches the motion, and every split agrees within
  5 s, or there is nothing to compare. **Flag** (`flag` on the segment, `check: "athlete"` or
  `"video"`): a count off by 1 or more, or a split off by more than 5 s. The owner's count stays the
  label until the check.
- Short and single-pass: no new detectors, no tuning, no changes to the repo. If something needs
  more than a label (a bug, a detector idea), write one line in the report.
- Write the draft to `Corpus/labels/drafts/<label id>.json`, then send the Data chat one message:
  label id, sha256, counts per movement, flags (one line each), anything else in one line.

## Flags in Delivery's digest

At most 3 per day, one line each: `<date> <workout>: <movement> round <n>: motion <x> vs you <y>
(<why>). Check: <video | ask>`. The owner's answer goes back to the Data chat, which settles the flag.

## Datasets

`python3 tools/build_dataset.py --out data/datasets --version v<N>` on the local copy of every
label and cached recording, then upload the folder to `Corpus/datasets/v<N>/`. One folder per
movement (`index.csv`, `motion.npz`, `reps.csv`), a `manifest.json` with the builder's commit and
every label's sha256, and a `CHANGELOG.md`. A version is never changed: new labels make a new
version. Split: test = tier A (filmed or console) sessions only, never used for tuning.

## Movement tracker and the weekly report

`python3 tools/movement_tracker.py` per movement: sessions, athletes, sets, rep times, tiers,
dev/test. Targets for the first three (run, air bike, wall balls): 10 sessions, 2 athletes,
3 tier-A sessions each. Every Sunday the Data chat tells the owner what is missing, one line per
movement, and puts one line in Delivery's digest.
