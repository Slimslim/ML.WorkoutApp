# Transitions: how much of each split is getting to the work

> **Status: Python prototype (2026-11-01), not in the app.** Code: `tools/barpath/transitions.py`,
> tests: `tools/tests/test_transitions.py`. One athlete (the owner), left wrist, four sessions.
> Reproduce every table below with
>
>     python3 tools/barpath/transitions.py data/raw/<session folder>

## What we measure

The athlete turns the Crown as soon as a movement ends, so every Crown segment is

    Crown ── transition (walk over, chalk, set the erg, pick up the DB, wait) ── first rep ── work ── Crown

`work_onset(movement, motion, seg_start, seg_end)` returns the **onset**: seconds from the Crown
turn to the first real rep / stroke / running stride, plus a confidence and the detector used.
**transition = onset, work = segment − onset.** Example from AMRAP 40, round 6:
**Bike 1:34 = 0:08 transition + 1:26 work.** Rests have no transition. If nothing is found the
whole segment counts as work (onset `None`, confidence 0).

## Method

Each segment is analysed on its own motion slice (100 Hz device motion; `vert` = −userAccel·gravity
band-passed 0.2–3 Hz; `gx` = gravity along the forearm, +1 = hand overhead, −1 = arm hanging).
A movement-specific detector runs first, and a generic one always runs as a cross-check.

| family (movement ids) | what marks the first rep | reused from |
|---|---|---|
| run | running cadence 130–200 steps/min on \|userAccel\| (4 s windows, 6 s debounce) | `segments.detect_running` |
| row, skiErg | `gx` cyclic at 1.5–4 s per stroke: a 4 s window correlates (r > 0.5) with the window one period later for ≥ 5 s, then moved to where the stroke amplitude reaches half its level | amrap40 `cyclic_window` |
| bike | same on `vert`, 0.6–2 s per revolution | amrap40 `cyclic_window` |
| overhead (DB snatch, wall balls, thrusters, devil press) | first rep of a rhythmic train (≥ 3 rises, gaps ≤ 2.5 × median gap, 4–15 s) of `gx` rising through +0.7 after < −0.3; onset = start of that arm lift | amrap40 `overhead_rises` + `trim_rhythm` |
| DB clean & jerk | same, through +0.5 (other-hand reps only lift the watch arm to 0.6–0.9) | amrap40 `cj_reps` |
| burpees | overhead rise with a landing impulse (vert < −1.5 g within 2 s); onset = end of the last still moment in the 4 s before that jump (the drop to the floor), else jump − 2 s | amrap40 `burpee_reps` |
| KB swings | gravity.x flips (range ≥ 1 in 1 s windows, 3 s sustained) | `segments.kb_swing_onset` |
| pull-ups | forearm up (gx > 0.8) ≥ 3 s (strict), or `bar_hangs` (kipping); the earlier | `segments.bar_hangs`, amrap40 `pullup_reps` |
| push-ups | hand planted (vert 1 s SD < 0.04 g, gx < −0.5) while the body moves (\|rot\| RMS > 0.35) ≥ 3 s | amrap40 `floor_bouts` |
| wall walks | 4–12 s burst of hand placements with the forearm down | amrap40 `wallwalk_reps` |
| double unders | \|userAccel\| 1 s SD > 0.9 g for ≥ 2 s | new |
| DB walking lunges | DB racked: gx > 0.5 held ≥ 5 s | partner WOD README |
| **generic** (anything else: sleds, carries, sandbag lunges, step-overs, air squats…) | 3 s motion energy (SD of \|userAccel\| + 0.1 · RMS \|rot\|) above the segment's own baseline (p10 + 40 % of p10..p90) for ≥ 3 s, dips < 2 s tolerated | new |

**Confidence:** 0.9 = movement detector, and the generic detector agrees within 8 s;
0.75 = movement detector only; 0.5 = generic only; 0 = nothing found.

The generic detector agrees with the movement detectors within 5 s on **37 of 39** vigorous
segments (row, bike, C&J, snatch, burpees, KB, double unders, devil press) but is **useless for
planted-hand movements** (push-ups, wall walks, strict pull-ups: it fires on the walk over, at
0–3 s), because those are quieter than walking. Its onsets come out ~1 s early (centred window).

## Results

`specific / generic` = the two detectors' answers (s). `walking` = seconds of the transition that
look like walking (cadence 80–135/min); it is mostly 0–6 s because the walk to the next station is
short and mixed with picking things up.

### AMRAP 40, 2026-11-01 (odd rounds row / push-ups / C&J / burpees, even rounds bike / pull-ups / snatch / wall walks)

