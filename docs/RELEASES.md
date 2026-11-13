# Releases: what goes in which build

The plan of record: which feature goes in which build, and the rules. Stories and "done when" live in
`docs/USER_STORIES.md`. The owner decides what goes in a build. **`main` is the truth**: a PR edits
only its own rows, never another chat's; keep one row per line (fewer merge conflicts).

## Now (read this at the stand-up)

Waiting on the owner:
- **Build 15 device test, 13 Nov:** practice, short workout, 200 Hz, settings, Lifting passed. Left:
  GPS run (14 Nov) and the re-check of the Crown-side fix (#27, merged into #24). Battery: later.
  Then #24 out of draft and merged; TestFlight build 15 from `main` goes to the friend testers.

In progress:
- #24 (build 15): `claude/funny-faraday-1adqio`, frozen, device test nearly done.

Blocked:
- Build 16 (W28, W27, W23): **blocked on the merge of #24**. Then `claude/release-16` is cut from `main`.

## Tickets, board and releases (owner, 13 Nov: work like a tech company)

The team process (stand-up, planning, review, retro, the Scrum Master chat): `docs/SCRUM.md`.

- **Tickets are GitHub issues** in this repo: one per story, bug, chore or experiment, with acceptance
  criteria ("done when"). Labels: `story`, `bug`, `chore`, `experiment`, `epic`, `release`,
  `area:workouts`, `area:lifting`, `needs-brief`, `needs-design`. The repo is public: no tester names
  or personal data in issues (tester A, B, ...).
- **Fix version = milestone** (`Build 15`, `Build 16`, `Build 17`): which release a ticket ships in.
  Each release has a `release` ticket with its QA checklist.
- **Board = GitHub Projects** (board view), columns **Backlog -> To Do -> In Progress -> In Review ->
  QA -> Done**. In Review: PR open, CI and code review. QA: merged into the release branch, owner
  testing on a device (UAT). Done: passed QA. PRs say `Closes #N` so the ticket closes when the work
  reaches `main`.
- **Release dashboard** (https://claude.ai/artifact/R1im1djQEebDWBRsYDT1zk, page `docs/roadmap.html`):
  timeline and milestones, the owner's decisions and the stand-up log. Collections `decisions`,
  `standups`, `sprints`, `checks`, `meta/plan` (read first, pin `if_version`, never delete a stand-up
  or decision). Its old `items` collection is replaced by the issues.

## Rules

**Status and definition of done**

| Status | Means |
|---|---|
| `proposed` | an idea, not agreed by the owner |
| `story` | written in USER_STORIES.md, owner agreed |
| `design` | mockups waiting for the owner (anything the athlete sees) |
| `ready` | approved, can be built |
| `building` | claimed: a branch exists (`who` = branch, `claimed` = date) |
| `in PR` | CI green + independent review done + a "not tested" list in the PR |
| `in build N` | build N is on TestFlight, built from `main` |
| `device-tested` | the owner ticked the PR's device checklist (**only the owner sets it**) |
| `with testers` | invites sent for that build |

- **Claiming:** a row with a branch in `who` is claimed. A claim with no commits for 2 days is free
  again. One chat per release branch; never several chats on the same file at once
  (`WorkoutSessionModel.swift`, the PhoneLink files).
- **WIP limit:** one build in `building` at a time. The next build's rows stay `ready` until the
  current build is merged.
- **`main` is protected:** changes only through a PR with CI green (Python tests, BarPathKit tests +
  app builds); no force push, no deletion. Only the owner merges into `main`.
- **Builds come from `main` only.** The commit a TestFlight build is made from gets a git tag
  (`build-15`). (Builds 7-14 came from an unmerged branch; never again.)
- **Release branch (owner, 13 Nov):** each build has one branch cut from `main` (`claude/release-16`;
  build 15 is `claude/funny-faraday-1adqio`). Workers branch from it and open PRs into it; the Scrum Master has each
  reviewed by an independent reviewer and merges it into the build branch when CI is green and the
  review says merge, otherwise the findings go back to the worker. The owner device-tests the build
  branch and merges it into `main`; TestFlight is built from `main`.
- **Build numbers:** `CURRENT_PROJECT_VERSION` in `BarPath/project.yml` (shared file), set once by
  the PR that owns the build (named in the build's heading). Never reuse a number.
- **Freeze:** a build freezes when its PR says so; after that only fixes from the owner's device
  test. Any other change needs the owner's OK and is listed under "Exceptions" in that build.
- **Story ids:** take the next id free on `main` **and** in open PRs. A brief may use provisional
  labels (R1, I1, ...) until the owner approves it.
- **Dates live here only.** Other docs (MVP.md) point to this file.
- **No personal data:** testers are "tester A, B, ..." in the repo and on the board.

## Shipped

| Build | When | What (PRs) |
|---|---|---|
| 1-6 | 29 Oct - 4 Nov | Bar path, deadlift reps, Hyrox workouts ([#1](https://github.com/Slimslim/ML.WorkoutApp/pull/1)); TestFlight, Sign in with Apple, uploads ([#4](https://github.com/Slimslim/ML.WorkoutApp/pull/4)); every-minute auto-advance, time cap, recovery, Free Workout ([#8](https://github.com/Slimslim/ML.WorkoutApp/pull/8)); cloud library W8-W10 ([#9](https://github.com/Slimslim/ML.WorkoutApp/pull/9)); workout cards W11-W14 ([#11](https://github.com/Slimslim/ML.WorkoutApp/pull/11)); beta navigation N1-N11 ([#14](https://github.com/Slimslim/ML.WorkoutApp/pull/14)); fixes ([#16](https://github.com/Slimslim/ML.WorkoutApp/pull/16), [#17](https://github.com/Slimslim/ML.WorkoutApp/pull/17)) |
| 7-14 | 4-10 Nov | Built from `claude/results-report` ([#19](https://github.com/Slimslim/ML.WorkoutApp/pull/19), never merged): results page, avatar menu, version in Settings. Cloud corrections W17 ([#20](https://github.com/Slimslim/ML.WorkoutApp/pull/20)) was merged to `main`; which of builds 7-14 contained it is unknown |

## Build 15: pre-beta (owner: #24, branch `claude/funny-faraday-1adqio`; frozen 11 Nov)

[#24](https://github.com/Slimslim/ML.WorkoutApp/pull/24) is a **draft**; build 15 is not on TestFlight
yet. It contains #19 (builds 7-14), so merging it brings `main` level with what testers run.

| Feature | Story | Status |
|---|---|---|
| A crash does not lose the workout | W24 | in PR; device-tested 10 Nov on an earlier commit |
| Practice workout: asks Health, Motion, Location (then Health again for routes), teaches the Crown | W22 | in PR |
| Max heart rate (age / measured / manual) | W25 | in PR |
| kg or lb, and "About you" in Settings (height, body weight, forearm length; uploaded as `profile`) | W26 | in PR |
| Recording profile, per workout at START: 200 Hz with barbell / DB / KB movements; step-ups, runs, carries, sleds, machines stay 100 Hz (also with a vest). 200 Hz reaches the 50 MB limit at ~87 min after gzip | W21 (part) | in PR |
| GPS for workouts with a run: route to Apple Health only; the upload has distance, speed, accuracy, never coordinates. Watch background location mode added (wrist-down GPS unproven) | W21 (part) | in PR |
| Every recording's header: watch model, watchOS, wrist, crown side, app build, sampleRate, planProfile, gps | - | in PR |
| Compressed uploads (gzip), files too large are not retried forever | fix | in PR |
| Account deletion removes every file; Lifting "Ending..." timeout; analyzer crash fixes; Crown lockout after an automatic advance; personal library rows (`make_row.py --owner`); PRIVACY.md; "Rx Lab" in athlete-facing text; `legacy/` removed | fixes | in PR |

Exceptions after the freeze (owner OK): four device-test fixes; W26 kg / About you; Crown hint on the
Crown's side ([#27](https://github.com/Slimslim/ML.WorkoutApp/pull/27), owner device test 13 Nov).

Who gets it (owner, 13 Nov): after the GPS run, the friend tester group (heart-rate graphs).

## Build 16: tester stability (owner decided 13 Nov)

For the Swiss testers. W28 uploads without opening the app, W27 Tabata timing, W23 banner (mockup
approved 13 Nov). Battery line: moved to a later build (owner, 13 Nov). **No rep counting
on the watch** (owner, 13 Nov: "not yet"): the press / bench lockout rule stays in Python and the
labels. Release branch `claude/release-16`, cut from `main` after #24 merges; one PR per ticket into it
(milestone `Build 16`: #30 W28, #31 W27, #32 W23).

Order: W28 -> W27 -> W23. Dependencies:
- **W28** needs #24's gzip staging and upload manifest; touches both PhoneLink files (#24 added a
  `weightUnit` application-context key). Check on a locked phone: staged gzip copies in Caches are
  readable, and the Supabase session is readable after first unlock.
- **W27** touches `WorkoutSessionModel.clockAdvance`, which #24 changed (checkpoint every 15 s,
  Crown lockout after an automatic advance). Owner, 13 Nov: 8 x (20 s work + 10 s rest) on the clock,
  3-2-1 at the end of each work, 3-2-1 GO at the end of each rest. Also decide what a Crown turn does
  in a clocked workout (today it jumps a round and the clock never gives it back:
  `WorkoutProgress.swift`).
- **W23** needs a rule change before it is built: iOS does not say whether heart-rate read access was
  refused, so the banner follows "the last session received no heart rate" (`lastSessionReceivedHeartRate.v1`,
  written by the practice today; the real workout must write it too). Mockup approved 13 Nov.

Fallback: if W28 is not device-tested in time, the tester guide keeps "open the phone app after the
session". Invites (proposed Fri 20 Nov) need #24 merged by about 14 Nov; otherwise the dates move.

**Hyrox race, Sat 5 Dec (owner's milestone):** the owner races with the app. Proposal for sprint
planning: race on build 16, no risky change to the workout code in the week before.

## Build 17: design review + workout import (owner decided 13 Nov)

The brief `docs/BUILD_16.md` on #24 (to be renamed for build 17): UI/UX design review with the
testers' feedback, "add a workout from a photo or text" (server function, movement table, import
log). Provisional labels R1-R2, I1-I6, M1 until the owner approves the brief. Email sign-up must be
closed before the import ships. Builds 18+ during the beta: fixes only.

## Backlog (after the beta; owner picks at the review)

| Feature | Story | Status | Note |
|---|---|---|---|
| Partitioned workout round by round | W18 | story | |
| Rx / Scaled saved with the result | W19 | story | |
| AMRAP ending on a run scores the distance | W20 | story | |
| Lift pieces in the program, recorded as lifts, one start screen | W21 | story | needs design |
| Recording switches per part of the plan (rates, GPS, rest), one Fitness workout | W21 | story | after lift pieces; `docs/RECORDING_PLAN.md` |
| Strict press and bench reps on the watch, counted at lockout | MVP | ready (Python) | owner, 13 Nov: not yet |
| Automatic movement switching on the watch (phase 1) | - | experiment | switch-v1 must beat the Crown on held-out sessions first (`docs/LABELS.md`) |
| Rep counting in metcons (GHD / sit-ups / press first) | - | experiment | training data in `data/labels/`; flagged reps checked on video |
| Weight per set in EMOMs, transition vs work time | W4, W5 | story | |
| Battery level line in every recording | - | story | owner, 13 Nov: later, if testers report battery issues |
| Library aliases (old results stay linked) + "For Time" cards | - | proposed | from closed #15, branch kept; needs a free story id |
| Strength sets in a workout get bar path / bar speed; Lifting mode merges into the normal recording | W21 | story | owner, 13 Nov: free lifting only records, classify later; Olympic live "last lift" view is a side feature |

## Data and server state (not code)

- Gyms migration run on 11 Nov. Gym `blue-republic`: owner and tester B are members; 18 class rows
  belong to it; 2 training-data rows are private to the owner.
- Email sign-up is still open (accepted for TestFlight); close it before any AI import ships.
- Testers' programs are entered as private rows; gym programming only for gym members.

## Open PRs not in a build

| PR | What | Decision |
|---|---|---|
| [#19](https://github.com/Slimslim/ML.WorkoutApp/pull/19) | Results page, builds 7-14 | close when #24 merges (contained in it) |

Closed 13 Nov (owner asked the Scrum Master to decide; branches kept): #6 (stale screenshots), #7
(class workouts now in the cloud library), #15 (not in builds 15-17; moved to the backlog).
