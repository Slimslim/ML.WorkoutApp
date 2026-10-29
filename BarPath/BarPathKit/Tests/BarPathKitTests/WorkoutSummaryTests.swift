import Foundation
import XCTest
@testable import BarPathKit

final class WorkoutSummaryTests: XCTestCase {

    // MARK: Helpers

    /// Plays `durations` through WorkoutProgress (advance on each; the last one finishes, or
    /// `capFinish` stops it like the AMRAP cap) and builds the result the watch would send.
    /// `hr(t)` gives a 1 Hz HR sample at relative second t (nil = no sample).
    private func buildResult(_ def: WorkoutDefinition, durations: [Double],
                             start: Double = 1_800_000_000, capFinish: Bool = false,
                             source: AdvanceSource = .crown, hr: ((Double) -> Double?)? = nil,
                             withSeries: Bool = true, id: UUID = UUID()) -> WorkoutResult {
        var p = WorkoutProgress(definition: def)
        p.start(at: start)
        var t: Double = start
        for (i, d) in durations.enumerated() {
            t += d
            if i == durations.count - 1 && capFinish {
                XCTAssertTrue(p.finish(at: t, source: .auto))
            } else {
                XCTAssertTrue(p.advance(at: t, source: source))
            }
        }
        let end: Double = t
        var samples: [TimedValue] = []
        if let f = hr {
            var s: Double = 0
            while s < end - start {
                if let v = f(s) { samples.append(TimedValue(t: start + s, value: v)) }
                s += 1
            }
        }
        let segs: [SegmentResult] = SplitStats.compute(progress: p, now: end, heartRates: samples, pedometer: [])
        var series: HeartRateSeries? = nil
        if hr != nil && withSeries {
            series = HeartRateSeries.make(samples: samples, start: start, end: end)
        }
        let finish: Date? = p.finishTime.map({ (x: Double) -> Date in Date(timeIntervalSince1970: x) })
        return WorkoutResult(id: id, definition: def, startDate: Date(timeIntervalSince1970: start),
                             finishDate: finish, endDate: Date(timeIntervalSince1970: end + 10),
                             totalSeconds: end - start, segments: segs, events: p.events,
                             heartRateSeries: series)
    }

    private func loadHelen() throws -> WorkoutResult {
        let data = try fixtureData("workout-helen-2026-10-29", "json")
        return try WorkoutResult.decode(from: data)
    }

    // MARK: Real fixture: Helen, version 1

    func testHelenFixtureDecodesAsVersion1() throws {
        let r = try loadHelen()
        XCTAssertEqual(r.version, 1)
        XCTAssertNil(r.heartRateSeries)
        XCTAssertNil(r.definition.roundSize)
        XCTAssertNil(r.segments[0].heartRateMin)
        XCTAssertEqual(r.segments.count, 9)
        XCTAssertEqual(WorkoutSummary.effectiveRoundSize(r.definition), 3)
    }

    func testHelenSummary() throws {
        let r = try loadHelen()
        let s = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)

        XCTAssertEqual(s.headline.totalSeconds, 767.3, accuracy: 0.05)
        XCTAssertEqual(s.headline.scoreText, "12:47")
        XCTAssertEqual(s.headline.contextText, "3 rounds for time · 3:13 under the 16:00 cap")
        XCTAssertEqual(s.headline.underCapSeconds ?? -1, 192.7, accuracy: 0.05)
        XCTAssertTrue(s.headline.isFinished)
        XCTAssertNil(s.headline.zone45Seconds)
        XCTAssertNil(s.headline.deltaSeconds)
        XCTAssertEqual(s.headline.heartRateMax ?? -1, 180, accuracy: 1e-9)
        XCTAssertEqual(s.roundSize, 3)

