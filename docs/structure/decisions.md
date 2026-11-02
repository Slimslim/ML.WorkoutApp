# Rx Lab structure: decisions on the four reviews (v1 → v2)

Date: 1 Nov 2026. Inputs: context.md, the owner's binding decision on phone-controlled lifting blocks (late 1 Nov), proposal-v1.html, proposal-v2.html, proposal-v3.html, scenarios.md, review-ux.md, review-athlete.md, review-watch.md, review-data.md, mayhem-day.md (owner input, late 1 Nov), and a read-only check of the code in `/home/user/ML.WorkoutApp/BarPath` (Watch, iOS, BarPathKit).

Decision words: **Accept** = do as the reviewer says. **Adapt** = keep the goal, change the how or the timing. **Reject** = don't do it (reason given).

Release stages used below:
- **Before Anaheim**: race-critical only. Test build **Sun 15 Nov** + full trial sim; code freeze **Sun 22 Nov**; half sim on the frozen build in the week of 23 Nov; then only bug fixes (updated in Round 2). Race Dec 3–6.
- **Before TestFlight**: Dec–Feb (widened in Round 2), before the 2–3 friends get the app.
- **Before App Store**.
- **Later**.

---

## 0. What the code really does today (checked, corrects reviewers)

| # | Reviewer claim | What the code shows | Effect on v2 |
|---|---|---|---|
| C1 | Watch #1, Data #9, S-56: "results only arrive while the phone app is open; build an outbox with `transferFile`, keep files until acknowledged, idempotent import" | **Already built.** `Watch/PhoneLink.swift` writes every result to an `Outbox` folder and sends it with `WCSession.transferFile` (queues while the phone is away). A file is deleted only after `didFinish fileTransfer` succeeds; failed transfers retry 3 times; files left over are re-sent at next launch. The phone stores results by their UUID (`iOS/Model/WorkoutFiles.swift`), so a re-send replaces, never duplicates. The phone receives files when iOS delivers them (in the background or at next app launch). | Watch reviewer's #1 is closed. Remaining gaps: (a) the phone shows sync state only in Debug; (b) rare edge: if the watch re-sends a result after you edited it on the phone, the re-send overwrites the edit (the original copy is kept). Fix (b) in the data model v2 (edits as a separate layer). |
| C2 | Watch #2: "sync state is invisible" | **Half true.** The watch already shows a pending count (`↑2`) and a "Phone / Phone offline" dot on both start pages and in the session footer. The phone shows nothing outside Debug. | Keep the watch indicator; add a phone-side "Watch & sync" row + Log placeholder (Before TestFlight). |
| C3 | Watch #8, Data #9, Watch S-86, UX S-86: "no HKWorkout writer / Health writing not specified" | **Wrong.** `Watch/WorkoutManager.swift` uses `HKLiveWorkoutBuilder` and calls `finishWorkout`, which saves every session to Apple Health with heart rate and calories (rings close). Activity types: lift sessions = Traditional Strength Training; workouts use a per-workout field (HYROX = Mixed Cardio, WODs = Cross Training). | S-86 already works. Remaining (Before App Store): activity segments inside each Health workout. Per the owner's decision (section 1b), a day stays **several Apple workouts, one per active block**, grouped in Rx Lab. |
| C4 | Watch #3: "no crash or battery resilience" | **True, and race-critical.** Progress is saved to disk at every Crown turn (`persistProgress()` in `WorkoutSessionModel.swift`) but is **never read back**. There is no HealthKit session-recovery handler. If the watch app crashes mid-race, the result is lost; only the raw Data-mode file (on by default) is recovered and sent at next launch, which the phone does not turn into a result. The result is also only written at **End**, not at the finish. | Before Anaheim: on relaunch, offer **Resume** (clock continues from saved times) or **Save as incomplete**; write the result at the finish too. |
| C5 | Watch #6: "add Race lock so End needs a Crown confirm" | **Already there.** End opens a full-screen "End workout?" with "Keep going" as the default. Always-On already has its own dimmed race layout. | Reject Race lock. |
| C6 | Watch #10: "distinct haptics for next / undo / done" | **Already distinct** (direction up / direction down / success / start). | No work. |
| C7 | Athlete #4, Data #3, UX S-28/29: "no partner model" | **Partly exists.** Workouts carry `team: solo / doubles / team`; HYROX Doubles and Partner WOD 1/2 are built in. Results don't record who did which split. | Add "me / partner / together" tags on results (Before TestFlight); watch toggle later. |
| C8 | Athlete S-80, Watch S-80: "no roxzone segment" | **Mostly built.** The model has a `transition` segment kind, the watch border has a roxzone colour, the phone story already says roxzone "gets its own share once the watch records transitions". The HYROX built-ins just don't include transitions. | Roxzone is a data change to the HYROX workouts, small enough for Before Anaheim (if the owner wants it, Q2). |
| C9 | UX S-91: "max HR works (avatar › Profile)" | The phone reads a stored max HR, but **no screen sets it**. | Tiny Settings field, Before TestFlight. |
| C10 | v1 wireframe: "Partner WOD 1 23:09 and 56 bpm recovery are your real results" | context.md has no result numbers. | All v2 example numbers are marked illustrative, except the Mayhem previous results / recent maxes quoted from the owner's own screenshots (mayhem-day.md). |
| C11 | UX S-03 "no watch-missing state" | The phone already shows "Watch app missing / No watch paired" on the lift row status chip. | Move this into the Today banner (Before TestFlight). |
| C13 | Phone-controlled lifting (owner decision 1b) | Not built: no `HKWorkoutSession` mirroring in the code. The phone can already open the watch app with a workout configuration (`HKHealthStore.startWatchApp`). The project already targets **iOS 17 / watchOS 10**, the minimum versions for mirroring, so no version change is needed. | Mirroring is new code built Before TestFlight, tested in real lifting sessions. |
| C12 | Phone → watch "Send to watch" | Uses application context (delivered when the watch app next runs) plus an instant message when reachable; no confirmation back. | "On watch ✓" confirmation: Before TestFlight (race day: check the watch screen instead). |

