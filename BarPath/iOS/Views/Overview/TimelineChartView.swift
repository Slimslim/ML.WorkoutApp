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

    var body: some View {
        GeometryReader { (geo: GeometryProxy) in
            chart(width: geo.size.width)
        }
        .frame(height: TimelineDrawing.totalHeight)
    }

    private func chart(width: CGFloat) -> some View {
        let drawing: TimelineDrawing = TimelineDrawing(timeline: timeline, selection: selection,
                                                       hoverTime: hoverTime)
        return Canvas { (context: inout GraphicsContext, size: CGSize) in
            drawing.draw(&context, size)
        }
        .contentShape(Rectangle())
        .gesture(scrub(width: width))
        .accessibilityElement()
        .accessibilityLabel("Heart rate over time with segment bands")
        .accessibilityHint("Swipe up or down to step through segments")
        .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    private func scrub(width: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 0)
            .onChanged { (value: DragGesture.Value) in
                touch(x: value.location.x, width: width)
            }
    }

    private func touch(x: CGFloat, width: CGFloat) {
        if width <= 0 || timeline.duration <= 0 { return }
        let fraction: Double = Double(x / width)
        var t: Double = fraction * timeline.duration
        t = Swift.min(Swift.max(t, 0), timeline.duration - 0.01)
        onTouch(t)
    }
}

/// Pure drawing of the timeline into a GraphicsContext.
struct TimelineDrawing {
    let timeline: WorkoutSummary.Timeline
    let selection: ClosedRange<Int>?
    let hoverTime: Double?

    static let topY: CGFloat = 18
    static let bottomY: CGFloat = 150
    static let zoneTopY: CGFloat = 156
    static let zoneHeight: CGFloat = 8
    static let totalHeight: CGFloat = 204

    private let low: Double
    private let high: Double

    init(timeline: WorkoutSummary.Timeline, selection: ClosedRange<Int>?, hoverTime: Double?) {
        self.timeline = timeline
        self.selection = selection
        self.hoverTime = hoverTime
        var lo: Double = 60
        var hi: Double = 200
        if let l = timeline.heartRateLow, let h = timeline.heartRateHigh {
            lo = ((l - 8) / 10).rounded(.down) * 10
            hi = ((h + 4) / 10).rounded(.up) * 10
        }
        if hi - lo < 20 { hi = lo + 20 }
        self.low = lo
        self.high = hi
    }

    // MARK: Mapping

    private func xOf(_ t: Double, _ width: CGFloat) -> CGFloat {
        if timeline.duration <= 0 { return 0 }
        return CGFloat(t / timeline.duration) * width
    }

    private func yOf(_ bpm: Double) -> CGFloat {
        let plotHeight: CGFloat = TimelineDrawing.bottomY - TimelineDrawing.topY - 6
        let fraction: CGFloat = CGFloat((bpm - low) / (high - low))
        return TimelineDrawing.bottomY - fraction * plotHeight
    }

    // MARK: Entry

    func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        drawBands(&context, size.width)
        drawHeartRateGrid(&context, size.width)
        drawGaps(&context, size.width)
        drawHeartRate(&context, size.width)
        drawZoneStrip(&context, size.width)
        drawAxis(&context, size.width)
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
            context.fill(Path(CGRect(x: x0, y: top, width: bw, height: height)),
                         with: .color(Theme.ovBand(b.kind)))
            context.fill(Path(CGRect(x: x0, y: top, width: bw, height: 3)),
                         with: .color(Theme.ovSolid(b.kind)))
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

    private func drawZoneStrip(_ context: inout GraphicsContext, _ width: CGFloat) {
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
        text(&context, "finish " + SummaryFormat.clock(duration), CGPoint(x: width, y: tickTop + 22),
             UnitPoint.topTrailing, size: 10, weight: .regular, color: Theme.ovFg2)
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
        if let bpm = timeline.heartRate(at: t) {
            let y: CGFloat = yOf(bpm)
            let outer: CGRect = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
            let inner: CGRect = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: outer), with: .color(Theme.cardBackground))
            context.fill(Path(ellipseIn: inner), with: .color(Theme.ovHR))
        }
    }
}
