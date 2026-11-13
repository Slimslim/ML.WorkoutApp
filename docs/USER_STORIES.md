# User stories

One list for the whole app, so every chat works from the same picture of what the athlete
needs. Each area keeps its own section; add stories to your area, don't edit another
area's stories (propose changes in your PR instead).

## How to write one

```
**<ID>. <Short title> (<Now | Later>)**
As a <who>, I want <what>, so that <why>.
*Done when:* <one or two checks we can actually test, in the gym or against video>.
```

- **IDs** are a prefix plus a number and never change or get reused. Lifting uses `S`
  (setup), `T` (technique), `L` (sets/logging) and `P` (progress). Workouts use `W`,
  navigation uses `N`. Pick the next free number in your prefix.
- **Now** = in the first version of that feature; **Later** = after that.
- Write from the athlete's side ("see how fast I get under the bar"), not the code's
  ("add turnover metric to LiftMetrics").
- "Done when" must be checkable: a number against video, a tap count, a time limit.
- When a story ships, add `— shipped in #<PR>` to its title line. Don't delete it.

## Lifting

Olympic lifting has two modes, and they answer different questions:

- **Technique** (singles, live): *how am I moving?* Bar path, pull speed and height, and how
  fast I get under the bar, shown rep by rep on the phone while I walk back to the bar.
- **Sets** (logging): *did I do the work?* Sets × reps × weight, rest timer, and one chart
  per set showing the bar going up and down over time. Includes touch-and-go sets and
  strength lifts like the deadlift.

Both feed **progress**: same lift, same weight, is the bar moving faster than before?

### Setup (both modes)

**S1. Pick my mode (Now)**
As a lifter, I want to choose Technique or Sets when I pick my lift, so the watch knows
whether I'm working on technique or logging work.
*Done when:* the watch setup shows Lift, Weight and Mode and starts with one tap; the last
mode used for each lift is remembered.

**S2. Change between blocks without ending my workout (Now)**
As a lifter, I want to switch from snatch technique to deadlift sets mid-session, so the
whole gym session stays one workout.
*Done when:* Change → pick → Continue takes 3 taps or fewer, and Apple Fitness shows one
workout.

### Technique mode (singles, live)

**T1. See each rep while I walk back (Now)**
As a lifter doing singles, I want the phone to show the rep I just did by the time I'm
back at the bar, so I can adjust the next one.
*Done when:* the rep appears on the phone within 5 s of dropping the bar, readable from
3 m.

**T2. Know how hard I pulled and how high (Now)**
As a lifter, I want peak bar speed and pull height for each rep, so I can tell a strong
pull from a weak one.
*Done when:* both numbers show in large type and match video within about 0.1 m/s and
5 cm.

**T3. See how fast I get under the bar (Now)**
As a lifter, I want a turnover time (top of the pull to the catch) and how far I dropped,
so "snap under the bar" becomes a number I can improve.
*Done when:* turnover shows in seconds and stays within about 0.08 s of video; if the catch
isn't found, it shows "—" rather than a wrong number.

**T4. Compare with my previous rep (Now)**
As a lifter, I want this rep next to the previous one, so I can see whether my change
worked.
*Done when:* the previous path shows as a faint ghost, with the difference for each number
(e.g. "▲ 0.08 m/s").

**T5. Show someone what "slow under the bar" means (Later)**
As a coach or training partner, I want to show a slow and a snappy rep side by side, so
the difference is obvious.
*Done when:* I can pick any 2 reps from the session and compare them.

### Sets mode (logging)

**L1. Count my touch-and-go reps (Now)**
As a lifter doing 5 × 3 touch-and-go, I want the watch to count the reps, so I don't have
to.
*Done when:* the count is right on filmed test sets, and the set saves itself a few seconds
after the bar goes down.

**L2. Time my rest (Now)**
As a lifter, I want a rest timer to start when the set ends, so I know when to go again.
*Done when:* the timer counts up by default; with a rest time set (e.g. 3:00) it counts
down and buzzes at zero.

**L3. Change the weight between sets in one move (Now)**
As a lifter, I want to adjust the weight during the rest, so each set is logged at the
right weight.
*Done when:* turning the Crown on the rest screen changes the weight for the next set, with
no menus.

**L4. Log my session (Now)**
As a lifter, I want the phone to keep my sets, reps and weights, so I have a training log
without writing anything.
*Done when:* the session shows rows like "Snatch · 5 × 3 · 135 lb · rest 2:40 avg".