        guard case .roundGrid(let g) = s.story else {
            return XCTFail("expected roundGrid, got \(s.story)")
        }
        XCTAssertEqual(g.columns.count, 3)
        XCTAssertEqual(g.columns.map { (c: WorkoutSummary.GridColumn) -> String in c.title },
                       ["Run 400 m", "KB Swings 21", "Pull-ups 12"])
        XCTAssertEqual(g.rounds.count, 3)
        for round in g.rounds {
            XCTAssertEqual(round.cells.count, 3)
            XCTAssertTrue(round.isComplete)
        }
        // Round totals from the JSON: 128.58 + 52.62 + 54.51, 149.04 + 52.58 + 62.25, 156.14 + 56.75 + 54.81.
        XCTAssertEqual(g.rounds[0].duration, 235.71, accuracy: 0.05)
        XCTAssertEqual(g.rounds[1].duration, 263.88, accuracy: 0.05)
        XCTAssertEqual(g.rounds[2].duration, 267.71, accuracy: 0.05)
        XCTAssertEqual(g.fastestRound, 0)
        XCTAssertEqual(g.slowestRound, 2)
        XCTAssertTrue(g.rounds[0].isFastest)
        XCTAssertTrue(g.rounds[2].isSlowest)
        XCTAssertEqual(g.rounds[1].deltaFromFastestSeconds ?? -1, 28.17, accuracy: 0.05)
        XCTAssertEqual(g.driftPercent ?? -1, 13.57, accuracy: 0.05)
        XCTAssertEqual(g.driftText, "Round 3 was 14 % slower than round 1")
        XCTAssertEqual(g.slowedMostColumn, 0)
        XCTAssertEqual(g.slowedMostSeconds ?? -1, 27.57, accuracy: 0.05)
        // Pace from the 400 m target: 128.58 s → 321.4 s/km; mean of the three 361.5.
        XCTAssertEqual(g.runPaceBest ?? -1, 321.44, accuracy: 0.05)
        XCTAssertEqual(g.runPaceAverage ?? -1, 361.47, accuracy: 0.05)
        // Cell tint: run column mean 144.59; round 1 run 16.0 s faster → −0.92.
        let c00 = g.rounds[0].cells[0]
        XCTAssertEqual(c00.deviationSeconds ?? 0, -16.01, accuracy: 0.05)
        XCTAssertEqual(c00.tint, -0.923, accuracy: 0.005)
        for round in g.rounds {
            for c in round.cells {
                XCTAssertGreaterThanOrEqual(c.tint, -1)
                XCTAssertLessThanOrEqual(c.tint, 1)
            }
        }

        // Timeline: version 1 → estimated step series from the segment averages.
        let tl = s.timeline
        XCTAssertTrue(tl.isEstimated)
        XCTAssertTrue(tl.hasHeartRate)
        XCTAssertTrue(tl.zonesEstimated)
        XCTAssertEqual(tl.maxHeartRate, 190, accuracy: 1e-9)
        XCTAssertEqual(tl.heartRate.count, 154)
        XCTAssertEqual(tl.heartRate[0] ?? -1, 145.1875, accuracy: 1e-9)
        XCTAssertEqual(tl.heartRate(at: 140) ?? -1, 172.636, accuracy: 0.001)
        XCTAssertTrue(tl.gaps.isEmpty)
        XCTAssertEqual(tl.bands.count, 9)
        XCTAssertEqual(tl.bands.map { (b: WorkoutSummary.Band) -> String in b.shortLabel },
                       ["R1", "KB", "Pull", "R2", "KB", "Pull", "R3", "KB", "Pull"])
        XCTAssertEqual(tl.bands[0].start, 0, accuracy: 1e-6)
        XCTAssertEqual(tl.bands[2].end, 235.71, accuracy: 0.05)
        XCTAssertEqual(tl.segment(at: 130), 1)
        XCTAssertEqual(tl.segment(at: -5), 0)
        XCTAssertEqual(tl.segment(at: 10_000), 8)
        let st = tl.stats(from: 0, to: 128.5)
        XCTAssertEqual(st.average ?? -1, 145.1875, accuracy: 1e-9)
        XCTAssertEqual(st.gapSeconds, 0)
        var zoneTotal: Double = 0
        for z in tl.zoneSeconds { zoneTotal += z }
        XCTAssertEqual(zoneTotal, tl.duration, accuracy: 1e-6)

