# Workout mode v1 (Hyrox and partner WODs): shared spec

Status: the contract for B1 (manual segments with full recording). Written 2026-10-28.
Goal for **Sat Oct 31**: the athlete runs the two partner workouts with the watch, advances
segments by turning the Digital Crown, and gets a split table on the phone plus a full motion
recording for detector work. Automatic switching (B2) comes later and must not need format
changes.

Units: seconds, meters, beats per minute, steps. Times in the model are **seconds since 1970**
(`Date().timeIntervalSince1970`), as `Double`.

## 1. Files and ownership

| Area | Files | Notes |
|---|---|---|
| Kit (pure Swift) | `BarPathKit/Sources/BarPathKit/Workout*.swift`, `Tests/BarPathKitTests/Workout*Tests.swift` | No Apple framework imports beyond Foundation |
| Python mirror | `tools/barpath/workout.py`, `tools/tests/test_workout.py`, `tools/workout_report.py` | Same logic, line for line |
| Watch | new `Watch/Workout*.swift`; small edits to `BarPathWatchApp.swift` (RootView), `WorkoutManager.swift`, `DebugCSVWriter.swift`, `PhoneLink.swift` | Lifting files otherwise untouched |
| Phone | new `iOS/Workout*.swift`, `iOS/Views/Workout*.swift`; small edits to `iOS/PhoneLink.swift`, `iOS/BarPathApp.swift` (tab) | |

## 2. Kit API (exact names)

```swift
public enum SegmentKind: String, Codable, CaseIterable { case run, station, transition, rest }

public enum TargetUnit: String, Codable { case meters, reps, calories, seconds }

public struct SegmentTarget: Codable, Equatable {
    public var value: Double
    public var unit: TargetUnit
    public init(_ value: Double, _ unit: TargetUnit)
    /// "1000 m", "100 reps", "20 cal", "2:00"; whole numbers without decimals.
    public var text: String
}

public struct WorkoutSegment: Codable, Equatable {
    public var kind: SegmentKind
    public var movement: String        // movement id, e.g. "run", "wallBalls" (see Movement)
    public var name: String            // display name, e.g. "Wall Balls"
    public var target: SegmentTarget?
    public init(kind: SegmentKind, movement: String, name: String, target: SegmentTarget?)
    /// Short title for the watch: "Run 800 m", "Wall Balls 100", "SkiErg 1000 m".
    public var title: String
}

/// Known movement ids and names. Strings, so definitions can contain movements this build
/// doesn't know yet (pasted workouts later).
public enum Movement {
    public static let run = "run"
    public static let skiErg = "skiErg", sledPush = "sledPush", sledPull = "sledPull",
                      burpeeBroadJumps = "burpeeBroadJumps", row = "row",
                      farmersCarry = "farmersCarry", sandbagLunges = "sandbagLunges",
                      wallBalls = "wallBalls", dumbbellWalkingLunges = "dumbbellWalkingLunges",
                      burpees = "burpees", medBallBoxStepOvers = "medBallBoxStepOvers",
                      devilPress = "devilPress", dumbbellOverShoulder = "dumbbellOverShoulder",
                      airSquats = "airSquats"
    public static func displayName(_ id: String) -> String   // falls back to the id
}

public enum WorkoutFormat: String, Codable { case forTime, amrap, emom }   // v1 uses forTime
public enum TeamFormat: String, Codable { case solo, doubles, team }

public struct WorkoutDefinition: Codable, Equatable, Identifiable {
    public var id: String                  // stable, e.g. "hyrox.solo"
    public var name: String                // "HYROX Solo"
    public var shortName: String           // ≤ 12 chars for a watch tile: "Hyrox Solo"
    public var format: WorkoutFormat
    public var team: TeamFormat
    public var timeCapSeconds: Double?
    /// HKWorkoutActivityType name used by the watch: "mixedCardio", "crossTraining",
    /// "functionalStrengthTraining", "highIntensityIntervalTraining", "running".
    public var healthKitActivity: String
    public var segments: [WorkoutSegment]
    public var intervalSeconds: Double?   // optional: "every N:00" sets. Every segment of a set
                                          // ends on the next interval boundary (2026-11-03, W1/W2):
                                          // a Crown turn after the reps starts the rest; without
                                          // it the clock jumps to the next set (rest recorded 0 s).
                                          // WorkoutProgress.autoAdvanceTime / autoAdvance(at:).
    public var roundSize: Int?            // optional (v2): segments per round/set incl. rest
    public init(id:name:shortName:format:team:timeCapSeconds:healthKitActivity:segments:
                intervalSeconds: = nil, roundSize: = nil)
    public var runCount: Int
    public var stationCount: Int
}

public enum WorkoutLibrary {
    public static let hyroxSolo: WorkoutDefinition
    public static let hyroxDoubles: WorkoutDefinition
    public static let halfHyrox: WorkoutDefinition      // 8 × (500 m + half station)
    public static let partnerWod1: WorkoutDefinition    // Sat Oct 31, part 1
    public static let partnerWod2: WorkoutDefinition    // Sat Oct 31, part 2
    public static let quickTest: WorkoutDefinition      // 4 segments, for testing at home
    /// Exactly 9, in this order (fills the watch's 3×3 picker): hyroxSolo, hyroxDoubles,
    /// halfHyrox, partnerWod1, partnerWod2, quickTest, helen, rowThrusters, amrap20.
    public static let all: [WorkoutDefinition]
    public static func definition(id: String) -> WorkoutDefinition?
}
```