---

## 1. Conflicts between reviewers, and the ruling

| Conflict | Positions | Decision | Reason |
|---|---|---|---|
| **3 tabs vs 5 tabs** | v1: Today · Library · + · Log · Insights. UX: Today · Library · Log, + in the top bar. Athlete: the 5 tabs fit the day. Data: Insights as Today cards first. | **Adapt: 3 tabs now (Today · Library · Log), plus a big "+ Add" button in the top bar of every tab and as the empty-state action. Insights becomes tab 4 when the "10 workouts" phase ships (Before App Store).** | An empty Insights tab is worse than none. A centre "+" tab is non-standard on iOS and AI agents can't test custom tab bars well without a compiler. Add stays one tap from everywhere. |
| **Insights now or later** | v1: tab now. UX: cut. Data: phase it 1/10/50. Athlete: helpful vs vanity list. | **Adapt: phase it.** 1 workout = the report (exists). 10 = deltas, PRs per comparability key, cited Rx notes (Before App Store, Insights tab appears). 50 = btwb-style levels from measured data + published standards, marked "estimate" (Later). | Honest confidence; with 3 users there is no population to rank against. |
| **How much before Anaheim** | v1: tab bar + merged history + settings + watch home. Athlete and Watch: race-plan editor, ahead/behind, roxzone, divisions, calibration, outbox, checkpoints, race mode, watch home. UX: "order the build by the P1 list". | **Adapt: only 3 items + a rehearsal.** (1) Race target + ahead/behind on the watch; (2) crash/battery safety (Resume / Save incomplete, save at finish); (3) roxzone laps (optional); (4) dress-rehearsal sim on the frozen build. **No tab-bar rebuild before the race.** | 4.5 weeks, no compiler, owner tests alone. The race needs time vs target and no lost result. The new tabs change nothing on race day and add risk. Calibration only improves the pace number, not the splits (mats are marked with the Crown). Outbox/sync is already built (C1). |
| **"P1" = 56 scenarios** | Scenarios file: P1 = before Anaheim AND TestFlight. | **Split P1 in two**: race-critical P1 → Before Anaheim (S-46, S-47, S-55, S-77, S-78, S-79, S-80); other P1 → Before TestFlight. A few P1 lowered (see table). | Realistic scope. |
| **Where targets live** | Athlete: race-plan editor. UX: on HYROX preview. Watch: `targets[]` in the payload, editor can follow. | **Accept Watch + UX:** targets travel inside the workout sent to the watch; set on the workout preview ("Race plan"). Before Anaheim the "editor" is one field: goal finish time, spread over your best sim's split shape (or "beat best attempt"). Per-split editing Before TestFlight. | Smallest thing that gives ahead/behind on race day. |
| **Partner mode** | Athlete/Data: model now. Watch: per-segment toggle. | **Adapt:** model tags (me / partner / together) Before TestFlight, set on the phone after the workout; watch toggle Before App Store. Before Anaheim: none (team time + splits already work with the Doubles workout). | Extra Crown actions mid-race are a risk; tagging later on the phone is cheap. |
| **Gym day (S-35) + Mayhem day** | v1 Q5 open. Athlete/Data/Watch/UX: one Session with blocks. Watch reviewer: one HK workout per day with "Next block". | **Accept a Session (one Log row) of typed Blocks; replace the "one watch session for the day" idea with the owner's binding rule (1b):** lifting blocks are run from the phone, metcon blocks from the watch, and each active block is its own Apple workout. | Owner decision. Each block also stays simple to build and test. |

