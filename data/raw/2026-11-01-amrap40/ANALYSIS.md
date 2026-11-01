# AMRAP 40 · rep counting from the wrist, first analysis

One athlete (owner), one session, watch on the left wrist, 100 Hz device motion. Labels from
README.md (owner); segment boundaries are the Crown presses from the workout JSON. Reproduce with

    python3 tools/scratch/amrap40_reps.py data/raw/2026-11-01-amrap40

All tables below are that script's output. **Caveat that matters most:** the "specific" rules were
designed while looking at these same 21 segments, so their accuracy is training accuracy, not a
validated number. The "generic" counter has no per-movement tuning beyond a plausible-period range.

## Summary

| movement | true | counted (specific rule) | verdict | what the wrist sees |
|---|---|---|---|---|
| Burpees to target | 15 ×4 | 15, 15, 15, 15 | **works** | hand overhead (gx → +1) plus a −3.5 g landing spike every rep |
| DB snatch (alt.) | 12 ×3 | 12, 12, 12 | **works** | every rep (either hand) takes the watch forearm to vertical, one every 2.3 s |
| DB clean & jerk | 12 ×4 | 12, 12, 12, 12 | works, with an assumption | only every other rep reaches full lockout (gx > 0.9); counted as 2 × lockouts, i.e. assumes the reps alternate hands. Counting every rise through gx 0.5 gives 12, 12, 11, 11 |
| Wall walks | 3 ×3 | 3, 3, 3 | works (fitted on 3 segments) | a 6-7 s burst of 5-6 hand placements with the forearm pointing down, ~15-18 s apart |
| Strict pull-ups | 6 ×3 | 6, 6, 7 | mostly | hand clamped to the bar: almost no acceleration, one slow gy (wrist bend) wave per pull; hang found 3/3 |
| Push-ups 3×5 | 15 ×4 | 17, 13, 16, 16 (sets 6/12 exact, ±1) | **sets yes, reps no** | the watch hand is planted, only tiny wrist-angle changes. The 3 sets and the rests between them are found 12/12 |
| Row | – | 21-28 strokes/min | rate yes | gx swings up at every finish (period 2.1-2.9 s, ACF r ≈ 0.8) |
| Bike | – | 54-60 rpm | rate yes | very clean push-pull in vert (period 1.0-1.1 s, ACF r ≈ 0.9) |

A blind generic counter (autocorrelation period + peak picking on one signal) on the whole Crown
segment is **not usable**: the best single signal (gx) is exact on 3 of 21 segments (vert 2, |rot| 1),
MAE 0.7-10 reps per movement, mostly because the transition at the start of every segment (walking
over, picking up the dumbbell) adds peaks. Cut to the detected work window and choosing the best of three signals afterwards (an oracle), it gets
burpees/snatches/wall walks right (9/10) but still misses push-ups and pull-ups.

### Conclusions

1. **Overhead movements count well from gravity alone.** gx (forearm axis) is the single most useful
   signal: a hysteresis rise counter (up through +0.7 after below −0.3), which is the same idea as the
   KB swing counter in `barpath/segments.py`, counts burpees, snatches and C&J. It needs two
   guards: a jump-landing impulse for burpees (rejects arm raises while walking/resting) and a rhythm
   trim (drop a first/last event > 2.5 × median gap away: dumbbell pick-up, arm wave on the walk over).
2. **Alternating-hand dumbbell work is asymmetric on one wrist.** In the C&J the non-watch-hand reps
   lift the watch forearm only to gx 0.6-0.9. A per-rep threshold of 0.5 catches them but is
   fragile (11/12 in rounds 5 and 7); 2 × full lockouts was exact. The snatch shows no such asymmetry.
   Need the owner to confirm the C&J was alternating.
3. **Planted-hand movements (push-ups, wall walks, pull-ups) are bout detectors, not peak counters.**
   With the hand on the floor/bar the wrist barely accelerates (vert 1 s SD < 0.04 g). The bouts are
   easy and very useful (push-up sets 12/12, set lengths 8-12 s, rests 7-14 s; wall-walk reps 9/9; pull-up
   hang 3/3), the reps inside them are not: push-ups ±1 per set.
