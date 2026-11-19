import Foundation

/// One line of the results page's insight block (docs/RESULTS_INSIGHTS.md, story W47).
/// `id` is the rule id ("A1", "A2", "A3", "F1", "F2", "F5", "L1", "R1", "E3", "CHECK" for a
/// timing warning, "CUE" for the "next time" cue). `text` is ready to show.
public struct ResultInsight: Equatable, Codable {
    public let id: String
    public let text: String
    public let isCue: Bool

    public init(id: String, text: String, isCue: Bool) {
        self.id = id
        self.text = text
        self.isCue = isCue
    }
}

/// Insight rules for the results page. Port of tools/barpath/result_insights.py (the reference);
/// ResultInsightsTests checks both on Fixtures/result_insights_cases.json.
///
/// At most 3 insights plus at most 1 cue (always last). Silence beats an unsupported insight:
/// with nothing that passes the rules the list is empty.
///
/// Data honesty (spec §3), applied before any rule:
/// - only completed run and station segments count: rest and transition segments never enter the
///   numbers, nor does the segment cut by the cap / end;
/// - a segment shorter than 5 s, or longer than 3x the median of its movement (per target unit
///   when all of the movement's targets share a unit), is ignored and "Check your timing on
///   round N" is shown instead (id "CHECK");
/// - texts speak of segment times only (no speed, pace or cause); heart rate is not used.
public enum ResultInsights {
    static let maxInsights: Int = 3
    static let minSegmentSeconds: Double = 5.0
    static let outlierFactor: Double = 3.0
    static let steadyFraction: Double = 0.05
    static let driftMinSeconds: Double = 10.0
    static let driftMinFraction: Double = 0.05
    static let a3MinRoundFraction: Double = 0.08
    static let halvesMinFraction: Double = 0.05
    static let runFadeMinFraction: Double = 0.05
    static let startedHardFraction: Double = 0.08
    static let ladderFraction: Double = 0.20

    public static func insights(result: WorkoutResult, definition: WorkoutDefinition) -> [ResultInsight] {
        let ctx: InsightContext = InsightContext(result: result, definition: definition)
        let format: WorkoutFormat = definition.format

        let check: ResultInsight? = checkInsight(ctx)
        let budget: Int = maxInsights - (check != nil ? 1 : 0)
        var out: [ResultInsight] = []
        var drift: Drift? = nil
        var runRuleDone: Bool = false

        let order: [String]
        if format == .emom {
            order = ["E3"]
        } else if ctx.ladder {
            order = ["L1", "R1", "F5", "E3"]
        } else if ctx.roundsOK {
            if format == .amrap {
                order = ["DRIFT", "A3", "A2", "R1", "F5", "E3"]
            } else {
                order = ["DRIFT", "F1", "A3", "A2", "R1", "F5", "E3"]
            }
        } else {
            order = ["R1", "F5", "E3"]
        }

        for rule in order {
            if out.count >= budget { break }
            var item: ResultInsight? = nil
            switch rule {
            case "DRIFT":
                drift = findDrift(ctx)
                if let d = drift {
                    item = ResultInsight(id: format == .amrap ? "A1" : "F2", text: driftText(d), isCue: false)
                    if d.key.hasPrefix("run|") { runRuleDone = true }
                }
            case "A3":
                if let d = drift { item = intoScore(ctx, d) }
            case "A2":
                item = steady(ctx, driftKey: drift?.key)
            case "F1":
                item = halves(ctx)
            case "L1":
                item = ladderInsight(ctx)
            case "R1":
                if !runRuleDone {
                    item = startedHard(ctx)
                    if item != nil { runRuleDone = true }
                }
            case "F5":
                if !runRuleDone && format == .forTime { item = runFade(ctx) }
            case "E3":
                item = heaviest(ctx)
            default:
                break
            }
            if let i = item { out.append(i) }
        }

        if let c = check { out.append(c) }
        if let d = drift, out.contains(where: { (i: ResultInsight) -> Bool in i.id == "A1" || i.id == "F2" }) {
            let cueTime: Double = Double(roundHalfAway(d.t0 / 5.0)) * 5.0
            out.append(ResultInsight(id: "CUE", text: "Next time: hold the \(d.name) nearer \(timeText(cueTime)).",
                                     isCue: true))
        }
        return out
    }