### Library contents

- **hyroxSolo** ("HYROX Solo", short "Hyrox Solo", team solo, activity "mixedCardio"):
  8 × [Run 1000 m, station], with stations in order: SkiErg 1000 m, Sled Push 50 m, Sled
  Pull 50 m, Burpee Broad Jumps 80 m, Row 1000 m, Farmers Carry 200 m, Sandbag Lunges 100 m,
  Wall Balls 100 reps. 16 segments.
- **hyroxDoubles** ("HYROX Doubles", "Hyrox Dbl", doubles): same segments.
- **halfHyrox** ("Half HYROX", "Half Hyrox", solo): 8 × [Run 500 m, half station]: SkiErg
  500 m, Sled Push 25 m, Sled Pull 25 m, Burpee Broad Jumps 40 m, Row 500 m, Farmers Carry
  100 m, Sandbag Lunges 50 m, Wall Balls 50 reps.
- **partnerWod1** ("Partner WOD 1", "WOD 1", doubles, "crossTraining"): Run 1000 m, Wall
  Balls 100, Run 800 m, DB Walking Lunges 80, Run 600 m, Burpees 60, Run 400 m, Med Ball Box
  Step-Overs 40, Run 200 m, Devil Press 20. 10 segments.
- **partnerWod2** ("Partner WOD 2", "WOD 2", doubles, "crossTraining"): SkiErg 1000 m, Sled
  Push 40 m, Farmers Carry 100 m, DB Over-Shoulder 40 reps, SkiErg 1000 m. 5 segments, all
  stations.
- **quickTest** ("Quick Test", "Test", solo, "crossTraining"): Run 200 m, Air Squats 20,
  Run 200 m, Burpees 10.

**Roxzone (decided 2026-10-28):** not a separate segment in v1. Transition time counts in the
*run* (the athlete advances when the station work starts and when the station work ends).
`SegmentKind.transition` exists so it can be split out later.

### Progress state machine

