# Phase 1 Plan — Apple Watch Barbell Tracker (Snatch / Clean & Jerk)

_Written October 2026 as the restart point for this repo._

---

## 0. Do this first: leaked database credentials

`config/mongodb_connector.py` and `notebooks/data_extraction_V1.ipynb` contain a
MongoDB Atlas connection string with a username and password. **This repo is public.**
Treat the password as compromised:

1. In MongoDB Atlas, rotate the password for that user (or delete the user/cluster if unused).
2. Check Atlas access logs for unexpected connections.
3. Removing the string from the current files is not enough, because it stays in git
   history. Rotation is the real fix. Rewriting history (e.g. `git filter-repo`) is optional
   once the password is dead.

From now on, secrets go in environment variables or the iOS Keychain. They never go in
source files.

---

## 1. What's in the repo today (honest audit)

| Item | What it is | Verdict |
|---|---|---|
| `notebooks/data_extraction_V1.ipynb` | Pulls watch accelerometer batches from MongoDB, trains an LSTM to output a *single rep count per recording* (Air Squats) | Archive |
| `scripts/`, `main.py`, `plot_data.py` | Data extraction + plotting from MongoDB. Training/eval/inference scripts are empty stubs | Archive |
| `notebooks/data/models/*.keras` | Two small trained LSTMs (10 units) | Archive |
| iPhone / Watch app | Lives in `Slimslim/WorkoutApp`, reviewed below | Start fresh, port the sensor code |

What it tells us about the old approach, and why it stalled:

- **Only user-acceleration (x/y/z) was used.** No gyroscope, no attitude/orientation, no
  gravity vector. You can't get a bar path without orientation, because you need to know
  which way is "up" at every instant.
- **Whole-recording → one number regression.** The model saw an entire set and guessed the
  total reps. That needs a lot of labeled sets, can't tell you *when* each rep happened, and
  can't generalize. With a few dozen recordings it can only memorize.