    // MARK: - Formatting (same rounding as Python: half away from zero)

    static func roundHalfAway(_ x: Double) -> Int {
        let r: Double = (abs(x) + 0.5).rounded(.down)
        return x < 0 ? -Int(r) : Int(r)
    }

    /// m:ss (h:mm:ss from one hour) of the absolute value, rounded to the second.
    public static func timeText(_ seconds: Double) -> String {
        let total: Int = roundHalfAway(abs(seconds))
        let h: Int = total / 3600
        let m: Int = (total % 3600) / 60
        let s: Int = total % 60
        if h > 0 { return String(format: "%ld:%02ld:%02ld", h, m, s) }
        return String(format: "%ld:%02ld", m, s)
    }

    /// "+22 %", "-6 %", "+0 %".
    public static func percentText(_ fraction: Double) -> String {
        let p: Int = roundHalfAway(fraction * 100.0)
        return p >= 0 ? "+\(p) %" : "-\(-p) %"
    }

    static func numberText(_ v: Double) -> String {
        if v == v.rounded() { return String(Int(v)) }
        return String(format: "%.1f", v)
    }

    static func loadText(_ load: SegmentLoad) -> String {
        let v: String = numberText(load.value) + " " + load.unit.rawValue
        return load.count > 1 ? "\(load.count) × " + v : v
    }

