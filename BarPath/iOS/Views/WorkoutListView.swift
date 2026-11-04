import SwiftUI
import BarPathKit

struct WorkoutRoute: Hashable {
    let id: UUID
}

extension Theme {
    static let workoutRun = Color(red: 0.22, green: 0.45, blue: 1.00)
    static let workoutStation = accent
}

/// Time formatting for workouts: h:mm:ss / m:ss, pace m:ss/km.
enum WorkoutFmt {
    /// "1:02:03" from an hour on, otherwise "41:12".
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Always h:mm:ss (list rows and the detail header).
    static func hms(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        let total = Int(max(0, secondsPerKm).rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000.0)
        }
        return String(format: "%.0f m", meters)
    }

    static func bpm(_ value: Double?) -> String {
        guard let value = value else { return "–" }
        return String(format: "%.0f", value)
    }
}
