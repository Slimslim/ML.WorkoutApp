# Phase B: Hyrox mode, plan (draft, 2026-10-28)

Target: HYROX Anaheim, Dec 3–6 2026. First tester: the athlete's own watch (Series 12,
watchOS 27). Once 2–3 more testers are lined up (one is in Switzerland), distribute through
TestFlight. See §4.

## 1. How Apple handles a triathlon (and what we copy)

Sources: Apple's "Dividing a HealthKit workout into activities" developer article, and the
Apple Watch user guide page "Combine multiple workouts".

- **One workout split into activities.** The session is `.swimBikeRun`. Each leg is started
  with `HKWorkoutSession.beginNewActivity(configuration:date:metadata:)` and closed with
  `endCurrentActivity(on:)`. Starting a new activity ends the current one. The gaps between
  legs can be `.transition` activities. Available since watchOS 9 / iOS 17.
- **Per-leg metrics come for free.** In a `.swimBikeRun` session the live data source changes
  what it collects when the leg changes. A `.running` leg collects `distanceWalkingRunning`,
  `runningStrideLength` and the other running metrics. Every activity keeps its own statistics,
  so the Fitness app can show a split per leg.
- **Mixing types is only allowed in `.swimBikeRun`.** Apple's rule: "you can create an interval
  workout for any activity type; however, all workout activities must use the same activity
  type as the containing workout. You can't mix activities within a single workout." Inside
  `.swimBikeRun` the legs must be swimming, cycling, running or transition. **There is no
  built-in Hyrox type** and no "SkiErg" or "sled" activity.
- **Automatic legs plus a manual fallback.** Apple's multisport detects leg changes from motion
  and inserts a transition phase. Since watchOS 9 the user can choose manual transitions
  instead. Reviewers report that the automatic mode works for one T1 and one T2 but can get
  stuck on longer, repeated sequences. A Hyrox race has 16 or more changes, so our known
  segment order and Undo matter.

### What this means for us: three ways to save a Hyrox race

| Option | Workout type | Activities | Pros | Cons |
|---|---|---|---|---|
| A | `.swimBikeRun` | runs = `.running` (indoor); stations and Roxzone = `.transition` with `metadata["station"]` | Apple measures distance, stride and power per run automatically. Fitness shows splits | Fitness labels it "Multisport" and the stations "Transition". Indoor running inside multisport is unverified |
| B | `.functionalStrengthTraining` or `.mixedCardio` | one activity per segment, all the same type, `metadata["segment"]` | Honest label | No automatic running metrics: distance and cadence come from `CMPedometer` |
| C | `.running` (indoor) | one activity per segment, all `.running`, stations tagged by metadata | Apple's running metrics everywhere | Shows up as a 90-min "Indoor Run" |

**Decision:** test A and B on the athlete's watch in week 1 (a 10-minute test). Our own split
table never depends on this choice. Splits come from our timestamps, and run distance and
cadence come from `CMPedometer`, which works indoors in every option.

## 2. Build plan

1. `docs/HYROX_SPEC.md`: the workout-definition model, the race state machine, the file
   formats (race result file, practice recording at 50 Hz with segment labels) and the watch
   screens.
2. BarPathKit (pure Swift with XCTests, plus a Python mirror tested with pytest):
   `WorkoutDefinition` (segments, rounds, targets, kind) with Hyrox Solo and Doubles presets,
   and a `RaceProgress` state machine (advance, undo, splits).
3. Watch B1:
   - A Lifting / Hyrox mode choice on Setup.
   - A race screen showing the current segment, segment time, total time, HR, and pace and
     cadence on runs.
   - Next = press and hold (~0.5 s), Undo for 10 s after every change, a haptic and a
     next-segment preview.
   - A Data mode that records the full session.
4. B2, automatic switching: a Python detector built on the practice recordings, then a Swift
   port, then shadow mode, then auto-advance with Undo.
5. Phone: a post-race split table (live view only when the phone is in Bluetooth range).
6. `docs/HYROX_TEST_PROTOCOL.md`: what to record and how to label it.

## 3. Timeline

| Week | Build | Athlete |
|---|---|---|
| Oct 28 – Nov 1 | Spec, model and tests, watch B1, the A/B HealthKit test | Install; short practice: a few runs and 2–3 stations |
| Nov 2–8 | Fixes, phone split table, Python reader, first detector | 1–2 longer practice sessions with taps |
| Nov 9–15 | Detector v1, Swift port, shadow mode | Practice in shadow mode; send the files |
| Nov 16–22 | Auto-advance and Undo, Doubles. **First TestFlight build to testers** | Full simulation; testers install |
| Nov 23–29 | Tuning; **feature freeze Sat Nov 29** | Full-length rehearsal (battery, storage) |
| Nov 30 – Dec 2 | Bug fixes only, race-day checklist | Final TestFlight build on testers' watches |