| # | movement | total | transition | work | conf | method | specific / generic s | walking in transition s |
|---:|---|---:|---:|---:|---:|---|---|---:|
| 0 | row | 0:50 | 0:01 | 0:49 | 0.90 | row | 1.0 / 7.9 | 0 |
| 1 | pushup | 0:56 | 0:06 | 0:51 | 0.90 | pushup | 5.7 / 0.6 | 0 |
| 2 | cj | 0:59 | 0:10 | 0:49 | 0.90 | overhead_cj | 9.9 / 10.6 | 4 |
| 3 | burpee | 1:58 | 0:11 | 1:47 | 0.90 | burpee | 10.8 / 11.2 | 2 |
| 4 | rest | 1:00 | – | – | – | rest | | |
| 5 | bike | 1:11 | 0:03 | 1:09 | 0.90 | bike | 2.5 / 5.8 | 0 |
| 6 | pullup | 0:31 | 0:12 | 0:20 | 0.75 | pullup | 11.6 / 3.5 | 0 |
| 7 | snatch | 0:55 | 0:24 | 0:31 | 0.90 | overhead | 23.5 / 22.0 | 2 |
| 8 | wallwalk | 1:16 | 0:30 | 0:46 | 0.75 | wallwalk | 29.6 / 0.0 | 2 |
| 9 | rest | 1:00 | – | – | – | rest | | |
| 10 | row | 0:53 | 0:10 | 0:44 | 0.90 | row | 9.5 / 6.3 | 0 |
| 11 | pushup | 1:13 | 0:17 | 0:56 | 0.75 | pushup | 16.7 / 0.6 | 0 |
| 12 | cj | 1:08 | 0:21 | 0:47 | 0.90 | overhead_cj | 21.2 / 22.0 | 6 |
| 13 | burpee | 2:14 | 0:28 | 1:46 | 0.90 | burpee | 28.4 / 28.1 | 2 |
| 14 | rest | 1:00 | – | – | – | rest | | |
| 15 | bike | 1:27 | 0:01 | 1:26 | 0.90 | bike | 1.0 / 0.0 | 0 |
| 16 | pullup | 0:33 | 0:14 | 0:20 | 0.90 | pullup | 13.7 / 8.1 | 2 |
| 17 | snatch | 0:48 | 0:19 | 0:30 | 0.90 | overhead | 18.6 / 18.1 | 0 |
| 18 | wallwalk | 1:19 | 0:32 | 0:47 | 0.75 | wallwalk | 32.3 / 0.0 | 2 |
| 19 | rest | 1:00 | – | – | – | rest | | |
| 20 | row | 1:02 | 0:04 | 0:58 | 0.90 | row | 3.8 / 0.0 | 0 |
| 21 | pushup | 1:12 | 0:13 | 0:59 | 0.75 | pushup | 12.7 / 2.1 | 2 |
| 22 | cj | 1:37 | 0:44 | 0:53 | 0.90 | overhead_cj | 43.9 / 44.9 | 4 |
| 23 | burpee | 2:24 | 0:25 | 1:59 | 0.90 | burpee | 25.4 / 26.4 | 6 |
| 24 | rest | 1:00 | – | – | – | rest | | |
| 25 | bike | 1:34 | 0:08 | 1:26 | 0.90 | bike | 8.0 / 3.2 | 0 |
| 26 | pullup | 0:39 | 0:17 | 0:22 | 0.75 | pullup | 17.0 / 2.9 | 0 |
| 27 | snatch | 0:50 | 0:19 | 0:30 | 0.90 | overhead | 19.2 / 19.0 | 4 |
| 28 | wallwalk | 1:27 | 0:42 | 0:45 | 0.75 | wallwalk | 42.1 / 17.0 | 10 |
| 29 | rest | 1:00 | – | – | – | rest | | |
| 30 | row | 0:49 | 0:00 | 0:48 | 0.75 | row | 0.5 / 8.9 | 0 |
| 31 | pushup | 1:11 | 0:15 | 0:56 | 0.75 | pushup | 15.0 / 0.0 | 0 |
| 32 | cj | 1:11 | 0:17 | 0:54 | 0.90 | overhead_cj | 17.3 / 18.2 | 6 |
| 33 | burpee | 1:47 | 0:17 | 1:30 | 0.90 | burpee | 16.7 / 17.0 | 0 |
| 34 | rest | 0:06 | – | – | – | rest | | |

Time in transitions: **7:38** of 33:54 non-rest time (23 %).

