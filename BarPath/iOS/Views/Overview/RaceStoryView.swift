import SwiftUI
import BarPathKit

/// HYROX and other runs + stations: runs vs stations split, run pace strip, stations list.
struct RaceStoryView: View {
    let data: WorkoutSummary.RunsAndStations
    let summary: WorkoutSummary
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RunsStationsSplitBar(data: data, totalSeconds: summary.headline.totalSeconds)
            OvSectionDivider()
            RunPaceSection(data: data, previousDate: summary.previousDate,
                           selection: selection, onSelect: onSelect)
            OvSectionDivider()
            StationsSection(data: data, selection: selection, onSelect: onSelect)
        }
    }
}

// MARK: - Where the time went

struct RunsStationsSplitBar: View {
    let data: WorkoutSummary.RunsAndStations
    let totalSeconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OvSectionHeader(title: "Where the time went",
                            caption: "Runs and stations as share of " + SummaryFormat.clock(totalSeconds) + ".")
            bar
            HStack(alignment: .top) {
                labelBlock("Runs", data.runSeconds, TextAlignment.leading)
                Spacer()
                labelBlock("Stations", data.stationSeconds, TextAlignment.trailing)
            }
            roxNote
        }
    }

    private var bar: some View {
        let runPart: Double = Swift.max(0.0001, data.runSeconds)
        let stationPart: Double = Swift.max(0.0001, data.stationSeconds)
        return GeometryReader { (geo: GeometryProxy) in
            let usable: CGFloat = Swift.max(0, geo.size.width - 2)
            let runWidth: CGFloat = usable * CGFloat(runPart / (runPart + stationPart))
            HStack(spacing: 2) {
                segment("Runs", Theme.ovRun, runWidth)
                segment("Stations", Theme.ovStation, usable - runWidth)
            }
        }
        .frame(height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func segment(_ title: String, _ color: Color, _ width: CGFloat) -> some View {
        return ZStack(alignment: .leading) {
            Rectangle().fill(color)
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.cardBackground)
                .padding(.horizontal, 8)
                .lineLimit(1)
        }
        .frame(width: Swift.max(0, width))
        .clipped()
    }

    private func labelBlock(_ title: String, _ seconds: Double, _ alignment: TextAlignment) -> some View {
        let horizontal: HorizontalAlignment = alignment == TextAlignment.trailing
            ? HorizontalAlignment.trailing : HorizontalAlignment.leading
        return VStack(alignment: horizontal, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.ovFg2)
            Text(SummaryFormat.clock(seconds))
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .monospacedDigit()
        }
    }

    private var roxNote: some View {
        HStack(alignment: .top, spacing: 6) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(Theme.ovRun, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                .frame(width: 14, height: 8)
                .padding(.top, 3)
            Text("Roxzone (station to run mat) is inside run time for now. It gets its own share once the watch records transitions.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }
}

// MARK: - Run pace

struct RunPaceSection: View {
    let data: WorkoutSummary.RunsAndStations
    let previousDate: Date?
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    private var caption: String {
        var text: String = "Higher = faster."
        if data.hasPrevious {
            text += " Hollow dots: your last attempt"
            if let d = previousDate { text += " (" + OverviewFormat.shortDate(d) + ")" }
            text += "."
        }
        return text + " Pace includes Roxzone."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OvSectionHeader(title: "Run pace, 1 to " + String(data.runs.count), caption: caption)
            PaceChartView(runs: data.runs, selection: selection, onSelect: onSelect)
            runButtons
            statTiles
            flag
        }
    }

    private var runButtons: some View {
        HStack(spacing: 0) {
            ForEach(data.runs) { (run: WorkoutSummary.RunSplit) in
                RunButton(run: run,
                          state: OverviewSel.state(selection, run.segmentIndex, run.segmentIndex),
                          onTap: { onSelect(run.segmentIndex, run.segmentIndex) })
            }
        }
    }

    private var statTiles: some View {
        HStack(spacing: 8) {
            OvStatTile(key: "Fade", value: fadeValue, detail: "run \(data.runs.count) vs run 1, /km",
                       valueColor: fadeColor)
            OvStatTile(key: "Best", value: bestValue, detail: bestDetail)
            OvStatTile(key: "Worst", value: worstValue, detail: worstDetail)
        }
        .padding(.top, 4)
    }

    private var fadeValue: String {
        guard let f = data.fadeSecondsPerKm else { return SummaryFormat.missing }
        return SummaryFormat.signed(f)
    }

    private var fadeColor: Color {
        guard let f = data.fadeSecondsPerKm else { return Theme.ovFg }
        return f > 0 ? Theme.ovSlow : Theme.ovFast
    }

    private func run(at index: Int?) -> WorkoutSummary.RunSplit? {
        guard let i = index, i >= 0, i < data.runs.count else { return nil }
        return data.runs[i]
    }

    private var bestValue: String {
        return SummaryFormat.pace(run(at: data.bestRun)?.paceSecondsPerKm)
    }

    private var bestDetail: String {
        guard let r = run(at: data.bestRun) else { return "" }
        return "run \(r.number), /km"
    }

    private var worstValue: String {
        return SummaryFormat.pace(run(at: data.worstRun)?.paceSecondsPerKm)
    }

    private var worstDetail: String {
        guard let w = run(at: data.worstRun), let b = run(at: data.bestRun),
              let wp = w.paceSecondsPerKm, let bp = b.paceSecondsPerKm else { return "" }
        return SummaryFormat.signed(wp - bp) + " vs best"
    }

    @ViewBuilder
    private var flag: some View {
        if data.wentOutFast && data.outFastSecondsPerKm != nil {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.ovSlow)
                    .frame(width: 3)
                flagText
                    .font(.footnote)
                    .padding(.leading, 10)
                    .padding(.vertical, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 6)
        }
    }
}

