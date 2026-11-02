# Rx Lab: usage scenarios catalogue

Written 1 Nov 2026 to test the app structure in proposal v1 (Today · Library · + · Log · Insights, Settings behind the avatar) and the watch app.
**W:** = what the watch must offer · **P:** = what the iPhone must offer.
**Priority:** P1 = must work before HYROX Anaheim (Dec 3-6) and the TestFlight build · P2 = before the App Store · P3 = later.

## Personas
| Code | Who | Trains | Notes |
|---|---|---|---|
| **OWN** | Owner (Selim) | CrossFit class + Hero/benchmarks, strength + Olympic lifting, HYROX doubles/solo, Saturday partner WODs | Series 12 + iPhone, lb, racing in Dec |
| **HYX** | HYROX-only friend | Runs + stations, race sims | Thinks in target splits, ahead/behind |
| **LFT** | Lifter-only friend | Squat/bench/dead, Oly | Cares about loads, %1RM, bar speed, not HR |
| **BEG** | Beginner at a box | Class WODs, always scaled | Doesn't know the jargon (Rx, EMOM, AMRAP) |
| **TST** | TestFlight tester in Switzerland | Mixed | kg, metric pace, German/English, different time zone |
| **PTN** | Partner in doubles/team WOD | Shares the work | May or may not own the app |
| **COA** | Coach (later) | Programs for others | Wants to see athletes' results |

---

## A. First launch, onboarding, permissions
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-01 | OWN/TST install from TestFlight and open the phone app for the first time | Get to a usable state in under 2 min | P: short onboarding: what the app does, watch app check, units, birth year/max HR, body weight; skip possible | P1 |
| S-02 | First launch asks for HealthKit, motion and notification permissions | Understand why each is needed; can decline some | P: permission asks just in time with one-line reason; app still works with HR only or without notifications; Settings shows what's missing | P1 |
| S-03 | Watch app not installed or not paired with this phone | Find out and fix it | P: Settings › Watch shows status + "Install on watch" hint; Today shows a banner, not an empty screen | P1 |
| S-04 | TST in Switzerland: kg, km, 24h clock, comma decimals | Everything in their units from the start | P: units chosen in onboarding (default from locale); every load/pace/distance respects it; W: same | P1 |
| S-05 | BEG opens the app with no history at all | See what to do first, not empty charts | P: empty states for Today/Log/Insights with one action each ("Start a free workout", "Pick a benchmark") | P1 |
| S-06 | Opens the watch app first, phone never opened | Can still train | W: free workout + lift session work without phone setup; results queue until the phone app runs | P1 |
| S-07 | Existing user updates from today's build (Live/Workouts/History/Debug) to the new structure | Keep all past results | P: migration of old result + lift files into the single Log; nothing lost; Debug moved to Settings › Advanced | P1 |
| S-08 | User wants an account / sync to iCloud before trusting the app | Know where data lives | P: Settings › Data explains on-device + iCloud backup status | P2 |

