import SwiftUI
import BarPathKit

// The workout card (docs/concepts/workout-cards.html, "Final card spec" in
// docs/concepts/HEADER_STUDY.md). Text comes from BarPathKit's WorkoutCard; this file only lays it
// out. Type scale: name 20/500 (compact 16/500, 1 line), lines 14/400, scheme and time domain
// 14/500, cap 13, meta 12, tags 10.5/500. Spacing: padding 16, 9 between blocks, 5 between
// movement lines, radius 16, 1 px border. Neutrals + one accent (type tag). Colours not final.

enum WorkoutCardTheme {
    static let accent: Color = Theme.accent
    static let fg2: Color = Theme.ovFg2
    static let fg3: Color = Theme.ovFg3
    static let border: Color = Theme.ovGrid
    static let tagFill: Color = Theme.tileBackground
    static let cardFill: Color = Theme.cardBackground
}

/// Top-left meta of a card and rows.
enum WorkoutCardMeta {
    /// Library: "Today · PitFIRE", "Mon, Nov 2 · PitFIRE", "PitFIRE"; built-in: "Built-in".
    static func text(_ library: LibraryWorkout?) -> String {
        guard let w = library else { return "Built-in" }
        var parts: [String] = []
        if let day = w.scheduledOn, day == LibraryDay.today {
            parts.append("Today")
        } else if let label = w.dateLabel {
            parts.append(label)
        }
        if let program = w.program?.trimmingCharacters(in: .whitespacesAndNewlines), !program.isEmpty {
            parts.append(program)
        }
        return parts.isEmpty ? "Library" : parts.joined(separator: " · ")
    }
}

/// A small pill: block tag (neutral fill) or type tag (outlined, accent).
struct WorkoutCardTag: View {
    let text: String
    let outlined: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(outlined ? WorkoutCardTheme.accent : WorkoutCardTheme.fg2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(outlined ? Color.clear : WorkoutCardTheme.tagFill)
            )
            .overlay(
                Capsule().strokeBorder(outlined ? WorkoutCardTheme.accent : Color.clear, lineWidth: 1)
            )
    }
}

/// Rx / Scaled answer of a logged workout. Nothing stores it yet, so logged workouts show the
/// dashed "?" of the spec ("not answered yet").
enum WorkoutRxBadge {
    case rx
    case scaled
    case unknown
}

struct WorkoutRxBadgeView: View {
    let badge: WorkoutRxBadge
    /// Compact rows write the unknown badge as "?" only.
    var short: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .foregroundColor(badge == WorkoutRxBadge.scaled ? Color.orange : WorkoutCardTheme.fg2)
            .padding(.horizontal, badge == WorkoutRxBadge.unknown ? 5 : 6)
            .padding(.vertical, badge == WorkoutRxBadge.unknown ? 2 : 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(badge == WorkoutRxBadge.unknown ? WorkoutCardTheme.fg3 : Color.clear,
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            )
            .accessibilityLabel(badge == WorkoutRxBadge.unknown ? "Rx or Scaled not answered" : label)
    }

    private var label: String {
        switch badge {
        case .rx: return "Rx"
        case .scaled: return "Scaled"
        case .unknown: return short ? "?" : "Rx / Scaled ?"
        }
    }

    private var fill: Color {
        switch badge {
        case .rx: return WorkoutCardTheme.tagFill
        case .scaled: return Color.orange.opacity(0.15)
        case .unknown: return Color.clear
        }
    }
}

/// The score line of a done card: "19:37", unit, Rx / Scaled badge, the context ("3:13 under the
/// 16:00 cap") and the change vs the last attempt.
struct WorkoutCardScore {
    /// "19:37", "7 + 12", "8 / 8".
    let value: String
    /// "rounds + reps", "sets".
    let unit: String?
    let badge: WorkoutRxBadge
    /// "3 rounds for time · 3:13 under the 16:00 cap".
    let context: String?
    /// "−0:23" (coloured: faster green, slower red) and "vs last time (Nov 2)".
    let delta: String?
    let deltaSeconds: Double?
    let deltaSuffix: String?
    /// "Avg HR 160 · Max 175 · Zone 4–5 12:04".
    let facts: String?

    static func make(_ summary: WorkoutSummary) -> WorkoutCardScore {
        let h: WorkoutSummary.Headline = summary.headline
        var suffix: String? = nil
        if h.deltaText != nil {
            var text: String = " vs last time"
            if let d = h.previousDate {
                text += " (" + OverviewFormat.shortDate(d) + ")"
            }
            suffix = text
        }
        var facts: [String] = []
        if h.heartRateAvg != nil {
            facts.append("Avg HR " + SummaryFormat.bpm(h.heartRateAvg))
        }
        if h.heartRateMax != nil {
            facts.append("Max " + SummaryFormat.bpm(h.heartRateMax))
        }
        if let z = h.zone45Seconds {
            facts.append("Zone 4\u{2013}5 " + SummaryFormat.clock(z))
        }
        let context: String = h.contextText.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkoutCardScore(value: h.scoreText, unit: h.scoreUnit, badge: WorkoutRxBadge.unknown,
                                context: context.isEmpty ? nil : context,
                                delta: h.deltaText, deltaSeconds: h.deltaSeconds, deltaSuffix: suffix,
                                facts: facts.isEmpty ? nil : facts.joined(separator: " \u{00B7} "))
    }
}