**L5. See how a set went (Now)**
As a lifter, I want one chart per set showing the bar going up and down over time, with
the speed of each pull, so I can see whether I slowed down.
*Done when:* each rep's pull speed is labelled and coloured, and tapping a rep opens its
detail.

**L6. Follow a plan (Later)**
As a lifter, I want to send "5 × 3 @ 135 lb, rest 3:00" from the phone, so the watch guides
me: "Set 2 of 5", the rest countdown, then the next set.
*Done when:* the plan arrives on the watch and the set number moves on automatically.

### Progress (both modes)

**P1. See that I'm getting faster (Now, simple version)**
As a lifter, I want to compare today with the same lift and weight from weeks ago, so I
can see that "it feels lighter" in the data.
*Done when:* each lift and weight shows its average and best pull speed per session over
time.

### Decisions so far (lifting)

- The live view compares with the **previous rep** (a "best rep" option may come later as
  a setting).
- Speed colours are **absolute** (the same speed is always the same colour).
- First build: S1, T1–T4, L1–L5, P1. L1 needs a filmed touch-and-go recording session
  first; there is no touch-and-go data yet.

### What the data says (checked against video, 29 Oct 2026 recordings)

- Turnover time (top of pull → catch): within 0.08 s of video on 8 of 9 checkable lifts;
  drop under the bar within 1–8 cm. The catch wasn't found on 2 of 18 lifts.
- Set timeline: bar height drifts up to 65 cm over a set unless it's reset at the top of
  each rep; with the reset, rep depth matches video within about 0.3–6 cm and pull speed
  within ±0.05 m/s on 10 of 12 deadlift reps.
- Not checked yet: squats, touch-and-go Olympic sets, sticking points.

## Workouts (Hyrox / CrossFit)

*Owned by the Workouts chat. Add stories here with the `W` prefix.*

### Interval workouts (EMOM, "every N:00")

**W1. Each minute starts by itself (Now)**
As an athlete doing an EMOM, I want the watch to start the next set on every minute mark with
a 3-2-1 and a strong tap, whether or not I turned the Crown, so I never have to catch up.
*Done when:* in an 8-minute EMOM done without touching the Crown, the watch shows set k from
minute k−1:00 for every k (±1 s), the last set finishes at 8:00, and later minutes never shift.

**W2. Turning the Crown means "set done" (Now)**
As an athlete, I want a Crown turn after my reps to start my rest, with the time left in the
minute shown, so my rest is recorded; skipping it must not break anything.
*Done when:* Crown after the reps → rest until the minute mark; no Crown → the rest is recorded
as 0 s and the next set still starts on the minute.

**W3. See my EMOM minute by minute (Now)**
As an athlete, I want the workout report to show each minute as a row: weight, reps found,
how fast I started after the beep, work time and rest left, so I see where the minutes got
tight.
*Done when:* the 2026-11-02 power C&J EMOM shows 8 rows matching the motion analysis
(16 reps, start delays 2.5–24 s, rest left 42 → 12 s).

**W4. Weight per set (Later)**
As an athlete, I want to enter the weight of each set (125 → 175 lb) once, on the phone, so
bar speed can be compared with the load.
*Done when:* weights entered in under 30 s for 8 sets and shown in the W3 rows.

### Transitions

**W5. Transition vs work time (Later)**
As an athlete, I want each split shown as setup + work, with total time in transitions, so I
see the time I lose walking and setting up.
*Done when:* on the AMRAP 40 and Freedom files, transitions match the motion analysis within
5 s for 80 % of segments (docs/TRANSITIONS.md).

### Recovery after the finish

**W6. End when I'm done, still get 3 min of recovery (Now)**
As an athlete, I want to press End when I'm done (a few seconds after the finish, walking
around) and still have my heart-rate recovery recorded to 3:00 after the finish, without a
waiting screen or another tap, so I can look at my results right away and the recovery fills
in by itself.
*Done when:* End confirmed 30 s after the finish → the watch is back on the start screen at once
("Recovery recording · 0:31" counting there) and the phone shows the result at once (no recovery
card yet, < 1 min); at 3:00 after the finish the phone's result updates by itself (same workout,
not a second one) and shows the 1 / 2 / 3 min recovery; an edit made on the phone in between is
kept. Starting a new workout or a lifting session before 3:00 stops the recording (the phone
gets what was recorded) and the new session starts within ~1 s. Apple Fitness shows the
workout ending at the End press.

