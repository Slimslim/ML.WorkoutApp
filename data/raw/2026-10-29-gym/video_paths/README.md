# Video bar paths, 2026-10-29 gym session

Bar paths measured from the side-view iPhone videos of this session, as ground truth for the
watch's bar-path estimate. The videos stay on the athlete's Mac (`videos/`, git-ignored; the
repo is public). Only these CSVs and this README are committed.

## Files

- `<video name>_lift<k>.csv`: one per lift (Olympic lifts: one per watch lift; deadlifts: one
  per rep). Columns:
  - `t`: seconds from the start of the video (frame index / fps)
  - `x_cm`: horizontal, **positive = forward**, toward the lifter's front (away from the
    lifter's body)
  - `y_cm`: vertical, positive = up
  - `ok`: 1 = plate circle detected in that frame; 0 = position from the CSRT tracker only
    (fast motion blur, occlusion) or plate partly above the top of the frame. Treat 0 frames
    as less exact.

  Origin (0, 0) = the bar at that lift's start. Olympic-lift CSVs cover the tracking window
  (0.7 s before the watch's homing time to 1 s after its lift end, longer for the clean & jerk),
  so they include the drop. Deadlift CSVs run from just before the rep to just after it.
- `<video name>.csv`: the same columns, all of that video's lift windows in time order (frames
  between windows are absent; each window keeps its own lift's origin). This is the input of
  `tools/compare_video.py`, which aligns each watch lift to it by vertical-velocity
  cross-correlation and re-bases the path at the watch's homing time.
- `lifts.csv`: one row per lift, with the summary numbers and the watch match (columns below).

## Video ↔ watch session matching

Videos were renamed `2026-10-29_<liftType>_<sessionId first 8>_<n>.mov` (the athlete approved
the names). Each video was matched to the watch session that overlaps it in time (video creation
time from `mdls`, watch `startDate` from the CSV header). Every video starts 3–6 s before its
watch session (`video_offset_s` = watch start − video start).

| Original | Renamed | Watch session | Lift type | Weight (athlete) | Lifts in video | Notes |
|---|---|---|---|---|---|---|
| IMG_9226 | `2026-10-29_hangSnatch_86270EB1_1` | 86270EB1 | hangSnatch | empty training bar (~15 lb) | 3 | **not tracked**: no plate (see below) |
| IMG_9227 | `2026-10-29_snatch_C288475F_1` | C288475F | snatch | ~45 lb (15 lb bar + 30) | 3 | |
| IMG_9228 | `2026-10-29_powerClean_0D7CECD1_1` | 0D7CECD1 | powerClean | ~45 lb | 2 | video ends before watch lift 3 |
| IMG_9229 | `2026-10-29_powerClean_8CCBF91F_1` | 8CCBF91F | powerClean | 95 lb | 2 | |
| IMG_9230 | `2026-10-29_powerClean_7947DB2B_1` | 7947DB2B | powerClean | 125 lb | 3 | athlete-checked timings |
| IMG_9231 | `2026-10-29_cleanAndJerk_E0A15242_1` | E0A15242 | cleanAndJerk | not recorded | 3 | lifts 1–2: squat clean, re-grip, jerk; lift 3: clean then push jerk |
| IMG_9232 | `2026-10-29_snatch_9440D88E_1` | 9440D88E | snatch | 75 lb | 4 | |
| IMG_9233 | `2026-10-29_powerSnatch_0313E491_1` | 0313E491 | powerSnatch | 95 lb | 3 | |
| IMG_9234 | `2026-10-29_unmatched_IMG9234_1` | none overlaps (01:51 UTC) | deadlift | 225 lb × 6 | 6 reps | no watch data |
| IMG_9235 | `2026-10-29_other_8B36E5AE_1` | 8B36E5AE | other (deadlift) | 275 lb × 6 | 6 reps | watch logged 1 lift (= rep 1) |
| IMG_9236 | `2026-10-29_other_0A3AE1B5_1` | 0A3AE1B5 | other (deadlift) | 300 lb × 6 | 6 reps | watch logged 1 lift (= rep 1) |

The lift start found in the video is within 0.7 s of the watch's `liftStarted homing=` time
(shifted into video time) for every Olympic lift (`video_minus_watch_s`, −0.69…+0.04 s; the
video start is "bar leaves the floor", homing is a little later). For the 125 lb power cleans
the athlete checked the video by eye: bar leaves the floor at ~8–9 s, ~19 s and ~36 s, caught
~10 s, dropped; the tracker gives starts 8.84 / 18.71 / 35.88 s and the first catch at 10.34 s.

## Method

1. **Lift windows from the watch.** Each watch lift's `homing` and `liftEnded` times are shifted
   into video time by the offset above. The tracker runs only in [homing − 0.7 s, end + 1.0 s].
   The bar is dropped and rolled back into place between lifts, so each window starts again on
   the resting bar. The clean & jerk sessions end on the watch's 8 s timeout, before the re-grip
   and jerk, so their windows run to 2 s before the next lift's homing. Deadlifts (bar never
   dropped, one watch "lift" per 6-rep set) are tracked over the whole video and split into reps.