## B. Planning and choosing a workout
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-09 | OWN at home the night before, checks the box's programming | Have tomorrow's WOD ready on the watch | P: + Add (paste/photo) → Confirm → Schedule for tomorrow; Today shows it next morning with Send to watch | P1 |
| S-10 | OWN in the box 5 min before class, whiteboard just revealed | Load the WOD before the warm-up ends | P: + → Photo → confirm in ≤30 s → Send to watch; works on weak gym Wi-Fi (on-device or quick retry) | P1 |
| S-11 | Coach posts the WOD in WhatsApp/Instagram/SugarWOD | Turn the text into a workout | P: paste text + iOS Share Sheet "Add to Rx Lab"; parser handles "21-15-9", "AMRAP 12", "For time, cap 20" | P1 |
| S-12 | Wants to do "Fran" or "Murph" from the library | Find it fast with standard and scaled versions | P: Library › Benchmarks search, preview with Rx/scaled loads, past results and best | P1 |
| S-13 | HYX picks a HYROX format (full sim, half sim, Doubles, run-compromised) | Get the right 8 runs + 8 stations with correct weights per division | P: Library › HYROX formats with division (Open/Pro, M/W, Doubles) setting loads and distances | P1 |
| S-14 | OWN opens Today in the morning | Know what's on and if they're ready | P: Today: scheduled workout, readiness (resting HR/HRV/sleep), last result + Rx note | P2 |
| S-15 | Repeats a class WOD from 3 months ago | Find it and beat it | P: Log row → Do again → preview with past score as target; W: ahead/behind vs last time | P2 |
| S-16 | Doesn't know what to do on an open gym day | Get a suggestion | P: recommendation on Today/Insights ("retest Grace", "weak: long metcon") with one tap to preview | P3 |
| S-17 | Plans the week (3 WODs, 2 lift days, 1 long run) | See and adjust the week | P: Schedule on preview, week strip on Today; simple calendar in Log | P2 |
| S-18 | Wants to favourite workouts they like | Reach them quickly | P: Favourite on preview; Library › My workouts; W: favourites listed after "Today's" | P2 |

## C. Creating and importing (input edge cases)
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-19 | Whiteboard photo is blurry, has 3 tracks (Rx / Scaled / Foundations) and abbreviations (T2B, DU, C2B) | Get the right track, correctly read | P: Confirm screen with each line editable, track choice, movement dictionary; never silently guess | P1 |
| S-20 | Pasted text has a strength part + a metcon + a finisher | Keep it as one gym day with parts | P: parser splits into blocks (Strength / WOD / Finisher); each block becomes a watch segment group | P1 |
| S-21 | Builds a workout from scratch on the phone | Exact control | P: Builder: format (For time / AMRAP / EMOM / Every N:00 / Rounds+rest / Intervals / Lifting / HYROX), movements, reps, loads, cap | P1 |
| S-22 | Friend shares a workout via link/AirDrop | Open it in Rx Lab | P: share link/file opens a preview with "Save" and "Send to watch"; works if friend has no app (web text fallback) | P2 |
| S-23 | Coach message in German/French (TST) | Parse non-English text | P: parser tolerant of common EU terms or graceful fallback to manual edit | P3 |
| S-24 | Imported workout has a movement the app doesn't know ("Devil press burpee over DB") | Still do it | P: unknown movement kept as free text segment; W: shows the text; can map to a known movement later | P1 |
| S-25 | Edits a library benchmark (e.g. Murph without vest, partitioned 20×5-10-15) | Save as own variant, keep link to the original | P: Edit → "Save as my version"; results tagged as variant, not compared as Rx | P2 |

## D. Workout structures the model must express
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-26 | Rx vs scaled choice (95 lb vs 65 lb thrusters, jumping pull-ups) | Record what they actually did | P: Rx/Scaled/custom selector before start and editable after; W: shows the chosen load | P1 |
| S-27 | "This or that" movement (row 500 m or run 400 m; bike or ski) | Pick on the day | P: alternatives in the definition; W: pick at start or at that segment | P2 |
| S-28 | Partner WOD "you go, I go" Saturday, splitting reps freely | Track their own work vs team score | P/W: partner mode: team score + "my turns" segments with Crown; rest while partner works counted as rest | P1 |
| S-29 | HYROX doubles: both run together, stations split | Splits for runs, stations and their share | W: race mode with optional "partner working" toggle per station; P: report shows team time and own effort | P1 |
| S-30 | Time cap reached mid-round | Correct score = rounds + reps | W: cap alarm, partial reps picker (exists); P: score as "CAP + 7 reps" | P1 |
| S-31 | EMOM 12 alternating / Every 2:00 × 6 | Clock drives segments | W: auto segment change on the minute with 3-2-1 haptics; marks failed minutes | P1 |
| S-32 | 5 rounds with 1:00 rest between | Rest counted, not part of work | W: timed rest with countdown (exists); P: work vs rest split in report | P1 |
| S-33 | Strength: 5×5 back squat at 75% 1RM | See the actual load in lb/kg | P: % of stored 1RM resolved to load, rounded to plates; W: shows load per set | P1 |
| S-34 | Complex: 1 power clean + 1 hang clean + 1 jerk, build to heavy | Log each attempt load and make/miss | W: lift session with complex type, load per set, make/miss; bar path for the set | P2 |
| S-35 | Gym day: warm-up, snatch work, then a 12-min AMRAP, then cool-down | One session, several parts, one log entry | W: chained blocks; P: Log shows one day with lift report + WOD report inside | P1 |
| S-36 | Warm-up and cool-down shouldn't pollute the score/HR stats | Exclude them | W: warm-up/cool-down segments marked; P: excluded from score, shown in HR chart | P2 |
| S-37 | Tabata / intervals (20 on / 10 off ×8) with "lowest round" score | Correct score type | Model supports score types: time, rounds+reps, reps, load, lowest/total, distance, calories | P2 |
| S-38 | Chipper with 10 movements and 300 reps | Know where they are | W: big current segment, next segment preview, progress border | P1 |
| S-39 | Buy-in / buy-out runs ("1 mile, then...") | Distance segment measured | W: run segment with pace + distance via pedometer/GPS; auto end at distance optional | P1 |

