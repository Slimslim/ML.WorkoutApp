import Foundation

/// View model of the post-workout overview (docs/WORKOUT_OVERVIEW_V2.md). Pure Foundation,
/// built once from a WorkoutResult with `WorkoutSummary.make(result:previous:maxHeartRate:)`.
///
/// Times inside the summary are seconds from the workout start ("relative"), so the views
/// never deal with seconds since 1970. Heart-rate values are bpm. Everything is precomputed:
/// the views only lay things out and format with `SummaryFormat`.
///
/// Layout, top to bottom: `headline` (score), `timeline` (HR over the whole workout, segment
/// bands, zones), `story` (one view per format), `rows` (the split table) and `dataNote`.
/// Selection works on segment indices: every Band, run, cell, set part, round part, bar and
/// row carries `segmentIndex`; rounds and sets carry `firstSegmentIndex…lastSegmentIndex`.
public struct WorkoutSummary: Equatable {
    public let headline: Headline
    public let timeline: Timeline
    public let story: Story
    public let rows: [SplitRow]
    public let dataNote: DataNote
    /// Segments per round used for grouping (definition's `roundSize`, else detected), or nil.
    public let roundSize: Int?
    /// The previous attempt was usable for per-segment comparison (same definition id).
    public let hasPrevious: Bool
    /// Start date of the previous attempt (for "vs Oct 21"), nil without one.
    public let previousDate: Date?

    /// Builds the overview.
    /// - previous: an earlier result; it is used only when its definition id matches.
    /// - maxHeartRate: the athlete's max HR from Settings; nil → zones use
    ///   max(190, highest HR in this workout) and are flagged `zonesEstimated`.
    public static func make(result: WorkoutResult, previous: WorkoutResult?,
                            maxHeartRate: Double?) -> WorkoutSummary {
        let ctx: SummaryContext = SummaryContext(result: result, previous: previous)
        let bands: [Band] = makeBands(ctx: ctx)
        let timeline: Timeline = makeTimeline(ctx: ctx, bands: bands, maxHeartRate: maxHeartRate)
        let story: Story = makeStory(ctx: ctx, timeline: timeline)
        let headline: Headline = makeHeadline(ctx: ctx, timeline: timeline, story: story,
                                              maxHeartRateSet: (maxHeartRate ?? 0) > 0)
        let rows: [SplitRow] = makeRows(ctx: ctx, story: story)
        let note: DataNote = makeDataNote(ctx: ctx, timeline: timeline)
        return WorkoutSummary(headline: headline, timeline: timeline, story: story, rows: rows,
                              dataNote: note, roundSize: ctx.roundSize,
                              hasPrevious: ctx.previous != nil,
                              previousDate: ctx.previous?.startDate)
    }

    // MARK: - Headline

    public struct Headline: Equatable {
        /// Workout name, e.g. "Helen".
        public let title: String
        public let format: WorkoutFormat
        /// Big score: "12:47", "1:23:45" (for time), "6 / 6" (sets), "4 + 51" (AMRAP).
        public let scoreText: String
        /// Small unit after the score: nil, "sets", "rounds + reps".
        public let scoreUnit: String?
        /// Line under the score, e.g. "3 rounds for time · 3:13 under the 16:00 cap",
        /// "8 runs · 8 stations · 16 segments", "Avg work per set 1:42 · done at 17:12",
        /// "Stopped in Double Unders, 0:36 in, at the 20:00 cap".
        public let contextText: String
        /// Start to finish (or to the end when not finished), seconds.
        public let totalSeconds: Double
        /// Last segment completed (false: ended early or stopped by an AMRAP cap mid-segment).
        public let isFinished: Bool
        public let capSeconds: Double?
        /// For time: cap − total when finished under the cap (nil otherwise).
        public let underCapSeconds: Double?
        /// AMRAP: completed rounds and reps of the completed segments of the unfinished round
        /// (plus the result's `partialReps`).
        public let rounds: Int?
        public let extraReps: Int?
        /// Reps done in the segment cut by the cap / end (WorkoutResult.partialReps), nil if unknown.
        public let partialReps: Int?
        /// AMRAP / unfinished: name of the segment the workout stopped in ("Double Unders")
        /// and seconds into it.
        public let stoppedIn: String?
        public let stoppedAfterSeconds: Double?
        /// Interval workouts: sets completed / planned, average work per completed set.
        public let setsCompleted: Int?
        public let setsPlanned: Int?
        public let averageWorkSeconds: Double?
        /// Whole-workout heart rate (result values, else from the timeline).
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        /// Seconds in zones 4–5; nil without a real HR series or without a max HR setting.
        public let zone45Seconds: Double?
        /// Previous attempt (same definition id, both finished, not AMRAP).
        public let previousTotalSeconds: Double?
        public let previousDate: Date?
        /// total − previous total (negative = faster).
        public let deltaSeconds: Double?
        /// "−1:29" / "+0:12", nil without a comparable previous attempt.
        public let deltaText: String?
    }