2. **Detection.** Frames are downscaled to 540×960, greyed and median-blurred.
   `cv2.HoughCircles` (`HOUGH_GRADIENT_ALT`) finds the near-side 45 cm bumper plate as the
   strongest plate-sized circle on the resting bar in the first 0.6 s of the window.
3. **Tracking.** A CSRT tracker (`opencv-contrib-python` 5.0) follows a box around the plate.
   Every frame, Hough looks again within ±2.2 plate radii of the tracker's prediction for a
   circle with radius within ±12 % of the plate's. If found, the circle centre is used
   (`ok = 1`) and the tracker is re-initialised on it when it has drifted; if not, the tracker
   centre is used (`ok = 0`). After 0.5 s without a circle the whole frame is searched again.
4. **Scale (cm/px), corrected for camera tilt.** The plate is its own ruler: 22.5 cm / radius in
   px. The phone was not exactly parallel to the bar's plane: the plate looks 6–17 % larger at
   the top of the frame than on the floor in the same lift, so one scale would overstate heights
   near the top by up to ~8 %. Per lift, the plate radius is fitted as a linear function of image
   row (robust fit over sharp, slow frames from the window start to the lift's finish, excluding
   frames where the plate is cut off). Then y = ∫ 22.5 cm / r(v) dv along the image column, and
   x = (column − image centre) × 22.5 cm / r(v) at that row. `cm_per_px` in `lifts.csv` is the
   scale at the resting bar, `r_slope` the fitted radius change per pixel row.
5. **Axes.** y = up. The lifter faces right in the outdoor videos and left in the indoor
   deadlift videos; x is flipped for those to keep +x = forward.
6. **Lift points.** Positions are smoothed (3-frame median, then 7-frame Savitzky–Golay) for the
   metrics; the CSVs hold the unsmoothed values.
   - **start**: walking back from where the bar first passes 30 cm, the last point where it was
     still going down or resting (bar leaves the floor).
   - **catch**: after the first pull peak, the lowest bar position before the finish (receiving
     position: quarter squat in a power clean, bottom of the squat in a full snatch or squat
     clean). Blank when the bar didn't dip ≥ 3 cm after the pull (caught at full height), and
     for deadlifts.
   - **finish**: the last held position (|v| < 25 cm/s for ≥ 0.2 s, above half the peak height)
     before the bar comes down: standing lockout or rack, jerk lockout for the C&J, deadlift
     lockout. When the bar is dropped with no hold, the highest point is used.
   - Relative to the start, over start → finish: `peak_cm` (highest point), `rise_cm` (finish
     height), `fwd_max_cm` / `back_max_cm` (most forward / most backward), `finish_dx_cm`
     (finish x).

## Limits and special cases

- **Hang snatch with the empty training bar (86270EB1): not measured.** No plate. The sleeve end
  (~5 cm disc, end-on to the camera) was tried as the target, but CSRT lost it during the fast
  pull twice.
- **Plate out of frame overhead.** On the jerks and the taller snatches the top of the plate
  goes above the frame at lockout (`clipped` = share of start→finish frames). Those frames are
  `ok = 0` and the finish numbers for those lifts are less exact. Frame wider next time.
- **The yellow post-it** on the heavier bars' sleeve end was tried as a second detector for
  motion-blurred frames. It isn't usable as a position: it is on the sleeve, which spins during
  the turnover, so its offset from the plate centre changes by 4–12 cm. It could be used to
  measure sleeve rotation.
- Big forward/backward numbers are real moves, not tracking errors (checked on frames):
  9440D88E lift 1 jumped forward into the catch (+31 cm), lift 3 staggered backward while
  standing up (−32 cm).
