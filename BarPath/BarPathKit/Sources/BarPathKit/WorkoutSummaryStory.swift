import Foundation

// The format-specific "story" view models (docs/WORKOUT_OVERVIEW_V2.md, "The story view").
// Times are relative seconds; paces are seconds per km; HR is bpm.

extension WorkoutSummary {

    /// Which story view to show, with its data.
    /// Choice: AMRAP → amrapClock; emom or intervalSeconds → intervalSlots; for time with runs
    /// alternating with stations and a round size of 2 → runsAndStations; for time with a
    /// repeating round of 2+ segments → roundGrid; otherwise segments.
    public enum Story: Equatable {
        case runsAndStations(RunsAndStations)
        case roundGrid(RoundGrid)
        case intervalSlots(IntervalSlots)
        case amrapClock(AmrapClock)
        case segments([SegmentBar])
    }

    /// Per-movement numbers over the completed segments of that movement.
    public struct MovementStat: Equatable, Identifiable {
        public let movement: String
        /// Display name, e.g. "Double Unders".
        public let name: String
        public let count: Int
        public let averageSeconds: Double
        public let bestSeconds: Double
        public let worstSeconds: Double
        public var id: String { return movement }
    }

    // MARK: Runs and stations (HYROX, Partner WOD 1)

    public struct RunSplit: Equatable, Identifiable {
        public let segmentIndex: Int
        /// 1-based run number.
        public let number: Int
        public let title: String
        /// Distance used for the pace (target in meters, else measured), nil if unknown.
        public let meters: Double?
        public let duration: Double
        public let paceSecondsPerKm: Double?
        public let previousDuration: Double?
        public let previousPaceSecondsPerKm: Double?
        /// duration − previous duration.
        public let deltaSeconds: Double?
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        /// Seconds of missing HR in the 5 s series (0 when estimated).
        public let gapSeconds: Double
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    public struct StationSplit: Equatable, Identifiable {
        public let segmentIndex: Int
        /// 1-based station number (counts every non-run segment).
        public let number: Int
        /// "SkiErg 1000 m"
        public let title: String
        /// "SkiErg"
        public let name: String
        public let movement: String
        public let kind: SegmentKind
        public let shortLabel: String
        public let duration: Double
        public let previousDuration: Double?
        /// duration − previous duration (negative = faster).
        public let deltaSeconds: Double?
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public let heartRateMin: Double?
        public let gapSeconds: Double
        public var hasGap: Bool { return gapSeconds > 0 }
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    public struct RunsAndStations: Equatable {
        /// Sum of run durations (Roxzone included for now).
        public let runSeconds: Double
        /// Sum of all non-run durations.
        public let stationSeconds: Double
        public let runs: [RunSplit]
        public let stations: [StationSplit]
        /// Pace of the last run − pace of the first run (runs with a pace), s/km.
        public let fadeSecondsPerKm: Double?
        /// Indices into `runs` of the fastest / slowest pace.
        public let bestRun: Int?
        public let worstRun: Int?
        /// mean(pace of the last 3 runs) − pace of run 1 (needs 4+ runs with a pace).
        public let outFastSecondsPerKm: Double?
        /// outFastSecondsPerKm > 20 s/km: "Went out fast".
        public let wentOutFast: Bool
        /// Indices into `stations` with the largest time gain (most negative delta < 0) and
        /// loss (largest delta > 0) vs the previous attempt.
        public let biggestGain: Int?
        public let biggestLoss: Int?
        /// Longest of all station durations and previous durations (shared bar scale).
        public let stationScaleMax: Double
        public let hasPrevious: Bool
    }

    // MARK: Rounds grid (Helen)

    public struct GridColumn: Equatable, Identifiable {
        public let index: Int
        /// Definition title, e.g. "Run 400 m", "KB Swings 21", "Pull-ups 12".
        public let title: String
        public let name: String
        public let movement: String
        public let kind: SegmentKind
        public let shortLabel: String
        /// Mean / best over the completed cells of this column.
        public let averageSeconds: Double?
        public let bestSeconds: Double?
        public var id: Int { return index }
    }

    public struct GridCell: Equatable, Identifiable {
        public let segmentIndex: Int
        public let round: Int
        public let column: Int
        public let duration: Double
        /// duration − column average (nil for a partial cell or without an average).
        public let deviationSeconds: Double?
        /// −1 (fastest tint, teal) … +1 (slowest tint, plum): deviation / column average / 12 %,
        /// clamped. 0 when there is no deviation.
        public let tint: Double
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    public struct GridRound: Equatable, Identifiable {
        /// 0-based round index; `number` is 1-based.
        public let index: Int
        public var number: Int { return index + 1 }
        public let firstSegmentIndex: Int
        public let lastSegmentIndex: Int
        /// Cells of this round in column order (fewer for an unfinished round).
        public let cells: [GridCell]
        public let start: Double
        public let end: Double
        public let duration: Double
        /// All columns present and none partial.
        public let isComplete: Bool
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        /// duration − fastest complete round (nil when incomplete).
        public let deltaFromFastestSeconds: Double?
        public let isFastest: Bool
        public let isSlowest: Bool
        public var id: Int { return index }
    }

    public struct RoundGrid: Equatable {
        public let columns: [GridColumn]
        public let rounds: [GridRound]
        /// Indices into `rounds` (complete rounds only; nil with fewer than 2).
        public let fastestRound: Int?
        public let slowestRound: Int?
        /// Last complete round vs the first: seconds and percent of the first.
        public let driftSeconds: Double?
        public let driftPercent: Double?
        /// "Round 3 was 14 % slower than round 1" (nil with fewer than 2 complete rounds).
        public let driftText: String?
        /// Column that slowed most from the first to the last complete round, and by how much.
        public let slowedMostColumn: Int?
        public let slowedMostSeconds: Double?
        /// Runs in the grid: average and best pace (s/km), nil without runs.
        public let runPaceAverage: Double?
        public let runPaceBest: Double?
        /// The tint reaches ±1 at this fraction of the column average (0.12).
        public let tintFullScale: Double
    }

    // MARK: Interval slots (every N:00)

    public struct SetPart: Equatable, Identifiable {
        public let segmentIndex: Int
        /// Position inside the set (0-based; rests excluded).
        public let column: Int
        public let title: String
        public let name: String
        public let movement: String
        public let shortLabel: String
        /// Seconds from the start of the set's first segment.
        public let offset: Double
        public let duration: Double
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    public struct IntervalSet: Equatable, Identifiable {
        /// 0-based set index; `number` is 1-based.
        public let index: Int
        public var number: Int { return index + 1 }
        public let firstSegmentIndex: Int
        public let lastSegmentIndex: Int
        /// Relative time the slot begins (index × interval, or the first segment's start).
        public let slotStart: Double
        /// Work parts in order (row, thrusters).
        public let parts: [SetPart]
        /// First work start to last work end.
        public let workSeconds: Double
        public let restSegmentIndex: Int?
        public let restSeconds: Double?
        /// Work took longer than the interval ("no rest").
        public let overran: Bool
        /// HR 2 s after the work began (first value in the work if that is a gap).
        public let startHeartRate: Double?
        /// Highest HR during the work.
        public let peakHeartRate: Double?
        /// HR 3 s before the rest ended.
        public let restEndHeartRate: Double?
        /// peak − rest end (positive = recovered that much).
        public let recoveryDrop: Double?
        /// All planned work parts recorded and not cut off.
        public let isComplete: Bool
        public var id: Int { return index }
    }

    public struct IntervalSlots: Equatable {
        /// Slot length (definition intervalSeconds), nil for sets without a clock.
        public let intervalSeconds: Double?
        public let sets: [IntervalSet]
        public let setsPlanned: Int
        public let setsCompleted: Int
        /// Mean work time of the complete sets.
        public let averageWorkSeconds: Double?
        /// Last complete set's work − the first's.
        public let workDriftSeconds: Double?
        /// Start HR of the first and the last set that have one.
        public let firstStartHeartRate: Double?
        public let lastStartHeartRate: Double?
        /// "Start HR rose 100 → 151 over 6 sets." (nil without two start values).
        public let startHeartRateText: String?
        /// Recovery drop of the first and last set that have one.
        public let firstRecoveryDrop: Double?
        public let lastRecoveryDrop: Double?
        /// Rest of the first and the last set that have a rest.
        public let firstRestSeconds: Double?
        public let lastRestSeconds: Double?
        /// Average per work column (e.g. Row, Thrusters) over complete parts.
        public let partAverages: [MovementStat]
    }

    // MARK: AMRAP clock

    public struct RoundPart: Equatable, Identifiable {
        public let segmentIndex: Int
        public let column: Int
        public let title: String
        public let name: String
        public let movement: String
        public let shortLabel: String
        /// Relative times on the workout clock.
        public let start: Double
        public let end: Double
        public let duration: Double
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    public struct AmrapRound: Equatable, Identifiable {
        public let index: Int
        public var number: Int { return index + 1 }
        public let firstSegmentIndex: Int
        public let lastSegmentIndex: Int
        public let parts: [RoundPart]
        public let start: Double
        public let end: Double
        public let duration: Double
        public let isComplete: Bool
        /// Completed parts (not cut off) and the parts a full round has.
        public let completedParts: Int
        public let totalParts: Int
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public var id: Int { return index }
    }

    public struct StopPoint: Equatable {
        public let segmentIndex: Int
        /// "Double Unders"
        public let name: String
        public let title: String
        /// Seconds spent in that segment before the stop.
        public let secondsIn: Double
        /// 0-based round index.
        public let round: Int
    }

    public struct AmrapClock: Equatable {
        /// Axis length: the time cap, else the workout duration.
        public let capSeconds: Double
        public let rounds: [AmrapRound]
        public let completedRounds: Int
        /// Reps of the completed segments in the unfinished round (rep targets only).
        public let extraReps: Int
        public let stoppedIn: StopPoint?
        /// Mean duration of the complete rounds.
        public let averageRoundSeconds: Double?
        /// Last complete round vs the first complete round.
        public let driftSeconds: Double?
        public let driftPercent: Double?
        /// "Round 4 took 25 % longer than round 1"
        public let driftText: String?
        /// Column that slowed most between those two rounds.
        public let slowedMostColumn: Int?
        public let slowedMostName: String?
        public let slowedMostSeconds: Double?
        /// Per movement over complete segments, in order of first appearance.
        public let movements: [MovementStat]
    }

    // MARK: Fallback

    public struct SegmentBar: Equatable, Identifiable {
        public let segmentIndex: Int
        public let title: String
        public let kind: SegmentKind
        public let shortLabel: String
        public let duration: Double
        /// duration / longest duration (0…1) for the bar width.
        public let fraction: Double
        public let heartRateAvg: Double?
        public let heartRateMax: Double?
        public let paceSecondsPerKm: Double?
        public let previousDuration: Double?
        public let deltaSeconds: Double?
        public let isPartial: Bool
        public var id: Int { return segmentIndex }
    }

    /// Cell tint reaches ±1 at this fraction of the column average.
    public static let tintFullScale: Double = 0.12

    /// "Went out fast" threshold, s/km.
    public static let outFastThreshold: Double = 20

    // MARK: - Choice

    static func makeStory(ctx: SummaryContext, timeline: Timeline) -> Story {
        let def: WorkoutDefinition = ctx.definition
        if ctx.segments.isEmpty {
            return .segments([])
        }
        if def.format == .amrap {
            return .amrapClock(makeAmrap(ctx: ctx, timeline: timeline))
        }
        if def.format == .emom || def.intervalSeconds != nil {
            return .intervalSlots(makeSlots(ctx: ctx, timeline: timeline))
        }
        if let rs = ctx.roundSize, rs == 2, alternatesRunsAndStations(def) {
            return .runsAndStations(makeRunsAndStations(ctx: ctx, timeline: timeline))
        }
        if let rs = ctx.roundSize, rs >= 2 {
            let keys: [String] = def.segments.map({ (s: WorkoutSegment) -> String in segmentKey(s) })
            if repeats(keys, period: rs) {
                return .roundGrid(makeGrid(ctx: ctx, timeline: timeline, roundSize: rs))
            }
        }
        return .segments(makeBars(ctx: ctx))
    }

    // MARK: - Helpers

    /// Segment HR: the watch's per-segment values when present, else the timeline's.
    static func segmentHeartRate(_ seg: SegmentResult, ctx: SummaryContext,
                                 timeline: Timeline) -> (avg: Double?, max: Double?, gap: Double) {
        let st: RangeStats = timeline.stats(from: ctx.rel(seg.start), to: ctx.rel(seg.end))
        let gap: Double = timeline.isEstimated ? 0 : st.gapSeconds
        return (seg.heartRateAvg ?? st.average, seg.heartRateMax ?? st.max, gap)
    }

    static func mean(_ values: [Double]) -> Double? {
        if values.isEmpty { return nil }
        var s: Double = 0
        for v in values { s += v }
        return s / Double(values.count)
    }

    static func groups(_ segments: [SegmentResult], roundSize: Int) -> [(Int, [SegmentResult])] {
        var out: [(Int, [SegmentResult])] = []
        for seg in segments {
            let r: Int = seg.index / roundSize
            if let last = out.last, last.0 == r {
                out[out.count - 1].1.append(seg)
            } else {
                out.append((r, [seg]))
            }
        }
        return out
    }

    static func movementStats(_ items: [(String, String, Double)]) -> [MovementStat] {
        var order: [String] = []
        var names: [String: String] = [:]
        var values: [String: [Double]] = [:]
        for (movement, name, d) in items {
            if values[movement] == nil {
                order.append(movement)
                names[movement] = name
                values[movement] = []
            }
            values[movement]?.append(d)
        }
        var out: [MovementStat] = []
        for m in order {
            let v: [Double] = values[m] ?? []
            if v.isEmpty { continue }
            let avg: Double = mean(v) ?? 0
            let best: Double = v.min() ?? 0
            let worst: Double = v.max() ?? 0
            out.append(MovementStat(movement: m, name: names[m] ?? m, count: v.count,
                                    averageSeconds: avg, bestSeconds: best, worstSeconds: worst))
        }
        return out
    }

    // MARK: - Runs and stations

    static func makeRunsAndStations(ctx: SummaryContext, timeline: Timeline) -> RunsAndStations {
        var runs: [RunSplit] = []
        var stations: [StationSplit] = []
        var runSeconds: Double = 0
        var stationSeconds: Double = 0
        var scaleMax: Double = 0
        for seg in ctx.segments {
            let hr: (avg: Double?, max: Double?, gap: Double) = segmentHeartRate(seg, ctx: ctx, timeline: timeline)
            let prev: SegmentResult? = ctx.previousSegment(seg.index)
            let delta: Double? = prev.map({ (p: SegmentResult) -> Double in seg.duration - p.duration })
            let partial: Bool = ctx.isPartial(seg)
            if seg.kind == .run {
                runSeconds += seg.duration
                let pace: Double? = ctx.pace(seg)
                var meters: Double? = nil
                if let p = pace, p > 0 { meters = seg.duration / p * 1000.0 }
                runs.append(RunSplit(segmentIndex: seg.index, number: runs.count + 1, title: seg.title,
                                     meters: meters, duration: seg.duration, paceSecondsPerKm: pace,
                                     previousDuration: prev?.duration,
                                     previousPaceSecondsPerKm: ctx.previousPace(seg.index),
                                     deltaSeconds: delta, heartRateAvg: hr.avg, heartRateMax: hr.max,
                                     gapSeconds: hr.gap, isPartial: partial))
            } else {
                stationSeconds += seg.duration
                scaleMax = Swift.max(scaleMax, seg.duration, prev?.duration ?? 0)
                stations.append(StationSplit(segmentIndex: seg.index, number: stations.count + 1,
                                             title: seg.title, name: ctx.name(seg), movement: seg.movement,
                                             kind: seg.kind,
                                             shortLabel: shortLabel(movement: seg.movement, kind: seg.kind,
                                                                    name: ctx.name(seg)),
                                             duration: seg.duration, previousDuration: prev?.duration,
                                             deltaSeconds: delta, heartRateAvg: hr.avg, heartRateMax: hr.max,
                                             heartRateMin: seg.heartRateMin, gapSeconds: hr.gap,
                                             isPartial: partial))
            }
        }

        // Paces of complete runs, in order.
        var paced: [(Int, Double)] = []
        for (i, r) in runs.enumerated() {
            if let p = r.paceSecondsPerKm, !r.isPartial { paced.append((i, p)) }
        }
        var fade: Double? = nil
        var best: Int? = nil
        var worst: Int? = nil
        var outFast: Double? = nil
        if let first = paced.first, let last = paced.last {
            if paced.count >= 2 { fade = last.1 - first.1 }
            var b: (Int, Double) = first
            var w: (Int, Double) = first
            for p in paced {
                if p.1 < b.1 { b = p }
                if p.1 > w.1 { w = p }
            }
            best = b.0
            worst = w.0
            if paced.count >= 4 {
                let tail: [Double] = paced.suffix(3).map({ (p: (Int, Double)) -> Double in p.1 })
                if let m = mean(tail) { outFast = m - first.1 }
            }
        }

        var gain: Int? = nil
        var loss: Int? = nil
        var gainValue: Double = 0
        var lossValue: Double = 0
        for (i, s) in stations.enumerated() {
            guard let d = s.deltaSeconds, !s.isPartial else { continue }
            if d < gainValue { gainValue = d; gain = i }
            if d > lossValue { lossValue = d; loss = i }
        }

        return RunsAndStations(runSeconds: runSeconds, stationSeconds: stationSeconds, runs: runs,
                               stations: stations, fadeSecondsPerKm: fade, bestRun: best, worstRun: worst,
                               outFastSecondsPerKm: outFast,
                               wentOutFast: (outFast ?? 0) > WorkoutSummary.outFastThreshold,
                               biggestGain: gain, biggestLoss: loss, stationScaleMax: scaleMax,
                               hasPrevious: ctx.previous != nil)
    }

    // MARK: - Round grid

    static func makeGrid(ctx: SummaryContext, timeline: Timeline, roundSize rs: Int) -> RoundGrid {
        let def: WorkoutDefinition = ctx.definition
        // Column averages over complete cells.
        var colValues: [[Double]] = Array(repeating: [], count: rs)
        for seg in ctx.segments where !ctx.isPartial(seg) {
            colValues[seg.index % rs].append(seg.duration)
        }
        var columns: [GridColumn] = []
        for c in 0..<rs {
            let d: WorkoutSegment? = c < def.segments.count ? def.segments[c] : nil
            let movement: String = d?.movement ?? ""
            let kind: SegmentKind = d?.kind ?? .station
            let name: String = d?.name ?? "Part \(c + 1)"
            columns.append(GridColumn(index: c, title: d?.title ?? name, name: name, movement: movement,
                                      kind: kind,
                                      shortLabel: shortLabel(movement: movement, kind: kind, name: name),
                                      averageSeconds: mean(colValues[c]), bestSeconds: colValues[c].min()))
        }

        var rounds: [GridRound] = []
        for (r, segs) in groups(ctx.segments, roundSize: rs) {
            var cells: [GridCell] = []
            var complete: Bool = segs.count == rs
            for seg in segs {
                let c: Int = seg.index % rs
                let partial: Bool = ctx.isPartial(seg)
                if partial { complete = false }
                var dev: Double? = nil
                var tint: Double = 0
                if !partial, let avg = columns[c].averageSeconds, avg > 0 {
                    let dv: Double = seg.duration - avg
                    dev = dv
                    tint = Swift.max(-1, Swift.min(1, dv / avg / WorkoutSummary.tintFullScale))
                }
                let hr: (avg: Double?, max: Double?, gap: Double) = segmentHeartRate(seg, ctx: ctx, timeline: timeline)
                cells.append(GridCell(segmentIndex: seg.index, round: r, column: c, duration: seg.duration,
                                      deviationSeconds: dev, tint: tint, heartRateAvg: hr.avg,
                                      heartRateMax: hr.max, isPartial: partial))
            }
            let first: SegmentResult = segs[0]
            let last: SegmentResult = segs[segs.count - 1]
            let start: Double = ctx.rel(first.start)
            let end: Double = ctx.rel(last.end)
            let st: RangeStats = timeline.stats(from: start, to: end)
            rounds.append(GridRound(index: r, firstSegmentIndex: first.index, lastSegmentIndex: last.index,
                                    cells: cells, start: start, end: end, duration: end - start,
                                    isComplete: complete, heartRateAvg: st.average, heartRateMax: st.max,
                                    deltaFromFastestSeconds: nil, isFastest: false, isSlowest: false))
        }

        // Fastest / slowest / drift over complete rounds.
        let completeIdx: [Int] = rounds.indices.filter({ (i: Int) -> Bool in rounds[i].isComplete })
        var fastest: Int? = nil
        var slowest: Int? = nil
        var fastestDuration: Double? = nil
        for i in completeIdx {
            if fastest == nil || rounds[i].duration < rounds[fastest ?? 0].duration { fastest = i }
            if slowest == nil || rounds[i].duration > rounds[slowest ?? 0].duration { slowest = i }
        }
        if let f = fastest { fastestDuration = rounds[f].duration }
        var finalRounds: [GridRound] = []
        for (i, r) in rounds.enumerated() {
            let delta: Double? = (r.isComplete && fastestDuration != nil) ? r.duration - (fastestDuration ?? 0) : nil
            let multiple: Bool = completeIdx.count >= 2
            finalRounds.append(GridRound(index: r.index, firstSegmentIndex: r.firstSegmentIndex,
                                         lastSegmentIndex: r.lastSegmentIndex, cells: r.cells, start: r.start,
                                         end: r.end, duration: r.duration, isComplete: r.isComplete,
                                         heartRateAvg: r.heartRateAvg, heartRateMax: r.heartRateMax,
                                         deltaFromFastestSeconds: delta,
                                         isFastest: multiple && fastest == i,
                                         isSlowest: multiple && slowest == i && fastest != i))
        }

        var driftSeconds: Double? = nil
        var driftPercent: Double? = nil
        var driftText: String? = nil
        var slowedCol: Int? = nil
        var slowedSec: Double? = nil
        if completeIdx.count >= 2, let a = completeIdx.first, let b = completeIdx.last {
            let ra: GridRound = finalRounds[a]
            let rb: GridRound = finalRounds[b]
            driftSeconds = rb.duration - ra.duration
            if ra.duration > 0 {
                let pct: Double = (rb.duration - ra.duration) / ra.duration * 100
                driftPercent = pct
                driftText = driftSentence(later: rb.number, first: ra.number, percent: pct, verb: "was")
            }
            for c in 0..<Swift.min(ra.cells.count, rb.cells.count) {
                let d: Double = rb.cells[c].duration - ra.cells[c].duration
                if slowedSec == nil || d > (slowedSec ?? 0) {
                    slowedSec = d
                    slowedCol = c
                }
            }
        }

        var runPaces: [Double] = []
        for seg in ctx.segments where seg.kind == .run && !ctx.isPartial(seg) {
            if let p = ctx.pace(seg) { runPaces.append(p) }
        }

        return RoundGrid(columns: columns, rounds: finalRounds, fastestRound: completeIdx.count >= 2 ? fastest : nil,
                         slowestRound: completeIdx.count >= 2 ? slowest : nil, driftSeconds: driftSeconds,
                         driftPercent: driftPercent, driftText: driftText, slowedMostColumn: slowedCol,
                         slowedMostSeconds: slowedSec, runPaceAverage: mean(runPaces),
                         runPaceBest: runPaces.min(), tintFullScale: WorkoutSummary.tintFullScale)
    }

    /// "Round 3 was 14 % slower than round 1" / "… 5 % faster …" / "… the same as …".
    static func driftSentence(later: Int, first: Int, percent: Double, verb: String) -> String {
        let r: Int = Int(abs(percent).rounded())
        if r == 0 {
            return "Round \(later) \(verb) as fast as round \(first)"
        }
        if verb == "took" {
            return "Round \(later) took \(r) % " + (percent > 0 ? "longer" : "less") + " than round \(first)"
        }
        return "Round \(later) \(verb) \(r) % " + (percent > 0 ? "slower" : "faster") + " than round \(first)"
    }

    // MARK: - Interval slots

    static func makeSlots(ctx: SummaryContext, timeline: Timeline) -> IntervalSlots {
        let def: WorkoutDefinition = ctx.definition
        let interval: Double? = (def.intervalSeconds ?? 0) > 0 ? def.intervalSeconds : nil
        let rs: Int = ctx.roundSize ?? Swift.max(1, def.segments.count)

        // Planned sets: groups of the definition that contain work.
        var planned: Int = 0
        var plannedWork: [Int: Int] = [:]
        for (i, s) in def.segments.enumerated() where s.kind != .rest {
            plannedWork[i / rs, default: 0] += 1
        }
        planned = plannedWork.count

        var sets: [IntervalSet] = []
        for (k, segs) in groups(ctx.segments, roundSize: rs) {
            let work: [SegmentResult] = segs.filter({ (s: SegmentResult) -> Bool in s.kind != .rest })
            let rest: SegmentResult? = segs.first(where: { (s: SegmentResult) -> Bool in s.kind == .rest })
            let firstStart: Double = ctx.rel(segs[0].start)
            var parts: [SetPart] = []
            for (j, w) in work.enumerated() {
                let name: String = ctx.name(w)
                parts.append(SetPart(segmentIndex: w.index, column: j, title: w.title, name: name,
                                     movement: w.movement,
                                     shortLabel: shortLabel(movement: w.movement, kind: w.kind, name: name),
                                     offset: ctx.rel(w.start) - firstStart, duration: w.duration,
                                     isPartial: ctx.isPartial(w)))
            }
            var workSeconds: Double = 0
            var startHR: Double? = nil
            var peakHR: Double? = nil
            if let w0 = work.first, let w1 = work.last {
                let ws: Double = ctx.rel(w0.start)
                let we: Double = ctx.rel(w1.end)
                workSeconds = we - ws
                startHR = timeline.heartRate(at: Swift.min(ws + 2, we))
                if startHR == nil {
                    for k2 in 0..<timeline.heartRate.count {
                        let c: Double = timeline.time(ofSample: k2)
                        if c >= ws && c < we, let v = timeline.heartRate[k2] {
                            startHR = v
                            break
                        }
                    }
                }
                peakHR = timeline.stats(from: ws, to: we).max
                if peakHR == nil {
                    for w in work {
                        if let m = w.heartRateMax { peakHR = Swift.max(peakHR ?? m, m) }
                    }
                }
            }
            var restEnd: Double? = nil
            if let r = rest {
                restEnd = timeline.heartRate(at: Swift.max(ctx.rel(r.start), ctx.rel(r.end) - 3))
                if restEnd == nil { restEnd = r.heartRateMin }
            }
            var drop: Double? = nil
            if let p = peakHR, let e = restEnd { drop = p - e }
            let expected: Int = plannedWork[k] ?? work.count
            let complete: Bool = work.count >= expected && !work.contains(where: { (s: SegmentResult) -> Bool in
                ctx.isPartial(s)
            })
            let slotStart: Double = interval.map({ (iv: Double) -> Double in Double(k) * iv }) ?? firstStart
            sets.append(IntervalSet(index: k, firstSegmentIndex: segs[0].index,
                                    lastSegmentIndex: segs[segs.count - 1].index, slotStart: slotStart,
                                    parts: parts, workSeconds: workSeconds, restSegmentIndex: rest?.index,
                                    restSeconds: rest?.duration,
                                    overran: interval.map({ (iv: Double) -> Bool in workSeconds > iv }) ?? false,
                                    startHeartRate: startHR, peakHeartRate: peakHR, restEndHeartRate: restEnd,
                                    recoveryDrop: drop, isComplete: complete))
        }

        let complete: [IntervalSet] = sets.filter({ (s: IntervalSet) -> Bool in s.isComplete })
        let avgWork: Double? = mean(complete.map({ (s: IntervalSet) -> Double in s.workSeconds }))
        var workDrift: Double? = nil
        if complete.count >= 2, let a = complete.first, let b = complete.last {
            workDrift = b.workSeconds - a.workSeconds
        }
        let starts: [(Int, Double)] = sets.compactMap({ (s: IntervalSet) -> (Int, Double)? in
            guard let h = s.startHeartRate else { return nil }
            return (s.number, h)
        })
        var startText: String? = nil
        if starts.count >= 2, let a = starts.first, let b = starts.last {
            let verb: String = b.1 > a.1 ? "rose" : (b.1 < a.1 ? "fell" : "stayed")
            // Built in steps: one long `+` chain of literals is slow for the type checker.
            let from: String = SummaryFormat.bpm(a.1)
            let to: String = SummaryFormat.bpm(b.1)
            var text: String = "Start HR " + verb
            text += " " + from + " → " + to
            text += " over \(starts.count) sets."
            startText = text
        }
        let drops: [Double] = sets.compactMap({ (s: IntervalSet) -> Double? in s.recoveryDrop })
        let rests: [Double] = sets.compactMap({ (s: IntervalSet) -> Double? in s.restSeconds })

        var items: [(String, String, Double)] = []
        for s in sets {
            for p in s.parts where !p.isPartial {
                items.append(("\(p.column)|" + p.movement, p.name, p.duration))
            }
        }
        var partStats: [MovementStat] = []
        for m in movementStats(items) {
            // Strip the column prefix used to keep e.g. two rows in one set apart.
            var mv: String = m.movement
            if let bar = mv.firstIndex(of: "|") { mv = String(mv[mv.index(after: bar)...]) }
            partStats.append(MovementStat(movement: mv, name: m.name, count: m.count,
                                          averageSeconds: m.averageSeconds, bestSeconds: m.bestSeconds,
                                          worstSeconds: m.worstSeconds))
        }

        return IntervalSlots(intervalSeconds: interval, sets: sets, setsPlanned: Swift.max(planned, sets.count),
                             setsCompleted: complete.count, averageWorkSeconds: avgWork,
                             workDriftSeconds: workDrift, firstStartHeartRate: starts.first?.1,
                             lastStartHeartRate: starts.last?.1, startHeartRateText: startText,
                             firstRecoveryDrop: drops.first, lastRecoveryDrop: drops.last,
                             firstRestSeconds: rests.first, lastRestSeconds: rests.last,
                             partAverages: partStats)
    }

    // MARK: - AMRAP clock

    static func makeAmrap(ctx: SummaryContext, timeline: Timeline) -> AmrapClock {
        let def: WorkoutDefinition = ctx.definition
        let rs: Int = ctx.roundSize ?? Swift.max(1, def.segments.count)
        let cap: Double = (def.timeCapSeconds ?? 0) > 0 ? (def.timeCapSeconds ?? 0) : ctx.duration

        var rounds: [AmrapRound] = []
        var items: [(String, String, Double)] = []
        for (r, segs) in groups(ctx.segments, roundSize: rs) {
            var parts: [RoundPart] = []
            var done: Int = 0
            for seg in segs {
                let partial: Bool = ctx.isPartial(seg)
                if !partial { done += 1 }
                let name: String = ctx.name(seg)
                parts.append(RoundPart(segmentIndex: seg.index, column: seg.index % rs, title: seg.title,
                                       name: name, movement: seg.movement,
                                       shortLabel: shortLabel(movement: seg.movement, kind: seg.kind, name: name),
                                       start: ctx.rel(seg.start), end: ctx.rel(seg.end), duration: seg.duration,
                                       isPartial: partial))
                if !partial { items.append((seg.movement, name, seg.duration)) }
            }
            let start: Double = ctx.rel(segs[0].start)
            let end: Double = ctx.rel(segs[segs.count - 1].end)
            let st: RangeStats = timeline.stats(from: start, to: end)
            rounds.append(AmrapRound(index: r, firstSegmentIndex: segs[0].index,
                                     lastSegmentIndex: segs[segs.count - 1].index, parts: parts, start: start,
                                     end: end, duration: end - start, isComplete: done == rs,
                                     completedParts: done, totalParts: rs, heartRateAvg: st.average,
                                     heartRateMax: st.max))
        }

        let complete: [AmrapRound] = rounds.filter({ (r: AmrapRound) -> Bool in r.isComplete })
        var extra: Int = 0
        if let last = rounds.last, !last.isComplete {
            for p in last.parts where !p.isPartial {
                if let d = ctx.definitionSegment(p.segmentIndex), let t = d.target, t.unit == .reps {
                    extra += Int(t.value.rounded())
                }
            }
        }
        var stop: StopPoint? = nil
        if let seg = ctx.segments.last, ctx.isPartial(seg) {
            stop = StopPoint(segmentIndex: seg.index, name: ctx.name(seg), title: seg.title,
                             secondsIn: seg.duration, round: seg.index / rs)
        }

        var driftSeconds: Double? = nil
        var driftPercent: Double? = nil
        var driftText: String? = nil
        var slowedCol: Int? = nil
        var slowedName: String? = nil
        var slowedSec: Double? = nil
        if complete.count >= 2, let a = complete.first, let b = complete.last {
            driftSeconds = b.duration - a.duration
            if a.duration > 0 {
                let pct: Double = (b.duration - a.duration) / a.duration * 100
                driftPercent = pct
                driftText = driftSentence(later: b.number, first: a.number, percent: pct, verb: "took")
            }
            for c in 0..<Swift.min(a.parts.count, b.parts.count) {
                let d: Double = b.parts[c].duration - a.parts[c].duration
                if slowedSec == nil || d > (slowedSec ?? 0) {
                    slowedSec = d
                    slowedCol = c
                    slowedName = a.parts[c].name
                }
            }
        }

        return AmrapClock(capSeconds: cap, rounds: rounds, completedRounds: complete.count, extraReps: extra,
                          stoppedIn: stop,
                          averageRoundSeconds: mean(complete.map({ (r: AmrapRound) -> Double in r.duration })),
                          driftSeconds: driftSeconds, driftPercent: driftPercent, driftText: driftText,
                          slowedMostColumn: slowedCol, slowedMostName: slowedName, slowedMostSeconds: slowedSec,
                          movements: movementStats(items))
    }

    // MARK: - Fallback bars

    static func makeBars(ctx: SummaryContext) -> [SegmentBar] {
        var longest: Double = 0
        for s in ctx.segments { longest = Swift.max(longest, s.duration) }
        var out: [SegmentBar] = []
        for seg in ctx.segments {
            let prev: SegmentResult? = ctx.previousSegment(seg.index)
            out.append(SegmentBar(segmentIndex: seg.index, title: seg.title, kind: seg.kind,
                                  shortLabel: shortLabel(movement: seg.movement, kind: seg.kind, name: ctx.name(seg)),
                                  duration: seg.duration, fraction: longest > 0 ? seg.duration / longest : 0,
                                  heartRateAvg: seg.heartRateAvg, heartRateMax: seg.heartRateMax,
                                  paceSecondsPerKm: ctx.pace(seg), previousDuration: prev?.duration,
                                  deltaSeconds: prev.map({ (p: SegmentResult) -> Double in seg.duration - p.duration }),
                                  isPartial: ctx.isPartial(seg)))
        }
        return out
    }
}