    // MARK: - Split table

    public struct SplitRow: Equatable, Identifiable {
        public let segmentIndex: Int
        /// 1-based position in race order.
        public let number: Int
        public let title: String
        /// "R2" (round), "S3" (set) or nil, to tell repeated movements apart.
        public let groupLabel: String?
        /// title, plus " · R2" / " · S3" when there is a group label.
        public let displayTitle: String
        public let kind: SegmentKind
        public let movement: String
        public let start: Double
        /// Cumulative time at the end of this split (relative).
        public let end: Double
        public let duration: Double
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public let heartRateMin: Double?
        /// Runs only.
        public let paceSecondsPerKm: Double?
        public let isPartial: Bool
        public let previousDuration: Double?
        /// duration − previous duration (negative = faster).
        public let deltaSeconds: Double?

        public var id: Int { return segmentIndex }
    }

    // MARK: - Data note

    /// How much to trust the splits. `text` is ready to show as one grey line, e.g.
    /// "9 of 9 switches by Crown · no undos · HR per split only · steps OK" (+ " · edited"
    /// after a correction on the phone).
    public struct DataNote: Equatable {
        /// Segment switches (advance and finish events), by source.
        public let switchCount: Int
        public let crownCount: Int
        public let pressCount: Int
        public let buttonCount: Int
        public let autoCount: Int
        /// Undo and un-finish events.
        public let undoCount: Int
        /// Seconds with no HR in the 5 s series; nil when there is no real series.
        public let heartRateGapSeconds: Double?
        /// Segment with the most missing HR (when there is a gap).
        public let longestGapSegmentTitle: String?
        /// No HR series: the timeline shows segment averages.
        public let heartRateEstimated: Bool
        /// No heart rate at all.
        public let heartRateMissing: Bool
        /// No pedometer data in any segment.
        public let stepsMissing: Bool
        /// Some run has no measured distance (pace then uses the target distance).
        public let runDistanceMissing: Bool
        /// The athlete corrected the result on the phone (WorkoutResult.editedAt is set).
        public let isEdited: Bool
        public let text: String
    }

    // MARK: - Building blocks

    static func makeBands(ctx: SummaryContext) -> [Band] {
        var out: [Band] = []
        var runNumber: Int = 0
        for seg in ctx.segments {
            if seg.kind == .run { runNumber += 1 }
            let label: String = seg.kind == .run ? "R\(runNumber)"
                : WorkoutSummary.shortLabel(movement: seg.movement, kind: seg.kind, name: ctx.name(seg))
            var round: Int? = nil
            var column: Int? = nil
            if let rs = ctx.roundSize, rs > 0 {
                round = seg.index / rs
                column = seg.index % rs
            }
            out.append(Band(segmentIndex: seg.index, kind: seg.kind, movement: seg.movement,
                            title: seg.title, name: ctx.name(seg), shortLabel: label,
                            start: ctx.rel(seg.start), end: ctx.rel(seg.end), duration: seg.duration,
                            round: round, column: column, isPartial: ctx.isPartial(seg),
                            heartRateAvg: seg.heartRateAvg, heartRateMax: seg.heartRateMax,
                            heartRateMin: seg.heartRateMin, paceSecondsPerKm: ctx.pace(seg)))
        }
        return out
    }

