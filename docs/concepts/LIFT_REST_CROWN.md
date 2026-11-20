# Lifting: rest timer, Crown arms the next set (#148), design note

Status: **approved 20 Nov (#150), built for 0.17.2.** Weight at rest: **variant A**. Stories L7–L9 in
`docs/USER_STORIES.md`; mockups in `docs/concepts/lift-rest-crown.html`. Replaces the
detector-only fix for #147 (shaking the hands at rest counted as a 1-rep set).

## States (watch, one lifting block)

| State | Detection | Screen | Leaves on |
|---|---|---|---|
| **Armed** | on | today's "Grip the bar" (deadlift) / "Walk to the bar" → READY (Olympic lifts); footer: set number, rest just taken | first rep / lift start → In set |
| **In set** | on | today's live reps (deadlift) / LIFTING (Olympic) | set ends (deadlift: 6 s without a rep; Olympic: lift ended) → Rest |
| **Rest** | **off** | REST counting up, weight, last set's reps, Crown cue | Crown turn (0.8 turn) → Armed; swipe left → End page |
| **Weight** (variant A only) | off | the weight, Crown changes it | Done or 3 s idle → Rest |
| **End page** | unchanged from the state it was opened in | End, Change lift | End → today's confirm; Change → today's Change; 5 s → back |

The first set after Start (and after Change → Continue) is **Armed** straight away: the owner
starts the watch at the bar. Swiping is off during In set.

## How it is built (0.17.2)

| Piece | Before | Now |
|---|---|---|
| `LiftCycle` (BarPathKit, new; reference `tools/barpath/lift_cycle.py`, fixture `lift_cycle_cases.json`) | — | armed / inSet / resting; `arm(at:)` only from resting; `listeningFrom` = arm time, +∞ while resting; `lastRest`; `canShowEndPage`. Pure, tested. |
| `SetTracker.armedFrom` (BarPathKit + `reps.py`, fixture `rest_arm_cases.json`) | — | reps that start before it are never counted. The sample history is kept, so the set recording still gets its 3 s pre-roll from before the Crown turn. |
| `MotionRecorder` | always fed the detector / tracker | owns the `LiftCycle`. CSV and ring buffers are fed exactly as before. The lift detector is fed only while listening and only samples from the arm time; the set tracker always gets samples but counts reps only from `armedFrom`. `armNextSet()` (Crown) arms and resets the lift detector. `liftStarted` / first rep → in set; `liftEnded` / `setEnded` → resting since the lift's end / last rep's top. |
| `SessionModel` | Status without rest | `cycleState`, `restStartDate` (motion clock → wall clock), `lastRestSeconds`, `armNextSet()` (start haptic), `canShowEndPage`, `Status.resting(since:)`. Phase and the HealthKit workout unchanged. |
| `SessionView` | one page, Change / End buttons on "walk to the bar" | `TabView(.page)`: main page + End page (End, Change lift; only when not in a set; back to the main page after 5 s). Rest screen: top line (✓ Set N · reps / Lift N saved), REST timer, weight button, Crown cue on the Crown's side, the workouts' Crown controller and arc (0.8 turn). Weight sheet (variant A): Crown changes the weight, Done or 3 s idle. |
| Recording | — | **unchanged**: HealthKit workout, session CSV, per-set / per-lift uploads and their format. The rest time is not stored yet (L4). No new phone↔watch keys. |

## Why a shake at rest can't become a set

Events from motion before the Crown turn are dropped, and both detectors restart counting only
motion after it. That is a structural guarantee, not a threshold, so it holds for every lift.
What remains: (1) a shake after arming but before the set (same as today, for at most the 3 min
armed time-out); (2) an accidental 0.8-turn Crown turn (sleeve, wrist on the knee) arms; (3)
forgetting to turn the Crown means the set isn't counted (no reminder, by the owner's choice; the
Rest screen's Crown cue is the only prompt).

## Risk to recording

- **Low:** the HealthKit workout, the session CSV and per-set uploads are unchanged; only which
  detector events are acted on changes.
- **Medium:** missed sets if the athlete forgets the Crown (Q3). Pre-roll near the arm time
  (handled by keeping history, above). Crown handling must not fight the weight picker
  (variant A gives the Crown to the Weight screen only while it is shown).
- **To test on device:** rest with hand shakes (0 sets), normal sets after a Crown turn (all
  reps counted), a set started < 3 s after the Crown turn (pre-roll), variant A/B weight change
  lands on the next set, End page not reachable mid-set, Crown on the left.

## Decisions (20 Nov, #150)

1. Weight at rest: **variant A** (tap the weight, then the Crown). Owner's choice.
2. Armed time-out: **yes, 3 min** (owner). Armed with no set → back to Rest, the rest counting on from
   the last set; not while a rep / lift is under way. `LiftCycle.armedTimeout`.
3. Forgotten Crown: **no reminder** (owner correction, 20 Nov). During rest the detector is simply
   ignored: no buzz, no prompt.
4. Change lift: **on the End page** (owner OK).
5. Olympic lifts: **a Crown turn before every single** too (owner).

## Not in this build

Rest countdown to a planned rest (L2 later, L6), double-tap to arm, phone UI for rest times.
