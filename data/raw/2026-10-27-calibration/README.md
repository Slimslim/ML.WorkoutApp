# Calibration session, 2026-10-27 (home, Apple Watch Series 12, left wrist)

One full-session CSV (200 Hz device motion, 377 s), Marks tapped before each test. Analysis:
`python3 tools/analyze_calibration.py <csv>` (tests) and `python3 tools/session_lifts.py <csv>`
(cuts the watch-detected lifts and runs the analyzer).

Athlete: watch at 0.25 m in the set position, 1.80 m at snatch lockout → expected rise 1.55 m.

| Mark | t (s) | Test | Result |
|---|---|---|---|
| 1 | 3.3 | A: watch flat on table | bias 1–6 mg; uncorrected drift 3.5 cm after 1 s, 14 cm after 2 s, ~0.9 m after 5 s |
| 2 | 48.8 | B: arm hanging | bias 2–3 mg, similar drift |
| 3 | 82.3 | C: up/down slow, seated, hanging → as high as possible (no tape, distance unknown) | **not measurable**: slow moves stay under the stillness thresholds, so false zero-velocity points are found mid-move |
| 4 | 129.5 | D: up/down fast, seated, same range (no tape) | **46.3 ± 0.9 cm** (8 moves): no ground truth, but shows repeatability ±1 cm; also detected as two "lifts" |
| 5 | 163.3 | E1: step forward / back ×5, slow (whole body moves) | **not measurable** (slow, same false-stillness problem) |
| 6 | 212.2 | E2: step forward / back ×5, fast | **54.8 ± 3.9 cm** step length (10 moves), no ground truth |
| 7 | 259.0 | F: wrist turn palm down/up | ~5 cm displacement per ~100° turn: the watch really moves (it sits ~3 cm off the forearm axis); no sign of fake motion from rotation |
| 8 | 330.0 | G: broomstick snatches (filmed; top cut off) | final height **1.55 / 1.57 / 1.53 m** vs 1.55 m measured; peak v 1.97–2.32 m/s |

Only ground truth in this session: the snatch rise (tape-measured watch heights).
The tests were done seated / with steps rather than against tape marks, so D and E give
repeatability, not accuracy.

Notes: the lift detected at t≈320 s (before Mark 8) rose only 0.3 m with no turnover
(picking up the stick); not a snatch. Distributing the ZUPT drift by rotation instead of time
made no difference on D/E.
