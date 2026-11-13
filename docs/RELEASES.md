# Releases: what goes in which build

The plan of record: which feature goes in which build, and the rules. Stories and "done when" live in
`docs/USER_STORIES.md`. The owner decides what goes in a build. **`main` is the truth**: a PR edits
only its own rows, never another chat's; keep one row per line (fewer merge conflicts).

## Now (read this at the stand-up)

Waiting on the owner:
- **Build 15 device test** (#24 test plan; only the crash test is done) -> then #24 out of draft.
- W23 banner mockup: approved, or approve it separately from the practice workout (W22)?
- Old PRs #6, #7, #15, #19: merge or close.

In progress:
- #24 (build 15): `claude/funny-faraday-1adqio`, frozen, waiting on the device test.
- #26 (this plan and the live board): `claude/amazing-fermi-2lev62`.

Blocked:
- Everything in build 16 that touches the watch or upload code (W28, W27, W23, battery): **blocked on
  the owner's device test and the merge of #24**.

## Live board

The team process (stand-up, planning, review, retro, the Scrum Master chat): `docs/SCRUM.md`.

https://claude.ai/artifact/R1im1djQEebDWBRsYDT1zk (page `docs/roadmap.html`). Its shared database
holds the **status**: each feature's status, who has it and "needs review"; the device-test and
release checklists (each tick records who and when); the owner's decisions; the stand-up log. This
file holds the **plan**. A PR that adds, moves or drops a feature changes this file; status moves
on the board, any time.

Chats update the board with `ArtifactData` on that URL. Collections: `items` (`sid, title, area,
build, status, who, claimed, note, review, pr, updatedAt`), `checks` (`group, text, done, at`),
`decisions` (`title, detail, status open|decided, answer`), `standups` (`done, next, blocked, at`),
`sprints`, `meta/plan`. Read first and pin `if_version`; never delete someone's stand-up or
decision. Write when a status changes, a PR opens or merges (`pr`), something needs the owner
(`review: true`, cleared once reviewed), and once at the end of a working session (a stand-up).
Page code changes: edit `docs/roadmap.html` in a PR and republish to the same URL (the data stays).

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
  again. One chat per build branch; never several chats on the same file at once
  (`WorkoutSessionModel.swift`, the PhoneLink files).
- **WIP limit:** one build in `building` at a time. The next build's rows stay `ready` until the
  current build is merged.
- **Builds come from `main` only.** The commit a TestFlight build is made from gets a git tag
  (`build-15`). (Builds 7-14 came from an unmerged branch; never again.)
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
| Device-test fix: practice "Turn the Crown" hint points at the Crown when it is on the left | fix | in PR ([#27](https://github.com/Slimslim/ML.WorkoutApp/pull/27), merged into #24 on 13 Nov) |

Exceptions after the freeze (owner OK): four device-test fixes; W26 kg / About you.

## Build 16: tester stability (owner decided 13 Nov)

W28 uploads without opening the app, W23 banner, W27 Tabata timing, battery line. **No rep counting
on the watch** (owner, 13 Nov: "not yet"): the press / bench lockout rule stays in Python and the
labels. Owner of the build branch: the chat that claims W28 first, after #24 merges.

Order once #24 is merged (one PR each, or one chat owns the build branch): W28 -> W27 -> W23 ->
battery line. Dependencies:
- **W28** needs #24's gzip staging and upload manifest; touches both PhoneLink files (#24 added a
  `weightUnit` application-context key). Check on a locked phone: staged gzip copies in Caches are
  readable, and the Supabase session is readable after first unlock.
- **W27** touches `WorkoutSessionModel.clockAdvance`, which #24 changed (checkpoint every 15 s,
  Crown lockout after an automatic advance).
- **W23** needs a rule change before it is built: iOS does not say whether heart-rate read access was
  refused, so the banner follows "the last session received no heart rate" (`lastSessionReceivedHeartRate.v1`,
  written by the practice today; the real workout must write it too). Mockup approval: ask the owner.
- **Battery line:** `WKInterfaceDevice` battery monitoring on, an event line per minute in the session
  CSV and `batteryStart` in the header (additive keys).

Fallback: if W28 is not device-tested in time, the tester guide keeps "open the phone app after the
session". Invites (proposed Fri 20 Nov) need #24 merged by about 14 Nov; otherwise the dates move.

## Build 17: design review + workout import (owner decided 13 Nov)

The brief `docs/BUILD_17.md`: UI/UX design review with the
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

## Data and server state (not code)

- Gyms migration run on 11 Nov. Gym `blue-republic`: owner and tester B are members; 18 class rows
  belong to it; 2 training-data rows are private to the owner.
- Email sign-up is still open (accepted for TestFlight); close it before any AI import ships.
- Testers' programs are entered as private rows; gym programming only for gym members.

## Open PRs not in a build

| PR | What | Decision needed |
|---|---|---|
| [#6](https://github.com/Slimslim/ML.WorkoutApp/pull/6) | Docs: approved watch design screenshots | merge or close |
| [#7](https://github.com/Slimslim/ML.WorkoutApp/pull/7) | Old class workouts, builds 2-3 | close (superseded) |
| [#15](https://github.com/Slimslim/ML.WorkoutApp/pull/15) | Library aliases keep old results linked; "For Time" cards | merge `main` into it after #24 lands, or close |
| [#19](https://github.com/Slimslim/ML.WorkoutApp/pull/19) | Results page, builds 7-14 | close when #24 merges (contained in it) |
