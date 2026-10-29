# BarPath — how we work in this repo

BarPath is an Apple Watch + iPhone app: Olympic-lift bar paths, strength rep counting
(velocity-based training) and workout tracking (Hyrox / CrossFit). Several Claude Code
chats work on it in parallel. These rules keep them from stepping on each other.
The repo is public: **never commit videos, video frames, photos or personal data.**

## Branches

- `main` is the app. Nothing reaches it except through a pull request, and the owner
  (Slimslim) builds and installs from `main`.
- One short branch per piece of work (`claude/<area>-<feature>`), merged within a day or
  two. Before starting, and again before opening the PR, merge the latest `main` into
  your branch: `git fetch origin main && git merge origin/main`.
- Never rewrite history on a shared branch (no rebase/force-push of someone else's work).
- Don't put model names or IDs in commits, PRs or code.

## Areas (one chat each)

| Area | Owns |
|---|---|
| Lifting | `BarPath/BarPathKit` analysis (LiftAnalyzer, OnlineLiftDetector, RepCounter, SetTracker), `tools/barpath`, `tools/tests`, watch lifting recorder/screens (`Watch/MotionRecorder.swift`, `SessionModel.swift`, `SessionView.swift`, `StartView.swift`), phone lift results and live views (`iOS/Views/Lift*`, `LiveView.swift` lifting parts, `iOS/Model/Lift*`) |
| Workouts (Hyrox) | `Watch/Workout*.swift`, `iOS/Views/Workout*.swift`, `iOS/Views/Overview/`, `iOS/Workout*.swift`, `iOS/Model/WorkoutFiles.swift`, workout parts of BarPathKit |
| Navigation UI/UX | phone tab bar and top-level layout, watch page structure, shared styling (`iOS/Views/Theme.swift`) — design first, mockups approved by the owner, then one focused PR |

Stay inside your area. **Shared files** — change them only in small, separate commits and
call it out in the PR description so the other chats merge `main` soon after:
`iOS/PhoneLink.swift`, `Watch/PhoneLink.swift`, `iOS/BarPathApp.swift`,
`Watch/BarPathWatchApp.swift`, `BarPathKit/Sources/BarPathKit/Models.swift`,
`BarPath/project.yml`, `CLAUDE.md`, `.github/`.

Phone↔watch messages: the WatchConnectivity application context is one dictionary shared
by everyone. Keep other areas' keys when you update it (today: `type`/`selectWorkout`
payload and `liftSelection`). Add new keys; don't reuse or remove existing ones.

## How a feature gets done

1. **Brief** — what it is for, how it is used in the gym, what "done" means. Owner agrees.
2. **Design** (anything the athlete sees) — mockups, judged against: no scrolling on the
   watch, one signal per state, glanceable mid-set, readable from ~2 m on the phone,
   as few taps as possible. Owner approves before code.
3. **Build** with tests: Python reference first where there is an algorithm
   (`tools/barpath`), Swift port second, parity test between them.
4. **Senior review** — an independent review of the diff (compile errors, logic, edge
   cases, phone↔watch messaging). Fix what it finds.
5. **PR into `main`** — CI must be green.
6. **Device test** by the owner (checklist in the PR), then a gym test where accuracy matters.

Don't push unreviewed or untested work to `main`. Say plainly in the PR what was not
tested (for example: "not run on a device yet").

## Build and test

- No Swift compiler in cloud sessions: write compile-conservative Swift and rely on CI.
- CI (`.github/workflows/ci.yml`) runs on every PR: Python tests, `swift test` for
  BarPathKit, and builds of the iPhone and watch apps (simulator, no signing).
- Locally: `cd BarPath && xcodegen` (the Xcode project is generated and git-ignored; re-run
  after pulling new files or switching branches), then build in Xcode.
- Python: `python3 -m pytest tools/tests -q` (needs numpy, pytest).
- Swift package tests: `cd BarPath/BarPathKit && swift test`.
- Specs and history of decisions: `docs/RECORDER_SPEC.md` (lifting), `docs/WORKOUT_SPEC.md`
  and `docs/HYROX_PLAN.md` (workouts).