extension RunPaceSection {
    fileprivate var flagText: Text {
        let out: Double = data.outFastSecondsPerKm ?? 0
        let lead: Text = Text("Went out fast. ").bold().foregroundColor(Theme.ovSlow)
        let rest: Text = Text("Run 1 was " + SummaryFormat.clock(out)
                              + "/km faster than your last three runs. Rule of thumb: keep that under 0:20/km.")
        return lead + rest
    }
}

struct RunButton: View {
    let run: WorkoutSummary.RunSplit
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                Text("R" + String(run.number))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ovFg2)
                Text(SummaryFormat.pace(run.paceSecondsPerKm))
                    .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state, corner: 8)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        let pace: String = SummaryFormat.pace(run.paceSecondsPerKm)
        return "Run " + String(run.number) + ", " + pace + " per kilometre"
    }
}

/// Pace dots: one column per run, faster = higher, previous attempt as hollow dots.
struct PaceChartView: View {
    let runs: [WorkoutSummary.RunSplit]
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    var body: some View {
        GeometryReader { (geo: GeometryProxy) in
            chart(width: geo.size.width)
        }
        .frame(height: 118)
    }

    private func chart(width: CGFloat) -> some View {
        let drawing: PaceDrawing = PaceDrawing(runs: runs, selection: selection)
        return Canvas { (context: inout GraphicsContext, size: CGSize) in
            drawing.draw(&context, size)
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { (value: SpatialTapGesture.Value) in
            tap(x: value.location.x, width: width)
        })
        .accessibilityHidden(true)
    }

    private func tap(x: CGFloat, width: CGFloat) {
        if runs.isEmpty || width <= 0 { return }
        let column: CGFloat = width / CGFloat(runs.count)
        var i: Int = Int((x / column).rounded(.down))
        i = Swift.min(Swift.max(i, 0), runs.count - 1)
        let index: Int = runs[i].segmentIndex
        onSelect(index, index)
    }
}