    static func joinAnd(_ items: [String]) -> String {
        if items.isEmpty { return "" }
        if items.count == 1 { return items[0] }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    static func median(_ values: [Double]) -> Double {
        let v: [Double] = values.sorted()
        let n: Int = v.count
        if n == 0 { return 0 }
        if n % 2 == 1 { return v[n / 2] }
        return (v[n / 2 - 1] + v[n / 2]) / 2.0
    }

    /// "1:48-1:51" (one value when both ends read the same), then the suffix.
    static func rangeText(_ values: [Double], suffix: String = "") -> String {
        var lo: Double = values[0]
        var hi: Double = values[0]
        for v in values {
            if v < lo { lo = v }
            if v > hi { hi = v }
        }
        let a: String = timeText(lo)
        let b: String = timeText(hi)
        return (a == b ? a : a + "-" + b) + suffix
    }

    static let roundWords: [(Double, String)] = [
        (0.1, "a tenth of a round"),
        (0.2, "a fifth of a round"),
        (0.25, "a quarter of a round"),
        (1.0 / 3.0, "a third of a round"),
        (0.5, "half a round"),
        (2.0 / 3.0, "two thirds of a round"),
        (0.75, "three quarters of a round"),
        (1.0, "a full round")
    ]

    static func roundFractionText(_ f: Double) -> String {
        if f < 1.25 {
            var best: (Double, String) = roundWords[0]
            var bestDiff: Double = abs(f - best.0)
            for item in roundWords.dropFirst() {
                let d: Double = abs(f - item.0)
                if d < bestDiff {
                    best = item
                    bestDiff = d
                }
            }
            return best.1
        }
        let halves: Int = roundHalfAway(f * 2.0)
        return numberText(Double(halves) / 2.0) + " rounds"
    }

    // MARK: - Definition structure

    static func sameTarget(_ a: SegmentTarget?, _ b: SegmentTarget?) -> Bool {
        guard let x = a, let y = b else { return a == nil && b == nil }
        return x.value == y.value && x.unit == y.unit
    }

    static func sameLoad(_ a: SegmentLoad?, _ b: SegmentLoad?) -> Bool {
        guard let x = a, let y = b else { return a == nil && b == nil }
        return x.value == y.value && x.unit == y.unit && x.count == y.count
    }

    /// A work segment says which movement it is. Free Workout "part" segments do not: two parts
    /// are usually different movements, so they are never compared and never grouped.
    public static func isKnown(_ s: WorkoutSegment) -> Bool {
        return !isWork(s.kind) || (s.movement != Movement.part && !s.movement.isEmpty)
    }

    static func sameMovement(_ a: WorkoutSegment, _ b: WorkoutSegment) -> Bool {
        return isKnown(a) && isKnown(b) && a.kind == b.kind && a.movement == b.movement
    }

    static func comparable(_ a: WorkoutSegment, _ b: WorkoutSegment) -> Bool {
        return sameMovement(a, b) && sameTarget(a.target, b.target) && sameLoad(a.load, b.load)
    }

    /// segments[i] matches segments[i % period] for every i, and at least two full rounds.
    static func repeats(_ segments: [WorkoutSegment], period: Int,
                        _ eq: (WorkoutSegment, WorkoutSegment) -> Bool) -> Bool {
        if period <= 0 || segments.count < 2 * period { return false }
        for i in period..<segments.count where !eq(segments[i], segments[i % period]) {
            return false
        }
        return true
    }

    /// Segments per round when the (kind, movement) list repeats: the definition's roundSize if it
    /// repeats, else the shortest repeating period. Nil for chippers and run + station races.
    public static func roundSize(_ definition: WorkoutDefinition) -> Int? {
        let segs: [WorkoutSegment] = definition.segments
        if let r = definition.roundSize, r > 0 {
            return repeats(segs, period: r, sameMovement) ? r : nil
        }
        let n: Int = segs.count
        if n < 2 { return nil }
        for p in 1...(n / 2) where repeats(segs, period: p, sameMovement) {
            return p
        }
        return nil
    }

    /// Some movement appears with different rep targets (21-15-9, 2-4-6 ...).
    public static func isLadder(_ definition: WorkoutDefinition) -> Bool {
        var seen: [String: Double] = [:]
        for s in definition.segments {
            guard isWork(s.kind), isKnown(s), let t = s.target, t.unit == .reps else { continue }
            let key: String = movementKey(s)
            if let v = seen[key] {
                if v != t.value { return true }
            } else {
                seen[key] = t.value
            }
        }
        return false
    }

    static func isWork(_ kind: SegmentKind) -> Bool {
        return kind == .run || kind == .station
    }

    static func movementKey(_ s: WorkoutSegment) -> String {
        return s.kind.rawValue + "|" + s.movement
    }

    // MARK: - Rules

    struct Drift {
        let key: String
        let name: String
        let t0: Double
        let later: [Double]
        let extra: Double
        let fraction: Double
    }

    /// Movement times per later round (present ones only), round 1 first.
    static func laterRounds(_ ctx: InsightContext, key: String) -> (Double, [Double])? {
        guard let t0 = ctx.movementRoundTime(key: key, round: 0), t0 > 0 else { return nil }
        var later: [Double] = []
        if ctx.roundCount > 1 {
            for r in 1..<ctx.roundCount {
                if let t = ctx.movementRoundTime(key: key, round: r) { later.append(t) }
            }
        }
        return (t0, later)
    }

    /// A1 / F2: the movement whose segment time cost the most extra seconds vs its own round 1.
    static func findDrift(_ ctx: InsightContext) -> Drift? {
        var best: Drift? = nil
        for (key, name) in ctx.movements() {
            guard let pair = laterRounds(ctx, key: key), !pair.1.isEmpty else { continue }
            let t0: Double = pair.0
            let later: [Double] = pair.1
            var extra: Double = 0
            for t in later { extra += t - t0 }
            let fraction: Double = (extra / Double(later.count)) / t0
            if best == nil || extra > best!.extra {
                best = Drift(key: key, name: name, t0: t0, later: later, extra: extra, fraction: fraction)
            }
        }
        guard let b = best, b.extra >= driftMinSeconds, b.fraction >= driftMinFraction else { return nil }
        return b
    }

    static func driftText(_ d: Drift) -> String {
        return "\(d.name): \(timeText(d.t0)) in round 1, then \(rangeText(d.later)) "
            + "(\(percentText(d.fraction))), \(timeText(d.extra)) in total."
    }

    /// A2: movements within ±5 % of their round-1 time in every later round (2+ later rounds).
    static func steady(_ ctx: InsightContext, driftKey: String?) -> ResultInsight? {
        var names: [String] = []
        for (key, name) in ctx.movements() {
            if let dk = driftKey, dk == key { continue }
            guard let pair = laterRounds(ctx, key: key), pair.1.count >= 2 else { continue }
            let t0: Double = pair.0
            let later: [Double] = pair.1
            var held: Bool = true
            for t in later where abs(t - t0) / t0 > steadyFraction {
                held = false
            }
            if held { names.append(name) }
        }
        if names.isEmpty { return nil }
        return ResultInsight(id: "A2", text: "\(joinAnd(names)) held within 5 %.", isCue: false)
    }

    /// A3: the drift's extra seconds as a share of the average round work time.
    static func intoScore(_ ctx: InsightContext, _ drift: Drift) -> ResultInsight? {
        var works: [Double] = []
        for r in 0..<ctx.roundCount {
            if let w = ctx.roundWorkTime(round: r) { works.append(w) }
        }
        if works.isEmpty { return nil }
        var total: Double = 0
        for w in works { total += w }
        let avg: Double = total / Double(works.count)
        if avg <= 0 { return nil }
        let f: Double = drift.extra / avg
        if f < a3MinRoundFraction { return nil }
        return ResultInsight(id: "A3", text: "That drift added \(timeText(drift.extra)), about \(roundFractionText(f)).",
                             isCue: false)
    }

    static func roundsLabel(_ a: Int, _ b: Int, capital: Bool) -> String {
        let word: String = capital ? "Round" : "round"
        if a == b { return "\(word) \(a)" }
        return "\(word)s \(a)-\(b)"
    }

    /// F1: second half vs first half of the rounds, work time only.
    static func halves(_ ctx: InsightContext) -> ResultInsight? {
        let n: Int = ctx.roundCount
        let h: Int = n / 2
        if h < 1 { return nil }
        var works: [Double] = []
        for r in 0..<n {
            guard let w = ctx.roundWorkTime(round: r) else { return nil }
            works.append(w)
        }
        var first: Double = 0
        for r in 0..<h { first += works[r] }
        var second: Double = 0
        for r in (n - h)..<n { second += works[r] }
        if first <= 0 { return nil }
        let diff: Double = second - first
        let fraction: Double = diff / first
        if abs(fraction) < halvesMinFraction { return nil }
        let later: String = roundsLabel(n - h + 1, n, capital: true)
        let earlier: String = roundsLabel(1, h, capital: false)
        let word: String = diff > 0 ? "longer" : "less"
        return ResultInsight(id: "F1",
                             text: "\(later) took \(timeText(diff)) \(word) than \(earlier) (\(percentText(fraction))).",
                             isCue: false)
    }

    /// L1: a ladder segment whose time is more than 20 % off its share of the movement's reps.
    static func ladderInsight(_ ctx: InsightContext) -> ResultInsight? {
        var bestDeviation: Double = 0
        var bestText: String? = nil
        for (key, name) in ctx.movements() {
            var entries: [(SegmentResult, Double)] = []
            for s in ctx.segments {
                guard let clean = ctx.clean[s.index], let d = ctx.definitionSegment(s.index) else { continue }
                guard movementKey(d) == key, let t = d.target, t.unit == .reps, t.value > 0 else { continue }
                entries.append((clean, t.value))
            }
            if entries.count < 2 { continue }
            var totalReps: Double = 0
            var totalTime: Double = 0
            for (s, reps) in entries {
                totalReps += reps
                totalTime += s.duration
            }
            if totalTime <= 0 { continue }
            for (i, entry) in entries.enumerated() {
                let s: SegmentResult = entry.0
                let reps: Double = entry.1
                let deviation: Double = (s.duration / totalTime) / (reps / totalReps) - 1.0
                if bestText == nil || abs(deviation) > abs(bestDeviation) {
                    var others: [String] = []
                    for (j, other) in entries.enumerated() where j != i {
                        others.append(numberText(other.1))
                    }
                    let expected: Double = reps * (totalTime - s.duration) / (totalReps - reps)
                    let expected5: Double = Double(roundHalfAway(expected / 5.0)) * 5.0
                    bestDeviation = deviation
                    bestText = "\(name) \(numberText(reps)): \(timeText(s.duration)), "
                        + "expected about \(timeText(expected5)) from your \(joinAnd(others))."
                }
            }
        }
        guard let text = bestText, abs(bestDeviation) > ladderFraction else { return nil }
        return ResultInsight(id: "L1", text: text, isCue: false)
    }

    /// Clean runs in order with their meters: target distance, else measured (> 50 m).
    static func runs(_ ctx: InsightContext, targetOnly: Bool) -> [(SegmentResult, Double)] {
        var out: [(SegmentResult, Double)] = []
        for s in ctx.segments {
            guard let clean = ctx.clean[s.index], clean.kind == .run,
                  let d = ctx.definitionSegment(s.index) else { continue }
            if let t = d.target, t.unit == .meters, t.value > 0 {
                out.append((clean, t.value))
            } else if !targetOnly, let dist = clean.distance, dist > 50 {
                out.append((clean, dist))
            }
        }
        return out
    }

    static func allSameDistance(_ runs: [(SegmentResult, Double)]) -> Bool {
        for r in runs where r.1 != runs[0].1 { return false }
        return true
    }

    /// R1: the median of the other runs is more than 8 % slower than run 1 ("started hard, then
    /// faded" read as one condition: run 1 vs the median of the rest, strictly more than 8 %).
    static func startedHard(_ ctx: InsightContext) -> ResultInsight? {
        let list: [(SegmentResult, Double)] = runs(ctx, targetOnly: false)
        if list.count < 3 { return nil }
        let same: Bool = allSameDistance(list)
        let values: [Double] = list.map({ (r: (SegmentResult, Double)) -> Double in
            same ? r.0.duration : r.0.duration / (r.1 / 1000.0)
        })
        let first: Double = values[0]
        let rest: [Double] = Array(values.dropFirst())
        let med: Double = median(rest)
        if first <= 0 || med <= first * (1.0 + startedHardFraction) { return nil }
        let pct: String = percentText(med / first - 1.0)
        if same {
            return ResultInsight(id: "R1", text: "Started hard, then faded: run 1 in \(timeText(first)), "
                                 + "the rest \(rangeText(rest)) (\(pct) at the median).", isCue: false)
        }
        return ResultInsight(id: "R1", text: "Started hard, then faded: run 1 at \(timeText(first)) /km, "
                             + "the rest \(rangeText(rest, suffix: " /km")) (\(pct) at the median).", isCue: false)
    }

    /// F5: last run vs first run, from the target distance.
    static func runFade(_ ctx: InsightContext) -> ResultInsight? {
        let list: [(SegmentResult, Double)] = runs(ctx, targetOnly: true)
        if list.count < 2 { return nil }
        let a: (SegmentResult, Double) = list[0]
        let b: (SegmentResult, Double) = list[list.count - 1]
        let same: Bool = allSameDistance(list)
        let first: Double = same ? a.0.duration : a.0.duration / (a.1 / 1000.0)
        let last: Double = same ? b.0.duration : b.0.duration / (b.1 / 1000.0)
        if first <= 0 { return nil }
        let fraction: Double = last / first - 1.0
        if abs(fraction) < runFadeMinFraction { return nil }
        let unit: String = same ? "" : " /km"
        return ResultInsight(id: "F5", text: "Runs: first \(timeText(first))\(unit), last \(timeText(last))\(unit) "
                             + "(\(percentText(fraction))).", isCue: false)
    }

    /// E3: heaviest completed load and the loads ladder, for a movement done at 2+ loads.
    static func heaviest(_ ctx: InsightContext) -> ResultInsight? {
        for (key, name) in ctx.movements() {
            var loads: [SegmentLoad] = []
            for s in ctx.usable {
                guard let d = ctx.definitionSegment(s.index), movementKey(d) == key, let load = d.load else { continue }
                if !loads.contains(where: { (x: SegmentLoad) -> Bool in sameLoad(x, load) }) {
                    loads.append(load)
                }
            }
            if loads.count < 2 { continue }
            var top: SegmentLoad = loads[0]
            for x in loads.dropFirst() where x.kilograms > top.kilograms {
                top = x
            }
            var compact: Bool = true
            for x in loads where x.unit != loads[0].unit || x.count != 1 {
                compact = false
            }
            let ladder: String
            if compact {
                ladder = loads.map({ (x: SegmentLoad) -> String in numberText(x.value) }).joined(separator: " → ")
                    + " " + loads[0].unit.rawValue
            } else {
                ladder = loads.map({ (x: SegmentLoad) -> String in loadText(x) }).joined(separator: " → ")
            }
            return ResultInsight(id: "E3", text: "\(name): heaviest \(loadText(top)). Loads \(ladder).", isCue: false)
        }
        return nil
    }

    /// "Check your timing on round 2." for segments the honesty filter set aside.
    static func checkInsight(_ ctx: InsightContext) -> ResultInsight? {
        if ctx.flagged.isEmpty { return nil }
        if let rs = ctx.roundSize {
            var rounds: [Int] = []
            for s in ctx.flagged {
                let r: Int = s.index / rs + 1
                if !rounds.contains(r) { rounds.append(r) }
            }
            let word: String = rounds.count == 1 ? "round" : "rounds"
            let list: [String] = rounds.map({ (r: Int) -> String in String(r) })
            return ResultInsight(id: "CHECK", text: "Check your timing on \(word) \(joinAnd(list)).", isCue: false)
        }
        if ctx.flagged.count == 1 {
            let s: SegmentResult = ctx.flagged[0]
            let title: String = ctx.definitionSegment(s.index)?.title ?? s.title
            return ResultInsight(id: "CHECK", text: "Check your timing on \(title) (segment \(s.index + 1)).",
                                 isCue: false)
        }
        let numbers: [String] = ctx.flagged.map({ (s: SegmentResult) -> String in String(s.index + 1) })
        return ResultInsight(id: "CHECK", text: "Check your timing on segments \(joinAnd(numbers)).", isCue: false)
    }
}

// MARK: - Context (internal)

struct InsightContext {
    let definition: WorkoutDefinition
    /// Recorded segments sorted by index.
    let segments: [SegmentResult]
    /// Completed run / station segments that match their definition segment.
    let usable: [SegmentResult]
    /// Usable segments set aside by the honesty filter (< 5 s or > 3x the movement's median).
    let flagged: [SegmentResult]
    /// Usable and not flagged, by segment index.
    let clean: [Int: SegmentResult]
    let roundSize: Int?
    let ladder: Bool
    /// Rounds repeat exactly (same movements, targets and loads): the A rules and F1 apply.
    let roundsOK: Bool
    let roundCount: Int

