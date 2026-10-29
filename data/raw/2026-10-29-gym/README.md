# Gym session, 2026-10-29 (real bar, several weights, filmed)

12 full-session CSVs (200 Hz device motion), one watch session per set. Videos exist on the
athlete's Mac only (not in this public repo). Weights per set: not yet recorded here.

Sessions by watch lift type: snatch ×2, powerSnatch ×1, hangSnatch ×1, powerClean ×3,
cleanAndJerk ×1, other ×4 (deadlifts, by the athlete's description). 32 lifts detected.

First analysis (Python reference, `tools/session_lifts.py`):
- Vertical looks right: snatch lockout rise 1.42–1.67 m (athlete's measured 1.55 m from the
  broomstick session), peak vertical velocity 2.1–2.6 m/s.
- Forward/back drift is large and ALWAYS backward (end of lift 0.2–2.8 m behind the start).
- With the real bar the finish was almost never "still" by the analyzer's thresholds, so no
  zero-velocity anchor exists after the turnover (pseudo-anchors only).
- An "end-over-start" prior (lockout roughly above the starting position; remove a linearly
  growing velocity error so forward(T) = 0) brings most snatch paths to −15…+9 cm, which
  is plausible, but it is unvalidated until the video bar paths are measured.
- Deadlifts ("other") aren't handled: no turnover, bar lowered not dropped.

## Watch vs video (2026-10-29, `tools/compare_video.py`, `tools/fit_lever_arm.py`)

Video bar paths: `video_paths/` (plate-centre tracking on the athlete's Mac; method in its
README). 14 Olympic lifts aligned with correlation ≥ 0.85.

- **Wrist → bar lever arm, fitted on the video:** r ≈ (−10.9, 0, −2.6) cm in the watch's
  device frame, i.e. ~11 cm down the forearm toward the hand and ~3 cm below the watch face.
  Exactly where the bar sits in the hand. Applying bar = watch + R(t)·r:
  snatch vertical RMS error 10–23 cm → 4.5–11 cm, and snatch rise watch 148–167 cm →
  166–175 cm vs video 163–170 cm.
- **Horizontal:** the raw watch path is 24–30 cm RMS off on snatches (always drifting
  backward); the end-over-start prior brings that to 4–10 cm on clean snatches but fails on
  lifts that really finish elsewhere (e.g. a forward jump into the catch).
- **Watch-side segmentation problems seen:** several power cleans end far too early
  (watch rise 23–47 cm vs 125 cm on video); C&J lifts end on a timeout before the jerk.
