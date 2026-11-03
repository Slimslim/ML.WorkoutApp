# Power C&J EMOM + Freedom · reps, sets and timing from the wrist, first analysis

One athlete (owner), watch on the left wrist, 100 Hz device motion, barbell (both hands on the bar,
so every rep is seen by the watch arm). Loads from README.md (owner). Reproduce with

    python3 tools/scratch/pcj_freedom_reps.py data/raw/2026-11-02-pcj-emom-freedom

Everything under "Script output" is that script's output, unedited.

**Accuracy caveats.** There is no video. The owner's plan (8 × 2 C&J, 5 × 7 cleans) is the only
ground truth, and the detector thresholds were chosen while looking at these two sessions, so
"16/16" and "35/35" are training accuracy. The speed numbers are wrist velocity from integrated,
4 Hz band-limited acceleration: good for comparing reps of one athlete, not a calibrated bar speed.
Phase boundaries (pull start, dip, lockout) are ±0.1-0.2 s; row starts ±3-5 s.

## How a barbell rep looks on the wrist

| phase | signal |
|---|---|
| floor / hang | forearm hanging: gx (gravity along the forearm) ≈ −1 |
| pull | wrist vertical velocity rises to a peak of 1.6-2.1 m/s in ~0.85-1.0 s |
| catch (front rack) | gx flips from < −0.5 to > +0.5 in **0.17-0.19 s** with a 4-8 g spike; rack = gx 0.65-0.9 with the wrist extended (gy +0.3..+0.6) |
| jerk | dip (wrist v ≈ −1.0 m/s) then drive (+1.2-1.5 m/s), lockout 0.6-0.8 s after the dip |
| lockout | gx > 0.93 with gy ≈ 0 (forearm vertical), held ~2-2.7 s |
| down | gx back below 0, a 3-8 g spike when the bar lands |

Nothing else in either session flips the forearm that fast: watch glances and row finishes take
0.35-1.5 s, keep the wrist rotated the other way (gy < −0.4) and stay under 3.5 g. That is why the
counts are clean: 16/16 C&J (all 16 with a detected lockout), 35/35 power cleans, 0 false
lockouts on the cleans, and no false catches in the rows.

**Sign of vertical acceleration.** CoreMotion's userAcceleration has the sign of gravity: a wrist
accelerating up shows a positive component *along* the gravity vector, so up = +(a · ĝ). With
the −(a · ĝ) used in `tools/scratch/squat_first_look.py` (and the "vert" of the AMRAP 40 scripts)
every pull integrates to a downward velocity and every bar drop to an upward one. Worth
re-checking the squat first look (its "bottoms" may be the tops); not changed here.

## Workout 1 · Every 1:00 × 8 power clean & jerk (125 → 175 lb)

| set | minute | load lb | reps (lockouts) | first pull after the minute mark | set length (first pull → bar down) | rest left | clean peak v | jerk drive v |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 125 | 2 (2) | 3.2 s | 14.5 s | 42 s | 1.95 | 1.33 |
| 2 | 2 | 135 | 2 (2) | 2.5 s | 17.4 s | 40 s | 1.84 | 1.32 |
| 3 | 3 | 145 | 2 (2) | 8.9 s | 18.8 s | 32 s | 1.89 | 1.35 |
| 4 | 4 | 145 | 2 (2) | 5.0 s | 17.0 s | 38 s | 1.88 | 1.33 |
| 5 | 5 | 155 | 2 (2) | 4.3 s | 19.8 s | 36 s | 1.97 | 1.30 |
| 6 | 6 | 155 | 2 (2) | 7.8 s | 22.0 s | 30 s | 1.80 | 1.45 |
| 7 | 7 | 165 | 2 (2) | 14.8 s | 21.9 s | 23 s | 1.70 | 1.28 |
| 8 | 8 | 175 | 2 (2) | 24.0 s | 23.9 s | 12 s | 1.62 | 1.30 |

* **Every set was done in its own minute**, 2 reps each, all 16 locked out. Sets took 15-24 s; the
  first pull came 2.5-24 s after the mark (median 6 s) and drifted later as the bar got heavier
  (8 s → 15 s → 24 s in the last three minutes: loading plates / waiting longer). One more C&J
  happened 38 s after the finish (9:21, with lockout); not counted.
