import Foundation
import Combine
import HealthKit
import CoreMotion
import WatchKit
import os
import BarPathKit

/// One pedometer update (cumulative since the workout start, CMPedometer semantics).
/// Top-level (not nested in the @MainActor model) so the pedometer's background handler
/// can build it.
struct PedometerSnapshot: Codable, Equatable {
    var t: Double                   // seconds since 1970 (data.endDate)
    var steps: Double
    var distance: Double?           // meters
    var paceSecondsPerMeter: Double?
    var cadenceStepsPerSecond: Double?
}

/// Thread-safe logger (Logger is Sendable); file-level so nonisolated code can use it.
private let workoutLog = Logger(subsystem: "BarPathWatch", category: "workoutMode")

/// Workout mode (Hyrox / partner WODs) session state, WORKOUT_SPEC §3.
///
/// Owns its own `WorkoutManager` (HealthKit session: keeps the app alive wrist-down, gives
/// HR), a `WorkoutMotionRecorder` (Data mode CSV), a `CMPedometer`, and the kit's
/// `WorkoutProgress` (segment state machine). Segments are advanced manually (Crown, long
/// press, buttons).
///
/// Robustness rules (the athlete must not lose a race to a framework hiccup):
/// - If HealthKit fails or doesn't reach `.running` within `healthKitStartTimeout`, the
///   workout starts anyway without it (timer, pedometer, CSV still work).
/// - End always works: it finalizes and sends the result first, then ends HealthKit; if
///   HealthKit doesn't report back within `endTimeout`, the manager is discarded.
/// - A HealthKit session ended by the system is treated like End (saves what we have).
/// - End after the finish ends the workout as always (result sent, Health workout saved to the
///   End press, back to the start screen). With less than `recoverySeconds` since the finish,
///   a second, unsaved HealthKit session then records HR silently in the background until
///   finish + `recoverySeconds` and the result is sent again with the longer HR series (W6,
///   WORKOUT_SPEC §6). A new workout or lifting session stops it first.
@MainActor
final class WorkoutSessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle        // start screen
        case starting    // waiting for the HealthKit session
        case running     // segments being timed (also while "DONE" is shown)
        case ending      // result sent, waiting for HealthKit to save
    }

    /// Live numbers for the run line on the main page.
    struct RunLine: Equatable {
        var distance: Double?           // meters in this segment
        var paceSecondsPerKm: Double?
        var cadence: Double?            // steps per minute
    }

    private struct HeartRateSample {
        var t: Double
        var bpm: Double
    }

    static let healthKitStartTimeout: Double = 4.0
    static let endTimeout: Double = 8.0
    /// The Undo capsule replaces "Next: …" for this long after an advance or undo.
    static let undoCapsuleSeconds: Double = 10.0
    /// currentPace / currentCadence older than this are not shown (the athlete stopped).
    static let liveMetricMaxAge: Double = 10.0
    static let noHealthMessage = "No Health session (HR off)"
    /// The crash checkpoint is refreshed at least this often while a workout runs.
    static let checkpointInterval: Double = 15.0

    private enum Keys {
        static let progress = "workoutProgress.v1"
        static let dataMode = "workoutDataMode.v1"
        static let definitionId = "workoutDefinitionId.v1"
        static let lastSummary = "workoutLastSummary.v1"
        static let phoneDefinition = "phoneWorkoutDefinition.v1"
    }

    // MARK: Settings (persisted)

    /// Data mode (full-session CSV + Mark). Its own setting, default ON.
    @Published var dataMode: Bool {
        didSet { UserDefaults.standard.set(dataMode, forKey: Keys.dataMode) }
    }
    @Published var definitionId: String {
        didSet { UserDefaults.standard.set(definitionId, forKey: Keys.definitionId) }
    }

    /// The last workout picked on the iPhone (any definition, not only the built-in library).
    @Published private(set) var phoneDefinition: WorkoutDefinition?

    var selectedDefinition: WorkoutDefinition {
        // A built-in workout always uses this build's version, so an update (e.g. WOD 1 scaled,
        // 2026-10-31) isn't masked by an older copy the phone sent earlier.
        if let builtIn = WorkoutLibrary.definition(id: definitionId) {
            return builtIn
        }
        if let phone = phoneDefinition, phone.id == definitionId {
            return phone
        }
        return WorkoutLibrary.partnerWod1
    }

    /// True when the selected workout came from the iPhone.
    var isSelectedFromPhone: Bool {
        return phoneDefinition?.id == definitionId
    }

    /// Selects a workout sent by the iPhone. Safe during a session: the running workout keeps
    /// its own definition; this only changes what the next START uses.
    func selectFromPhone(_ definition: WorkoutDefinition) {
        phoneDefinition = definition
        if let data = try? JSONEncoder().encode(definition) {
            UserDefaults.standard.set(data, forKey: Keys.phoneDefinition)
        }
        definitionId = definition.id
    }

    // MARK: Session state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: WorkoutProgress
    @Published private(set) var heartRate: Double?
    /// Last advance/undo (wall clock), for the Undo capsule.
    @Published private(set) var lastChangeDate: Date?
    /// Last change made by the clock itself (timed rest or interval ending, time cap). The view
    /// starts the Crown lockout on it, so a turn in progress does not skip the next part.
    @Published private(set) var lastAutoAdvanceDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSummary: String?
    @Published private(set) var healthKitRunning = false
    @Published private(set) var isRecordingCSV = false
    @Published private(set) var motionSamples = 0
    @Published private(set) var csvBytes = 0
    @Published private(set) var marksCount = 0
    @Published private(set) var latestPedometer: PedometerSnapshot?
    /// Reps done in the segment cut by the time cap, entered on the done screen
    /// (WORKOUT_SPEC §5). Written into the WorkoutResult at End; nil = not entered.
    /// For time past the cap (§5b, W7) the same picker asks the reps of the segment running at
    /// the cap; the value then goes to `WorkoutResult.repsAtCap` instead.
    @Published private(set) var partialReps: Int?
    /// For time with a cap (§5b, W7): when the "Time cap · keep going" announcement played
    /// (wall clock), for the banner; nil before the cap. The workout does not stop there.
    @Published private(set) var forTimeCapAnnouncedDate: Date?
    /// Screen demo (`startDemo`): the real screen with mock HR / run distance (WorkoutDemo).
    /// No HealthKit, motion, pedometer, CSV, result, phone transfer or summary.
    @Published private(set) var isDemo = false

    private var workout: WorkoutManager
    private let recorder: WorkoutMotionRecorder
    private let link: PhoneLink
    private var pedometer: CMPedometer?
    private var workoutId = UUID()
    private var heartRates: [HeartRateSample] = []
    private var pedometerSamples: [PedometerSnapshot] = []
    private var finalized = false
    private var startTimeoutTask: Task<Void, Never>?
    /// Drives timed segments (rest on the clock, AMRAP cap) and the 3-2-1 countdown.
    private var clockTask: Task<Void, Never>?
    private var countdownTarget: Double?
    private var countdownLastBeep: Int?
    /// After an undo into a timed rest whose time has already passed, don't auto-advance it
    /// again (keyed by that segment's start time); same for a passed AMRAP cap.
    private var autoSuppressedStart: Double?
    private var capSuppressed = false
    /// systemUptime of the last crash checkpoint (see `saveCheckpoint`).
    private var lastCheckpointUptime: Double = 0
    private var endTimeoutTask: Task<Void, Never>?
    /// Managers replaced because they got stuck (kept alive so they can still finish).
    private var retiredManagers: [WorkoutManager] = []
    /// Screen demo: fake HR ticker and its state.
    private var demoTask: Task<Void, Never>?
    private var demoHeartRate = WorkoutDemo.HeartRate()

    // MARK: Recovery after the finish (WORKOUT_SPEC §6)

    /// HR at the finish (HeartRateRecovery rule on the samples so far), shown as the base of
    /// "−19" on the done screen. Nil until a sample near the finish exists, or not finished.
    @Published private(set) var recoveryFinishHeartRate: Double?
    /// Finish time the recovery state below belongs to (an undo + new finish restarts it).
    private var recoveryFinishKey: Double?
    /// Recovery marks (1:00, 2:00, 3:00) already announced with a haptic.
    private var recoveryMarksPlayed = 0
    /// recoveryFinishHeartRate no longer changes (enough time has passed for its buckets).
    private var recoveryFinishHeartRateFinal = false
    /// After this long the finish HR is fixed (its 5 s buckets and their neighbours are in).
    static let recoveryFinishSettleSeconds: Double = 20.0
    /// Recovery recorded after the finish (the done screen's "3 min done"); after an earlier
    /// End the watch records HR in the background until finish + this (W6).
    static let recoverySeconds: Double = 180.0
    /// Less than this left to finish + `recoverySeconds` at End: no background recording.
    static let backgroundRecoveryMinimumSeconds: Double = 10.0
    /// A new session waits at most this long for the background recording's HealthKit session
    /// to end.
    static let backgroundRecoveryStopWait: Double = 1.0

    // MARK: Background recovery after End (W6, WORKOUT_SPEC §6)

    typealias MainAction = @MainActor () -> Void

    /// Everything a WorkoutResult is built from: the session at End, or the copy a background
    /// recovery keeps (with the HR that arrives after End appended).
    fileprivate struct ResultInput {
        var id: UUID
        var progress: WorkoutProgress
        var heartRates: [TimedValue]
        var pedometer: [PedometerSnapshot]
        var partialReps: Int?
        var recordedCSV: Bool
        /// End press, seconds since 1970: splits, HR average and the CSV end here.
        var endT: Double
    }

    fileprivate struct BackgroundRecovery {
        var input: ResultInput
        /// finish + recoverySeconds (seconds since 1970).
        var until: Double
    }

    /// The input of the result sent at End (for a background recovery that follows).
    private var lastResultInput: ResultInput?
    /// Set at End when a background recovery should follow; started once HealthKit has saved.
    private var pendingRecovery: BackgroundRecovery?
    /// The background recovery being recorded, nil when none.
    private var backgroundRecovery: BackgroundRecovery?
    /// Its HealthKit session (activity "other", discarded at the end: Health keeps the workout
    /// that ended at the End press). Kept until it reports finished.
    private var recoveryManager: WorkoutManager?
    private var recoveryTask: Task<Void, Never>?
    /// Run once the recovery's HealthKit session has ended (or after `backgroundRecoveryStopWait`).
    private var recoveryWaiters: [MainAction] = []
    /// Finish time of the workout whose recovery is recording in the background (start screen
    /// "Recovery recording · 1:42"), nil when none.
    @Published private(set) var backgroundRecoveryFinish: Date?
    /// The app's one workout model, for `endBackgroundRecovery(then:)` (lifting start).
    private static weak var current: WorkoutSessionModel?

    init() {
        let defaults = UserDefaults.standard
        let initialData = defaults.object(forKey: Keys.dataMode) == nil ? true : defaults.bool(forKey: Keys.dataMode)
        var storedPhoneDefinition: WorkoutDefinition? = nil
        if let data = defaults.data(forKey: Keys.phoneDefinition) {
            storedPhoneDefinition = try? JSONDecoder().decode(WorkoutDefinition.self, from: data)
        }
        var initialId = defaults.string(forKey: Keys.definitionId) ?? WorkoutLibrary.partnerWod1.id
        if WorkoutLibrary.definition(id: initialId) == nil && storedPhoneDefinition?.id != initialId {
            initialId = WorkoutLibrary.partnerWod1.id
        }
        var initialDefinition = WorkoutLibrary.definition(id: initialId) ?? WorkoutLibrary.partnerWod1
        if let phone = storedPhoneDefinition, phone.id == initialId,
           WorkoutLibrary.definition(id: initialId) == nil {
            initialDefinition = phone
        }

        dataMode = initialData
        definitionId = initialId
        progress = WorkoutProgress(definition: initialDefinition)
        workout = WorkoutManager()
        recorder = WorkoutMotionRecorder()
        link = PhoneLink.shared
        // All stored properties are initialized now; this one has a default, so it's a setter.
        lastSummary = defaults.string(forKey: Keys.lastSummary)
        phoneDefinition = storedPhoneDefinition
        wireWorkoutCallbacks()
        recorder.onBatchWritten = { [weak self] in
            self?.refreshCounters()
        }
        recorder.onError = { [weak self] message in
            self?.errorMessage = message
        }
        WorkoutSessionModel.current = self
        // A workout the app died in the middle of is saved as incomplete; a Health session
        // that is still active is ended and saved.
        recoverInterruptedWorkout()
        WorkoutManager.recoverInterruptedSession()
    }

    // MARK: - HealthKit manager

    private func wireWorkoutCallbacks() {
        workout.onStateChange = { [weak self] state in
            self?.workoutStateChanged(state)
        }
        workout.onHeartRate = { [weak self] bpm in
            self?.heartRateReceived(bpm)
        }
        workout.onError = { [weak self] message in
            self?.workoutFailed(message)
        }
        workout.onFinished = { [weak self] in
            self?.workoutFinished()
        }
    }

    /// Drops a WorkoutManager that is stuck (never reported back) and makes a fresh one.
    private func replaceWorkoutManager() {
        let old = workout
        old.onStateChange = nil
        old.onHeartRate = nil
        old.onError = nil
        old.onFinished = nil
        // Ask it to end/save whatever it still holds; keep it alive so its HealthKit
        // delegate callbacks (weak references) can still complete.
        old.end()
        retiredManagers.append(old)
        if retiredManagers.count > 3 {
            retiredManagers.removeFirst()
        }
        workout = WorkoutManager()
        wireWorkoutCallbacks()
        workoutLog.error("Replaced the HealthKit workout manager")
    }

    static func activityType(for name: String) -> HKWorkoutActivityType {
        switch name {
        case "mixedCardio": return .mixedCardio
        case "crossTraining": return .crossTraining
        case "functionalStrengthTraining": return .functionalStrengthTraining
        case "highIntensityIntervalTraining": return .highIntensityIntervalTraining
        case "running": return .running
        default: return .crossTraining
        }
    }

    // MARK: - Actions

    func start() {
        guard phase == .idle else { return }
        // Retries a recovery whose result could not be written at launch, before the new
        // workout's checkpoint replaces it.
        recoverInterruptedWorkout()
        resetForStart(definition: selectedDefinition, demo: false)
        // A background recovery (W6) holds a HealthKit session and only one can run: it is
        // stopped (its update sent) first; HealthKit starts once it has ended, at most ~1 s.
        stopBackgroundRecovery(reason: "new workout") { [weak self] in
            self?.startHealthKit()
        }

        startTimeoutTask?.cancel()
        startTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutSessionModel.healthKitStartTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.phase == .starting else { return }
            workoutLog.error("HealthKit not running after timeout; starting without it")
            self.errorMessage = WorkoutSessionModel.noHealthMessage
            self.beginRunning()
        }
    }

    private func startHealthKit() {
        guard phase == .starting, !isDemo else { return }
        if workout.hasSession {
            // Left over from a previous run that never finished: don't let it block us.
            replaceWorkoutManager()
        }
        workout.activityType = WorkoutSessionModel.activityType(for: progress.definition.healthKitActivity)
        workout.locationType = .indoor
        workout.start()
    }

    /// Screen demo: the real workout screen with mock data (WorkoutDemo). Starts at once,
    /// without HealthKit; clock-driven times (timed rests, interval, AMRAP cap) are shortened.
    func startDemo() {
        guard phase == .idle else { return }
        resetForStart(definition: WorkoutDemo.demoDefinition(from: selectedDefinition), demo: true)
        demoHeartRate = WorkoutDemo.HeartRate()
        workoutLog.info("Screen demo: \(self.progress.definition.id, privacy: .public)")
        beginRunning()
    }

    /// Clears the session state and enters `.starting` with `definition`.
    private func resetForStart(definition: WorkoutDefinition, demo: Bool) {
        isDemo = demo
        workoutId = UUID()
        progress = WorkoutProgress(definition: definition)
        heartRates = []
        pedometerSamples = []
        latestPedometer = nil
        heartRate = nil
        lastChangeDate = nil
        errorMessage = nil
        healthKitRunning = false
        isRecordingCSV = false
        motionSamples = 0
        csvBytes = 0
        marksCount = 0
        partialReps = nil
        forTimeCapAnnouncedDate = nil
        finalized = false
        autoSuppressedStart = nil
        capSuppressed = false
        countdownTarget = nil
        countdownLastBeep = nil
        lastResultInput = nil
        pendingRecovery = nil
        resetRecovery()
        phase = .starting
    }

    /// Next segment (finishes on the last one). Returns true if something changed.
    @discardableResult
    func advance(source: AdvanceSource) -> Bool {
        guard phase == .running else { return false }
        let t = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        guard progress.advance(at: t, source: source) else { return false }
        if progress.isFinished {
            play(.success)
            recorder.appendEvent(atUptime: uptime,
                                 description: "name=finish index=\(progress.currentIndex) source=\(source.rawValue)")
        } else {
            let kind = progress.currentSegment?.kind ?? .station
            // "Go" after a timed rest is always the strong haptic.
            play(kind == .run || source == .auto ? .start : .directionUp)
            recorder.appendEvent(atUptime: uptime,
                                 description: "name=segment index=\(progress.currentIndex) kind=\(kind.rawValue) source=\(source.rawValue)")
        }
        lastChangeDate = Date()
        persistProgress()
        workoutLog.info("advance (\(source.rawValue, privacy: .public)) -> \(self.progress.currentIndex) finished \(self.progress.isFinished)")
        return true
    }

    /// The clock's change: like `advance(source: .auto)`, but in an interval workout a work
    /// segment still running at the minute mark jumps to the next set (the rest in between is
    /// recorded as 0 s), and the last set finishes on its minute. One "go" haptic.
    @discardableResult
    func clockAdvance() -> Bool {
        guard phase == .running else { return false }
        let t = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        guard progress.autoAdvance(at: t) else { return false }
        if progress.isFinished {
            play(.success)
            recorder.appendEvent(atUptime: uptime,
                                 description: "name=finish index=\(progress.currentIndex) source=auto")
        } else {
            let kind = progress.currentSegment?.kind ?? .station
            play(.start)
            recorder.appendEvent(atUptime: uptime,
                                 description: "name=segment index=\(progress.currentIndex) kind=\(kind.rawValue) source=auto")
        }
        lastChangeDate = Date()
        lastAutoAdvanceDate = Date()
        persistProgress()
        workoutLog.info("clock advance -> \(self.progress.currentIndex) finished \(self.progress.isFinished)")
        return true
    }

    /// Back one segment, or un-finish. Returns true if something changed.
    @discardableResult
    func undo(source: AdvanceSource) -> Bool {
        guard phase == .running else { return false }
        let t = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        let wasFinished = progress.isFinished
        guard progress.undo(at: t, source: source) else { return false }
        play(.directionDown)
        if let auto = progress.autoAdvanceTime(), auto <= t {
            autoSuppressedStart = progress.segmentStarts.last
        }
        if let cap = progress.capTime, cap <= t {
            capSuppressed = true
        }
        if wasFinished {
            // The reps belonged to the cap finish; the athlete re-enters them if it finishes again.
            partialReps = nil
        }
        let name = wasFinished ? "unfinish" : "undo"
        recorder.appendEvent(atUptime: uptime,
                             description: "name=\(name) index=\(progress.currentIndex) source=\(source.rawValue)")
        lastChangeDate = Date()
        persistProgress()
        workoutLog.info("undo (\(source.rawValue, privacy: .public)) -> \(self.progress.currentIndex)")
        return true
    }

    // MARK: - Partial reps (WORKOUT_SPEC §5)

    /// Finished by the AMRAP time cap (the last finish event came from the clock).
    var isFinishedByCap: Bool {
        guard progress.isFinished, progress.capTime != nil,
              let last = progress.events.last(where: { (e: WorkoutEvent) -> Bool in e.kind == .finish }) else {
            return false
        }
        return last.source == .auto
    }

    /// The segment the cap cut (asked "Reps of <name>?"), nil when there is nothing to ask.
    /// AMRAP: the segment the cap finished in. For time finished past the cap: the segment
    /// running at the cap (`repsAtCapSegment`).
    var partialRepsSegment: WorkoutSegment? {
        if isFinishedByCap {
            guard let segment = progress.currentSegment, segment.kind != .rest else { return nil }
            return segment
        }
        return repsAtCapSegment
    }

    /// For time finished past the cap (§5b, W7): the segment running at the cap when it counts
    /// reps (asked "Reps of <name> at the cap?"); nil for a run, a rest, a metre or time target,
    /// or when the workout finished under the cap.
    var repsAtCapSegment: WorkoutSegment? {
        guard progress.isFinished, let finish = progress.finishTime,
              let i = progress.capSegmentIndex(now: finish),
              i >= 0, i < progress.definition.segments.count else { return nil }
        let segment: WorkoutSegment = progress.definition.segments[i]
        if segment.kind == .rest || segment.kind == .run { return nil }
        if let target = segment.target, target.unit == .meters || target.unit == .seconds { return nil }
        return segment
    }

    /// The picker asks about the for-time cap (title "… at the cap?"), not an AMRAP cut.
    var asksRepsAtCap: Bool {
        return !isFinishedByCap && repsAtCapSegment != nil
    }

    /// The done screen shows the reps picker (it then owns the Digital Crown).
    var asksPartialReps: Bool {
        return phase == .running && partialRepsSegment != nil
    }

    /// Picker range 0…partialRepsMax: the segment's reps target, else 200.
    var partialRepsMax: Int {
        if let target = partialRepsSegment?.target, target.unit == .reps, target.value >= 1 {
            return Int(target.value.rounded())
        }
        return 200
    }

    /// Stores the reps (clamped to 0…partialRepsMax) and logs `name=partialReps reps=<n>` in
    /// the CSV. Can be called again until End; the last value wins.
    func savePartialReps(_ reps: Int) {
        guard phase == .running, partialRepsSegment != nil else { return }
        let value: Int = min(max(0, reps), partialRepsMax)
        partialReps = value
        let name: String = asksRepsAtCap ? "repsAtCap" : "partialReps"
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: "name=\(name) reps=\(value)")
        play(.click)
        saveCheckpoint()
        workoutLog.info("partial reps saved: \(value)")
    }

    /// Mark line in the CSV (Data mode only).
    func mark() {
        if let n = recorder.addMark(label: "mark") {
            marksCount = n
            WKInterfaceDevice.current().play(.click)
        } else {
            WKInterfaceDevice.current().play(.failure)
        }
    }

    /// Ends the workout: result + CSV first, then HealthKit. Works without HealthKit.
    /// After the finish with less than `recoverySeconds` recorded, a background recovery
    /// follows once HealthKit has saved (W6, `backgroundRecoveryEnd`).
    func end() {
        if isDemo {
            // Nothing to save or send: straight back to the start screen.
            if phase == .starting || phase == .running {
                workoutLog.info("Screen demo ended")
                goIdle()
            }
            return
        }
        switch phase {
        case .starting, .running:
            let until: Double? = backgroundRecoveryEnd(now: Date().timeIntervalSince1970)
            if until != nil {
                // Logged before the CSV closes; the HR after End is not in the CSV.
                recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                                     description: "name=backgroundRecovery")
            }
            endNow()
            if let until = until, let input = lastResultInput {
                pendingRecovery = BackgroundRecovery(input: input, until: until)
            }
        case .idle, .ending:
            break
        }
    }

    /// Finalizes (result + CSV) and ends HealthKit.
    private func endNow() {
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        finalize()
        phase = .ending
        armEndTimeout()
        workout.end()     // calls onFinished right away if there is no HK session
    }

    // MARK: - Running

    private func beginRunning() {
        guard phase == .starting else { return }
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        let t = Date().timeIntervalSince1970
        progress.start(at: t)
        phase = .running

        if isDemo {
            startClock()
            startDemoTicker()
            play(progress.currentSegment?.kind == .run ? .start : .directionUp)
            return
        }
        if dataMode {
            recorder.start(sessionId: workoutId, definitionId: progress.definition.id)
            isRecordingCSV = true
        }
        let kind = progress.currentSegment?.kind ?? .station
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: "name=segment index=0 kind=\(kind.rawValue) source=start")
        persistProgress()
        startClock()
        startPedometer(from: Date(timeIntervalSince1970: t))
        play(kind == .run ? .start : .directionUp)
        workoutLog.info("Workout started: \(self.progress.definition.id, privacy: .public), HK \(self.healthKitRunning), data \(self.dataMode)")
    }

    // MARK: - Clock (timed rests, AMRAP cap, for-time cap announcement)

    /// The next automatic change, if any: a timed rest ending (advance) or the AMRAP cap
    /// (finish), whichever comes first.
    func nextClockEvent() -> (time: Double, isFinish: Bool)? {
        guard phase == .running, progress.isStarted, !progress.isFinished else { return nil }
        var best: (time: Double, isFinish: Bool)? = nil
        if let t = progress.autoAdvanceTime(), progress.segmentStarts.last != autoSuppressedStart {
            best = (time: t, isFinish: false)
        }
        if let cap = progress.capTime, !capSuppressed {
            if let current = best {
                if cap <= current.time { best = (time: cap, isFinish: true) }
            } else {
                best = (time: cap, isFinish: true)
            }
        }
        return best
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self = self else { return }
                if self.phase != .running { return }
                self.clockTick()
            }
        }
    }

    private func clockTick() {
        if ProcessInfo.processInfo.systemUptime - lastCheckpointUptime >= WorkoutSessionModel.checkpointInterval {
            saveCheckpoint()
        }
        updateRecovery(now: Date().timeIntervalSince1970)
        checkForTimeCap(now: Date().timeIntervalSince1970)
        guard let event = nextClockEvent() else {
            countdownTarget = nil
            return
        }
        if countdownTarget != event.time {
            countdownTarget = event.time
            countdownLastBeep = nil
        }
        let remaining = event.time - Date().timeIntervalSince1970
        if remaining <= 0 {
            countdownTarget = nil
            if event.isFinish {
                finishByCap()
            } else {
                _ = clockAdvance()
            }
            return
        }
        // Ready, set, go: one tap at 3, 2 and 1 s; the advance itself plays the "go".
        let second = Int(remaining.rounded(.up))
        if second >= 1 && second <= 3 && countdownLastBeep != second {
            countdownLastBeep = second
            // Felt mid-effort (a .click was too light to notice during double unders).
            play(.directionUp)
        }
    }

    private func finishByCap() {
        let t = Date().timeIntervalSince1970
        guard progress.finish(at: t, source: .auto) else { return }
        playTimeHaptic()
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: "name=finish index=\(progress.currentIndex) source=auto")
        lastChangeDate = Date()
        lastAutoAdvanceDate = Date()
        persistProgress()
        workoutLog.info("time cap reached at segment \(self.progress.currentIndex)")
    }

    /// "Time!": a strong, unmistakable pattern (stop ×3, then success), since a single
    /// tap was missed mid-movement on 2026-10-30. AMRAP cap and for-time cap.
    private func playTimeHaptic() {
        play(.stop)
        Task { @MainActor in
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 650_000_000)
                WKInterfaceDevice.current().play(.stop)
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            WKInterfaceDevice.current().play(.success)
        }
    }

    /// For time with a cap (§5b, W7): once the cap passes while the workout runs, the "Time!"
    /// haptic, the banner (`forTimeCapAnnouncedDate`) and `name=capReached` in the CSV. The
    /// workout keeps going: nothing finishes, the total keeps counting. Announced once per
    /// workout (an undo of the finish after the cap does not repeat it).
    private func checkForTimeCap(now t: Double) {
        guard forTimeCapAnnouncedDate == nil, progress.isStarted, !progress.isFinished,
              let cap = progress.forTimeCapTime, t >= cap else { return }
        forTimeCapAnnouncedDate = Date()
        playTimeHaptic()
        let index: Int = progress.segmentIndex(at: cap) ?? progress.currentIndex
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: "name=capReached index=\(index)")
        workoutLog.info("for-time cap reached at segment \(index); keep going")
    }

    // MARK: - HealthKit callbacks

    private func workoutStateChanged(_ state: HKWorkoutSessionState) {
        // A demo has no HealthKit session; a leftover manager must not end or save it.
        // A late .running (e.g. a slow start from an earlier real workout) is still ended,
        // as it would be when idle, so no zombie HealthKit workout runs behind the demo.
        if isDemo {
            workoutLog.info("HealthKit state \(state.rawValue) ignored during screen demo")
            if state == .running {
                workout.end()
            }
            return
        }
        switch state {
        case .running:
            if phase == .idle || phase == .ending {
                // Session came up after we already ended (e.g. a slow authorization):
                // don't leave a zombie workout running.
                workoutLog.error("HealthKit session running while \(String(describing: self.phase), privacy: .public); ending it")
                workout.end()
                return
            }
            healthKitRunning = true
            if errorMessage == WorkoutSessionModel.noHealthMessage {
                errorMessage = nil
            }
            if phase == .starting {
                beginRunning()
            }
        case .ended:
            let wasRunning = healthKitRunning
            healthKitRunning = false
            // Only a session that actually ran counts as "ended by the system"; an .ended
            // from tearing down a session that failed to start must not end our workout.
            if wasRunning && (phase == .running || phase == .starting) {
                // Ended by the system (not by us): save what we have.
                workoutLog.error("HealthKit session ended by the system; saving")
                startTimeoutTask?.cancel()
                startTimeoutTask = nil
                errorMessage = "Workout ended by watch"
                finalize()
                phase = .ending
                armEndTimeout()
                // WorkoutManager saves the builder itself on .ended and then calls onFinished.
            }
        default:
            break
        }
    }

    private func workoutFailed(_ message: String) {
        workoutLog.error("HealthKit error: \(message, privacy: .public)")
        errorMessage = message
        if phase == .starting {
            // Don't make the athlete wait or retry: time the workout without HealthKit.
            beginRunning()
        }
    }

    private func workoutFinished() {
        // WorkoutManager also calls this after tearing down a session that failed to start;
        // that must not end a workout that is running without HealthKit.
        healthKitRunning = false
        guard phase == .ending else { return }
        goIdle()
        if let recovery = pendingRecovery {
            pendingRecovery = nil
            startBackgroundRecovery(recovery)
        }
    }

    private func armEndTimeout() {
        endTimeoutTask?.cancel()
        endTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutSessionModel.endTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.phase == .ending else { return }
            workoutLog.error("HealthKit did not finish in time; going idle anyway")
            // HealthKit is stuck: no second session for the recovery (the result at End stands).
            self.pendingRecovery = nil
            self.replaceWorkoutManager()
            self.goIdle()
        }
    }

    private func goIdle() {
        endTimeoutTask?.cancel()
        endTimeoutTask = nil
        clockTask?.cancel()
        clockTask = nil
        demoTask?.cancel()
        demoTask = nil
        // Nothing was started: no checkpoint is needed. (A started workout's checkpoint is
        // cleared once its result is written; a demo never has one.)
        if !isDemo && !progress.isStarted {
            WorkoutCheckpoint.clear()
        }
        phase = .idle
        heartRate = nil
        healthKitRunning = false
        isDemo = false
    }

    // MARK: - Screen demo

    /// Fake HR once a second while the demo runs.
    private func startDemoTicker() {
        demoTask?.cancel()
        demoTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                if self.phase != .running || !self.isDemo { return }
                self.demoTick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func demoTick() {
        let kind: SegmentKind? = progress.isFinished ? SegmentKind.rest : progress.currentSegment?.kind
        let t: Double = Date().timeIntervalSince1970
        let bpm: Double = demoHeartRate.step(now: t, kind: kind)
        heartRate = bpm
        // Kept like real samples so the done screen's recovery drop works in the demo too
        // (a demo never builds or sends a result).
        heartRates.append(HeartRateSample(t: t, bpm: bpm))
    }

    private func heartRateReceived(_ bpm: Double) {
        if isDemo { return }
        heartRate = bpm
        guard phase == .running, !finalized else { return }
        let t = Date().timeIntervalSince1970
        heartRates.append(HeartRateSample(t: t, bpm: bpm))
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: String(format: "name=hr bpm=%.0f", bpm))
    }

    // MARK: - Recovery (WORKOUT_SPEC §6)

    /// Seconds since the finish while the done screen is up (before End), else nil.
    func recoveryElapsed(now: Date) -> Double? {
        guard phase == .running, let finish = progress.finishTime else { return nil }
        return max(0, now.timeIntervalSince1970 - finish)
    }

    /// HR now minus HR at the finish is shown as "−19"; this is finish − current (positive = down).
    var recoveryDrop: Double? {
        guard let base = recoveryFinishHeartRate, let current = heartRate else { return nil }
        return base - current
    }

    private func resetRecovery() {
        recoveryFinishKey = nil
        recoveryMarksPlayed = 0
        recoveryFinishHeartRateFinal = false
        if recoveryFinishHeartRate != nil {
            recoveryFinishHeartRate = nil
        }
    }

    /// Called from the clock (5×/s) while running: finish HR, and a light haptic at 1:00 and
    /// 2:00, success at 3:00 after the finish. Never ends the workout.
    private func updateRecovery(now: Double) {
        guard let finish = progress.finishTime else {
            if recoveryFinishKey != nil { resetRecovery() }
            return
        }
        if recoveryFinishKey != finish {
            // New finish (or a finish again after Undo): start over.
            resetRecovery()
            recoveryFinishKey = finish
        }
        let elapsed: Double = now - finish
        if !recoveryFinishHeartRateFinal {
            let value: Double? = finishHeartRate(finish: finish, now: now)
            if value != recoveryFinishHeartRate {
                recoveryFinishHeartRate = value
            }
            if elapsed >= WorkoutSessionModel.recoveryFinishSettleSeconds {
                recoveryFinishHeartRateFinal = true
            }
        }
        var crossed: Int = 0
        for mark in HeartRateRecovery.markSeconds where elapsed >= mark {
            crossed += 1
        }
        if crossed > recoveryMarksPlayed {
            // Only the latest mark plays (e.g. after a long suspension, not three in a row).
            recoveryMarksPlayed = crossed
            let isLast: Bool = crossed >= HeartRateRecovery.markSeconds.count
            play(isLast ? .success : .click)
            let seconds: Int = Int(HeartRateRecovery.markSeconds[crossed - 1])
            let bpm: Double = heartRate ?? -1
            recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                                 description: String(format: "name=recovery seconds=%d bpm=%.0f", seconds, bpm))
            workoutLog.info("recovery \(seconds) s, HR \(bpm)")
        }
    }

    /// HR at the finish by the kit's rule (HeartRateRecovery.finishHeartRate) on the samples
    /// near the finish, on the same 5 s grid as the result (from the workout start).
    private func finishHeartRate(finish: Double, now: Double) -> Double? {
        guard let startT = progress.startTime else { return nil }
        let windowStart: Double = finish - HeartRateRecovery.finishWindow - 30.0
        var near: [TimedValue] = []
        for s in heartRates where s.t >= windowStart && s.t <= now {
            near.append(TimedValue(t: s.t, value: s.bpm))
        }
        if near.isEmpty { return nil }
        let end: Double = min(now, finish + WorkoutSessionModel.recoveryFinishSettleSeconds)
        if !(end > startT) { return nil }
        let series: HeartRateSeries = HeartRateSeries.make(samples: near, start: startT, end: end)
        return HeartRateRecovery.finishHeartRate(series: series, finish: finish)
    }

    // MARK: - Background recovery after End (W6, WORKOUT_SPEC §6)

    /// finish + `recoverySeconds` when End now should be followed by a background recovery,
    /// else nil: not finished (abandoned), no HealthKit session (no HR to record), or less than
    /// `backgroundRecoveryMinimumSeconds` left.
    private func backgroundRecoveryEnd(now: Double) -> Double? {
        guard phase == .running, progress.isFinished, healthKitRunning,
              let finish = progress.finishTime else { return nil }
        let until: Double = finish + WorkoutSessionModel.recoverySeconds
        return until - now >= WorkoutSessionModel.backgroundRecoveryMinimumSeconds ? until : nil
    }

    /// Starts the unsaved HealthKit session that records HR until `recovery.until`. Runs after
    /// the workout's own session has ended and saved (one session at a time).
    private func startBackgroundRecovery(_ recovery: BackgroundRecovery) {
        let now: Double = Date().timeIntervalSince1970
        guard recovery.until - now >= WorkoutSessionModel.backgroundRecoveryMinimumSeconds else { return }
        if let old = recoveryManager {
            // Shouldn't happen (a recovery is stopped before anything else starts).
            retireRecoveryManager(old)
        }
        let manager = WorkoutManager()
        manager.activityType = .other
        manager.locationType = .indoor
        manager.saveWorkoutOnEnd = false
        manager.onHeartRate = { [weak self] bpm in
            self?.backgroundHeartRateReceived(bpm)
        }
        manager.onStateChange = { [weak self, weak manager] state in
            guard let self = self, let manager = manager else { return }
            self.backgroundStateChanged(state, manager: manager)
        }
        manager.onError = { message in
            workoutLog.error("background recovery HealthKit error: \(message, privacy: .public)")
        }
        manager.onFinished = { [weak self, weak manager] in
            guard let self = self, let manager = manager else { return }
            self.backgroundManagerFinished(manager)
        }
        recoveryManager = manager
        backgroundRecovery = recovery
        backgroundRecoveryFinish = recovery.input.progress.finishTime.map { Date(timeIntervalSince1970: $0) }
        manager.start()

        let wait: Double = max(0, recovery.until - now)
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            self?.stopBackgroundRecovery(reason: "recovery recorded")
        }
        workoutLog.info("background recovery: recording HR for \(wait) s")
    }

    private func backgroundHeartRateReceived(_ bpm: Double) {
        guard var recovery = backgroundRecovery else { return }
        let t: Double = Date().timeIntervalSince1970
        if t > recovery.until {
            stopBackgroundRecovery(reason: "recovery recorded")
            return
        }
        recovery.input.heartRates.append(TimedValue(t: t, value: bpm))
        backgroundRecovery = recovery
    }

    private func backgroundStateChanged(_ state: HKWorkoutSessionState, manager: WorkoutManager) {
        switch state {
        case .running:
            if manager !== recoveryManager || backgroundRecovery == nil {
                // Came up after the recovery was stopped: end it, nothing is saved.
                workoutLog.error("background recovery session running after stop; ending it")
                manager.saveWorkoutOnEnd = false
                manager.end()
            }
        case .ended:
            if manager === recoveryManager && backgroundRecovery != nil {
                // Ended by the system (e.g. another workout app): send what was recorded.
                stopBackgroundRecovery(reason: "HealthKit session ended")
            }
        default:
            break
        }
    }

    private func backgroundManagerFinished(_ manager: WorkoutManager) {
        guard manager === recoveryManager else { return }
        recoveryManager = nil
        retireRecoveryManager(manager)
        if backgroundRecovery != nil {
            // The session never ran or ended early: send what was recorded.
            stopBackgroundRecovery(reason: "HealthKit session over")
        }
        flushRecoveryWaiters()
    }

    /// Kept alive (with its callbacks) so a session that still comes up late is ended.
    private func retireRecoveryManager(_ manager: WorkoutManager) {
        retiredManagers.append(manager)
        if retiredManagers.count > 3 {
            retiredManagers.removeFirst()
        }
    }

    /// Stops the background recovery, if any: sends the updated result with the HR recorded so
    /// far, then ends its HealthKit session (discarded). `then` runs once that session has
    /// ended, or after `backgroundRecoveryStopWait` at the latest; at once when there is none.
    func stopBackgroundRecovery(reason: String, then: MainAction? = nil) {
        recoveryTask?.cancel()
        recoveryTask = nil
        // Not started yet (End still saving): a session started now (lifting) must not be
        // followed by a recovery session that would take HealthKit from it.
        pendingRecovery = nil
        if let recovery = backgroundRecovery {
            backgroundRecovery = nil
            backgroundRecoveryFinish = nil
            workoutLog.info("background recovery stopped: \(reason, privacy: .public)")
            let stopT: Double = min(Date().timeIntervalSince1970, recovery.until)
            sendRecoveryUpdate(recovery, stopT: stopT)
        }
        if let manager = recoveryManager {
            manager.saveWorkoutOnEnd = false
            // Without a session this calls onFinished at once (→ backgroundManagerFinished).
            manager.end()
        }
        guard let then = then else { return }
        if recoveryManager == nil {
            then()
            return
        }
        recoveryWaiters.append(then)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutSessionModel.backgroundRecoveryStopWait * 1_000_000_000))
            self?.flushRecoveryWaiters()
        }
    }

    private func flushRecoveryWaiters() {
        if recoveryWaiters.isEmpty { return }
        let waiters: [MainAction] = recoveryWaiters
        recoveryWaiters = []
        for waiter in waiters {
            waiter()
        }
    }

    /// The same workout again (same id) with the HR series and `endDate` running to `stopT`.
    /// Skipped when no HR arrived after End (the first result already has everything).
    private func sendRecoveryUpdate(_ recovery: BackgroundRecovery, stopT: Double) {
        let endT: Double = recovery.input.endT
        guard recovery.input.heartRates.contains(where: { (s: TimedValue) -> Bool in s.t > endT }),
              stopT > endT else {
            workoutLog.info("background recovery: no HR after End, no update")
            return
        }
        let result: WorkoutResult = WorkoutSessionModel.makeResult(recovery.input, recordingEndT: stopT)
        // Its own file name: the result sent at End may still be waiting in the outbox under
        // workout-<id>.json (deleted once delivered). The phone files it by the id inside.
        _ = writeAndSend(result, fileName: "workout-\(UUID().uuidString).json")
        workoutLog.info("background recovery: update sent, \(stopT - endT) s after End")
    }

    /// Lifting (SessionModel.start) calls this before starting its HealthKit session: stops a
    /// workout's background recovery (W6) and runs `then` once its session has ended (≤ ~1 s),
    /// or at once when there is none.
    static func endBackgroundRecovery(then: @escaping @MainActor () -> Void) {
        guard let model = current else {
            then()
            return
        }
        model.stopBackgroundRecovery(reason: "lifting session", then: then)
    }

    // MARK: - Pedometer

    private func startPedometer(from date: Date) {
        guard CMPedometer.isStepCountingAvailable() else {
            workoutLog.error("Step counting not available")
            return
        }
        let p = CMPedometer()
        pedometer = p
        p.startUpdates(from: date) { [weak self] data, error in
            // Arrives on a background queue: copy plain values, then hop to main.
            if let error = error {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        workoutLog.error("Pedometer error: \(message, privacy: .public)")
                    }
                }
                return
            }
            guard let data = data else { return }
            let snapshot = PedometerSnapshot(t: data.endDate.timeIntervalSince1970,
                                             steps: data.numberOfSteps.doubleValue,
                                             distance: data.distance?.doubleValue,
                                             paceSecondsPerMeter: data.currentPace?.doubleValue,
                                             cadenceStepsPerSecond: data.currentCadence?.doubleValue)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.pedometerReceived(snapshot)
                }
            }
        }
    }

    private func stopPedometer() {
        pedometer?.stopUpdates()
        pedometer = nil
    }

    private func pedometerReceived(_ s: PedometerSnapshot) {
        guard phase == .running, !finalized else { return }
        if let last = pedometerSamples.last, s.t < last.t { return }
        pedometerSamples.append(s)
        latestPedometer = s
        let distance: Double = s.distance ?? -1
        let cadence: Double = s.cadenceStepsPerSecond.map { $0 * 60.0 } ?? -1
        let pace: Double = s.paceSecondsPerMeter.map { $0 * 1000.0 } ?? -1
        recorder.appendEvent(atUptime: recorder.uptime(forEpoch: s.t),
                             description: String(format: "name=pedometer steps=%.0f distance=%.1f cadence=%.1f pace=%.1f",
                                                 s.steps, distance, cadence, pace))
    }

    /// Cumulative pedometer distance at `t` (linear; before the first sample linear from
    /// (workout start, 0); after the last sample the last value). Nil without distance data.
    private func cumulativeDistance(at t: Double) -> Double? {
        let samples = pedometerSamples.filter { $0.distance != nil }
        guard let first = samples.first, let firstDistance = first.distance else { return nil }
        let start = progress.startTime ?? first.t
        if t <= first.t {
            let span = first.t - start
            guard span > 0 else { return 0 }
            return max(0, firstDistance * (t - start) / span)
        }
        var previous = first
        for s in samples.dropFirst() {
            if t <= s.t {
                let d0 = previous.distance ?? 0
                let d1 = s.distance ?? d0
                let span = s.t - previous.t
                guard span > 0 else { return d1 }
                return d0 + (d1 - d0) * (t - previous.t) / span
            }
            previous = s
        }
        return previous.distance
    }

    /// Run line for the current segment (nil when not on a run segment).
    func runLine(now: Date) -> RunLine? {
        guard phase == .running, progress.isStarted, !progress.isFinished,
              let segment = progress.currentSegment, segment.kind == .run,
              let segmentStart = progress.segmentStarts.last else { return nil }
        if isDemo {
            let nowDemo: Double = now.timeIntervalSince1970
            return WorkoutDemo.runLine(segment: segment, elapsed: progress.segmentElapsed(now: nowDemo), now: nowDemo)
        }
        var line = RunLine(distance: nil, paceSecondsPerKm: nil, cadence: nil)
        if let latest = latestPedometer, let latestDistance = latest.distance,
           let atStart = cumulativeDistance(at: segmentStart) {
            line.distance = max(0, latestDistance - atStart)
        }
        let nowT = now.timeIntervalSince1970
        if let latest = latestPedometer, nowT - latest.t <= WorkoutSessionModel.liveMetricMaxAge, latest.t >= segmentStart {
            if let pace = latest.paceSecondsPerMeter, pace > 0 {
                line.paceSecondsPerKm = pace * 1000.0
            }
            if let cadence = latest.cadenceStepsPerSecond, cadence > 0 {
                line.cadence = cadence * 60.0
            }
        }
        if line.paceSecondsPerKm == nil, let d = line.distance, d > 50 {
            let elapsed = progress.segmentElapsed(now: nowT)
            if elapsed > 0 {
                line.paceSecondsPerKm = elapsed / (d / 1000.0)
            }
        }
        return line
    }

    // MARK: - End / result

    /// Stops sensors, closes the CSV, builds/writes/sends the result, then the CSV.
    /// Runs once per workout.
    private func finalize() {
        // Belt and braces: a demo never writes, sends or summarizes anything.
        guard !isDemo else { return }
        guard !finalized else { return }
        finalized = true
        stopPedometer()
        let csvURL = recorder.stop()
        refreshCounters()

        let endT = Date().timeIntervalSince1970
        if progress.isStarted {
            progress.recordEnd(at: endT)
            persistProgress()
            sendResult(endT: endT, recordedCSV: csvURL != nil)
        }
        if let csvURL = csvURL {
            link.sendFile(csvURL, metadata: PhoneLink.sessionCSVMetadata(sessionId: workoutId.uuidString))
        }
    }

    private func sendResult(endT: Double, recordedCSV: Bool) {
        let hr: [TimedValue] = heartRates.map { TimedValue(t: $0.t, value: $0.bpm) }
        let input = ResultInput(id: workoutId, progress: progress, heartRates: hr,
                                pedometer: pedometerSamples,
                                partialReps: progress.isFinished ? partialReps : nil,
                                recordedCSV: recordedCSV, endT: endT)
        lastResultInput = input
        let result: WorkoutResult = WorkoutSessionModel.makeResult(input, recordingEndT: endT)

        let summary = "\(result.definition.shortName) · \(SessionModel.formatElapsed(result.totalSeconds))"
        lastSummary = summary
        UserDefaults.standard.set(summary, forKey: Keys.lastSummary)

        if writeAndSend(result, fileName: "workout-\(workoutId.uuidString).json") {
            WorkoutCheckpoint.clear()
        } else {
            let failed = "\(summary) · not saved"
            lastSummary = failed
            UserDefaults.standard.set(failed, forKey: Keys.lastSummary)
        }
    }

    // MARK: - Crash checkpoint

    /// Writes the crash checkpoint (file, off the main thread). Called with every
    /// `persistProgress()` and about every `checkpointInterval` from the clock, so the HR
    /// series and `savedAt` stay fresh. Never for the screen demo, and not once End has begun
    /// (the result itself is the record from then on).
    private func saveCheckpoint() {
        guard !isDemo, !finalized, progress.isStarted else { return }
        lastCheckpointUptime = ProcessInfo.processInfo.systemUptime
        let hr: [TimedValue] = heartRates.map { (s: HeartRateSample) -> TimedValue in
            TimedValue(t: s.t, value: s.bpm)
        }
        let checkpoint = WorkoutCheckpoint(workoutId: workoutId,
                                           progress: progress,
                                           heartRates: hr,
                                           pedometer: pedometerSamples,
                                           partialReps: partialReps,
                                           recordedCSV: isRecordingCSV,
                                           savedAt: Date().timeIntervalSince1970)
        WorkoutCheckpoint.save(checkpoint)
    }

    /// At launch: a checkpoint left behind means the app died mid-workout. Its result is
    /// built like an early End at `savedAt` (no finish time unless the athlete had finished),
    /// written as `workout-<id>.json` and queued for the phone, then the checkpoint is
    /// deleted. If the file cannot be written the checkpoint stays for the next launch.
    /// The debug CSV (`session-<id>.csv`) is moved to the outbox by `PhoneLink.activate()`.
    private func recoverInterruptedWorkout() {
        guard phase == .idle, !isDemo else { return }
        guard let checkpoint = WorkoutCheckpoint.load() else { return }
        guard checkpoint.progress.isStarted else {
            WorkoutCheckpoint.clear()
            return
        }
        let fileName = "workout-\(checkpoint.workoutId.uuidString).json"
        let outboxFile: URL = WatchFiles.outbox.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: outboxFile.path) {
            // The normal End got as far as writing the full result: keep that one.
            workoutLog.info("Checkpoint ignored: result \(fileName, privacy: .public) already written")
            WorkoutCheckpoint.clear()
            return
        }
        var recovered: WorkoutProgress = checkpoint.progress
        let startT: Double = recovered.startTime ?? checkpoint.savedAt
        let endT: Double = max(checkpoint.savedAt, startT)
        recovered.recordEnd(at: endT)
        let input = ResultInput(id: checkpoint.workoutId, progress: recovered,
                                heartRates: checkpoint.heartRates,
                                pedometer: checkpoint.pedometer,
                                partialReps: recovered.isFinished ? checkpoint.partialReps : nil,
                                recordedCSV: checkpoint.recordedCSV, endT: endT)
        let result: WorkoutResult = WorkoutSessionModel.makeResult(input, recordingEndT: endT)
        if writeAndSend(result, fileName: fileName) {
            let summary = "\(result.definition.shortName) · \(SessionModel.formatElapsed(result.totalSeconds)) · saved after interruption"
            lastSummary = summary
            UserDefaults.standard.set(summary, forKey: Keys.lastSummary)
            WorkoutCheckpoint.clear()
            workoutLog.info("Recovered an interrupted workout: \(result.segments.count) segments")
        }
    }

    /// The WorkoutResult for `input`. Splits, HR average / max and the end event belong to the
    /// End press (`input.endT`); the HR series and `endDate` run to `recordingEndT` (the End
    /// press, or later for the update after a background recovery, W6).
    private static func makeResult(_ input: ResultInput, recordingEndT: Double) -> WorkoutResult {
        let p: WorkoutProgress = input.progress
        let definition = p.definition
        let endT: Double = input.endT
        let startT = p.startTime ?? endT
        let finishT = p.finishTime
        let total = (finishT ?? endT) - startT

        let hr: [TimedValue] = input.heartRates
        let workoutHR: [TimedValue] = hr.filter { (s: TimedValue) -> Bool in s.t <= endT }
        let steps: [PedometerSample] = input.pedometer.map {
            PedometerSample(t: $0.t, steps: $0.steps, distance: $0.distance)
        }
        let segments = SplitStats.compute(progress: p, now: endT, heartRates: workoutHR, pedometer: steps)

        // Average / max of the workout part only (start → finish, or end): HR after the finish
        // is recovery (WORKOUT_SPEC §6) and would pull the average down.
        let workoutEndT: Double = finishT ?? endT
        var hrSum = 0.0
        var hrCount = 0
        var hrMax: Double?
        for s in hr where s.t >= startT && s.t <= workoutEndT {
            hrSum += s.value
            hrCount += 1
            hrMax = max(hrMax ?? s.value, s.value)
        }
        let hrAvg: Double? = hrCount > 0 ? hrSum / Double(hrCount) : nil
        // HR every 5 s from the start to the end of the recording (not the finish): the part
        // after the finish is the recovery the phone shows (HeartRateRecovery). Nil when no HR
        // arrived at all.
        let seriesEndT: Double = max(endT, recordingEndT)
        let hrSeries: HeartRateSeries? = hr.isEmpty ? nil
            : HeartRateSeries.make(samples: hr, start: startT, end: seriesEndT)

        var result = WorkoutResult(version: WorkoutResult.currentVersion,
                                   id: input.id,
                                   definition: definition,
                                   startDate: Date(timeIntervalSince1970: startT),
                                   finishDate: finishT.map { Date(timeIntervalSince1970: $0) },
                                   endDate: Date(timeIntervalSince1970: seriesEndT),
                                   totalSeconds: total,
                                   segments: segments,
                                   events: p.events,
                                   heartRateAvg: hrAvg,
                                   heartRateMax: hrMax,
                                   recordingFileName: input.recordedCSV ? "session-\(input.id.uuidString).csv" : nil,
                                   heartRateSeries: hrSeries)
        if p.isFinished, let reps = input.partialReps {
            // Entered on the watch: not an edit, so editedAt stays nil. For time past the cap
            // the picker asked the reps at the cap (§5b); AMRAP: the reps of the cut segment.
            if result.isCapped {
                result.repsAtCap = min(max(0, reps), result.repsAtCapLimit ?? reps)
            } else {
                result.partialReps = min(max(0, reps), result.partialRepsLimit ?? reps)
            }
        }
        return result
    }

    /// Writes `result` to the outbox as `fileName` and queues it for the phone.
    private func writeAndSend(_ result: WorkoutResult, fileName: String) -> Bool {
        let url = WatchFiles.outbox.appendingPathComponent(fileName)
        do {
            let data = try result.encoded()
            try data.write(to: url, options: .atomic)
            link.sendFile(url, metadata: PhoneLink.workoutResultMetadata(id: result.id.uuidString))
            workoutLog.info("Workout result written: \(result.segments.count) segments, \(data.count) bytes")
            return true
        } catch {
            workoutLog.error("Could not write workout result: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Result not saved: \(error.localizedDescription)"
            return false
        }
    }

    private func persistProgress() {
        if isDemo { return }
        saveCheckpoint()
        do {
            let data = try JSONEncoder().encode(progress)
            UserDefaults.standard.set(data, forKey: Keys.progress)
        } catch {
            workoutLog.error("Could not persist progress: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshCounters() {
        motionSamples = recorder.sampleCount
        csvBytes = recorder.csvBytes
    }

    private func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    // MARK: - Formatting

    /// "5:12" (per km), nil-safe.
    static func formatPace(_ secondsPerKm: Double) -> String {
        guard secondsPerKm.isFinite, secondsPerKm > 0, secondsPerKm < 3600 else { return "–:––" }
        let total = Int(secondsPerKm.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