## 1b. Owner decision (binding): lifting blocks run from the phone

| Item | Decision |
|---|---|
| Who controls | **Lifting blocks** are started, moved on and ended on the **phone**. **Metcon / timed blocks** stay as today: send to watch, START on the watch, Crown to advance, End on the watch. |
| Flow | Phone: open the day › **Start lifting** › the watch starts recording (HR + motion, as a Traditional Strength Training workout) › phone shows the current lift (Back squat 3-3-3-3-3) with its set list › **Next lift** (Front squat) › **End lifting** › the watch stops and saves the block as **one** Apple workout. |
| Data | One lifting block = one Recording with lifts › sets › reps; motion data stored per lift and per set (superseded in Round 2: sets are marked by the athlete — Double Tap on the watch, Set done on the phone as backup — because the existing detector only finds Olympic pulls). Loads per set are prefilled from the %1RM prescription and edited on the phone. |
| Apple Health | One day = several Apple workouts (one per active block: lifting block, metcon, V-ups test). Rx Lab groups them in one Session. Warm-up, cool-down, core "for quality" don't create workouts unless you start one. |
| Watch while phone-controlled | Simple screen: lift name, "Set 3 of 5", HR, a red recording dot. No setup on the watch. |
| How it's built | `HKWorkoutSession` **mirroring** (iOS 17 / watchOS 10, which the project already targets): the watch owns the session and records; the phone gets a mirrored copy and sends control messages ("next lift", "end") over the session. Phone starts it via `startWatchApp` (exists). No home-made message protocol. |
| Phone must be nearby | Yes, for lifting blocks. |
| Phone disconnects | Watch keeps recording and tagging sets to the last lift; it shows "Phone away · recording" and offers **End lifting** (and **Next lift**) on the watch as a fallback. When the phone comes back, the mirrored session reconnects and the phone shows the sets recorded meanwhile. If the phone app was closed, reopening it re-attaches to the running session. If the phone never comes back, End on the watch saves the block normally and it syncs later like any result. |
| Stage | Before TestFlight (with the data model v2). Nothing of this before Anaheim. |

Findings changed by this decision: **W-9** and **M-7** (watch runs lifting blocks itself) → replaced by phone control; **W-8 / C3** "one Health workout per gym day" → rejected (one per active block); **W-10** watch load stepper → kept only for the stand-alone Lift session on the watch.

---

## 2. Every finding

### UX / IA review (review-ux.md)

