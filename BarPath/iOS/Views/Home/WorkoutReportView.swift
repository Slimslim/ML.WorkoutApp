import SwiftUI
import BarPathKit

/// One colour of the time bar: a modality, Rest, or other time.
private struct BudgetPart: Identifiable {
    let id: Int
    let name: String
    let color: Color
    let seconds: Double
}

private enum TimeBudget {
    /// EMOM with found lifts: lifting, Transitioning before the first lift, and Rest.
    static func minutes(_ result: WorkoutResult) -> [BudgetPart]? {
        let sets: [EmomSet] = EmomSet.all(result)
        guard !sets.isEmpty, sets.allSatisfy({ (s: EmomSet) -> Bool in s.found }) else { return nil }
        let lifting: Double = sets.reduce(0) { (t: Double, s: EmomSet) -> Double in t + s.lastEnd - s.firstStart }
        let lead: Double = sets.reduce(0) { (t: Double, s: EmomSet) -> Double in t + s.firstStart }
        let rest: Double = sets.reduce(0) { (t: Double, s: EmomSet) -> Double in t + s.rest }
        let m: Modality? = Modality.of(movement: sets[0].station.movement)
        return [BudgetPart(id: 0, name: "Lifting", color: m?.color ?? Color(uiColor: .systemGray3), seconds: lifting),
                BudgetPart(id: 1, name: "Transitioning", color: Color(uiColor: .systemGray4), seconds: lead),
                BudgetPart(id: 2, name: "Rest", color: Theme.tileBackground, seconds: rest)]
    }

    static func make(_ result: WorkoutResult) -> [BudgetPart] {
        if let parts = minutes(result) { return parts }
        var order: [String] = []
        var seconds: [String: Double] = [:]
        var colors: [String: Color] = [:]
        for s in result.segments {
            let name: String
            let color: Color
            if s.kind == .rest {
                name = "Rest"
                color = Theme.tileBackground
            } else if s.kind == .transition {
                name = "Transitioning"
                color = Color(uiColor: .systemGray4)
            } else if let m = Modality.of(movement: s.movement) {
                name = m.name
                color = m.color
            } else {
                name = "Other"
                color = Color(uiColor: .systemGray3)
            }
            if seconds[name] == nil {
                order.append(name)
                colors[name] = color
            }
            seconds[name, default: 0] += s.duration
        }
        return order.enumerated().map { (item: (offset: Int, element: String)) -> BudgetPart in
            BudgetPart(id: item.offset, name: item.element,
                       color: colors[item.element] ?? Color.gray, seconds: seconds[item.element] ?? 0)
        }
    }
}

/// One round, set or split of the report. A minute of an EMOM has `minute` instead of parts.
private struct ReportRow: Identifiable {
    let id: Int
    let title: String
    let seconds: Double
    var right: String? = nil
    var note: String? = nil
    let parts: [(color: Color, seconds: Double)]
    var minute: MinuteTrack? = nil
}

/// Where the lifts fell inside one minute, as shares of the minute.
private struct MinuteTrack {
    let lead: Double
    let lifts: [(start: Double, width: Double)]
    let color: Color
}

/// One set of an EMOM, placed in its own minute from the found lifts (or the segment without them).
private struct EmomSet {
    let number: Int
    let interval: Double
    let station: SegmentResult
    let load: SegmentLoad?
    /// [start, end] in seconds into the minute.
    let spans: [(start: Double, end: Double)]
    let found: Bool

    var firstStart: Double { return spans.first?.start ?? 0 }
    var lastEnd: Double { return spans.last?.end ?? 0 }
    var rest: Double { return Swift.max(0, interval - lastEnd) }

    static func all(_ result: WorkoutResult) -> [EmomSet] {
        guard result.definition.format == .emom, let t0 = result.segments.first?.start else { return [] }
        let interval: Double = result.definition.intervalSeconds ?? 60
        let stations: [SegmentResult] = result.segments.filter { (s: SegmentResult) -> Bool in s.kind == .station }
        return stations.enumerated().map { (item: (offset: Int, element: SegmentResult)) -> EmomSet in
            let st: SegmentResult = item.element
            let mark: Double = t0 + Double(item.offset) * interval
            let lifts: [[Double]] = (st.lifts ?? []).filter { (l: [Double]) -> Bool in l.count == 2 }
            var spans: [(start: Double, end: Double)] = lifts.map { (l: [Double]) -> (start: Double, end: Double) in
                (l[0] - mark, l[1] - mark)
            }
            if spans.isEmpty {
                spans = [(Swift.max(0, st.start - mark), Swift.min(interval, st.end - mark))]
            }
            let defs: [WorkoutSegment] = result.definition.segments
            let load: SegmentLoad? = st.index < defs.count ? defs[st.index].load : nil
            return EmomSet(number: item.offset + 1, interval: interval, station: st, load: load,
                           spans: spans, found: !lifts.isEmpty)
        }
    }