    init(result: WorkoutResult, definition: WorkoutDefinition) {
        self.definition = definition
        let sorted: [SegmentResult] = result.segments.sorted(by: { (a: SegmentResult, b: SegmentResult) -> Bool in
            a.index < b.index
        })
        self.segments = sorted
        let finished: Bool = result.finishDate != nil && sorted.count >= definition.segments.count
        let lastIndex: Int = sorted.last?.index ?? -1

        var usable: [SegmentResult] = []
        for s in sorted {
            guard s.index >= 0, s.index < definition.segments.count else { continue }
            let d: WorkoutSegment = definition.segments[s.index]
            if !ResultInsights.isWork(s.kind) || d.kind != s.kind || d.movement != s.movement { continue }
            if !ResultInsights.isKnown(d) || !s.duration.isFinite { continue }
            if !finished && s.index == lastIndex { continue }
            usable.append(s)
        }
        self.usable = usable

        let flagged: [SegmentResult] = InsightContext.honestyFilter(usable, definition: definition)
        self.flagged = flagged
        var flaggedIndices: Set<Int> = []
        for s in flagged { flaggedIndices.insert(s.index) }
        var clean: [Int: SegmentResult] = [:]
        for s in usable where !flaggedIndices.contains(s.index) {
            clean[s.index] = s
        }
        self.clean = clean

        let rs: Int? = ResultInsights.roundSize(definition)
        self.roundSize = rs
        let ladder: Bool = ResultInsights.isLadder(definition)
        self.ladder = ladder
        if let r = rs, !ladder {
            self.roundsOK = ResultInsights.repeats(definition.segments, period: r, ResultInsights.comparable)
        } else {
            self.roundsOK = false
        }
        if let r = rs {
            self.roundCount = (definition.segments.count + r - 1) / r
        } else {
            self.roundCount = 0
        }
    }

