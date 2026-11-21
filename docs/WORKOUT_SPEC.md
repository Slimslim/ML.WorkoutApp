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
public enum AdvanceSource: String, Codable { case crown, press, button, auto, edit }

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
- Device motion, rate chosen **once at START** for the whole session (build 15). **200 Hz** through
  `CMBatchedSensorManager` when the planned workout's `RecordingProfile` is `.high` (it contains a
  barbell / dumbbell / kettlebell strength or Olympic movement; locomotion, machines and metcon
  stations such as step-ups, runs, rucks, ergs, wall balls and burpees stay standard even with a
  load), the HealthKit session is running and the watch supports it. Otherwise **100 Hz** from
  `CMMotionManager`, unchanged. The high-rate path falls back to 100 Hz when HealthKit is not
  running at START (no Health access, or the start timed out) or when the batched stream delivers
  nothing within 2.5 s. No 800 Hz accel (the session CSV has no accel columns), no lift detector.
  The header carries the real `sampleRate=<100|200>` and the rule's verdict `planProfile=<high|standard>`.
  The Python loader (`load_session_csv`) decimates workout files to 100 Hz, so the detectors are unchanged.
- Comment lines (key=value with no spaces in values, so `tools/barpath/recording.py` parses
  them as events):
  - `# event t=<s> name=segment index=<i> kind=<run|station> source=<start|crown|press|button|auto>`
  - `# event t=<s> name=undo index=<i after undo> source=<…>`
  - `# event t=<s> name=finish index=<last>` and `name=unfinish`
  - `# event t=<s> name=hr bpm=<value>`
  - `# event t=<s> name=pedometer steps=<cum> distance=<cum m or -1> cadence=<spm or -1> pace=<s/km or -1>`
  - `# event t=<s> name=gps distance=<cum m> speed=<m/s> accuracy=<m> altitudeDelta=<m>` (build 15,
    only in sessions whose header says `gps=on`, i.e. the plan has a run): one line per accepted
    location fix (horizontal accuracy 0-30 m, timestamp after the start). `distance` = meters since
    the first accepted fix (sum of the distances between consecutive accepted fixes); `speed` =
    `CLLocation.speed`, the key is omitted when negative (unknown); `accuracy` = horizontal accuracy;
    `altitudeDelta` = altitude change since the first fix (relative). **No latitude, longitude,
    absolute altitude or course.** Example:
    `# event t=412.350000 name=gps distance=1043.2 speed=3.41 accuracy=4.8 altitudeDelta=-1.6`.
    Parsed by `barpath.recording.parse_gps_events` / `SessionCSV.gps_fixes()`. Recorded for comparison
    with the pedometer; the displayed distance and the result still use the pedometer. The route goes
    to Apple Health only (route builder of the live builder, `finishRoute` after `finishWorkout`).
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
  Crash recovery (W24): a checkpoint file (`WorkoutCheckpoint`, Application Support) holds the
  progress, HR, pedometer samples, partial reps and `savedAt`; it is rewritten at every split and
  about every 15 s, and deleted once the result is written at End. At the next launch a leftover
  checkpoint becomes a result ending at `savedAt` (no finish time unless finished), is sent as
  `workout-<id>.json`, and the start screen reads "… · saved after interruption". The workout is
  not resumed; an active HealthKit session is ended and saved.

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
    AMRAP time left, recovery) is plain text from the 1 s `TimelineView`, which a running
    workout session refreshes every second wrist down; no `Text(timerInterval:)`, which
    watchOS shows as "1:--" there (athlete feedback 2026-11-01 and 2026-11-05: read the
    exact time without raising the arm).
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

### Corrections from the cloud (added 2026-11-05, W17)
For learning and debugging: a result can be corrected outside the app by replacing
`<user id>/Workouts/<id>.json` in the `uploads` bucket (service role; keep the watch copy as
`<id>.original.json` next to it). The correction must set `editedAt` to the time of the edit and
may change the result's own definition (its parts) — the library workout stays as written.