```swift
public enum AdvanceSource: String, Codable { case crown, press, button, auto }

public enum WorkoutEventKind: String, Codable { case start, advance, undo, finish, unfinish, end }

public struct WorkoutEvent: Codable, Equatable {
    public var t: Double                  // seconds since 1970
    public var kind: WorkoutEventKind
    public var segmentIndex: Int          // current segment index AFTER the event
    public var source: AdvanceSource?     // advance/finish/undo only
}

public struct WorkoutProgress: Codable, Equatable {
    public let definition: WorkoutDefinition
    public private(set) var segmentStarts: [Double]   // start time of segments 0...currentIndex
    public private(set) var finishTime: Double?
    public private(set) var events: [WorkoutEvent]
    public init(definition: WorkoutDefinition)

    public var isStarted: Bool            // segmentStarts non-empty
    public var isFinished: Bool           // finishTime != nil
    public var currentIndex: Int          // segmentStarts.count - 1 (0 before start)
    public var currentSegment: WorkoutSegment?   // nil before start
    public var nextSegment: WorkoutSegment?      // nil on the last segment or when finished
    public var startTime: Double?

    public mutating func start(at t: Double)                         // no-op if started
    /// Moves to the next segment; on the last segment it finishes (finishTime = t, event
    /// .finish). Returns false if not started, already finished, or t < current start.
    @discardableResult public mutating func advance(at t: Double, source: AdvanceSource) -> Bool
    /// Finished → unfinish (finishTime = nil, event .unfinish). Otherwise drops the last
    /// segment start (back to the previous segment, which keeps its original start time).
    /// Returns false on segment 0 or before start.
    @discardableResult public mutating func undo(at t: Double, source: AdvanceSource) -> Bool
    public mutating func recordEnd(at t: Double)                      // appends .end only

    public func segmentElapsed(now: Double) -> Double     // 0 before start; frozen when finished
    public func totalElapsed(now: Double) -> Double       // frozen at finishTime
    /// Completed segments plus the current one (ended at `now`, or at finishTime).
    public func splits(now: Double) -> [SegmentSplit]
}

public struct SegmentSplit: Codable, Equatable {
    public var index: Int
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
}
```

### Results and stats

```swift
public struct TimedValue: Codable, Equatable { public var t: Double; public var value: Double }
/// Cumulative since the workout start (CMPedometer semantics).
public struct PedometerSample: Codable, Equatable {
    public var t: Double; public var steps: Double; public var distance: Double?
}

public struct SegmentResult: Codable, Equatable {
    public var index: Int
    public var kind: SegmentKind
    public var movement: String
    public var title: String
    public var start: Double
    public var end: Double
    public var duration: Double
    public var heartRateAvg: Double?      // mean of HR samples with start ≤ t < end
    public var heartRateMax: Double?
    public var steps: Double?             // cumulative pedometer interpolated at end − at start
    public var distance: Double?          // same, meters (nil if the pedometer gave none)
    public var cadence: Double?           // steps per minute = steps / duration × 60
    public var paceSecondsPerKm: Double?  // runs only: duration / (distance / 1000), distance > 50 m
    public var heartRateMin: Double?      // v2: lowest HR sample with start ≤ t < end
}

/// v2. bpm[k] covers [start + k·interval, start + (k+1)·interval); null = no reading.
/// make(): mean of the samples in the bucket; else interpolate the nearest samples before/after
/// the centre that are within maxGap (15 s), or carry the one that is; else null. 0.1 bpm.
public struct HeartRateSeries: Codable, Equatable {
    public var start: Double; public var interval: Double; public var bpm: [Double?]
    public static func make(samples: [TimedValue], start: Double, end: Double,
                            interval: Double = 5, maxGap: Double = 15) -> HeartRateSeries
}

public enum SplitStats {
    /// Pedometer interpolation: linear between samples; before the first sample → linear from
    /// (startTime, 0); after the last → last value. Nil stats when there is no data.
    public static func compute(progress: WorkoutProgress, now: Double,
                               heartRates: [TimedValue],
                               pedometer: [PedometerSample]) -> [SegmentResult]
}

public struct WorkoutResult: Codable, Equatable, Identifiable {
    public var version: Int               // 2 (WorkoutResult.currentVersion); 1 still decodes
    public var id: UUID
    public var definition: WorkoutDefinition
    public var startDate: Date
    public var finishDate: Date?          // last segment completed
    public var endDate: Date              // session ended
    public var totalSeconds: Double       // finish − start, or end − start if not finished
    public var segments: [SegmentResult]
    public var events: [WorkoutEvent]
    public var heartRateAvg: Double?
    public var heartRateMax: Double?
    public var recordingFileName: String? // "session-<id>.csv" when Data mode was on
    public var heartRateSeries: HeartRateSeries? // v2, 5 s: start → End (since 2026-11-01; §6)
    public init(...)                      // memberwise
    public func encoded() throws -> Data  // pretty JSON, dates via LiftRecording.makeEncoder()
    public static func decode(from data: Data) throws -> WorkoutResult
    public var runSeconds: Double         // sum of run segments
    public var stationSeconds: Double     // sum of non-run segments
}
```

