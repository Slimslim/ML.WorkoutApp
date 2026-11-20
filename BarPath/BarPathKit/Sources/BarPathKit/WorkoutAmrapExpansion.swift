import Foundation

/// An AMRAP must not run out of list before its cap (#138). The watch's progress finishes on the
/// last listed segment whatever the format, so a library AMRAP that lists one pass offered
/// Finish with minutes left. At workout start the watch runs `expandedForAmrap()`: the
/// repeating round is written out until the list is long enough, and `roundSize` is set so the
/// watch, the result and the summary count rounds. Python mirror: `amrap_expanded` in
/// tools/barpath/workout.py; shared cases in Fixtures/amrap_expand_cases.json.
extension WorkoutDefinition {

    /// Rounds an expanded AMRAP lists at least (no one finishes 30 rounds before a cap).
    public static let amrapMinListedRounds: Int = 30
    /// Upper bound on the expanded list: a long round gets fewer rounds (never fewer than listed).
    public static let amrapMaxSegments: Int = 600

    /// For an AMRAP with a time cap: the definition with its last full round repeated until it
    /// lists `amrapMinListedRounds` rounds (fewer when that would pass `amrapMaxSegments`), and
    /// `roundSize` set (not when an interval is set without one). The round is `roundSize`
    /// segments; when `roundSize` is missing or out of range, the smallest exact repeat of the
    /// list (`exactRepeatPeriod`), else the whole list. Unchanged: other formats, no cap, an empty list, a list that is
    /// not whole rounds (no clear repeating unit), or a list that is already long enough with
    /// its `roundSize` set. Expanding twice gives the same result (safe on restore).
    public func expandedForAmrap() -> WorkoutDefinition {
        guard format == .amrap, let cap = timeCapSeconds, cap > 0 else { return self }
        let n: Int = segments.count
        if n == 0 { return self }
        var r: Int = WorkoutDefinition.exactRepeatPeriod(segments)
        if let rs = roundSize, rs >= 1, rs <= n {
            r = rs
        }
        if n % r != 0 { return self }
        let listed: Int = n / r
        let fit: Int = Swift.max(1, WorkoutDefinition.amrapMaxSegments / r)
        let target: Int = Swift.max(listed, Swift.min(WorkoutDefinition.amrapMinListedRounds, fit))
        if target == listed && roundSize == r { return self }

        let block: [WorkoutSegment] = Array(segments[(n - r)..<n])
        var expanded: [WorkoutSegment] = segments
        var k: Int = listed
        while k < target {
            expanded.append(contentsOf: block)
            k += 1
        }
        var d: WorkoutDefinition = self
        d.segments = expanded
        // With an interval and no roundSize, setting one would turn on the interval jump for
        // work segments (WorkoutProgress.autoAdvanceTime): keep it unset there.
        if roundSize != nil || (intervalSeconds ?? 0) <= 0 {
            d.roundSize = r
        }
        return d
    }

    /// Smallest p that divides the list into at least two identical rounds (segments equal,
    /// targets included), else the whole list. A ladder without roundSize is one round.
    static func exactRepeatPeriod(_ segments: [WorkoutSegment]) -> Int {
        let n: Int = segments.count
        if n < 2 { return n }
        for p in 1...(n / 2) where n % p == 0 {
            var same: Bool = true
            for i in p..<n where segments[i] != segments[i % p] {
                same = false
                break
            }
            if same { return p }
        }
        return n
    }
}
