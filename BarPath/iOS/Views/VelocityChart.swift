import SwiftUI
import Charts
import BarPathKit

/// Vertical velocity vs time since the set position, with segment boundaries
/// (zero-velocity anchors) as dashed vertical rules.
struct VelocityChart: View {
    let display: LiftDisplay

    private var timeDomain: ClosedRange<Double> {
        let end = max(display.pathDuration, 0.5)
        return 0.0...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Vertical velocity")
                    .font(.headline)
                Spacer()
                Text("dashed = still points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Chart {
                zeroRule
                boundaryRules
                velocityLine
                peakMarker
            }
            .chartXScale(domain: timeDomain)
            .chartXAxisLabel("Time since set position (s)")
            .chartYAxisLabel("m/s")
            .frame(height: 190)
        }
    }

    @ChartContentBuilder
    private var zeroRule: some ChartContent {
        RuleMark(y: .value("Zero", 0.0))
            .foregroundStyle(Color.gray.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1))
    }

    @ChartContentBuilder
    private var boundaryRules: some ChartContent {
        ForEach(display.segmentBoundaryTimes, id: \.self) { t in
            RuleMark(x: .value("Segment boundary", t))
                .foregroundStyle(Color.gray.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }

    @ChartContentBuilder
    private var velocityLine: some ChartContent {
        ForEach(display.points) { p in
            LineMark(x: .value("Time", p.t),
                     y: .value("Velocity", p.vVertical))
                .foregroundStyle(Theme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private var peakMarker: some ChartContent {
        PointMark(x: .value("Time", display.metrics.timeToPeakVelocity),
                  y: .value("Velocity", display.metrics.peakVerticalVelocity))
            .foregroundStyle(Theme.accent)
            .symbolSize(70)
            .annotation(position: .top, spacing: 4) {
                Text("\(Fmt.mps(display.metrics.peakVerticalVelocity)) m/s")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
    }
}