    /// Short band label for a movement ("Ski", "KB", "Pull", "Rest"); runs use "R<n>" instead.
    public static func shortLabel(movement: String, kind: SegmentKind, name: String) -> String {
        if kind == .rest { return "Rest" }
        if kind == .transition { return "Tr" }
        if let s = shortLabels[movement] { return s }
        let trimmed: String = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "?" }
        return String(trimmed.prefix(4))
    }

    private static let shortLabels: [String: String] = [
        "run": "Run",
        "skiErg": "Ski",
        "sledPush": "Push",
        "sledPull": "Pull",
        "burpeeBroadJumps": "BBJ",
        "row": "Row",
        "farmersCarry": "Farm",
        "sandbagLunges": "Lung",
        "wallBalls": "WB",
        "dumbbellWalkingLunges": "Lung",
        "burpees": "Burp",
        "medBallBoxStepOvers": "Box",
        "devilPress": "DP",
        "dumbbellOverShoulder": "DBOS",
        "airSquats": "Sq",
        "kettlebellSwings": "KB",
        "pullUps": "Pull",
        "thrusters": "Thr",
        "lateralBurpeeOverDumbbell": "Bur",
        "doubleUnders": "DU",
        "dumbbellSnatch": "Sn",
        "rest": "Rest"
    ]

    static func makeHeadline(ctx: SummaryContext, timeline: Timeline, story: Story,
                             maxHeartRateSet: Bool) -> Headline {
        let def: WorkoutDefinition = ctx.definition
        let total: Double = ctx.duration
        let finished: Bool = ctx.isFinished
        let cap: Double? = (def.timeCapSeconds ?? 0) > 0 ? def.timeCapSeconds : nil

        var score: String = SummaryFormat.clock(total)
        var unit: String? = nil
        var context: String = ""
        var underCap: Double? = nil
        var rounds: Int? = nil
        var extraReps: Int? = nil
        var stoppedIn: String? = nil
        var stoppedAfter: Double? = nil
        var setsDone: Int? = nil
        var setsPlanned: Int? = nil
        var avgWork: Double? = nil

        if let last = ctx.segments.last, ctx.isPartial(last) {
            stoppedIn = ctx.name(last)
            stoppedAfter = last.duration
        }

        var capText: String? = nil
        if let c = cap {
            let capClock: String = SummaryFormat.clock(c)
            if finished && total <= c {
                underCap = c - total
                let left: String = SummaryFormat.clock(c - total)
                capText = left + " under the " + capClock + " cap"
            } else if finished {
                let over: String = SummaryFormat.clock(total - c)
                capText = over + " over the " + capClock + " cap"
            }
        }
        var notFinishedText: String? = nil
        if !finished {
            if let s = stoppedIn {
                notFinishedText = "Not finished · ended in " + s
            } else {
                notFinishedText = "Not finished"
            }
        }

        switch story {
        case .runsAndStations(let r):
            var parts: [String] = [plural(r.runs.count, "run"), plural(r.stations.count, "station"),
                                   plural(ctx.segments.count, "segment")]
            if let t = capText { parts.append(t) }
            if let t = notFinishedText { parts.append(t) }
            context = parts.joined(separator: " · ")
        case .roundGrid(let g):
            var parts: [String] = []
            let planned: Int = ctx.plannedRounds ?? g.rounds.count
            parts.append(plural(planned, "round") + " for time")
            if let t = capText { parts.append(t) }
            if let t = notFinishedText { parts.append(t) }
            context = parts.joined(separator: " · ")
        case .intervalSlots(let s):
            score = "\(s.setsCompleted) / \(s.setsPlanned)"
            unit = "sets"
            setsDone = s.setsCompleted
            setsPlanned = s.setsPlanned
            avgWork = s.averageWorkSeconds
            var parts: [String] = []
            if let a = s.averageWorkSeconds { parts.append("Avg work per set " + SummaryFormat.clock(a)) }
            parts.append((finished ? "done at " : "ended at ") + SummaryFormat.clock(total))
            var text: String = parts.joined(separator: " · ")
            if let first = text.first, parts.count == 1 {
                text = String(first).uppercased() + String(text.dropFirst())
            }
            context = text
        case .amrapClock(let a):
            score = "\(a.completedRounds) + \(a.extraReps)"
            unit = "rounds + reps"
            rounds = a.completedRounds
            extraReps = a.extraReps
            if let stop = a.stoppedIn {
                let secondsIn: String = SummaryFormat.clock(stop.secondsIn)
                var text: String = "Stopped in " + stop.name + ", " + secondsIn + " in"
                if let c = cap, total >= c - 1 {
                    text += ", at the " + SummaryFormat.clock(c) + " cap"
                }
                if let pr = stop.partialReps, pr > 0 {
                    text += " · +\(pr) " + stop.name
                }
                context = text
            } else if let c = cap {
                context = plural(a.completedRounds, "round") + " in " + SummaryFormat.clock(c)
            } else {
                context = plural(a.completedRounds, "round")
            }
        case .segments(let bars):
            var parts: [String] = [plural(bars.count, "segment")]
            if let t = capText { parts.append(t) }
            if let t = notFinishedText { parts.append(t) }
            context = parts.joined(separator: " · ")
        }

        // Heart rate for the whole workout.
        let all: RangeStats = timeline.stats(from: 0, to: timeline.duration)
        let hrAvg: Double? = ctx.result.heartRateAvg ?? all.average
        let hrMax: Double? = ctx.result.heartRateMax ?? all.max
        var z45: Double? = nil
        if maxHeartRateSet && !timeline.isEstimated && timeline.hasHeartRate {
            z45 = timeline.zoneSeconds[3] + timeline.zoneSeconds[4]
        }

        // Previous attempt.
        var prevTotal: Double? = nil
        var prevDate: Date? = nil
        var delta: Double? = nil
        var deltaText: String? = nil
        if let p = ctx.previous, def.format != .amrap, finished, p.finishDate != nil {
            prevTotal = p.totalSeconds
            prevDate = p.startDate
            delta = total - p.totalSeconds
            deltaText = SummaryFormat.signed(total - p.totalSeconds)
        }

        return Headline(title: def.name, format: def.format, scoreText: score, scoreUnit: unit,
                        contextText: context, totalSeconds: total, isFinished: finished,
                        capSeconds: cap, underCapSeconds: underCap, rounds: rounds, extraReps: extraReps,
                        partialReps: ctx.result.partialReps, stoppedIn: stoppedIn, stoppedAfterSeconds: stoppedAfter,
                        setsCompleted: setsDone, setsPlanned: setsPlanned, averageWorkSeconds: avgWork,
                        heartRateAvg: hrAvg, heartRateMax: hrMax, zone45Seconds: z45,
                        previousTotalSeconds: prevTotal, previousDate: prevDate,
                        deltaSeconds: delta, deltaText: deltaText)
    }

    static func makeRows(ctx: SummaryContext, story: Story) -> [SplitRow] {
        var prefix: String? = nil
        switch story {
        case .roundGrid, .amrapClock:
            prefix = "R"
        case .intervalSlots:
            prefix = "S"
        default:
            prefix = nil
        }
        var out: [SplitRow] = []
        for (i, seg) in ctx.segments.enumerated() {
            var group: String? = nil
            if let p = prefix, let rs = ctx.roundSize, rs > 0 {
                group = p + String(seg.index / rs + 1)
            }
            let display: String = group.map({ (g: String) -> String in seg.title + " · " + g }) ?? seg.title
            let prev: Double? = ctx.previousSegment(seg.index)?.duration
            let delta: Double? = prev.map({ (p: Double) -> Double in seg.duration - p })
            out.append(SplitRow(segmentIndex: seg.index, number: i + 1, title: seg.title,
                                groupLabel: group, displayTitle: display, kind: seg.kind,
                                movement: seg.movement, start: ctx.rel(seg.start), end: ctx.rel(seg.end),
                                duration: seg.duration, heartRateAvg: seg.heartRateAvg,
                                heartRateMax: seg.heartRateMax, heartRateMin: seg.heartRateMin,
                                paceSecondsPerKm: ctx.pace(seg), isPartial: ctx.isPartial(seg),
                                previousDuration: prev, deltaSeconds: delta))
        }
        return out
    }

    static func makeDataNote(ctx: SummaryContext, timeline: Timeline) -> DataNote {
        var crown: Int = 0
        var press: Int = 0
        var button: Int = 0
        var auto: Int = 0
        var undos: Int = 0
        for e in ctx.result.events {
            switch e.kind {
            case .advance, .finish:
                if let s = e.source {
                    switch s {
                    case .crown: crown += 1
                    case .press: press += 1
                    case .button: button += 1
                    case .auto: auto += 1
                    }
                }
            case .undo, .unfinish:
                undos += 1
            default:
                break
            }
        }
        let switches: Int = crown + press + button + auto

        var gapSeconds: Double? = nil
        var gapTitle: String? = nil
        if !timeline.isEstimated && timeline.hasHeartRate {
            var total: Double = 0
            for g in timeline.gaps { total += g.duration }
            gapSeconds = total
            var worst: Double = 0
            for b in timeline.bands {
                let st: RangeStats = timeline.stats(from: b.start, to: b.end)
                if st.gapSeconds > worst {
                    worst = st.gapSeconds
                    gapTitle = b.name
                }
            }
        }
        let hrMissing: Bool = !timeline.hasHeartRate
        let stepsMissing: Bool = !ctx.segments.isEmpty
            && ctx.segments.allSatisfy({ (s: SegmentResult) -> Bool in s.steps == nil })
        let runDistanceMissing: Bool = ctx.segments.contains(where: { (s: SegmentResult) -> Bool in
            s.kind == .run && (s.distance ?? 0) <= 50
        })

        var parts: [String] = []
        if switches > 0 {
            let labelled: [(Int, String)] = [(auto, "automatic"), (crown, "by Crown"),
                                             (button, "by button"), (press, "by press")]
            let used: [(Int, String)] = labelled
                .filter({ (p: (Int, String)) -> Bool in p.0 > 0 })
                .sorted(by: { (a: (Int, String), b: (Int, String)) -> Bool in a.0 > b.0 })
            var text: String = ""
            for (i, p) in used.enumerated() {
                if i == 0 {
                    text = "\(p.0) of \(switches) switches \(p.1)"
                } else {
                    text += " · \(p.0) \(p.1)"
                }
            }
            parts.append(text)
        }
        parts.append(undos == 0 ? "no undos" : (undos == 1 ? "1 undo" : "\(undos) undos"))
        if hrMissing {
            parts.append("no HR")
        } else if timeline.isEstimated {
            parts.append("HR per split only")
        } else if let g = gapSeconds, g > 0 {
            var t: String = "HR gap " + SummaryFormat.clock(g)
            if let name = gapTitle { t += " in " + name }
            parts.append(t)
        } else {
            parts.append("HR complete")
        }
        if stepsMissing {
            parts.append("no steps")
        } else if runDistanceMissing {
            parts.append("run distance missing")
        } else {
            parts.append("steps OK")
        }
        let edited: Bool = ctx.result.editedAt != nil
        if edited {
            parts.append("edited")
        }

        return DataNote(switchCount: switches, crownCount: crown, pressCount: press, buttonCount: button,
                        autoCount: auto, undoCount: undos, heartRateGapSeconds: gapSeconds,
                        longestGapSegmentTitle: gapTitle, heartRateEstimated: timeline.isEstimated,
                        heartRateMissing: hrMissing, stepsMissing: stepsMissing,
                        runDistanceMissing: runDistanceMissing, isEdited: edited,
                        text: parts.joined(separator: " · "))
    }

    static func plural(_ n: Int, _ word: String) -> String {
        return "\(n) " + (n == 1 ? word : word + "s")
    }
}

