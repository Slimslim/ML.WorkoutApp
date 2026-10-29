import SwiftUI
import BarPathKit

/// AMRAP: each round is a bar placed where it happened on the cap clock, split into its
/// movements; the unfinished round is drawn short with a dashed end.
struct AmrapClockView: View {
    let data: WorkoutSummary.AmrapClock
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    private var movementOrder: [String] {
        var order: [String] = []
        for m in data.movements { order.append(m.movement) }
        return order
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            roundsSection
            OvSectionDivider()
            statsSection
        }
    }

    // MARK: Rounds on the clock

    private var roundsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            OvSectionHeader(title: "Rounds on the " + SummaryFormat.clock(data.capSeconds) + " clock",
                            caption: "Each bar sits where that round happened. The last round is cut by the cap.")
                .padding(.bottom, 4)
            ForEach(data.rounds) { (round: WorkoutSummary.AmrapRound) in
                ClockRoundRow(round: round, capSeconds: data.capSeconds, movementOrder: movementOrder,
                              state: OverviewSel.state(selection, round.firstSegmentIndex, round.lastSegmentIndex),
                              onTap: { onSelect(round.firstSegmentIndex, round.lastSegmentIndex) })
            }
            ClockAxisRow(capSeconds: data.capSeconds)
            legend
        }
    }

    private var legend: some View {
        FlowLayout(hSpacing: 12, vSpacing: 4) {
            ForEach(0..<data.movements.count, id: \.self) { (i: Int) in
                OvLegendItem(color: Theme.ovPartColor(i), text: data.movements[i].name)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    // MARK: Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OvStatTile(key: "Round drift", value: driftValue, detail: driftDetail, valueColor: driftColor)
                OvStatTile(key: "Avg round", value: SummaryFormat.clock(data.averageRoundSeconds),
                           detail: String(data.completedRounds) + " full rounds")
                OvStatTile(key: "Slowed most", value: data.slowedMostName ?? SummaryFormat.missing,
                           detail: slowedDetail)
            }
            if let text = data.driftText {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ovFg2)
            }
            Text(movementLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var driftValue: String {
        guard let p = data.driftPercent else { return SummaryFormat.missing }
        return SummaryFormat.signedPercent(p)
    }

    private var driftDetail: String {
        guard let s = data.driftSeconds else { return "needs 2 full rounds" }
        return "last vs first round (" + SummaryFormat.signed(s) + ")"
    }

    private var driftColor: Color {
        guard let p = data.driftPercent else { return Theme.ovFg }
        return p > 0 ? Theme.ovSlow : Theme.ovFast
    }

    private var slowedDetail: String {
        guard let s = data.slowedMostSeconds else { return "" }
        return SummaryFormat.signed(s) + " first to last round"
    }

    private var movementLine: String {
        var parts: [String] = []
        for m in data.movements {
            parts.append(m.name + " \u{00D7}" + String(m.count) + ": avg " + SummaryFormat.clock(m.averageSeconds)
                         + ", best " + SummaryFormat.clock(m.bestSeconds))
        }
        var text: String = parts.joined(separator: " \u{00B7} ")
        if let stop = data.stoppedIn {
            text += ". Reps inside the unfinished " + stop.name + " are not counted."
        }
        return text
    }
}

// MARK: - Row

struct ClockRoundRow: View {
    let round: WorkoutSummary.AmrapRound
    let capSeconds: Double
    let movementOrder: [String]
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text("R" + String(round.number))
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 30, alignment: .leading)
                ClockBarCanvas(round: round, capSeconds: capSeconds, movementOrder: movementOrder)
                    .frame(height: 20)
                    .frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(SummaryFormat.clock(round.duration))
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text(subline)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ovFg2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 74, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state)
    }

    private var subline: String {
        if !round.isComplete {
            return String(round.completedParts) + " of " + String(round.totalParts) + " done"
        }
        return "avg " + SummaryFormat.bpm(round.heartRateAvg) + " bpm"
    }
}

struct ClockBarCanvas: View {
    let round: WorkoutSummary.AmrapRound
    let capSeconds: Double
    let movementOrder: [String]

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            draw(&context, size)
        }
        .accessibilityHidden(true)
    }

    private func xOf(_ t: Double, _ width: CGFloat) -> CGFloat {
        if capSeconds <= 0 { return 0 }
        return CGFloat(t / capSeconds) * width
    }

    private func colorIndex(_ part: WorkoutSummary.RoundPart) -> Int {
        if let i = movementOrder.firstIndex(of: part.movement) { return i }
        return part.column
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        drawGrid(&context, size)
        for part in round.parts {
            let rect: CGRect = CGRect(x: xOf(part.start, size.width) + 0.5, y: 2,
                                      width: Swift.max(1, xOf(part.duration, size.width) - 1),
                                      height: size.height - 4)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.ovPartColor(colorIndex(part))))
            if part.isPartial {
                let outline: CGRect = CGRect(x: rect.minX, y: 1, width: rect.width, height: size.height - 2)
                context.stroke(Path(roundedRect: outline, cornerRadius: 2), with: .color(Theme.ovFg2),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
        }
        var end: Path = Path()
        end.move(to: CGPoint(x: size.width - 0.75, y: 0))
        end.addLine(to: CGPoint(x: size.width - 0.75, y: size.height))
        context.stroke(end, with: .color(Theme.ovFg2), lineWidth: 1.5)
    }

    private func drawGrid(_ context: inout GraphicsContext, _ size: CGSize) {
        let step: Double = ClockAxisRow.step(for: capSeconds)
        var t: Double = step
        while t < capSeconds - 1 {
            let x: CGFloat = xOf(t, size.width)
            var line: Path = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(Theme.ovGrid), lineWidth: 1)
            t += step
        }
    }
}

/// Time labels under the round bars, aligned with them.
struct ClockAxisRow: View {
    let capSeconds: Double

    static func step(for cap: Double) -> Double {
        if cap > 1500 { return 600 }
        if cap > 600 { return 300 }
        return 120
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 30, height: 1)
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                draw(&context, size)
            }
            .frame(height: 16)
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: 74, height: 1)
        }
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        if capSeconds <= 0 { return }
        let step: Double = ClockAxisRow.step(for: capSeconds)
        var ticks: [Double] = []
        var t: Double = 0
        while t < capSeconds - 1 {
            ticks.append(t)
            t += step
        }
        ticks.append(capSeconds)
        for (i, tick) in ticks.enumerated() {
            let x: CGFloat = CGFloat(tick / capSeconds) * size.width
            var anchor: UnitPoint = UnitPoint.top
            if i == 0 {
                anchor = UnitPoint.topLeading
            } else if i == ticks.count - 1 {
                anchor = UnitPoint.topTrailing
            }
            let label: Text = Text(SummaryFormat.clock(tick)).font(.system(size: 10)).foregroundColor(Theme.ovFg2)
            context.draw(label, at: CGPoint(x: x, y: 2), anchor: anchor)
        }
    }
}
