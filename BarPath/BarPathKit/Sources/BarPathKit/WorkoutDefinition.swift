import Foundation

/// Workout model (docs/WORKOUT_SPEC.md §2). Pure Foundation; times are seconds since 1970.

public enum SegmentKind: String, Codable, CaseIterable {
    case run, station, transition, rest
}

public enum TargetUnit: String, Codable {
    case meters, reps, calories, seconds
}

public struct SegmentTarget: Codable, Equatable {
    public var value: Double
    public var unit: TargetUnit

    public init(_ value: Double, _ unit: TargetUnit) {
        self.value = value
        self.unit = unit
    }

    /// "1000 m", "100 reps", "20 cal", "2:00"; whole numbers without decimals.
    public var text: String {
        switch unit {
        case .meters:
            return SegmentTarget.number(value) + " m"
        case .reps:
            return SegmentTarget.number(value) + " reps"
        case .calories:
            return SegmentTarget.number(value) + " cal"
        case .seconds:
            let total: Int = Int(value.rounded())
            let minutes: Int = total / 60
            let secs: Int = total % 60
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Number without a trailing ".0".
    fileprivate static func number(_ v: Double) -> String {
        if v == v.rounded() {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }
}

public struct WorkoutSegment: Codable, Equatable {
    public var kind: SegmentKind
    public var movement: String        // movement id, e.g. "run", "wallBalls"
    public var name: String            // display name, e.g. "Wall Balls"
    public var target: SegmentTarget?

    public init(kind: SegmentKind, movement: String, name: String, target: SegmentTarget?) {
        self.kind = kind
        self.movement = movement
        self.name = name
        self.target = target
    }

    /// Short title for the watch: "Run 800 m", "Wall Balls 100", "SkiErg 1000 m".
    public var title: String {
        guard let t = target else { return name }
        switch t.unit {
        case .reps:
            return name + " " + SegmentTarget.number(t.value)
        default:
            return name + " " + t.text
        }
    }
}

/// Known movement ids and names. Strings, so definitions can contain movements this build
/// doesn't know yet.
public enum Movement {
    public static let run = "run"
    public static let skiErg = "skiErg"
    public static let sledPush = "sledPush"
    public static let sledPull = "sledPull"
    public static let burpeeBroadJumps = "burpeeBroadJumps"
    public static let row = "row"
    public static let farmersCarry = "farmersCarry"
    public static let sandbagLunges = "sandbagLunges"
    public static let wallBalls = "wallBalls"
    public static let dumbbellWalkingLunges = "dumbbellWalkingLunges"
    public static let burpees = "burpees"
    public static let medBallBoxStepOvers = "medBallBoxStepOvers"
    public static let devilPress = "devilPress"
    public static let dumbbellOverShoulder = "dumbbellOverShoulder"
    public static let airSquats = "airSquats"
    public static let kettlebellSwings = "kettlebellSwings"
    public static let pullUps = "pullUps"
    public static let thrusters = "thrusters"
    public static let lateralBurpeeOverDumbbell = "lateralBurpeeOverDumbbell"
    public static let doubleUnders = "doubleUnders"
    public static let dumbbellSnatch = "dumbbellSnatch"
    public static let rest = "rest"

    private static let names: [String: String] = [
        "run": "Run",
        "skiErg": "SkiErg",
        "sledPush": "Sled Push",
        "sledPull": "Sled Pull",
        "burpeeBroadJumps": "Burpee Broad Jumps",
        "row": "Row",
        "farmersCarry": "Farmers Carry",
        "sandbagLunges": "Sandbag Lunges",
        "wallBalls": "Wall Balls",
        "dumbbellWalkingLunges": "DB Walking Lunges",
        "burpees": "Burpees",
        "medBallBoxStepOvers": "Med Ball Box Step-Overs",
        "devilPress": "Devil Press",
        "dumbbellOverShoulder": "DB Over-Shoulder",
        "airSquats": "Air Squats",
        "kettlebellSwings": "KB Swings",
        "pullUps": "Pull-ups",
        "thrusters": "Thrusters",
        "lateralBurpeeOverDumbbell": "Lateral Burpee Over DB",
        "doubleUnders": "Double Unders",
        "dumbbellSnatch": "Alt. DB Snatch",
        "rest": "Rest"
    ]

    /// Display name; falls back to the id.
    public static func displayName(_ id: String) -> String {
        if let n = names[id] { return n }
        return id
    }
}

public enum WorkoutFormat: String, Codable { case forTime, amrap, emom }
public enum TeamFormat: String, Codable { case solo, doubles, team }

public struct WorkoutDefinition: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var shortName: String
    public var format: WorkoutFormat
    public var team: TeamFormat
    public var timeCapSeconds: Double?
    public var healthKitActivity: String
    public var segments: [WorkoutSegment]
    /// "Every N:00" workouts: sets start on multiples of this from the workout start, so a
    /// rest segment without its own duration ends on the next boundary. Optional in JSON.
    public var intervalSeconds: Double?
    /// Segments per round (or per set, rest included) when the segment list repeats, e.g.
    /// Helen 3, AMRAP 20 4, Row + Thrusters 3, HYROX 2 (run + station). The last round may be
    /// partial (Row + Thrusters has no rest after set 6). Optional in JSON (older files: nil,
    /// and WorkoutSummary detects the pattern).
    public var roundSize: Int?

    public init(id: String, name: String, shortName: String, format: WorkoutFormat,
                team: TeamFormat, timeCapSeconds: Double?, healthKitActivity: String,
                segments: [WorkoutSegment], intervalSeconds: Double? = nil,
                roundSize: Int? = nil) {
        self.intervalSeconds = intervalSeconds
        self.roundSize = roundSize
        self.id = id
        self.name = name
        self.shortName = shortName
        self.format = format
        self.team = team
        self.timeCapSeconds = timeCapSeconds
        self.healthKitActivity = healthKitActivity
        self.segments = segments
    }

    public var runCount: Int {
        return segments.filter { (s: WorkoutSegment) -> Bool in s.kind == .run }.count
    }

    public var stationCount: Int {
        return segments.filter { (s: WorkoutSegment) -> Bool in s.kind == .station }.count
    }
}
