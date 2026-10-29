import SwiftUI
import BarPathKit

/// "Heart rate through the workout": segment bands, HR line (broken at gaps), zone strip,
/// time axis, tap / drag scrubbing, a detail chip and the honesty notes.
struct HeartRateTimelineCard: View {
    let summary: WorkoutSummary
    @Binding var selection: ClosedRange<Int>?
    @Binding var hoverTime: Double?

    private var timeline: WorkoutSummary.Timeline {
        return summary.timeline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            OvSectionHeader(title: "Heart rate through the workout",
                            caption: "Tap or drag sideways across the chart. Bands are your segments.")
            TimelineChartView(timeline: timeline, selection: selection, hoverTime: hoverTime,
                              onTouch: touch, onStep: step)
            TimelineLegend(timeline: timeline)
            TimelineChip(summary: summary, selection: selection, hoverTime: hoverTime, onClear: clear)
            notes
        }
        .card()
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            if timeline.isEstimated && timeline.hasHeartRate {
                Text("Detailed heart rate not recorded for this workout. Lines show each split's average.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ovFg2)
            }
            if !timeline.hasHeartRate {
                Text("No heart rate was recorded for this workout.")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ovFg2)
            }
            Text("Wrist heart rate can lag or read low during stations (sleds, wall balls, pull-ups). Hatched = no reading.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ovFg3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    /// Finger at time t: select the segment under it and remember the moment.
    private func touch(_ t: Double) {
        hoverTime = t
        guard let index = timeline.segment(at: t) else { return }
        let range: ClosedRange<Int> = index...index
        if let current = selection, current == range { return }
        selection = range
    }

    private func clear() {
        hoverTime = nil
        selection = nil
    }

    /// VoiceOver adjust: previous / next segment.
    private func step(_ delta: Int) {
        let bands: [WorkoutSummary.Band] = timeline.bands
        if bands.isEmpty { return }
        var current: Int = -1
        if let s = selection {
            let anchor: Int = delta > 0 ? s.upperBound : s.lowerBound
            for (i, b) in bands.enumerated() where b.segmentIndex == anchor {
                current = i
            }
        }
        var target: Int = current + delta
        if current < 0 { target = 0 }
        let n: Int = bands.count
        target = ((target % n) + n) % n
        let index: Int = bands[target].segmentIndex
        hoverTime = nil
        selection = index...index
    }
}

// MARK: - Legend

struct TimelineLegend: View {
    let timeline: WorkoutSummary.Timeline

    private var hasRest: Bool {
        for b in timeline.bands where b.kind == .rest { return true }
        return false
    }

    private var zoneText: String {
        let maxText: String = String(Int(timeline.maxHeartRate.rounded()))
        let suffix: String = timeline.zonesEstimated ? ", estimated" : ""
        return "Zones 1\u{2013}5 (max HR " + maxText + suffix + ")"
    }

    var body: some View {
        FlowLayout(hSpacing: 12, vSpacing: 4) {
            OvLegendItem(color: Theme.ovRun, text: "Run")
            OvLegendItem(color: Theme.ovStation, text: "Station")
            if hasRest {
                OvLegendItem(color: Theme.ovRestBand, text: "Rest", outlined: true)
            }
            zoneKey
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var zoneKey: some View {
        HStack(spacing: 4) {
            HStack(spacing: 1) {
                ForEach(1..<6, id: \.self) { (z: Int) in
                    Rectangle()
                        .fill(Theme.ovZone(z))
                        .frame(width: 8, height: 10)
                }
            }
            Text(zoneText)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ovFg2)
        }
        .fixedSize()
    }
}

// MARK: - Chip

/// Numbers for the chip, precomputed from the summary (no statistics of its own: segment
/// numbers come from `Timeline.stats` and `SplitRow`).
struct OverviewChip {
    var title: String
    var swatch: Color
    var duration: String
    var range: String
    var avg: String
    var max: String
    var pace: String?
    var delta: String?
    var deltaSeconds: Double?
    var gap: String?
    var moment: String?

