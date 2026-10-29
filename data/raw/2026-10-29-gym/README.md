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
