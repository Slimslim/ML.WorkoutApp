import SwiftUI
import BarPathKit
import WatchConnectivity

struct LiftRoute: Hashable {
    let id: UUID
}

struct SessionRoute: Hashable {
    let id: UUID
}

/// Compact row: lift number, type, time, peak velocity, max height, confidence.
struct LiftRow: View {
    let entry: LiftEntry

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                Text("\(entry.index)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.subtitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.startDate, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let r = entry.reps, r.count > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(r.count) rep\(r.count == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                    Text(r.count >= 2 ? "loss \(Fmt.percent(r.velocityLoss))" : "\(Fmt.mps(r.reps[0].meanVelocity)) m/s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if let d = entry.display {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Fmt.mps(d.metrics.peakVerticalVelocity)) m/s")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("\(Fmt.cm(d.metrics.maxHeight)) cm")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Circle()
                    .fill(Theme.confidenceColor(d.confidence))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Confidence \(Labels.confidence(d.confidence))")
            } else {
                Label("No path", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// "Lift 3 · Snatch · 80 kg" header used on the hero card and the detail screen.
struct LiftTitle: View {
    let entry: LiftEntry
    var showReceived: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.isSet ? "Set" : "Lift") \(entry.index)")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text(entry.subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if let d = entry.display {
                    ConfidenceBadge(confidence: d.confidence)
                }
                if showReceived {
                    (Text(entry.receivedAt, style: .relative) + Text(" ago"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(entry.startDate, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct AnalysisFailedView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No bar path for this lift", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(Color.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("The recording is still saved and can be exported for tuning.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Bar path + velocity + tiles + notes for one lift.
struct LiftAnalysisContent: View {
    let entry: LiftEntry
    let previous: LiftEntry?

    var body: some View {
        if let r = entry.reps, r.count > 0 {
            RepSetView(analysis: r)
        } else if let d = entry.display {
            VStack(alignment: .leading, spacing: 16) {
                BarPathChart(display: d,
                             previous: previous?.display,
                             previousLabel: previous.map { "Lift \($0.index)" })
                VelocityChart(display: d)
                MetricTiles(display: d)
                AnalysisNotesView(display: d)
            }
        } else {
            AnalysisFailedView(message: entry.failure ?? "This lift has not been analyzed.")
        }
    }
}

/// Strength-mode set: count, velocity loss and one row per rep (VBT).
struct RepSetView: View {
    let analysis: RepAnalysis

    private var fastest: Double {
        return analysis.reps.map { $0.meanVelocity }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tile("REPS", "\(analysis.count)")
                tile("VELOCITY LOSS", analysis.count >= 2 ? Fmt.percent(analysis.velocityLoss) : "—")
                tile("BEST MEAN", "\(Fmt.mps(fastest)) m/s")
            }
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Rep").gridColumnAlignment(.leading)
                    Text("ROM")
                    Text("Mean")
                    Text("Peak")
                    Text("")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                ForEach(Array(analysis.reps.enumerated()), id: \.offset) { item in
                    let rep = item.element
                    GridRow {
                        Text("\(item.offset + 1)").gridColumnAlignment(.leading)
                        Text("\(Fmt.cm(rep.range)) cm")
                        Text("\(Fmt.mps(rep.meanVelocity)) m/s")
                        Text("\(Fmt.mps(rep.peakVelocity)) m/s")
                        bar(rep.meanVelocity)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
            }
            Text("Mean = average upward bar speed over the rep (concentric). Velocity loss compares the last rep with the faster of the first two. ROM is from the wrist and reads low on the first and last rep.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Mean velocity relative to the set's fastest rep.
    private func bar(_ v: Double) -> some View {
        let fraction = fastest > 0 ? max(0, min(1, v / fastest)) : 0
        return Capsule()
            .fill(Theme.accent)
            .frame(width: 60 * fraction, height: 6)
            .frame(width: 60, alignment: .leading)
    }
}

struct WatchStatusChip: View {
    @EnvironmentObject private var link: PhoneLink

    private var text: String {
        if link.isReachable { return "Watch connected" }
        if link.activationState != .activated { return "Connecting…" }
        if !link.isPaired { return "No watch paired" }
        if !link.isWatchAppInstalled { return "Watch app missing" }
        if link.isLaunchingWatchApp { return "Opening on watch…" }
        if link.watchLaunchError != nil { return "Unlock watch, tap to retry" }
        return "Tap to open on watch"
    }

    private var canLaunch: Bool {
        return !link.isReachable && link.activationState == .activated
            && link.isPaired && link.isWatchAppInstalled
    }

    private var color: Color {
        if link.isReachable { return Color.green }
        if link.isPaired && link.isWatchAppInstalled { return Color.gray }
        return Color.orange
    }

    var body: some View {
        Button {
            link.launchWatchApp()
        } label: {
            chip
        }
        .buttonStyle(.plain)
        .disabled(!canLaunch)
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: "applewatch")
                .font(.caption)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
    }
}
