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
    public var intervalSeconds: Double?   // optional: "every N:00" sets
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
    public var heartRateSeries: HeartRateSeries? // v2: start → finish (or end), 5 s
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
  - Always-on (`isLuminanceReduced`): the title and the segment time only.
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