## E. During the workout (watch)
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-40 | Mid-WOD, sweaty hands, chalk, phone in the bag | Advance segments without looking | W: Crown turn = next, big targets, haptic confirm; no taps required | P1 |
| S-41 | Starts a workout that was sent from the phone | Find it immediately | W: first screen = "Today's workout" with START; others below | P1 |
| S-42 | Unknown/open workout, started on the watch only (coach shouts it) | Measure it and describe later | W: "Free workout" start: timer + HR + Crown laps; P: name/define it afterwards and re-split | P1 |
| S-43 | Wants HR zone and time but not a busy screen | Glanceable info | W: one main metric + HR; option to choose the metric | P1 |
| S-44 | Between lifting sets | See rest time, next set, HR recovery | W: rest timer starting automatically after set; next load shown | P2 |
| S-45 | Pauses WOD to fix a broken jump rope / help someone | Pause without breaking splits | W: pause (side button or menu), paused time shown separately | P2 |
| S-46 | Racing the clock vs own target or previous best | Know if ahead/behind | W: ahead/behind delta per segment against target splits or last attempt | P1 |
| S-47 | Finishes; done screen with 3-min recovery | See score, HR recovery, then leave | W: done screen, recovery clock (exists), can end early; result saved even if left mid-recovery | P1 |

## F. Lifting persona specifics
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-48 | LFT does squat/bench/dead, no Oly | App not cluttered with WOD stuff | Library/Insights filterable to lifting; Today shows lift day; W: lift session first if preferred | P2 |
| S-49 | OWN does snatch singles to a heavy | Bar path and speed per lift right after | W: auto lift detection, load entry; P: lift report per rep with path, velocity, confidence | P1 |
| S-50 | Wants an estimated 1RM from bar speed | Know daily max without testing | P: Lift page: speed by load, estimated max, trend | P2 |
| S-51 | Changes load between sets with the Crown, wrong by 10 lb | Correct easily | W: load stepper with plate increments in units; P: edit load per set after | P1 |

