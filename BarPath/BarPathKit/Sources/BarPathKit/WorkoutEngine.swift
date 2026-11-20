import Foundation

/// Which workout engine the watch runs (E2, release 0.18): the new engine (`v2`) or the one in
/// 0.17 (`legacy`). Chosen on the phone (Settings › Workout engine), sent to the watch on its own
/// WatchConnectivity application-context key, kept on the watch, and read once when a workout
/// starts, so a running workout never switches engine. Pure logic, tested without a watch.
public enum WorkoutEngine: String, Codable, Equatable, Sendable, CaseIterable {
    case v2
    case legacy

    /// Application context key (phone → watch). New in 0.18; never reuse an existing key.
    public static let contextKey = "workoutEngine"

    /// What the watch uses when the phone never sent a choice (older phone app, fresh install).
    public static let watchDefault: WorkoutEngine = .legacy

    /// What the phone sends until the athlete picks one in Settings. 0.18 testers run the new
    /// engine; the race default is decided at go/no-go (1 Dec).
    public static let phoneDefault: WorkoutEngine = .v2

    /// A stored or received value: the watch default when it is missing or not a known engine.
    public static func resolve(_ raw: Any?) -> WorkoutEngine {
        if let text = raw as? String, let engine = WorkoutEngine(rawValue: text) {
            return engine
        }
        return watchDefault
    }

    /// The engine in a received context or message, or nil when the key is absent or unknown
    /// (the watch then keeps what it had).
    public static func received(in payload: [String: Any]) -> WorkoutEngine? {
        guard let text = payload[contextKey] as? String else { return nil }
        return WorkoutEngine(rawValue: text)
    }

    /// How a recording and a result name the engine that ran (QA, 0.18): "new" or "classic". The
    /// result's `engine` field and the recording CSV header's `engine=` pair use it.
    public var recordName: String {
        switch self {
        case .v2: return "new"
        case .legacy: return "classic"
        }
    }

    /// The recording CSV header pair, e.g. "engine=new".
    public var headerPair: String { return "engine=" + recordName }

    /// The engine a `recordName` stands for, nil for anything else.
    public static func fromRecordName(_ name: String?) -> WorkoutEngine? {
        switch name {
        case "new": return .v2
        case "classic": return .legacy
        default: return nil
        }
    }

    /// The application context with `engine` set and every other key kept, or nil when it is
    /// already set to that value (nothing to send).
    public static func merged(context: [String: Any], engine: WorkoutEngine) -> [String: Any]? {
        if (context[contextKey] as? String) == engine.rawValue { return nil }
        var out: [String: Any] = context
        out[contextKey] = engine.rawValue
        return out
    }
}