struct PaceDrawing {
    let runs: [WorkoutSummary.RunSplit]
    let selection: ClosedRange<Int>?

    let top: CGFloat = 14
    let bottom: CGFloat = 104

    func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        if runs.isEmpty { return }
        var values: [Double] = []
        for r in runs {
            if let p = r.paceSecondsPerKm { values.append(p) }
            if let p = r.previousPaceSecondsPerKm { values.append(p) }
        }
        guard let lowest = values.min(), let highest = values.max() else {
            label(&context, "No pace measured", CGPoint(x: size.width / 2, y: 50), UnitPoint.center)
            return
        }
        let lo: Double = lowest - 6
        let hi: Double = highest + 6
        let column: CGFloat = size.width / CGFloat(runs.count)
        drawSelection(&context, column)
        drawReference(&context, size.width, lo, hi)
        drawPrevious(&context, column, lo, hi)
        drawLine(&context, column, lo, hi)
        drawDots(&context, column, lo, hi)
        label(&context, "slower \u{2193}", CGPoint(x: size.width, y: bottom + 6), UnitPoint.topTrailing)
    }

    private func yOf(_ v: Double, _ lo: Double, _ hi: Double) -> CGFloat {
        return top + CGFloat((v - lo) / (hi - lo)) * (bottom - top)
    }

    private func xOf(_ i: Int, _ column: CGFloat) -> CGFloat {
        return column * (CGFloat(i) + 0.5)
    }

    private func label(_ context: inout GraphicsContext, _ string: String, _ point: CGPoint, _ anchor: UnitPoint) {
        let t: Text = Text(string).font(.system(size: 10)).foregroundColor(Theme.ovFg2)
        context.draw(t, at: point, anchor: anchor)
    }

    private func drawSelection(_ context: inout GraphicsContext, _ column: CGFloat) {
        guard let sel = selection, sel.lowerBound == sel.upperBound else { return }
        for (i, r) in runs.enumerated() where r.segmentIndex == sel.lowerBound {
            let rect: CGRect = CGRect(x: column * CGFloat(i) + 1, y: 0, width: column - 2, height: 112)
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(Theme.tileBackground))
        }
    }

    private func drawReference(_ context: inout GraphicsContext, _ width: CGFloat, _ lo: Double, _ hi: Double) {
        var firstPace: Double? = nil
        for r in runs {
            if let p = r.paceSecondsPerKm {
                firstPace = p
                break
            }
        }
        guard let p = firstPace else { return }
        let y: CGFloat = yOf(p, lo, hi)
        var line: Path = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: width, y: y))
        context.stroke(line, with: .color(Theme.ovFg3), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        label(&context, "run 1 pace", CGPoint(x: 2, y: y - 4), UnitPoint.bottomLeading)
    }

    private func drawPrevious(_ context: inout GraphicsContext, _ column: CGFloat, _ lo: Double, _ hi: Double) {
        for (i, r) in runs.enumerated() {
            guard let p = r.previousPaceSecondsPerKm else { continue }
            let c: CGPoint = CGPoint(x: xOf(i, column), y: yOf(p, lo, hi))
            let rect: CGRect = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
            context.fill(Path(ellipseIn: rect), with: .color(Theme.cardBackground))
            context.stroke(Path(ellipseIn: rect), with: .color(Theme.ovFg3), lineWidth: 1.5)
        }
    }

    private func drawLine(_ context: inout GraphicsContext, _ column: CGFloat, _ lo: Double, _ hi: Double) {
        var path: Path = Path()
        var penDown: Bool = false
        for (i, r) in runs.enumerated() {
            guard let p = r.paceSecondsPerKm else {
                penDown = false
                continue
            }
            let pt: CGPoint = CGPoint(x: xOf(i, column), y: yOf(p, lo, hi))
            if penDown {
                path.addLine(to: pt)
            } else {
                path.move(to: pt)
                penDown = true
            }
        }
        context.stroke(path, with: .color(Theme.ovRun), lineWidth: 2)
    }

    private func drawDots(_ context: inout GraphicsContext, _ column: CGFloat, _ lo: Double, _ hi: Double) {
        for (i, r) in runs.enumerated() {
            guard let p = r.paceSecondsPerKm else { continue }
            let c: CGPoint = CGPoint(x: xOf(i, column), y: yOf(p, lo, hi))
            let outer: CGRect = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
            let inner: CGRect = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
            context.fill(Path(ellipseIn: outer), with: .color(Theme.cardBackground))
            context.fill(Path(ellipseIn: inner), with: .color(Theme.ovRun))
        }
    }
}