| movement | n | transition s (min–max) | mean transition | mean segment |
|---|---:|---|---:|---:|
| row | 4 | 0–10 | 4 | 54 |
| bike | 3 | 1–8 | 4 | 84 |
| push-ups | 4 | 6–17 | 13 | 68 |
| pull-ups | 3 | 12–17 | 14 | 34 |
| DB C&J | 4 | 10–44 | 23 | 74 |
| DB snatch | 3 | 19–24 | 20 | 51 |
| burpees | 4 | 11–28 | 20 | 126 |
| wall walks | 3 | 30–42 | 35 | 81 |

**AMRAP 40 bike:** 0:03 / 0:01 / 0:08 transition (1:11 = 0:03 + 1:09, 1:27 = 0:01 + 1:26,
1:34 = 0:08 + 1:26). **Row:** 0:01 / 0:10 / 0:04 / 0:00. The erg transitions are short because the
1:00 rest before them already contains the walk over (the rest segments show 4–12 s of walking
and arm movement); 0:10 in round 3 is the one where the strokes took a while to settle.

### Helen, 2026-10-29 (3 × 400 m run, 21 KB swings, 12 pull-ups)

| # | movement | total | transition | work | conf | method | specific / generic s | walking in transition s |
|---:|---|---:|---:|---:|---:|---|---|---:|
| 0 | run | 2:09 | 0:08 | 2:01 | 0.90 | run | 8.0 / 2.1 | 0 |
| 1 | kettlebellSwings | 0:53 | 0:10 | 0:43 | 0.90 | kb | 9.5 / 9.7 | 4 |
| 2 | pullUps | 0:55 | 0:04 | 0:50 | 0.90 | pullup | 4.5 / 8.9 | 0 |
| 3 | run | 2:29 | 0:02 | 2:27 | 0.90 | run | 2.0 / 6.1 | 0 |
| 4 | kettlebellSwings | 0:53 | 0:08 | 0:44 | 0.90 | kb | 8.5 / 7.5 | 6 |
| 5 | pullUps | 1:02 | 0:03 | 1:00 | 0.90 | pullup | 2.8 / 1.6 | 0 |
| 6 | run | 2:36 | 0:04 | 2:32 | 0.75 | run | 4.0 / 12.1 | 0 |
| 7 | kettlebellSwings | 0:57 | 0:12 | 0:45 | 0.90 | kb | 12.0 / 12.4 | 6 |
| 8 | pullUps | 0:55 | 0:11 | 0:44 | 0.90 | pullup | 11.0 / 16.2 | 0 |

Time in transitions: **1:02** of 12:47 non-rest time (8 %).

### Nightmare AMRAP 20, 2026-10-30 (lateral burpees over DB, double unders, DB snatch, double unders)

Segments 11–13 are wrong in the saved result (Crown/Undo mix-up in round 4, see the README):
segment 11 holds DU round 3 plus burpees round 4 plus 22 s of fixing the watch, 12–13 are 2–3 s
artefacts. Lateral burpees have no overhead reach, so they fall back to the generic detector.