    /// Heaviest set in pounds, nil when no set has a load.
    static func heaviestPounds(_ sets: [EmomSet]) -> Int? {
        let kilos: [Double] = sets.compactMap { (s: EmomSet) -> Double? in s.load?.kilograms }
        guard let top = kilos.max() else { return nil }
        return Int((top / 0.45359237).rounded())
    }
}

private enum ReportRows {
    static func color(_ s: SegmentResult) -> Color {
        if s.kind == .rest { return Theme.tileBackground }
        return Modality.of(movement: s.movement)?.color ?? Color(uiColor: .systemGray3)
    }

    static func color(band: WorkoutSummary.Band) -> Color {
        if band.kind == .rest { return Color(uiColor: .systemGray3) }
        return Modality.of(movement: band.movement)?.color ?? Color(uiColor: .systemGray3)
    }

    static func make(_ result: WorkoutResult) -> (title: String, rows: [ReportRow]) {
        let sets: [EmomSet] = EmomSet.all(result)
        if !sets.isEmpty { return ("Minute by minute", minuteRows(sets)) }
        let size: Int = result.definition.roundSize ?? 1
        let segments: [SegmentResult] = result.segments
        if size <= 1 {
            let rows: [ReportRow] = segments.enumerated().map { (item: (offset: Int, element: SegmentResult)) -> ReportRow in
                ReportRow(id: item.offset, title: item.element.title, seconds: item.element.duration,
                          parts: [(color(item.element), item.element.duration)])
            }
            return ("Splits", rows)
        }
        var rows: [ReportRow] = []
        var i: Int = 0
        while i < segments.count {
            let group: [SegmentResult] = Array(segments[i..<Swift.min(i + size, segments.count)])
            let n: Int = rows.count + 1
            rows.append(ReportRow(id: n, title: "Round " + String(n),
                                  seconds: group.reduce(0) { (t: Double, s: SegmentResult) -> Double in t + s.duration },
                                  parts: group.map { (s: SegmentResult) -> (color: Color, seconds: Double) in (color(s), s.duration) }))
            i += size
        }
        return ("Rounds", rows)
    }

    private static func minuteRows(_ sets: [EmomSet]) -> [ReportRow] {
        return sets.map { (s: EmomSet) -> ReportRow in
            var title: String = String(s.number)
            if let load = s.load {
                title += " \u{00B7} " + String(Int((load.kilograms / 0.45359237).rounded())) + " lb"
            } else {
                title = "Minute " + title
            }
            // One block per set until rep detection runs in the app, then a pill per lift.
            let spans: [(start: Double, width: Double)] = [(s.firstStart / s.interval, (s.lastEnd - s.firstStart) / s.interval)]
            let color: Color = Modality.of(movement: s.station.movement)?.color ?? Color(uiColor: .systemGray3)
            var note: String? = nil
            if s.found {
                let reps: Int = s.spans.count
                note = "Started " + String(Int(s.firstStart.rounded())) + " s in \u{00B7} "
                    + String(Int((s.lastEnd - s.firstStart).rounded())) + " s for " + String(reps)
                    + (reps == 1 ? " rep" : " reps")
            }
            return ReportRow(id: s.number, title: title, seconds: s.interval,
                             right: String(Int(s.rest.rounded())) + " s rest", note: note, parts: [],
                             minute: MinuteTrack(lead: s.firstStart / s.interval, lifts: spans, color: color))
        }
    }
}

/// The workout report (docs/DESIGN_GUIDELINES.md): score, time by modality, Effort and heart rate,
/// AI insights (coming soon), rounds, heart rate through the workout with its bands, zones and
/// scrubbing, and recovery, each in its own card.
struct WorkoutReportView: View {
    let result: WorkoutResult
    let previous: WorkoutResult?
    let card: WorkoutCard
    let meta: String
    /// Highest heart rate recorded, for Effort.
    let maxHeartRate: Double?
    private let summary: WorkoutSummary
    @State private var showAI: Bool = false
    @State private var selection: ClosedRange<Int>? = nil
    @State private var hoverTime: Double? = nil

    init(result: WorkoutResult, previous: WorkoutResult?, card: WorkoutCard, meta: String, maxHeartRate: Double?) {
        self.result = result
        self.previous = previous
        self.card = card
        self.meta = meta
        self.maxHeartRate = maxHeartRate
        self.summary = WorkoutSummary.make(result: result, previous: previous, maxHeartRate: maxHeartRate)
    }