| # | Finding | Decision | Reason / where |
|---|---|---|---|
| UX-1 | Build order breaks P1 (photo, builder, schedule, targets, calibration after race) | **Adapt** | Race-critical P1 before Anaheim; photo, builder, schedule, calibration Before TestFlight (see conflicts). |
| UX-2 | Watch IA is one wireframe; write a watch tree | **Accept** | v2 §Watch: full tree + in-session + done + sync states. |
| UX-3 | No first-run path: onboarding, empty states, watch banner, migration notice | **Accept** | Before TestFlight. 3 skippable screens; units from locale. |
| UX-4 | Reports can't edit the result (variant, delete/merge, date, load, trim) | **Accept** | "Edit result" sheet next to Fix splits. Before TestFlight. |
| UX-5 | + misses no-watch actions; drop "From Library"; add Share Sheet | **Accept** | Add sheet: Paste · Photo/screenshots · Build · Log a result · Start on watch. Share Sheet extension. Before TestFlight. |
| UX-6 | Sync hidden behind Debug | **Adapt** | Watch already shows ↑N (C2). Phone: Settings › Watch & sync (pending, last sync, Sync now), Today chip, Log "Arriving from watch" row, Send diagnostics. Before TestFlight. |
| UX-7 | Model questions block the IA (gym day, partner, variant) | **Accept** | Decided in v2 data model. |
| UX-8 | Tabs: Today · Library · Log, + in nav bar, avatar on every tab, Insights later | **Accept (with big + button)** | See conflicts. |
| UX-9 | Library holds only startable things: Benchmarks · HYROX · Mine · Lifts; one Lift page; search in Log | **Accept** | Library: Benchmarks · HYROX · Programs (imported days, e.g. Mayhem) · Mine · Lifts. Log search Before TestFlight. |
| UX-10 | Accessibility: icon+text flags, signed deltas, VoiceOver chart sentences, Dynamic Type, double tap | **Adapt** | Signed deltas (+0:12) and text labels Before Anaheim (ahead/behind). Rest Before App Store. |
| UX-cut-1 | Cut readiness card | **Accept** | Later. Today shows last recovery instead. |
| UX-cut-2 | Defer Insights tab | **Accept** | Phased. |
| UX-cut-3 | Class workouts section → filter; drop "From Library" in + | **Accept** | "From gym / program" is a filter in Library › Mine. |
| UX-cut-4 | Defer calendar; "Schedule for tomorrow" covers S-09 | **Accept** | Schedule for a date Before TestFlight; calendar Before App Store. |
| UX-cut-5 | Defer estimated-max lift pages | **Adapt** | Lift page with best lifts + recent rep maxes Before TestFlight (Mayhem needs maxes); speed-by-load / estimated max from bar speed Before App Store. |
| UX-S-01/02 | No onboarding, no just-in-time permissions | **Accept** | Before TestFlight. |
| UX-S-05 | No empty states | **Accept** | Before TestFlight. |
| UX-S-13 | HYROX filed under Benchmarks, no division selector | **Adapt** | HYROX is its own Library section. Division selector Before TestFlight; before Anaheim just make sure the owner's race workout has the right distances/loads (data only). |
| UX-S-42 | Free workout not on watch, no "define afterwards" | **Accept** | Before TestFlight. Reuses existing "apply definition". |
| UX-S-54 | Trim end missing | **Accept** | Before TestFlight. |
| UX-S-59 | No delete/merge | **Accept** | Before TestFlight. |
| UX-S-69 | Log has no search/calendar | **Accept** | Search Before TestFlight; calendar Before App Store. |
| UX-S-82 | Calibration in wrong home | **Accept home, adapt timing** | Settings › Running + watch Calibrate. Before TestFlight (not race-critical, see conflicts). |
| UX-S-97 | No "Send diagnostics" | **Accept** | Before TestFlight (testers need it). |
| UX-S-22 / S-99 | No inbound link; no glossary | **Accept** | Before App Store. |

### Athlete review (review-athlete.md)

