import Foundation
import Combine
import HealthKit
import CoreMotion
import CoreLocation
import WatchKit
import BarPathKit

/// The W22 practice workout: asks for Health, Motion and Location with the reason, then walks the tester
/// through two "parts" with the Digital Crown. It leaves no trace: it saves no result, writes no
/// file, sends nothing to the phone and its HealthKit workout is discarded.
///
/// It owns its own `WorkoutManager` (a real `HKWorkoutSession` is the only way to get the live
/// heart rate). Nothing here touches `WorkoutSessionModel`'s state, `WorkoutCheckpoint`, the
/// motion recorder, `PhoneLink` or any file.
@MainActor
final class WorkoutPracticeModel: ObservableObject {
    /// One instance for the whole run: it must outlive the sheet so the HealthKit session it
    /// ends (and discards) is not released half-way (HealthKit's delegates are weak).
    static let shared = WorkoutPracticeModel()

    enum Stage: Equatable {
        case permissions
        case requesting
        case part1
        case part2
        case done
        case blocked
    }

    /// A one-time screen telling the tester what a refused permission costs.
    enum Notice: Equatable {
        case heartRate
        case motion
    }

    /// Set when "Got it" is tapped; the practice opens by itself at launch until then.
    static let finishedKey: String = "practiceWorkout.finished.v1"
    // W23: the practice writes `SensorAccess.receivedHeartRateKey` with the same rule as a
    // workout: true at the first sample, false only when a session of 2 min or more got none.
    // A shorter practice (the usual case) leaves the previous answer.

    /// No heart-rate sample this long after the session is running: heart rate is off.
    static let heartRateCheckSeconds: Double = 20.0
    /// The Motion question is given this long; after it the practice goes on.
    static let motionTimeoutSeconds: Double = 10.0
    /// If the session never reports running, decide after this long anyway.
    static let sessionStartGraceSeconds: Double = 25.0
    /// Part 2 shows "Nice." this long before the undo hint, and the hint this long.
    static let undoHintDelaySeconds: Double = 4.0
    static let undoHintSeconds: Double = 4.0
    /// The border slice fills against this nominal time (like a station without a target).
    static let partNominalSeconds: Double = 30.0
    /// Safety net, not shown: a practice left running this long is ended (no zombie session).
    static let maxSessionSeconds: Double = 600.0

    static var hasFinished: Bool {
        return UserDefaults.standard.bool(forKey: WorkoutPracticeModel.finishedKey)
    }

    @Published private(set) var stage: Stage = .permissions
    /// Real heart rate in BPM, nil until the first sample arrives.
    @Published private(set) var heartRate: Int?
    /// No heart rate arrived in time (never a placeholder number).
    @Published private(set) var heartRateOff: Bool = false
    @Published private(set) var notice: Notice?
    @Published private(set) var showUndoHint: Bool = false
    /// When the current part started (drives the border fill).
    @Published private(set) var partStart: Date = Date()
    @Published private(set) var blockedText: String = ""

    private let manager = WorkoutManager()
    private var pedometer: CMPedometer?
    private var locationRequest: LocationPermissionRequest?
    private var motionOff: Bool = false
    private var motionStepDone: Bool = false
    private var motionTimeoutTask: Task<Void, Never>?
    private var heartRateNoticeShown: Bool = false
    private var hintShown: Bool = false
    /// Bumped on every reset/leave: callbacks and timers of an earlier run check it and stop.
    private var generation: Int = 0
    private var heartRateTask: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?
    private var safetyTask: Task<Void, Never>?
    /// When the HealthKit session was started (W23: how long it ran without heart rate).
    private var sessionStartedAt: Date?

    var isSessionStage: Bool {
        return stage == .part1 || stage == .part2
    }

    // MARK: - Lifecycle

    /// Fresh start of the screens (called before the sheet opens).
    func prepare() {
        resetState()
    }

    /// The sheet was dismissed, or the app left the foreground: ends the HealthKit session
    /// (discarded) and forgets the run. Safe to call at any time, any number of times.
    func leave() {
        endSession()
        resetState()
    }

    private func resetState() {
        generation += 1
        heartRateTask?.cancel()
        heartRateTask = nil
        hintTask?.cancel()
        hintTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        pedometer = nil
        motionTimeoutTask?.cancel()
        motionTimeoutTask = nil
        motionStepDone = false
        locationRequest = nil
        stage = .permissions
        heartRate = nil
        heartRateOff = false
        notice = nil
        showUndoHint = false
        partStart = Date()
        blockedText = ""
        motionOff = false
        heartRateNoticeShown = false
        hintShown = false
        sessionStartedAt = nil
    }

    // MARK: - Permissions

