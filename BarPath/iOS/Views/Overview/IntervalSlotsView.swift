import SwiftUI
import BarPathKit

/// Every N:00: one row per set, drawn as the full fixed slot. Work parts fill the left,
/// rest is the remainder; start -> peak HR and the drop in the rest on the right.
struct IntervalSlotsView: View {
    let data: WorkoutSummary.IntervalSlots
    let selection: ClosedRange<Int>?
    let onSelect: (Int, Int) -> Void

    /// Length of the slot drawn for every set.
    private var slotSeconds: Double {
        if let i = data.intervalSeconds, i > 0 { return i }
        var longest: Double = 1
        for s in data.sets {
            longest = Swift.max(longest, s.workSeconds + (s.restSeconds ?? 0))
        }
        return longest
    }

    /// Axis length: the slot, or longer when a set overran it.
    private var scaleSeconds: Double {
        var scale: Double = slotSeconds
        for s in data.sets { scale = Swift.max(scale, s.workSeconds) }
        return scale
    }

    private var title: String {
        if let i = data.intervalSeconds, i > 0 {
            return "Sets inside the " + SummaryFormat.clock(i) + " clock"
        }
        return "Sets"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            slotsSection
            OvSectionDivider()
            statsSection
        }
    }

    // MARK: Slots

    private var slotsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            OvSectionHeader(title: title,
                            caption: "Each bar is one full slot. Work fills the left, rest is what was left.")
                .padding(.bottom, 4)
            ForEach(data.sets) { (set: WorkoutSummary.IntervalSet) in
                SlotRow(set: set, slotSeconds: slotSeconds, scaleSeconds: scaleSeconds,
                        partOrder: partOrder,
                        state: OverviewSel.state(selection, set.firstSegmentIndex, set.lastSegmentIndex),
                        onTap: { onSelect(set.firstSegmentIndex, set.lastSegmentIndex) })
            }
            SlotAxisRow(slotSeconds: slotSeconds, scaleSeconds: scaleSeconds)
            legend
        }
    }

    /// Movement order of the work parts (colour index).
    private var partOrder: [String] {
        var order: [String] = []
        for stat in data.partAverages { order.append(stat.movement) }
        return order
    }

    private var legend: some View {
        FlowLayout(hSpacing: 12, vSpacing: 4) {
            ForEach(0..<data.partAverages.count, id: \.self) { (i: Int) in
                OvLegendItem(color: Theme.ovPartColor(i), text: data.partAverages[i].name)
            }
            OvLegendItem(color: Theme.ovRestBand, text: "Rest", outlined: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
    }

    // MARK: Stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OvStatTile(key: "Work drift", value: driftValue, detail: "last set vs first",
                           valueColor: driftColor)
                OvStatTile(key: "Start HR", value: startHRValue, detail: "first set \u{2192} last")
                OvStatTile(key: "Recovery", value: recoveryValue, detail: "bpm drop in rest, first \u{2192} last")
            }
            Text(footnote)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var driftValue: String {
        guard let d = data.workDriftSeconds else { return SummaryFormat.missing }
        return SummaryFormat.signed(d)
    }

    private var driftColor: Color {
        guard let d = data.workDriftSeconds else { return Theme.ovFg }
        return d > 0 ? Theme.ovSlow : Theme.ovFast
    }

    private var startHRValue: String {
        return SummaryFormat.bpm(data.firstStartHeartRate) + "\u{2192}" + SummaryFormat.bpm(data.lastStartHeartRate)
    }

    private var recoveryValue: String {
        guard let a = data.firstRecoveryDrop, let b = data.lastRecoveryDrop else { return SummaryFormat.missing }
        return SummaryFormat.signedNumber(-a) + "\u{2192}" + SummaryFormat.signedNumber(-b)
    }

    private var footnote: String {
        var parts: [String] = []
        if let f = data.firstRestSeconds, let l = data.lastRestSeconds {
            parts.append("Rest went from " + SummaryFormat.clock(f) + " to " + SummaryFormat.clock(l) + ".")
        }
        if let t = data.startHeartRateText { parts.append(t) }
        var averages: [String] = []
        for stat in data.partAverages {
            averages.append(stat.name + " avg " + SummaryFormat.clock(stat.averageSeconds))
        }
        if !averages.isEmpty { parts.append(averages.joined(separator: " \u{00B7} ") + ".") }
        parts.append("Start HR rising set after set means you are not fully recovering.")
        return parts.joined(separator: " ")
    }
}

// MARK: - Row

struct SlotRow: View {
    let set: WorkoutSummary.IntervalSet
    let slotSeconds: Double
    let scaleSeconds: Double
    let partOrder: [String]
    let state: SelState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text("S" + String(set.number))
                    .font(.system(size: 13, weight: .heavy))
                    .frame(width: 30, alignment: .leading)
                SlotBarCanvas(set: set, slotSeconds: slotSeconds, scaleSeconds: scaleSeconds,
                              partOrder: partOrder)
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
                numbers
                    .frame(width: 98, alignment: .trailing)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .selectable(state)
    }

    private var hrLine: String {
        var text: String = SummaryFormat.bpm(set.startHeartRate) + " \u{2192} " + SummaryFormat.bpm(set.peakHeartRate)
        if let drop = set.recoveryDrop {
            text += " \u{00B7} " + SummaryFormat.signedNumber(-drop)
        } else {
            text += " \u{00B7} last"
        }
        return text
    }

    private var numbers: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(spacing: 3) {
                Text(SummaryFormat.clock(set.workSeconds))
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text("work")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ovFg2)
            }
            Text(hrLine)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(Theme.ovFg2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if set.overran {
                Text("no rest")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.ovSlow)
            }
        }
    }
}

