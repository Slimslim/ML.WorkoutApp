import SwiftUI
import BarPathKit

/// The format-specific part of the overview. Switches on `summary.story`.
struct StoryCard: View {
    let summary: WorkoutSummary
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            storyBody
        }
        .card()
    }

    @ViewBuilder
    private var storyBody: some View {
        switch summary.story {
        case .runsAndStations(let data):
            RaceStoryView(data: data, summary: summary, selection: selection, onSelect: onSelect)
        case .roundGrid(let data):
            RoundGridView(data: data, summary: summary, selection: selection, onSelect: onSelect)
        case .intervalSlots(let data):
            IntervalSlotsView(data: data, selection: selection, onSelect: onSelect)
        case .amrapClock(let data):
            AmrapClockView(data: data, selection: selection, onSelect: onSelect)
        case .segments(let bars):
            SegmentsFallbackView(bars: bars, selection: selection, onSelect: onSelect)
        }
    }
}

/// Anything else: one bar per segment on its own scale (longest = full width).
struct SegmentsFallbackView: View {
    let bars: [WorkoutSummary.SegmentBar]
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OvSectionHeader(title: "Segments",
                            caption: "Each bar is one segment; the longest fills the width.")
            if bars.isEmpty {
                Text("No segments were recorded.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
            }
            ForEach(bars) { (bar: WorkoutSummary.SegmentBar) in
                SegmentBarRow(bar: bar,
                              state: OverviewSel.state(selection, bar.segmentIndex, bar.segmentIndex),
                              onTap: { onSelect(bar.segmentIndex, bar.segmentIndex) })
            }
        }
    }
}

struct SegmentBarRow: View {
    let bar: WorkoutSummary.SegmentBar
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(bar.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(hrText)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ovFg2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                track
                    .frame(maxWidth: .infinity)
                Text(SummaryFormat.clock(bar.duration))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
                Text(deltaText)
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(OverviewFormat.deltaColor(bar.deltaSeconds))
                    .frame(width: 46, alignment: .trailing)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state)
    }

    private var hrText: String {
        var text: String = "HR " + SummaryFormat.bpm(bar.heartRateAvg) + " / " + SummaryFormat.bpm(bar.heartRateMax)
        if bar.paceSecondsPerKm != nil {
            text += " \u{00B7} " + SummaryFormat.pace(bar.paceSecondsPerKm) + "/km"
        }
        return text
    }

    private var deltaText: String {
        guard let d = bar.deltaSeconds else { return "" }
        return SummaryFormat.signed(d)
    }

    private var track: some View {
        GeometryReader { (geo: GeometryProxy) in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tileBackground)
                Capsule()
                    .fill(Theme.ovSolid(bar.kind))
                    .frame(width: geo.size.width * CGFloat(Swift.min(1.0, Swift.max(0.02, bar.fraction))))
            }
        }
        .frame(height: 10)
    }
}