### Time caps

**W7. Keep going past a for-time cap (Now)**
As an athlete doing a for-time workout with a cap, I want the watch to tell me when the cap
passes but let me finish the whole workout, and then ask how many reps of the movement I was
on I had done at the cap, so I know both my full time and how far I got within the cap. I can
still press End whenever I decide to stop.
*Done when:* Helen (16:00 cap) still running at 16:00 → the strong "Time!" haptic and a
"TIME CAP · KEEP GOING" banner for ~3 s, the workout does not stop and the total keeps counting
("+0:42 over cap"); after the last Crown turn the done screen asks "Reps of <movement> at the
cap?" (Crown, 0…target, skippable); the phone shows the full time as the score and "… over the
16:00 cap · at the cap: 7/12 Pull-ups (R3)". Finishing under the cap and AMRAP caps behave as
before.

### Workout library (docs/WORKOUT_LIBRARY.md)

**W8. Add a workout without an app update (Now)**
As the owner, I want to add today's class workout to the app by pasting one SQL statement in the
Supabase dashboard, so I can run it on the watch the same day without building or reinstalling.
*Done when:* after running the SQL from `tools/library/make_row.py` and pulling down in Choose,
the workout is listed within 5 s, Send to watch puts it on the watch, and the result on the phone
carries its name and segments like a built-in workout.

**W9. Today's workout at the top of Choose (Now)**
As an athlete, I want the workout programmed for today at the top of Choose, so picking it is one
tap after opening Choose.
*Done when:* a row with `scheduled_on` = today (phone calendar) is in a "Today" section above
everything else; other library workouts are grouped by program, newest first, each with its date;
the built-in groups follow.

**W10. Works offline from the last list (Now)**
As an athlete in a gym with no signal, I want Choose to still show the library workouts I saw
last time, so I can send one to the watch without a connection.
*Done when:* in airplane mode (or signed out) after one successful refresh, Choose shows the same
library workouts and Send to watch works; a failed refresh shows a short note and keeps the list.

### Workout card (docs/concepts/HEADER_STUDY.md, workout-cards.html)

**W11. Read a workout the way the whiteboard writes it (Now)**
As an athlete choosing what to send to the watch, I want each workout written like the gym
whiteboard (name, `3 rounds` / `40 min AMRAP` / `Every 1:00 × 8`, one movement per line with its
load, the cap at the bottom), so I can tell what it is at a glance and check it before I start.
*Done when:* every row in Choose shows the name, `block · type`, one line of movements and my
last score when I have one; the preview shows the full card (date · program or Built-in, block
and type tags, time domain, rep scheme, movements, cap) above Send to watch; Freedom reads
`5 rounds` / `40-30-20-30-40 Cal` / `Row` / `7 Power Cleans @155 lb` / `20 min cap`. The card text
comes from one model (Python reference + Swift port with a parity test).

**W12. Find a workout by searching (Now)**
As an athlete with a growing library, I want a search button at the top right of Choose, so I
can find "Freedom", every workout with KB swings, or every EMOM without scrolling through
programs.
*Done when:* the magnifying glass opens a search field; typing filters Today, every program and
the built-ins together, matching the name, short name, program or group, movement names (as
written, full and short: "KB", "C&J", "Row") and the type or block tag ("EMOM", "RFT",
"Strength"); every word typed must match; no match says so; clearing the search brings the
full list back.

