# tools/video_tracking — bar path from a side-view video

Measures the true bar path (plate centre = bar end) from a phone video, to compare with the
watch. Method, limits and results for the first session are in
`data/raw/2026-10-29-gym/video_paths/README.md`.

**Videos never go in the repo** (it is public). Keep them in `videos/` at the repo root, which
is git-ignored along with everything the scripts write there (`videos/tracks/`,
`videos/overlays/`). Only the CSVs in `data/raw/<date>/video_paths/` are meant to be committed.

## Setup

```sh
python3 -m venv .venv
.venv/bin/pip install opencv-contrib-python numpy scipy matplotlib
```

`opencv-contrib-python` (not `opencv-python`) is needed for the CSRT tracker. macOS only as
written: the video start time comes from `mdls`.

## Inputs

- **Video:** `videos/<date>_<liftType>_<sessionId first 8>_<n>.mov`, filmed side-on, near-side
  plate visible, camera fixed. The scale comes from a 45 cm bumper plate. The session id in the
  name is how a video finds its watch session.
- **Session CSV:** the watch's `session-<id>.csv` in `data/raw/<date>/` (header `startDate`,
  `# event … liftStarted homing=… / liftEnded end=…` lines).

## Run

```sh
# 1. track each watch lift in its own window of the video  ->  videos/tracks/lifts/*.npz
.venv/bin/python tools/video_tracking/track_lifts.py --data data/raw/<date> [name-filter ...]

# 1b. deadlifts / videos without a watch session: track the whole video  ->  videos/tracks/<video>.npz
.venv/bin/python tools/video_tracking/track_plate.py videos/<video>.mov

# 2. metrics, CSVs and overlays  ->  data/raw/<date>/video_paths/, videos/overlays/
.venv/bin/python tools/video_tracking/analyze_tracks.py --data data/raw/<date>
```

Step 1 takes about a minute per lift (4 videos in parallel). Step 2 takes seconds and
overwrites every CSV in `video_paths/`.

## Outputs (`data/raw/<date>/video_paths/`)

- `<video>_lift<k>.csv`: `t, x_cm, y_cm, ok` for one lift (t = s from video start, x forward,
  y up, origin = the bar at the lift start, ok = 1 circle detected / 0 tracker only or clipped).
- `<video>.csv`: the same columns, all lift windows of the video; input of
  `tools/compare_video.py`.
- `lifts.csv`: per-lift start/catch/peak/finish metrics and the matching watch lift.
- `videos/overlays/<video>_lift<k>.jpg`: path drawn on the start frame, for checking by eye
  (local only).

## Scripts

| File | Does |
|---|---|
| `track_plate.py` | Hough circle detection plus CSRT tracking of the plate; `track()` is used by `track_lifts.py` |
| `track_lifts.py` | cuts windows from the watch's homing/end times and tracks each lift |
| `analyze_tracks.py` | camera-tilt-corrected scale, lift points, metrics, CSVs, overlays |
| `postit_refine.py` | experiment: fill blurred frames from a coloured marker on the sleeve end. Not used: a marker on the spinning sleeve wobbles 4–12 cm |

Per-video settings live at the top of `analyze_tracks.py`: `FACING` (−1 for videos where the
lifter faces left) and `DEADLIFTS` (name prefixes tracked whole and split into reps).
`track_lifts.py` skips the prefixes in `SKIP`.