        // Rows and data note.
        XCTAssertEqual(s.rows.count, 9)
        XCTAssertEqual(s.rows[3].displayTitle, "Run 400 m · R2")
        XCTAssertEqual(s.rows[8].end, 767.3, accuracy: 0.05)
        XCTAssertEqual(s.rows[0].paceSecondsPerKm ?? -1, 321.44, accuracy: 0.05)
        XCTAssertNil(s.rows[1].paceSecondsPerKm)
        XCTAssertEqual(s.dataNote.switchCount, 9)
        XCTAssertEqual(s.dataNote.crownCount, 9)
        XCTAssertEqual(s.dataNote.undoCount, 0)
        XCTAssertTrue(s.dataNote.heartRateEstimated)
        XCTAssertNil(s.dataNote.heartRateGapSeconds)
        XCTAssertTrue(s.dataNote.text.hasPrefix("9 of 9 switches by Crown"), s.dataNote.text)
        XCTAssertEqual(s.dataNote.text, "9 of 9 switches by Crown · no undos · HR per split only · steps OK")
    }

    // MARK: HYROX with an HR series and a previous attempt

    private let hyroxRuns: [Double] = [262, 281, 292, 301, 309, 318, 322, 330]
    private let hyroxStations: [Double] = [258, 192, 238, 296, 268, 128, 286, 452]

    private func hyroxDurations(runs: [Double], stations: [Double]) -> [Double] {
        var out: [Double] = []
        for i in 0..<8 {
            out.append(runs[i])
            out.append(stations[i])
        }
        return out
    }

    func testHyroxRunsAndStations() {
        let def = WorkoutLibrary.hyroxSolo
        // HR 150 + t/100, no samples from 300 s to 360 s (inside SkiErg: 262–520 s).
        let hr: (Double) -> Double? = { (t: Double) -> Double? in
            if t >= 300 && t < 360 { return nil }
            return 150 + t / 100
        }
        let result = buildResult(def, durations: hyroxDurations(runs: hyroxRuns, stations: hyroxStations), hr: hr)
        let prevRuns: [Double] = [275, 286, 290, 305, 311, 320, 330, 336]
        let prevStations: [Double] = [262, 205, 246, 288, 272, 131, 295, 470]
        let previous = buildResult(def, durations: hyroxDurations(runs: prevRuns, stations: prevStations),
                                   start: 1_799_000_000)
        let s = WorkoutSummary.make(result: result, previous: previous, maxHeartRate: 192)

        guard case .runsAndStations(let r) = s.story else {
            return XCTFail("expected runsAndStations, got \(s.story)")
        }
        XCTAssertEqual(r.runs.count, 8)
        XCTAssertEqual(r.stations.count, 8)
        XCTAssertEqual(r.runSeconds, 2415, accuracy: 1e-9)
        XCTAssertEqual(r.stationSeconds, 2118, accuracy: 1e-9)
        // 1000 m targets: pace == duration.
        XCTAssertEqual(r.runs[0].paceSecondsPerKm ?? -1, 262, accuracy: 1e-9)
        XCTAssertEqual(r.runs[0].previousPaceSecondsPerKm ?? -1, 275, accuracy: 1e-9)
        XCTAssertEqual(r.runs[0].meters ?? -1, 1000, accuracy: 1e-9)
        XCTAssertEqual(r.fadeSecondsPerKm ?? -1, 68, accuracy: 1e-9)
        XCTAssertEqual(r.bestRun, 0)
        XCTAssertEqual(r.worstRun, 7)
        let lastThreeMean: Double = (318.0 + 322.0 + 330.0) / 3.0
        XCTAssertEqual(r.outFastSecondsPerKm ?? -1, lastThreeMean - 262.0, accuracy: 1e-9)
        XCTAssertTrue(r.wentOutFast)
        // Station deltas vs previous: SkiErg −4, Sled Push −13, BBJ +8, WB −18 → gain WB, loss BBJ.
        XCTAssertEqual(r.stations[0].deltaSeconds ?? 0, -4, accuracy: 1e-9)
        XCTAssertEqual(r.biggestGain, 7)
        XCTAssertEqual(r.biggestLoss, 3)          // BBJ +8
        XCTAssertEqual(r.stations[0].name, "SkiErg")
        XCTAssertEqual(r.stations[0].shortLabel, "Ski")
        XCTAssertTrue(r.stations[0].hasGap)
        XCTAssertEqual(r.stations[0].gapSeconds, 30, accuracy: 1e-9)
        XCTAssertFalse(r.stations[1].hasGap)
        XCTAssertEqual(r.stationScaleMax, 470, accuracy: 1e-9)
        XCTAssertTrue(r.hasPrevious)

        // Headline.
        XCTAssertEqual(s.headline.scoreText, "1:15:33")
        XCTAssertEqual(s.headline.contextText, "8 runs · 8 stations · 16 segments")
        let prevTotal: Double = 2453 + 2169
        XCTAssertEqual(s.headline.previousTotalSeconds ?? -1, prevTotal, accuracy: 1e-9)
        XCTAssertEqual(s.headline.deltaSeconds ?? 0, 4533 - prevTotal, accuracy: 1e-9)
        XCTAssertEqual(s.headline.deltaText, SummaryFormat.minus + "1:29")
        XCTAssertNotNil(s.headline.zone45Seconds)
        XCTAssertTrue(s.hasPrevious)

        // Timeline with a real series and one gap 315–345 s.
        let tl = s.timeline
        XCTAssertFalse(tl.isEstimated)
        XCTAssertFalse(tl.zonesEstimated)
        XCTAssertEqual(tl.maxHeartRate, 192, accuracy: 1e-9)
        XCTAssertEqual(tl.heartRate.count, Int((4533.0 / 5).rounded(.up)))
        XCTAssertEqual(tl.gaps.count, 1)
        XCTAssertEqual(tl.gaps[0].start, 315, accuracy: 1e-9)
        XCTAssertEqual(tl.gaps[0].end, 345, accuracy: 1e-9)
        XCTAssertNil(tl.heartRate(at: 330))
        XCTAssertEqual(tl.heartRate(at: 2) ?? -1, 150.0, accuracy: 1e-9)   // 150.02 rounded to 0.1
        let skiStats = tl.stats(segmentIndex: 1)
        XCTAssertEqual(skiStats.gapSeconds, 30, accuracy: 1e-9)
        XCTAssertNotNil(skiStats.average)
        // Zone runs never cover a gap.
        for z in tl.zones {
            XCTAssertTrue(z.end <= 315 || z.start >= 345, "zone run \(z) overlaps the gap")
            XCTAssertTrue((1...5).contains(z.zone))
        }
        XCTAssertEqual(tl.zone(for: 150), 3)       // 150 / 192 = 78 %
        XCTAssertEqual(tl.zone(for: 160), 4)

        // Rows and data note.
        XCTAssertEqual(s.rows.count, 16)
        XCTAssertNil(s.rows[0].groupLabel)
        XCTAssertEqual(s.rows[1].deltaSeconds ?? 0, -4, accuracy: 1e-9)
        XCTAssertEqual(s.dataNote.heartRateGapSeconds ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(s.dataNote.longestGapSegmentTitle, "SkiErg")
        XCTAssertEqual(s.dataNote.text,
                       "16 of 16 switches by Crown · no undos · HR gap 0:30 in SkiErg · no steps")

        // Without a max HR: zones estimated and no zone 4–5 time in the headline.
        let s2 = WorkoutSummary.make(result: result, previous: nil, maxHeartRate: nil)
        XCTAssertTrue(s2.timeline.zonesEstimated)
        XCTAssertNil(s2.headline.zone45Seconds)
        XCTAssertNil(s2.headline.deltaSeconds)
        XCTAssertFalse(s2.hasPrevious)
    }

    func testPreviousWithOtherDefinitionIsIgnored() {
        let a = buildResult(WorkoutLibrary.quickTest, durations: [60, 30, 60, 30])
        let b = buildResult(WorkoutLibrary.helen, durations: [100, 50, 50, 100, 50, 50, 100, 50, 50])
        let s = WorkoutSummary.make(result: a, previous: b, maxHeartRate: nil)
        XCTAssertFalse(s.hasPrevious)
        XCTAssertNil(s.headline.deltaSeconds)
        // Quick test alternates runs and stations → runsAndStations.
        guard case .runsAndStations(let r) = s.story else {
            return XCTFail("expected runsAndStations")
        }
        XCTAssertNil(r.runs[0].deltaSeconds)
        XCTAssertFalse(r.wentOutFast)          // only 2 runs
        XCTAssertNil(r.outFastSecondsPerKm)
    }

    // MARK: Every 3:00: Row + Thrusters

    func testRowThrustersIntervalSlots() {
        let def = WorkoutLibrary.rowThrusters
        let row: [Double] = [52, 54, 55, 57, 58, 60]
        let thr: [Double] = [40, 43, 46, 48, 52, 55]
        var durations: [Double] = []
        for i in 0..<6 {
            durations.append(row[i])
            durations.append(thr[i])
            if i < 5 { durations.append(180 - row[i] - thr[i]) }
        }
        XCTAssertEqual(durations.count, 17)
        // HR: rises 0.5 bpm/s in work from 100 + 5 × set, falls 0.3 bpm/s in rest.
        let hr: (Double) -> Double? = { (t: Double) -> Double? in
            let k: Int = min(5, Int(t / 180))
            let s: Double = t - Double(k) * 180
            let work: Double = row[k] + thr[k]
            let base: Double = 100 + 5 * Double(k)
            if s < work { return base + 0.5 * s }
            return base + 0.5 * work - 0.3 * (s - work)
        }
        let result = buildResult(def, durations: durations, hr: hr)
        let s = WorkoutSummary.make(result: result, previous: nil, maxHeartRate: 190)

        guard case .intervalSlots(let slots) = s.story else {
            return XCTFail("expected intervalSlots, got \(s.story)")
        }
        XCTAssertEqual(slots.intervalSeconds ?? -1, 180, accuracy: 1e-9)
        XCTAssertEqual(slots.sets.count, 6)
        XCTAssertEqual(slots.setsPlanned, 6)
        XCTAssertEqual(slots.setsCompleted, 6)
        XCTAssertEqual(slots.sets[0].parts.count, 2)
        XCTAssertEqual(slots.sets[0].parts[1].offset, 52, accuracy: 1e-9)
        XCTAssertEqual(slots.sets[0].workSeconds, 92, accuracy: 1e-9)
        XCTAssertEqual(slots.sets[0].restSeconds ?? -1, 88, accuracy: 1e-9)
        XCTAssertEqual(slots.sets[0].slotStart, 0, accuracy: 1e-9)
        XCTAssertEqual(slots.sets[5].slotStart, 900, accuracy: 1e-9)
        XCTAssertNil(slots.sets[5].restSeconds)      // no rest after set 6
        XCTAssertNil(slots.sets[5].recoveryDrop)
        XCTAssertFalse(slots.sets[0].overran)
        XCTAssertEqual(slots.workDriftSeconds ?? -1, 23, accuracy: 1e-9)
        XCTAssertEqual(slots.averageWorkSeconds ?? -1, 620.0 / 6.0, accuracy: 1e-9)
        XCTAssertEqual(slots.firstRestSeconds ?? -1, 88, accuracy: 1e-9)
        XCTAssertEqual(slots.lastRestSeconds ?? -1, 70, accuracy: 1e-9)
        // Start HR: first 5 s bucket of each set = base + 1.
        XCTAssertEqual(slots.sets[0].startHeartRate ?? -1, 101, accuracy: 1e-6)
        XCTAssertEqual(slots.sets[5].startHeartRate ?? -1, 126, accuracy: 1e-6)
        XCTAssertEqual(slots.startHeartRateText, "Start HR rose 101 → 126 over 6 sets.")
        for k in 0..<5 {
            let item = slots.sets[k]
            XCTAssertNotNil(item.peakHeartRate)
            XCTAssertGreaterThan(item.peakHeartRate ?? 0, item.startHeartRate ?? 1000)
            XCTAssertGreaterThan(item.recoveryDrop ?? 0, 0)
        }
        XCTAssertEqual(slots.partAverages.map { (m: WorkoutSummary.MovementStat) -> String in m.movement },
                       [Movement.row, Movement.thrusters])
        XCTAssertEqual(slots.partAverages[0].averageSeconds, 336.0 / 6.0, accuracy: 1e-9)

        XCTAssertEqual(s.headline.scoreText, "6 / 6")
        XCTAssertEqual(s.headline.scoreUnit, "sets")
        XCTAssertEqual(s.headline.contextText, "Avg work per set 1:43 · done at 16:55")
        XCTAssertEqual(s.timeline.bands[2].shortLabel, "Rest")
        XCTAssertEqual(s.rows[3].displayTitle, "Row 15 cal · S2")
    }

    // MARK: AMRAP 20

    func testAmrapPartialRound() {
        let def = WorkoutLibrary.amrap20
        let rounds: [[Double]] = [[75, 40, 55, 38], [82, 44, 60, 42], [88, 47, 63, 45],
                                  [95, 50, 66, 48], [102, 54, 70, 36]]
        var durations: [Double] = []
        for r in rounds { durations.append(contentsOf: r) }
        XCTAssertEqual(durations.reduce(0, +), 1200, accuracy: 1e-9)
        let result = buildResult(def, durations: durations, capFinish: true,
                                 hr: { (t: Double) -> Double? in 140 + t / 60 })
        let s = WorkoutSummary.make(result: result, previous: nil, maxHeartRate: nil)

        guard case .amrapClock(let a) = s.story else {
            return XCTFail("expected amrapClock, got \(s.story)")
        }
        XCTAssertEqual(a.capSeconds, 1200, accuracy: 1e-9)
        XCTAssertEqual(a.rounds.count, 5)
        XCTAssertEqual(a.completedRounds, 4)
        XCTAssertEqual(a.extraReps, 51)                 // 10 + 31 + 10
        XCTAssertFalse(a.rounds[4].isComplete)
        XCTAssertEqual(a.rounds[4].completedParts, 3)
        XCTAssertTrue(a.rounds[4].parts[3].isPartial)
        XCTAssertEqual(a.rounds[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(a.rounds[1].start, 208, accuracy: 1e-9)
        XCTAssertEqual(a.stoppedIn?.name, "Double Unders")
        XCTAssertEqual(a.stoppedIn?.secondsIn ?? -1, 36, accuracy: 1e-9)
        XCTAssertEqual(a.stoppedIn?.round, 4)
        let expectedDrift: Double = (259.0 - 208.0) / 208.0 * 100
        XCTAssertEqual(a.driftPercent ?? -1, expectedDrift, accuracy: 1e-9)
        XCTAssertEqual(a.driftText, "Round 4 took 25 % longer than round 1")
        let expectedAverage: Double = (208.0 + 228.0 + 243.0 + 259.0) / 4.0
        XCTAssertEqual(a.averageRoundSeconds ?? -1, expectedAverage, accuracy: 1e-9)
        let du = a.movements.first(where: { (m: WorkoutSummary.MovementStat) -> Bool in
            m.movement == Movement.doubleUnders
        })
        XCTAssertEqual(du?.count, 9)
        XCTAssertEqual(du?.bestSeconds ?? -1, 38, accuracy: 1e-9)
        XCTAssertEqual(a.slowedMostColumn, 0)           // burpees +20 s
        XCTAssertEqual(a.slowedMostSeconds ?? -1, 20, accuracy: 1e-9)

        XCTAssertEqual(s.headline.scoreText, "4 + 51")
        XCTAssertEqual(s.headline.scoreUnit, "rounds + reps")
        XCTAssertEqual(s.headline.rounds, 4)
        XCTAssertEqual(s.headline.extraReps, 51)
        XCTAssertEqual(s.headline.contextText, "Stopped in Double Unders, 0:36 in, at the 20:00 cap")
        XCTAssertFalse(s.headline.isFinished)
        XCTAssertEqual(s.headline.stoppedIn, "Double Unders")
        XCTAssertNil(s.headline.deltaSeconds)
        XCTAssertTrue(s.rows[19].isPartial)
        XCTAssertFalse(s.rows[18].isPartial)
        XCTAssertEqual(s.dataNote.text,
                       "19 of 20 switches by Crown · 1 automatic · no undos · HR complete · no steps")
    }

    // MARK: Fallback and estimated HR without series

    func testFallbackSegmentsAndEstimatedTimeline() {
        let def = WorkoutLibrary.partnerWod2
        let result = buildResult(def, durations: [240, 120, 90, 150, 250],
                                 hr: { (t: Double) -> Double? in 150 }, withSeries: false)
        let s = WorkoutSummary.make(result: result, previous: nil, maxHeartRate: nil)
        guard case .segments(let bars) = s.story else {
            return XCTFail("expected segments, got \(s.story)")
        }
        XCTAssertEqual(bars.count, 5)
        XCTAssertEqual(bars[4].fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(bars[2].fraction, 90.0 / 250.0, accuracy: 1e-9)
        XCTAssertTrue(s.timeline.isEstimated)
        XCTAssertEqual(s.timeline.heartRate.compactMap { (v: Double?) -> Double? in v }.count, s.timeline.heartRate.count)
        XCTAssertEqual(s.headline.contextText, "5 segments")
    }

    // MARK: Story choice and round size

    func testStoryChoiceAndRoundSizes() {
        XCTAssertEqual(WorkoutLibrary.helen.roundSize, 3)
        XCTAssertEqual(WorkoutLibrary.rowThrusters.roundSize, 3)
        XCTAssertEqual(WorkoutLibrary.amrap20.roundSize, 4)
        XCTAssertEqual(WorkoutLibrary.hyroxSolo.roundSize, 2)
        XCTAssertEqual(WorkoutLibrary.hyroxDoubles.roundSize, 2)
        XCTAssertEqual(WorkoutLibrary.halfHyrox.roundSize, 2)
        XCTAssertEqual(WorkoutLibrary.partnerWod1.roundSize, 2)
        XCTAssertNil(WorkoutLibrary.partnerWod2.roundSize)
        XCTAssertNil(WorkoutLibrary.quickTest.roundSize)

        // Detection without roundSize.
        var h = WorkoutLibrary.helen
        h.roundSize = nil
        XCTAssertEqual(WorkoutSummary.effectiveRoundSize(h), 3)
        var rt = WorkoutLibrary.rowThrusters
        rt.roundSize = nil
        XCTAssertEqual(WorkoutSummary.effectiveRoundSize(rt), 3)   // partial last set allowed
        var am = WorkoutLibrary.amrap20
        am.roundSize = nil
        XCTAssertEqual(WorkoutSummary.effectiveRoundSize(am), 4)
        var hy = WorkoutLibrary.hyroxSolo
        hy.roundSize = nil
        XCTAssertEqual(WorkoutSummary.effectiveRoundSize(hy), 2)   // alternation
        XCTAssertNil(WorkoutSummary.effectiveRoundSize(WorkoutLibrary.partnerWod2))
        XCTAssertTrue(WorkoutSummary.alternatesRunsAndStations(WorkoutLibrary.partnerWod1))
        XCTAssertFalse(WorkoutSummary.alternatesRunsAndStations(WorkoutLibrary.helen))

        let w1 = buildResult(WorkoutLibrary.partnerWod1, durations: [300, 200, 240, 180, 180, 160, 120, 100, 60, 90])
        if case .runsAndStations(let r) = WorkoutSummary.make(result: w1, previous: nil, maxHeartRate: nil).story {
            // 800 m run in 240 s → 300 s/km.
            XCTAssertEqual(r.runs[1].paceSecondsPerKm ?? -1, 300, accuracy: 1e-9)
        } else {
            XCTFail("Partner WOD 1 should be runsAndStations")
        }
    }

    func testEndedEarlyIsPartial() {
        // Helen ended during round 2 pull-ups without finishing.
        var p = WorkoutProgress(definition: WorkoutLibrary.helen)
        p.start(at: 0)
        var t: Double = 0
        for d in [120.0, 50, 55, 130, 50] {
            t += d
            p.advance(at: t, source: .crown)
        }
        let segs = SplitStats.compute(progress: p, now: t + 20, heartRates: [], pedometer: [])
        let r = WorkoutResult(definition: WorkoutLibrary.helen, startDate: Date(timeIntervalSince1970: 0),
                              finishDate: nil, endDate: Date(timeIntervalSince1970: t + 20),
                              totalSeconds: t + 20, segments: segs, events: p.events)
        let s = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertFalse(s.headline.isFinished)
        XCTAssertEqual(s.headline.stoppedIn, "Pull-ups")
        XCTAssertEqual(s.headline.contextText, "3 rounds for time · Not finished · ended in Pull-ups")
        guard case .roundGrid(let g) = s.story else { return XCTFail("expected roundGrid") }
        XCTAssertEqual(g.rounds.count, 2)
        XCTAssertTrue(g.rounds[0].isComplete)
        XCTAssertFalse(g.rounds[1].isComplete)
        XCTAssertTrue(g.rounds[1].cells[2].isPartial)
        XCTAssertNil(g.rounds[1].cells[2].deviationSeconds)
        XCTAssertNil(g.fastestRound)
        XCTAssertNil(g.driftPercent)
        XCTAssertFalse(s.timeline.hasHeartRate)
        XCTAssertTrue(s.dataNote.heartRateMissing)
        XCTAssertEqual(s.dataNote.text, "5 of 5 switches by Crown · no undos · no HR · no steps")
    }

    // MARK: HeartRateSeries

    func testHeartRateSeriesBucketsAndGaps() {
        let samples: [TimedValue] = [
            TimedValue(t: 12, value: 120),
            TimedValue(t: 0, value: 100),
            TimedValue(t: 1, value: 110),
            TimedValue(t: 40, value: 130),
            TimedValue(t: -3, value: 999),     // before start: ignored
            TimedValue(t: 100, value: 999)     // after end: ignored
        ]
        let s = HeartRateSeries.make(samples: samples, start: 0, end: 80)
        XCTAssertEqual(s.start, 0)
        XCTAssertEqual(s.interval, 5)
        let expected: [Double?] = [105, 115.9, 120, 120, 120, 130, 130, 130, 130, 130, 130,
                                   nil, nil, nil, nil, nil]
        XCTAssertEqual(s.bpm, expected)
        XCTAssertEqual(s.value(at: 2), 105)
        XCTAssertNil(s.value(at: 56))
        XCTAssertNil(s.value(at: -1))
        XCTAssertNil(s.value(at: 80))
        XCTAssertEqual(s.centre(1), 7.5)

        XCTAssertEqual(HeartRateSeries.make(samples: samples, start: 10, end: 10).bpm.count, 0)
        XCTAssertEqual(HeartRateSeries.make(samples: [], start: 0, end: 12).bpm, [nil, nil, nil])
        // Sample exactly at the end belongs to the last bucket.
        let e = HeartRateSeries.make(samples: [TimedValue(t: 10, value: 90)], start: 0, end: 10, maxGap: 0)
        XCTAssertEqual(e.bpm, [nil, 90])
    }

    // MARK: JSON

    func testVersion2RoundTripWithNulls() throws {
        let def = WorkoutLibrary.helen
        let hr: (Double) -> Double? = { (t: Double) -> Double? in
            (t >= 100 && t < 160) ? nil : 140 + t / 50
        }
        let r = buildResult(def, durations: [120, 50, 55, 130, 50, 60, 140, 55, 55], hr: hr,
                            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        XCTAssertEqual(r.version, 2)
        XCTAssertNotNil(r.heartRateSeries)
        XCTAssertTrue(r.heartRateSeries?.bpm.contains(where: { (v: Double?) -> Bool in v == nil }) ?? false)
        XCTAssertNotNil(r.segments[0].heartRateMin)
        XCTAssertEqual(r.segments[0].heartRateMin ?? -1, 140, accuracy: 1e-9)

        let data = try r.encoded()
        let back = try WorkoutResult.decode(from: data)
        XCTAssertEqual(back, r)
        let obj = try jsonObject(data)
        XCTAssertEqual(number(obj["version"]), 2)
        let series = obj["heartRateSeries"] as? [String: Any]
        let bpm = series?["bpm"] as? [Any]
        XCTAssertNotNil(bpm)
        XCTAssertTrue(bpm?.contains(where: { (v: Any) -> Bool in v is NSNull }) ?? false)
        let defObj = obj["definition"] as? [String: Any]
        XCTAssertEqual(number(defObj?["roundSize"]), 3)

        // Summary from the decoded file uses the real series.
        let s = WorkoutSummary.make(result: back, previous: nil, maxHeartRate: 185)
        XCTAssertFalse(s.timeline.isEstimated)
        XCTAssertFalse(s.timeline.gaps.isEmpty)
    }

    func testVersion1JSONWithoutNewFieldsDecodes() throws {
        let json = """
        {"version":1,"id":"11111111-2222-3333-4444-555555555555",
         "definition":{"id":"wod.helen","name":"Helen","shortName":"Helen","format":"forTime","team":"solo",
           "healthKitActivity":"crossTraining","timeCapSeconds":960,
           "segments":[{"kind":"run","movement":"run","name":"Run","target":{"value":400,"unit":"meters"}}]},
         "startDate":"2026-10-29T02:02:45.246Z","endDate":"2026-10-29T02:05:00Z","totalSeconds":120,
         "segments":[{"index":0,"kind":"run","movement":"run","title":"Run 400 m","start":1793239365.246,
           "end":1793239485.246,"duration":120,"heartRateAvg":150}],
         "events":[]}
        """
        let r = try WorkoutResult.decode(from: Data(json.utf8))
        XCTAssertEqual(r.version, 1)
        XCTAssertNil(r.heartRateSeries)
        XCTAssertNil(r.definition.roundSize)
        XCTAssertNil(r.segments[0].heartRateMin)
        let s = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil)
        XCTAssertTrue(s.timeline.isEstimated)
        XCTAssertEqual(s.timeline.heartRate.count, 24)
        XCTAssertEqual(s.timeline.heartRate[0] ?? -1, 150, accuracy: 1e-9)
    }

    // MARK: Formatting

    func testSummaryFormat() {
        XCTAssertEqual(SummaryFormat.clock(0), "0:00")
        XCTAssertEqual(SummaryFormat.clock(42.4), "0:42")
        XCTAssertEqual(SummaryFormat.clock(767.3), "12:47")
        XCTAssertEqual(SummaryFormat.clock(4533), "1:15:33")
        XCTAssertEqual(SummaryFormat.clock(-5), SummaryFormat.minus + "0:05")
        XCTAssertEqual(SummaryFormat.signed(12), "+0:12")
        XCTAssertEqual(SummaryFormat.signed(-5), "\u{2212}0:05")
        XCTAssertEqual(SummaryFormat.signed(-0.2), "+0:00")
        XCTAssertEqual(SummaryFormat.pace(309), "5:09")
        XCTAssertEqual(SummaryFormat.pace(nil), "\u{2013}")
        XCTAssertEqual(SummaryFormat.bpm(151.6), "152")
        XCTAssertEqual(SummaryFormat.signedPercent(21.4), "+21 %")
        XCTAssertEqual(SummaryFormat.signedNumber(-35), "\u{2212}35")
        let none: Double? = nil
        XCTAssertEqual(SummaryFormat.clock(none), "\u{2013}")
    }
}