// MARK: - Context (internal)

/// Everything the builders share: sorted segments, the time origin, the previous attempt.
struct SummaryContext {
    let result: WorkoutResult
    let definition: WorkoutDefinition
    /// Recorded segments sorted by index.
    let segments: [SegmentResult]
    /// Previous attempt's segments by index (same definition id only), nil without one.
    let previous: WorkoutResult?
    let previousByIndex: [Int: SegmentResult]
    /// Seconds since 1970 of the workout start (first segment start, else startDate).
    let origin: Double
    /// Workout length (relative), at least the last segment's end.
    let duration: Double
    let isFinished: Bool
    let roundSize: Int?

    init(result: WorkoutResult, previous: WorkoutResult?) {
        self.result = result
        self.definition = result.definition
        let sorted: [SegmentResult] = result.segments.sorted(by: { (a: SegmentResult, b: SegmentResult) -> Bool in
            a.index < b.index
        })
        self.segments = sorted
        var prev: WorkoutResult? = nil
        var byIndex: [Int: SegmentResult] = [:]
        if let p = previous, p.definition.id == result.definition.id, p.id != result.id {
            prev = p
            for s in p.segments { byIndex[s.index] = s }
        }
        self.previous = prev
        self.previousByIndex = byIndex
        let origin: Double = sorted.first?.start ?? result.startDate.timeIntervalSince1970
        self.origin = origin
        var duration: Double = result.totalSeconds
        if let last = sorted.last {
            duration = Swift.max(duration, last.end - origin)
        }
        self.duration = Swift.max(0, duration)
        self.isFinished = result.finishDate != nil && sorted.count >= result.definition.segments.count
        self.roundSize = WorkoutSummary.effectiveRoundSize(result.definition)
    }

