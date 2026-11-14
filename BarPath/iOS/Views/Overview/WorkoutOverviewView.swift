import SwiftUI
import BarPathKit

/// The post-workout overview: score, heart rate through the workout, one story view per
/// format, folded splits and a data note. All numbers come from `WorkoutSummary`.
///
/// With a `card` (the report, WorkoutDetailView) the top is the done workout card (spec context
/// d): meta, tags, name, time domain, rep scheme, movements, cap, then the score line, which
/// replaces the HeroCard. Without one (Live) the HeroCard stays.
///
/// One shared selection (a range of segment indices) links every part: tap a band, run,
/// cell, set, round or row and the same segment lights up everywhere.
struct WorkoutOverviewView: View {
    let summary: WorkoutSummary
    let kicker: String
    let isNew: Bool
    /// HR after the finish (nil for older results or when End came right away: no card).
    let recovery: HeartRateRecovery?
    /// Report top: the workout card and its meta ("Mon, Nov 2 · PitFIRE").
    let card: WorkoutCard?
    let cardMeta: String?

    @State private var selection: ClosedRange<Int>? = nil
    @State private var hoverTime: Double? = nil

    /// - kicker: line above the title; nil shows the workout date.
    /// - card: when set, the done card replaces the HeroCard (kicker and isNew are then unused).
    /// - maxHeartRate: the max in use (`AthleteProfile.maxHeartRate`); nil estimates the zones.
    init(result: WorkoutResult, previous: WorkoutResult?, maxHeartRate: Double?, kicker: String? = nil,
         isNew: Bool = false, card: WorkoutCard? = nil, cardMeta: String? = nil) {
        self.summary = WorkoutSummary.make(result: result, previous: previous, maxHeartRate: maxHeartRate)
        self.kicker = kicker ?? OverviewFormat.dayAndTime(result.startDate).uppercased()
        self.isNew = isNew
        self.recovery = result.heartRateRecovery
        self.card = card
        self.cardMeta = cardMeta
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let card = card {
                WorkoutCardView(card: card, meta: cardMeta, style: WorkoutCardView.Style.full,
                                score: WorkoutCardScore.make(summary))
            } else {
                HeroCard(summary: summary, kicker: kicker, isNew: isNew)
            }
            HeartRateTimelineCard(summary: summary, selection: $selection, hoverTime: $hoverTime)
            if let recovery = recovery {
                RecoveryCard(recovery: recovery)
            }
            StoryCard(summary: summary, selection: selection, onSelect: select)
            SplitsTableCard(rows: summary.rows, selection: selection, onSelect: select)
            dataNote
        }
    }

    private var dataNote: some View {
        Text(summary.dataNote.text)
            .font(.caption)
            .foregroundStyle(Theme.ovFg3)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }

    /// Tap on a story element or a table row: select segments a...b, tap again to clear.
    private func select(_ a: Int, _ b: Int) {
        hoverTime = nil
        let range: ClosedRange<Int> = a...b
        if let current = selection, current == range {
            selection = nil
        } else {
            selection = range
        }
    }
}

/// Which workout the athlete has already looked at (drives the NEW badge on Live).
enum WorkoutViewed {
    static let key: String = "lastViewedWorkoutId"

    static func isNew(_ id: UUID) -> Bool {
        let stored: String = UserDefaults.standard.string(forKey: key) ?? ""
        return stored != id.uuidString
    }

    static func mark(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: key)
    }

    /// Opening the newest workout (anywhere) counts as viewing it.
    static func markIfNewest(_ result: WorkoutResult, in results: [WorkoutResult]) {
        var newest: WorkoutResult? = nil
        for r in results {
            if let n = newest {
                if r.endDate > n.endDate { newest = r }
            } else {
                newest = r
            }
        }
        if let n = newest, n.id == result.id {
            mark(result.id)
        }
    }
}

/// "Last workout: Helen · 12:47 ›" row shown on Live while the lifting content is newer.
struct LastWorkoutRow: View {
    let result: WorkoutResult

    var body: some View {
        NavigationLink(value: WorkoutRoute(id: result.id)) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .foregroundStyle(Theme.accent)
                Text("Last workout: \(result.definition.name) \u{00B7} \(SummaryFormat.clock(result.totalSeconds))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }
}