// MARK: - Stations

struct StationsSection: View {
    let data: WorkoutSummary.RunsAndStations
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    private var caption: String {
        if data.hasPrevious {
            return "Own scale (not comparable with runs). Black tick: last attempt."
        }
        return "Own scale (not comparable with runs)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            OvSectionHeader(title: "Stations", caption: caption)
                .padding(.bottom, 4)
            ForEach(data.stations) { (station: WorkoutSummary.StationSplit) in
                StationRow(station: station, scaleMax: data.stationScaleMax,
                           state: OverviewSel.state(selection, station.segmentIndex, station.segmentIndex),
                           onTap: { onSelect(station.segmentIndex, station.segmentIndex) })
            }
            gainLoss
        }
    }

    private func station(at index: Int?) -> WorkoutSummary.StationSplit? {
        guard let i = index, i >= 0, i < data.stations.count else { return nil }
        return data.stations[i]
    }

    @ViewBuilder
    private var gainLoss: some View {
        let gain: WorkoutSummary.StationSplit? = station(at: data.biggestGain)
        let loss: WorkoutSummary.StationSplit? = station(at: data.biggestLoss)
        if gain != nil || loss != nil {
            Text(gainLossText(gain, loss))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private func gainLossText(_ gain: WorkoutSummary.StationSplit?, _ loss: WorkoutSummary.StationSplit?) -> String {
        var parts: [String] = []
        if let g = gain, let d = g.deltaSeconds {
            parts.append("Biggest gain: " + g.name + " " + SummaryFormat.signed(d))
        }
        if let l = loss, let d = l.deltaSeconds {
            parts.append("Biggest loss: " + l.name + " " + SummaryFormat.signed(d))
        }
        return parts.joined(separator: " \u{00B7} ")
    }
}

struct StationRow: View {
    let station: WorkoutSummary.StationSplit
    let scaleMax: Double
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(station.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(hrText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ovFg2)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                track
                    .frame(maxWidth: .infinity)
                Text(SummaryFormat.clock(station.duration))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
                Text(deltaText)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(OverviewFormat.deltaColor(station.deltaSeconds))
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state)
    }

    private var hrText: String {
        var text: String = "HR " + SummaryFormat.bpm(station.heartRateAvg) + " / " + SummaryFormat.bpm(station.heartRateMax)
        if station.hasGap { text += " \u{00B7} gap" }
        return text
    }

    private var deltaText: String {
        guard let d = station.deltaSeconds else { return "" }
        return SummaryFormat.signed(d)
    }

    private var track: some View {
        let scale: Double = Swift.max(1, scaleMax)
        let fill: CGFloat = CGFloat(Swift.min(1.0, station.duration / scale))
        let tick: CGFloat? = station.previousDuration.map({ (p: Double) -> CGFloat in
            return CGFloat(Swift.min(1.0, p / scale))
        })
        return GeometryReader { (geo: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tileBackground)
                Capsule()
                    .fill(Theme.ovStation)
                    .frame(width: geo.size.width * fill)
                if let t = tick {
                    Rectangle()
                        .fill(Theme.ovFg)
                        .frame(width: 2, height: 16)
                        .offset(x: Swift.max(0, geo.size.width * t - 1))
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 10)
    }
}