Fallback if automatic switching isn't reliable by Nov 22: race with manual Next and Undo, and
keep the detector in shadow mode.

## 4. Distribution

- Phase 1: Xcode installs straight onto the athlete's own iPhone and watch. No account needed.
- Testers (including the friend in Switzerland): **TestFlight**. This needs the paid Apple
  Developer Program ($99/yr; enrolment can take a few days). External testers get the app by
  email or a public link. The first external build goes through a short beta review (usually
  about a day), so the first TestFlight build should go out by about **Nov 16–20**.
- App Store release: after the race. A public release needs a privacy policy, HealthKit
  review notes and more polish, which is not worth doing before Dec 3.

## 5. Workout library (draft, 2026-10-28)

Testers need shorter workouts to practise with before a full race. Every workout is a
**definition** (data, not code), so adding one doesn't need new watch code.

| Workout | Content | Length | Purpose |
|---|---|---|---|
| HYROX Solo | 8 × (1 km run + station) | 60–100 min | Race |
| HYROX Doubles | as Solo; stations shared | 55–90 min | Race |
| Half HYROX (all stations) | 8 × (500 m run + half-volume station) | 30–45 min | Tests all 16 changes |
| Half HYROX (4 rounds) | 4 × (1 km run + station 1–4 or 5–8) | 30–45 min | Race-pace runs |
| Compromised run | N × (1 km run + one chosen station) | 20–40 min | Classic Hyrox training |
| Station circuit | stations only, no runs | 15–30 min | Station data (rep-counting groundwork) |
| Custom | phone builder: rounds, run distance, station list, volumes | any | Gyms without sleds, coach workouts |

Built-in presets ship first. The phone builder (sent to the watch with
`updateApplicationContext`) comes in week 2–3, as the first step toward the general workout
engine.

## 6. Data strategy

Two kinds of recording:

1. **Always (every user): the race file plus a 1 Hz feature log.** Segment times, HR,
   pace, cadence, detector decisions, Next/Undo taps, and per-second features (cadence, arm
   swing, wrist orientation, motion intensity, detector score). About 100 KB per hour. Enough
   to see *why* the detector made each decision, without raw data.
2. **Data mode (opt-in testers only): raw motion.** Device motion at 100 Hz, stored as
   compact binary (float32) rather than CSV, ≈ 20 MB per hour. Sent to the phone with
   `transferFile` at the end. 800 Hz accelerometer stays off (lifting only).

**Labels are free:** every segment boundary is a label, whether it's a manual Next, an
automatic switch that stayed, or an automatic switch fixed with Undo. Undo is the most valuable
label, because it marks exactly where the detector was wrong. Rep counts have known totals
(100 wall balls Solo, 80 m of burpee broad jumps, 100 m of lunges), which gives weak labels.
A few sessions filmed on a phone give exact rep timestamps.

**Getting tester data to us (5-week version):** a "Share recording" button on the phone
(AirDrop / email / Drive). Testers agree first, and files get anonymous IDs. **Tester data
does not go into this public repo.** It goes in a private folder or private repo. Only small,
trimmed fixtures are committed, and only with the tester's permission. Automatic cloud upload
comes later.

**Expected volume:** 4 testers × 2–3 sessions a week × 4 weeks ≈ 40 h of labelled data
(≈ 1 GB), plus up to 4 full races at Anaheim in Data mode, which is the most valuable set.

**Models:** per-window features (2 s) with rules plus a small classifier (decision tree or
gradient boosting). These port to Swift as plain code or Core ML and run live on the watch.
The known segment order means the detector only has to decide "has the next segment started
yet?". Rep counting later: peak detection per known station, checked against the known
totals.

## 7. Backlog from the athlete (2026-10-28)

- **Timed segments:** a rest ends by itself on the clock: "every 3:00" sets (`intervalSeconds`)
  and fixed rests ("1:00 rest", a rest segment with a seconds target). Countdown haptic at 3, 2
  and 1 s, then a strong "go". The AMRAP finishes itself at the time cap. *(Built 2026-10-28.)*
- **Phone Live tab after a workout:** an overview of the workout that just finished: total
  time, splits, HR, rounds (AMRAP), average pace per run segment and anything else useful.
  This is the Live tab's "last workout" state.
- **Live screen per workout type:** what the watch shows during a segment should depend on the
  workout (runs vs stations vs rests vs AMRAP rounds).