- **Per-recording normalization (StandardScaler per workout)** removes the absolute
  magnitudes (g's, velocity) that matter most for lifting.
- **ML before physics.** For bar path, physics (sensor fusion + integration) does most of
  the work. ML is useful later for classification (which lift, which phase), not for
  computing displacement.

The good part: you already proved you can stream motion data off the watch in batches
and store it. That instinct (collect real data first) is right. We keep it, with better
sensors and labels.

### The Swift app (`Slimslim/WorkoutApp`, last touched Aug 2024)

iPhone + watchOS app (iOS 17.5 / watchOS 10.5, SwiftUI). The phone sends a movement/reps/weight
form to the watch; the watch records motion during a workout session; the phone shows a
confirmation form. No secrets in that repo.

**Worth keeping (the right building blocks were chosen):**
- `CMBatchedSensorManager` for 800 Hz accelerometer + 200 Hz device motion.
- `HKWorkoutSession` + `HKLiveWorkoutBuilder` with the `workout-processing` background mode.
- The idea of labeling each recording (movement, reps, weight, "data good" flag).

**Why it doesn't work today:**
1. **Recorded data is silently dropped.** `MotionManager.saveData()` writes into
   `sharedWorkoutInfo.workoutData?…`, but `workoutData` is never created on the watch, so the
   optional chain does nothing and an empty recording is sent.
2. **Transfer can't carry the data anyway.** It uses `WCSession.sendMessage` with JSON. That's
   meant for small messages (tens of KB). One minute at 800 Hz is roughly 4 MB of JSON. Needs
   `transferFile` with a compact binary format.
3. **Several competing WatchConnectivity delegates.** `WCSession.default` has one delegate, but
   the phone creates `WatchConnector` three times (App, `WorkoutFormView`,
   `WorkoutFormViewModel`) and the watch creates `PhoneConnector` three times. Whichever was
   created last receives the messages, so the confirmation sheet may never appear.
4. **The orientation data needed for bar path is thrown away.** From device motion only
   `rotationRate` is kept. Attitude (quaternion), gravity and user acceleration are discarded.
5. **Sessions are never properly ended.** It calls `stopActivity` but never `end()` /
   `finishWorkout`. Sample arrays aren't cleared between sets, so sets accumulate. Activity type
   is `.other` with `locationType = .outdoor` (should be strength training, indoor).
6. **Uploading isn't implemented in this repo.** "Upload" only prints. The MongoDB upload that
   produced the data in the ML repo isn't here.
7. The watch can only start after the phone sends a form. Phase 1 should be watch-first.

**Verdict:** start a clean project and port about 60 lines (the sensor and workout-session setup)
by hand. Fixing the old app costs more than rewriting it, and the data model has to change
anyway for bar path.

**Recommendation:** move the old code into `legacy/` (or tag it `legacy-2024` and delete
it from `main`), then start a clean project.

---

## 2. Mentor review: is Phase 1 doable?

### The core physics question

The watch sits on the wrist, not on the bar. In the snatch and clean the hands are locked
on the bar, so **wrist trajectory ≈ bar trajectory**, offset by a few centimeters. The offset
rotates during the turnover, and we can correct for it because we know the watch's
orientation.

To draw a path you double-integrate acceleration, and normally that drifts badly. Olympic
lifts are almost the best case for it, though:

- A lift is short: about 1–2 s from floor to catch.
- The bar **starts and ends at rest**: on the floor, then held in the catch/recovery. Those
  zero-velocity moments let us cancel drift ("ZUPT", the same trick foot-mounted
  pedestrian navigation uses).
- watchOS 10+ on Series 8 / Ultra and newer exposes `CMBatchedSensorManager`:
  **800 Hz accelerometer + 200 Hz fused device motion** (attitude, gravity, rotation rate)
  during an active workout session. That's research-grade sample rates.

### Confidence by metric

| Metric | Feasibility from the wrist | Notes |
|---|---|---|
| Rep detection (a lift happened, start/end) | ✅ High | Big, distinctive signal |
| Lift type: snatch vs clean vs jerk | ✅ High | Rules first, small classifier later |
| Peak bar velocity, velocity curve | ✅ High | The core of every VBT product |
| Vertical displacement / max bar height | ✅ Good (≈ a few cm, to be validated) | ZUPT makes this workable |
| Phase timing (1st pull, 2nd pull, turnover, catch) | ✅ Good | Visible in the velocity/rotation signals |
| Catch height (bar height when caught) | 🟡 Medium | Needs a stable start reference (bar on floor = 0) |
| Horizontal path (loop toward/away from body) | 🟡 Medium–Low | Hardest part. The forward direction must be estimated (dominant plane of motion). This is the main research risk |
| Jerk drive/split bar path | 🟡 Medium | Hands stay on bar, so feasible, but starts from the rack, not the floor |
| Body position, bar–hip distance, foot work | ❌ No | A wrist can't see these. Needs camera |
| Load (kg) | ❌ No | User enters it |

### What to avoid

- **Don't start with ML.** Build the physics pipeline, validate it, *then* add learned models
  where rules break down.
- **Don't build the polished app first.** The whole product rests on one unknown: *is a
  wrist bar path accurate enough to be useful?* Answer that in ~2–3 weeks before designing
  screens.
- **Don't build a backend yet.** No accounts, no cloud, no social. Store everything on the
  phone (SwiftData). Add iCloud sync later.
- **Don't try real-time bar path on the watch screen.** Record on the watch, compute on the
  phone, show results 1–2 s after the lift. Live drawing on a tiny screen mid-lift is useless
  to the athlete anyway.
- **Don't promise "exactly like a bar sensor."** Position the product as "your watch already
  knows how the bar moved" (zero extra hardware), with honest accuracy.

### Real-world risks to plan around

- **Wearing the watch while lifting.** In the clean's front rack and the snatch catch the
  wrist is hyper-extended, and many lifters take their watch off or wear wraps. We need an
  explicit recommendation (wear it snug, slightly up the forearm, over or under the wrap) and
  must test what that does to accuracy. *This is a product risk, not just a technical one.*
- **Dropping the bar.** Impacts after the lift can saturate the accelerometer. That's fine,
  we stop the analysis at the end of the recovery.
- **Device support.** 800 Hz batching needs Series 8 / Ultra or newer and watchOS 10+. A
  100 Hz fallback (`CMMotionManager` device motion) works on older watches with lower
  accuracy.
- **Left vs right wrist, and grip width.** Snatch grip is wide, so the wrist is far from the
  bar's center. The bar's *vertical* path is the same across its length (if the bar stays
  level), but horizontal loops near the hand can differ a little from the center. Acceptable.

### Competitive landscape (to research properly)

Bar-mounted sensors (e.g. Enode/Vmaxpro-style IMUs), linear position transducers
(GymAware), and phone camera bar-path apps already exist. The **gap** is: *no extra
hardware, no tripod, works with the watch you already wear, and the same device later counts
reps for everything else (Phase 2/3).* That's a real differentiator, and it lines up with your
long-term CrossFit vision.

---

## 3. Senior PM view: scope and milestones

### Phase 1 goal (one sentence)

> Start a session on the watch, do snatches / clean & jerks, and see each rep's bar path,
> peak velocity, max height and catch height on the iPhone within seconds, accurate enough
> that a coach would trust it.

### Milestones

**M0 — Restart & safety (½ day)**
Rotate DB password. Archive legacy code. New Xcode project: iOS app + watchOS app +
a shared Swift package `BarPathKit` (pure Swift, no UIKit, so it can be unit-tested anywhere).

**M1 — Data recorder (1 week)** _(the most important milestone)_
- Watch: start an `HKWorkoutSession` (required for background sensors and batching),
  record `CMBatchedSensorManager` accelerometer (800 Hz) + device motion (200 Hz),
  with a big "Snatch / Clean & Jerk" picker and a start/stop button.
- Transfer the raw recording to the phone (`WatchConnectivity` `transferFile`).
- Phone: list recordings, export as CSV/JSON (AirDrop/Files) for offline analysis.
- At the same time, **record slow-mo iPhone video** of the same lifts from the side. This is
  our ground truth.

**M2 — Ground truth + algorithm spike (1–2 weeks)**
- Ground truth: track a bright marker on the plate (or the bar end) in the side-view
  video. A small Python/OpenCV script gives true bar path in cm (use plate diameter
  45 cm for scale).
- Algorithm v0, prototyped in Python on recorded data:
  1. Rotate acceleration into the world frame using attitude; subtract gravity.
  2. Detect each lift (bar at rest → motion → rest).
  3. Integrate to velocity; apply zero-velocity correction at start/end (linear or
     smoothed drift removal).
  4. Integrate to position. Find the sagittal plane with PCA on horizontal motion.
  5. Correct for wrist-to-bar offset using orientation (lever-arm term).
  6. Extract metrics: peak velocity, max height, catch height, phase times.
- **Go/no-go gate:** compare against video on ~30 lifts. Target: vertical error under
  ~3–5 cm, peak velocity under ~0.1 m/s. If horizontal is poor, ship Phase 1 with vertical
  metrics plus a "side view" that's honest about horizontal confidence.

**M3 — Port to Swift + MVP app (2–3 weeks)**
Port the validated algorithm into `BarPathKit` with unit tests that replay recorded
sessions. iPhone UI per section 4. Watch UI: start, lift picker, rep counter, last-rep peak
velocity.

**M4 — Private TestFlight with real lifters (2 weeks)**
5–10 lifters from your gym. Collect feedback and more data. Fix wear and comfort issues.

**M5 — Phase 1 polish**
History and progress charts (velocity at load, PR tracking), accessory variants (power,
hang, block), and an optional rep classifier trained on the now-large labeled dataset.

### Out of scope for Phase 1

Accounts and backend, social features, coaching AI, Android/Wear OS, real-time path on the
watch, Phase 2/3 movements.

---

## 4. UX / UI designer view

### Watch (glanceable, sweaty hands, big targets)

1. **Start screen:** two huge buttons, *Snatch* and *Clean & Jerk*, plus "More" (power /
   hang / block variants). Optional load entry with the Digital Crown.
2. **Recording:** big rep count, last rep's peak velocity (m/s), heart rate. Haptic tap when
   a rep is detected, so the lifter knows it was captured without looking.
3. **End set:** one tap. The set syncs to the phone automatically.

### iPhone

1. **Session view:** list of sets → reps, each with a mini bar-path thumbnail.
2. **Rep detail (hero screen):**
   - Side-view **bar path** drawing (vertical vs horizontal), colored by velocity, with
     markers for start, max height and catch.
   - Velocity-over-time curve with phases shaded (1st pull / 2nd pull / turnover / catch).
   - Key numbers: peak velocity, max bar height, catch height, drop under the bar
     (max height − catch height), time to catch.
   - Overlay mode: compare this rep against your best rep, or against rep 1 of the set
     (fatigue).
3. **Progress:** peak velocity vs load chart per lift (the classic load–velocity profile),
   catch-height trends.
4. **Onboarding:** how to wear the watch for lifting, plus a 1-time "stand still with the
   bar" calibration.

Design principle: **show confidence honestly.** If a rep's horizontal path is low
confidence, draw it lighter or dashed instead of faking precision.

---

## 5. Software engineering view: architecture

```
WatchApp (watchOS 10+)
 ├─ WorkoutSessionController   HKWorkoutSession + HKLiveWorkoutBuilder (HR, keeps app alive)
 ├─ MotionRecorder             CMBatchedSensorManager (800 Hz accel, 200 Hz device motion)
 │                             fallback: CMMotionManager 100 Hz
 ├─ LiveRepDetector            lightweight, from BarPathKit (rep count + haptics only)
 └─ SessionUploader            WatchConnectivity transferFile (compact binary recording)

iPhoneApp (iOS 17+)
 ├─ SessionStore               SwiftData: Session → Set → Rep (+ raw recording file)
 ├─ AnalysisService            runs BarPathKit on received recordings
 └─ UI                         SwiftUI + Swift Charts (bar path, velocity curves)

BarPathKit (shared Swift package, no Apple-UI deps → testable on Linux/CI)
 ├─ Recording                  raw sample types + (de)serialization
 ├─ FrameTransform             device → world frame, gravity removal
 ├─ LiftSegmenter              rest/motion detection, rep boundaries
 ├─ Integrator                 velocity/position with zero-velocity drift correction
 ├─ PlaneEstimator             PCA sagittal plane
 ├─ LeverArmCorrection         wrist → bar offset
 └─ Metrics                    peak velocity, heights, phases

tools/ (Python)                offline analysis, video ground-truth tracking, plots
```

Key decisions:

- **Raw data is always kept.** Every recording is saved raw, so the algorithm can be
  re-run on old sessions when it improves. This is also your future training set for
  Phase 2/3.
- **Algorithm lives in a pure Swift package with replay tests.** Recorded lifts become test
  fixtures ("this snatch should show max height 1.05 ± 0.05 m").
- **Prototype in Python, ship in Swift.** Iterating on signal processing in notebooks is
  much faster; port once validated.
- **Labels at record time.** The watch picker records lift type, load, and optionally
  "made/missed", so every recording is labeled for free.

### Practical note on tooling

iOS/watchOS apps need **Xcode on a Mac** to build and run, and the motion sensors need a
**real watch** (the simulator has none). In these cloud sessions I can write the Swift code,
the Python analysis tools and the tests, and run Python (and pure-Swift package tests if a
Swift toolchain is added to the environment). Building, signing and running on your watch
happens on your Mac.

---

## 6a. Phase B: Hyrox (added 2026-10-27, before the full CrossFit app)

A Hyrox race is a fixed format: 8 × (1 km run + 1 station), with transitions through the
"Roxzone" between them. Stations in order: SkiErg 1000 m, Sled Push 50 m, Sled Pull 50 m,
Burpee Broad Jumps 80 m, Row 1000 m, Farmers Carry 200 m, Sandbag Lunges 100 m, Wall Balls
100 reps. Because the sequence is always the same, it's the easiest "multi-movement" workout
to referee, much easier than an arbitrary CrossFit WOD.

- **B1: splits (start here).** The watch knows the 16 segments in order. One gesture (tap
  anywhere, double tap, or the Action button on an Ultra) advances to the next segment.
  Shows the current segment, segment time, total time, HR, and pace on runs; haptic and
  next-segment preview. Post-race split table on the phone vs a target or previous race.
  Low technical risk, useful on day one. Note: races are indoors, so run distance/pace
  comes from the watch's indoor running estimate, not GPS.
- **B2: auto-splits.** Detect run ↔ station transitions from motion (running cadence vs.
  everything else) and suggest or auto-advance; record full sessions to train it, using the
  same debug-CSV pipeline as Phase 1.
- **B3: station metrics.** Wall-ball rep counting (very distinct squat-and-throw), row/ski
  stroke counting and stroke rate, burpee broad jump counts, lunge counts.
- **Reuse from Phase 1:** workout session + sensor recorder, watch → phone transfer, file
  formats, analysis pipeline, debug recordings and the Python tools.

## 6. How Phases 2 and 3 build on this

- **Phase 2 (rep counting: bench, pull-ups, push-ups…):** reuses the recorder, segmenter
  and labeled-data pipeline. The approach changes from "whole set → count" (old LSTM) to
  **per-rep detection** (peak/cycle detection plus a small classifier over short windows),
  which needs far less data and tells you *when* each rep happened.
- **Phase 3 (CrossFit WOD referee):** adds a workout definition model (rounds, movements,
  targets), movement *classification* on sliding windows, transition detection, and the
  native running/rowing metrics from HealthKit. This is the hard, data-hungry part, which
  is why the data pipeline built in Phase 1 matters so much.

---

## 7. Immediate next steps

1. ☐ Rotate the MongoDB password (you, today).
2. ☐ Decide: archive legacy code into `legacy/` in this repo, or start a new repo.
3. ☐ Confirm your devices: watch model + watchOS version, iPhone model, Mac with Xcode.
4. ☐ Build M1 (data recorder) and record ~30 snatches + ~30 cleans with side-view slow-mo
   video.
5. ☐ Run the M2 accuracy spike → go/no-go on horizontal bar path.