    /// "Continue": Health prompt, then the Motion prompt, then Location, then part 1. `blockedReason` is set
    /// by the view when a workout, a lift or a recovery recording owns HealthKit.
    func continueFromPermissions(blockedReason: String?) {
        guard stage == .permissions else { return }
        if let reason = blockedReason {
            blockedText = reason
            stage = .blocked
            return
        }
        if manager.hasSession {
            blockedText = "The last practice is still closing. Try again in a moment."
            stage = .blocked
            return
        }
        stage = .requesting
        let gen: Int = generation
        manager.requestAuthorization { [weak self] in
            self?.askMotion(generation: gen)
        }
    }

    /// Any CoreMotion pedometer call makes watchOS show the Motion & Fitness prompt the first
    /// time. A one-minute-old query is the lightest one; its result is thrown away.
    private func askMotion(generation gen: Int) {
        guard gen == generation, stage == .requesting else { return }
        guard CMPedometer.isStepCountingAvailable() else {
            motionAnswered(generation: gen)
            return
        }
        let p = CMPedometer()
        pedometer = p
        motionTimeoutTask?.cancel()
        motionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutPracticeModel.motionTimeoutSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.motionAnswered(generation: gen)
        }
        let now = Date()
        p.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.motionAnswered(generation: gen)
                }
            }
        }
    }

    private func motionAnswered(generation gen: Int) {
        guard gen == generation, stage == .requesting, !motionStepDone else { return }
        motionStepDone = true
        motionTimeoutTask?.cancel()
        motionTimeoutTask = nil
        pedometer = nil
        let status: CMAuthorizationStatus = CMPedometer.authorizationStatus()
        motionOff = status == .denied || status == .restricted
        askLocation(generation: gen)
    }

    /// Third question: when-in-use location, for GPS on workouts with a run. A refusal needs no
    /// screen (one log line); the practice goes on either way.
    private func askLocation(generation gen: Int) {
        guard gen == generation, stage == .requesting else { return }
        let request = LocationPermissionRequest()
        locationRequest = request
        request.start { [weak self] in
            self?.locationAnswered(generation: gen)
        }
    }

    private func locationAnswered(generation gen: Int) {
        guard gen == generation, stage == .requesting else { return }
        locationRequest = nil
        // Health was asked first, before Location, so the route type was left out of that
        // request. When Location was allowed, ask once more so Health's route question is
        // asked here and never at a real workout's START. With nothing new to ask, HealthKit
        // shows nothing and the completion runs at once.
        let status: CLAuthorizationStatus = CLLocationManager().authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestAuthorization { [weak self] in
                self?.beginPartOne(generation: gen)
            }
        } else {
            beginPartOne(generation: gen)
        }
    }

    private func beginPartOne(generation gen: Int) {
        guard gen == generation, stage == .requesting else { return }
        stage = .part1
        partStart = Date()
        if motionOff {
            notice = .motion
        }
        startSession(generation: gen)
    }

    // MARK: - HealthKit session (heart rate only; discarded)

    private func startSession(generation gen: Int) {
        // A workout's background recovery holds a HealthKit session and only one can run. The
        // view refuses to start while one is visibly recording; this covers one about to start.
        WorkoutSessionModel.endBackgroundRecovery { [weak self] in
            self?.startManager(generation: gen)
        }
    }

    private func startManager(generation gen: Int) {
        guard gen == generation, stage == .part1 || stage == .part2 else { return }
        manager.activityType = .other
        manager.locationType = .indoor
        // Whatever happens, this workout is thrown away.
        manager.saveWorkoutOnEnd = false
        manager.onStateChange = { [weak self] (state: HKWorkoutSessionState) in
            self?.sessionStateChanged(state, generation: gen)
        }
        manager.onHeartRate = { [weak self] (bpm: Double) in
            self?.heartRateReceived(bpm, generation: gen)
        }
        manager.onError = { [weak self] (message: String) in
            self?.sessionFailed(message, generation: gen)
        }
        manager.onFinished = nil
        sessionStartedAt = Date()
        manager.start()
        scheduleHeartRateCheck(after: WorkoutPracticeModel.sessionStartGraceSeconds, generation: gen)
        safetyTask?.cancel()
        safetyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutPracticeModel.maxSessionSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.generation == gen else { return }
            self.endSession()
        }
    }

    private func sessionStateChanged(_ state: HKWorkoutSessionState, generation gen: Int) {
        guard gen == generation, isSessionStage else { return }
        if state == .running && heartRate == nil && !heartRateOff {
            scheduleHeartRateCheck(after: WorkoutPracticeModel.heartRateCheckSeconds, generation: gen)
        }
    }

    private func heartRateReceived(_ bpm: Double, generation gen: Int) {
        guard gen == generation, isSessionStage, bpm > 0 else { return }
        heartRate = Int(bpm.rounded())
        heartRateOff = false
        if notice == .heartRate {
            notice = nil   // a late reading: the "no heart rate" screen no longer applies
        }
        heartRateTask?.cancel()
        heartRateTask = nil
        UserDefaults.standard.set(true, forKey: SensorAccess.receivedHeartRateKey)
    }

    private func sessionFailed(_ message: String, generation gen: Int) {
        guard gen == generation, isSessionStage else { return }
        if heartRate == nil {
            heartRateMissing()
        }
    }

    private func scheduleHeartRateCheck(after seconds: Double, generation gen: Int) {
        heartRateTask?.cancel()
        heartRateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.generation == gen, self.isSessionStage else { return }
            self.heartRateMissing()
        }
    }

    /// No heart-rate sample arrived: show HR OFF and, once, the refused screen.
    private func heartRateMissing() {
        guard heartRate == nil else { return }
        heartRateOff = true
        showHeartRateNoticeIfDue()
    }

    private func showHeartRateNoticeIfDue() {
        guard heartRateOff, !heartRateNoticeShown, notice == nil, isSessionStage else { return }
        heartRateNoticeShown = true
        notice = .heartRate
    }

    /// "Continue" on a refused screen: back to the part; the other notice follows if due.
    func dismissNotice() {
        notice = nil
        showHeartRateNoticeIfDue()
    }

    /// Ends the HealthKit session and discards the workout. Never saves.
    private func endSession() {
        if let started = sessionStartedAt {
            sessionStartedAt = nil
            let seconds: Double = Date().timeIntervalSince(started)
            if let received = SensorAccess.receivedHeartRate(sampleCount: heartRate == nil ? 0 : 1, sessionSeconds: seconds) {
                UserDefaults.standard.set(received, forKey: SensorAccess.receivedHeartRateKey)
            }
        }
        heartRateTask?.cancel()
        heartRateTask = nil
        safetyTask?.cancel()
        safetyTask = nil
        manager.onStateChange = nil
        manager.onHeartRate = nil
        manager.onError = nil
        manager.onFinished = nil
        manager.saveWorkoutOnEnd = false
        manager.end()
    }

    // MARK: - Crown

    /// Crown turned forward far enough (same gesture as a workout's advance).
    func crownAdvance() {
        guard notice == nil else { return }
        switch stage {
        case .part1:
            stage = .part2
            partStart = Date()
            WKInterfaceDevice.current().play(.directionUp)
            scheduleUndoHint()
        case .part2:
            hintTask?.cancel()
            hintTask = nil
            showUndoHint = false
            stage = .done
            WKInterfaceDevice.current().play(.success)
            // The practice is over: stop the session now so nothing keeps running.
            endSession()
        default:
            break
        }
    }

    /// Crown turned backward far enough: part 2 goes back to part 1.
    func crownUndo() {
        guard notice == nil, stage == .part2 else { return }
        hintTask?.cancel()
        hintTask = nil
        showUndoHint = false
        stage = .part1
        partStart = Date()
        WKInterfaceDevice.current().play(.directionDown)
    }

    private func scheduleUndoHint() {
        hintTask?.cancel()
        hintTask = nil
        if hintShown { return }
        let gen: Int = generation
        hintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WorkoutPracticeModel.undoHintDelaySeconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard let self = self, self.generation == gen, self.stage == .part2 else { return }
            self.hintShown = true
            self.showUndoHint = true
            try? await Task.sleep(nanoseconds: UInt64(WorkoutPracticeModel.undoHintSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            self.showUndoHint = false
        }
    }

    // MARK: - Finish

    /// "Got it": remembered, so the practice no longer opens by itself.
    func markFinished() {
        UserDefaults.standard.set(true, forKey: WorkoutPracticeModel.finishedKey)
    }
}

// MARK: - Opening the practice

/// Opens the practice sheet (from launch or from the workout list). The sheet itself is
/// attached once, at the root, by `workoutPractice()`.
@MainActor
final class WorkoutPracticeLauncher: ObservableObject {
    static let shared = WorkoutPracticeLauncher()

    @Published var isPresented: Bool = false
    private var launchChecked: Bool = false

    /// At launch: opens it while no practice has ever been finished.
    func openAtLaunchIfNeeded(canRun: Bool) {
        guard !launchChecked else { return }
        launchChecked = true
        guard canRun, !WorkoutPracticeModel.hasFinished else { return }
        open(afterSeconds: 0.8)
    }

    /// Opens after `delay` (lets another sheet, e.g. the workout picker, close first).
    func open(afterSeconds delay: Double) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self = self, !self.isPresented else { return }
            WorkoutPracticeModel.shared.prepare()
            self.isPresented = true
        }
    }
}