* **Load-velocity**: clean peak wrist velocity falls with load, −0.13 m/s per 10 kg (r = −0.74 over
  16 reps; 1.95 m/s at 125 lb → 1.62 m/s at 175 lb). The jerk drive does not change (r ≈ 0): the
  jerk was never the limiter. The rack pause before the jerk grew (1.3 s → 2.6 s) and the time
  overhead too (2.2 → 2.7 s) on the heaviest sets.
* **Watch segments vs reality.** Only the first segment started right. Because the work part
  waited for the Crown, segment 0 ran 2:32 and contained sets 1-3; segments 1-5 (2:32-3:00) are
  catch-up turns with no lifting (errors +32 to +134 s against the EMOM clock). From 3:00 on the
  stations started on the minute (auto, ±0.2 s) and the rests started 4-6 s after the bar came
  down (Crown). In minute 7 the Crown came 27 s after the set (7:04), so the rest started late and
  set 8 (7:24-7:48) fell **inside a rest segment**; the following "station" 7:52-8:43 had no
  lifting at all. Net: only the station segments of minutes 4-7 hold exactly their own set; the per-segment summary is
  wrong for sets 1-3 and 8.
* HR rose 149 → 170 over the eight minutes; recovery after the finish: 152 → 135 (+60 s) → 118
  (+120 s). End came 2:23 after the finish, so no +180 s mark.

### What the EMOM auto-advance should do (from these timings)

1. **The minute is the boundary, not the Crown.** Start station k at start + k·60 s, always, and
   end the work part by itself. A Crown turn during the work part = "set done, start the rest
   now" (optional, only splits work/rest); a missed Crown must never shift later minutes.
2. **Default rest start without the Crown:** the real sets ended 14.5-24 s after the mark plus
   up to 24 s of lead-in, i.e. 18-48 s into the minute. A fixed split is wrong half the time; if
   the watch must guess, use motion: rest starts when the bar comes down after the last rep (gx
   below 0 after a lockout, then ≥ 5 s without a catch). Reps are reliable enough for that here.
3. **Count reps per minute from motion** (catch = fast forearm flip + spike; lockout for jerks) and
   show "2/2" — that is also the signal for "set done". Attach reps to the minute they happened
   in, not to the segment that happened to be open (set 8 here).
4. **Late start is information, not an error:** show the time from the mark to the first pull
   (here 3 → 24 s); it is the athlete's real rest pressure.
5. Keep minute 1 at the Start press (it was exact here); a 3-2-1 countdown to each mark is enough
   cue — this athlete did not need to touch the watch at all.

## Workout 2 · Freedom (row 40-30-20-30-40 cal, 7 power cleans at 155 lb after each, 19:37)

The definition says 85 kg; the owner used **155 lb (70 kg)**.

| round | row cal | strokes | rate /min | row → bar transition | cleans found | clean span | median gap | style | clean peak v | bar → row transition |
|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| 1 | 40 | 52 | 19.9 | 29.9 s | 7 | 68 s | 10.4 s | singles | 1.99 | 13.6 s |
| 2 | 30 | 43 | 19.8 | 30.7 s | 7 | 72 s | 11.4 s | singles | 1.93 | 16.7 s |
| 3 | 20 | 33 | 22.9 | 23.5 s | 7 | 68 s | 11.3 s | singles | 1.94 | 10.8 s |
| 4 | 30 | 48 | 20.8 | 24.1 s | 7 | 82 s | 11.5 s | singles | 1.89 | 13.3 s |
| 5 | 40 | 57 | 18.8 | 12.2 s | 7 | 31 s | 4.8 s | fast singles | 1.94 | – |

* **35/35 power cleans found**, 7 in every round, none outside the clean windows. All reps were
  singles (bar back to the floor; gaps 4.6-24 s, none < 3.5 s). Rounds 1-4: one rep every
  ~10-12 s; round 5 (last, 4.8 s apart) was much faster.
* **Speed held up**: clean peak velocity 1.89-1.99 m/s per round, −0.08 m/s over 35 reps (flat).
  At 155 lb this matches the EMOM sets 5-6 at the same load (1.97 / 1.80), a useful cross-check of
  the proxy across days of fatigue.