    static func honestyFilter(_ usable: [SegmentResult], definition: WorkoutDefinition) -> [SegmentResult] {
        var groups: [String: [SegmentResult]] = [:]
        var order: [String] = []
        for s in usable {
            let key: String = s.kind.rawValue + "|" + s.movement
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append(s)
        }
        var flagged: [SegmentResult] = []
        for m in order {
            let group: [SegmentResult] = groups[m] ?? []
            let targets: [SegmentTarget?] = group.map({ (s: SegmentResult) -> SegmentTarget? in
                definition.segments[s.index].target
            })
            var perUnit: Bool = true
            let firstUnit: TargetUnit? = targets.first.flatMap({ (t: SegmentTarget?) -> TargetUnit? in t?.unit })
            for t in targets {
                guard let x = t, x.value > 0, let u = firstUnit, x.unit == u else {
                    perUnit = false
                    break
                }
            }
            var values: [Double] = []
            for (i, s) in group.enumerated() {
                if perUnit, let t = targets[i] {
                    values.append(s.duration / t.value)
                } else {
                    values.append(s.duration)
                }
            }
            let med: Double = ResultInsights.median(values)
            for (i, s) in group.enumerated()
                where s.duration < ResultInsights.minSegmentSeconds
                    || (med > 0 && values[i] > ResultInsights.outlierFactor * med) {
                flagged.append(s)
            }
        }
        flagged.sort(by: { (a: SegmentResult, b: SegmentResult) -> Bool in a.index < b.index })
        return flagged
    }

