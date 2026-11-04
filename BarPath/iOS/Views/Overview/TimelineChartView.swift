import SwiftUI
import BarPathKit

/// The drawn timeline (Canvas) with the touch gesture. Drawing lives in `TimelineDrawing`
/// so each piece stays small.
struct TimelineChartView: View {
    let timeline: WorkoutSummary.Timeline
    let selection: ClosedRange<Int>?
    let hoverTime: Double?
    let onTouch: (Double) -> Void
    let onStep: (Int) -> Void
    /// Band colour instead of the run / station colours (the report uses modalities).
    var bandColor: ((WorkoutSummary.Band) -> Color)? = nil

    var body: some View {
        GeometryReader { (geo: GeometryProxy) in
            chart(width: geo.size.width)
        }
        .frame(height: TimelineDrawing.totalHeight)
    }

    private func chart(width: CGFloat) -> some View {
        let drawing: TimelineDrawing = TimelineDrawing(timeline: timeline, selection: selection,
                                                       hoverTime: hoverTime, bandColor: bandColor)
        return Canvas { (context: inout GraphicsContext, size: CGSize) in
            drawing.draw(&context, size)
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { (value: SpatialTapGesture.Value) in
            touch(x: value.location.x, width: width)
        })
        .simultaneousGesture(scrub(width: width))
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint("Swipe up or down to step through segments")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    private var accessibilityText: String {
        if timeline.recovery == nil { return "Heart rate over time with segment bands" }
        return "Heart rate over time with segment bands, then the recovery after the finish"
    }

    /// Scrubs only while the drag is mostly horizontal; vertical swipes are left to the
    /// page's ScrollView (the gesture is simultaneous, so it never blocks scrolling).
    /// Stateless on purpose: a drag the ScrollView takes over may never call onEnded.
    private func scrub(width: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 10)
            .onChanged { (value: DragGesture.Value) in
                let dx: CGFloat = abs(value.translation.width)
                let dy: CGFloat = abs(value.translation.height)
                if dx > dy {
                    touch(x: value.location.x, width: width)
                }
            }
    }

    /// x → time with the chart's scale; in the recovery tail t is past `duration` (the card
    /// shows the recovery chip there instead of selecting a segment).
    private func touch(x: CGFloat, width: CGFloat) {
        if width <= 0 || timeline.duration <= 0 { return }
        let scale: TimelineScale = TimelineScale(timeline: timeline, width: width)
        var t: Double = scale.time(x)
        t = Swift.min(Swift.max(t, 0), scale.end - 0.01)
        onTouch(t)
    }
}

/// Time (relative seconds) ↔ x for the timeline chart.
/// Without a recovery tail: linear from 0 to `duration` over the whole width (as before).
/// With one: the workout is linear over [0, finishX] and the tail linear over [finishX, width].
/// The tail gets its real share of the width, but at least `minTailShare` and at most
/// `maxTailShare`, so 3 minutes after a 25-minute workout are still wide enough to read the
/// +1 / +2 / +3 min marks, and a long cool-down never squeezes the workout. The finish divider
/// and the tail's own "+1m" ticks make the change of scale visible.
struct TimelineScale {
    static let minTailShare: Double = 0.30
    static let maxTailShare: Double = 0.45

    let duration: Double
    /// Right end of the axis: the tail's end, else `duration`.
    let end: Double
    let width: CGFloat
    /// x of the finish (= width without a tail).
    let finishX: CGFloat

    init(timeline: WorkoutSummary.Timeline, width: CGFloat) {
        self.duration = timeline.duration
        self.width = width
        if let r = timeline.recovery, timeline.duration > 0, r.end > timeline.duration {
            self.end = r.end
            let linear: Double = (r.end - timeline.duration) / r.end
            let share: Double = Swift.min(Swift.max(linear, TimelineScale.minTailShare), TimelineScale.maxTailShare)
            self.finishX = width * CGFloat(1.0 - share)
        } else {
            self.end = timeline.duration
            self.finishX = width
        }
    }