| # | movement | total | transition | work | conf | method | specific / generic s | walking in transition s |
|---:|---|---:|---:|---:|---:|---|---|---:|
| 0 | lateralBurpeeOverDumbbell | 0:43 | 0:00 | 0:43 | 0.50 | generic(burpee) | - / 0.0 | 0 |
| 1 | doubleUnders | 0:34 | 0:04 | 0:30 | 0.90 | jumprope | 4.2 / 3.2 | 0 |
| 2 | dumbbellSnatch | 0:29 | 0:05 | 0:25 | 0.90 | overhead | 4.6 / 6.8 | 0 |
| 3 | doubleUnders | 0:50 | 0:08 | 0:43 | 0.90 | jumprope | 7.6 / 6.2 | 0 |
| 4 | lateralBurpeeOverDumbbell | 0:58 | 0:05 | 0:53 | 0.50 | generic(burpee) | - / 4.6 | 0 |
| 5 | doubleUnders | 0:52 | 0:12 | 0:40 | 0.90 | jumprope | 11.5 / 10.4 | 0 |
| 6 | dumbbellSnatch | 0:34 | 0:07 | 0:26 | 0.90 | overhead | 7.4 / 5.5 | 0 |
| 7 | doubleUnders | 0:46 | 0:20 | 0:26 | 0.90 | jumprope | 20.3 / 19.2 | 0 |
| 8 | lateralBurpeeOverDumbbell | 1:04 | 0:06 | 0:57 | 0.50 | generic(burpee) | - / 6.4 | 0 |
| 9 | doubleUnders | 0:34 | 0:13 | 0:21 | 0.90 | jumprope | 12.6 / 11.2 | 0 |
| 10 | dumbbellSnatch | 0:53 | 0:27 | 0:27 | 0.90 | overhead | 26.7 / 26.2 | 4 |
| 11 | doubleUnders | 3:18 | 0:20 | 2:58 | 0.90 | jumprope | 19.6 / 18.3 | 0 |
| 12 | lateralBurpeeOverDumbbell | 0:02 | 0:00 | 0:02 | 0.00 | none | - / - | 0 |
| 13 | doubleUnders | 0:03 | 0:00 | 0:03 | 0.00 | none | - / - | 0 |
| 14 | dumbbellSnatch | 0:55 | 0:17 | 0:38 | 0.90 | overhead | 17.1 / 16.7 | 2 |
| 15 | doubleUnders | 0:40 | 0:18 | 0:22 | 0.90 | jumprope | 18.2 / 17.0 | 0 |
| 16 | lateralBurpeeOverDumbbell | 1:14 | 0:11 | 1:03 | 0.50 | generic(burpee) | - / 10.7 | 0 |
| 17 | doubleUnders | 0:35 | 0:12 | 0:22 | 0.90 | jumprope | 12.3 / 11.2 | 0 |
| 18 | dumbbellSnatch | 1:10 | 0:26 | 0:44 | 0.90 | overhead | 26.3 / 24.7 | 0 |
| 19 | doubleUnders | 0:50 | 0:18 | 0:32 | 0.90 | jumprope | 18.4 / 17.1 | 0 |
| 20 | lateralBurpeeOverDumbbell | 1:13 | 0:11 | 1:02 | 0.50 | generic(burpee) | - / 10.5 | 0 |
| 21 | doubleUnders | 0:49 | 0:16 | 0:33 | 0.90 | jumprope | 15.8 / 14.4 | 0 |
| 22 | dumbbellSnatch | 0:38 | 0:14 | 0:24 | 0.90 | overhead | 13.9 / 12.1 | 0 |
| 23 | doubleUnders | 0:16 | 0:09 | 0:07 | 0.90 | jumprope | 8.6 / 7.5 | 0 |

Time in transitions: **4:38** of 20:00 non-rest time (23 %).

### Partner WOD 1, 2026-10-31 (doubles: runs together, stations split)

**Read with care.** In a doubles station the partner starts, so the "transition" here is walk-over
**plus waiting for the partner's first set**; the athlete's own wrist cannot tell the two apart.
Wall balls 23 s and burpees 27 s match the README (partner went first, sets of 20–24 s). Lunges
16 s = the first DB rack hold (~729 s in the README). Devil press 20 s ≈ the first burst at
1340 s (segment start 1322 s). Med-ball step-overs: no detector, generic fired on the walk-over
(0 s, almost certainly too early).

| # | movement | total | transition | work | conf | method | specific / generic s | walking in transition s |
|---:|---|---:|---:|---:|---:|---|---|---:|
| 0 | run | 4:41 | 0:06 | 4:35 | 0.90 | run | 6.0 / 4.0 | 0 |
| 1 | wallBalls | 3:24 | 0:23 | 3:01 | 0.50 | generic(overhead) | - / 23.4 | 14 |
| 2 | run | 3:47 | 0:02 | 3:45 | 0.75 | run | 2.0 / 19.8 | 0 |
| 3 | dumbbellWalkingLunges | 2:10 | 0:16 | 1:54 | 0.75 | rack | 16.1 / 0.0 | 10 |
| 4 | run | 2:28 | 0:06 | 2:22 | 0.90 | run | 6.0 / 11.1 | 0 |
| 5 | burpees | 2:27 | 0:27 | 2:01 | 0.50 | generic(burpee) | - / 26.6 | 0 |
| 6 | run | 1:11 | 0:06 | 1:05 | 0.90 | run | 6.0 / 5.8 | 2 |
| 7 | medBallBoxStepOvers | 1:17 | 0:00 | 1:17 | 0.50 | generic | - / 0.0 | 0 |
| 8 | run | 0:35 | 0:04 | 0:31 | 0.90 | run | 4.0 / 1.4 | 0 |
| 9 | devilPress | 1:08 | 0:20 | 0:48 | 0.90 | overhead | 19.7 / 14.8 | 2 |

Time in transitions: **1:50** of 23:09 non-rest time (8 %).

## Sanity checks

- **Against the rep-counting prototype** (`data/raw/2026-11-01-amrap40/ANALYSIS.md`, built
  independently from the rep detectors): pull-up hangs 11.6 / 13.7 / 17.0 s, wall walks
  29.6 / 32.3 / 42.1 s, C&J and snatch first reps, and row/bike cyclic windows all agree within
  1–2 s; burpee onsets are by design 1–3 s before that script's first jump (the drop to the
  floor starts the rep) (pinned in `test_amrap40_lead_in_matches_rep_counter`). Not independent evidence (same
  signals, same author), but the transition numbers are consistent with the rep counts.