### Golden test scenario (Swift and Python must agree)

`quickTest`, start at t = 1000. Advance (crown) at 1060, 1100; undo (button) at 1105; advance
at 1110, 1170, 1200 (the last one finishes).
- Splits: [1000–1060, 1060–1110, 1110–1170, 1170–1200], durations 60, 50, 60, 30; total 200.
- Events: start, advance, advance, undo, advance, advance, finish (7), with `segmentIndex`
  0,1,2,1,2,3,3.
- HR samples every 10 s from 1000 to 1200 with value = 100 + (t − 1000)/10 → segment 0 avg
  102.5 (samples 1000…1050), max 105.
- Pedometer: (1030, 90, 100), (1060, 180, 200), (1200, 400, 500). Segment 0: steps 180,
  distance 200, cadence 180 spm, pace 300 s/km.

## 3. Watch

### Recording (Data mode on)

- Reuse `DebugCSVWriter`, file `session-<workoutId>.csv`, sent with the existing
  `PhoneLink.sessionCSVMetadata`, so the phone files it under Debug unchanged.
- Header line: `# barpath-session v1, sessionId=<workoutId>, startDate=<ISO8601>, workout=<definitionId>`
  (instead of `liftType=`). Same columns: `t,qw,qx,qy,qz,ax,ay,az,gx,gy,gz,rx,ry,rz`.
- Device motion at **100 Hz** from `CMMotionManager` (no 800 Hz accel, no lift detector).
- Comment lines (key=value with no spaces in values, so `tools/barpath/recording.py` parses
  them as events):
  - `# event t=<s> name=segment index=<i> kind=<run|station> source=<start|crown|press|button|auto>`
  - `# event t=<s> name=undo index=<i after undo> source=<…>`
  - `# event t=<s> name=finish index=<last>` and `name=unfinish`
  - `# event t=<s> name=hr bpm=<value>`
  - `# event t=<s> name=pedometer steps=<cum> distance=<cum m or -1> cadence=<spm or -1> pace=<s/km or -1>`
  - `# mark t=<s> n=<k> label=mark` (Mark button on the controls page)
- With Data mode off: no CSV. The pedometer, HR and result still work.

### Session

- New `WorkoutSessionModel` (`@MainActor ObservableObject`) with its own `WorkoutManager`.
  `WorkoutManager` gains `var activityType: HKWorkoutActivityType` (default
  `.traditionalStrengthTraining`) and `var locationType: HKWorkoutSessionLocationType`
  (default `.indoor`), both used by `beginSession()`. The lifting code path is unchanged.
- On `.running`: `progress.start(at:)`, motion and CSV start, `CMPedometer.startUpdates(from:)`.
- HR comes from `WorkoutManager.onHeartRate`, stored as `TimedValue`s.
- At End: stop the pedometer and motion, close the CSV, build the `WorkoutResult` with
  `SplitStats.compute`, write `Outbox/workout-<id>.json` and send it with metadata
  `["type": "workoutResult", "id": <uuid>]`, then send the CSV. Then `WorkoutManager.end()`.
  `PhoneLink.metadata(forFileNamed:)` must map `workout-<uuid>.json` to that metadata (check
  it **before** the lift `.json` rule).
- After every event, persist `progress` (JSON) to `UserDefaults` key `workoutProgress.v1`.
  Crash recovery comes later; this keeps the splits.

### Screens (no scrolling; SF Rounded)

- RootView: if the lifting session isn't idle → `SessionView`; else if the workout session
  isn't idle → `WorkoutSessionView`; else a horizontal page `TabView` (`.tabViewStyle(.page)`)
  with `StartView` (Lifting) and `WorkoutStartView` (Workouts). Remember the last page.