    var hasTail: Bool {
        return end > duration
    }

    func x(_ t: Double) -> CGFloat {
        if duration <= 0 { return 0 }
        if !hasTail || t <= duration {
            return CGFloat(t / duration) * finishX
        }
        let f: Double = (t - duration) / (end - duration)
        return finishX + CGFloat(f) * (width - finishX)
    }

    func time(_ x: CGFloat) -> Double {
        if duration <= 0 || finishX <= 0 { return 0 }
        if !hasTail || x <= finishX {
            return Double(x / finishX) * duration
        }
        let w: CGFloat = width - finishX
        if w <= 0 { return duration }
        return duration + Double((x - finishX) / w) * (end - duration)
    }
}

/// Pure drawing of the timeline into a GraphicsContext.
struct TimelineDrawing {
    let timeline: WorkoutSummary.Timeline
    let selection: ClosedRange<Int>?
    let hoverTime: Double?
    var bandColor: ((WorkoutSummary.Band) -> Color)? = nil

    static let topY: CGFloat = 18
    static let bottomY: CGFloat = 150
    static let zoneTopY: CGFloat = 156
    static let zoneHeight: CGFloat = 8
    static let totalHeight: CGFloat = 204

    private let low: Double
    private let high: Double

    init(timeline: WorkoutSummary.Timeline, selection: ClosedRange<Int>?, hoverTime: Double?,
         bandColor: ((WorkoutSummary.Band) -> Color)? = nil) {
        self.timeline = timeline
        self.selection = selection
        self.hoverTime = hoverTime
        self.bandColor = bandColor
        var lo: Double = 60
        var hi: Double = 200
        var lowest: Double? = timeline.heartRateLow
        var highest: Double? = timeline.heartRateHigh
        if let r = timeline.recovery, let rl = r.heartRateLow, let rh = r.heartRateHigh {
            lowest = Swift.min(lowest ?? rl, rl)
            highest = Swift.max(highest ?? rh, rh)
        }
        if let l = lowest, let h = highest {
            lo = ((l - 8) / 10).rounded(.down) * 10
            hi = ((h + 4) / 10).rounded(.up) * 10
        }
        if hi - lo < 20 { hi = lo + 20 }
        self.low = lo
        self.high = hi
    }

    // MARK: Mapping

    private func xOf(_ t: Double, _ width: CGFloat) -> CGFloat {
        return TimelineScale(timeline: timeline, width: width).x(t)
    }

    private func yOf(_ bpm: Double) -> CGFloat {
        let plotHeight: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY - 6
        let fraction: CGFloat = CGFloat((bpm - low) / (high - low))
        return TimelineDrawing.bottomY - fraction * plotHeight
    }

    // MARK: Entry