- **Row/bike vs walking over:** in AMRAP 40 every row/bike follows a 1:00 rest, and the walking is
  in the rest (4–12 s of walking-like windows per rest). The erg transitions (0–10 s) contain no
  walking at all, only sitting down / strapping in. The very first segment (row, 1.0 s) starts at
  the rower. So short erg transitions are what we expect here; in HYROX (run → SkiErg/row) they
  will be longer.
- **Helen:** KB transitions 10 / 8 / 12 s match the README ("~7–9 s of arms-down walking at the
  start of each KB segment"); 4–6 s of each is walking-like. Run onsets 8 / 2 / 4 s match "run
  start 2–8 s after the Crown" (the first, 8 s, is the start of the workout). Pull-ups 4 / 3 / 11 s:
  the bar was next to the kettlebell; round 2 starts with a 1-rep set at 2.8 s (label `1-2-3-3-3`),
  round 3 with a short arm-up at 3–6 s that is not a set, first set at 11 s.
- **Generic vs specific:** 37/39 within 5 s on vigorous movements (above).
- **Totals:** time in transitions is 8 % (Helen, partner WOD) to 23 % (AMRAP 20 and 40) of the
  non-rest time. In AMRAP 40 that is **7:38 of 33:54**: wall walks (1:44 in total), C&J (1:32)
  and burpees (1:21) cost the most.

## Where it is unreliable

1. **One athlete, one wrist, thresholds fitted on the same sessions.** Every number above is
   training accuracy. No video/rep timestamps to validate onsets against (±2 s is our guess at
   the precision where two detectors agree).
2. **Planted-hand movements** (push-ups, wall walks, strict pull-ups) depend entirely on the
   movement detector; the generic fallback is wrong there. A new planted movement (e.g. bear
   crawl, sled push) would get a wrong ~0 s transition.
3. **"Transition" is a definition, not an observation.** Standing at the bar before jumping up,
   chalking, a 2 s grab-and-drop before a pull-up set (AMRAP 40 R4), resting in front of the
   dumbbell before the first rep (C&J R5: 44 s) all count as transition. That is usually what the
   athlete means ("time before I started"), but it is also partly fatigue/rest, not walking.
4. **Partner workouts:** transition includes the partner's set. Needs the partner's split (or a
   "partner first" flag) to separate.
5. **Crown errors** shift everything (AMRAP 20 round 4).
6. **First segment** of a workout: there is no walk-over, the "transition" is set-up.
7. **Offline only:** zero-phase FFT filters over the whole segment. On the watch this should run
   when the segment closes (causal filters), not live.

## On the phone overview (proposal)

Keep it to two things:

1. **Each split bar gets a lighter leading part** for the transition, the solid rest for the work
   (same hue: light blue / blue for runs, light orange / orange for stations). Tapping the bar
   shows the chip `Bike 1:34 · 0:08 getting there + 1:26 work`. Low-confidence onsets (< 0.75)
   are drawn without the split (one solid bar), never guessed. No transition on rests.
2. **One line under the score:** `Time in transitions 7:38 (23 %)` — the total of the light parts
   over non-rest time, and compared with the previous attempt of the same workout when there is
   one. For rounds/AMRAP formats an optional per-movement summary in the folded table: `Wall walks:
   35 s average before the first rep`.

Wording: "getting there" or "transition" (HYROX athletes already say transition/roxzone).

## For HYROX

In HYROX the transition before each station and each run **is the Roxzone** (from the run to the
station mat and back). With the Crown turned when a movement ends:

- **Station segment:** onset = first SkiErg/row stroke, first sled push, first burpee broad jump,
  etc. The part before it ≈ Roxzone in + set-up. SkiErg/row reuse the cyclic detector (SkiErg
  needs a check: both arms pull down, period ~1.5–2.5 s). Sled push/pull, farmers carry and
  sandbag lunges currently fall back to the generic detector, which will be weak for the sled
  push (hands planted, like push-ups) → first thing to record and label.
- **Run segment:** onset = running cadence; the part before it ≈ Roxzone out (and the time spent
  standing after the station). This works today (Helen, partner WOD: 2–8 s).
- Show it as **"Roxzone" per station and a total**, the number HYROX results already report, so
  the athlete can compare with the official split. Validation needed: a race or simulation with
  the official Roxzone times (timing mats) next to ours.
