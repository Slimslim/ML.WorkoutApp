import Foundation

/// Which saved results belong to a workout (the history under a workout's preview, the "last"
/// score on the Choose rows).
///
/// The same workout can reach the phone under more than one id: a built-in on a branch that was
/// never merged ("wod.freedom") and the library row of the same day ("lib.pitfire.20261102.freedom").
/// Two definitions are the same workout when their ids are equal, or when their names match once
/// normalized AND their segments have the same kinds and movements in the same order. Targets and
/// loads are left out on purpose: a load typed differently (85 kg vs 155 lb) is still the workout.
///
/// Port of tools/barpath/workout_history.py.
public enum WorkoutHistory {

    /// Lowercased, accents and width folded, every run of characters that are not letters or
    /// digits turned into one space, trimmed: "Every 1:00 × 8: Power C&J" → "every 1 00 8 power c j".
    public static func normalizedName(_ name: String) -> String {
        let folded: String = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        var words: [String] = []
        var current: String = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words.joined(separator: " ")
    }

    /// "station:row", "rest:rest", one per segment, in order.
    public static func movementSequence(_ d: WorkoutDefinition) -> [String] {
        return d.segments.map { (s: WorkoutSegment) -> String in s.kind.rawValue + ":" + s.movement }
    }

    /// Same id, or same normalized (non-empty) name and the same segment kinds and movements.
    public static func isSameWorkout(_ a: WorkoutDefinition, _ b: WorkoutDefinition) -> Bool {
        if a.id == b.id {
            return true
        }
        let nameA: String = normalizedName(a.name)
        if nameA.isEmpty || nameA != normalizedName(b.name) {
            return false
        }
        return movementSequence(a) == movementSequence(b)
    }

    /// Results of this workout, newest start first.
    public static func results(of definition: WorkoutDefinition, in results: [WorkoutResult]) -> [WorkoutResult] {
        let matching: [WorkoutResult] = results.filter { (r: WorkoutResult) -> Bool in
            isSameWorkout(definition, r.definition)
        }
        return matching.sorted { (x: WorkoutResult, y: WorkoutResult) -> Bool in x.startDate > y.startDate }
    }

    /// The newest result of this workout.
    public static func latest(of definition: WorkoutDefinition, in results: [WorkoutResult]) -> WorkoutResult? {
        var best: WorkoutResult? = nil
        for r in results where isSameWorkout(definition, r.definition) {
            if let b = best {
                if r.startDate > b.startDate { best = r }
            } else {
                best = r
            }
        }
        return best
    }
}
