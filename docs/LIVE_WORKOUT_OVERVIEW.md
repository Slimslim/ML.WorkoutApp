# Live tab after a workout: overview design

> **Status: design proposal (2026-10-28), not implemented.** Implements backlog item
> "Phone Live tab after a workout" (HYROX_PLAN §7). Phone only; no watch changes needed for
> the first build.

**Goal.** When the athlete finishes a workout and picks up the iPhone, the Live tab shows the
result: the score in 2 seconds, then runs, rounds or sets, stations, heart rate, and the splits.

## 1. What the Live tab shows

The Live tab shows **the newest thing that arrived**: a lifting session or a workout result.
"Newest" means the result's `endDate` compared with the lift session's `latestDate`.

| State | Live tab shows |
|---|---|
| No lifts, no workouts | Waiting view: "Start a lift session or a workout on your watch. Results show up here. Keep this app open." |
| Workout result arrived (newest) | **Workout overview**, with a NEW badge for about 10 s after it arrives (same as the hero lift card) |
| Lift arrives after the workout | Lift content as it is today, plus a one-line **"Earlier today: HYROX Solo 1:18:42 ›"** row at the bottom (only for workouts from the last 12 h) |
| Workout arrives after lifting | Overview, plus a one-line "Earlier today: Bench, 6 lifts ›" row at the bottom |
| Workout is running on the watch | No change. The phone gets no live data from a workout yet (the result arrives as a file at the end). |
| Newest item is older than 3 h | Same content. The label changes from "JUST FINISHED" to "LAST WORKOUT" (like "CURRENT/LAST SESSION" today) |
| Result file can't be read | Previous content, plus an amber row "A workout result couldn't be read: see Workouts" |

**Older workouts.** You find them in the Workouts tab list. The detail screen uses **the same
overview view**, with the full split table and the share buttons added at the bottom. There is one
design, used in two places. The "Earlier today" row links to the same detail screen.

## 2. Information hierarchy

**Hero card (the 2-second read).** It shows the workout name, a "JUST FINISHED · 14:05" kicker, the
**score** in large type, one line of context, and three tiles.

| Format | Score (hero number) | Context line | Tiles |
|---|---|---|---|
| For time (HYROX, Partner WOD, Helen) | total time `1:18:42` | "Runs 41:10 · Stations 37:32" or "Time cap 16:00 · 4:12 to spare" | Avg run pace · HR avg · HR max |
| For time, capped or ended early | time + amber "Capped at 16:00" / "Ended in segment 7 of 9" | segments completed | same |
| AMRAP | `4 + 41` (rounds + reps) | "4 rounds + 41 reps in 20:00 · avg round 4:31" | Avg round · HR avg · HR max |
| Every N:00 (`emom`) | `6 / 6 sets` | "Avg work 2:04 · avg rest 0:56" | Fastest set · Slowest set · HR max |

**The sections below the hero card.** A section is shown only when it has data.

1. **Comparison** (one line, if there is a previous result with the same workout `id`):
   "−1:12 vs last time (Oct 21)". Green when faster, secondary colour when slower.
2. **Rounds / Sets** (Helen, AMRAP, Every 3:00). One row per round with its time. The fastest and
   slowest rounds are marked. Footer: "Round 3 was 0:41 slower than round 1."
   - EMOM: a stacked bar per set (work segments + rest) against a 3:00 rule mark. Below it:
     fastest, slowest, and **drift** (last set minus first set). A set whose work runs past 3:00
     is flagged "no rest".
3. **Runs** (any run segments). A per-run pace bar chart (one horizontal bar per run, numbered),
   then total run time, average pace, best and worst run. Below that comes the **compromised
   running** line, for 3 or more runs: "Runs 2–8 averaged 0:39/km slower than run 1." It is hidden
   when runs have different targets *and* no pace (pace is comparable across lengths, time is not).
4. **Stations**. A list with title, time, HR avg/max, and a small share-of-total bar. Footer:
   "Longest: Wall Balls 7:55 (10 % of total)". Repeated movements (AMRAP double unders) are
   grouped: "Double Unders ×9: avg 0:48, best 0:39".
