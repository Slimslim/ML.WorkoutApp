import Foundation

/// Which motion rate a workout is recorded at (docs/RECORDING_PLAN.md). Pure rule, no I/O.
/// Swift port of `tools/barpath/recording_profile.py`; both read the same table of cases
/// (`Fixtures/recording_profile_cases.json`).
///
/// `.high` (200 Hz, CMBatchedSensorManager) when any segment is a barbell / dumbbell / kettlebell
/// strength or Olympic movement; `.standard` (100 Hz) otherwise. Locomotion and machines (step-ups,
/// runs, rucks, carries, lunges, sleds, ergs, bikes) stay `.standard` even with an external load, so
/// long simple pieces (Chad 1000X, 60+ min) do not outgrow the 50 MB upload limit at 200 Hz.
public enum RecordingProfile: String {
    case standard
    case high

    /// Nominal device-motion rate of the profile.
    public var sampleRateHz: Int {
        switch self {
        case .standard: return 100
        case .high: return 200
        }
    }

    // MARK: Keywords (matched on the lower-case ASCII words of an id / name, joined)

    static let excluded: [String] = [
        "airsquat", "bodyweightsquat", "bwsquat", "jumpsquat", "squatjump", "pistolsquat", "pistol",
        "pushup", "pressup", "wallball", "burpee", "curlup", "benchdip", "benchjump", "benchstep"
    ]
    static let keywords: [String] = [
        "snatch", "clean", "jerk", "cleanandjerk", "cj", "press", "deadlift", "squat", "thruster",
        "curl", "swing", "bench", "overshoulder", "highpull", "shrug", "goodmorning", "hipthrust",
        "windmill", "turkishgetup", "bentoverrow", "barbellrow", "dumbbellrow", "kettlebellrow",
        "pendlayrow", "tbarrow", "uprightrow", "singlearmrow", "renegaderow", "gorillarow",
        "dbrow", "bbrow", "kbrow"
    ]
    static let wordKeywords: [String] = ["ohp", "rdl"]
    static let locomotion: [String] = [
        "stepup", "stepover", "ruck", "carry", "lunge", "sled", "walk", "skierg", "rowerg", "bikeerg",
        "assaultbike", "echobike", "sandbag", "vest"
    ]
    static let locomotionWords: [String] = ["run", "row", "bike", "erg", "ruck", "hike"]
    static let skippedKinds: [SegmentKind] = [.run, .rest, .transition]

    // MARK: Rule

    /// `.high` when any segment of the planned workout needs the high rate.
    public static func profile(for definition: WorkoutDefinition) -> RecordingProfile {
        for s in definition.segments {
            if segmentIsHigh(kind: s.kind, movement: s.movement, name: s.name, hasLoad: s.load != nil) {
                return .high
            }
        }
        return .standard
    }

    public static func segmentIsHigh(kind: SegmentKind, movement: String, name: String,
                                     hasLoad: Bool) -> Bool {
        if skippedKinds.contains(kind) { return false }
        let a = classify(movement)
        let b = classify(name)
        if a.high || b.high { return true }
        if a.excluded || b.excluded { return false }
        return hasLoad
    }

    // MARK: Location (GPS)

    /// Decided once at START for the whole session, from the planned workout only: GPS is on when
    /// the plan has at least one segment of kind `.run`. Free Workout and plans without a run: off.
    /// Independent of the rate rule above. Mirror of `uses_location` in the Python reference.
    public static func usesLocation(for definition: WorkoutDefinition) -> Bool {
        return usesLocation(kinds: definition.segments.map { (s: WorkoutSegment) -> SegmentKind in s.kind })
    }

    public static func usesLocation(kinds: [SegmentKind]) -> Bool {
        return kinds.contains(.run)
    }

    /// Lower-case ASCII words: boundaries at non-alphanumerics (and non-ASCII) and at a lower-case
    /// letter followed by an upper-case one.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        var cur: String = ""
        var prevLower: Bool = false
        for scalar in text.unicodeScalars {
            let v: UInt32 = scalar.value
            let isUpper: Bool = v >= 65 && v <= 90
            let isLower: Bool = v >= 97 && v <= 122
            let isDigit: Bool = v >= 48 && v <= 57
            if !(isUpper || isLower || isDigit) {
                if !cur.isEmpty { out.append(cur) }
                cur = ""
                prevLower = false
                continue
            }
            if isUpper && prevLower && !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
            let lowered: UInt32 = isUpper ? v + 32 : v
            if let u = Unicode.Scalar(lowered) {
                cur.unicodeScalars.append(u)
            }
            prevLower = isLower
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func classify(_ text: String) -> (high: Bool, excluded: Bool) {
        let ws: [String] = words(text)
        var joined: String = ws.joined()
        var isExcluded: Bool = ws.contains(where: { (w: String) -> Bool in locomotionWords.contains(w) })
        if !isExcluded {
            isExcluded = locomotion.contains(where: { (p: String) -> Bool in joined.contains(p) })
        }
        let isLocomotion: Bool = isExcluded
        for phrase in excluded where joined.contains(phrase) {
            isExcluded = true
            joined = joined.replacingOccurrences(of: phrase, with: "")
        }
        for k in keywords where joined.contains(k) {
            return (true, isExcluded)
        }
        if isLocomotion && joined.contains("barbell") {
            return (true, isExcluded)
        }
        for w in ws where wordKeywords.contains(w) {
            return (true, isExcluded)
        }
        return (false, isExcluded)
    }
}