* **Rowing**: 19-23 strokes/min (2.6-3.2 s per stroke), 0.6-0.8 cal per stroke (strokes counted on
  the forearm swing at each finish; a new row counter, see the script: the AMRAP 40 cyclic window
  lost most of rounds 3 and 5 here).
* **Transitions** (motion-based): row → bar 12-31 s (getting off the erg, chalk, set-up; the
  Crown came 1-6 s after the last stroke, then 11-30 s until the first pull), bar → row 11-17 s
  (Crown 2-3 s after the last clean). Time budget: rowing 11:19, cleans 5:21, everything else
  2:57 of 19:37. `transitions.py` row onsets were right for rounds 3-4 but 15-20 s late for rounds
  1, 2 and 5 (it needs a well-correlated stroke rhythm; the first strokes ramp up).
* **HR**: rows 145-163 avg, cleans 163-170 avg, max 175 at the finish. Recovery 175 → 153 (+60 s,
  −22) → 135 (+120 s, −40) → 118 (+180 s, −57); the watch's own recovery events (155 / 137 / 117)
  agree within 2 bpm.

## Script output
### Workout 1 · Every 1:00 × 8 power clean & jerk

Start -0.02 s (session time), minute marks every 60 s, 8 sets planned, finish (Crown) at 8:43.

#### Every rep (session seconds; m:ss = since start)

| set | rep | pull start | catch (rack) | lockout | down | pull s | rack s | jerk dip→lockout s | overhead s | clean peak v m/s | jerk dip v | jerk drive v | peak g |
|---:|---:|---|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 1 | 3.2 (0:03) | 4.1 | 5.7 | 7.8 | 0.88 | 1.0 | 0.63 | 2.1 | 1.95 | -1.01 | 1.28 | 4.1 |
| 1 | 2 | 12.4 (0:12) | 13.2 | 15.5 | 17.7 | 0.84 | 1.6 | 0.64 | 2.3 | 1.95 | -1.14 | 1.38 | 4.8 |
| 2 | 1 | 62.4 (1:02) | 63.3 | 65.6 | 68.1 | 0.87 | 1.6 | 0.65 | 2.6 | 1.86 | -1.26 | 1.16 | 4.5 |
| 2 | 2 | 74.1 (1:14) | 75.0 | 77.4 | 79.9 | 0.82 | 1.8 | 0.65 | 2.4 | 1.82 | -0.97 | 1.47 | 5.1 |
| 3 | 1 | 128.8 (2:09) | 129.8 | 132.2 | 134.3 | 0.98 | 1.7 | 0.70 | 2.1 | 1.91 | -1.16 | 1.14 | 5.7 |
| 3 | 2 | 141.8 (2:22) | 142.6 | 145.4 | 147.7 | 0.84 | 2.0 | 0.70 | 2.3 | 1.88 | -0.99 | 1.57 | 5.5 |
| 4 | 1 | 185.0 (3:05) | 185.9 | 188.0 | 190.2 | 0.89 | 1.5 | 0.65 | 2.2 | 1.89 | -1.09 | 1.30 | 5.1 |
| 4 | 2 | 196.8 (3:17) | 197.7 | 199.9 | 202.0 | 0.91 | 1.5 | 0.71 | 2.1 | 1.87 | -1.22 | 1.37 | 6.1 |
| 5 | 1 | 244.3 (4:04) | 245.3 | 247.7 | 250.1 | 0.97 | 1.6 | 0.75 | 2.5 | 2.00 | -1.08 | 1.17 | 5.6 |
| 5 | 2 | 258.6 (4:19) | 259.5 | 261.9 | 264.2 | 0.88 | 1.7 | 0.72 | 2.3 | 1.95 | -0.84 | 1.43 | 6.0 |
| 6 | 1 | 307.7 (5:08) | 308.6 | 311.2 | 313.5 | 0.84 | 1.9 | 0.73 | 2.3 | 1.77 | -0.99 | 1.41 | 6.2 |
| 6 | 2 | 323.2 (5:23) | 324.1 | 327.4 | 329.8 | 0.86 | 2.6 | 0.70 | 2.4 | 1.82 | -0.96 | 1.49 | 5.4 |
| 7 | 1 | 374.7 (6:15) | 375.6 | 377.9 | 380.1 | 0.82 | 1.5 | 0.80 | 2.2 | 1.65 | -1.11 | 1.40 | 5.3 |
| 7 | 2 | 390.6 (6:31) | 391.5 | 394.0 | 396.6 | 0.90 | 1.8 | 0.67 | 2.6 | 1.75 | -1.20 | 1.16 | 5.9 |
| 8 | 1 | 444.0 (7:24) | 444.9 | 448.1 | 450.6 | 0.86 | 2.4 | 0.78 | 2.5 | 1.63 | -0.85 | 1.40 | 6.8 |
| 8 | 2 | 460.7 (7:41) | 461.6 | 465.2 | 467.9 | 0.95 | 2.7 | 0.79 | 2.8 | 1.61 | -0.95 | 1.21 | 6.2 |
| after finish | | 560.0 | 560.9 | 565.7 | 566.5 | 0.94 | | | | 1.94 | | | 4.9 |