5. **Heart rate**. A per-segment bar chart with the avg as a bar and the max as a tick, coloured
   by segment kind. Footer: "Peak 184 bpm in Wall Balls". HR zones come later (§4).
6. **Splits**. The existing `WorkoutSplitTable`. On Live it is collapsed to the first 4 rows plus
   "Show all 16 splits". On the detail screen it is always open.
7. **Data note** (a small secondary-colour footer): "14 of 16 switches automatic · 1 undo ·
   no step data". This tells the athlete how much to trust the splits.
8. **"Details & share ›"** (Live only), which goes to the detail screen.

**Roxzone note.** The definitions have no transition segments (`SegmentKind.transition` exists
but is unused). In HYROX the time from the station back to the run mat therefore counts as run
time, so the run pace includes the Roxzone. The Runs card shows this as a footer: "Run times
include transitions (Roxzone)". Separate Roxzone splits come later (§5).

**Pace.** Pace = time / **target distance** (e.g. 1 km) when the run has a meters target. The
wrist pedometer is often 5–15 % off, so the measured distance is shown second ("watch 0.94 km").
When a run has no target, pace = time / pedometer distance (the existing
`paceSecondsPerKm`). With neither, no pace is shown, only time.

## 3. Mockups (iPhone portrait, 393 pt; 16 pt margins; cards = `.card()`)

Shared style: page `Theme.pageBackground`; cards with radius 20 on `Theme.cardBackground`. The kicker
is `.caption.bold`, tracking 1.0, in `Theme.accent`. The name is 22 pt heavy rounded. The score is 52 pt heavy
rounded `monospacedDigit` (as `WorkoutHeaderCard`). Tiles are `MetricTile` (26 pt bold rounded). Section
titles are `.headline`. Colours: run is `Theme.workoutRun` (blue), station is `Theme.workoutStation`
(orange), rest is `Color.gray`, HR is `Color.red`, warnings are `Color.orange`. Charts are Swift Charts with
horizontal `BarMark`s, 22–28 pt per row, values in `WorkoutFmt`.

**A. HYROX Solo (for time, 16 segments)**
```
 Live                                ⌚ ● Ready
╭───────────────────────────────────────────╮
│ JUST FINISHED · 14:05              [NEW]  │
│ HYROX Solo                                │
│ 1:18:42                                   │
│ Runs 41:10 · Stations 37:32               │
│ ┌AVG PACE──┐ ┌HR AVG───┐ ┌HR MAX───┐      │
│ │5:09 /km  │ │162 bpm  │ │184 bpm  │      │
│ └──────────┘ └─────────┘ └─────────┘      │
│ −1:12 vs last time (Oct 21)               │
╰───────────────────────────────────────────╯
╭ Runs ─────────────────────────────────────╮
│ 1 ████████████           4:31/km  best    │
│ 2 ██████████████         4:58             │
│ …                                         │
│ 8 ██████████████████     5:48/km  slowest │
│ 8 runs · 41:10 · avg 5:09/km              │
│ Runs 2–8: +0:39/km vs run 1               │
│ Run times include transitions (Roxzone)   │
╰───────────────────────────────────────────╯
╭ Stations ─────────────────────────────────╮
│ SkiErg 1000 m      4:12  ▬▬▬   158/171    │
│ Sled Push 50 m     3:05  ▬▬    170/181    │
│ …                                         │
│ Wall Balls 100     7:55  ▬▬▬▬▬ 172/184    │
│ Longest: Wall Balls 7:55 (10 % of total)  │
╰───────────────────────────────────────────╯
╭ Heart rate per segment ───────────────────╮
│ (16 bars: avg bar, max tick; blue/orange) │
╰───────────────────────────────────────────╯
╭ Splits (first 4 rows)  Show all 16 ›      ╮
  14 of 16 switches automatic · 1 undo
  [ Details & share                    › ]
```

