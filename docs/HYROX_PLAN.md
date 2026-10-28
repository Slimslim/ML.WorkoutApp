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
