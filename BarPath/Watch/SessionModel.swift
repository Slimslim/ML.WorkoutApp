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
    @Published var loadKg: Double {
        didSet {
            recorder.loadKg = currentLoad
            UserDefaults.standard.set(loadKg, forKey: Keys.loadKg)
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

    var currentLoad: Double? { useLoad ? loadKg : nil }

    private let workout: WorkoutManager
    private let recorder: MotionRecorder
    private let link: PhoneLink
    private var sessionId = UUID()
    private var lastHapticDate: Date?

    private enum Keys {
        static let liftType = "liftType"
        static let useLoad = "useLoad"
        static let loadKg = "loadKg"
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
        let storedLoad = defaults.double(forKey: Keys.loadKg)
        let initialLoad = storedLoad > 0 ? storedLoad : 60
        let initialDebug = defaults.object(forKey: Keys.debugRecording) == nil
            ? true
            : defaults.bool(forKey: Keys.debugRecording)

        liftType = initialType
        useLoad = initialUseLoad
        loadKg = initialLoad
        debugRecording = initialDebug

        recorder.liftType = initialType
        recorder.loadKg = initialUseLoad ? initialLoad : nil
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
    }

    // MARK: - Actions

    func start() {
        guard phase == .idle else { return }
        errorMessage = nil
        lastSummary = nil
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
        phase = .starting
        workout.start()
    }

    func end() {
        switch phase {
        case .running, .starting:
            stopRecording()
            phase = .ending
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

    func status(at date: Date) -> Status {
        switch phase {
        case .idle: return .walkToBar
        case .starting: return .starting
        case .ending: return .ending
        case .running: break
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
                recorder.start(sessionId: sessionId, recordDebugCSV: debugRecording)
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
            var summary = "\(liftCount) lift\(liftCount == 1 ? "" : "s") sent"
            if isRecordingCSV {
                summary += " + session CSV (\(SessionModel.formatBytes(csvBytes)))"
            }
            lastSummary = summary
        }
        phase = .idle
        sessionStartDate = nil
        heartRate = nil
        detectorState = .idle
        sendStatus()
    }

    /// Stops motion, flushes snippets and sends the debug CSV (always, even with 0 lifts;
    /// transferFile queues it if the phone isn't reachable).
    private func stopRecording() {
        let csvURL = recorder.stop()
        refreshCounters()
        liftCount = recorder.liftCount
        if let csvURL = csvURL {
            link.sendFile(csvURL, metadata: PhoneLink.sessionCSVMetadata(sessionId: sessionId.uuidString))
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
        link.sendStatus([
            "type": "status",
            "sessionId": sessionId.uuidString,
            "phase": String(describing: phase),
            "state": detectorState.rawValue,
            "liftCount": liftCount,
            "liftType": liftType.rawValue
        ])
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