4. **The existing `bar_hangs` misses strict pull-ups.** Its activity gate (SD of |userAccel| ≥ 0.5 g,
   set for Helen's kipping) rejects every hang here (0/3 found; strict hangs have SD 0.19-0.23 g). A
   strict/kipping split or a lower gate (≈ 0.15 g, plus gx > 0.8 for ≥ 3 s) is needed.
5. **Crown segment ≠ work.** The lead-in before the first rep is 1-10 s on the erg/bike but 9-42 s for
   pull-ups, snatches, C&J and wall walks (walking over, chalk, setting up). Any per-segment rate
   (reps/min) must use the detected work window.
6. **The pairs that share a slot are trivially separable** on this athlete (every feature below separates
   them with a clear gap): row vs bike by cycle period (2.1-2.9 s vs 1.0-1.1 s); C&J vs snatch by the
   share of overhead rises that reach lockout (0.50-0.55 vs 0.92-1.00) or the gap between rises (3.2-4.4 s
   vs 2.3 s); burpees vs wall walks by the landing spike (vert min −3.5 g vs −0.7 g) or any overhead
   rise at all (15 vs 0); push-ups vs pull-ups by forearm direction (gx p95 < −0.5 vs +1.0).

### Next data needed

- **Rep timestamps** for at least a few segments (video, or a Crown/tap per rep) – needed to tell
  which push-up and pull-up peaks are real and to tune the set-internal counters honestly.
- **A second session of the same movements** (same athlete, then another athlete) to test the specific
  rules out of sample; every threshold here was chosen on this one recording.
- **Confirm the C&J style** (alternating hands? one or two dumbbells?) and the wrist (left assumed).
- **Erg/bike monitor numbers** (strokes, rpm or calories over time) to check stroke/rpm counts – here
  only the rate is plausible, not verified.
- **Kipping vs strict pull-ups** and **push-ups unbroken** in a labelled session, to see if bar/floor
  rules generalize.
- Watch on the **other wrist** for one alternating-DB session to see the mirrored asymmetry.

## Script output

## Rep counts (counted, true in column 'true')

Generic = autocorrelation period + peak picking; cell = whole Crown segment / detected work window. Specific = per-movement rule (script docstrings).

| seg | R | movement | dur s | true | generic vert | generic gx | generic rot | specific | work window s |
|---:|---:|---|---:|---:|---|---|---|---|---|
| 1 | 1 | pushup | 56 | 15 | 14 / 13 | 13 / 15 | 28 / 24 | **17 (5+6+6)** | 5.7-51.9 |
| 2 | 1 | cj | 59 | 12 | 8 / 6 | 12 / 6 | 9 / 7 | **12 (2x6; every-rep rule 12)** | 8.6-54.8 |
| 3 | 1 | burpee | 118 | 15 | 19 / 17 | 18 / 16 | 19 / 17 | **15** | 10.8-117.4 |
| 6 | 2 | pullup | 31 | 6 | 9 / 2 | 16 / 7 | 4 / 5 | **6** | 11.6-28.7 |
| 7 | 2 | snatch | 54 | 12 | 11 / 7 | 12 / 12 | 8 / 7 | **12** | 22.0-52.0 |
| 8 | 2 | wallwalk | 76 | 3 | 4 / 3 | 4 / 2 | 10 / 3 | **3** | 29.6-69.9 |
| 11 | 3 | pushup | 72 | 15 | 20 / 13 | 16 / 12 | 19 / 28 | **13 (4+4+5)** | 16.7-68.5 |
| 12 | 3 | cj | 68 | 12 | 10 / 6 | 14 / 12 | 10 / 6 | **12 (2x6; every-rep rule 12)** | 19.8-64.7 |
| 13 | 3 | burpee | 134 | 15 | 20 / 15 | 16 / 15 | 19 / 15 | **15** | 27.8-133.4 |
| 16 | 4 | pullup | 33 | 6 | 12 / 2 | 16 / 7 | 8 / 4 | **6** | 13.7-29.9 |
| 17 | 4 | snatch | 48 | 12 | 11 / 8 | 16 / 12 | 10 / 7 | **12** | 17.0-46.4 |
| 18 | 4 | wallwalk | 79 | 3 | 6 / 3 | 6 / 2 | 8 / 3 | **3** | 32.3-77.2 |
| 21 | 5 | pushup | 72 | 15 | 14 / 8 | 11 / 7 | 31 / 22 | **16 (5+5+6)** | 12.7-68.7 |
| 22 | 5 | cj | 97 | 12 | 31 / 18 | 16 / 12 | 23 / 12 | **12 (2x6; every-rep rule 11)** | 42.3-92.4 |
| 23 | 5 | burpee | 144 | 15 | 17 / 15 | 17 / 15 | 17 / 15 | **15** | 26.0-143.2 |
| 26 | 6 | pullup | 39 | 6 | 6 / 2 | 15 / 10 | 6 / 7 | **7** | 17.0-36.1 |
| 27 | 6 | snatch | 50 | 12 | 12 / 7 | 14 / 12 | 11 / 7 | **12** | 17.6-46.6 |
| 28 | 6 | wallwalk | 87 | 3 | 6 / 3 | 6 / 3 | 6 / 3 | **3** | 42.1-85.1 |
| 31 | 7 | pushup | 71 | 15 | 17 / 11 | 25 / 9 | 23 / 32 | **16 (5+5+6)** | 15.0-67.7 |
| 32 | 7 | cj | 71 | 12 | 26 / 18 | 12 / 12 | 16 / 12 | **12 (2x6; every-rep rule 11)** | 16.1-66.6 |
| 33 | 7 | burpee | 107 | 15 | 17 / 15 | 16 / 15 | 18 / 15 | **15** | 15.8-105.3 |

## Accuracy per movement (segments with the exact count; MAE in reps)

| movement | segs | generic vert (segment) | generic gx (segment) | generic rot (segment) | generic, best signal in work window (oracle) | specific rule |
|---|---:|---|---|---|---|---|
| pushup | 4 | 0/4 exact, MAE 2.2 | 0/4 exact, MAE 4.2 | 0/4 exact, MAE 10.2 | 1/4 exact, MAE 3.2 | **0/4 exact, MAE 1.5** |
| cj | 4 | 0/4 exact, MAE 9.8 | 2/4 exact, MAE 1.5 | 0/4 exact, MAE 5.0 | 3/4 exact, MAE 1.2 | **4/4 exact, MAE 0.0** |
| burpee | 4 | 0/4 exact, MAE 3.2 | 0/4 exact, MAE 1.8 | 0/4 exact, MAE 3.2 | 3/4 exact, MAE 0.2 | **4/4 exact, MAE 0.0** |
| pullup | 3 | 1/3 exact, MAE 3.0 | 0/3 exact, MAE 9.7 | 1/3 exact, MAE 1.3 | 0/3 exact, MAE 1.0 | **2/3 exact, MAE 0.3** |
| snatch | 3 | 1/3 exact, MAE 0.7 | 1/3 exact, MAE 2.0 | 0/3 exact, MAE 2.3 | 3/3 exact, MAE 0.0 | **3/3 exact, MAE 0.0** |
| wallwalk | 3 | 0/3 exact, MAE 2.3 | 0/3 exact, MAE 2.3 | 0/3 exact, MAE 5.0 | 3/3 exact, MAE 0.0 | **3/3 exact, MAE 0.0** |

## Push-up sets: work vs rest inside the segment

| seg | R | sets | set windows (s from segment start) | set length s | reps per set (true 5+5+5) | rest between sets s |
|---:|---:|---:|---|---|---|---|
| 1 | 1 | 3 | 5.7-13.7, 21.1-31.0, 40.7-51.9 | 8.0, 9.9, 11.2 | 5+6+6 | 7.4, 9.7 |
| 11 | 3 | 3 | 16.7-25.6, 36.0-45.1, 58.7-68.5 | 8.9, 9.1, 9.8 | 4+4+5 | 10.4, 13.6 |
| 21 | 5 | 3 | 12.7-22.8, 35.4-45.6, 56.5-68.7 | 10.1, 10.2, 12.2 | 5+5+6 | 12.6, 10.9 |
| 31 | 7 | 3 | 15.0-26.3, 35.8-46.7, 56.1-67.7 | 11.3, 10.9, 11.6 | 5+5+6 | 9.5, 9.4 |

## Pull-up hangs and wall-walk reps

| seg | R | movement | bouts (s from segment start) | bar_hangs() (barpath) | lead-in before first bout s |
|---:|---:|---|---|---|---:|
| 6 | 2 | pull-up | hang 11.6-28.7 (17.1 s), pulls at 15.5, 18.0, 20.2, 23.2, 25.9, 28.3 | 0 hangs | 11.6 |
| 8 | 2 | wall walk | 29.6-35.9, 44.9-51.6, 63.3-69.9 (rep every 15, 18 s) | - | 29.6 |
| 16 | 4 | pull-up | hang 13.7-29.9 (16.3 s), pulls at 16.8, 18.8, 21.6, 23.6, 26.5, 29.7 | 0 hangs | 13.7 |
| 18 | 4 | wall walk | 32.3-38.9, 50.1-56.6, 68.6-77.2 (rep every 18, 18 s) | - | 32.3 |
| 26 | 6 | pull-up | hang 17.0-36.1 (19.1 s), pulls at 18.1, 21.3, 23.6, 25.9, 29.3, 32.1, 35.2 | 0 hangs | 17.0 |
| 28 | 6 | wall walk | 42.1-48.6, 60.5-66.7, 76.6-85.1 (rep every 18, 16 s) | - | 42.1 |

## Row and bike: stroke / revolution rate

Row on gx (forearm swings up at the finish), bike on vert (arm push-pull).

| seg | R | movement | segment s | cyclic window s | period s | rate /min | cycles counted |
|---:|---:|---|---:|---|---:|---:|---:|
| 0 | 1 | row | 50 | 1.0-47.0 | 2.48 | 24.2 | 18 |
| 5 | 2 | bike | 71 | 2.5-68.1 | 1.00 | 60.0 | 64 |
| 10 | 3 | row | 53 | 9.5-49.4 | 2.91 | 20.6 | 14 |
| 15 | 4 | bike | 87 | 0.5-84.7 | 1.09 | 55.0 | 77 |
| 20 | 5 | row | 62 | 2.5-57.3 | 2.29 | 26.2 | 24 |
| 25 | 6 | bike | 94 | 8.0-93.7 | 1.11 | 54.1 | 78 |
| 30 | 7 | row | 49 | 0.5-44.1 | 2.12 | 28.3 | 20 |

## Crown segment vs detected work (transition = lead-in before the first rep)

| movement | segs | Crown s (mean) | lead-in s (min..max) | work s (mean) | tail s (mean) |
|---|---:|---:|---|---:|---:|
| row | 4 | 54 | 1..10 | 46 | 4 |
| bike | 3 | 84 | 1..8 | 78 | 2 |
| pushup | 4 | 68 | 6..17 | 52 | 4 |
| pullup | 3 | 34 | 12..17 | 18 | 3 |
| cj | 4 | 74 | 9..42 | 48 | 4 |
| snatch | 3 | 51 | 17..22 | 29 | 2 |
| burpee | 4 | 126 | 11..28 | 105 | 1 |
| wallwalk | 3 | 81 | 30..42 | 43 | 3 |

## Features on the work window

Work window = detected sets / reps / cyclic part (push-ups: the three set windows only).

| seg | R | movement | gx p95 | gy p95 | vert min g | vert SD g | rot p99 rad/s | gx period s (acf r) | vert period s (acf r) | still frac | rises >0.5 | median rise gap s | lockout frac |
|---:|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0 | 1 | row | +0.53 | -0.03 | -0.65 | 0.18 | 4.0 | 2.48 (0.76) | 2.48 (0.30) | 0.00 | 12 | 2.5 | 0.00 |
| 1 | 1 | pushup | -0.82 | -0.09 | -0.04 | 0.02 | 1.9 | 7.14 (0.17) | 0.68 (0.49) | 1.00 | 0 | - | - |
| 2 | 1 | cj | +0.96 | +0.69 | -1.11 | 0.43 | 8.1 | 7.79 (0.76) | 7.79 (0.52) | 0.00 | 12 | 3.2 | 0.50 |
| 3 | 1 | burpee | +0.91 | +0.22 | -3.72 | 0.80 | 14.2 | 6.17 (0.52) | 0.98 (0.31) | 0.02 | 16 | 6.2 | 0.94 |
| 5 | 2 | bike | +0.04 | -0.40 | -0.56 | 0.24 | 3.7 | 1.02 (0.88) | 1.00 (0.89) | 0.00 | 0 | - | - |
| 6 | 2 | pullup | +1.01 | +0.35 | -0.14 | 0.19 | 3.9 | 2.51 (0.54) | 0.64 (0.07) | 0.77 | 0 | - | - |
| 7 | 2 | snatch | +0.97 | +0.89 | -2.41 | 0.72 | 10.7 | 2.37 (0.77) | 4.75 (0.49) | 0.00 | 12 | 2.3 | 0.92 |
| 8 | 2 | wallwalk | -0.76 | +0.13 | -0.61 | 0.17 | 4.1 | 1.80 (0.19) | 1.08 (0.25) | 0.44 | 0 | - | - |
| 10 | 3 | row | +0.47 | -0.39 | -0.45 | 0.16 | 4.1 | 2.91 (0.78) | 2.97 (0.36) | 0.02 | 7 | 4.5 | 0.00 |
| 11 | 3 | pushup | -0.80 | -0.11 | -0.05 | 0.02 | 1.9 | 2.47 (0.17) | 1.32 (0.41) | 1.00 | 0 | - | - |
| 12 | 3 | cj | +0.97 | +0.71 | -1.16 | 0.43 | 7.9 | 3.76 (0.77) | 7.55 (0.48) | 0.00 | 12 | 3.5 | 0.50 |
| 13 | 3 | burpee | +0.93 | +0.14 | -3.63 | 0.78 | 13.9 | 7.27 (0.71) | 0.99 (0.29) | 0.05 | 15 | 7.3 | 1.00 |
| 15 | 4 | bike | +0.03 | -0.34 | -0.64 | 0.22 | 3.2 | 1.09 (0.82) | 1.09 (0.91) | 0.00 | 0 | - | - |
| 16 | 4 | pullup | +1.01 | +0.31 | -0.08 | 0.17 | 3.2 | 2.49 (0.29) | 0.62 (0.07) | 0.86 | 0 | - | - |
| 17 | 4 | snatch | +0.98 | +0.90 | -2.82 | 0.77 | 11.3 | 2.31 (0.73) | 4.59 (0.43) | 0.00 | 12 | 2.3 | 0.92 |
| 18 | 4 | wallwalk | -0.70 | +0.19 | -0.67 | 0.17 | 4.0 | 1.81 (0.11) | 1.81 (0.33) | 0.43 | 0 | - | - |
| 20 | 5 | row | +0.30 | -0.31 | -0.74 | 0.21 | 5.9 | 2.29 (0.83) | 2.33 (0.45) | 0.00 | 1 | - | 0.00 |
| 21 | 5 | pushup | -0.57 | -0.13 | -0.04 | 0.01 | 1.7 | 3.67 (0.02) | 0.70 (0.40) | 1.00 | 0 | - | - |
| 22 | 5 | cj | +0.97 | +0.61 | -1.74 | 0.58 | 8.7 | 4.31 (0.47) | 3.32 (0.19) | 0.00 | 11 | 4.4 | 0.55 |
| 23 | 5 | burpee | +0.92 | +0.16 | -3.53 | 0.71 | 14.2 | 1.39 (-0.00) | 1.04 (0.26) | 0.04 | 15 | 8.0 | 1.00 |
| 25 | 6 | bike | +0.06 | -0.31 | -0.52 | 0.21 | 3.5 | 1.11 (0.76) | 1.11 (0.93) | 0.03 | 0 | - | - |
| 26 | 6 | pullup | +1.01 | +0.32 | -0.15 | 0.15 | 3.5 | 6.01 (0.28) | 0.63 (0.07) | 0.84 | 0 | - | - |
| 27 | 6 | snatch | +0.97 | +0.92 | -2.75 | 0.76 | 11.5 | 2.27 (0.75) | 4.49 (0.60) | 0.00 | 12 | 2.3 | 1.00 |
| 28 | 6 | wallwalk | -0.76 | +0.19 | -0.70 | 0.17 | 4.2 | 1.80 (0.11) | 1.74 (0.30) | 0.49 | 0 | - | - |
| 30 | 7 | row | +0.39 | -0.30 | -1.27 | 0.25 | 6.4 | 2.12 (0.80) | 2.14 (0.35) | 0.00 | 2 | 4.2 | 0.00 |
| 31 | 7 | pushup | -0.78 | -0.07 | -0.03 | 0.01 | 1.8 | 3.64 (0.11) | 0.67 (0.45) | 1.00 | 0 | - | - |
| 32 | 7 | cj | +0.97 | +0.66 | -1.48 | 0.53 | 8.1 | 4.12 (0.50) | 1.61 (0.17) | 0.00 | 11 | 4.2 | 0.55 |
| 33 | 7 | burpee | +0.93 | +0.21 | -3.80 | 0.85 | 14.4 | 6.12 (0.23) | 6.09 (0.26) | 0.02 | 15 | 6.1 | 1.00 |

## Which features separate the pairs (min-max per movement on the work window)

| pair | feature | A range | B range | separated | gap / spread |
|---|---|---|---|---|---:|
| row vs bike | p_gx | 2.12..2.91 | 1.02..1.11 | yes | +1.28 |
| row vs bike | gx_p95 | 0.30..0.53 | 0.03..0.06 | yes | +1.07 |
| row vs bike | c_v | 0.30..0.45 | 0.89..0.93 | yes | +2.83 |
| cj vs snatch | rise_gap | 3.18..4.43 | 2.25..2.32 | yes | +0.69 |
| cj vs snatch | lock_frac | 0.50..0.55 | 0.92..1.00 | yes | +4.45 |
| cj vs snatch | gy_p95 | 0.61..0.71 | 0.89..0.92 | yes | +1.69 |
| cj vs snatch | vert_min | -1.74..-1.11 | -2.82..-2.41 | yes | +1.06 |
| cj vs snatch | rot_p99 | 7.86..8.65 | 10.74..11.50 | yes | +2.61 |
| burpee vs wallwalk | vert_min | -3.80..-3.53 | -0.70..-0.61 | yes | +10.41 |
| burpee vs wallwalk | rot_p99 | 13.88..14.38 | 4.04..4.23 | yes | +19.29 |
| burpee vs wallwalk | gx_p95 | 0.91..0.93 | -0.76..-0.70 | yes | +23.67 |
| burpee vs wallwalk | rises | 15.00..16.00 | 0.00..0.00 | yes | +15.00 |
| burpee vs wallwalk | still_frac | 0.02..0.05 | 0.43..0.49 | yes | +6.30 |
| pushup vs pullup | gx_p95 | -0.82..-0.57 | 1.01..1.01 | yes | +6.43 |
| pushup vs pullup | vert_sd | 0.01..0.02 | 0.15..0.19 | yes | +3.90 |
| pushup vs pullup | still_frac | 1.00..1.00 | 0.77..0.86 | yes | +1.38 |
