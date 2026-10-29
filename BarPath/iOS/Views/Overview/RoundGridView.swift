import SwiftUI
import BarPathKit

/// Rounds for time: rounds x movements grid (tinted against each movement's own average),
/// round totals with fastest / slowest, and the drift tiles.
struct RoundGridView: View {
    let data: WorkoutSummary.RoundGrid
    let summary: WorkoutSummary
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            gridSection
            OvSectionDivider()
            statsSection
        }
    }

    // MARK: Grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            OvSectionHeader(title: "Rounds \u{00D7} movements",
                            caption: "Each cell: time, change vs that movement's average, avg HR. Tap a cell or a round.")
                .padding(.bottom, 4)
            headerRow
            ForEach(data.rounds) { (round: WorkoutSummary.GridRound) in
                GridRoundRow(round: round, columnCount: data.columns.count,
                             selection: selection, onSelect: onSelect)
            }
            tintKey
        }
    }

    private var headerRow: some View {
        HStack(spacing: 3) {
            Color.clear.frame(width: 30, height: 1)
            ForEach(data.columns) { (column: WorkoutSummary.GridColumn) in
                Text(column.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ovFg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
            }
            Text("Round")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ovFg2)
                .frame(maxWidth: .infinity)
        }
    }

    private var tintKey: some View {
        HStack(spacing: 6) {
            Text("faster")
            Capsule()
                .fill(LinearGradient(colors: [Theme.ovFast, Theme.tileBackground, Theme.ovSlow],
                                     startPoint: UnitPoint.leading, endPoint: UnitPoint.trailing))
                .frame(width: 90, height: 8)
            Text("slower than that movement's average")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.ovFg2)
        .padding(.top, 6)
    }

    // MARK: Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OvStatTile(key: "Drift", value: driftValue, detail: driftDetail, valueColor: driftColor)
                OvStatTile(key: "Slowed most", value: slowedName, detail: slowedDetail)
                OvStatTile(key: "Run pace", value: paceValue, detail: paceDetail)
            }
            if let text = data.driftText {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ovFg2)
            }
            footnote
        }
    }

    private var driftValue: String {
        guard let p = data.driftPercent else { return SummaryFormat.missing }
        return SummaryFormat.signedPercent(p)
    }

    private var driftDetail: String {
        guard let s = data.driftSeconds else { return "needs 2 complete rounds" }
        return "last vs first round (" + SummaryFormat.signed(s) + ")"
    }

    private var driftColor: Color {
        guard let p = data.driftPercent else { return Theme.ovFg }
        return p > 0 ? Theme.ovSlow : Theme.ovFast
    }

    private var slowedColumn: WorkoutSummary.GridColumn? {
        guard let c = data.slowedMostColumn else { return nil }
        for column in data.columns where column.index == c { return column }
        return nil
    }

    private var slowedName: String {
        guard let column = slowedColumn else { return SummaryFormat.missing }
        return column.name
    }

    private var slowedDetail: String {
        guard slowedColumn != nil, let s = data.slowedMostSeconds else { return "" }
        return SummaryFormat.signed(s) + " first to last round"
    }

    private var paceValue: String {
        return SummaryFormat.pace(data.runPaceAverage)
    }

    private var paceDetail: String {
        if data.runPaceAverage == nil { return "no runs" }
        return "avg /km \u{00B7} " + SummaryFormat.pace(data.runPaceBest) + " best"
    }

    @ViewBuilder
    private var footnote: some View {
        let previous: String = previousText
        let pullUps: Bool = data.columns.contains(where: { (c: WorkoutSummary.GridColumn) -> Bool in
            c.movement == "pullUps"
        })
        if !previous.isEmpty || pullUps {
            Text(previous + (pullUps ? " Wrist HR on pull-ups often reads low: hands overhead, wrist flexed." : ""))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var previousText: String {
        guard summary.hasPrevious, let total = summary.headline.previousTotalSeconds else { return "" }
        var text: String = "Previous attempt"
        if let d = summary.previousDate { text += " (" + OverviewFormat.shortDate(d) + ")" }
        return text + ": " + SummaryFormat.clock(total) + "."
    }
}

// MARK: - One round row

struct GridRoundRow: View {
    let round: WorkoutSummary.GridRound
    let columnCount: Int
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    private var roundState: SelState {
        return OverviewSel.state(selection, round.firstSegmentIndex, round.lastSegmentIndex)
    }

    private func selectRound() {
        onSelect(round.firstSegmentIndex, round.lastSegmentIndex)
    }

    var body: some View {
        HStack(spacing: 3) {
            roundLabel
            ForEach(round.cells) { (cell: WorkoutSummary.GridCell) in
                GridCellView(cell: cell,
                             state: OverviewSel.state(selection, cell.segmentIndex, cell.segmentIndex),
                             onTap: { onSelect(cell.segmentIndex, cell.segmentIndex) })
            }
            ForEach(0..<Swift.max(0, columnCount - round.cells.count), id: \.self) { (_: Int) in
                Color.clear.frame(maxWidth: .infinity, minHeight: 1)
            }
            totalCell
        }
    }

    private var roundLabel: some View {
        Button(action: selectRound) {
            Text("R" + String(round.number))
                .font(.system(size: 13, weight: .heavy))
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(roundState)
    }

    private var totalCell: some View {
        Button(action: selectRound) {
            VStack(spacing: 1) {
                Text(SummaryFormat.clock(round.duration))
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                totalTag
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.ovGrid, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(roundState)
    }

    @ViewBuilder
    private var totalTag: some View {
        if round.isFastest {
            RoundTag(text: "fastest", color: Theme.ovFast)
        } else if round.isSlowest {
            RoundTag(text: "slowest", color: Theme.ovSlow)
        } else if let d = round.deltaFromFastestSeconds {
            Text(SummaryFormat.signed(d))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(Theme.ovFg2)
        } else {
            Text("unfinished")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ovFg2)
        }
    }
}

struct RoundTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(color, lineWidth: 1)
            )
    }
}

// MARK: - One cell

struct GridCellView: View {
    let cell: WorkoutSummary.GridCell
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                Text(SummaryFormat.clock(cell.duration))
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                deviationLine
                Text(SummaryFormat.bpm(cell.heartRateAvg) + " bpm")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ovFg2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.top, 7)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .background(CellTintBackground(tint: cell.tint, hasDeviation: cell.deviationSeconds != nil))
            .overlay(partialOutline)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state)
    }

    @ViewBuilder
    private var deviationLine: some View {
        if let d = cell.deviationSeconds {
            Text(SummaryFormat.signed(d))
                .font(.system(size: 10.5, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(OverviewFormat.deltaColor(d))
        } else {
            Text(cell.isPartial ? "cut off" : " ")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ovFg2)
        }
    }

    private var partialOutline: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(cell.isPartial ? Theme.ovFg2 : Color.clear,
                          style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
    }
}

/// Teal (fast) to plum (slow) tint over the tile colour: 6 % to 40 % by |tint|.
struct CellTintBackground: View {
    let tint: Double
    let hasDeviation: Bool

    private var tone: Color {
        return tint <= 0 ? Theme.ovFast : Theme.ovSlow
    }

    private var strength: Double {
        let t: Double = Swift.min(1.0, Swift.abs(tint))
        return 0.06 + t * 0.34
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.tileBackground)
            if hasDeviation {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tone.opacity(strength))
            }
        }
    }
}