    static func make(summary: WorkoutSummary, selection: ClosedRange<Int>, hover: Double?) -> OverviewChip? {
        let timeline: WorkoutSummary.Timeline = summary.timeline
        guard let first = timeline.band(segmentIndex: selection.lowerBound),
              let last = timeline.band(segmentIndex: selection.upperBound) else { return nil }
        let stats: WorkoutSummary.RangeStats = timeline.stats(from: first.start, to: last.end)
        let single: Bool = selection.lowerBound == selection.upperBound
        var chip: OverviewChip = OverviewChip(
            title: single ? first.title : OverviewChip.rangeTitle(summary: summary, selection: selection),
            swatch: single ? Theme.ovSolid(first.kind) : Theme.ovFg,
            duration: SummaryFormat.clock(last.end - first.start),
            range: SummaryFormat.clock(first.start) + "\u{2013}" + SummaryFormat.clock(last.end),
            avg: SummaryFormat.bpm(stats.average),
            max: SummaryFormat.bpm(stats.max),
            pace: nil, delta: nil, deltaSeconds: nil, gap: nil, moment: nil)
        if single {
            if first.paceSecondsPerKm != nil {
                chip.pace = SummaryFormat.pace(first.paceSecondsPerKm)
            }
            for row in summary.rows where row.segmentIndex == first.segmentIndex {
                if let d = row.deltaSeconds {
                    chip.delta = SummaryFormat.signed(d) + " vs last"
                    chip.deltaSeconds = d
                }
            }
        }
        if stats.gapSeconds > 0 && !timeline.isEstimated {
            chip.gap = "HR missing for " + SummaryFormat.clock(stats.gapSeconds)
        }
        if let t = hover, t >= first.start, t < last.end {
            chip.moment = momentText(timeline: timeline, t: t)
        }
        return chip
    }

    static func momentText(timeline: WorkoutSummary.Timeline, t: Double) -> String {
        let at: String = SummaryFormat.clock(t)
        if let hr = timeline.heartRate(at: t) {
            return "at " + at + ": " + SummaryFormat.bpm(hr) + " bpm \u{00B7} zone " + String(timeline.zone(for: hr))
        }
        return "at " + at + ": no HR reading"
    }

    /// "Round 2", "Set 3" for a whole round / set; else the split numbers.
    static func rangeTitle(summary: WorkoutSummary, selection: ClosedRange<Int>) -> String {
        let lo: Int = selection.lowerBound
        let hi: Int = selection.upperBound
        switch summary.story {
        case .roundGrid(let grid):
            for r in grid.rounds where r.firstSegmentIndex == lo {
                return "Round " + String(r.number)
            }
        case .intervalSlots(let slots):
            for s in slots.sets where s.firstSegmentIndex == lo {
                return "Set " + String(s.number)
            }
        case .amrapClock(let clock):
            for r in clock.rounds where r.firstSegmentIndex == lo {
                return "Round " + String(r.number)
            }
        default:
            break
        }
        return "Splits " + String(lo + 1) + "\u{2013}" + String(hi + 1)
    }
}

struct TimelineChip: View {
    let summary: WorkoutSummary
    let selection: ClosedRange<Int>?
    let hoverTime: Double?
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sel = selection, let chip = OverviewChip.make(summary: summary, selection: sel, hover: hoverTime) {
                selectedContent(chip)
            } else {
                idleContent
            }
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.tileBackground)
        )
        .accessibilityElement(children: .contain)
    }

    private var idleContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing selected")
                .font(.subheadline.weight(.bold))
            Text("Tap a band, a run, a cell, a set or a split row.")
                .font(.footnote)
                .foregroundStyle(Theme.ovFg2)
            if let t = hoverTime {
                Text(OverviewChip.momentText(timeline: summary.timeline, t: t))
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
            }
        }
    }

    private func selectedContent(_ chip: OverviewChip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(chip.swatch)
                    .frame(width: 10, height: 10)
                Text(chip.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClear) {
                    Text("Clear")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
            }
            factsFlow(chip)
        }
    }

    private func factsFlow(_ chip: OverviewChip) -> some View {
        FlowLayout(hSpacing: 14, vSpacing: 2) {
            OvFact(label: "", value: chip.duration)
            Text(chip.range)
                .font(.footnote)
                .foregroundStyle(Theme.ovFg2)
                .fixedSize()
            OvFact(label: "avg", value: chip.avg)
            OvFact(label: "max", value: chip.max, unit: "bpm")
            if let p = chip.pace {
                OvFact(label: "pace", value: p, unit: "/km")
            }
            if let d = chip.delta {
                Text(d)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(OverviewFormat.deltaColor(chip.deltaSeconds))
                    .fixedSize()
            }
            if let g = chip.gap {
                Text(g)
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
                    .fixedSize()
            }
            if let m = chip.moment {
                Text(m)
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
