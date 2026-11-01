# Round 2 review: proposal v2 (UX/IA + CrossFit/HYROX coach)

## Verdict
v2 is a big step up. All owner decisions are applied consistently. Spot checks of decisions.md (UX-1 to UX-10, ATH-2/3/5/6, W-3/5, M-1 to M-8, C1 to C13) all show up where the log says. No gendered pronouns.

Main problems: the Before Anaheim flows use screens that won't exist before the race, and the model doesn't say how two strength blocks become one lifting block.

**P1 re-walk (56):** 47 work, 7 partial (S-02, S-09, S-21, S-28, S-29, S-77, S-80), 1 fails (S-39, in no stage), 1 moved on purpose (S-82).
**Mayhem day:** partial. The flow works, but there are 4 inconsistencies (fixes 2–5).
**Before Anaheim:** realistic and race-critical once fixes 1, 7 and 8 are made.

## Required fixes

1. **§11 "Setting the Anaheim target" and "Race day in the hall"; §13 Before Anaheim.** These flows use *Library › HYROX* and *Watch: Today › HYROX*. Neither exists before the race. **Fix:** "Workouts tab › Choose › your race workout › preview › **Race plan** (goal time) › Send to watch". Watch: "Workouts page › race workout › START".

2. **§7 Block / Lifting block, §12 Log wireframe.** The confirm screen makes Back squat and Front squat two Strength blocks. The lifting screen runs both as one ("Lift 1 of 2"). The Log row lists only Back squat, and "4 scored blocks" doesn't add up. **Fix:** add to §7: "Strength blocks that follow each other run as one lifting block: one recording, one Apple workout, but each lift keeps its own result. *Start lifting* on the first card includes the next ones." In the Log wireframe, add "Front squat 185 ×3". Walkthrough: "5 scored blocks".

3. **§11 Mayhem walkthrough, steps 3 and 8.** The day is scheduled but never sent, yet step 8 says the metcon "was sent to the watch with the day". **Fix:** in step 4 (next morning), add "Today › **Send day to watch**", or make Schedule send automatically on the day.

4. **§12 Log wireframe "V-ups 100 CAP+82".** "CAP+N" is read both as reps done and as reps short. **Fix:** "V-ups · 82 reps at cap (7:00)". Use this wording everywhere.

5. **§12 Today and lifting wireframes.** "Last: 5×3 @ 245 lb (Dec 24)" sits above suggested loads of 155–175 lb with a 3RM of 215. That reads as a bug. **Fix:** when the last result is more than 6 months old, show it greyed with "over a year ago". Base suggested loads only on maxes from the last 6 months. Show "from 3RM 215 (Feb 26), est. 1RM ~230".

6. **§14 Q1, §11 "Profile: men's", report wireframe "Open Men".** The defaults assume the owner's gender. **Fix:** "Default: your division and load column as set in Q1 / Profile". Ask Q1 as "Solo or Doubles, Open or Pro, which category".

7. **§11 "Setting the Anaheim target", §14 Q3.** "Spread over your best sim's split shape" breaks when the best sim is a Half HYROX (as in the report wireframe) or has no roxzone splits. **Fix:** "Shape comes from your best *full* sim with the same segments. Otherwise it uses a standard HYROX split template." Add a **delta off** switch so the race can fall back to a plain clock if the delta misbehaves.

8. **§13 Before Anaheim timing.** "Roxzone tried in one sim first" has no date before the 22 Nov freeze. A full sim 10 days out is also late for a taper. **Fix:** test build **Sun 15 Nov** with a trial sim that week (full sim, roxzone on). Freeze 22 Nov. Rehearsal in the week of 23 Nov becomes a **half sim or race-pace segments** on the frozen build. Add a hidden "simulate crash" in Data mode to rehearse Resume.

9. **§13 build order, S-39 (buy-in run).** This P1 isn't in any stage. **Fix:** add "distance run segment (pace via pedometer, manual end)" to Before TestFlight next to Calibrate run.

10. **§13 build order ID lists.** S-31 and S-36 appear in two stages. S-41 is listed as "Works today", but the watch home has no Today item yet. **Fix:** list each ID once. S-36 and S-41 go Before TestFlight.

11. **§12 watch done wireframe "Next: V-ups 100 ›".** The tree marks [Next block] as *(later)*. **Fix:** label the wireframe "later", or make it Before TestFlight. It is cheap and the Mayhem day needs it.

12. **Jargon for a non-developer (§13 Before TestFlight / Before App Store; §6).** Replace:
    - "units stored canonically" → "stored in kg/m/s plus the unit you typed"
    - "PRs per comparability key" → "PRs compared like with like (same workout, scaling, score type)"
    - "workout mirroring" → "Apple's live link between watch and phone workouts"
    - "edits layer" → "fixes kept separate from the raw recording"
    - "Data mode", "Screen demo": explain them or move them to Advanced.

13. **§5 Settings, S-02.** Nothing shows which permissions were declined. **Fix:** add "Permissions (Health, Motion, Notifications: on/off, why)" under Settings › Watch & sync or Profile.

## Optional suggestions
- Add "phone report shows target deltas" to Before Anaheim, so the trial sim can be reviewed.
- Use the Mayhem "target score" as the metcon's ahead/behind target (it reuses the race code).
- Confirm wireframe: show the row ladder (40-30-20-30-40 cal / 7 PC) instead of "×5 rounds".
- S-21: list the formats Build offers. S-28/29: until the watch toggle exists, add the hint "Crown at each change of who works, tag later".
- scenarios.md S-14/18/26/28/29/38 use "he/his". Change them to "you/your".
