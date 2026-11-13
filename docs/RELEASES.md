# Releases: what goes in which build

The one list of features by build. **Every chat reads this before starting a feature and updates it
in the same PR** (status, build, PR link). Stories and "done when" live in `docs/USER_STORIES.md`;
this file only says *when* and *where they are*. Owner decides what goes in a build.

## How to use it

- A feature is a story id (W28, N3, L1, ...). No id yet = write the story first.
- Status, in order: `story` -> `design` (mockups waiting for the owner) -> `ready` (approved, can be
  built) -> `building` (branch) -> `in PR` -> `in build N` (on TestFlight) -> `device-tested` (owner,
  checklist in the PR) -> `with testers`.
- A build is frozen when its PR says so: after that only fixes from the owner's device test go in.
- Build numbers: `CURRENT_PROJECT_VERSION` in `BarPath/project.yml` (shared file), set once per
  build by the chat that owns that build's PR. Never reuse a number.
- Story numbers: take the next free id **on `main` and in open PRs** (two chats once both took W24).

## Shipped

| Build | When | What (PRs) |
|---|---|---|
| 1-6 | 29 Oct - 4 Nov | Bar path, deadlift reps, Hyrox workouts ([#1](https://github.com/Slimslim/ML.WorkoutApp/pull/1)); TestFlight, Sign in with Apple, uploads ([#4](https://github.com/Slimslim/ML.WorkoutApp/pull/4)); every-minute auto-advance, time cap, recovery, Free Workout ([#8](https://github.com/Slimslim/ML.WorkoutApp/pull/8)); cloud library W8-W10 ([#9](https://github.com/Slimslim/ML.WorkoutApp/pull/9)); workout cards W11-W14 ([#11](https://github.com/Slimslim/ML.WorkoutApp/pull/11)); beta navigation N1-N11 ([#14](https://github.com/Slimslim/ML.WorkoutApp/pull/14)); fixes ([#16](https://github.com/Slimslim/ML.WorkoutApp/pull/16), [#17](https://github.com/Slimslim/ML.WorkoutApp/pull/17)) |
| 7-14 | 4-10 Nov | Built from `claude/results-report` ([#19](https://github.com/Slimslim/ML.WorkoutApp/pull/19), never merged): new results page, avatar menu, version in Settings; plus cloud corrections W17 ([#20](https://github.com/Slimslim/ML.WorkoutApp/pull/20)) |

## Build 15: pre-beta (frozen 11 Nov, owner device test)

[#24](https://github.com/Slimslim/ML.WorkoutApp/pull/24), draft until the owner's test plan is done.
Merging it brings `main` level with what testers run (it contains #19).

| Feature | Story | Status |
|---|---|---|
| A crash does not lose the workout | W24 | device-tested (10 Nov) |
| Practice workout on the watch | W22 | in build 15, device test pending |
| Max heart rate (age / measured / manual) | W25 | in build 15 |
| Recording profile per workout: 200 Hz with barbell / DB / KB movements | W21 (part) | in build 15 |
| GPS for workouts with a run, route in Apple Health | W21 (part) | in build 15 |
| Compressed uploads (gzip), 50 MB limit handled | fix | in build 15 |
| Account deletion removes every file; Lifting "Ending..." timeout; analyzer crash fixes | fixes | in build 15 |
| Device-test fix: practice "Turn the Crown" hint points at the Crown when it is on the left | fix | in PR (into #24) |

## Build 16: tester build (MVP, `docs/MVP.md`)

Target: owner tests it 18-19 Nov, invites Fri 20 Nov, test 23 Nov - 6 Dec. Starts after build 15 is
merged (most items change the same files). Anything not ready by Tue 17 Nov moves to build 17+.

| Feature | Story | Area | Status | Why in 16 |
|---|---|---|---|---|
| Fixes from the build 15 device test | - | all | waiting on the test | stability first |
| Upload without opening the phone app | W28 | Workouts | story (plan written) | testers end and walk away (2nd tester: Chad reached the cloud 2.5 h late) |
| Heart rate / Motion is off banner | W23 | Workouts + Navigation | design (mockups in `docs/concepts/first-workout.html`, confirm approval) | 2nd tester recorded two workouts with no HR or steps |
| Strict press and bench press reps, counted at lockout | MVP build 1 (L-) | Lifting | ready (Python lockout rule matches 56/56 Tabata presses) | MVP scope; bench checked on a dumbbell bench session first |
| Tabata: timed work parts end by themselves | W27 | Workouts | story | small change; the gym programs Tabatas (10 Nov timer showed 30 s) |

Fallbacks: if W28 is not device-tested in time, the tester guide keeps "open the phone app after
the session"; if bench miscounts, bench ships without rep counting.

## Build 17+: during the test (23 Nov - 6 Dec)

Fixes only (crashes, lost recordings, wrong numbers), one build per fix batch. Library and program
rows are data, not builds: they change any day.

## After the test (review Mon 7 Dec, owner picks)

| Feature | Story | Status | Note |
|---|---|---|---|
| Partitioned workout round by round | W18 | story | |
| Rx / Scaled saved with the result | W19 | story | |
| AMRAP ending on a run scores the distance | W20 | story | |
| Lift pieces in the program, recorded as lifts, one start screen | W21 | story | needs design |
| Recording switches per part of the plan (rates, GPS, rest), one Fitness workout | W21 | story | after lift pieces; `docs/RECORDING_PLAN.md` |
| kg or lb, athlete's size | W26 | story | in #24's stories |
| Automatic movement switching on the watch (phase 1) | - | offline experiment | `docs/LABELS.md`: switch-v1 must beat the Crown on held-out sessions first |
| Rep counting in metcons (GHD / sit-ups / press first) | - | offline experiment | training data in `data/labels/`; flagged reps checked on video |
| Weight per set in EMOMs, transition vs work time | W4, W5 | story | |

## Open PRs not in a build

| PR | What | Decision needed |
|---|---|---|
| [#6](https://github.com/Slimslim/ML.WorkoutApp/pull/6) | Docs: approved watch design screenshots | merge or close |
| [#7](https://github.com/Slimslim/ML.WorkoutApp/pull/7) | Old class workouts, builds 2-3 | close (superseded) |
| [#15](https://github.com/Slimslim/ML.WorkoutApp/pull/15) | Library aliases keep old results linked; "For Time" cards | rebase on #24 or close |
| [#19](https://github.com/Slimslim/ML.WorkoutApp/pull/19) | Results page, builds 7-14 | close when #24 merges (contained in it) |
