import Foundation
import Combine
import HealthKit
import WatchKit
import BarPathKit

/// UI-facing state of the watch app; ties WorkoutManager, MotionRecorder and PhoneLink together.
@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle        // start screen
        case starting    // waiting for the workout session to run
        case running     // recording
        case paused      // workout still running, back on the setup screen ("Change")
        case ending      // saving the workout
    }

    enum Status: Equatable {
        case starting
        case walkToBar
        case ready
        case lifting
        case saving
        case saved(Int)
        case ending
        // Strength mode (deadlift)
        case waitingForSet
        case reps(Int)
    }

    // MARK: Settings (persisted)

    @Published var liftType: LiftType {
        didSet {
            recorder.liftType = liftType
            UserDefaults.standard.set(liftType.rawValue, forKey: Keys.liftType)
        }
    }
    @Published var useLoad: Bool {
        didSet {
            recorder.loadKg = currentLoad
            UserDefaults.standard.set(useLoad, forKey: Keys.useLoad)
        }
    }
    /// Load entered on the watch, in pounds (lbs for now; a unit setting comes later).
    /// Recordings still store kilograms (`loadKg`), converted in `currentLoad`.
    @Published var loadLb: Double {
        didSet {
            recorder.loadKg = currentLoad
            UserDefaults.standard.set(loadLb, forKey: Keys.loadLb)
        }
    }
    /// Full-session CSV. Defaults to ON for now (data collection phase).
    @Published var debugRecording: Bool {
        didSet { UserDefaults.standard.set(debugRecording, forKey: Keys.debugRecording) }
    }

    // MARK: Session state

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var detectorState: DetectorState = .idle
    @Published private(set) var liftCount = 0
    @Published private(set) var savedLiftCount = 0
    @Published private(set) var lastSavedIndex: Int?
    @Published private(set) var savedBannerUntil: Date?
    @Published private(set) var heartRate: Double?
    @Published private(set) var sessionStartDate: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSummary: String?
    @Published private(set) var recorderMode: MotionRecorder.Mode = .batched
    @Published private(set) var motionSamples = 0
    @Published private(set) var accelSamples = 0
    @Published private(set) var csvBytes = 0
    @Published private(set) var marksCount = 0
    @Published private(set) var isRecordingCSV = false
    /// Strength mode: live reps in the set in progress, and the last finished set's reps.
    @Published private(set) var repCount = 0
    @Published private(set) var lastSetReps: Int?

    static let kgPerLb = 0.45359237

    /// Load in kilograms for the recording, or nil when not logging load.
    var currentLoad: Double? { useLoad ? loadLb * SessionModel.kgPerLb : nil }

    private let workout: WorkoutManager
    private let recorder: MotionRecorder
    private let link: PhoneLink
    private var sessionId = UUID()
    /// Names the current block's debug CSV (a new one after each Change).
    private var csvId = UUID()
    private var lastHapticDate: Date?
    private var pendingPhoneLift: LiftSelection?

    private enum Keys {
        static let liftType = "liftType"
        static let useLoad = "useLoad"
        static let loadLb = "loadLb"
        static let debugRecording = "debugRecording.v1"
    }

    init() {
        workout = WorkoutManager()
        recorder = MotionRecorder()
        link = PhoneLink.shared

        let defaults = UserDefaults.standard
        let storedType = defaults.string(forKey: Keys.liftType).flatMap { LiftType(rawValue: $0) }
        let initialType = storedType ?? .snatch
        let initialUseLoad = defaults.bool(forKey: Keys.useLoad)
        let storedLoad = defaults.double(forKey: Keys.loadLb)
        let initialLoad = storedLoad > 0 ? storedLoad : 135
        let initialDebug = defaults.object(forKey: Keys.debugRecording) == nil
            ? true
            : defaults.bool(forKey: Keys.debugRecording)

        liftType = initialType
        useLoad = initialUseLoad
        loadLb = initialLoad
        debugRecording = initialDebug

        recorder.liftType = initialType
        recorder.loadKg = initialUseLoad ? initialLoad * SessionModel.kgPerLb : nil
        wireCallbacks()
    }

    private func wireCallbacks() {
        workout.onStateChange = { [weak self] state in
            self?.workoutStateChanged(state)
        }
        workout.onHeartRate = { [weak self] bpm in
            self?.heartRate = bpm
        }
        workout.onError = { [weak self] message in
            self?.workoutFailed(message)
        }
        workout.onFinished = { [weak self] in
            self?.workoutFinished()
        }

        recorder.onDetectorStateChange = { [weak self] state in
            self?.detectorStateChanged(state)
        }
        recorder.onDetectorEvent = { [weak self] event in
            self?.detectorEvent(event)
        }
        recorder.onLiftSaved = { [weak self] index in
            self?.liftSaved(index)
        }
        recorder.onError = { [weak self] message in
            self?.errorMessage = message
        }
        recorder.onBatchProcessed = { [weak self] in
            self?.refreshCounters()
        }
        recorder.onRepCount = { [weak self] n in
            self?.repCountChanged(n)
        }
        recorder.onSetEnded = { [weak self] index, reps in
            self?.setEnded(index: index, reps: reps)
        }
    }

    // MARK: - Actions

    func start() {
        if phase == .paused {
            resume()
            return
        }
        guard phase == .idle else { return }
        errorMessage = nil
        lastSummary = nil
        pendingPhoneLift = nil
        sessionId = UUID()
        liftCount = 0
        savedLiftCount = 0
        lastSavedIndex = nil
        savedBannerUntil = nil
        heartRate = nil
        detectorState = .idle
        motionSamples = 0
        accelSamples = 0
        csvBytes = 0
        marksCount = 0
        isRecordingCSV = false
        repCount = 0
        lastSetReps = nil
        phase = .starting
        workout.start()
    }

    /// Lift + load sent from the phone's Lifts tab. Applied on the setup screen (idle or after
    /// Change); while a block is recording it waits for the next Change.
    func selectFromPhone(_ selection: LiftSelection) {
        guard phase == .idle || phase == .paused else {
            pendingPhoneLift = selection
            return
        }
        apply(selection)
    }

    private func apply(_ selection: LiftSelection) {
        liftType = selection.liftType
        if let lb = selection.loadLb {
            loadLb = lb
            useLoad = true
        } else {
            useLoad = false
        }
        pendingPhoneLift = nil
    }

    /// "Change": stop recording this block (lift type / load) and go back to setup while the
    /// HealthKit workout keeps running, so one gym session stays one workout in Fitness.
    func change() {
        guard phase == .running else { return }
        stopRecording()
        detectorState = .idle
        phase = .paused
        if let selection = pendingPhoneLift {
            apply(selection)
        }
        sendStatus()
    }

    /// Continue the same workout with the (possibly changed) setup.
    private func resume() {
        errorMessage = nil
        csvId = UUID()
        recorder.liftType = liftType
        recorder.loadKg = currentLoad
        recorder.start(sessionId: sessionId, csvId: csvId, recordDebugCSV: debugRecording,
                       liftIndexOffset: liftCount)
        recorderMode = recorder.mode
        isRecordingCSV = recorder.isRecordingCSV
        detectorState = .idle
        marksCount = 0
        repCount = 0
        phase = .running
        sendStatus()
    }

    func end() {
        switch phase {
        case .paused:
            phase = .ending
            let duration = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
            workout.saveWorkoutOnEnd = liftCount > 0 || duration >= 300
            workout.end()
        case .running, .starting:
            stopRecording()
            phase = .ending
            // Only keep real sessions in Health/Fitness: at least one lift, or 5+ minutes.
            let duration = sessionStartDate.map { Date().timeIntervalSince($0) } ?? 0
            workout.saveWorkoutOnEnd = liftCount > 0 || duration >= 300
            workout.end()
        case .idle, .ending:
            break
        }
    }

    /// User marker in the debug CSV ("lift now", "bad rep", ...).
    func mark(label: String = "mark") {
        if let n = recorder.addMark(label: label) {
            marksCount = n
            WKInterfaceDevice.current().play(.click)
        } else {
            WKInterfaceDevice.current().play(.failure)
        }
    }

    // MARK: - Status

    /// The running block counts reps (deadlift) instead of tracking single lifts.
    var isRepMode: Bool { liftType.countsReps }

    func status(at date: Date) -> Status {
        switch phase {
        case .idle, .paused: return .walkToBar
        case .starting: return .starting
        case .ending: return .ending
        case .running: break
        }
        if isRepMode {
            if repCount > 0 { return .reps(repCount) }
            if let until = savedBannerUntil, date < until, let index = lastSavedIndex { return .saved(index) }
            return .waitingForSet
        }
        if detectorState == .lifting { return .lifting }
        if let until = savedBannerUntil, date < until, let index = lastSavedIndex { return .saved(index) }
        if detectorState == .armed { return .ready }
        if liftCount > savedLiftCount || detectorState == .cooldown { return .saving }
        return .walkToBar
    }

    // MARK: - Workout callbacks

    private func workoutStateChanged(_ state: HKWorkoutSessionState) {
        switch state {
        case .running:
            if phase == .starting {
                sessionStartDate = workout.startDate ?? Date()
                recorder.liftType = liftType
                recorder.loadKg = currentLoad
                csvId = UUID()
                recorder.start(sessionId: sessionId, csvId: csvId, recordDebugCSV: debugRecording)
                recorderMode = recorder.mode
                isRecordingCSV = recorder.isRecordingCSV
                phase = .running
                sendStatus()
            }
        case .ended:
            // Ended by the system (or by us): make sure the data is flushed and sent.
            if phase == .running || phase == .starting {
                stopRecording()
                phase = .ending
            } else if phase == .paused {
                phase = .ending
            }
        default:
            break
        }
    }

    private func workoutFailed(_ message: String) {
        errorMessage = message
        if phase == .starting {
            // Session never ran; WorkoutManager tears it down and calls onFinished.
            if !workout.hasSession {
                phase = .idle
            }
        }
    }

    private func workoutFinished() {
        if phase == .running || phase == .starting {
            stopRecording()
        }
        if sessionStartDate != nil {
            var summary = "\(liftCount) recording\(liftCount == 1 ? "" : "s") sent"
            if isRecordingCSV {
                summary += " + session CSV (\(SessionModel.formatBytes(csvBytes)))"
            }
            lastSummary = summary
        }
        phase = .idle
        sessionStartDate = nil
        heartRate = nil
        detectorState = .idle
        // A lift sent from the phone during the session is the setup for the next one.
        if let selection = pendingPhoneLift {
            apply(selection)
        }
        sendStatus()
    }

    /// Stops motion, flushes snippets and sends the debug CSV (always, even with 0 lifts;
    /// transferFile queues it if the phone isn't reachable).
    private func stopRecording() {
        let csvURL = recorder.stop()
        refreshCounters()
        liftCount = recorder.liftCount
        if let csvURL = csvURL {
            link.sendFile(csvURL, metadata: PhoneLink.sessionCSVMetadata(sessionId: csvId.uuidString))
        }
    }

    // MARK: - Recorder callbacks

    private func detectorStateChanged(_ state: DetectorState) {
        detectorState = state
        sendStatus()
    }

    private func detectorEvent(_ event: DetectorEvent) {
        switch event {
        case .armed:
            playHaptic(.start, minimumGap: 2.5)
        case .liftEnded:
            liftCount = recorder.liftCount
            playHaptic(.success, minimumGap: 0)
        case .liftStarted, .disarmed:
            break
        }
    }

    private func repCountChanged(_ n: Int) {
        if n > repCount {
            playHaptic(.click, minimumGap: 0)
        }
        repCount = n
        sendStatus()
    }

    private func setEnded(index: Int, reps: Int) {
        liftCount = recorder.liftCount
        lastSetReps = reps
        repCount = 0
        playHaptic(.success, minimumGap: 0)
        sendStatus()
    }

    private func liftSaved(_ index: Int) {
        savedLiftCount = recorder.savedLiftCount
        lastSavedIndex = index
        savedBannerUntil = Date().addingTimeInterval(3)
        sendStatus()
    }

    private func refreshCounters() {
        motionSamples = recorder.motionSampleCount
        accelSamples = recorder.accelSampleCount
        csvBytes = recorder.csvBytes
    }

    /// `minimumGap`: suppress the haptic if another one played less than this many seconds ago
    /// (avoids a buzz storm when the detector re-arms right after a drop or while resting).
    private func playHaptic(_ type: WKHapticType, minimumGap: TimeInterval) {
        let now = Date()
        if minimumGap > 0, let last = lastHapticDate, now.timeIntervalSince(last) < minimumGap {
            return
        }
        lastHapticDate = now
        WKInterfaceDevice.current().play(type)
    }

    private func sendStatus() {
        var message: [String: Any] = [
            "type": "status",
            "sessionId": sessionId.uuidString,
            "phase": String(describing: phase),
            "state": detectorState.rawValue,
            "liftCount": liftCount,
            "liftType": liftType.rawValue
        ]
        if isRepMode {
            // Live set on the phone: reps so far in the set in progress (0 between sets).
            message["repCount"] = repCount
            if useLoad {
                message["loadLb"] = loadLb
            }
        }
        link.sendStatus(message)
    }

    // MARK: - Formatting

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        }
        return String(format: "%.0f KB", Double(bytes) / 1_000)
    }

    static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.0fk", Double(n) / 1_000)
        }
        return "\(n)"
    }
}
