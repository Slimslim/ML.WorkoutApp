# Lifting: rest timer, Crown arms the next set (#148), design note

Status: **design, for the owner's approval. No app code.** Stories L7–L9 in
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

## How it maps to today's code

| Piece | Today | With #148 |
|---|---|---|
| `SessionModel.Phase` | idle / starting / running / paused / ending | unchanged. Rest and Armed are sub-states of `running` (a new `LiftCycle` enum: `armed`, `inSet`, `resting(since:)`), so the HealthKit workout and Change are not touched. |
| `SessionModel.Status` | `.waitingForSet`, `.reps`, `.ready`, `.lifting`, `.saved`, `.walkToBar` … | adds `.resting(since: Date)`; `.saved` banner folds into the Rest screen's top line. |
| `SessionView` | one screen; Change / End buttons on "walk to the bar" / "grip the bar" | main page + End page in a `TabView(.page)`; paging disabled while In set. Rest screen and the Crown arc are new; the arc reuses `CrownArcView` and `CrownAdvanceController` (0.8 turn, lockout) from workouts. |
| Weight at rest | Load picker on the setup screen (Change) | A: a Weight screen reusing `LoadPickerView`'s Crown binding; B: −/+ on Rest using `stepLoad`. Either way `recorder.loadKg` is set for the **next** set only. |
| `MotionRecorder` | always feeds `OnlineLiftDetector` / `SetTracker` while running | keeps reading motion and writing the session CSV the whole time (unchanged). New: `arm(at:)` / `disarm()`. While disarmed, detector and tracker events are dropped; `arm(at:)` resets them and sets a floor so only reps / lifts **starting after the arm time** can count. |
| `SetTracker` (BarPathKit) | floor = last set end + post-roll | adds an "ignore reps starting before t" floor that keeps the sample history, so the set recording's 3 s pre-roll still works when the first rep comes < 3 s after the Crown turn. Python reference + parity test (`tools/barpath/reps.py`) first, per CLAUDE.md. |
| `OnlineLiftDetector` | arms itself when the watch is still | unchanged inside; `MotionRecorder` resets it on `arm` and ignores its events while disarmed. Its 30 s ring buffer keeps filling, so snippets keep their pre-roll. |
| Rest time | not stored | rest = last rep top (or lift end) → Crown turn, stored with the next set's recording as an optional field (new key; old builds ignore it). The phone can show it later (L4). |
| Phone status message | `repCount`, `liftCount`, `phase`, … | adds new keys only (`cycle`, `restStartedAt`); none removed or reused. |

## Why a shake at rest can't become a set

Events from motion before the Crown turn are dropped, and both detectors restart counting only
motion after it. That is a structural guarantee, not a threshold, so it holds for every lift.
What remains: (1) a shake after arming but before the set (same as today); (2) an accidental
0.8-turn Crown turn (sleeve, wrist on the knee) arms; (3) forgetting to turn the Crown means the
set isn't counted. For (3) the Rest screen's cue is the reminder; see open question Q3.

## Risk to recording

- **Low:** the HealthKit workout, the session CSV and per-set uploads are unchanged; only which
  detector events are acted on changes.
- **Medium:** missed sets if the athlete forgets the Crown (Q3). Pre-roll near the arm time
  (handled by keeping history, above). Crown handling must not fight the weight picker
  (variant A gives the Crown to the Weight screen only while it is shown).
- **To test on device:** rest with hand shakes (0 sets), normal sets after a Crown turn (all
  reps counted), a set started < 3 s after the Crown turn (pre-roll), variant A/B weight change
  lands on the next set, End page not reachable mid-set, Crown on the left.

## Open questions for the owner

1. **Weight at rest: A (tap the weight, then the Crown) or B (−/+)?** Recommendation: A.
2. **Armed time-out:** should Armed go back to Rest after, say, 3 min without a set? (Proposal: no,
   keep it simple for the first build.)
3. **Forgotten Crown:** if a full set happens while resting, should the watch buzz "Turn the Crown?"
   Proposal: not in the first build; it would bring back the false-set detection the flow avoids.
4. **Change lift on the End page**, or keep Change only on the setup flow? Proposal: on the End page.
5. **Olympic singles:** a Crown turn before every single. OK, or should Olympic lifts re-arm by
   themselves after a short rest? (The owner's story says all lifts.)

## Not in this build

Rest countdown to a planned rest (L2 later, L6), double-tap to arm, phone UI for rest times.
