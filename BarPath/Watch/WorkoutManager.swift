import Foundation
import Combine
import HealthKit
import CoreLocation

/// Owns the HKWorkoutSession + HKLiveWorkoutBuilder.
///
/// The workout session is what keeps the app running with the wrist down and what
/// CMBatchedSensorManager requires before it streams anything. Motion recording is started
/// by SessionModel only once this reports `.running`.
///
/// HealthKit calls the delegate methods on an arbitrary queue, so they are `nonisolated`
/// and hop to the main actor explicitly.
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    let healthStore = HKHealthStore()

    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var isFinishing = false
    /// Route of a workout with GPS (workout mode, plans with a run). Created from the live
    /// builder on the first `insertRoute`, so a session without GPS never has one. Finished with
    /// the workout, or discarded with it.
    private var routeBuilder: HKWorkoutRouteBuilder?
    private var routeLocationCount = 0
    /// `start()` was called and its session isn't created yet (authorization pending);
    /// `end()` before then cancels it, so no session comes up after the caller moved on.
    private var startPending = false
    private(set) var startDate: Date?
    /// Used by `beginSession()`. Lifting keeps the defaults; workout mode sets them before `start()`.
    var activityType: HKWorkoutActivityType = .traditionalStrengthTraining
    var locationType: HKWorkoutSessionLocationType = .indoor

    var onStateChange: (@MainActor (HKWorkoutSessionState) -> Void)?
    var onHeartRate: (@MainActor (Double) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// Called once the workout has been ended and saved (or when there was nothing to end).
    var onFinished: (@MainActor () -> Void)?
    /// Set before `end()`: false discards the workout instead of saving it to Health/Fitness
    /// (used for tiny sessions with no lifts, so Fitness doesn't fill up with 1-minute workouts).
    var saveWorkoutOnEnd = true

    override init() {
        super.init()
    }

    /// Number of times any manager in this process was asked to start a session. The launch
    /// recovery below only acts while this is still 0, so it can never end a session started
    /// in this run.
    private static var startRequests = 0

    var hasSession: Bool { session != nil }

    // MARK: - Start

    /// Requests HealthKit authorization (a no-op if already answered), then starts the session.
    func start() {
        guard session == nil else {
            Log.workout.error("start() called while a session exists")
            return
        }
        guard HKHealthStore.isHealthDataAvailable() else {
            onError?("Health data is not available on this device")
            return
        }
        startPending = true
        WorkoutManager.startRequests += 1
        let sets = authorizationSets()
        healthStore.requestAuthorization(toShare: sets.share, read: sets.read) { success, error in
            if let error = error {
                Log.workout.error("HealthKit authorization error: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                // `success` only means the request completed, not that it was granted.
                // If sharing was denied, creating/starting the session reports the error.
                self.beginSession()
            }
        }
    }

    /// The types every session of this app asks for (one place, so the practice asks for exactly
    /// what a workout does).
    private func authorizationSets() -> (share: Set<HKSampleType>, read: Set<HKObjectType>) {
        var share: Set<HKSampleType> = [HKObjectType.workoutType()]
        // The route of a workout with a run goes to Health through the route builder; Apple's
        // "Creating a workout route" asks for read and share access to the route type.
        share.insert(HKSeriesType.workoutRoute())
        var read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType()
        ]
        // Date of birth, for the max heart rate estimate on the phone (asked in the same sheet).
        if let birth = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) {
            read.insert(birth)
        }
        read.insert(HKSeriesType.workoutRoute())
        return (share: share, read: read)
    }

    /// Asks for the same Health access `start()` does, without starting a session (the
    /// practice workout asks before anything runs). `completion` runs on the main actor once
    /// the question is answered, or at once when it was answered before or Health is
    /// unavailable. It does not say whether access was granted.
    func requestAuthorization(completion: @escaping @MainActor () -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion()
            return
        }
        let sets = authorizationSets()
        healthStore.requestAuthorization(toShare: sets.share, read: sets.read) { _, error in
            if let error = error {
                Log.workout.error("HealthKit authorization error: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor in
                completion()
            }
        }
    }

    private func beginSession() {
        guard session == nil, startPending else { return }
        startPending = false
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = locationType

        let newSession: HKWorkoutSession
        do {
            newSession = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        } catch {
            Log.workout.error("Could not create workout session: \(error.localizedDescription, privacy: .public)")
            onError?("Could not start workout: \(error.localizedDescription)")
            return
        }
        let newBuilder = newSession.associatedWorkoutBuilder()
        newBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore,
                                                       workoutConfiguration: configuration)
        newSession.delegate = self
        newBuilder.delegate = self
        session = newSession
        builder = newBuilder
        isFinishing = false
        routeBuilder = nil
        routeLocationCount = 0

        let start = Date()
        startDate = start
        newSession.startActivity(with: start)
        newBuilder.beginCollection(withStart: start) { success, error in
            if let error = error {
                Log.workout.error("beginCollection failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Log.workout.info("beginCollection ok: \(success)")
            }
        }
    }

    // MARK: - Route

    /// Adds accepted GPS fixes to the workout's route (Health only; no app file gets them).
    /// Does nothing without a running session or once the workout is being finished.
    func insertRoute(_ locations: [CLLocation]) {
        guard !locations.isEmpty, !isFinishing, let live = builder else { return }
        if routeBuilder == nil {
            routeBuilder = live.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
            if routeBuilder == nil {
                Log.workout.error("No route builder available; route not saved")
            }
        }
        guard let route = routeBuilder else { return }
        routeLocationCount += locations.count
        route.insertRouteData(locations) { _, error in
            if let error = error {
                Log.workout.error("Route insert failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Recovery after the app died

    /// Called once at launch by the workout model. If the app died mid-workout the system may
    /// still hold an active HKWorkoutSession for it: end it and save the Health workout (end
    /// collection now, then finishWorkout). Fire and forget; errors are only logged. A lifting
    /// session (traditional strength) is left alone, and nothing happens if a session was
    /// already requested in this run.
    nonisolated static func recoverInterruptedSession() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        store.recoverActiveWorkoutSession { session, error in
            if let error = error {
                Log.workout.error("recoverActiveWorkoutSession failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            guard let session = session else { return }
            Task { @MainActor in
                finishRecovered(session)
            }
        }
    }

    private static func finishRecovered(_ session: HKWorkoutSession) {
        if startRequests > 0 {
            Log.workout.info("Recovered session ignored: a session was already requested in this run")
            return
        }
        if session.workoutConfiguration.activityType == .traditionalStrengthTraining {
            Log.workout.info("Recovered session is a lifting session; left alone")
            return
        }
        // Activity "other" is only ever the practice workout or a background recovery session;
        // both are discarded, never saved to Health.
        let discard: Bool = session.workoutConfiguration.activityType == .other
        let verb: String = discard ? "discarding" : "saving"
        Log.workout.error("Recovered an active workout session from before the app died; \(verb, privacy: .public) it")
        let builder: HKLiveWorkoutBuilder = session.associatedWorkoutBuilder()
        if session.state != .ended {
            session.end()
        }
        let endDate = Date()
        builder.endCollection(withEnd: endDate) { _, error in
            if let error = error {
                Log.workout.error("Recovered endCollection failed: \(error.localizedDescription, privacy: .public)")
            }
            if discard {
                builder.discardWorkout()
                _ = session
                return
            }
            builder.finishWorkout { _, error in
                if let error = error {
                    Log.workout.error("Recovered finishWorkout failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.workout.info("Recovered workout saved")
                }
                // Keeps the session alive until the workout is saved.
                _ = session
            }
        }
    }

    // MARK: - End

    /// Ends the session properly: session.end(), then (on `.ended`) endCollection + finishWorkout.
    func end() {
        guard let session = session else {
            startPending = false
            onFinished?()
            return
        }
        if session.state == .ended {
            finishBuilder(endDate: Date())
        } else {
            session.end()
        }
    }

    private func handleStateChange(_ state: HKWorkoutSessionState, date: Date) {
        Log.workout.info("Workout state -> \(state.rawValue)")
        onStateChange?(state)
        if state == .ended {
            finishBuilder(endDate: date)
        }
    }

    private func finishBuilder(endDate: Date) {
        guard !isFinishing else { return }
        isFinishing = true
        guard let builder = builder else {
            cleanup()
            return
        }
        let save = saveWorkoutOnEnd   // read on the main actor, before the background callback
        let route: HKWorkoutRouteBuilder? = routeLocationCount > 0 ? routeBuilder : nil
        if route == nil {
            routeBuilder?.discard()   // a builder that never got a fix
        }
        builder.endCollection(withEnd: endDate) { _, error in
            if let error = error {
                Log.workout.error("endCollection failed: \(error.localizedDescription, privacy: .public)")
            }
            if !save {
                builder.discardWorkout()
                route?.discard()
                Log.workout.info("Workout discarded (too short / no lifts)")
                Task { @MainActor in
                    self.cleanup()
                }
                return
            }
            builder.finishWorkout { workout, error in
                if let error = error {
                    Log.workout.error("finishWorkout failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.workout.info("Workout saved")
                }
                guard let route = route else {
                    Task { @MainActor in
                        self.cleanup()
                    }
                    return
                }
                guard let workout = workout else {
                    route.discard()
                    Task { @MainActor in
                        self.cleanup()
                    }
                    return
                }
                // Same Fitness workout: the route is attached to the workout just saved.
                route.finishRoute(with: workout, metadata: nil) { _, routeError in
                    if let routeError = routeError {
                        Log.workout.error("finishRoute failed: \(routeError.localizedDescription, privacy: .public)")
                    } else {
                        Log.workout.info("Route saved")
                    }
                    Task { @MainActor in
                        self.cleanup()
                    }
                }
            }
        }
    }

    private func cleanup() {
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        routeBuilder = nil
        routeLocationCount = 0
        startDate = nil
        isFinishing = false
        saveWorkoutOnEnd = true
        onFinished?()
    }

    private func handleFailure(_ message: String) {
        onError?(message)
        // If the session never got going, tear it down so the user can try again.
        if let session = session, session.state == .notStarted || session.state == .prepared {
            session.end()
            cleanup()
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            self.handleStateChange(toState, date: date)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Log.workout.error("Workout session failed: \(message, privacy: .public)")
        Task { @MainActor in
            self.handleFailure("Workout error: \(message)")
        }
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let heartRateType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRateType),
              let statistics = workoutBuilder.statistics(for: heartRateType),
              let quantity = statistics.mostRecentQuantity() else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        Task { @MainActor in
            self.onHeartRate?(bpm)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        // Not used.
    }
}