    func rel(_ t: Double) -> Double {
        return t - origin
    }

    /// Definition segment at a result segment's index.
    func definitionSegment(_ index: Int) -> WorkoutSegment? {
        if index >= 0 && index < definition.segments.count { return definition.segments[index] }
        return nil
    }

    /// Movement name without target ("KB Swings"), falling back to the title.
    func name(_ seg: SegmentResult) -> String {
        if let d = definitionSegment(seg.index) { return d.name }
        return seg.title
    }

    /// The last recorded segment when the workout did not finish (AMRAP cap, ended early).
    func isPartial(_ seg: SegmentResult) -> Bool {
        if isFinished { return false }
        guard let last = segments.last else { return false }
        return seg.index == last.index
    }

    /// Pace for runs: target distance when the target is in meters (and the run is complete),
    /// else the measured distance (> 50 m), else the stored pace.
    func pace(_ seg: SegmentResult) -> Double? {
        return WorkoutSummary.pace(seg, definition: definition, partial: isPartial(seg))
    }

    func previousSegment(_ index: Int) -> SegmentResult? {
        guard previous != nil, let p = previousByIndex[index] else { return nil }
        if let cur = segments.first(where: { (s: SegmentResult) -> Bool in s.index == index }),
           cur.movement != p.movement {
            return nil
        }
        return p
    }