**B. Helen (3 rounds for time, cap 16:00, `roundSize` 3)**
```
╭───────────────────────────────────────────╮
│ JUST FINISHED · 07:12                     │
│ Helen                                     │
│ 11:48                                     │
│ Time cap 16:00 · 4:12 to spare            │
│ [AVG PACE 4:38/km] [HR AVG 165] [MAX 182] │
╰───────────────────────────────────────────╯
╭ Rounds ───────────────────────────────────╮
│      Run 400  KB 21  Pull 12   Round      │
│ R1     1:41    0:52    0:58    3:31 best  │
│ R2     1:52    0:58    1:12    4:02       │
│ R3     2:01    1:04    1:10    4:15 slow  │
│ Round 3 was 0:44 slower than round 1      │
╰───────────────────────────────────────────╯
╭ Runs: 3 × 400 m · 5:34 · avg 4:38/km      ╮
│ 1 ██████████   4:13/km  ·  2 ███ 4:40 …   │
╰───────────────────────────────────────────╯
 Heart rate per segment · Splits · Data note
```
In a round table, a cell is a segment time. The run cell gets a secondary line with the pace when
there is room. If the athlete stopped mid-round, the missing cells show "–" and the
round total shows "partial".

**C. Every 3:00 × 6: Row + Thrusters (`emom`, `intervalSeconds` 180)**
```
╭───────────────────────────────────────────╮
│ JUST FINISHED · 18:20                     │
│ Every 3:00 × 6 · Row + Thrusters          │
│ 6 / 6 sets                                │
│ Avg work 2:04 · avg rest 0:56             │
│ [FASTEST 1:48 #1] [SLOWEST 2:21 #6] [MAX 179]
╰───────────────────────────────────────────╯
╭ Sets (work vs 3:00) ──────────────────────╮
│ 1 ▓▓▓▓▓▓░░░░░░░░░░░░░·········  1:48      │
│ 2 ▓▓▓▓▓▓▓░░░░░░░░░░░░░░·······  1:55      │
│ …                                 ┆3:00   │
│ 6 ▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░···  2:21      │
│ ▓ Row 15 cal  ░ Thrusters 12  · Rest      │
│ Drift +0:33 (set 6 vs set 1)              │
│ Row avg 0:52 · Thrusters avg 1:12         │
╰───────────────────────────────────────────╯
 Heart rate per segment · Splits · Data note
```
The colours are: row in a light tint of `workoutStation`, thrusters in full `workoutStation`, and rest in
gray at 30 % opacity. The rule mark is at 3:00. A set whose work goes past 3:00 gets an orange bar end and
"no rest" in place of its rest time. Rest switches come from the clock, so the data note
counts them separately ("5 rests ended on the clock").

**D. Nightmare AMRAP 20 (`amrap`, cap 20:00, `roundSize` 4)**
```
╭───────────────────────────────────────────╮
│ JUST FINISHED · 19:05                     │
│ Nightmare AMRAP 20                        │
│ 4 + 41                                    │
│ rounds + reps in 20:00                    │
│ [AVG ROUND 4:31] [HR AVG 168] [HR MAX 186]│
│ Stopped in: Alt. DB Snatch (0:24 in)      │
╰───────────────────────────────────────────╯
╭ Rounds ───────────────────────────────────╮
│ 1 ████████████████           4:05  best   │
│ 2 █████████████████          4:22         │
│ 3 ██████████████████         4:41         │
│ 4 ███████████████████        4:58  slow   │
│ 5 ██████▒ partial            1:54         │
╰───────────────────────────────────────────╯
╭ Stations (grouped) ───────────────────────╮
│ Lat. Burpee Over DB ×5   avg 1:31         │
│ Double Unders ×9         avg 0:47 best 0:39
│ Alt. DB Snatch ×5        avg 1:02         │
╰───────────────────────────────────────────╯
```
The reps after "+" are only the **completed** segments of the unfinished round (10 + 31 = 41).
Reps done in the segment where the cap hit are unknown. The hero shows "Stopped in: …" so the
athlete can add them in their head. A later build lets them type the number in (§4).

**Empty and partial data**

| Situation | Handling |
|---|---|
| No HR at all | The HR tiles show "–". The HR section is hidden. The data note says "no heart rate". |
| HR missing for some segments | The bar is missing for those segments. The chart stays. |
| No pedometer | Pace uses the target distance, so no change for HYROX and Helen. Cadence and "watch 0.94 km" are hidden. The note says "no step data". |
| Run without target and without distance | Time only. The run is left out of the average pace. |
| Ended early (`finishDate == nil`, not AMRAP) | Amber "Ended in segment 7 of 16". Stats use completed segments only. The last segment is labelled "partial" and left out of best/worst. |
| Capped for time (Helen past 16:00) | Score "16:00 CAP" and "8 of 9 segments" |
| 1 run or 1 round | No best/worst/drift lines |
| Very short (< 30 s, e.g. a mis-start) | Overview still shown, with no hero tiles. Not hidden. |