| # | Finding | Decision | Reason / where |
|---|---|---|---|
| ATH-1 | HYROX items after the race: race plan, ahead/behind, roxzone, divisions, calibration → before Anaheim | **Adapt** | Ahead/behind + simple target + roxzone (opt.) before Anaheim. Division selector and calibration Before TestFlight (not needed to race: division is fixed for the owner; splits come from Crown laps). |
| ATH-2 | Session → Block → Segment | **Accept** | Core of the v2 model; confirmed by Mayhem day. |
| ATH-3 | Scaling belongs to the result (Rx+/Rx/Scaled/Foundations/Custom + substitutions), PRs per level | **Accept** | Before TestFlight (model + Edit result). PRs per level Before App Store. |
| ATH-4 | Partner/team model now | **Adapt** | Tags on the phone Before TestFlight; watch toggle Before App Store (C7). |
| ATH-5 | Strength prescriptions: 1RMs per lift, % / RPE, plate rounding, complexes | **Accept, raised** | Mayhem prescribes "65–75% 1RM" daily. Rep-max store (1/3/5/10RM, dated) + %→suggested loads rounded to plates Before TestFlight. RPE, tempo, complexes Before App Store. |
| ATH-6 | Score types (time, rounds+reps, reps, load, cal, distance, total/lowest, CAP+reps, tiebreak) with sort direction | **Accept** | Model Before TestFlight. Adds "none / quality" (Mayhem core block) and "load per set + total". |
| ATH-7 | Fixed benchmark identity; variants link but never count as Rx | **Accept** | Before App Store (linking by name). |
| ATH-8 | Log a result + Share Sheet in + | **Accept** | Before TestFlight. |
| ATH-9 | Watch home ordered like a class; block headers; load per set | **Accept** | Watch home: Today (the day's blocks) · Free workout · Lift session · Workouts · Sync · Settings. Before TestFlight. |
| ATH-10 | Movement model: this-or-that recorded, EMOM variants, distance segments | **Adapt** | Record choice made: Before TestFlight. Alternating/failed-minute EMOM and auto-end at distance: Before App Store. |
| ATH-§3 | Full format list, loads M/F pairs, per-gym plates, movement standards | **Adapt** | M/F pairs (Mayhem "185/125") Before TestFlight: you pick your standard once in Profile. Per-gym plates/machine types Later. |
| ATH-§4 | Helpful insights (pacing decay, compromised run, bar speed at load, HR recovery, balance) vs vanity (calories, streaks, badges, bare HRV, sparse Fitness Level) | **Accept** | Insights phasing in v2. No streaks/badges/calorie cards. |

### Watch review (review-watch.md)

| # | Finding | Decision | Reason / where |
|---|---|---|---|
| W-1 | Sync depends on phone being open; build outbox + transferFile + acks + idempotent import | **Reject (already built)** | C1. Only the "edit overwritten by re-send" edge remains → data model v2. |
| W-2 | Sync state invisible; pending on watch, complication, Settings row, Log placeholder | **Adapt** | Watch already has ↑N (C2). Phone side Before TestFlight. Complication Later. |
| W-3 | Crash/battery: checkpoints, HK recovery, Resume / Save incomplete | **Accept, Before Anaheim** | C4. Checkpoints exist; add reading them back. Also write the result at the finish. |
| W-4 | Free workout + Lift session on watch home; name it later | **Accept** | Before TestFlight. |
| W-5 | Ahead/behind: targets in payload, ± per segment + cumulative | **Accept, Before Anaheim** | The core race item. |
| W-6 | Race mode: indoor run, calibrated pedometer, Crown run/roxzone/station, Always-On minimal, Race lock, Calibrate on home | **Adapt** | Roxzone laps Before Anaheim (opt.). Always-On already exists. Race lock rejected (C5). Calibration Before TestFlight. |
| W-7 | Forgot to stop: "Still going?" prompt + Trim end | **Accept** | Before TestFlight. |
| W-8 | No Health story; HKWorkoutBuilder only on watch; activity types; skip WorkoutKit; Smart Stack | **Adapt** | Health save already works (C3). Accept "only the watch writes" and "skip WorkoutKit". One workout per active block (owner decision), segments inside Before App Store. Smart Stack Later. |
| W-9 | Gym day on watch: blocks, [Next block], one session, one result | **Adapt (owner decision 1b)** | Lifting blocks run from the phone (mirrored session); timed blocks start on the watch from Today's list; each is its own Apple workout; phone groups them into one Session. No single all-day session. Before TestFlight. |
| W-10 | Units pushed to watch, plate-step stepper, double-tap, complications | **Adapt** | Units + plate steps Before TestFlight (Swiss tester). Double tap Before App Store. Complications Later. |
| W-note | Decide partner mode before Saturday WODs | **Adapt** | Saturday WODs keep working with the existing Doubles workouts; tagging Before TestFlight. |
| W-§3 | Watch tree + sync state table; phone→watch "On watch ✓" | **Accept** | Used as the base of v2's watch section, corrected for what exists. Send confirmation Before TestFlight. |
| W-§3b | Switch workout ≤60 s, Pause | **Accept, later** | Before App Store. |

### Data / import / Insights review (review-data.md)

| # | Finding | Decision | Reason / where |
|---|---|---|---|
| D-1 | Definition, result, session conflated; lock model first | **Accept (timing adapted)** | Model locked in v2; built Before TestFlight, not before the race (too big to test in 3 weeks). |
| D-2 | Variant on result + comparability key; scaled PRs first-class | **Accept** | Before TestFlight (model), PR logic Before App Store. |
| D-3 | Partner: team score + splits tagged me/partner/together; HR insights use "me" | **Accept** | Before TestFlight. |
| D-4 | Log a result; source (watch/manual/health/official); typed score with capped flag + sort direction | **Accept** | Before TestFlight. |
| D-5 | Raw recording immutable; edits a restorable layer; recompute PRs; UTC + time zone | **Accept** | Today's "original.json + Restore" is a first version of this; generalise Before TestFlight. Fixes C1(b). |
| D-6 | Import pipeline: source → blocks → movement match → track → confirm; Share Sheet; keep original on device; unknown movement mapped later backfills | **Accept** | Extended for Mayhem: several screenshots/one paste → one Session of typed blocks. Before TestFlight. |
| D-7 | Insights cold start; btwb level must cite published standards | **Accept** | Phasing in v2. |
| D-8 | Units: store kg/m/s + unit as entered; plate set; 1RMs | **Accept** | Before TestFlight. |
| D-9 | Health write before Anaheim; UUID per result; export-all | **Adapt** | Health write and UUIDs already exist (C1, C3). Export all Before App Store. |
| D-10 | Privacy: no real health data in repo; scrub diagnostics; share toggle; data stays on device + your iCloud | **Changed in Round 2: accepted by owner** | The owner allows their own motion and heart-rate data in the public repo. Rule kept: friends'/testers' data never goes in the repo. Diagnostics preview Before TestFlight; share toggle Before App Store. |
| D-§3 | Model entities (Movement, Definition+versions, Block, Plan, Session, Result, Recording, Split, LiftSet, Profile, Derived) | **Accept** | Explained in plain words in v2; adds Rep-max entries and Reference blocks (Mayhem). |
| D-§4 | Insights at 1 / 10 / 50 workouts | **Accept** | v2 Insights section. |

### Owner input: Mayhem day (mayhem-day.md, screenshots)

| # | Finding | Decision | Reason / where |
|---|---|---|---|
| M-1 | A day = list of typed blocks (warm-up, strength, metcon, core quality, gymnastics test, cool-down, reference doc) | **Accept** | Block types in the model: Warm-up · Strength · Metcon · Skill/Gymnastics · Accessory (quality) · Cool-down · Reference. |
| M-2 | Each block has its own score type and its own Log / Start / Results | **Accept** | Block cards on Today and in the Session view: [Log] (manual) and [Start on watch] for timed blocks; past results per block. |
| M-3 | Lift blocks show previous result (each set + total + Rx'd) and recent maxes (3RM/5RM/10RM) | **Accept** | Strength card: prescription, suggested loads from your maxes, last time, recent maxes. Before TestFlight. |
| M-4 | %1RM (e.g. 65–75%) → suggested loads from stored maxes | **Accept** | Needs a rep-max store and an estimated 1RM from a 3RM/5RM when no 1RM exists (marked "estimated"). Before TestFlight. |
| M-5 | M/F standards ("40/32 cal", "185/125 lb"), time cap, target score in instructions | **Accept** | Parser keeps both; Profile picks your column. Instructions kept as text on the block. |
| M-6 | Import a whole day from several screenshots or pasted text → one session | **Accept** | Add › Photo/screenshots takes several images at once; confirm screen shows the day as blocks. Before TestFlight. |
| M-7 | Watch runs the day block by block, skipping unscored blocks | **Adapt (owner decision 1b)** | Watch "Today" lists the day's timed blocks (metcon, V-ups test) to START; lifting blocks are started from the phone; warm-up/cool-down/reference are not started. Before TestFlight. |
| M-8 | Programs come from a subscription (Mayhem) | **Adapt** | No automatic feed (no public API; copying their content wholesale into a shared library is also a rights issue). Import is personal, stays on the device. Library › Programs groups imported days by source. |

---

## 3. Priority changes vs scenarios.md

| ID | Was | Now | Why |
|---|---|---|---|
| S-82 calibration | P1 | Before TestFlight | Splits come from Crown laps at the mats; pace accuracy doesn't change race splits. |
| S-13 division selector | P1 | Before TestFlight | Owner's race is one fixed division; set it in the race workout data. |
| S-33 %1RM | P1 | Before TestFlight (confirmed, and raised in weight) | Mayhem daily use. |
| S-35 gym day | P1 | Before TestFlight: one Session in Rx Lab, several Apple workouts (lifting from phone, metcons on watch) | Owner decision 1b. |
| S-28/S-29 partner/doubles | P1 | Tagging Before TestFlight, watch toggle Before App Store | Team time already works. |
| S-14 readiness | P2 | Later | Extra permissions, low value now. |

---

## 4. Open questions only the owner can answer (max 6)

1. **Anaheim: Solo or Doubles, Open or Pro, and which category?** Default: none assumed. Until answered, the race plan works on whichever HYROX workout you pick, and Profile asks for your load column (no preset).
2. **Roxzone laps on race day?** That is 4 Crown turns per lap (run · roxzone · station · roxzone) instead of 2. Default: **on** in the full trial sim (week of 15 Nov); keep it for the race only if no turns were missed.
3. **Race target: one goal finish time shaped by your best *full* sim, or "beat my best sim" as-is?** Default: goal time (e.g. 1:15:00, illustrative); shape from the best full sim with the same segments, else a standard HYROX template.
4. **Test build Sun 15 Nov + full trial sim that week, freeze Sun 22 Nov, half sim / race-pace segments on the frozen build in the week of 23 Nov — fits your training?** Default: yes; after that only bug fixes.
5. **Lift + WOD on the same day: one Log entry (a Session with blocks)?** Default: yes, blocks done within the same day are grouped automatically; you can split them.
6. **Where do workouts come from most: Mayhem screenshots, box whiteboard photo, or pasted text?** Default: build multi-screenshot import first (it covers Mayhem and whiteboard), paste second, Share Sheet third.


---

## Round 2 (review2-ux-athlete.md, review2-watch-data.md, owner notes) → proposal-v3.html

Code re-checked for the lifting claims: `LiftType` is Olympic lifts + `other`; `OnlineLiftDetector` looks for a hanging forearm and a pull; the HealthKit share set is `workoutType` only; the two real-data fixtures exist in `BarPathKit/Tests/BarPathKitTests/Fixtures/`. Reviewers were right on all of these.

### UX / athlete round 2

| # | Finding | Decision | Reason / where in v3 |
|---|---|---|---|
| R2-UX-1 | Race flows use Library › HYROX and watch Today, which won't exist before the race | **Accept** | §12 walks + §14: today's Workouts tab › Choose › preview › Race plan; watch Workouts page › START. |
| R2-UX-2 | Two strength blocks vs one lifting block; Log row lists only back squat; "4 scored" wrong | **Accept** | §8: consecutive strength blocks run as one lifting block, each lift keeps its own result. Log mock has front squat; walk says 5 scored blocks. |
| R2-UX-3 | Day scheduled but never sent to the watch | **Accept** | Timed blocks are sent automatically on the scheduled day, plus Send day to watch on Today. |
| R2-UX-4 | "CAP+82" ambiguous | **Accept** | "82 reps at cap (7:00)" everywhere. |
| R2-UX-5 | Old last result (245 lb, 2024) above lower suggested loads reads as a bug | **Accept, merged with R2-WD-10** | Old results greyed "over a year ago"; suggested loads from tested 1RM, else best estimate within 12 months, source shown ("from 3RM 215 · est. 1RM ~230"). 12 months, not 6, to match the data reviewer's rule. |
| R2-UX-6 | Defaults assume the owner's sex/division | **Accept (owner note)** | No "Open Men"/"men's": division and load column are Profile/first-run questions with no preset; Q1 reworded. Pronouns in scenarios.md fixed to they/you. |
| R2-UX-7 | Split shape breaks with a Half sim or no roxzone; add Delta off | **Accept** | Shape from best full sim with same segments, else standard HYROX template; "Delta off" switch. |
| R2-UX-8 | Roxzone trial has no date; full sim 10 days out too late | **Accept** | Test build Sun 15 Nov + full trial sim that week; freeze 22 Nov; half sim / race-pace segments on the frozen build; hidden "Simulate crash". |
| R2-UX-9 | S-39 buy-in run in no stage | **Accept** | Distance run segment (pace from steps, manual end) Before TestFlight. |
| R2-UX-10 | IDs listed twice / S-41 wrongly "works today" | **Accept** | Each ID once (checked by script: 100 IDs, no duplicates); S-36 and S-41 Before TestFlight. |
| R2-UX-11 | Done-screen "Next block" marked later but drawn | **Accept** | Next timed block on the done screen is Before TestFlight. |
| R2-UX-12 | Jargon | **Accept** | "Stored in kg/m/s plus the unit you typed", "PRs compared like with like", "Apple's live link between watch and phone workouts", "fixes kept separate from the raw recording"; Data mode and Screen demo explained and moved to watch Advanced. |
| R2-UX-13 | No place to see declined permissions | **Accept** | Settings › Permissions. |
| R2-UX-opt-1 | Phone report shows target deltas before Anaheim | **Accept** | Needed to review the trial sim. |
| R2-UX-opt-2 | Mayhem "target score" as metcon ahead/behind target | **Accept, later** | Kept on import now; used as target Before App Store. |
| R2-UX-opt-3 | Show row ladder on confirm screen | **Accept** | Confirm mock shows 40-30-20-30-40 cal + 7 power cleans. |
| R2-UX-opt-4 | List Build formats; partner hint | **Accept** | §9 lists formats; partner walk has the Crown hint. |
| R2-UX-opt-5 | Fix "he/his" in scenarios.md | **Accept** | Done (S-14, 18, 26, 28, 29, 38). |

### Watch / data round 2

| # | Finding | Decision | Reason / where in v3 |
|---|---|---|---|
| R2-WD-1 | Motion detection can't find squat sets | **Accept + owner input** | Sets are marked by the athlete: Double Tap on the watch (decided, see O-2), Set done on the phone as backup; motion stored per set from Data mode; Olympic lifts grouped under the current set; `movementId` next to `LiftType`. New §7 plan to learn squat/press detection (see owner rows below). |
| R2-WD-2 | Watch can't start a phone-controlled block | **Accept** | Phone sends a lifting-block plan by application context before opening the watch app; the watch starts the session itself; metcon START blocked while lifting runs. |
| R2-WD-3 | Mirroring still needs a protocol and reconnect | **Accept** | Versioned commands in shared code with tests; watch owns the event log and set IDs; full state sent on every (re)connect; phone re-attaches at launch; first Before TestFlight item is a trial run (go/no-go). The v2 line "no home-made message protocol" is corrected: Apple's link carries our small, defined commands. |
| R2-WD-4 | Phone-entered loads must not live in the recording | **Accept** | Kept in the fixes layer, keyed by the watch's set ID. |
| R2-WD-5 | New file types must be re-sendable | **Accept** | Lifting-block file type added to the re-send list with a round-trip test. |
| R2-WD-6 | Saving at finish and End: overwrite and ordering risk | **Accept** | Revision number; phone keeps newest; End cancels the queued finish copy; arrival over an edited result is stored as the original. |
| R2-WD-7 | Resume under-specified | **Accept** | Progress + workout ID written atomically to a file; Apple's workout recovery continues the same workout; heart-rate gap filled from Health; "Simulate crash"; fallback = Save as incomplete only if Resume isn't solid by 15 Nov. |
| R2-WD-8 | Sync table promised states the phone can't know | **Accept** | Watch publishes its outbox list; Sync now asks the watch to resend, else "Open Rx Lab on your watch"; Health ✓ moved to the End row. |
| R2-WD-9 | Grouping needs IDs; migration rules | **Accept** | Session/block IDs sent and echoed; date grouping only for unplanned; old lift session → one lifting block, old result → one metcon block; old files keep importing. |
| R2-WD-10 | Score definitions: 3675 = Σ load×reps; best set for "heaviest"; %1RM base rule | **Accept** | §8 "Scores for lifts"; mayhem-day.md note fixed. |
| R2-WD-11 | No sim has roxzone yet | **Accept** | The 15 Nov trial sim records roxzone and becomes the target shape. |
| R2-WD-12 | Real HR data in public repo fixtures | **Accepted by owner** | Owner explicitly allows their own motion and HR data in the public repo. Kept rule: friends'/testers' data never goes in the repo; diagnostics leave out HR and raw motion unless ticked. |
| R2-WD-13 | Insight gates per like-for-like results; pedometer pace "estimate" | **Accept** | 3 results for a delta, 5 for a trend; pace labelled estimate until calibrated (also on the watch race mock). |
| R2-WD-opt-1 | Add heart rate / energy to HealthKit share set; check Fitness calories | **Adapt** | Check on the Fitness card Before TestFlight; add if missing (not touched before the race). |
| R2-WD-opt-2 | Logic in BarPathKit, `swift test` on a Mac/CI | **Accept** | Build-order rule in §14. |
| R2-WD-opt-3 | Before TestFlight too big; order it | **Accept** | Window now Dec–Feb; order: link trial → model + migration → Log → lifting → import → tabs. |

### Owner input: measure every barbell lift (late 1 Nov)

| # | Input | Decision | Note |
|---|---|---|---|
| O-1 | Measure all barbell lifts (squats, overhead squat, presses, bench later): reps, speed per rep, path | **Accept** | New v3 §7, four steps. |
| O-2 | Set start/stop now by hand as training labels; correct later | **Decided by owner (confirmed):** watch **Double Tap = primary** for set start and set end; phone **Set done = backup**. | The owner's "Crown press as hidden fallback" is adapted to a hidden Crown **turn**: watchOS keeps the Crown press for going home, so apps can't use it. Before TestFlight. |
| O-3 | Data collection: Data mode on every lifting block; ~20–30 labelled sets per lift | **Accept** | "Sets collected" counter on the Lift page; starts Before TestFlight. |
| O-4 | Automatic set detection + rep counting in shadow mode, manual always available | **Accept** | Shadow mode Before App Store (per lift, when it has enough data); fully automatic + bench Later. |
| O-5 | Feasibility: wrist moves with the bar in squats/presses; bench arm too | **Accept, with limits** | Overhead squat may need more data (wrist still, body moves); wrist speed is an estimate. |

### Final self-check of v3 (P1 scenarios + Mayhem day)

Walked all 56 P1 scenarios against v3, each counted as of the stage where v3 schedules it.

- **Works:** 49.
- **Partial (5):**
  - S-28 / S-29: partner work is tagged on the phone after the workout. The watch "partner working" toggle comes Before App Store.
  - S-31: EMOM works. Alternating minutes and failed-minute marks come Before App Store.
  - S-49: Olympic lifts work today. For squats and presses, reps come from what you type (sets marked by hand) until shadow mode.
  - S-55: the race build may ship only "Save as incomplete" if Resume isn't reliable by 15 Nov.
- **Moved on purpose (2):** S-13 (division selector) and S-82 (calibration) go to Before TestFlight; neither is needed to race.
- **Fails:** 0.
- **Mayhem day:** works Before TestFlight: import, block cards, lifting from the phone, metcon/V-ups on the watch, one Log row with 5 scored blocks. It stays partial in two points:
  - Squat reps come from typing until shadow mode.
  - The metcon's target score drives ahead/behind only from Before App Store.
- **HTML:** proposal-v3.html tags balanced (checked by parser).
- **Build order:** each of S-01…S-100 appears exactly once.
