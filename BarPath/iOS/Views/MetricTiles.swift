import SwiftUI
import BarPathKit

struct MetricTile: View {
    let title: String
    let value: String
    let unit: String
    var detail: String? = nil
    var tint: Color = Color.primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            if let detail = detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.tileBackground)
        )
    }
}

struct MetricTiles: View {
    let display: LiftDisplay

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        let m = display.metrics
        LazyVGrid(columns: columns, spacing: 10) {
            MetricTile(title: "Peak velocity",
                       value: Fmt.mps(m.peakVerticalVelocity),
                       unit: "m/s",
                       detail: "at \(Fmt.seconds(m.timeToPeakVelocity))",
                       tint: Theme.accent)
            MetricTile(title: "Max height",
                       value: Fmt.cm(m.maxHeight),
                       unit: "cm",
                       detail: "above start")
            MetricTile(title: "Catch height",
                       value: m.catchHeight.map { Fmt.cm($0) } ?? "—",
                       unit: m.catchHeight == nil ? "" : "cm",
                       detail: m.catchHeight == nil ? "no catch found" : "above start")
            MetricTile(title: "Drop under bar",
                       value: m.dropUnderBar.map { Fmt.cm($0) } ?? "—",
                       unit: m.dropUnderBar == nil ? "" : "cm",
                       detail: "max → catch")
            MetricTile(title: "Confidence",
                       value: Labels.confidence(display.confidence),
                       unit: "",
                       detail: "drift fix \(Fmt.mps(display.maxDrift)) m/s",
                       tint: Theme.confidenceColor(display.confidence))
            MetricTile(title: "Horizontal",
                       value: Fmt.cm(m.maxForward - m.maxBackward),
                       unit: "cm",
                       detail: "\(Fmt.signedCm(m.maxForward)) / \(Fmt.signedCm(m.maxBackward)) cm")
        }
    }
}

/// The analyzer's caveats, shown as-is.
struct AnalysisNotesView: View {
    let display: LiftDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if display.confidence.rawValue == "low" {
                Label("Low confidence: the path may be off by several cm. Hold still ~1 s at the set position and at the finish.",
                      systemImage: "exclamationmark.octagon")
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }
            if display.notes.isEmpty {
                Label("No caveats from the analyzer", systemImage: "checkmark.seal")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(display.notes.enumerated()), id: \.offset) { item in
                    Label(item.element, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