16 catches before the finish, 16 with a jerk lockout; 1 after the finish.

#### Sets vs the minute marks

| set | minute (mark) | reps | first pull after mark s | set duration s (pull → last down) | rest until next mark s | HR avg / max in the minute |
|---:|---|---:|---:|---:|---:|---|
| 1 | 1 (0:00) | 2 | 3.2 | 14.5 | 42.3 | 149 / 155 |
| 2 | 2 (1:00) | 2 | 2.5 | 17.4 | 40.1 | 145 / 151 |
| 3 | 3 (2:00) | 2 | 8.9 | 18.8 | 32.3 | 151 / 159 |
| 4 | 4 (3:00) | 2 | 5.0 | 17.0 | 37.9 | 150 / 156 |
| 5 | 5 (4:00) | 2 | 4.3 | 19.8 | 35.8 | 155 / 162 |
| 6 | 6 (5:00) | 2 | 7.8 | 22.0 | 30.2 | 157 / 165 |
| 7 | 7 (6:00) | 2 | 14.8 | 21.9 | 23.4 | 164 / 167 |
| 8 | 8 (7:00) | 2 | 24.0 | 23.9 | 12.0 | 163 / 170 |

First pull 2.5-24.0 s after the mark (median 6.4); sets last 14.5-23.9 s (median 19.3).

#### Watch segments vs what happened

