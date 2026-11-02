# Review: proposal v1 from the athlete's side (CF-L2 / HYROX Elite 15 lens)

**Verdict:** The tabs match the athlete's day: read the board, train, check the score, see the trend. The weak part is the model underneath. A workout is still a flat list of segments, but athletes think in **sessions**, **blocks**, **prescriptions** (%1RM, Rx/Scaled) and **results** (score type, scaling, team). The build order also puts most HYROX P1 work after Anaheim.

## 1. Scenario walk (P1 scenarios with training content)

| ID | Verdict | Why |
|---|---|---|
| S-09 | Partial | Schedule comes after the race. "Last sent" covers it by accident. |
| S-10 | Partial | Photo comes after the race, so before Anaheim it's paste only. |
| S-11 | Partial | Paste exists. No Share Sheet entry. |
| S-12 | Partial | The preview has no Rx/Scaled/Foundations tracks and no best per track. |
| S-13 | Fails | No division setting (Open/Pro, M/W, Doubles) to set sled and wall-ball loads. |
| S-19 | Partial | Good confirm screen, but no track picker. |
| S-20 | Fails | One format per workout, so strength + metcon + finisher can't be expressed. |
| S-21 | Partial | Builder deferred. No EMOM, Intervals/Tabata or HYROX format. |
| S-24 | Works | Flagged line kept as free text. |
| S-26 | Partial | Rx/scaled is on the definition only, not the result or the watch. |
| S-28 | Fails | No partner model. Saturday WODs show as a plain time. |
| S-29 | Fails | No doubles mode or "partner working" state. |
| S-30 | Works | Show "CAP + 7", ranked below any finish. |
| S-31 | Partial | No alternating minutes or failed-minute marking. |
| S-32 | Works | Add work vs rest totals to the report. |
| S-33 | Fails | No 1RM store, % resolution or plate rounding. |
| S-35 | Partial | Question 5 is open. The watch has separate lift and WOD starts. |
| S-38 | Works | Big segment, next preview, progress border. |
| S-39 | Partial | No distance segment. Calibration sits in Insights. |
| S-42 | Partial | Missing from the watch home. |
| S-46 / S-79 | Fails | Ahead/behind isn't in the build order before Anaheim. |
| S-49 / S-51 | Works | Needs a plate-step stepper and a load edit afterwards. |
| S-63 | Fails | No way to log a result without the watch. |
| S-65 | Partial | Scaling isn't on the result, so PRs can't update. |
| S-67 | Works | The "Last result" card does it. Add a PR badge. |
| S-77, S-80 | Fails | Insights only. No race-plan editor, no build slot. |
| S-78, S-82 | Partial | Watch is standalone. Calibration has no home. |

**Tally:** 7 work, 15 partial, 11 fail, almost all from the data model, not navigation.

## 2. Top 10 findings (ranked)

1. **The HYROX race items come after the race.** Move these into "Before Anaheim": race-plan editor (targets per run, station and roxzone, prefilled from the best sim), ahead/behind on the watch, roxzone as its own segment, division presets and calibration. They matter more than the new tab bar.
2. **Use Session → Block → Segment.** A gym day is one Session (one Log row, one HKWorkout) with blocks (Warm-up, Strength, WOD, Finisher, Cool-down), each with its own format, score type and report. This answers question 5 and fixes S-20, S-35 and S-36.
3. **Scaling belongs to the result.** Each result gets a level (Rx+, Rx, Scaled, Foundations, Custom) and per-movement substitutions, editable afterwards. PRs are kept per level, so scaled PRs count too.
4. **Add a partner/team model now.** Team size, team score, "my work" segments, and a partner-working state that counts as rest. Doubles race: run together, split the stations.
5. **Add strength prescriptions.** Store 1RMs per lift (date; tested or velocity-estimated). Prescriptions: sets × reps @ % or RPE, build to heavy, tempo, rest. Round to plates for the unit and bar. A complex is one set with N movements and make/miss.
6. **Define score types:** time, rounds + reps, reps, load, calories, distance, total or lowest, CAP + reps, tiebreak. Each type sets its own sort direction.
7. **Give benchmarks a fixed identity.** When the board says "Fran" or "24.1", link it to the library workout so retests compare automatically. Variants (partitioned Murph, no vest) link to the original but never count as Rx. Open workouts carry their divisions.
8. **Add "Log a result" and a Share Sheet entry to +.** Score, scaling, RPE and notes without the watch.
9. **Order the watch home like a class.** Today's session, Free workout, Lift session, then others. Block headers let you go from squats into the WOD without leaving. Show load per set.
10. **Finish the movement model.** Keep "this or that" and record which option was done. Add EMOM variants (alternating, failed minute) and distance segments.

## 3. Workout types and data the model must support

- **Formats:** For time + cap, AMRAP, EMOM/alternating, Every N:00, Rounds + rest, Tabata, Chipper, Ladder, Death-by, Strength sets, Complex, Max effort, Distance/time, HYROX (full, half, doubles, compromised runs), Partner (YGIG, split, synchro).
- **Blocks:** warm-up and cool-down are left out of scores. Buy-in and buy-out count.
- **Loads:** absolute, %1RM, RPE, "heavy", M/F pairs (95/65). Stored in kg, shown in the user's unit. Per-gym bars, plates, DB/KB steps.
- **Movements:** modality, height standards (wall ball, box), and machine type (row, bike and ski calories aren't equal).
- **Result:** score + type, scaling and substitutions, team, RPE, notes, flags (deload, injury, race, test), device, official vs watch time.
- **Profile:** rep maxes with history, max HR, body weight, HYROX division, run calibration.

## 4. Insights that help vs vanity metrics

**Helpful (they change the next session):**
- **Pacing decay:** splits overlaid on your best attempt, first round vs last. Flag going out too hot.
- **HYROX:** compromised-run cost (run pace after each station vs fresh 1 km pace), roxzone total, and station vs target. Sleds and wall balls lose races.
- **Strength:** bar speed at a fixed load (readiness), estimated 1RM trend, misses by position, %1RM used vs prescribed.
- **Engine:** 1-min HR recovery after comparable efforts, and HR at a fixed pace or wattage.
- **Balance:** volume by modality and time domain. This is btwb's real value. Say "under-trained: heavy long metcons", not just a score.
- **Benchmark trend per scaling level,** with retest prompts.

**Vanity (hide or demote):** calories, streaks, badge counts, "pounds moved", a bare daily HRV, and a Fitness Level built on sparse data. Show confidence ("based on 3 results") and leave out deload and injury weeks so a taper never reads as a decline.
