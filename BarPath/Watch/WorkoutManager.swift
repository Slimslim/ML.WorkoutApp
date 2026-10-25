import Foundation
import HealthKit

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
    private(set) var startDate: Date?

    var onStateChange: (@MainActor (HKWorkoutSessionState) -> Void)?
    var onHeartRate: (@MainActor (Double) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    /// Called once the workout has been ended and saved (or when there was nothing to end).
    var onFinished: (@MainActor () -> Void)?

    override init() {
        super.init()
    }

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
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        let read: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKObjectType.workoutType()
        ]
        healthStore.requestAuthorization(toShare: share, read: read) { success, error in
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

    private func beginSession() {
        guard session == nil else { return }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .traditionalStrengthTraining
        configuration.locationType = .indoor

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

    // MARK: - End

    /// Ends the session properly: session.end(), then (on `.ended`) endCollection + finishWorkout.
    func end() {
        guard let session = session else {
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
        builder.endCollection(withEnd: endDate) { _, error in
            if let error = error {
                Log.workout.error("endCollection failed: \(error.localizedDescription, privacy: .public)")
            }
            builder.finishWorkout { _, error in
                if let error = error {
                    Log.workout.error("finishWorkout failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    Log.workout.info("Workout saved")
                }
                Task { @MainActor in
                    self.cleanup()
                }
            }
        }
    }

    private func cleanup() {
        session?.delegate = nil
        builder?.delegate = nil
        session = nil
        builder = nil
        startDate = nil
        isFinishing = false
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