    var body: some View {
        let headline: WorkoutSummary.Headline = summary.headline
        let budget: [BudgetPart] = TimeBudget.make(result)
        let rows: (title: String, rows: [ReportRow]) = ReportRows.make(result)
        VStack(alignment: .leading, spacing: 12) {
            scoreCard(headline, budget: budget)
            aiCard
            rowsCard(rows.title, rows: rows.rows)
            heartRateCard
        }
    }

    // MARK: Score

    private func scoreCard(_ h: WorkoutSummary.Headline, budget: [BudgetPart]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta + " \u{00B7} " + tagLine)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(card.name)
                .font(.system(size: 25, weight: .medium))
                .padding(.top, 6)
            boardLines
                .padding(.top, 6)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(scoreText(h))
                    .font(.system(size: 46, weight: .medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit = scoreUnit(h) {
                    Text(unit)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 16)
            Text(contextText(h))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            timeBar(budget)
                .padding(.top, 16)
            stats
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The workout as the whiteboard writes it, one thing per line.
    private var boardLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let scheme = card.repSchemeLine {
                Text(scheme)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
            } else if let domain = card.timeDomainLine {
                Text(domain)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
            }
            ForEach(Array(card.visibleLines().lines.enumerated()), id: \.offset) { (item: (offset: Int, element: WorkoutCard.Line)) in
                WorkoutCardView.lineText(item.element)
                    .font(.system(size: 14))
            }
        }
    }

