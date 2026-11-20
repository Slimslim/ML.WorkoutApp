import Foundation
import Combine
import BarPathKit

/// E2 (0.18): the workout engine the watch runs, chosen in Settings › Workout engine. Kept on this
/// phone only (UserDefaults, no database). Until the athlete picks one it is
/// `WorkoutEngine.phoneDefault`. PhoneLink sends it to the watch on the `workoutEngine`
/// application-context key; the watch reads it when a workout starts.
final class EngineSwitchSetting: ObservableObject {
    static let shared = EngineSwitchSetting()

    /// UserDefaults key (absent until the athlete picks an engine).
    static let storageKey = "workoutEngine.v1"

    @Published private(set) var engine: WorkoutEngine

    private init() {
        let stored: String? = UserDefaults.standard.string(forKey: EngineSwitchSetting.storageKey)
        engine = stored.flatMap { WorkoutEngine(rawValue: $0) } ?? WorkoutEngine.phoneDefault
    }

    func set(_ newEngine: WorkoutEngine) {
        UserDefaults.standard.set(newEngine.rawValue, forKey: EngineSwitchSetting.storageKey)
        if newEngine != engine {
            engine = newEngine
        }
        PhoneLink.shared.sendWorkoutEngine()
    }
}
