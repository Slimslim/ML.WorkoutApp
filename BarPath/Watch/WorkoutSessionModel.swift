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
struct PedometerSnapshot: Equatable {
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
        if let phone = phoneDefinition, phone.id == definitionId {
            return phone
        }
        return WorkoutLibrary.definition(id: definitionId) ?? WorkoutLibrary.partnerWod1
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
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSummary: String?
    @Published private(set) var healthKitRunning = false
    @Published private(set) var isRecordingCSV = false
    @Published private(set) var motionSamples = 0
    @Published private(set) var csvBytes = 0
    @Published private(set) var marksCount = 0
    @Published private(set) var latestPedometer: PedometerSnapshot?

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
    private var endTimeoutTask: Task<Void, Never>?
    /// Managers replaced because they got stuck (kept alive so they can still finish).
    private var retiredManagers: [WorkoutManager] = []

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
        if let phone = storedPhoneDefinition, phone.id == initialId {
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
        let definition = selectedDefinition
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
        finalized = false
        autoSuppressedStart = nil
        capSuppressed = false
        countdownTarget = nil
        countdownLastBeep = nil
        phase = .starting

        if workout.hasSession {
            // Left over from a previous run that never finished: don't let it block us.
            replaceWorkoutManager()
        }
        workout.activityType = WorkoutSessionModel.activityType(for: definition.healthKitActivity)
        workout.locationType = .indoor
        workout.start()

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
        let name = wasFinished ? "unfinish" : "undo"
        recorder.appendEvent(atUptime: uptime,
                             description: "name=\(name) index=\(progress.currentIndex) source=\(source.rawValue)")
        lastChangeDate = Date()
        persistProgress()
        workoutLog.info("undo (\(source.rawValue, privacy: .public)) -> \(self.progress.currentIndex)")
        return true
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
    func end() {
        switch phase {
        case .starting, .running:
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            finalize()
            phase = .ending
            armEndTimeout()
            workout.end()     // calls onFinished right away if there is no HK session
        case .idle, .ending:
            break
        }
    }

    // MARK: - Running

    private func beginRunning() {
        guard phase == .starting else { return }
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        let t = Date().timeIntervalSince1970
        progress.start(at: t)
        phase = .running

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

    // MARK: - Clock (timed rests, AMRAP cap)

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
                _ = advance(source: .auto)
            }
            return
        }
        // Ready, set, go: one tap at 3, 2 and 1 s; the advance itself plays the "go".
        let second = Int(remaining.rounded(.up))
        if second >= 1 && second <= 3 && countdownLastBeep != second {
            countdownLastBeep = second
            play(.click)
        }
    }

    private func finishByCap() {
        let t = Date().timeIntervalSince1970
        guard progress.finish(at: t, source: .auto) else { return }
        play(.success)
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: "name=finish index=\(progress.currentIndex) source=auto")
        lastChangeDate = Date()
        persistProgress()
        workoutLog.info("time cap reached at segment \(self.progress.currentIndex)")
    }

    // MARK: - HealthKit callbacks

    private func workoutStateChanged(_ state: HKWorkoutSessionState) {
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
    }

    private func armEndTimeout() {
        endTimeoutTask?.cancel()
        endTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutSessionModel.endTimeout * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.phase == .ending else { return }
            workoutLog.error("HealthKit did not finish in time; going idle anyway")
            self.replaceWorkoutManager()
            self.goIdle()
        }
    }

    private func goIdle() {
        endTimeoutTask?.cancel()
        endTimeoutTask = nil
        clockTask?.cancel()
        clockTask = nil
        phase = .idle
        heartRate = nil
        healthKitRunning = false
    }

    private func heartRateReceived(_ bpm: Double) {
        heartRate = bpm
        guard phase == .running, !finalized else { return }
        let t = Date().timeIntervalSince1970
        heartRates.append(HeartRateSample(t: t, bpm: bpm))
        recorder.appendEvent(atUptime: ProcessInfo.processInfo.systemUptime,
                             description: String(format: "name=hr bpm=%.0f", bpm))
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
        let definition = progress.definition
        let startT = progress.startTime ?? endT
        let finishT = progress.finishTime
        let total = (finishT ?? endT) - startT

        let hr: [TimedValue] = heartRates.map { TimedValue(t: $0.t, value: $0.bpm) }
        let steps: [PedometerSample] = pedometerSamples.map {
            PedometerSample(t: $0.t, steps: $0.steps, distance: $0.distance)
        }
        let segments = SplitStats.compute(progress: progress, now: endT, heartRates: hr, pedometer: steps)

        var hrSum = 0.0
        var hrCount = 0
        var hrMax: Double?
        for s in heartRates where s.t >= startT && s.t <= endT {
            hrSum += s.bpm
            hrCount += 1
            hrMax = max(hrMax ?? s.bpm, s.bpm)
        }
        let hrAvg: Double? = hrCount > 0 ? hrSum / Double(hrCount) : nil

        let result = WorkoutResult(version: 1,
                                   id: workoutId,
                                   definition: definition,
                                   startDate: Date(timeIntervalSince1970: startT),
                                   finishDate: finishT.map { Date(timeIntervalSince1970: $0) },
                                   endDate: Date(timeIntervalSince1970: endT),
                                   totalSeconds: total,
                                   segments: segments,
                                   events: progress.events,
                                   heartRateAvg: hrAvg,
                                   heartRateMax: hrMax,
                                   recordingFileName: recordedCSV ? "session-\(workoutId.uuidString).csv" : nil)

        let summary = "\(definition.shortName) · \(SessionModel.formatElapsed(total))"
        lastSummary = summary
        UserDefaults.standard.set(summary, forKey: Keys.lastSummary)

        let url = WatchFiles.outbox.appendingPathComponent("workout-\(workoutId.uuidString).json")
        do {
            let data = try result.encoded()
            try data.write(to: url, options: .atomic)
            link.sendFile(url, metadata: PhoneLink.workoutResultMetadata(id: workoutId.uuidString))
            workoutLog.info("Workout result written: \(segments.count) segments, \(data.count) bytes")
        } catch {
            workoutLog.error("Could not write workout result: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Result not saved: \(error.localizedDescription)"
            let failed = "\(summary) · not saved"
            lastSummary = failed
            UserDefaults.standard.set(failed, forKey: Keys.lastSummary)
        }
    }

    private func persistProgress() {
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