/// The full card (preview) or the compact row (Choose list).
struct WorkoutCardView: View {
    enum Style {
        case full
        case compact
    }

    let card: WorkoutCard
    /// Full: "Mon, Nov 2 · PitFIRE" or "Built-in". Compact: an optional date put before
    /// "block · type".
    var meta: String? = nil
    var style: Style = Style.full
    /// Compact: the last score of this workout ("19:37", "7 rds").
    var lastScore: String? = nil
    /// Compact: this workout is the one on the watch.
    var isSent: Bool = false
    /// Done card (Log row, top of the report): the score line / the score on the right.
    var score: WorkoutCardScore? = nil

    var body: some View {
        switch style {
        case .full:
            fullCard
        case .compact:
            compactRow
        }
    }

    // MARK: Full

    private var fullCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Text(meta ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(WorkoutCardTheme.fg2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                tags
            }
            Text(card.name)
                .font(.system(size: 20, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let domain = card.timeDomainLine {
                Text(domain)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            movementBlock
            if let cap = card.capLine {
                Text(cap)
                    .font(.system(size: 13))
                    .foregroundColor(WorkoutCardTheme.fg2)
            }
            if let s = score {
                scoreLine(s)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(WorkoutCardTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(WorkoutCardTheme.border, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var tags: some View {
        HStack(spacing: 5) {
            if let block = card.blockTag {
                WorkoutCardTag(text: block.label, outlined: false)
            }
            if let typeTag = card.typeTag {
                WorkoutCardTag(text: typeTag.label, outlined: true)
            }
        }
    }

    private var movementBlock: some View {
        let shown: [WorkoutCard.Line] = card.visibleLines().lines
        let hidden: Int = card.visibleLines().hidden
        return VStack(alignment: .leading, spacing: 5) {
            if let scheme = card.repSchemeLine {
                Text(scheme)
                    .font(.system(size: 14, weight: .medium))
                    .tracking(0.2)
                    .monospacedDigit()
                    .padding(.bottom, 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { item in
                WorkoutCardView.lineText(item.element)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if hidden > 0 {
                Text("+" + String(hidden) + " more")
                    .font(.system(size: 13))
                    .foregroundColor(WorkoutCardTheme.fg2)
            }
        }
        .padding(.top, 2)
    }

    /// "7 Power Cleans" then "@155 lb" in the secondary colour; the load never breaks inside.
    static func lineText(_ line: WorkoutCard.Line) -> Text {
        var text: Text = Text(line.text)
        if let load = line.load {
            let together: String = ("@" + load).replacingOccurrences(of: " ", with: "\u{00A0}")
            text = text + Text(" ") + Text(together).foregroundColor(WorkoutCardTheme.fg2)
        }
        return text.monospacedDigit()
    }

    /// Under a thin rule: score 26/500 tabular, unit, badge; then the context, the change vs
    /// last time and the heart-rate facts.
    private func scoreLine(_ s: WorkoutCardScore) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(WorkoutCardTheme.border)
                .frame(height: 1)
                .padding(.bottom, 6)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(s.value)
                    .font(.system(size: 26, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = s.unit {
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundColor(WorkoutCardTheme.fg2)
                        .lineLimit(1)
                }
                WorkoutRxBadgeView(badge: s.badge)
                Spacer(minLength: 0)
            }
            if let delta = s.delta {
                (Text(delta).fontWeight(.medium).foregroundColor(OverviewFormat.deltaColor(s.deltaSeconds))
                    + Text(s.deltaSuffix ?? "").foregroundColor(WorkoutCardTheme.fg2))
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let context = s.context {
                Text(context)
                    .font(.system(size: 12.5))
                    .foregroundColor(WorkoutCardTheme.fg2)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let facts = s.facts {
                Text(facts)
                    .font(.system(size: 12))
                    .foregroundColor(WorkoutCardTheme.fg3)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 3)
    }

    // MARK: Compact

    private var compactRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(card.name)
                    .font(.system(size: 16, weight: .medium))
                    .lineLimit(1)
                Text(compactMeta)
                    .font(.system(size: 12))
                    .foregroundColor(WorkoutCardTheme.fg2)
                    .lineLimit(1)
                Text(card.summaryLine)
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .foregroundColor(WorkoutCardTheme.fg2)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if let done = score {
                    Text(done.value)
                        .font(.system(size: 17, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                    if let unit = done.unit {
                        Text(unit)
                            .font(.system(size: 11))
                            .foregroundColor(WorkoutCardTheme.fg3)
                            .lineLimit(1)
                    }
                    WorkoutRxBadgeView(badge: done.badge, short: true)
                } else if let score = lastScore {
                    Text("last")
                        .font(.system(size: 11))
                        .foregroundColor(WorkoutCardTheme.fg3)
                    Text(score)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if isSent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(WorkoutCardTheme.accent)
                        .accessibilityLabel("On the watch")
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "Mon, Nov 2 · Metcon · RFT", "Metcon · AMRAP", "No plan" for the Free Workout.
    private var compactMeta: String {
        var parts: [String] = []
        if let m = meta, !m.isEmpty { parts.append(m) }
        if let block = card.blockTag { parts.append(block.label) }
        if let typeTag = card.typeTag { parts.append(typeTag.label) }
        if card.blockTag == nil && card.typeTag == nil { parts.append("No plan") }
        return parts.joined(separator: " · ")
    }
}

/// Last score of each workout for the Choose rows, written like the score line ("19:37", "7 rds",
/// "7 + 12", "8 sets"). The newest result of the same workout (WorkoutHistory: same id, an alias,
/// or same name and movements, so a result saved as "wod.freedom" counts for PitFIRE's "For Time").
enum WorkoutLastScore {
    /// Keyed by definition id.
    static func byDefinition(_ definitions: [WorkoutDefinition], results: [WorkoutResult]) -> [String: String] {
        var out: [String: String] = [:]
        for d in definitions where out[d.id] == nil {
            if let r = WorkoutHistory.latest(of: d, in: results) {
                out[d.id] = text(r)
            }
        }
        return out
    }

    /// Score of each result for the Log rows ("19:37", "7 rds"), keyed by result id.
    static func byResult(_ results: [WorkoutResult]) -> [UUID: WorkoutCardScore] {
        var out: [UUID: WorkoutCardScore] = [:]
        for r in results {
            out[r.id] = WorkoutCardScore(value: text(r), unit: nil, badge: WorkoutRxBadge.unknown,
                                         context: nil, delta: nil, deltaSeconds: nil, deltaSuffix: nil,
                                         facts: nil)
        }
        return out
    }

    static func text(_ r: WorkoutResult) -> String {
        let h: WorkoutSummary.Headline = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil).headline
        return text(h)
    }

    static func text(_ h: WorkoutSummary.Headline) -> String {
        if let rounds = h.rounds {
            let extra: Int = h.extraReps ?? 0
            return extra > 0 ? String(rounds) + " + " + String(extra) : String(rounds) + " rds"
        }
        if let unit = h.scoreUnit, unit == "sets" {
            return h.scoreText + " sets"
        }
        return h.scoreText
    }
}

/// The card of a logged workout: the definition to draw it from and its program. A result keeps
/// the definition it was recorded with; when the library has the same workout (same id, a library
/// row that lists the result's id in its aliases — "wod.freedom" for PitFIRE's "For Time" — or, for
/// an id that is no built-in any more, the same name and movements) the library's current version,
/// name and program are used.
enum WorkoutResultCard {
    static func resolve(_ result: WorkoutResult, library: [LibraryWorkout]) -> (definition: WorkoutDefinition, program: String?) {
        let id: String = result.definition.id
        if let w = library.first(where: { (w: LibraryWorkout) -> Bool in w.id == id }) {
            return (w.definition, WorkoutResultCard.clean(w.program))
        }
        // An alias is written on purpose, so it counts even for an id a built-in still uses.
        if let w = library.first(where: { (w: LibraryWorkout) -> Bool in
            WorkoutHistory.hasAlias(w.definition, id) }) {
            return (w.definition, WorkoutResultCard.clean(w.program))
        }
        if WorkoutLibrary.definition(id: id) == nil,
           let w = library.first(where: { (w: LibraryWorkout) -> Bool in
               WorkoutHistory.isSameWorkout(w.definition, result.definition) }) {
            return (w.definition, WorkoutResultCard.clean(w.program))
        }
        return (result.definition, nil)
    }

    /// "Mon, Nov 2".
    static func dateLabel(_ date: Date) -> String {
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Log row: "Mon, Nov 2 · PitFIRE" or "Mon, Nov 2".
    static func logMeta(_ result: WorkoutResult, program: String?) -> String {
        var parts: [String] = [dateLabel(result.startDate)]
        if let p = program { parts.append(p) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Report card: "Mon, Nov 2 · PitFIRE", "Thu, Oct 29 · Built-in".
    static func reportMeta(_ result: WorkoutResult, program: String?) -> String {
        var parts: [String] = [dateLabel(result.startDate)]
        if let p = program {
            parts.append(p)
        } else if WorkoutLibrary.definition(id: result.definition.id) != nil {
            parts.append("Built-in")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private static func clean(_ program: String?) -> String? {
        guard let p = program?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return nil }
        return p
    }
}