    func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        drawBands(&context, size.width)
        drawRecoveryBand(&context, size.width)
        drawHeartRateGrid(&context, size.width)
        drawGaps(&context, size.width)
        drawRecoveryGaps(&context, size.width)
        drawHeartRate(&context, size.width)
        drawRecoveryLine(&context, size.width)
        drawZoneStrip(&context, size.width)
        drawAxis(&context, size.width)
        drawFinishDivider(&context, size.width)
        drawRecoveryMarks(&context, size.width)
        drawSelection(&context, size.width)
        drawHover(&context, size.width)
    }

    // MARK: Pieces

    private func text(_ context: inout GraphicsContext, _ string: String, _ point: CGPoint,
                      _ anchor: UnitPoint, size: CGFloat, weight: Font.Weight, color: Color) {
        let t: Text = Text(string).font(.system(size: size, weight: weight)).foregroundColor(color)
        context.draw(t, at: point, anchor: anchor)
    }

    private func drawBands(_ context: inout GraphicsContext, _ width: CGFloat) {
        let top: CGFloat = TimelineDrawing.topY
        let height: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY
        for b in timeline.bands {
            let x0: CGFloat = xOf(b.start, width)
            let bw: CGFloat = Swift.max(0.5, xOf(b.end, width) - x0 - 1)
            let solid: Color = bandColor?(b) ?? Theme.ovSolid(b.kind)
            let pale: Color = bandColor == nil ? Theme.ovBand(b.kind) : solid.opacity(0.12)
            context.fill(Path(CGRect(x: x0, y: top, width: bw, height: height)), with: .color(pale))
            context.fill(Path(CGRect(x: x0, y: top, width: bw, height: 3)), with: .color(solid))
            let needed: CGFloat = CGFloat(b.shortLabel.count) * 5.4 + 2
            if bw >= needed {
                text(&context, b.shortLabel, CGPoint(x: x0 + bw / 2, y: 12), UnitPoint.center,
                     size: 9, weight: .semibold, color: Theme.ovFg2)
            }
        }
    }

    private func drawHeartRateGrid(_ context: inout GraphicsContext, _ width: CGFloat) {
        var h: Double = (low / 20).rounded(.up) * 20
        while h <= high {
            let y: CGFloat = yOf(h)
            if y >= TimelineDrawing.topY + 8 {
                var line: Path = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: width, y: y))
                context.stroke(line, with: .color(Theme.ovGrid), lineWidth: 1)
                text(&context, String(Int(h)), CGPoint(x: width - 2, y: y - 3), UnitPoint.bottomTrailing,
                     size: 10, weight: .regular, color: Theme.ovFg2)
            }
            h += 20
        }
    }

    private func drawGaps(_ context: inout GraphicsContext, _ width: CGFloat) {
        if timeline.isEstimated { return }
        let top: CGFloat = TimelineDrawing.topY + 3
        let height: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY - 3
        for g in timeline.gaps {
            let x0: CGFloat = xOf(g.start, width)
            let gw: CGFloat = xOf(g.end, width) - x0
            if gw <= 0 { continue }
            let rect: CGRect = CGRect(x: x0, y: top, width: gw, height: height)
            hatch(&context, rect)
            if gw > 30 {
                text(&context, "no HR", CGPoint(x: x0 + gw / 2, y: TimelineDrawing.bottomY - 6),
                     UnitPoint.center, size: 9, weight: .bold, color: Theme.ovFg2)
            }
        }
    }

    private func hatch(_ context: inout GraphicsContext, _ rect: CGRect) {
        var inner: GraphicsContext = context
        inner.clip(to: Path(rect))
        var lines: Path = Path()
        var x: CGFloat = rect.minX - rect.height
        while x < rect.maxX {
            lines.move(to: CGPoint(x: x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        inner.stroke(lines, with: .color(Theme.ovFg2.opacity(0.7)), lineWidth: 1)
    }

    private func drawHeartRate(_ context: inout GraphicsContext, _ width: CGFloat) {
        if timeline.isEstimated {
            drawEstimatedSteps(&context, width)
            return
        }
        if !timeline.hasHeartRate {
            text(&context, "No heart rate recorded", CGPoint(x: width / 2, y: 90), UnitPoint.center,
                 size: 12, weight: .semibold, color: Theme.ovFg2)
            return
        }
        var path: Path = Path()
        var penDown: Bool = false
        let values: [Double?] = timeline.heartRate
        for k in 0..<values.count {
            if let v = values[k] {
                let p: CGPoint = CGPoint(x: xOf(timeline.time(ofSample: k), width), y: yOf(v))
                if penDown {
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                    penDown = true
                }
            } else {
                penDown = false
            }
        }
        let style: StrokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        context.stroke(path, with: .color(Theme.ovHR), style: style)
    }

    /// Version 1 files: each split's average as a flat step, its max as a tick.
    private func drawEstimatedSteps(_ context: inout GraphicsContext, _ width: CGFloat) {
        let style: StrokeStyle = StrokeStyle(lineWidth: 2, lineCap: .butt)
        for b in timeline.bands {
            guard let avg = b.heartRateAvg else { continue }
            let x0: CGFloat = xOf(b.start, width) + 1
            let x1: CGFloat = xOf(b.end, width) - 1
            var step: Path = Path()
            step.move(to: CGPoint(x: x0, y: yOf(avg)))
            step.addLine(to: CGPoint(x: Swift.max(x0, x1), y: yOf(avg)))
            context.stroke(step, with: .color(Theme.ovHR), style: style)
            if let mx = b.heartRateMax {
                let mid: CGFloat = (x0 + x1) / 2
                var tick: Path = Path()
                tick.move(to: CGPoint(x: mid, y: yOf(avg)))
                tick.addLine(to: CGPoint(x: mid, y: yOf(mx)))
                context.stroke(tick, with: .color(Theme.ovHR.opacity(0.6)), lineWidth: 1.5)
            }
        }
    }

    /// Zones stop at the finish (time in zones is a workout number); under the recovery tail
    /// the strip is the pale recovery colour, so the row doesn't look like missing data.
    private func drawZoneStrip(_ context: inout GraphicsContext, _ width: CGFloat) {
        if let tail = timeline.recovery {
            let x0: CGFloat = xOf(tail.start, width)
            let rect: CGRect = CGRect(x: x0, y: TimelineDrawing.zoneTopY, width: Swift.max(0, width - x0),
                                      height: TimelineDrawing.zoneHeight)
            context.fill(Path(rect), with: .color(Theme.ovRecoveryBand))
        }
        for z in timeline.zones {
            let x0: CGFloat = xOf(z.start, width)
            let zw: CGFloat = Swift.max(0.5, xOf(z.end, width) - x0)
            let rect: CGRect = CGRect(x: x0, y: TimelineDrawing.zoneTopY, width: zw,
                                      height: TimelineDrawing.zoneHeight)
            context.fill(Path(rect), with: .color(Theme.ovZone(z.zone)))
        }
    }

    private func drawAxis(_ context: inout GraphicsContext, _ width: CGFloat) {
        let duration: Double = timeline.duration
        if duration <= 0 { return }
        var step: Double = 120
        if duration > 3000 {
            step = 900
        } else if duration > 1100 {
            step = 300
        } else if duration > 900 {
            step = 180
        }
        let tickTop: CGFloat = TimelineDrawing.zoneTopY + TimelineDrawing.zoneHeight
        let scale: TimelineScale = TimelineScale(timeline: timeline, width: width)
        var t: Double = 0
        while t <= duration {
            let x: CGFloat = xOf(t, width)
            var tick: Path = Path()
            tick.move(to: CGPoint(x: x, y: tickTop))
            tick.addLine(to: CGPoint(x: x, y: tickTop + 4))
            context.stroke(tick, with: .color(Theme.ovGrid), lineWidth: 1)
            var anchor: UnitPoint = UnitPoint.top
            if t == 0 {
                anchor = UnitPoint.topLeading
            } else if width - x < 22 {
                anchor = UnitPoint.topTrailing
            }
            text(&context, SummaryFormat.clock(t), CGPoint(x: x, y: tickTop + 6), anchor,
                 size: 10, weight: .regular, color: Theme.ovFg2)
            t += step
        }
        guard let tail = timeline.recovery, scale.hasTail else {
            text(&context, "finish " + SummaryFormat.clock(duration), CGPoint(x: width, y: tickTop + 22),
                 UnitPoint.topTrailing, size: 10, weight: .regular, color: Theme.ovFg2)
            return
        }
        // Recovery tail: its own minute ticks ("+1m", "+2m", …), at least 24 pt apart.
        let tailWidth: CGFloat = width - scale.finishX
        let perMinute: CGFloat = tail.duration > 0 ? tailWidth * 60 / CGFloat(tail.duration) : 0
        if perMinute > 0 {
            let every: Int = Swift.max(1, Int((24 / perMinute).rounded(.up)))
            var minute: Int = every
            while Double(minute) * 60 <= tail.duration {
                let x: CGFloat = xOf(tail.start + Double(minute) * 60, width)
                var tick: Path = Path()
                tick.move(to: CGPoint(x: x, y: tickTop))
                tick.addLine(to: CGPoint(x: x, y: tickTop + 4))
                context.stroke(tick, with: .color(Theme.ovGrid), lineWidth: 1)
                let anchor: UnitPoint = width - x < 10 ? UnitPoint.topTrailing : UnitPoint.top
                text(&context, "+" + String(minute) + "m", CGPoint(x: x, y: tickTop + 6), anchor,
                     size: 10, weight: .regular, color: Theme.ovRecovery)
                minute += every
            }
        }
        text(&context, "finish " + SummaryFormat.clock(duration), CGPoint(x: scale.finishX, y: tickTop + 22),
             UnitPoint.topTrailing, size: 10, weight: .regular, color: Theme.ovFg2)
        text(&context, "End " + SummaryFormat.signed(tail.duration), CGPoint(x: width, y: tickTop + 22),
             UnitPoint.topTrailing, size: 10, weight: .semibold, color: Theme.ovRecovery)
    }

    private func drawSelection(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let sel = selection,
              let first = timeline.band(segmentIndex: sel.lowerBound),
              let last = timeline.band(segmentIndex: sel.upperBound) else { return }
        let x0: CGFloat = xOf(first.start, width)
        let x1: CGFloat = xOf(last.end, width)
        let top: CGFloat = TimelineDrawing.topY
        let height: CGFloat = TimelineDrawing.zoneTopY + TimelineDrawing.zoneHeight - TimelineDrawing.topY
        let veil: Color = Theme.cardBackground.opacity(0.62)
        context.fill(Path(CGRect(x: 0, y: top, width: Swift.max(0, x0), height: height)), with: .color(veil))
        context.fill(Path(CGRect(x: x1, y: top, width: Swift.max(0, width - x1), height: height)),
                     with: .color(veil))
        let outline: CGRect = CGRect(x: x0, y: top, width: Swift.max(1, x1 - x0 - 1), height: height)
        context.stroke(Path(roundedRect: outline, cornerRadius: 2), with: .color(Theme.ovSel), lineWidth: 1.5)
    }

    private func drawHover(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let t = hoverTime else { return }
        let x: CGFloat = xOf(t, width)
        var line: Path = Path()
        line.move(to: CGPoint(x: x, y: TimelineDrawing.topY))
        line.addLine(to: CGPoint(x: x, y: TimelineDrawing.zoneTopY + TimelineDrawing.zoneHeight))
        let dashed: StrokeStyle = StrokeStyle(lineWidth: 1, dash: [2, 2])
        context.stroke(line, with: .color(Theme.ovFg), style: dashed)
        var bpm: Double? = nil
        var dot: Color = Theme.ovHR
        if let tail = timeline.recovery, timeline.isRecovery(at: t) {
            bpm = tail.heartRate(at: t)
            dot = Theme.ovRecovery
        } else {
            bpm = timeline.heartRate(at: t)
        }
        if let v = bpm {
            let y: CGFloat = yOf(v)
            let outer: CGRect = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
            let inner: CGRect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: outer), with: .color(Theme.cardBackground))
            context.fill(Path(ellipseIn: inner), with: .color(dot))
        }
    }

    // MARK: Recovery tail (after the finish)

    /// Pale band behind the tail with a recovery-coloured top edge and the "Recovery" label.
    private func drawRecoveryBand(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let tail = timeline.recovery else { return }
        let x0: CGFloat = xOf(tail.start, width)
        let bw: CGFloat = Swift.max(0, width - x0)
        if bw <= 0 { return }
        let top: CGFloat = TimelineDrawing.topY
        let height: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY
        context.fill(Path(CGRect(x: x0, y: top, width: bw, height: height)), with: .color(Theme.ovRecoveryBand))
        context.fill(Path(CGRect(x: x0, y: top, width: bw, height: 3)), with: .color(Theme.ovRecovery))
        var label: String = ""
        if bw >= 50 {
            label = "Recovery"
        } else if bw >= 26 {
            label = "Rec."
        }
        if !label.isEmpty {
            text(&context, label, CGPoint(x: x0 + bw / 2, y: 12), UnitPoint.center,
                 size: 9, weight: .semibold, color: Theme.ovRecovery)
        }
    }

    /// Hatches the tail's 5 s values with no reading, like the workout's gaps.
    private func drawRecoveryGaps(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let tail = timeline.recovery else { return }
        let top: CGFloat = TimelineDrawing.topY + 3
        let height: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY - 3
        let values: [Double?] = tail.heartRate
        var gapStart: Double? = nil
        for k in 0...values.count {
            let s: Double = Swift.min(tail.start + Double(k) * tail.interval, tail.end)
            let missing: Bool = k < values.count && values[k] == nil
            if missing {
                if gapStart == nil { gapStart = s }
            } else if let g = gapStart {
                let x0: CGFloat = xOf(g, width)
                let gw: CGFloat = xOf(s, width) - x0
                if gw > 0 {
                    hatch(&context, CGRect(x: x0, y: top, width: gw, height: height))
                }
                gapStart = nil
            }
        }
    }

    /// The HR line after the finish in the recovery colour, joined to the workout's last
    /// value so the curve runs on through the finish.
    private func drawRecoveryLine(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let tail = timeline.recovery else { return }
        var path: Path = Path()
        var penDown: Bool = false
        let workout: [Double?] = timeline.heartRate
        if !timeline.isEstimated, let lastIndex = workout.indices.last, let last = workout[lastIndex] {
            path.move(to: CGPoint(x: xOf(timeline.time(ofSample: lastIndex), width), y: yOf(last)))
            penDown = true
        }
        let values: [Double?] = tail.heartRate
        for k in 0..<values.count {
            if let v = values[k] {
                let p: CGPoint = CGPoint(x: xOf(tail.time(ofSample: k), width), y: yOf(v))
                if penDown {
                    path.addLine(to: p)
                } else {
                    path.move(to: p)
                    penDown = true
                }
            } else {
                penDown = false
            }
        }
        let style: StrokeStyle = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        context.stroke(path, with: .color(Theme.ovRecovery), style: style)
    }

    /// Thin vertical line at the finish, from the band labels down through the zone strip.
    private func drawFinishDivider(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let tail = timeline.recovery else { return }
        let x: CGFloat = xOf(tail.start, width)
        var line: Path = Path()
        line.move(to: CGPoint(x: x, y: TimelineDrawing.topY - 2))
        line.addLine(to: CGPoint(x: x, y: TimelineDrawing.zoneTopY + TimelineDrawing.zoneHeight + 4))
        context.stroke(line, with: .color(Theme.ovFg2), lineWidth: 1)
    }

    /// A dot on the line at +1 / +2 / +3 min with its bpm above it.
    private func drawRecoveryMarks(_ context: inout GraphicsContext, _ width: CGFloat) {
        guard let tail = timeline.recovery else { return }
        for mark in tail.marks {
            let x: CGFloat = xOf(tail.time(of: mark), width)
            let y: CGFloat = yOf(mark.heartRate)
            let outer: CGRect = CGRect(x: x - 4.5, y: y - 4.5, width: 9, height: 9)
            let inner: CGRect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: outer), with: .color(Theme.cardBackground))
            context.fill(Path(ellipseIn: inner), with: .color(Theme.ovRecovery))
            let labelY: CGFloat = Swift.max(TimelineDrawing.topY + 14, y - 6)
            var anchor: UnitPoint = UnitPoint.bottom
            if width - x < 10 { anchor = UnitPoint.bottomTrailing }
            text(&context, SummaryFormat.bpm(mark.heartRate), CGPoint(x: x, y: labelY), anchor,
                 size: 9, weight: .bold, color: Theme.ovRecovery)
        }
    }
}
