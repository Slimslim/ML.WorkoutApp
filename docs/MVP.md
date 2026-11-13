# MVP: a stable build for 4-5 testers (2 weeks)

> Build-by-build status (build 15 frozen, build 16 = the tester build): `docs/RELEASES.md`.

**Goal:** 4-5 athletes use one stable TestFlight build with their own program for two weeks.
We collect recordings (training data) and feedback. No new features during the test except the one
listed under "Build".

Owner decisions (2026-11-10): strict press and bench press rep counting are in; the testers'
programs are entered by Claude from their screenshots; dates below are proposals.

## What testers get (exists today)

| | |
|---|---|
| **Their program on the watch** | Each tester sends screenshots of their week; Claude adds them as **private** library rows (`owner` = their user id, readable only by them). On the day: Workouts -> Choose -> Today -> Send to watch. |
| **Workouts (metcons)** | START, turn the Crown at the end of each movement, splits and heart rate, report on the phone. AMRAP, for time, EMOM, time caps. |
| **Free Workout** | For anything not in the program. |
| **Lifting** | Barbell lifts in Lifting mode: deadlift (reps counted, weight per set), Olympic lifts (bar path, speed, height per lift), and, new in this build, **strict press and bench press with reps counted**. |
| **Upload** | Sign in once (Sign in with Apple); every recording goes to the cloud (the training data). Claude can correct results there and the phone picks them up (W17). |
| **Feedback** | TestFlight's built-in feedback (screenshot -> Share Beta Feedback), crash reports (automatic), and a group chat for "what I really did". |

**Which mode:** a barbell lift piece -> Lifting; a metcon (score is time or reps under a clock) ->
Workout. One Fitness workout per mode used.

## Not in the MVP

Automatic movement switching (offline experiment only), the start mark by double tap, lift pieces in
the program and the single start screen, recording that follows the plan (W21), Rx/Scaled on the
phone (W19), round-by-round view (W18), run distance at the cap (W20), partner splits, supersets.

## Build (1): strict press and bench press reps (owner to confirm: "no rep counting yet", 11 Nov)

- `LiftType` gets `strictPress` and `benchPress`, both `countsReps` (shared file
  `BarPathKit/Sources/BarPathKit/Models.swift`: small separate commit, called out in the PR).
- Same `RepCounter` / `barpath.reps` as the deadlift. Evidence: on the 2026-11-08 strict press
  (3 x 10, labelled), the unchanged counter counts **10 / 10 / 10**, bar travel 0.44-0.65 m.
- **A press rep is counted at lockout** (forearm fully vertical after the push), not on any push:
  on the 2026-11-10 Tabata press this gives the athlete's count in all 8 sets and skips a missed rep
  and the re-rack. Where the counter and the athlete disagree, the label keeps the athlete's count
  and is flagged for video.
- Bench press: not yet seen in data. Check on the first bench session (Thursday 2026-11-12, dumbbell
  bench) before the build goes to testers; if it miscounts, ship bench without rep counting.
- Python reference + Swift parity test on a press fixture; watch lift picker and phone lift report
  show the two lifts.
- Lifting area; the Lifting chat merges `main` after it lands.

## Build (2): first workout and permissions (from the first tester)

W22 (practice workout) is in build 15 (#24); W23 (banner) is planned for build 16.

A tester's first workout (2026-11-10): the heart-rate prompt came mid-run, he refused or dismissed it
(no HR, no steps recorded) and he did not find the Crown, so the whole workout was one part.
- **W22 Practice workout:** permissions asked before START with the reason, a 2-part practice with
  real HR that teaches "turn the Crown", and the finish screen explaining the 3-min recovery and
  "swipe left, End" (recovery keeps recording). Saves nothing.
- **W23 Permission banner:** "Heart rate / Motion is off" on the phone and the watch, with a button to
  Settings.
- Watch and phone screens: mockups approved by the owner before code (Workouts + Navigation areas).

## Build (3): upload without opening the app (W28)

Testers end the workout and walk away (a tester: Chad reached the cloud 2.5 h later, when he opened the
app). The watch wakes the phone app at END and the phone uploads while locked. After #24 (compressed
uploads) is merged; device test only (3 sessions, one of 60 min). If it is not ready by the invite,
the tester guide keeps "open the phone app after the session".

## Before inviting (checklist)

1. **Feature freeze** on `main` once the press/bench PR is merged; only fixes after that.
2. **Build number up** (`CURRENT_PROJECT_VERSION`, now 6 on `main`) and upload to TestFlight.
3. **Owner uses that exact build for 4+ sessions**, fresh install first: sign-in, Health and motion
   permissions, watch app install, a metcon from the library, a Free Workout, a Lifting session with
   press or bench, upload and report, a cloud correction reaching the phone.
4. **Fix only what breaks** in those sessions; new build number.
5. **Practical checks:** a 60-min session's watch battery; upload size (Data mode is ~30 MB per
   40 min) and whether uploads wait for Wi-Fi; what happens with no signal in the gym.
6. **Library:** move the owner's gym programming (Mayhem, Blue Republic, PitFIRE rows) from the shared
   library to the owner's private rows, so testers only see their own program and public benchmarks.
7. **Tester guide** (one page, below) sent with the invite; testers do the practice workout first.

## Dates

In `docs/RELEASES.md` (the only place with dates and build scope). Build 16's scope is waiting on
the owner: rep counting on the watch may move out of the MVP.

## During the test

- Each tester sends their week's program (screenshots) by Sunday; Claude enters it as private rows.
- After each session: a short message with what they really did (reps, weights, broken sets,
  Rx/scaled, anything odd). Claude corrects the recording and labels it (docs/LABELS.md) under a
  neutral id ("athlete B"), only with the tester's OK; their recordings stay in their private folder.
- Bugs and confusion go through TestFlight feedback; a weekly check-in message from the owner.

## Success

- Every tester records at least 3 sessions a week for both weeks; no recording lost; no crash that
  ends a workout.
- At least 20 labelled sessions from people other than the owner (switches, sets, reps).
- A ranked list of the testers' top 5 problems and wishes.

## Tester guide (one page, to send)

1. Install from the TestFlight link; open the app on the phone and **Sign in with Apple**; allow
   Health and Motion. The watch app installs itself (or from the Watch app on the phone).
   Then do the **Practice workout** on the watch (1 minute) before your first real one.
2. Send your week's program (screenshots) to the owner by Sunday; it shows up in **Workouts ->
   Choose -> Today** on the day.
3. **Metcon:** pick it, **Send to watch**, START on the watch. **Turn the Crown when you finish each
   movement** (each run, each station, each set). Nothing else to do.
4. **Barbell lifts** (deadlift, press, bench, snatch, clean): use **Lifting** on the watch, pick the
   lift and the weight, START. Reps are counted; tap **Change** to change the weight between sets,
   **End** only at the end.
5. After the session: open the phone app (it uploads), then send a short message: what you really
   did (reps, weights, how you broke sets, Rx or scaled).
6. Something wrong? Screenshot -> **Share Beta Feedback** in TestFlight.
