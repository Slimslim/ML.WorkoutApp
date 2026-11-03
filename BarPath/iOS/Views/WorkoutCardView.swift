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
            VStack(alignment: .trailing, spacing: 3) {
                if let score = lastScore {
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

/// Last score per workout id, for the Choose rows: the newest result of each definition id,
/// written like the score line ("19:37", "7 rds", "7 + 12", "8 / 8 sets").
enum WorkoutLastScore {
    static func byDefinitionId(_ results: [WorkoutResult]) -> [String: String] {
        var newest: [String: WorkoutResult] = [:]
        for r in results {
            if let n = newest[r.definition.id], n.startDate >= r.startDate { continue }
            newest[r.definition.id] = r
        }
        var out: [String: String] = [:]
        for (id, r) in newest {
            let h: WorkoutSummary.Headline = WorkoutSummary.make(result: r, previous: nil, maxHeartRate: nil).headline
            out[id] = text(h)
        }
        return out
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