/// One slot: light rest-coloured track, work parts from the left, rest time in the remainder.
struct SlotBarCanvas: View {
    let set: WorkoutSummary.IntervalSet
    let slotSeconds: Double
    let scaleSeconds: Double
    let partOrder: [String]

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            draw(&context, size)
        }
        .accessibilityHidden(true)
    }

    private func xOf(_ t: Double, _ width: CGFloat) -> CGFloat {
        if scaleSeconds <= 0 { return 0 }
        return CGFloat(t / scaleSeconds) * width
    }

    private func colorIndex(_ part: WorkoutSummary.SetPart) -> Int {
        if let i = partOrder.firstIndex(of: part.movement) { return i }
        return part.column
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let slotWidth: CGFloat = xOf(slotSeconds, size.width)
        let track: CGRect = CGRect(x: 0, y: 0, width: slotWidth, height: size.height)
        context.fill(Path(roundedRect: track, cornerRadius: 5), with: .color(Theme.ovRestBand))
        var workEnd: Double = 0
        for (j, part) in set.parts.enumerated() {
            let x0: CGFloat = xOf(part.offset, size.width) + (j > 0 ? 1 : 0)
            let w: CGFloat = Swift.max(1, xOf(part.duration, size.width) - 1)
            let rect: CGRect = CGRect(x: x0, y: 0, width: w, height: size.height)
            let radius: CGFloat = j > 0 ? 2 : 5
            context.fill(Path(roundedRect: rect, cornerRadius: radius),
                         with: .color(Theme.ovPartColor(colorIndex(part))))
            if part.isPartial {
                context.stroke(Path(roundedRect: rect, cornerRadius: radius), with: .color(Theme.ovFg2),
                               style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
            }
            workEnd = Swift.max(workEnd, part.offset + part.duration)
        }
        drawRestLabel(&context, workEnd, slotWidth, size)
        var end: Path = Path()
        end.move(to: CGPoint(x: slotWidth - 0.75, y: 0))
        end.addLine(to: CGPoint(x: slotWidth - 0.75, y: size.height))
        context.stroke(end, with: .color(Theme.ovFg2), lineWidth: 1.5)
    }

    private func drawRestLabel(_ context: inout GraphicsContext, _ workEnd: Double, _ slotWidth: CGFloat,
                               _ size: CGSize) {
        let startX: CGFloat = xOf(workEnd, size.width)
        if slotWidth - startX < 24 { return }
        if let rest = set.restSeconds {
            let label: Text = Text(SummaryFormat.clock(rest)).font(.system(size: 10)).foregroundColor(Theme.ovFg2)
            context.draw(label, at: CGPoint(x: (startX + slotWidth) / 2, y: size.height / 2), anchor: UnitPoint.center)
        } else {
            let label: Text = Text("end").font(.system(size: 10)).foregroundColor(Theme.ovFg2)
            context.draw(label, at: CGPoint(x: startX + 6, y: size.height / 2), anchor: UnitPoint.leading)
        }
    }
}

/// Time ticks under the slot rows (0, 1:00, 2:00 ... slot end), aligned with the bars.
struct SlotAxisRow: View {
    let slotSeconds: Double
    let scaleSeconds: Double

    var body: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 30, height: 1)
            Canvas { (context: inout GraphicsContext, size: CGSize) in
                draw(&context, size)
            }
            .frame(height: 16)
            .frame(maxWidth: .infinity)
            Text("HR start \u{2192} peak \u{00B7} drop in rest")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ovFg2)
                .multilineTextAlignment(.trailing)
                .frame(width: 98, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        if scaleSeconds <= 0 { return }
        var step: Double = 60
        if slotSeconds > 600 {
            step = 300
        } else if slotSeconds > 240 {
            step = 120
        }
        var ticks: [Double] = []
        var t: Double = 0
        while t < slotSeconds - 1 {
            ticks.append(t)
            t += step
        }
        ticks.append(slotSeconds)
        for (i, tick) in ticks.enumerated() {
            let x: CGFloat = CGFloat(tick / scaleSeconds) * size.width
            var line: Path = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: 4))
            context.stroke(line, with: .color(Theme.ovGrid), lineWidth: 1)
            var anchor: UnitPoint = UnitPoint.top
            if i == 0 {
                anchor = UnitPoint.topLeading
            } else if i == ticks.count - 1 {
                anchor = UnitPoint.topTrailing
            }
            let label: Text = Text(SummaryFormat.clock(tick)).font(.system(size: 10)).foregroundColor(Theme.ovFg2)
            context.draw(label, at: CGPoint(x: x, y: 5), anchor: anchor)
        }
    }
}