**W13. See my history of a workout before I send it (Now)**
As an athlete about to redo a workout, I want the preview to list my past results of it, so I
know the score to beat and can open how it went last time.
*Done when:* under the card a "Your results" list shows each past result newest first (date,
score, Rx / Scaled once that is recorded, average heart rate), three at first with "Show all";
tapping one opens its report. A result counts for the workout when it has the same id, or the
same name and the same segment kinds and movements in order (my Freedom saved as `wod.freedom`
shows under the library's PitFIRE Freedom; the PC&J EMOM saved as `wod.pcjEmom` likewise). The
"last" score on the Choose rows uses the same rule (Freedom shows 19:37). Matcher in BarPathKit
(WorkoutHistory) with a Python reference and tests in both.

**W14. A log of done cards (Now)**
As an athlete looking back at my week, I want the Workouts tab to list what I did as the same
cards, with the score on the right, so the log reads like the whiteboard and I see results at a
glance.
*Done when:* the "Next workout on watch · Choose" row is the first row of the list and never
covers the title or the results; each logged workout is a compact done card (name, date ·
program · block · type, one line of movements, score and an Rx / Scaled badge on the right,
dashed `?` until answered), drawn from the library's current version of the workout when it has
it; swipe to delete still works. The report opens with the full done card (date · program, tags,
name, time domain, rep scheme, movements, cap, then the score line with the context, the change
vs last time and the heart-rate facts), replacing the old header; heart rate, recovery, story,
splits, share and Fix splits follow unchanged.

**W15. Scale a workout before I do it (Now)**
As an athlete, I want to change a workout's weights, rep scheme and movements, so the watch runs
what I am really doing.
*Done when:* the workout preview has Scale; I can change the load, reps or rep scheme and swap a
movement; the changed version is saved as my copy and sent to the watch, the original stays as it
was, and the result is recorded as Scaled with what I did.

**W16. Correct a result after the workout (Now)**
As an athlete, I want to fix the weights or reps of a finished workout.
*Done when:* the report and the done card have Edit; I can change the load per set or movement, the
reps and Rx / Scaled, and save; the original stays restorable (like Fix splits); the report, Log and
the "last" score use the corrected values.

### Corrections from the cloud

**W17. A recording corrected in the cloud shows on my phone (Now)**
As an athlete whose recording was corrected outside the app (by Claude reading my uploaded watch
data, or by me in the dashboard), I want the phone to pick up the corrected version, so the report,
Log and history show what I really did and not what the watch guessed.
*Done when:* after the result file in my cloud folder is replaced by a version with a later
`editedAt` than the phone's copy, opening the app (or pulling down in the Log) replaces the phone's
copy within 10 s; the report shows the corrected parts, reps, loads and heart rate; Restore original
brings back the phone's previous copy; a phone copy edited later than the cloud copy is never
overwritten; offline, the phone copy stays as it was. The download goes in the same sync that
uploads, and a downloaded file is not uploaded back.

**W18. See a partitioned workout round by round (Now)**
As an athlete who splits a chipper into small rounds (e.g. 50 pull-ups + 100 push-ups done as
25 × 2 + 4), I want the recording to show each round with its reps, the time on each movement, the
rest and my heart rate, so I can see where I slowed down and how long each movement really took.
*Done when:* a result whose own parts are rounds (the recording carries its parts; the planned
workout in the library stays as written) shows in the report as Round 1…N, each with time per
movement, rest and average / max heart rate, plus a total per movement (time and reps); the done
card and score use the recording's parts, not the library version of the workout.

**W19. Rx / Scaled saved with the result (Now)**
As an athlete, I want whether I did a workout Rx or Scaled stored with the result, so my history
and the "last" score compare like with like.
*Done when:* a result with `rx: true` (set by a cloud correction or by W16's Edit) shows the Rx
badge on its done card, report and in "Your results" (W13); `rx: false` shows Scaled; no value
shows the dashed `?` as today; older results without the key still open unchanged.


**W20. An AMRAP that ends on a run scores the distance (Now)**
As an athlete whose time cap hits during a run, I want the score to say how far I got on that run
(e.g. "5 rounds + 44 reps + 41 m"), so I don't have to make up a rep count for a run.
*Done when:* when the cap ends a run segment, the watch does not ask "Reps of …?"; the result keeps
the run's measured distance (pedometer, or GPS once runs use it) as the partial and the score reads
"+ <m> m" on the watch done screen, the report and the done card; for a station the reps question
stays as today. (SunYay 2026-11-08: the cap hit 21 s and 41 m into the run; 11 "reps" were entered.)

### First workout (MVP, from the first tester: 2026-11-10)

**W22. A practice workout before my first real one (Now)**
As a new athlete, I want a 1-minute practice on the watch before my first workout, so the
permission prompts don't hit me mid-run and I know how to move to the next movement and finish.
*Done when:* on first launch (and from Settings later) "Practice workout" runs on the watch:
1. Before START it asks for heart rate and motion, explaining why ("heart rate for your effort and
   recovery, motion to count reps"); if refused, it says what will be missing and how to turn it on.
2. Part 1 "Walk or march" shows the **real** heart rate within 10 s and an arrow to the Crown:
   "**Turn the Crown** when you finish a movement". Turning it moves to part 2 with a haptic.
3. Part 2 says "Again: turn the Crown"; turning it finishes the workout.
4. The finish screen explains: "We record **3 min of recovery**. You can **swipe left and tap
   End**; the recovery keeps recording in the background." Swiping left and tapping End completes
   the practice.
5. The practice saves no result, uploads nothing and adds nothing to Apple Fitness. A first-time
   tester does it in under 2 minutes without help.

**W23. Tell me when heart rate or motion is off (Now)**
As an athlete, I want the app to tell me before a workout if heart rate or motion access is off, so
I don't find out afterwards that nothing was measured.
*Done when:* the phone's Workouts tab and the watch start screen show "Heart rate is off" /
"Motion is off" with what it costs (no HR, recovery, distance, reps) and a button that opens the
right Settings page; the banner goes away as soon as access is on. (a tester, 2026-11-10: no HR or
steps recorded at all.)

**W27. Timed work intervals: Tabata 20 / 10 (Now)**
As an athlete doing a Tabata (8 x 20 s work, 10 s rest), I want the watch to switch from work to rest
and back by itself on the clock, so its timer matches the gym's buzzer and the rest is recorded.
*Done when:* a work segment with a seconds target ends by itself after that time (like a rest with a
seconds target does today), with the same 3-2-1 countdown; a library Tabata is entered as 8 x
(work 20 s, rest 10 s) and the watch shows 0:20 then 0:10, eight times, with no Crown turn; the
result has one work and one rest segment per interval. Other work segments with a seconds target
(e.g. "max reps in 1:00" inside a for-time workout) get the same rule, checked in the existing
library first. (Owner, 2026-11-10: the Tabata press and row timers counted 30 s; the watch today only
ends a work part on the interval boundary, so the 10 s rest was never shown.)

**W28. My workout uploads without opening the phone app (Now)**
As an athlete who ends the workout on the watch and walks away (phone locked in the bag), I want the
recording to reach the cloud by itself, so nothing waits on me opening the app.
*Done when:* after END on the watch, with the phone locked and the app not opened, the result and the
recording are in the cloud within 15 minutes (phone on Wi-Fi or cellular), checked on 3 sessions
including one of 60 minutes; nothing is lost when it takes longer (it goes on the next wake or the
next app open, as today). (a tester, 2026-11-11: Chad arrived 2.5 h after the end, only once the app was
opened; he does not look at results on the phone.)
How (to check on a device, background behaviour cannot be tested in CI):
- **Wake the phone app:** at END, while the watch app is still in front, the watch sends one message
  (new key, e.g. `type: "filesQueued"`); a watch message wakes the iPhone app in the background.
  Shared files `Watch/PhoneLink.swift` and `iOS/PhoneLink.swift`: small separate commit.
- **Receive and queue:** on that wake the phone activates WatchConnectivity (queued file transfers are
  delivered), restores the sign-in and queues the uploads (background `URLSession`, already in place),
  inside a background task long enough for the gzip copy (#24).
- **Locked phone:** the sign-in must be readable after the first unlock (check the Supabase session
  storage's keychain accessibility) and received files keep the default protection (readable after
  first unlock, not `.complete`).
- **Late uploads:** an access token lasts 1 h; an upload that starts later gets 401. A background app
  refresh (`BGAppRefreshTask`) refreshes the token and re-queues what is left.
- **Size:** the bucket takes 50 MB per file; a tester's 58-min Chad was 42 MB uncompressed, so a
  70-min session would be refused without the compressed uploads of #24. Build after #24.

### Recording follows the plan (spans Lifting and Workouts; after the MVP)

**W21. The watch records each part the way that part needs (Later)**
As an athlete whose program mixes barbell lifts, runs, ergs and metcons, I want the watch to
switch to the right sensors and analysis for whatever comes next in the plan, so every movement is
measured properly (a snatch gets bar speed, height and catch; a run gets GPS; a bike doesn't waste
battery) without me choosing modes.
*Done when:* in one session that has a barbell piece and a metcon (e.g. power snatch every 1:00 x 10,
then Freedom), with one START:
- **Olympic lifts** record 200 Hz motion + 800 Hz accel and give each lift its peak pull speed, max
  bar height and catch height, also without a still moment before the lift (the 2026-11-09 EMOM:
  today only 6 of 20 snatches could be analysed); **strength lifts** count reps with speed per rep;
  **runs** use GPS outdoors (pedometer indoors); **ergs/bike** use a low rate and no GPS; **metcon
  stations** stay at 100 Hz; **rest** drops to a low rate but still sees the next set start within 1 s.
- Switching profiles loses no data: no gap over 0.1 s at a switch, in the CSV or the result.
- **Apple Fitness stays clean: one session is one workout** in Fitness/Health (one activity type,
  one route only when there was an outdoor run), never one per part or per lift; HR and calories
  continuous across the whole session.
- Battery and upload size per hour are measured on a 60-min session and are no worse than today's
  workout mode (30 MB / 40 min).
Needs: lift pieces in the program (sets x reps x weight) and the single start screen; tested first
on recordings, then in the gym, before it replaces the two modes.

## Navigation and layout

*Owned by the Navigation UI/UX chat. Add stories here with the `N` prefix.*

Beta scope agreed with the owner on 3 Nov 2026. Layout, colours and wording: `docs/DESIGN_GUIDELINES.md`.

**N1. One footer I understand (Now)**
As a tester opening the app, I want a plain footer, so I can find everything without being told.
*Done when:* the footer is the standard iOS tab bar with Today · Workouts · + · Log · Progress, the
app opens on Today, and every feature of
the old Live, Lifts, Workouts, History and Debug tabs can still be reached (table in the guidelines,
section 6). Settings sits behind the avatar.

**N2. See my day first (Now)**
As an athlete, I want Today to show my effort, the week and today's workouts, so I know what I did
and what is next.
*Done when:* the top shows Effort (N6), the days strip moves through the week with ✓ for days with a
result, and tapping a day shows its library workouts (`scheduled_on`) as flat blocks: planned blocks
with Send to watch, done blocks with name and score. A block opens its card or report.

**N3. A first look for new testers (Now)**
As a new tester with no program and no data, I want Today to tell me how to start.
*Done when:* with no library workouts and no results, Today offers Start a workout and Record a lift,
and nothing looks broken or empty.

**N4. One log (Now)**
As an athlete, I want lifts and workouts in one list, newest first, so I don't have to remember
where something is.
*Done when:* Log shows lifting sessions and workouts together by date, opens the existing reports,
and keeps delete with confirmation and Fix splits.

**N5. The + starts things (Now)**
As an athlete, I want one place to start something new.
*Done when:* tapping + opens a standard iOS menu, Record a lift and Start a workout, which open the
existing lift chooser and the Workouts tab. The next workout on the watch and its send status stay visible.

**N6. Effort from what the watch measured (Now)**
As an athlete, I want one number for how much I did, based on measured heart rate.
*Done when:* Effort is minutes × heart rate zone from start to finish, added per local day, with max
heart rate the highest ever recorded. Days with no heart rate data (lifting sessions today) show a
dash, not 0. Python reference, Swift port and parity test. Weight lifted is left out of the beta: the
app doesn't know the loads actually lifted yet.

**N7. Live on the bench (Now)**
As an athlete lifting with the phone on the bench, I want the live screen to come up by itself, so
I never touch the phone mid-session.
*Done when:* the current Live content opens over the tabs when a set is live, a new lift arrives or
a workout has just finished, closes with a swipe or Done, and the phone stays awake on Today and Live, so transfers keep arriving.

**N8. Settings has my account (Now)**
As a tester, I want my account where I expect it.
*Done when:* the avatar at the top right of Today opens a standard iOS menu, not a full screen: watch status,
upload status, Settings, Sign out. Settings holds Upload now, Delete account, Privacy and For testing ›
Debug tools. Debug is no longer a tab.

**N10. Browse all workouts (Now)**
As an athlete, I want one place for every workout, so I can find one that isn't on today's plan.
*Done when:* the Workouts tab is the library: programs, built-ins, search and my past results of a
workout, with Send to watch. It is the existing Choose, moved to its own tab.

**N11. See my effort over time (Now)**
As an athlete, I want a simple view of how much I've been doing.
*Done when:* Progress shows Effort per day and per week from my results, using only real data, and
says what to do when there is none yet. More can come later.

**N9. Know the watch is there (Now)**
As an athlete, I want to see if the watch is connected without leaving Today.
*Done when:* a small dot on the avatar shows connected or not, the avatar menu says it in words with
the same text as the old chip, and the dot's state is in the avatar's accessibility label.