- **WorkoutStartView:** a top row with the phone dot and the DATA chip (its own setting,
  default ON); a big workout tile (name plus "10 segments"), tap → `WorkoutPickerView` (3×3
  grid of the 6 `WorkoutLibrary.all` short names, selected = filled); a green START (≥ 60 pt).
  Below that, a one-line summary of the last workout ("Last: WOD 1 · 41:12 · sent").
- **WorkoutSessionView**, page 1 (main):
  - Top line: `3/10` · total time · ♥ HR.
  - Center: the segment title (≤ 2 lines, 22 pt heavy) and the segment time (48 pt heavy
    monospaced digits).
  - Runs: a line with segment distance "620 m", pace "5:12/km" and cadence "172".
  - Bottom: "Next: Wall Balls 100", **or** for 10 s after any advance or undo an
    "↶ Undo" capsule button.
  - Finished: a full-screen green fill with "DONE", the total time, and the Undo capsule.
  - Always-on (`isLuminanceReduced`, wrist down): the same main layout, dimmed (80 %), no
    NOW flash, no undo hint, no Crown arc. Every clock (segment time, rest countdown, total /
    AMRAP time left, recovery) is a system timer text (`Text(timerInterval:)`) that keeps
    ticking every second; pace, HR and the border update at the reduced always-on rate
    (athlete feedback 2026-11-01: glance at it without raising the arm).
- **Page 2 (swipe):** End (with a confirmation: "End workout?" with [End] and [Keep going],
  Keep going is the default), Undo, Mark (Data mode only), a 12 pt data strip (samples,
  CSV MB, transfers pending).
- **Advance gesture: Digital Crown.** watchOS does not give apps the Crown *press* or the
  side button. So:
  - Turning the Crown forward through **one threshold** (constant `crownThreshold`, start
    value 0.6 of a full turn; tune on device) advances.
  - Turning it backward through the same amount undoes.
  - The accumulated rotation resets after 0.8 s without movement.
  - A progress arc around the screen edge shows the accumulated amount while turning.
  - A `.click` haptic plays at half the threshold.
  - Ignore Crown input for 2 s after any advance or undo.
  - Backup: a 1.0 s long-press anywhere on page 1 = advance (`source: .press`).
- **Haptics:** advance into a run → `.start`; advance into a station → `.directionUp`; undo →
  `.directionDown`; finish → `.success`.

## 4. Phone

- `PhoneLink.session(_:didReceive:)`: `type == "workoutresult"` (lowercased) or a file name
  that starts with `workout-` and ends with `.json` → move synchronously to
  `Documents/Workouts/<id>.json` and tell `WorkoutStore.shared` to ingest it. CSVs stay on the
  existing path.
- `WorkoutStore` (`@MainActor`, `.shared`): loads all results at launch, newest first, delete.
- New **Workouts** tab (second tab, after Live):
  - A list of results: name, date, total time, segment count.
  - Detail view:
    - Header: total time, runs total, stations total, average and max HR.
    - Split table rows: #, title, time, cumulative time, HR avg; for runs, pace and cadence.
    - Share buttons for the result JSON and, if present in `Documents/Debug/`, the CSV
      named in `recordingFileName`.

## 5. Result corrections and partial reps (added 2026-10-31)

Motivation: AMRAP 2026-10-30 had a Crown mix-up (splits wrong for 3 segments) and 13 double
unders done before the cap that the result could not hold.

### Kit (BarPathKit, WorkoutResult.swift / new WorkoutResultEditing.swift)
```swift
// New optional fields on WorkoutResult (decodeIfPresent; old files decode unchanged):
public var partialReps: Int?        // reps done in the segment that was cut by the cap/end
public var editedAt: Date?          // set when the athlete corrected splits on the phone

extension WorkoutResult {
    /// Moves the boundary between segment index-1 and index to `start` (s since 1970).
    /// Valid only for 1 ≤ index < segments.count; clamps to [segments[index-1].start + 1,
    /// segments[index].end − 1]. Updates start/end/duration of both segments, recomputes
    /// their heart-rate avg/max/min from heartRateSeries when present, and splits
    /// steps/distance between the two pro rata by time (cadence/pace recomputed; pace only for
    /// runs). Sets editedAt = now. Returns false if index is out of range.
    @discardableResult
    public mutating func moveSegmentStart(index: Int, to start: Double, now: Date = Date()) -> Bool
    /// Sets partialReps (nil or 0…target of the last segment's reps; clamped) and editedAt.
    public mutating func setPartialReps(_ reps: Int?, now: Date = Date())
}
```
WorkoutSummary: AMRAP headline extraReps adds `partialReps`; stoppedIn text mentions it
("+13 Double Unders"). DataNote adds "edited" when editedAt != nil.
Python mirror: fields in to_dict/from_dict + move_segment_start + set_partial_reps, same rules.