## G. Mistakes and failures
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-52 | Turned the Crown too far, skipped a segment | Undo without stopping | W: back = undo (exists), visible confirmation of current segment | P1 |
| S-53 | Forgot to tap START; realised after 2 rounds | Recover the data | W: "start N min ago" option; P: Fix splits can add the missing beginning from HR data | P2 |
| S-54 | Forgot to stop; watch ran 25 min extra | Trim the end | W: auto prompt when HR drops/no motion; P: trim end in Fix splits | P1 |
| S-55 | Watch battery dies mid-race | Keep what was recorded | W: periodic autosave/checkpoint; P: partial result with "incomplete" flag + manual completion | P1 |
| S-56 | Phone not nearby (in locker / at home) during workout | Workout still works and syncs later | W: fully standalone; results queued and transferred when phone app is reachable, with a visible "waiting to sync" | P1 |
| S-57 | Results don't arrive on phone (WatchConnectivity stuck) | Get them over without Debug | P: sync status in Settings › Watch + "Sync now"; W: pending count; no need to open Debug | P1 |
| S-58 | Did the workout with another device (Whoop, Garmin, other Apple Watch app) | Still have it in the log | P: import from Apple Health workouts (time + HR), attach a definition | P2 |
| S-59 | Accidentally started a second workout / duplicate result | Remove duplicate | P: delete/merge result in Log with confirm; undo | P1 |
| S-60 | Wrong workout started (yesterday's sent one) | Switch without losing time | W: "switch workout" within first minute keeps clock; P: apply other definition after (exists: apply newer definition) | P2 |
| S-61 | Crown misreads under chalk/gloves | Alternative input | W: double tap gesture / screen tap as next | P2 |

## H. After the workout: fixing and logging
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-62 | Splits slightly off (pressed late) | Move boundaries | P: Fix splits (exists) reachable from report; restore original | P1 |
| S-63 | Didn't wear the watch (charging) | Log the score manually | P: + → Log a result: pick/define workout, score, Rx/scaled, notes; no HR shown | P1 |
| S-64 | Adds notes: "shoulder tight", "no-repped 3 wall balls" | Remember context | P: notes + feel (RPE 1-10) on report; W: quick RPE after done | P2 |
| S-65 | Changes Rx→Scaled after the fact (coach said ring rows count as scaled) | Correct comparisons | P: edit variant on report; PRs/benchmarks recalculated | P1 |
| S-66 | Result belongs to wrong date (midnight workout, time zone travel) | Correct date | P: edit date/time; time zones stored | P2 |

## I. Reviewing and insights
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-67 | Right after class, still at the box | Quick look: score, PR?, HR | P: Today/Log top shows newest result with score, delta vs previous, PR badge | P1 |
| S-68 | At home that evening | Full story: splits, HR segments, recovery | P: Workout report (exists) | P1 |
| S-69 | A week later, wants a specific WOD | Find it | P: Log search by name/movement, filters (Races/WODs/Lifts), calendar | P1 |
| S-70 | Compares 3 attempts of Fran over a year | See progress per split | P: compare view: score trend + split-by-split overlay | P2 |
| S-71 | Hits a new PR (lift or benchmark) | Notice and celebrate | P: PR badge on report + Insights › Benchmarks & PRs; W: PR haptic on done screen | P2 |
| S-72 | Benchmark retest every 8-12 weeks | Be reminded and compare | P: "retest due" on Insights/Today with last result | P3 |
| S-73 | Wants btwb-style Fitness Level (0-100, 8 categories) | Single number + weak areas | P: Insights › Fitness level with category breakdown, imbalance notes, method explained | P3 |
| S-74 | Pre-workout "how hard is this for me" (workout level) | Pick scaling | P: preview shows predicted level/time based on history | P3 |
| S-75 | Recommendations ("pace runs 5 s slower in round 1") | Actionable second opinion | P: Rx note per report + Insights › Recommendations linking evidence | P2 |
| S-76 | Engine trend: resting HR, recovery after WODs | See fitness change | P: Insights › Engine with recovery trend | P2 |

## J. HYROX race prep and race day
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-77 | Sets target splits for Anaheim from sims | Have a race plan | P: target splits per run/station/roxzone; prefill from best sim; W: show targets | P1 |
| S-78 | Race day in a hall: no GPS, phone in bag check | Accurate run splits and stations | W: standalone race mode, run via pedometer (calibrated), Crown laps at each mat, no phone dependency | P1 |
| S-79 | Mid-race, glances once per lap | Ahead/behind vs target, total | W: big delta (+/-) and total clock; colour for ahead/behind | P1 |
| S-80 | Roxzone transitions | Measured separately | W: roxzone as segment between run and station (Crown) or auto; P: roxzone total in report | P1 |
| S-81 | After the race: compare to official results | Reconcile times | P: enter official splits/time; show diff to watch splits | P2 |
| S-82 | Run calibration before the race | Pace accurate indoors | P/W: calibration run (known distance) from Settings or Insights › Running | P1 |
| S-83 | Taper/race week, injured shoulder or deload | Lower loads, no false "decline" | P: mark result/week as deload/injury; excluded from trends; scale workouts | P3 |

## K. Sharing, export, privacy
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-84 | Share a result to Instagram story | Nice image | P: share card (score, splits, HR) image | P2 |
| S-85 | Send result to coach/friend for feedback | Readable summary | P: share as image/text + JSON/CSV (exists) | P1 |
| S-86 | Write workouts to Apple Health / Activity rings | Rings close, Health has it | W/P: HKWorkout saved with right activity type (HIIT, strength, run), HR, calories | P1 |
| S-87 | Export to Strava | Social feed | P: Strava connect (or via Health) | P3 |
| S-88 | Keep body weight / HR private when sharing | Control what's in the share | P: share options hide HR/body data; no data leaves device without action | P2 |
| S-89 | Coach views athletes' results | Team view | Separate coach surface (maybe separate app), invites | P3 |
| S-90 | Partner (PTN) wants the shared team result | Both have it | P: share result to partner who imports it as their own entry | P3 |

## L. Settings, devices and data
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-91 | Sets max HR from a test or wants it auto-estimated | Correct zones | P: Settings › Profile max HR (manual or from data), resting HR | P1 |
| S-92 | Switches lb ↔ kg (TST, or a kg-plate gym when travelling) | Loads convert; plates rounding correct | P/W: unit setting, stored canonical, display converts; per-gym option later | P1 |
| S-93 | Drop-in at a gym while travelling, new time zone | Train and log normally | Works offline; time zone handled; class WOD import from that gym | P2 |
| S-94 | Gets a new watch / has two watches | Keep history, results from both | Results identified by device; no duplicates; pairing change doesn't lose queue | P2 |
| S-95 | Gets a new iPhone | Restore everything | iCloud backup/restore of the database | P2 |
| S-96 | Phone storage fills / app deleted by mistake | No data loss | Export all (ZIP/CSV) + iCloud; warn before deletion of data | P2 |
| S-97 | TestFlight tester reports a bug | Send logs easily | P: Settings › Advanced › Send diagnostics (raw files, sync log) | P1 |
| S-98 | Wants to delete all data / one result | Privacy control | P: delete result; Settings › Data › delete all | P2 |

## M. Beginner and social context
| ID | Situation | Goal | App must offer | Pri |
|---|---|---|---|---|
| S-99 | BEG doesn't know what AMRAP/EMOM/Rx means | Understand without leaving | P: inline glossary on preview; plain-language format descriptions | P2 |
| S-100 | BEG always scaled; seeing "not Rx" everywhere is discouraging | Feel progress | P: progress shown against own scaled history; scaled PRs | P2 |

---

## Counts
P1: 56 · P2: 35 · P3: 9 (100 scenarios). Most P1 weight sits in groups D, E, G, J: the watch must work standalone, recover from mistakes and survive race day.

## Structure checks these scenarios raise for proposal v1
- **Watch first screen** must be "Today's workout" then Free workout / Lift session (S-06, S-41, S-42), not two unlabelled pages.
- **Sync status** must be user-facing, not only in Debug (S-56, S-57, S-97).
- **+ Add** needs a fifth way in: "Log a result" without the watch (S-63), and Share Sheet entry (S-11).
- **Gym day** (S-20, S-35) means a Log entry can hold several reports; Log rows must not be "one file = one row".
- **Variant/scaling** is a property of a result, not only of a workout (S-26, S-65, S-25), and PRs depend on it.
- **Partner/doubles** (S-28, S-29) needs a model decision before Saturday WODs and the Doubles race.
