# Partner WOD 1 (Scaled), 2026-10-31 — doubles, first team recording

Gym WOD, partner, 30:00 cap. Runs together, stations split. Scaled version actually done:
800 m run · 80 wall balls (athlete: 14 lb) · 600 m run · 60 single DB walking lunge steps (athlete: 50 lb DB) ·
400 m run · 40 burpees · 200 m run · 20 med ball step-overs 20" (14/10) · 100 m run · 10 devil press (athlete: 2 × 40 lb DBs).
NOTE: the watch still had the RX definition (1000/100/800/80/…), so titles and run paces in the JSON use
the wrong targets; the Crown boundaries are right (one Crown turn per team switch, no undos).
Apple Watch Series 12, left wrist, Data mode (100 Hz). Total 23:09 (1389 s).

## Runs: watch distance vs real
800 → 709 m (−11 %), 600 → 592 (−1 %), 400 → 381 (−5 %), 200 → 176 (−12 %), 100 → 88 (−12 %);
total 1946 vs 2100 m (−7 %). Calibration data for HYROX_PLAN §8.

## Work vs rest inside stations (first look, |userAccel| SD > 0.45 g in 1 s windows, merged)
- Wall balls (204 s): 4 work bouts of 20–24 s (you), partner first; your work 88 s (43 %), rest 117 s.
- Burpees (147 s): 4 bouts of 18–23 s; your work 80 s (54 %), rest 68 s.
- DB lunges, med-ball step-overs, devil press: wrist holds a weight → low |a|; needs other features
  (step cadence, gravity orientation). Labels from the athlete pending (who did which reps).

## Athlete labels (2026-10-31)
Wall balls split 10/10 (4 sets each), burpees 5/5 (4 sets each), partner started both.
Detector check: 4 work bouts in each station (matches); first bout starts after the partner's set.
First rep-count try inside the bouts (vertical accel = −(userAccel·gravity), low-pass 3 Hz, peaks > 1 g ≥ 1.2 s apart):
wall balls 11 / 10 / 11 / 12 (truth 10 each), burpees 6 / 5 / 5 / 5 (truth 5 each).