Implementation notes (2026-10-31, additive to the API above):
- `moveSegmentStart`: indices are positions in `segments`; a pair shorter than 2 s gets the
  midpoint; a non-finite `start` returns false. HR per segment = mean/max/min of the non-null
  series buckets whose centre lies in [start, end) (bucket at the midpoint if none);
  `public static func heartRateStats(series:from:to:) -> (avg: Double?, max: Double?, min: Double?)`.
  Steps/distance: the pair's total × (duration / pair span). Without a series HR is kept.
- `public var partialRepsLimit: Int?` = reps target of the last segment (nil → only ≥ 0 applies).
- The watch writes `partialReps` directly (no `editedAt`): only phone corrections count as edits.
- Summary: `Headline.partialReps`, `StopPoint.partialReps`, `DataNote.isEdited`; AMRAP context
  "Stopped in Double Unders, 0:16 in, at the 20:00 cap · +13 Double Unders"; data note ends
  with " · edited". `AmrapClock.extraReps` includes the partial reps too.
- CSV loader (`load_workout_csv`) exposes the last `partialReps` event as `partial_reps`.

### Watch
On the finish screen when the workout was finished by the time cap (AMRAP), ask:
"Reps of <segment name>?" with the Digital Crown picking 0…target (default 0), a Save tap.
Stored in the model and written as `partialReps` in the WorkoutResult at End (and in the CSV as
`# event name=partialReps reps=<n>`).

### Phone
Workouts detail: "Fix splits" button opens an editor: each segment row shows its start time
(m:ss from start) with −5 / −1 / +1 / +5 s buttons (calls moveSegmentStart for that index);
an AMRAP row "Reps after the cap" with a stepper (setPartialReps). Save writes the corrected
result over Documents/Workouts/<id>.json after keeping the first original as
Documents/Workouts/<id>.original.json (once), and reloads the store. Cancel discards.

## 6. Heart-rate recovery after the finish (added 2026-11-01)

Motivation: after the last segment the athlete stays on the done screen until End (Partner WOD 1,
2026-10-31: finish 23:09, End 3:41 later, HR 162 → ~107), but the series stopped at the finish.

### Result format (no version bump, no new keys)
- `heartRateSeries` now runs from the start to **End** (`endDate`), not to the finish. Files
  written before 2026-11-01 stop at the finish; both decode unchanged.
- The workout part is unchanged: the timeline, zones and segment stats use start → finish
  (`totalSeconds`, segment times), so nothing after the finish leaks into them.
- `heartRateAvg` / `heartRateMax` (watch) cover start → finish (or End if not finished); before
  2026-11-01 they covered start → End.

### Kit (`HeartRateRecovery.swift`; Python `HeartRateRecovery` in workout.py)
- `HeartRateRecovery.make(series:finish:end:) -> HeartRateRecovery?`, `WorkoutResult.heartRateRecovery`.
- HR at the finish = highest 5 s bucket overlapping the last 10 s before the finish (incl. the
  bucket holding it). HR at +60 / +120 / +180 s = mean of the non-null buckets whose centre is
  within ±7.5 s of the mark, only when the recording covers the mark. `drop1/2/3` = finish − mark
  (HRR1/2/3, bpm). `coveredSeconds` = min(End, series end) − finish.
- Nil when not finished, no series, < 60 s recorded after the finish, no HR at the finish, or no
  mark has a value.
