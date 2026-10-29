import SwiftUI
import Charts
import BarPathKit

/// Axis domains with the same cm-per-point scale on x and y (approximately: the plot area
/// is assumed to have the aspect ratio `widthOverHeight`).
struct PathDomain {
    let x: ClosedRange<Double>
    let y: ClosedRange<Double>

    static func make(points: [ChartPoint], extra: [ChartPoint], widthOverHeight: Double) -> PathDomain {
        // Always include the start position (0, 0).
        var minX = 0.0
        var maxX = 0.0
        var minY = 0.0
        var maxY = 0.0
        for p in points {
            minX = min(minX, p.forwardCm)
            maxX = max(maxX, p.forwardCm)
            minY = min(minY, p.verticalCm)
            maxY = max(maxY, p.verticalCm)
        }
        for p in extra {
            minX = min(minX, p.forwardCm)
            maxX = max(maxX, p.forwardCm)
            minY = min(minY, p.verticalCm)
            maxY = max(maxY, p.verticalCm)
        }
        let pad = 8.0
        var xSpan = max(maxX - minX, 20.0) + 2.0 * pad
        var ySpan = max(maxY - minY, 20.0) + 2.0 * pad
        if xSpan / ySpan < widthOverHeight {
            xSpan = ySpan * widthOverHeight
        } else {
            ySpan = xSpan / widthOverHeight
        }
        let cx = (minX + maxX) / 2.0
        let cy = (minY + maxY) / 2.0
        let xRange: ClosedRange<Double> = (cx - xSpan / 2.0)...(cx + xSpan / 2.0)
        let yRange: ClosedRange<Double> = (cy - ySpan / 2.0)...(cy + ySpan / 2.0)
        return PathDomain(x: xRange, y: yRange)
    }
}

/// Side view of the bar path: forward cm (x) vs height cm (y), points colored by speed.
struct BarPathChart: View {
    let display: LiftDisplay
    var previous: LiftDisplay? = nil
    var previousLabel: String? = nil

    /// Chart view aspect ratio (width / height). The plot area is slightly narrower
    /// because of the y-axis labels, hence the smaller plot aspect used for the domain.
    private let viewAspect: CGFloat = 0.9
    private let plotAspect: Double = 0.82

    private var speedTop: Double {
        return max(2.0, display.maxSpeed)
    }

    var body: some View {
        let domain = PathDomain.make(points: display.points,
                                     extra: previous?.points ?? [],
                                     widthOverHeight: plotAspect)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bar path")
                    .font(.headline)
                Spacer()
                if previous != nil {
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(Color.gray.opacity(0.45))
                            .frame(width: 14, height: 3)
                        Text(previousLabel ?? "Previous lift")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Chart {
                previousLayer
                pathLine
                speedPoints
                markerLayer
            }
            .chartForegroundStyleScale(domain: 0.0...speedTop, range: Theme.speedGradient)
            .chartLegend(.hidden)
            .chartXScale(domain: domain.x)
            .chartYScale(domain: domain.y)
            .chartXAxisLabel("Forward (cm) →  away from you")
            .chartYAxisLabel("Height \(display.heightReference) (cm)")
            .aspectRatio(viewAspect, contentMode: .fit)
            SpeedLegend(maxSpeed: speedTop)
        }
    }

    @ChartContentBuilder
    private var previousLayer: some ChartContent {
        if let prev = previous {
            ForEach(prev.points) { p in
                LineMark(x: .value("Forward", p.forwardCm),
                         y: .value("Height", p.verticalCm),
                         series: .value("Lift", "previous"))
                    .foregroundStyle(Color.gray.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
    }

    @ChartContentBuilder
    private var pathLine: some ChartContent {
        ForEach(display.points) { p in
            LineMark(x: .value("Forward", p.forwardCm),
                     y: .value("Height", p.verticalCm),
                     series: .value("Lift", "current"))
                .foregroundStyle(Color.primary.opacity(0.25))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    @ChartContentBuilder
    private var speedPoints: some ChartContent {
        ForEach(display.points) { p in
            PointMark(x: .value("Forward", p.forwardCm),
                      y: .value("Height", p.verticalCm))
                .foregroundStyle(by: .value("Speed", p.speed))
                .symbolSize(16)
        }
    }

    @ChartContentBuilder
    private var markerLayer: some ChartContent {
        ForEach(display.markers) { m in
            PointMark(x: .value("Forward", m.forwardCm),
                      y: .value("Height", m.verticalCm))
                .foregroundStyle(Theme.cardBackground)
                .symbolSize(170)
            PointMark(x: .value("Forward", m.forwardCm),
                      y: .value("Height", m.verticalCm))
                .foregroundStyle(Theme.markerColor(m.kind))
                .symbolSize(80)
                .annotation(position: annotationPosition(m.kind), spacing: 4) {
                    Text(m.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.markerColor(m.kind))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.cardBackground.opacity(0.85)))
                }
        }
    }

    private func annotationPosition(_ kind: MarkerKind) -> AnnotationPosition {
        switch kind {
        case .start: return .trailing
        case .maxHeight: return .top
        case .catchPoint: return .leading
        }
    }
}