- No lens-distortion correction; image vertical is taken as true vertical.

## `lifts.csv` columns

`video, lift, csv`; `t_start, t_peak, t_finish, t_end` (s from video start);
`catch_after_start_s, catch_y_cm, catch_dx_cm`; `peak_cm, rise_cm, fwd_max_cm, back_max_cm,
finish_dx_cm` (cm, relative to the lift start); `ok_circle` (share of start→finish frames with a
detected circle); `clipped` (share with the plate partly out of frame); `cm_per_px` (at the
resting bar), `r_slope`, `facing`; `session` (full watch session id), `watch_lift` (1-based index
of the watch lift), `watch_homing_video_s`, `watch_end_video_s` (watch times shifted into video
time), `video_minus_watch_s` (video start − watch homing), `video_offset_s` (watch session start
− video start).

## Results (cm, relative to each lift's start)

Rise = finish height; fwd/back = most forward/backward point between start and finish.

| Video | Lift | Weight | Start (s) | Catch y / dx | Peak | Rise (finish) | Most fwd | Most back | Finish dx | Circle frames | Clipped | Video − watch (s) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| cleanAndJerk_E0A15242 | 1 | not recorded | 9.60 | 62.5 / 2.8 | 183.3 | 179.2 | 15.8 | -4.4 | 3.5 | 71% | 16% | -0.17 |
| cleanAndJerk_E0A15242 | 2 | not recorded | 33.51 | 95.2 / -0.7 | 178.3 | 178.3 | 15.2 | -23.8 | -13.6 | 72% | 15% | -0.21 |
| cleanAndJerk_E0A15242 | 3 | not recorded | 57.68 | 101.3 / 0.0 | 179.6 | 176.7 | 16.4 | -13.5 | -10.9 | 61% | 28% | -0.20 |
| other_0A3AE1B5 | 1 | 300 lb | 9.67 | — | 61.7 | 60.6 | 0.0 | -4.4 | -1.1 | 100% | 0% | -0.53 |
| other_0A3AE1B5 | 2 | 300 lb | 12.40 | — | 58.8 | 57.5 | 0.0 | -8.5 | -5.9 | 100% | 0% | — |
| other_0A3AE1B5 | 3 | 300 lb | 15.00 | — | 57.0 | 55.9 | 0.0 | -5.6 | -1.8 | 98% | 0% | — |
| other_0A3AE1B5 | 4 | 300 lb | 17.70 | — | 59.2 | 57.0 | 2.3 | -3.9 | 1.4 | 100% | 0% | — |
| other_0A3AE1B5 | 5 | 300 lb | 20.47 | — | 57.7 | 57.1 | 0.0 | -8.3 | -2.9 | 97% | 0% | — |
| other_0A3AE1B5 | 6 | 300 lb | 23.33 | — | 58.5 | 58.5 | 2.3 | -6.0 | 2.3 | 100% | 0% | — |
| other_8B36E5AE | 1 | 275 lb | 11.40 | — | 63.4 | 61.3 | 3.9 | -0.6 | 2.5 | 100% | 0% | -0.29 |
| other_8B36E5AE | 2 | 275 lb | 13.70 | — | 61.5 | 60.4 | 1.1 | -3.6 | -0.1 | 100% | 0% | — |
| other_8B36E5AE | 3 | 275 lb | 15.87 | — | 60.3 | 58.8 | 0.3 | -5.4 | -0.8 | 100% | 0% | — |
| other_8B36E5AE | 4 | 275 lb | 18.10 | — | 58.4 | 57.2 | 3.8 | -2.5 | 2.6 | 100% | 0% | — |
| other_8B36E5AE | 5 | 275 lb | 20.40 | — | 59.9 | 59.9 | 0.0 | -8.0 | -4.1 | 100% | 0% | — |
| other_8B36E5AE | 6 | 275 lb | 22.90 | — | 57.7 | 57.2 | 0.7 | -5.2 | -0.1 | 100% | 0% | — |
| powerClean_0D7CECD1 | 1 | ~45 lb | 9.44 | 101.9 / 1.2 | 133.8 | 133.8 | 18.6 | -2.5 | 2.5 | 88% | 0% | -0.35 |
| powerClean_0D7CECD1 | 2 | ~45 lb | 18.61 | 102.7 / -7.7 | 130.2 | 130.2 | 12.5 | -11.8 | -7.5 | 91% | 0% | -0.38 |
| powerClean_7947DB2B | 1 | 125 lb | 8.84 | 97.4 / -13.7 | 126.5 | 126.5 | 10.1 | -14.4 | -9.1 | 89% | 0% | -0.68 |
| powerClean_7947DB2B | 2 | 125 lb | 18.71 | 100.2 / -9.0 | 129.9 | 129.9 | 11.9 | -12.4 | -3.7 | 94% | 0% | -0.69 |
| powerClean_7947DB2B | 3 | 125 lb | 35.88 | 95.9 / -11.0 | 130.1 | 130.1 | 10.0 | -11.8 | -7.2 | 73% | 0% | -0.68 |
| powerClean_8CCBF91F | 1 | 95 lb | 11.10 | 96.5 / -5.0 | 124.2 | 124.2 | 12.0 | -9.2 | -4.7 | 96% | 0% | -0.58 |
| powerClean_8CCBF91F | 2 | 95 lb | 21.84 | 94.2 / -8.0 | 131.1 | 131.1 | 10.6 | -11.4 | -7.4 | 87% | 0% | -0.69 |
| powerSnatch_0313E491 | 1 | 95 lb | 14.87 | — | 177.1 | 173.1 | 14.1 | -13.1 | -10.8 | 91% | 1% | +0.04 |
| powerSnatch_0313E491 | 2 | 95 lb | 27.87 | 130.1 / -4.3 | 175.0 | 173.1 | 12.1 | -7.3 | -7.2 | 92% | 0% | +0.02 |
| powerSnatch_0313E491 | 3 | 95 lb | 42.14 | 137.6 / 4.0 | 178.1 | 175.4 | 17.9 | -2.8 | -2.1 | 90% | 1% | +0.01 |
| snatch_9440D88E | 1 | 75 lb | 7.87 | 110.5 / 3.2 | 173.9 | 172.9 | 31.8 | -2.7 | 30.8 | 71% | 16% | -0.45 |
| snatch_9440D88E | 2 | 75 lb | 25.80 | 112.8 / 4.3 | 173.5 | 171.8 | 20.3 | -4.6 | -3.1 | 75% | 15% | -0.67 |
| snatch_9440D88E | 3 | 75 lb | 41.14 | 115.4 / -8.1 | 179.6 | 177.8 | 21.8 | -32.8 | -32.1 | 66% | 24% | -0.53 |
| snatch_9440D88E | 4 | 75 lb | 57.60 | 110.1 / -3.9 | 174.8 | 171.4 | 15.8 | -13.0 | -12.5 | 69% | 20% | -0.57 |
| snatch_C288475F | 1 | ~45 lb (15 lb bar + 30) | 8.20 | 98.8 / -15.9 | 171.2 | 171.2 | 13.7 | -16.4 | -12.3 | 84% | 6% | -0.17 |
| snatch_C288475F | 2 | ~45 lb (15 lb bar + 30) | 17.57 | 100.3 / -4.7 | 174.3 | 174.3 | 14.1 | -8.1 | -8.1 | 87% | 6% | -0.16 |
| snatch_C288475F | 3 | ~45 lb (15 lb bar + 30) | 30.21 | 101.3 / -9.5 | 170.6 | 170.0 | 14.6 | -17.9 | -15.2 | 65% | 19% | -0.19 |
| unmatched_IMG9234 | 1 | 225 lb | 9.53 | — | 67.2 | 64.8 | 2.1 | -1.3 | 1.8 | 100% | 0% | — |
| unmatched_IMG9234 | 2 | 225 lb | 11.77 | — | 66.9 | 64.2 | 0.3 | -4.7 | -0.5 | 100% | 0% | — |
| unmatched_IMG9234 | 3 | 225 lb | 13.83 | — | 67.0 | 64.3 | 0.6 | -3.9 | 0.0 | 100% | 0% | — |
| unmatched_IMG9234 | 4 | 225 lb | 15.93 | — | 63.7 | 62.0 | 0.0 | -4.1 | -2.6 | 100% | 0% | — |
| unmatched_IMG9234 | 5 | 225 lb | 18.07 | — | 63.9 | 61.1 | 0.6 | -3.8 | 0.1 | 100% | 0% | — |
| unmatched_IMG9234 | 6 | 225 lb | 20.20 | — | 63.1 | 60.5 | 0.0 | -4.5 | -0.9 | 100% | 0% | — |