    func previousPace(_ index: Int) -> Double? {
        guard let p = previous, let s = previousSegment(index) else { return nil }
        return WorkoutSummary.pace(s, definition: p.definition, partial: false)
    }

    /// Rounds in the definition (ceil(segments / roundSize)).
    var plannedRounds: Int? {
        guard let rs = roundSize, rs > 0 else { return nil }
        return (definition.segments.count + rs - 1) / rs
    }
}

extension WorkoutSummary {
    static func pace(_ seg: SegmentResult, definition: WorkoutDefinition, partial: Bool) -> Double? {
        if seg.kind != .run || seg.duration <= 0 { return nil }
        if !partial, seg.index >= 0, seg.index < definition.segments.count,
           let t = definition.segments[seg.index].target, t.unit == .meters, t.value > 0 {
            return seg.duration / (t.value / 1000.0)
        }
        if let d = seg.distance, d > 50 {
            return seg.duration / (d / 1000.0)
        }
        return seg.paceSecondsPerKm
    }

    /// Segments per round: the definition's `roundSize`; else the shortest period p
    /// (2·p ≤ count) with which the (kind, movement) list repeats, a partial last round
    /// allowed; else 2 when runs alternate with stations; else nil.
    public static func effectiveRoundSize(_ definition: WorkoutDefinition) -> Int? {
        if let r = definition.roundSize, r > 0 { return r }
        if let p = repeatPeriod(definition) { return p }
        if alternatesRunsAndStations(definition) { return 2 }
        return nil
    }

    static func segmentKey(_ s: WorkoutSegment) -> String {
        return s.kind.rawValue + "|" + s.movement
    }

    static func repeatPeriod(_ definition: WorkoutDefinition) -> Int? {
        let keys: [String] = definition.segments.map({ (s: WorkoutSegment) -> String in segmentKey(s) })
        let n: Int = keys.count
        if n < 2 { return nil }
        for p in 1...(n / 2) where repeats(keys, period: p) {
            return p
        }
        return nil
    }

    /// keys[i] == keys[i % period] for every i, and at least two full rounds.
    static func repeats(_ keys: [String], period: Int) -> Bool {
        if period <= 0 || keys.count < 2 * period { return false }
        for i in period..<keys.count where keys[i] != keys[i % period] {
            return false
        }
        return true
    }

    /// Even count, runs at even positions and stations at odd positions.
    public static func alternatesRunsAndStations(_ definition: WorkoutDefinition) -> Bool {
        let segs: [WorkoutSegment] = definition.segments
        if segs.count < 2 || segs.count % 2 != 0 { return false }
        for (i, s) in segs.enumerated() {
            if i % 2 == 0 && s.kind != .run { return false }
            if i % 2 == 1 && s.kind != .station { return false }
        }
        return true
    }
}