| seg | kind | source of start | start | end | dur s | should start at (EMOM clock) | error s | reps inside (set#) |
|---:|---|---|---|---|---:|---|---:|---|
| 0 | station | start | 0:00 | 2:32 | 151.6 | 0:00 | +0.0 | 6 (1,2,3) |
| 1 | rest | crown | 2:32 | 2:35 | 3.3 | 0:18 | +133.9 | 0 () |
| 2 | station | crown | 2:35 | 2:39 | 4.4 | 1:00 | +94.9 | 0 () |
| 3 | rest | crown | 2:39 | 2:57 | 17.4 | 1:20 | +79.4 | 0 () |
| 4 | station | crown | 2:57 | 2:59 | 2.4 | 2:00 | +56.7 | 0 () |
| 5 | rest | crown | 2:59 | 3:00 | 0.9 | 2:28 | +31.5 | 0 () |
| 6 | station | auto | 3:00 | 3:26 | 26.2 | 3:00 | +0.0 | 2 (4) |
| 7 | rest | crown | 3:26 | 4:00 | 33.9 | 3:22 | +4.2 | 0 () |
| 8 | station | auto | 4:00 | 4:29 | 28.9 | 4:00 | +0.2 | 2 (5) |
| 9 | rest | crown | 4:29 | 5:00 | 31.1 | 4:24 | +5.0 | 0 () |
| 10 | station | auto | 5:00 | 5:35 | 35.2 | 5:00 | +0.2 | 2 (6) |
| 11 | rest | crown | 5:35 | 6:00 | 24.7 | 5:30 | +5.6 | 0 () |
| 12 | station | auto | 6:00 | 7:04 | 63.5 | 6:00 | +0.1 | 2 (7) |
| 13 | rest | crown | 7:04 | 7:52 | 48.8 | 6:37 | +27.0 | 2 (8) |
| 14 | station | crown | 7:52 | 8:43 | 50.2 | 7:00 | +52.4 | 0 () |

Watch glances (wrist raised to read the screen): 6:04, 8:47, 9:38, 9:42, 10:21.

#### Bar-speed proxy by set (mean of the reps)

| set | load lb (kg) | clean peak v m/s | jerk drive v m/s | jerk dip v m/s | pull s | rack s | overhead s |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | 125 (57) | 1.95 | 1.33 | -1.08 | 0.86 | 1.3 | 2.2 |
| 2 | 135 (61) | 1.84 | 1.32 | -1.12 | 0.85 | 1.7 | 2.5 |
| 3 | 145 (66) | 1.89 | 1.35 | -1.08 | 0.91 | 1.9 | 2.2 |
| 4 | 145 (66) | 1.88 | 1.33 | -1.15 | 0.90 | 1.5 | 2.2 |
| 5 | 155 (70) | 1.97 | 1.30 | -0.96 | 0.93 | 1.7 | 2.4 |
| 6 | 155 (70) | 1.80 | 1.45 | -0.98 | 0.85 | 2.2 | 2.4 |
| 7 | 165 (75) | 1.70 | 1.28 | -1.16 | 0.86 | 1.7 | 2.4 |
| 8 | 175 (79) | 1.62 | 1.30 | -0.90 | 0.91 | 2.6 | 2.7 |

Clean peak v trend: -0.30 m/s over the 16 reps (linear fit).

Load-velocity (clean peak v vs kg, per rep): slope -0.127 m/s per 10 kg, r = -0.74; fit 1.98 m/s at 125 lb -> 1.69 m/s at 175 lb. Jerk drive v slope -0.012 m/s per 10 kg, r = -0.06.

#### Heart rate

| seg | kind | avg | max (JSON) |
|---:|---|---:|---:|
| 0 | station | 146 | 155 |
| 1 | rest | 149 | 149 |
| 2 | station | 157 | 157 |
| 3 | rest | 156 | 159 |
| 4 | station | - | - |
| 5 | rest | - | - |
| 6 | station | 148 | 151 |
| 7 | rest | 151 | 156 |
| 8 | station | 154 | 156 |
| 9 | rest | 156 | 162 |
| 10 | station | 153 | 161 |
| 11 | rest | 162 | 165 |
| 12 | station | 163 | 167 |
| 13 | rest | 163 | 167 |
| 14 | station | 160 | 170 |

Workout avg 155, max 170.

Recovery (HeartRateRecovery rules):

| | HR | drop |
|---|---:|---:|
| at finish (peak of last 10 s) | 152 | |
| +60 s (±7.5 s mean) | 135 | +17 |
| +120 s (±7.5 s mean) | 118 | +34 |
| recorded after finish | 143 s | |

5 s series finish → End: 149, 148, 140, 140, 142, 136, 136, 127, 132, 132, 132, 133, 135, 136, 136, 132, 125, 125, 126, 127, 129, 126, 125, 125, 115, 114, 118, 119, 117, 117

### Workout 2 · Freedom

Power cleans at 155 lb (70 kg, owner; the definition says 85 kg).

Start -0.00 s, finish 19:37 (Crown), End 22:50.

#### Rounds

| round | row cal | row segment | strokes window (from seg start) | strokes | period s | rate /min | cal/stroke | transitions.py row onset s (method, conf) | cleans segment | reps found | clean window |
|---:|---:|---|---|---:|---:|---:|---:|---|---|---:|---|
| 1 | 40 | 0:00-2:38 (158 s) | 0-154 | 52 | 3.01 | 19.9 | 0.77 | 20.0 (row, 0.75) | 2:38-4:15 (97 s) | **7** | 3:04-4:12 |
| 2 | 30 | 4:15-6:33 (138 s) | 10-137 | 43 | 3.02 | 19.8 | 0.70 | 25.0 (row, 0.90) | 6:33-8:17 (104 s) | **7** | 7:03-8:15 |
| 3 | 20 | 8:17-10:01 (104 s) | 14-98 | 33 | 2.62 | 22.9 | 0.61 | 15.0 (row, 0.75) | 10:01-11:30 (89 s) | **7** | 10:19-11:27 |
| 4 | 30 | 11:30-13:57 (147 s) | 8-143 | 48 | 2.88 | 20.8 | 0.62 | 5.5 (row, 0.90) | 13:57-15:43 (105 s) | **7** | 14:17-15:40 |
| 5 | 40 | 15:43-18:53 (190 s) | 10-189 | 57 | 3.20 | 18.8 | 0.70 | 29.8 (row, 0.90) | 18:53-19:37 (44 s) | **7** | 19:04-19:35 |

Power cleans found: **35** of 35.

#### Transitions (from motion; Crown = the watch's segment boundary)

| round | last stroke → Crown s | Crown → first pull s | **row → bar** (last stroke → first pull) s | last clean down → Crown s | Crown → first stroke s | **bar → row** (last clean down → first stroke) s |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 3.9 | 25.9 | **29.9** | 3.4 | 10.2 | **13.6** |
| 2 | 0.9 | 29.8 | **30.7** | 2.3 | 14.4 | **16.7** |
| 3 | 5.9 | 17.5 | **23.5** | 3.0 | 7.8 | **10.8** |
| 4 | 3.9 | 20.3 | **24.1** | 3.0 | 10.3 | **13.3** |
| 5 | 0.8 | 11.4 | **12.2** | 1.6 (finish) | - | - |

#### Every power clean

| round | rep | pull start (m:ss) | catch s | gap to previous catch s | style | pull s | rack s (catch → down) | clean peak v m/s | peak g |
|---:|---:|---|---:|---:|---|---:|---:|---:|---:|
| 1 | 1 | 3:04 | 184.7 | - | - | 1.01 | 1.1 | 2.10 | 5.8 |
| 1 | 2 | 3:11 | 192.5 | 7.7 | single | 0.98 | 1.2 | 2.00 | 5.9 |
| 1 | 3 | 3:21 | 201.7 | 9.3 | single | 0.95 | 1.1 | 1.95 | 7.1 |
| 1 | 4 | 3:31 | 211.5 | 9.7 | single | 0.96 | 1.2 | 1.92 | 6.8 |
| 1 | 5 | 3:43 | 224.2 | 12.8 | single | 0.95 | 1.0 | 2.02 | 7.1 |
| 1 | 6 | 3:59 | 239.6 | 15.3 | single | 0.99 | 1.1 | 1.98 | 6.8 |
| 1 | 7 | 4:10 | 250.6 | 11.0 | single | 0.99 | 1.1 | 1.96 | 7.0 |
| 2 | 1 | 7:03 | 424.0 | - | - | 1.01 | 1.1 | 1.95 | 7.0 |
| 2 | 2 | 7:13 | 434.0 | 9.9 | single | 1.00 | 1.1 | 1.95 | 6.7 |
| 2 | 3 | 7:25 | 445.6 | 11.6 | single | 1.00 | 1.1 | 2.06 | 6.3 |
| 2 | 4 | 7:36 | 456.7 | 11.1 | single | 0.95 | 1.1 | 1.93 | 7.1 |
| 2 | 5 | 7:48 | 469.0 | 12.3 | single | 0.96 | 1.1 | 1.92 | 7.0 |
| 2 | 6 | 8:01 | 482.4 | 13.4 | single | 1.00 | 1.1 | 1.91 | 6.8 |
| 2 | 7 | 8:13 | 493.5 | 11.1 | single | 0.98 | 1.2 | 1.78 | 7.0 |
| 3 | 1 | 10:19 | 619.9 | - | - | 1.00 | 1.1 | 1.91 | 7.0 |
| 3 | 2 | 10:29 | 630.0 | 10.1 | single | 0.96 | 1.1 | 1.96 | 4.9 |
| 3 | 3 | 10:39 | 640.2 | 10.2 | single | 0.97 | 1.1 | 1.93 | 5.8 |
| 3 | 4 | 10:51 | 651.5 | 11.3 | single | 0.97 | 1.2 | 1.97 | 6.2 |
| 3 | 5 | 11:02 | 663.1 | 11.5 | single | 0.99 | 1.2 | 1.88 | 5.9 |
| 3 | 6 | 11:13 | 674.4 | 11.4 | single | 0.98 | 1.1 | 2.00 | 6.6 |
| 3 | 7 | 11:25 | 685.8 | 11.3 | single | 1.00 | 1.2 | 1.93 | 6.7 |
| 4 | 1 | 14:17 | 858.4 | - | - | 1.01 | 1.2 | 1.89 | 5.7 |
| 4 | 2 | 14:42 | 882.8 | 24.4 | single | 0.98 | 1.2 | 1.94 | 6.6 |
| 4 | 3 | 14:52 | 892.6 | 9.9 | single | 0.98 | 1.1 | 1.82 | 7.6 |
| 4 | 4 | 15:03 | 904.5 | 11.8 | single | 1.00 | 1.1 | 1.95 | 5.8 |
| 4 | 5 | 15:15 | 916.3 | 11.9 | single | 1.01 | 1.1 | 1.99 | 6.9 |
| 4 | 6 | 15:27 | 927.6 | 11.2 | single | 0.95 | 1.1 | 1.82 | 5.9 |
| 4 | 7 | 15:37 | 938.4 | 10.8 | single | 0.99 | 1.2 | 1.85 | 5.8 |
| 5 | 1 | 19:04 | 1145.0 | - | - | 1.00 | 1.0 | 1.95 | 5.1 |
| 5 | 2 | 19:09 | 1150.2 | 5.2 | single | 1.10 | 1.0 | 2.06 | 5.5 |
| 5 | 3 | 19:14 | 1155.1 | 5.0 | single | 1.01 | 1.1 | 1.93 | 6.4 |
| 5 | 4 | 19:19 | 1159.9 | 4.8 | single | 1.01 | 1.0 | 1.95 | 5.3 |
| 5 | 5 | 19:24 | 1164.7 | 4.8 | single | 1.00 | 1.0 | 1.89 | 5.8 |
| 5 | 6 | 19:29 | 1169.6 | 4.8 | single | 1.05 | 1.0 | 2.01 | 5.9 |
| 5 | 7 | 19:33 | 1174.2 | 4.6 | single | 0.98 | 1.2 | 1.82 | 6.9 |

Jerk-lockout check on the cleans (should be none): 0.

#### Pace and speed proxy per round

| round | reps | first pull → last down s | median gap s (min-max) | singles / TnG | sec per rep | clean peak v mean m/s (min-max) | rack s mean | HR avg / max row | HR avg / max cleans |
|---:|---:|---:|---|---|---:|---|---:|---|---|
| 1 | 7 | 68.0 | 10.4 (7.7-15.3) | 6 / 0 | 9.7 | 1.99 (1.92-2.10) | 1.1 | 145 / 163 | 165 / 167 |
| 2 | 7 | 71.8 | 11.4 (9.9-13.4) | 6 / 0 | 10.3 | 1.93 (1.78-2.06) | 1.1 | 162 / 166 | 163 / 165 |
| 3 | 7 | 68.1 | 11.3 (10.1-11.5) | 6 / 0 | 9.7 | 1.94 (1.88-2.00) | 1.1 | 160 / 165 | 163 / 168 |
| 4 | 7 | 82.2 | 11.5 (9.9-24.4) | 6 / 0 | 11.7 | 1.89 (1.82-1.99) | 1.1 | 163 / 169 | 163 / 167 |
| 5 | 7 | 31.4 | 4.8 (4.6-5.2) | 6 / 0 | 4.5 | 1.94 (1.82-2.06) | 1.1 | 163 / 167 | 170 / 175 |

Clean peak v trend: -0.08 m/s over the 35 reps (linear fit).

#### Time budget

Rowing (stroke windows) 11:19, cleans (first pull → last down) 5:21, everything else (transitions, set-up, start) 2:57 of 19:37.

#### Heart-rate recovery (HeartRateRecovery rules)

| | HR | drop |
|---|---:|---:|
| at finish (peak of last 10 s) | 175 | |
| +60 s (±7.5 s mean) | 153 | +22 |
| +120 s (±7.5 s mean) | 135 | +40 |
| +180 s (±7.5 s mean) | 118 | +57 |
| recorded after finish | 193 s | |

5 s series finish → End: 175, 175, 176, 175, 170, 167, 167, 160, 160, 160, 156, 156, 155, 147, 145, 139, 139, 143, 143, 142, 139, 137, 136, 136, 137, 133, 126, 126, 127, 128, 129, 126, 124, 123, 120, 119, 117, 117, 118
