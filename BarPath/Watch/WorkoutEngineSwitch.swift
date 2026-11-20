import Foundation
import BarPathKit

/// E2 (0.18): which workout engine to run, as last chosen on the phone (Settings › Workout engine,
/// sent on the `workoutEngine` application-context key). Kept on the watch, so it still holds with
/// the phone off or out of reach; `WorkoutEngine.watchDefault` (legacy) until the phone ever sent
/// one.
///
/// Read it ONCE, when a workout starts, and keep that value for the whole workout (E3), so a
/// change on the phone never switches a running workout.
enum WorkoutEngineSwitch {
    /// UserDefaults key on the watch.
    static let storageKey = "workoutEngine.v1"

    /// The engine for the next workout start.
    static func current() -> WorkoutEngine {
        return WorkoutEngine.resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    /// Stores the engine from a received application context or message; ignores a payload
    /// without the key (or with an unknown value), so the last choice is kept.
    static func store(from payload: [String: Any]) {
        guard let engine = WorkoutEngine.received(in: payload) else { return }
        if UserDefaults.standard.string(forKey: storageKey) != engine.rawValue {
            UserDefaults.standard.set(engine.rawValue, forKey: storageKey)
            Log.link.info("Workout engine from phone: \(engine.rawValue, privacy: .public)")
        }
    }
}
