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

            if let d = entry.display {
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
                Text("Lift \(entry.index)")
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
        if let d = entry.display {
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