    private var tagLine: String {
        var parts: [String] = []
        if let block = card.blockTag { parts.append(block.label) }
        if let type = card.typeTag { parts.append(type.label) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func scoreText(_ h: WorkoutSummary.Headline) -> String {
        if let top = EmomSet.heaviestPounds(EmomSet.all(result)) { return String(top) }
        if let rounds = h.rounds, (h.extraReps ?? 0) == 0 { return String(rounds) }
        return h.scoreText
    }

    private func scoreUnit(_ h: WorkoutSummary.Headline) -> String? {
        if EmomSet.heaviestPounds(EmomSet.all(result)) != nil { return "lb, heaviest set" }
        if h.rounds != nil, (h.extraReps ?? 0) == 0 { return "rounds" }
        return h.scoreUnit
    }

    private func contextText(_ h: WorkoutSummary.Headline) -> String {
        if EmomSet.heaviestPounds(EmomSet.all(result)) != nil {
            return h.scoreText.replacingOccurrences(of: " / ", with: " of ") + " sets"
        }
        if let under = h.underCapSeconds, let cap = h.capSeconds {
            return WorkoutFmt.clock(under) + " under the " + WorkoutFmt.clock(cap) + " cap"
        }
        return h.contextText
    }

    private func timeBar(_ budget: [BudgetPart]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { (geo: GeometryProxy) in
                let total: Double = budget.reduce(0) { (t: Double, p: BudgetPart) -> Double in t + p.seconds }
                let gaps: CGFloat = CGFloat(max(0, budget.count - 1)) * 2
                HStack(spacing: 2) {
                    ForEach(budget) { (p: BudgetPart) in
                        Rectangle()
                            .fill(p.color)
                            .frame(width: total > 0 ? max(0, (geo.size.width - gaps) * CGFloat(p.seconds / total)) : 0)
                    }
                }
            }
            .frame(height: 6)
            FlowLegend(parts: budget)
        }
    }

    private var stats: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                stat("Effort", effortText)
                stat("Avg HR", WorkoutFmt.bpm(result.heartRateAvg))
                stat("Max HR", WorkoutFmt.bpm(result.heartRateMax))
            }
            .padding(.top, 10)
        }
    }

    private var effortText: String {
        guard let hr = maxHeartRate else { return "\u{2014}" }
        return EffortDays.text(result.effort(maxHeartRate: hr))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI insights

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showAI.toggle()
            } label: {
                HStack {
                    Text("AI insights")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Image(systemName: showAI ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showAI {
                Text("Coming soon.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: Rounds

    private func rowsCard(_ title: String, rows: [ReportRow]) -> some View {
        let longest: Double = rows.map { (r: ReportRow) -> Double in r.seconds }.max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .padding(.bottom, 6)
            ForEach(rows) { (row: ReportRow) in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.title)
                            .lineLimit(1)
                        Spacer()
                        Text(row.right ?? WorkoutFmt.clock(row.seconds))
                            .monospacedDigit()
                    }
                    .font(.system(size: 14, weight: .medium))
                    if let minute = row.minute {
                        minuteBar(minute)
                    } else {
                    GeometryReader { (geo: GeometryProxy) in
                        let width: CGFloat = geo.size.width * CGFloat(longest > 0 ? row.seconds / longest : 0)
                        let gaps: CGFloat = CGFloat(max(0, row.parts.count - 1))
                        HStack(spacing: 1) {
                            ForEach(row.parts.indices, id: \.self) { (i: Int) in
                                Rectangle()
                                    .fill(row.parts[i].color)
                                    .frame(width: row.seconds > 0
                                           ? max(0, (width - gaps) * CGFloat(row.parts[i].seconds / row.seconds)) : 0)
                            }
                        }
                    }
                    .frame(height: 4)
                    }
                    if let note = row.note {
                        Text(note)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 8)
                if row.id != rows.last?.id {
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The whole minute: Transitioning before the first lift, the lifting, Rest after.
    private func minuteBar(_ minute: MinuteTrack) -> some View {
        GeometryReader { (geo: GeometryProxy) in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Theme.tileBackground)
                Rectangle()
                    .fill(Color(uiColor: .systemGray4))
                    .frame(width: geo.size.width * CGFloat(minute.lead))
                ForEach(minute.lifts.indices, id: \.self) { (i: Int) in
                    Rectangle()
                        .fill(minute.color)
                        .frame(width: Swift.max(4, geo.size.width * CGFloat(minute.lifts[i].width)))
                        .offset(x: geo.size.width * CGFloat(minute.lifts[i].start))
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    // MARK: Heart rate

    private var heartRateCard: some View {
        let timeline: WorkoutSummary.Timeline = summary.timeline
        let recovery: HeartRateRecovery? = result.heartRateRecovery
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Heart rate through the workout")
                    .font(.system(size: 15, weight: .medium))
                Text("Tap or drag across the chart.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            TimelineChartView(timeline: timeline, selection: selection, hoverTime: hoverTime,
                              onTouch: touch, onStep: step, bandColor: ReportRows.color(band:))
            zoneLine(timeline)
            if selection != nil || hoverTime != nil {
                TimelineChip(summary: summary, selection: selection, hoverTime: hoverTime, onClear: clearChart)
            }
            if !timeline.hasHeartRate {
                Text("No heart rate saved for this one.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else if timeline.isEstimated {
                Text("Detailed heart rate wasn't saved. The line shows each split's average.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            if let r = recovery {
                Divider()
                Text("Recovery")
                    .font(.system(size: 15, weight: .medium))
                HStack(spacing: 0) {
                    recoveryCell("Finish", String(Int(r.heartRateAtFinish.rounded())), nil)
                    ForEach(1...3, id: \.self) { (m: Int) in
                        let mark: HeartRateRecovery.Mark? = r.mark(minutes: m)
                        recoveryCell(String(m) + " min",
                                     mark.map { (x: HeartRateRecovery.Mark) -> String in String(Int(x.heartRate.rounded())) } ?? "\u{2014}",
                                     mark.map { (x: HeartRateRecovery.Mark) -> String in "\u{2212}" + String(Int(x.drop.rounded())) })
                    }
                }
                Text("A bigger drop in the first minute usually means better fitness.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func zoneLine(_ timeline: WorkoutSummary.Timeline) -> some View {
        HStack(spacing: 5) {
            ForEach(1..<6, id: \.self) { (z: Int) in
                Rectangle()
                    .fill(Theme.ovZone(z))
                    .frame(width: 8, height: 8)
            }
            Text("Zones 1\u{2013}5, max " + String(Int(timeline.maxHeartRate.rounded())))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if timeline.recovery != nil {
                Rectangle()
                    .fill(Theme.ovRecovery)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 8)
                Text("Recovery")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func touch(_ t: Double) {
        let timeline: WorkoutSummary.Timeline = summary.timeline
        hoverTime = t
        if timeline.isRecovery(at: t) {
            selection = nil
        } else if let index = timeline.segment(at: t) {
            selection = index...index
        }
    }

    private func step(_ delta: Int) {
        let bands: [WorkoutSummary.Band] = summary.timeline.bands
        if bands.isEmpty { return }
        var current: Int = 0
        if let s = selection, let i = bands.firstIndex(where: { (b: WorkoutSummary.Band) -> Bool in b.segmentIndex == s.lowerBound }) {
            current = i + delta
        }
        let n: Int = bands.count
        let index: Int = bands[((current % n) + n) % n].segmentIndex
        hoverTime = nil
        selection = index...index
    }

    private func clearChart() {
        hoverTime = nil
        selection = nil
    }

    private func recoveryCell(_ label: String, _ value: String, _ drop: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .medium))
                .monospacedDigit()
            Text(drop ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(Color.green)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Coloured squares with the time of each part; wraps to a second line on narrow screens.
private struct FlowLegend: View {
    let parts: [BudgetPart]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(parts) { (p: BudgetPart) in
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(p.color)
                        .frame(width: 8, height: 8)
                    Text(p.name + " " + WorkoutFmt.clock(p.seconds))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                }
            }
        }
    }
}