## 4. Data contract

### Proposed `BarPathKit/WorkoutSummary.swift` (pure, unit-tested, no SwiftUI)

```swift
public struct WorkoutSummary: Equatable {
    public init(result: WorkoutResult, previous: WorkoutResult? = nil)

    public enum Score: Equatable {
        case time(seconds: Double)                          // forTime, finished
        case capped(capSeconds: Double, segmentsDone: Int)  // forTime, ran into the cap
        case endedEarly(seconds: Double, segmentsDone: Int) // ended before the last segment
        case roundsReps(rounds: Int, reps: Int?, stoppedIn: String?, stoppedAfter: Double?)
        case sets(done: Int, planned: Int)
    }
    public let score: Score
    public let plannedSegments: Int
    public let completedSegments: Int        // see "Completed" below
    public let deltaVsPrevious: Double?      // totalSeconds − previous.totalSeconds (forTime only)

    public let roundSize: Int?               // definition.roundSize ?? inferredRoundSize
    public let rounds: [RoundSummary]        // empty when roundSize == nil
    public let runs: [RunSummary]
    public let runStats: RunStats?           // nil when there are no complete runs
    public let stations: [StationGroup]      // grouped by movement+target, in first-seen order
    public let heartRate: HeartRateSummary
    public let quality: DataQuality

    public static func inferredRoundSize(_ d: WorkoutDefinition) -> Int?
}

public struct RoundSummary: Equatable {
    public let number: Int                   // 1-based
    public let segmentIndices: [Int]
    public let workSeconds: Double           // non-rest segments
    public let restSeconds: Double           // rest segments
    public let totalSeconds: Double          // work + rest
    public let isComplete: Bool
    public let overInterval: Bool            // emom: workSeconds > intervalSeconds
}

public struct RunSummary: Equatable {
    public let number: Int, segmentIndex: Int
    public let seconds: Double
    public let targetMeters: Double?, measuredMeters: Double?
    public let paceSecondsPerKm: Double?     // target first, then measured
    public let paceFromTarget: Bool
    public let heartRateAvg: Double?, heartRateMax: Double?, cadence: Double?
    public let isComplete: Bool
}

public struct RunStats: Equatable {
    public let count: Int, totalSeconds: Double, totalMeters: Double?
    public let avgPace: Double?              // Σ seconds / Σ km over runs with a pace (time-weighted)
    public let best: Int?, worst: Int?       // run numbers (lowest / highest pace)
    public let compromisedDelta: Double?     // mean(pace of runs 2…n) − pace of run 1; n ≥ 3
    public let driftPerRun: Double?          // least-squares slope of pace vs run number, s/km per run
}

public struct StationGroup: Equatable {
    public let title: String, movement: String, count: Int
    public let totalSeconds: Double, avgSeconds: Double, bestSeconds: Double
    public let shareOfTotal: Double          // totalSeconds / result.totalSeconds
    public let segmentIndices: [Int]
}

public struct HeartRateSummary: Equatable {
    public let avg: Double?, max: Double?    // result.heartRateAvg / heartRateMax
    public let peakSegmentIndex: Int?        // segment with the highest heartRateMax
    public let segmentsWithHR: Int
    public let zoneSeconds: [Double]?        // later: needs heartRateSeries + max HR setting
}

public struct DataQuality: Equatable {
    public let manualSwitches: Int           // advance/finish events with source crown|press|button
    public let detectorSwitches: Int         // source .auto, segment ended was not a rest
    public let clockSwitches: Int            // source .auto ending a rest, or the AMRAP cap
    public let undos: Int                    // events of kind .undo or .unfinish
    public let hasHeartRate: Bool, hasPedometer: Bool
}
```

**Formulas (all from `WorkoutResult`)**

- **Completed.** For a finished non-AMRAP result, every segment counts. Otherwise all segments
  but the last one in `segments` count (the last is partial). For an AMRAP, the last segment is
  partial unless the athlete advanced past the last segment of the definition.