- Backfill for older files: `needsHeartRateBackfill` (series ends ≥ 1 bucket before End),
  `SessionCSV.heartRateSamples(_:)` (the CSV's `# event t=… name=hr bpm=…` lines; t is seconds
  since the header `startDate`) and `backfillingHeartRate(samples:)` (keeps the existing buckets,
  appends `HeartRateSeries.make` buckets on the same grid up to End; no `editedAt`).
  Python: `needs_heart_rate_backfill`, `session_csv_heart_rates`, `backfill_heart_rate`.
- 2026-10-31 with its CSV: 161 → 145 (1 min) → 123 (2 min) → 105 (3 min), drops 16 / 38 / 56.
  (Raw samples read 162 / 143 / 123 / 107; the grid and the 15 s mean smooth single readings.)

### Watch
Done screen (after the finish, before End): "DONE 23:09" on one line, a dark panel with
"RECOVERY 1:23" (counting up from the finish), HR now and its change since the finish ("−19"),
Undo, and the End hint. Haptics: light (`.click`) at 1:00 and 2:00, `.success` at 3:00 plus
"3 min recovery done · End when ready". The done screen never ends by itself. The CSV logs
`# event name=recovery seconds=<60|120|180> bpm=<n>`. Cap finish: one compact recovery line above
the partial-reps picker. Screen demo: same, with the fake HR.

End during recovery (W6, added 2026-11-03): End (confirmed) after the finish with less than
`WorkoutSessionModel.recoverySeconds` (180 s) since the finish doesn't stop yet. Phase
`.recovering`: HealthKit, HR, motion CSV and pedometer keep running; the screen shows
"RECOVERY · SAVING IN 2:14" (countdown to finish + 180 s), HR now and its drop, and a small
"Save now". At finish + 180 s it saves by itself (the 3:00 `.success` haptic plays on the same
tick); "Save now" saves at once. Wrist down: same screen dimmed, system countdown, no button.
The CSV logs `# event name=endRequested recoveryLeft=<s>`. The result is built and sent once, at
the real save (`endDate` = finish + ~180 s), so the series covers the 3:00 mark. End saves at once
(as before) when: not finished (abandoned), 180 s already passed, the cap's reps picker is still
unanswered, no HealthKit session (no HR, and no background time to save wrist-down), or screen
demo ("End demo" leaves the demo). A HealthKit session ended by the system while recovering
saves at once, like during the workout.

### Phone
Overview: a "Recovery" card under the heart-rate chart when `heartRateRecovery` exists:
"HR 161 → 145 (1 min) → 123 (2 min) → 105 (3 min)", one tile per mark ("−16", first minute
highlighted), and "A bigger drop in the first minute usually means better fitness. Compare it
with your own past workouts". No card otherwise.

Heart-rate chart (added 2026-11-01): with a recovery, `WorkoutSummary.Timeline.recovery`
(`RecoveryTail`; Python `WorkoutResult.recovery_tail`) carries the HR after the finish on its own
5 s grid from the finish (value k = series at finish + bucket centre, last bucket cut at End),
placed at relative time `duration` → `duration + coveredSeconds`, with the recovery's
`heartRateAtFinish` and marks. Nothing in it feeds the workout numbers (stats, zones, gaps,
low / high, headline, story). The chart runs on past the finish: a thin "finish" divider, a pale
band labelled "Recovery", the line and the +1 / +2 / +3 min dots (with bpm) in the recovery colour
(`Theme.ovRecovery`, a calm cyan used for nothing else), its own "+1m" ticks and "End +3:41". The
tail gets its real share of the width but at least 30 % and at most 45 % (each side linear), so
the marks stay readable after a long workout. The zone strip stops at the finish (time in zones
is a workout number); under the tail it is the pale recovery colour. Tapping or scrubbing in the
tail clears the segment selection and the chip reads "Recovery +1:23 · 136 bpm · −25 since
finish"; VoiceOver stepping still walks the segments. Legend: "Recovery". Older results (no
recovery) look exactly as before. On load, results that need a backfill and whose
session CSV is on the phone are extended once in the background and saved like an edit
(`<id>.original.json` kept). Raw data in data/raw is not modified.
