import SwiftUI
import BarPathKit

/// All splits in race order, folded by default. Rows select like everything else.
struct SplitsTableCard: View {
    let rows: [WorkoutSummary.SplitRow]
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            toggleButton
            if expanded {
                tableBody
            } else {
                Text("Race order, with cumulative time and HR per split.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ovFg2)
            }
        }
        .card()
    }

    private var toggleButton: some View {
        Button(action: toggle) {
            HStack {
                Text("Splits")
                    .font(.headline)
                Spacer()
                Text(expanded ? "Hide" : "Show all " + String(rows.count))
                    .font(.subheadline)
                    .foregroundStyle(Theme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Hides the split table" : "Shows the split table")
    }

    private func toggle() {
        expanded.toggle()
    }

    private var tableBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            SplitHeaderRow()
            ForEach(rows) { (row: WorkoutSummary.SplitRow) in
                SplitRowView(row: row,
                             striped: row.number % 2 == 1,
                             state: OverviewSel.state(selection, row.segmentIndex, row.segmentIndex),
                             onTap: { onSelect(row.segmentIndex, row.segmentIndex) })
            }
        }
    }
}

struct SplitHeaderRow: View {
    var body: some View {
        HStack(spacing: 5) {
            Text("#")
                .frame(width: 20, alignment: .leading)
            Text("SEGMENT")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("TIME")
                .frame(width: 40, alignment: .trailing)
            Text("TOTAL")
                .frame(width: 50, alignment: .trailing)
            Text("HR")
                .frame(width: 54, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .bold))
        .tracking(0.4)
        .foregroundStyle(Theme.ovFg2)
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }
}

struct SplitRowView: View {
    let row: WorkoutSummary.SplitRow
    let striped: Bool
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(String(row.number))
                    .foregroundStyle(Theme.ovFg3)
                    .monospacedDigit()
                    .frame(width: 20, alignment: .leading)
                nameCell
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SummaryFormat.clock(row.duration))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Text(SummaryFormat.clock(row.end))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ovFg3)
                    .frame(width: 50, alignment: .trailing)
                Text(SummaryFormat.bpm(row.heartRateAvg) + "/" + SummaryFormat.bpm(row.heartRateMax))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: 54, alignment: .trailing)
            }
            .font(.system(size: 13))
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(striped ? Theme.tileBackground.opacity(0.55) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state, corner: 8)
    }

    private var nameCell: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Theme.ovSolid(row.kind))
                .frame(width: 4, height: 14)
            Text(row.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