- **Capped.** `format == .forTime`, `timeCapSeconds != nil` and `totalSeconds ≥ cap − 1`, or a
  `finish` event with source `.auto` that is not the last definition segment.
- **Rounds.** `roundSize = definition.roundSize ?? inferredRoundSize`. Round k = segments
  `[k·size ..< (k+1)·size]`. The last round may be shorter (Every 3:00 has no final rest).
  `inferredRoundSize` is the smallest p with `2p ≤ n` such that `segments[i]` equals
  `segments[i+p]` (same kind, movement and target) for all `i + p < n`. This gives Helen 3,
  Every 3:00 3 and AMRAP 4. HYROX and Partner WOD 1 get nil, so they need `roundSize`.
- **AMRAP score.** `rounds = completedSegments / size`. `reps` = the sum of `target.value` of
  completed segments in the unfinished round, nil if any of them is not `.reps`. The UI then
  shows "+ 2 segments". `stoppedIn` = the last segment's title, and `stoppedAfter` its duration.
- **EMOM.** For each round: `workSeconds` = Σ non-rest durations and `restSeconds` = the rest duration.
  Fastest and slowest are taken by `workSeconds`. Drift = last complete set − first.
- **Runs.** Segments with `kind == .run`. `targetMeters` = the definition segment's target
  when its unit is `.meters`. Pace = `seconds / (targetMeters/1000)`, else `paceSecondsPerKm`.
  Incomplete runs are listed but left out of `RunStats`.
- **Stations.** `kind == .station` (rests and transitions are excluded), grouped by
  movement + target text.

### Optional model additions (backward compatible)

Swift's synthesized `Codable` decodes a missing optional field as `nil`, so old JSON keeps
working and `version` stays 1. The Python tools ignore unknown keys.

1. **`WorkoutDefinition.roundSize: Int?`** (do now). Library values: HYROX/Half HYROX 2 (a
   "leg" = run + station), Partner WOD 1 2, Helen 3, Every 3:00 3, AMRAP 20 4; nil for Partner
   WOD 2. It is sent inside the definition, so results carry it too. If it is missing, use
   `inferredRoundSize`.
2. **`WorkoutResult.heartRateSeries: [TimedValue]?`** (later). The watch already holds the
   samples (`WorkoutSessionModel.heartRates`). Stored as 5 s means, a 100 min workout adds
   about 1 200 points (≈ 35 KB JSON). This enables an HR-over-time chart with segment bands and HR
   zones. Zones also need a **max HR** phone setting (default: the highest max HR in all stored
   results). Zones are 50–60–70–80–90 % of max HR.
3. **`WorkoutResult.partialReps: Int?`** (later). Entered on the phone for the AMRAP segment the
   cap stopped. It is added to the score. The phone rewrites the stored JSON.

## 5. Scope

**Next build (about 1 day):**
- Kit: `WorkoutSummary` with score, rounds, runs and run stats, station groups, HR summary
  (no zones), data quality, and `deltaVsPrevious`. Add `roundSize` to `WorkoutDefinition` and the
  library. Unit tests for the 5 example workouts (synthetic results) and for ended early, no HR,
  no pedometer, old JSON without `roundSize`, and the golden `quickTest` scenario.
- Phone: `WorkoutOverview` view (hero card, rounds/sets card, runs card, stations card,
  HR per segment chart, collapsible splits, data note). The LiveView newest-item switch, the
  "Earlier today" row and the NEW badge (`WorkoutStore.latestArrivalId`). `WorkoutDetailView`
  reuses `WorkoutOverview` plus the full splits and share. Rest segments are drawn gray in the
  existing chart (today they are orange).

**Later:**
- HR series, HR-over-time chart and zones (watch change plus a max HR setting).
- Entering partial AMRAP reps.
- Roxzone: add `transition` segments to the HYROX definitions (watch flow change), or detect
  transitions from the motion data.
- A personal best per workout, and a trend across attempts ("Helen: 12:30 → 11:48").
- A share image (a summary card as a PNG for Messages or Instagram).
- A live mirror of a running workout on the phone ("Workout in progress: Run 3 of 8").
