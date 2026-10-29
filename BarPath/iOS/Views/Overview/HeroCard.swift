import SwiftUI
import BarPathKit

/// Score first: kicker (+ NEW), workout name, big score, context line, change vs last
/// attempt, and the heart-rate facts.
struct HeroCard: View {
    let summary: WorkoutSummary
    let kicker: String
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            kickerRow
            Text(summary.headline.title)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .padding(.top, 2)
            scoreRow
            Text(summary.headline.contextText)
                .font(.subheadline)
                .foregroundStyle(Theme.ovFg2)
                .fixedSize(horizontal: false, vertical: true)
            deltaPill
            factsRow
        }
        .card()
    }

    private var kickerRow: some View {
        HStack {
            Text(kicker)
                .font(.caption.weight(.bold))
                .tracking(1.0)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            Spacer()
            if isNew {
                Text("NEW")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Theme.accent)
                    )
            }
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(summary.headline.scoreText)
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let unit = summary.headline.scoreUnit {
                Text(unit)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.ovFg2)
            }
        }
    }

    @ViewBuilder
    private var deltaPill: some View {
        if let text = summary.headline.deltaText, let seconds = summary.headline.deltaSeconds {
            let arrow: String = seconds <= 0 ? "\u{25B2} " : "\u{25BC} "
            let when: String = dateSuffix
            Text(arrow + text + " vs your last attempt" + when)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(OverviewFormat.deltaColor(seconds))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.tileBackground))
                .padding(.top, 8)
        }
    }

    private var dateSuffix: String {
        if let d = summary.headline.previousDate {
            return " (" + OverviewFormat.shortDate(d) + ")"
        }
        return ""
    }

    @ViewBuilder
    private var factsRow: some View {
        let h: WorkoutSummary.Headline = summary.headline
        if h.heartRateAvg != nil || h.heartRateMax != nil || h.zone45Seconds != nil {
            FlowLayout(hSpacing: 14, vSpacing: 4) {
                if h.heartRateAvg != nil {
                    OvFact(label: "Avg HR", value: SummaryFormat.bpm(h.heartRateAvg))
                }
                if h.heartRateMax != nil {
                    OvFact(label: "Max", value: SummaryFormat.bpm(h.heartRateMax))
                }
                if let z = h.zone45Seconds {
                    OvFact(label: "Zone 4\u{2013}5", value: SummaryFormat.clock(z))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        }
    }
}