    func definitionSegment(_ index: Int) -> WorkoutSegment? {
        if index >= 0 && index < definition.segments.count { return definition.segments[index] }
        return nil
    }

    /// Work movements in order of first appearance in the definition: (kind|movement, name).
    func movements() -> [(String, String)] {
        var out: [(String, String)] = []
        var seen: Set<String> = []
        for d in definition.segments where ResultInsights.isWork(d.kind) && ResultInsights.isKnown(d) {
            let key: String = ResultInsights.movementKey(d)
            if !seen.contains(key) {
                seen.insert(key)
                out.append((key, d.name))
            }
        }
        return out
    }

    func roundIndices(_ round: Int) -> [Int] {
        guard let rs = roundSize, rs > 0 else { return [] }
        let lo: Int = round * rs
        let hi: Int = Swift.min(definition.segments.count, lo + rs)
        if hi <= lo { return [] }
        return Array(lo..<hi)
    }

    /// Sum of the movement's segment times in a round; nil unless all of them are clean.
    func movementRoundTime(key: String, round: Int) -> Double? {
        var total: Double = 0
        var found: Bool = false
        for i in roundIndices(round) {
            let d: WorkoutSegment = definition.segments[i]
            if !ResultInsights.isWork(d.kind) || ResultInsights.movementKey(d) != key { continue }
            guard let s = clean[i] else { return nil }
            total += s.duration
            found = true
        }
        return found ? total : nil
    }

    /// Work time of a round (rest excluded); nil unless every work segment is clean.
    func roundWorkTime(round: Int) -> Double? {
        var total: Double = 0
        var found: Bool = false
        for i in roundIndices(round) {
            let d: WorkoutSegment = definition.segments[i]
            if !ResultInsights.isWork(d.kind) { continue }
            guard let s = clean[i] else { return nil }
            total += s.duration
            found = true
        }
        return found ? total : nil
    }
}