Every phone sync (app comes to the foreground, Upload now, pull down in the Log) first lists that
folder. For each `<id>.json` whose cloud date changed since the last check and whose result is on
the phone, it downloads the file and replaces the phone's copy when
`WorkoutCloudCorrection.shouldReplace` says so: the cloud copy has an `editedAt` and the phone's
copy has none or an earlier one. The phone's copy is kept as `<id>.original.json` (Restore
original), the store reloads, and the written files are marked as uploaded so they are not sent
back (a `.original.json` created this way does not overwrite the cloud's watch copy). A result
with a phone change not yet uploaded (or uploading) is skipped until that upload is done: the
phone's change wins. A cloud file that does not decode is reported once and skipped until it
changes or a new app build is installed (every build checks each file once). Events a correction
adds carry `source: "edit"`. Results deleted on the phone are not brought back. Keys this build does not know (e.g. `rx`) are
dropped from the phone's copy when it is written; the cloud copy keeps them.

## 5a. An AMRAP never runs out of list (added 2026-11-20, #138)

The watch's progress finishes on the last listed segment whatever the format, and `roundSize` does
not make the list repeat. A library AMRAP that listed one pass offered Finish after it, with minutes
left on the cap. Since 0.17.1 the watch expands an AMRAP at START
(`WorkoutDefinition.expandedForAmrap()`, Python `amrap_expanded`):
- Only `format: amrap` with a time cap. The round is `roundSize` segments; without a valid
  `roundSize`, the smallest exact repeat of the list (3 identical rounds of 4 → rounds of 4), else
  the whole list (a ladder written once is one round). A list that is not whole rounds (e.g. a
  final rest dropped) is left alone and can still run out: list such workouts in whole rounds.
- With `intervalSeconds` and no `roundSize`, the list is written out but `roundSize` stays unset
  (setting it would turn on the interval jump for work segments).
- The **last full round** is repeated until the list holds 30 rounds (fewer when that would pass
  600 segments; never fewer than listed), and `roundSize` is set. A ladder written out round by
  round therefore stays on its top rung after the listed rounds (it does not keep climbing). The
  watch then shows "Round n" (not "n/count" of the written-out list), and the result and summary
  count rounds. History matches a result to its library workout as expanded
  (`WorkoutHistory.isSameWorkout`).
- The result carries the expanded definition, and the crash checkpoint stores it inside the
  progress, so a restored workout keeps it. Expanding twice changes nothing.
- Builds before 0.17.1 still finish after the listed rounds: library AMRAPs must list their rounds
  out (the `make_row.py` check is PR #139).

## 5b. For-time caps: keep going past the cap (added 2026-11-03, W7)

Owner, 2026-11-03: "For time with a cap: if you are not done within the cap, I don't want the
workout to stop. Let me know at the cap and let me continue, so I can see how fast I did the
full workout. At the end ask how many reps I did on that movement before the time cap, so we
know how far I was. If I want to stop I can stop — it's my decision."

AMRAP caps are unchanged (the clock finishes the workout, `capTime`, `partialReps`, §5). This
section is for `format == .forTime` with `timeCapSeconds > 0` (Seesaw 18:00, Helen 16:00,
Partner WOD 1 30:00).

### Result format (no version bump, one new optional key)
- `repsAtCap: Int?` — reps done in the segment running at the cap, entered after the finish.
  Absent in older files and when not asked / skipped. `totalSeconds` stays start → finish (the
  time for the full workout), past the cap or not.
- No new `WorkoutEventKind` case: an older app would fail to decode the whole file on an
  unknown event kind. Everything else is derived, so older files that went past a cap read as
  capped too (with `repsAtCap` nil).

### Kit (`WorkoutProgress.swift`, new `WorkoutResultCap.swift`; Python mirror in workout.py)
```swift
// WorkoutProgress
public var forTimeCapTime: Double?                 // start + cap (for time only), nil otherwise
public func segmentIndex(at t: Double) -> Int?     // last segment started at or before t
public func capSegmentIndex(now: Double) -> Int?   // segment at the cap once (finish ?? now) > cap
// WorkoutResult
public var repsAtCap: Int?
public var forTimeCapSeconds: Double?              // definition cap, for time only
public var isCapped: Bool                          // forTimeCapSeconds != nil && totalSeconds > cap
public var capReachedAt: Date?                     // startDate + cap when capped
public var capSegmentIndex: Int?                   // recorded segment with start ≤ cap < end
public var capSegment: WorkoutSegment?
public var repsAtCapLimit: Int?                    // reps target of that segment, else nil
public mutating func setRepsAtCap(_ reps: Int?, now: Date = Date())   // clamped, sets editedAt
public var capPositionText: String?                // see below
```
Python: `for_time_cap_time`, `segment_index_at`, `cap_segment_index(now)`; on the result
`reps_at_cap`, `for_time_cap_seconds`, `is_capped`, `cap_reached_at` (s since 1970),
`cap_segment_index`, `cap_segment`, `reps_at_cap_limit`, `set_reps_at_cap`,
`cap_position_text`. Finishing exactly on the cap is not capped (strictly greater).

### Score format
- The big score is always the time for the full workout: "14:52" under the cap, "18:20" past it.
- Under the cap the context line is unchanged: "3 rounds for time · 0:23 under the 16:00 cap".
- Past the cap: "3 rounds for time · 2:20 over the 16:00 cap · at the cap: 7/12 Pull-ups (R3)".
- `capPositionText`: "7/12 Pull-ups (R3)" (reps / target), "7 Burpees" (no reps target),
  "in Pull-ups (R3)" (reps not entered). The round suffix only for `roundSize > 1`.
- Ended (not finished) past the cap: "… · Not finished · ended in KB Swings · at the cap: in
  KB Swings (R1)".
- `Headline.repsAtCap` carries the value (nil when not capped).

### Watch
- At the cap the workout keeps running: the "Time!" haptic (stop ×3, success — same as the
  AMRAP cap), a 3 s full-screen banner "TIME CAP · 16:00 · KEEP GOING", and
  `# event name=capReached index=<i>` in the CSV. Once per workout. The total line then reads
  "18:42 · +2:42 over cap" (wrist down: live total + " · over cap"). No 3-2-1 before the cap.
- Finished past the cap (last Crown turn): the done screen shows the reps picker, "Reps of
  <segment> at the cap?", 0…the segment's reps target (else 200), Save; skippable (End without
  Save). Asked only when the segment at the cap is not a run, a rest, or a metre/time target.
  Saved as `repsAtCap` at End and `# event name=repsAtCap reps=<n>` in the CSV (the AMRAP
  picker keeps writing `partialReps`). Undo of the finish clears it, as for AMRAP.
- Screen demo: the cap is shortened like the other clock times (WorkoutDemo).

### Phone
- Overview hero: the context line above (WorkoutSummary), no view change.
- Fix splits: "Reps at the cap · <segment>" stepper when the result is capped (setRepsAtCap).

## 5c. Repeating blocks and fixed lists (brief, #138, owner decision 20 Nov)

Status: **engine core for 0.18 (E1)**: Python reference (`tools/barpath/repeat_block.py`,
block mode in `WorkoutProgress`), BarPathKit port (`RepeatBlock.swift`, `WorkoutProgress.block`),
shared fixtures `Fixtures/repeat_block_cases.json` and `Fixtures/repeat_block_progress_cases.json`
(written by `tools/make_repeat_block_progress_cases.py`). The watch wiring behind the engine switch
is E3. The 0.17.1 stopgap (§5a) stays unchanged on the legacy route. Questions are marked
**[Q1]…[Q8]**.

### Only definitions marked listed-once repeat (0.18, owner 20 Nov via Delivery)
- A definition repeats only when it carries **`listedOnce: true`** (new optional key, left out
  otherwise; builds before 0.18 ignore it). **Every row stored today is unmarked** and takes the
  **legacy route**: today's `WorkoutProgress`, with the §5a AMRAP expansion, whatever the engine
  switch says. Written-out EMOM, Tabata and AMRAP rows (Row + Thrusters, AMRAP 20 / 40) and Hyrox
  therefore keep their window targets, finish and score exactly; tests check the stored built-ins
  by id (`test_repeat_block.py`, `RepeatBlockTests.swift`).
- Block mode needs **both** the engine switch on and the mark: `engine_plan(d, "v2")` /
  `RepeatBlock.enginePlan(for:engineOn:)` gives the plan, anything else gives nil (today's path).
  `WorkoutProgress(definition:block:)` with `block == nil` runs exactly today's code.
- A marked definition the block can't run (no segments, only rests, an interval block that does
  not end with a rest) falls back to the **written-out** legacy route (`listed_once_problems`,
  then `written_out`). A mis-marked written-out row grows (a marked Row + Thrusters becomes 6 × 17
  segments), and an interval block without a closing rest loses its window wait there (the Crown
  goes straight to the next set). **Every listed-once interval row must end with a rest**; the E5
  test workouts do, and a test fails if one doesn't.
- **Classic (engine off) with a marked definition:** the block is written out first, the way
  today's stored rows are (`written_out` / `RepeatBlock.writtenOut`): Rounds for time × N gets N
  passes with no rest after the last round; EMOM / Tabata gets the round count, else
  ceil(cap / interval) windows; an AMRAP gets `roundSize` = P and then the §5a expansion. So a
  listed-once workout never runs one pass on Classic (the #138 bug). A marked fixed list only
  loses the mark. An AMRAP with an interval keeps `roundSize` unset, as §5a does. A written-out
  interval block keeps the last window's rest, so it finishes at the last window's end (block mode
  does the same; the stored Row + Thrusters, which lists no last rest, finishes on the last Crown).
  In a rest, Classic still lets the Crown skip ahead while block mode waits for the window: by
  design, the gate compares each engine with itself, not the two routes. One START rule for the watch, Python and the E4 gate:
  `RepeatBlock.startProgress(for:engine:)` / `start_progress`.
- **A marked fixed list with an interval** ("Go every …" done once) takes the legacy route: block
  mode would end it at the first window.
- **Planned length in the phone views:** a block result's `displayDefinition` is written out to the
  planned steps when the plan has them (rounds × N, or ceil(cap / interval) windows), so an EMOM
  × 10 ended after 3 reads "3 / 10" and 5 rounds for time ended in round 3 reads as not finished;
  an AMRAP is written out to the steps done. The cap text's round comes from it too.
- **Marked built-ins behave as today:** every built-in marked listedOnce and run in block mode
  (fixed lists as fixed, the AMRAPs as a repeating block) gives exactly today's events (test).

### Timing in block mode (E1)
- **Interval blocks (EMOM, Tabata, "Go every"):** one window = one pass. The block must end with a
  rest: that rest is the wait until the next window, and a Crown there is **ignored** (the watch
  shows a hint, E3), so every window starts on the clock. A part with a seconds target (Tabata's
  20 s work, a 30 s rest in the middle) ends on its own timer and hands over to the next part,
  unless the window ends first. At the window end the clock moves to the first part of the next
  pass. A rest in the middle with no timer is skipped by the window end (today a rest moves to the
  next segment; this differs only for a mid-block rest, which no stored row has).
- **The last pass:** with an interval, the last window keeps its rest and the clock ends the
  workout (Tabata 8 × 30 s = 16 steps, 4:00 exactly). Without an interval (Rounds for time × N),
  the last pass ends on its last work part: a rest after the last round is not done.
- **The cap** ends AMRAP and interval blocks that have one (`capTime` in block mode); for time
  keeps going (§5b). Undo crosses back into the previous pass; undo after a Finish unfinishes.
- **Undo in an interval block once its timers have passed:** after an undo back into a step whose
  timer or window has already ended, the clock does not fire that past change again (the watch
  suppresses it, as today), and the Crown moves on even in the closing rest. The Crown is ignored
  in the closing rest only while its window end is still ahead, so the athlete is never stuck.

**Answers so far (Delivery, 20 Nov).** These are defaults until the owner overrides them:
- **Q1:** yes, an optional `rounds` key. Rows written out today, such as Helen, stay on the
  legacy route until they are migrated (and marked listedOnce).
- **Q2:** no data change. EMOM and Tabata rows stay written out, unmarked, on the legacy route.
- **Q3:** in an interval format, **one window = one pass of the block**. In the owner's words,
  "Go every … is a block that repeats". The window length comes from `intervalSeconds` and the
  block, never from `roundSize`. Today's rows are unmarked and keep today's window rule, so EMOM
  and Tabata timing doesn't change (#145 review: a written-out row read as a block would have
  jumped past the whole list). An alternating EMOM ("min 1 A, min 2 B") has no form in the new model
  yet. Those rows keep today's written-out path, which is a later extension; there is no
  `partsPerWindow`.
- **Q4:** a rest the cap falls in doesn't count as done (as today).
- **Q6:** an exact repeat. In ED3D7646 the athlete chose the order; the plan was 200/400/600
  repeating. No `vary` for now.
- **Q7:** OK. New results fall back to the stored titles until the wiring PR.
- **Q5 and Q8:** with the owner. The core doesn't depend on a legacy copy, so either answer for Q8 works.

### What the owner decided
- **Two kinds of workout.**
  - *Repeating block*: Rounds for time, AMRAP, EMOM, Tabata, "Go every …". The definition lists
    one block, once, and the watch repeats it.
  - *Fixed list*: everything else (for time, chipper, Hyrox). The parts are done once.
- **The block is the whole listed list.** `roundSize` only groups parts for display. It never
  decides what repeats.
- **Nothing is copied into the definition.** The next pass of the block starts when the athlete
  reaches the end of the current one ("lazy rounds"). The result stores what was actually done.
- **Fixed lists behave exactly as today.** Hyrox and every other fixed list keep today's path.

### Words
- **Part**: one listed segment of the definition, `segments[p]`, with `p` in `0..<P` (`P = segments.count`).
- **Pass**: one time through the block. A pass is a round, or an interval set.
- **Step**: one part as it is actually done, numbered `0, 1, 2, …` from START. Step `s` is pass
  `s / P` and part `s % P`. A fixed list has exactly `P` steps. Today's watch counts steps the same
  way (`WorkoutProgress.segmentStarts`), so a fixed list's step numbers are its segment indices.

### Which formats repeat (proposed classification)
| Definition today | Kind | Ends |
|---|---|---|
| `format: amrap` with a cap | repeating, no round count | the cap (or End) |
| `format: emom` (EMOM, Tabata, "Go every …") | repeating | the cap, or after N passes when a round count is given |
| `format: forTime` with a round count (new key, [Q1]) | repeating, N passes | Finish on the last part of pass N; the cap per §5b ("keep going") |
| `format: forTime` without a round count (Hyrox, chipper, Helen as listed today) | fixed list | as today |
| `format: amrap` without a cap | invalid today (`make_row.py` refuses it); the reference treats it as a fixed list | as today |

- **[Q1] How does "Rounds for time × N" say N?** The flat v1 definition has no round count. Today
  Helen lists its 3 rounds out (`roundSize: 3`). The proposal is a new optional key, `rounds: Int`,
  that old builds ignore.
  - With `rounds`, a forTime definition lists one round, which repeats N times.
  - Without it, nothing changes: every forTime row in the library today stays a fixed list.
  - v2 already has `repeat.times` (RFC §2), and its compiler would fill this key.
- **[Q2] EMOM and Tabata rows that are already written out.** Every live EMOM row lists its windows
  out (16 segments for 8 × 30 s, for example), with a cap equal to windows × interval.
  - As a repeating block, such a row would repeat the whole written-out list. The cap ends it
    before the list runs out, so the athlete sees no change.
  - Should these rows also be rewritten to list one window? That is a data change, so it needs your OK.

### What ends a repeating block
- **AMRAP:** only the cap (`finishByCap`) or End. The Crown on the last part never offers Finish;
  it starts the next pass. This is the #138 bug fixed without copying anything.
- **Rounds for time × N:** the Crown on the last part of pass N finishes. Before that, the last
  part of a pass moves on to part 0 of the next pass. The cap behaves as in §5b.
- **EMOM with N given:** after N passes, or at the cap, whichever comes first. With an interval,
  the clock moves windows on as today (`autoAdvanceTime`).
- **[Q3] In an interval workout, is a window one pass of the block or one part?** Today a window is
  a `roundSize` group, and the clock jumps to the next group. The owner's rule is that the block is
  the whole list and `roundSize` is display only. That makes a window one pass. An "odd minute A,
  even minute B" EMOM would then need A and B as two passes, not one. Which do you want?
- **Answered (Q3):** one window = one pass. At the window's end the clock moves to the first part of
  the next pass, skipping what is left of this one. The rule is `window_target_step`: next pass
  start = `(step / P + 1) × P`. It is today's `autoAdvanceTargetIndex` with `roundSize` replaced
  by the block length P, for listed-once definitions only. The stored interval built-ins are unmarked
  and keep today's rule; a test checks them by id.

### Undo across a pass boundary
- Undo goes back one step, whatever the pass: from pass k, part 0, back to pass k−1, last part. It
  keeps that step's start time, as today. Undo on step 0 does nothing.
- Unfinish after a Finish works as today. For an AMRAP the only Finish is the cap, and an unfinish
  after the cap follows §5's existing rule (10 s on the watch, then the phone).
- Nothing is ever "un-generated": the next pass only exists once its first step has started. After
  an undo the next Crown press starts that step again with a new time.

### Cap during a part, partial reps, score
- The cap finishes in the current step. `partialReps` keeps meaning the reps done in that step's part
  (the "Reps of <part>?" question, §5). The limit is that part's target.
- **AMRAP score:** completed passes plus the parts done in the cut pass, plus partial reps. For
  example: "5 rounds + Run 200 + 12 cal".
- **[Q4] Should a rest still count as done** when the cap falls inside it? Today a rest doesn't
  score (`makeAmrap`): a round counts as complete once its work is done. The proposal keeps that.

### Finish on the last listed part
- **Fixed list:** Finish, as today.
- **Repeating with no count (AMRAP):** no Finish; the next pass starts. The watch's second line
  shows "Round k".
- **Repeating with N:** Finish only on the last part of pass N.
- **[Q5] Ending an AMRAP early on purpose** stays on End (page 2), which needs no confirmation
  change. Is that enough, or do you want a Crown-hold Finish as well?

### Ladders and blocks that change by round
- **#138's row** (Run 200, Bike, Run 400, Bike, Run 600, Bike) is one block of 6 parts, so pass 2
  is 200 / 400 / 600 again.
- **[Q6] The owner's actual workout was different:** 200 / 400 / 600, then 200 / 600 / 400, ending
  on 4 cal (GPS reconstruction on #138). Pass 2 did *not* repeat the listed order.
  - With the repeating block, the watch would show "Run 400" while the athlete runs 600.
  - Was this workout meant to repeat exactly (and pass 2 was the athlete's choice), or does it need
    per-round targets (v2 `vary`)?
  - The reference only repeats the block exactly; per-round changes are out of scope here.

### How a result stores what was done
- `SegmentResult.index` becomes the **step** number. Today it is the segment index, which is the
  same thing for a fixed list. Each stored segment already carries its own `kind`, `movement` and
  `title`, so a step past the listed parts still reads correctly.
- New optional fields, decoded with `decodeIfPresent` (written only for repeating blocks):
  - `SegmentResult.pass`, with the part as `index % P`;
  - `WorkoutResult.passes`, the number of passes started.
  - Old files have neither, and read as one pass, as today.
- The definition in the result is the listed block (P parts), never copied.
- **Built (E3, 0.18):** `SegmentResult.pass` and `WorkoutResult.passes` (block mode only), and
  `WorkoutResult.engine` ("new" | "classic", E2). Views written for written-out lists use
  `WorkoutResult.definitionSegment(forIndex:)` (a step's part) or `displayDefinition` (the block
  written out to the steps done, `roundSize` = P, derived on the fly and never stored): the summary,
  the report's set loads, the partial-reps and cap limits. A block result is not offered a
  definition swap. The watch reads the engine once at START (`WorkoutEngineSwitch.current()`), runs
  block mode only with the engine on and a listed-once definition (no §5a expansion then), keeps
  the plan and the engine in the crash checkpoint, writes `engine=new|classic` in the CSV header,
  shows "Round k · part/P" (or "Round k/N") and "Next set on the clock" while waiting for a
  window, and a small "NEW" on START when the switch is on.
- **[Q7] Phone views written for written-out lists.** Some views index `definition.segments` with
  a step number. They guard `index < count` and then fall back to the stored title (checked: the
  summary, insights, the report rows). Those guards would show steps past P without their target
  (for example, the run distance for pace).
  - The wiring PR must map step → part (`index % P`) wherever a target is looked up.
  - Until then, a new result shown on 0.17.x falls back to the stored titles and measured distance.
    Is that acceptable for testers, or should new-format results wait for the phone side?

### Old results and old builds
- **Old results** (written-out lists, no `pass`) read exactly as today, because step = segment
  index. The #140 stopgap's expanded definitions are written-out lists too, so they read the same.
- **Builds 15, 16 and 0.17.x** see a definition that lists one block. They finish after one pass:
  the #138 behaviour, now for every repeating row.
- **[Q8] Library rows for old builds.** The options:
  - keep the library's legacy copy written out for builds ≤ 0.17 (the database could write that
    copy, as it already writes the v2 legacy copy);
  - keep repeating rows written out until testers are on 0.18;
  - accept the bug on old builds.
  #140 (0.17.1) already handles a one-pass AMRAP on 0.17.1. Builds 15, 16 and 0.17.0 have no fix.

### Fixed lists don't change (must hold)
- Same steps, same Finish on the last part, same undo, same `WorkoutResult` fields and values.
- Every stored built-in, listed by id in the tests (Hyrox Solo, Doubles, Half, partner WODs,
  AMRAP 20 / 40, Helen, Row + Thrusters, Quick test, Free), takes the legacy route with the engine
  on, and a scripted run gives exactly the events it gives with the engine off. The E4 gate extends
  this to fixed-list fixture rows in CI, and pins today's behaviour: `Fixtures/engine_gate_golden.json`
  holds the full trace (events, step starts, finish, every split field) of every built-in and gate
  row under 7 scripts, written by running the v0.17.2 code itself; both engines must reproduce it
  (Python and Swift). Never regenerate it to get green: a difference needs the owner's sign-off.

### What gets built before 5 Dec (no wiring)
1. **Python reference** in `tools/barpath`, as pure functions:
   - the kind of a definition (fixed or repeating, with its round count and cap);
   - step → (pass, part);
   - whether a Crown advance from step s finishes;
   - the end reason (list done, rounds done, cap).
2. **Shared fixtures:** the #138 ladder, an EMOM, a Tabata, Rounds for time × N, and a fixed list
   that must not change.
3. **BarPathKit Swift port** with parity tests against the same fixtures. It is not called from the
   watch or the phone.
4. **A test** that every fixed-list built-in steps exactly as `WorkoutProgress` does today.

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

End during recovery (W6, 2026-11-03, revised the same day: automatic, no waiting screen).
End (confirmed) after the finish ends the workout exactly as before: result + CSV sent, the
HealthKit workout ends and is saved at the End press (Apple Fitness shows the workout to End),
back to the start screen. If HealthKit was running and at least 10 s are left until
finish + `WorkoutSessionModel.recoverySeconds` (180 s), the watch then records HR silently in the
background:
- once the workout's HealthKit session has saved, a second HKWorkoutSession (activity "other",
  `saveWorkoutOnEnd = false`, discarded at the end, so nothing extra lands in Health/Fitness)
  keeps the HR sensor in workout mode and the app alive wrist-down; its live builder's HR is
  appended to a copy of the workout's samples (a few seconds' gap at End is bridged by the 5 s
  series' 15 s interpolation);
- the start screen shows "Recovery recording · 1:42" (time since the finish) instead of "Last: …";
- at finish + 180 s it stops, ends that session and sends the result again (same id, new outbox
  file name `workout-<random>.json`): same splits, events, HR avg/max and partial reps (all end at
  the End press), `heartRateSeries` and `endDate` running to the stop time. No update when no HR
  arrived after End;
- a new workout (START) or lifting session stops it first (update sent with what was recorded),
  then starts its own HealthKit session once the recovery session has ended, at most ~1 s later
  (`backgroundRecoveryStopWait`); the screen demo doesn't stop it. A recovery session ended by the
  system also sends what it has.
The motion CSV and pedometer stop at the End press (CSV event `name=backgroundRecovery` just
before). Not started for an abandoned workout (End before the finish), without HealthKit, after
180 s, or in the screen demo.

Phone: the update arrives for an id it already has (`WorkoutFiles.storeIncomingResult` →
`WorkoutResult.storedAfterWatchUpdate`): an older copy arriving late is dropped; an untouched
result is replaced; a result changed on the phone (edit, definition upgrade, CSV backfill: an
`<id>.original.json` exists) keeps everything and takes over only `heartRateSeries` and `endDate`
(like the CSV backfill), and `<id>.original.json` becomes the update, so "Restore original" gives
the full recovery. Until the update the Recovery card follows the 60 s rule below.

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
