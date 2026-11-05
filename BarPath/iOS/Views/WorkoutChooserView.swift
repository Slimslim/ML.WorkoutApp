import SwiftUI
import Combine
import BarPathKit

struct WorkoutGroup: Identifiable {
    let title: String
    let ids: [String]
    var id: String { title }
}

/// Groups of the built-in workouts, in the order the chooser shows them.
enum WorkoutGroups {
    static let sections: [WorkoutGroup] = [
        WorkoutGroup(title: "HYROX", ids: [WorkoutLibrary.hyroxSolo.id, WorkoutLibrary.hyroxDoubles.id,
                                           WorkoutLibrary.halfHyrox.id]),
        WorkoutGroup(title: "Partner", ids: [WorkoutLibrary.partnerWod1.id, WorkoutLibrary.partnerWod2.id]),
        WorkoutGroup(title: "Class", ids: [WorkoutLibrary.helen.id, WorkoutLibrary.rowThrusters.id,
                                           WorkoutLibrary.amrap20.id, WorkoutLibrary.amrap40.id]),
        WorkoutGroup(title: "Other", ids: [WorkoutLibrary.free.id])
    ]
}

/// First row of the Workouts tab: the workout the watch will run next.
struct NextWorkoutBar: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = WorkoutLibraryStore.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next workout on watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sentName)
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 2)
    }

    private var sentName: String {
        guard let id = link.sentWorkoutId else {
            return "Not chosen yet"
        }
        // A library workout removed since it was sent: still on the watch, name unknown here.
        guard let definition = library.definition(id: id) else {
            return id
        }
        return definition.name
    }
}

/// Today's library workouts, then the library by program (newest first, with the date), then the
/// built-in workouts by group; tap one to preview it and send it to the watch. Pull to refresh
/// the library (docs/WORKOUT_LIBRARY.md). The search button (top right) filters every section by
/// name, program, movements and type.
struct WorkoutChooserView: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = WorkoutLibraryStore.shared
    @ObservedObject private var store = WorkoutStore.shared
    /// Last score per definition id (newest result of the same workout), rebuilt when the
    /// results or the library change.
    @State private var lastScores: [String: String] = [:]
    @State private var query: String = ""
    @State private var searching: Bool = false

    var body: some View {
        List {
            let today: [LibraryWorkout] = filteredToday
            let groups: [LibraryGroup] = filteredGroups
            let builtIns: [WorkoutGroup] = filteredBuiltIns
            if !isSearching {
                Section {
                    NextWorkoutBar()
                }
            }
            if !today.isEmpty {
                Section("Today") {
                    ForEach(today) { (w: LibraryWorkout) in
                        libraryLink(w, detail: w.program)
                    }
                }
            }
            ForEach(groups) { (group: LibraryGroup) in
                Section(group.title) {
                    ForEach(group.workouts) { (w: LibraryWorkout) in
                        libraryLink(w, detail: w.dateLabel)
                    }
                }
            }
            ForEach(builtIns) { (section: WorkoutGroup) in
                Section(section.title) {
                    ForEach(section.ids, id: \.self) { id in
                        if let definition = WorkoutLibrary.definition(id: id) {
                            NavigationLink {
                                WorkoutPreviewView(definition: definition, meta: WorkoutCardMeta.text(nil))
                            } label: {
                                row(definition)
                            }
                        }
                    }
                }
            }
            if isSearching && today.isEmpty && groups.isEmpty && builtIns.isEmpty {
                Section {
                    Text("No workout matches \u{201C}" + trimmedQuery + "\u{201D}.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !isSearching {
                libraryStatus
            }
        }
        .searchable(text: $query, isPresented: $searching,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Name, program, movement, type")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search workouts")
            }
        }
        .refreshable {
            await library.refresh(force: true)
        }
        .task {
            await library.refresh()
        }
        .onReceive(store.$results) { (results: [WorkoutResult]) in
            lastScores = WorkoutLastScore.byDefinition(allDefinitions(library.workouts), results: results)
        }
        .onReceive(library.$workouts) { (workouts: [LibraryWorkout]) in
            lastScores = WorkoutLastScore.byDefinition(allDefinitions(workouts), results: store.results)
        }
        .navigationTitle("Workouts")
    }

    // MARK: Search

    private var trimmedQuery: String {
        return query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        return !trimmedQuery.isEmpty
    }

    private var filteredToday: [LibraryWorkout] {
        let q: String = trimmedQuery
        if q.isEmpty { return library.todayWorkouts }
        return library.todayWorkouts.filter { (w: LibraryWorkout) -> Bool in
            WorkoutSearch.matches(w.definition, program: w.program, query: q)
        }
    }

    private var filteredGroups: [LibraryGroup] {
        let q: String = trimmedQuery
        if q.isEmpty { return library.programGroups }
        var out: [LibraryGroup] = []
        for g in library.programGroups {
            let kept: [LibraryWorkout] = g.workouts.filter { (w: LibraryWorkout) -> Bool in
                WorkoutSearch.matches(w.definition, program: w.program ?? g.title, query: q)
            }
            if !kept.isEmpty {
                out.append(LibraryGroup(title: g.title, workouts: kept))
            }
        }
        return out
    }

    private var filteredBuiltIns: [WorkoutGroup] {
        let q: String = trimmedQuery
        if q.isEmpty { return WorkoutGroups.sections }
        var out: [WorkoutGroup] = []
        for g in WorkoutGroups.sections {
            let kept: [String] = g.ids.filter { (id: String) -> Bool in
                guard let d = WorkoutLibrary.definition(id: id) else { return false }
                return WorkoutSearch.matches(d, program: g.title, query: q)
            }
            if !kept.isEmpty {
                out.append(WorkoutGroup(title: g.title, ids: kept))
            }
        }
        return out
    }

    /// Library workouts and the built-ins shown here (for the last scores).
    private func allDefinitions(_ workouts: [LibraryWorkout]) -> [WorkoutDefinition] {
        var out: [WorkoutDefinition] = workouts.map { (w: LibraryWorkout) -> WorkoutDefinition in w.definition }
        for g in WorkoutGroups.sections {
            for id in g.ids {
                if let d = WorkoutLibrary.definition(id: id) {
                    out.append(d)
                }
            }
        }
        return out
    }

    private func libraryLink(_ w: LibraryWorkout, detail: String?) -> some View {
        NavigationLink {
            WorkoutPreviewView(definition: w.definition, meta: WorkoutCardMeta.text(w))
        } label: {
            row(w.definition, detail: detail)
        }
    }

    /// Last refresh, why it failed, rows that could not be read. The cached list stays usable.
    @ViewBuilder
    private var libraryStatus: some View {
        if !library.problems.isEmpty {
            Section("Library rows not shown") {
                ForEach(Array(library.problems.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption)
                }
            }
        }
        Section {
            if let error = library.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } footer: {
            Text(libraryFooter)
        }
    }

    private var libraryFooter: String {
        var text: String
        if let date = library.lastRefresh {
            text = "Library updated " + date.formatted(date: .abbreviated, time: .shortened) + "."
        } else {
            text = "Library not loaded yet."
        }
        if CloudConfig.isConfigured && !CloudAccount.shared.isSignedIn {
            text += " Sign in to get new workouts."
        } else {
            text += " Pull down to refresh."
        }
        return text
    }

    /// Compact card row: name, "date · block · type", one line of movements, last score.
    private func row(_ definition: WorkoutDefinition, detail: String? = nil) -> some View {
        WorkoutCardView(card: WorkoutCard.make(definition: definition), meta: detail,
                        style: WorkoutCardView.Style.compact,
                        lastScore: lastScores[definition.id],
                        isSent: link.sentWorkoutId == definition.id)
    }
}

/// The workout card (the whole preview), a big "Send to watch" button with its status, and a
/// collapsed list of every segment (for checking what the watch will step through).
struct WorkoutPreviewView: View {
    let definition: WorkoutDefinition
    /// Top-left of the card: "Mon, Nov 2 · PitFIRE", "Built-in".
    var meta: String? = nil
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var store = WorkoutStore.shared
    @State private var showSegments: Bool = false
    @State private var showAllResults: Bool = false

    /// "Your results" shows this many rows before "Show all".
    private static let resultRows: Int = 3

    private var isSent: Bool {
        return link.sentWorkoutId == definition.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkoutCardView(card: WorkoutCard.make(definition: definition), meta: meta,
                                style: WorkoutCardView.Style.full)

                historySection

                Button {
                    link.sendWorkout(definition)
                } label: {
                    HStack {
                        Spacer()
                        Label(isSent ? "Send again" : "Send to watch", systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                if let error = link.sendWorkoutError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isSent {
                    Text(sentText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !allSegments.isEmpty {
                    DisclosureGroup(isExpanded: $showSegments) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(allSegments.enumerated()), id: \.offset) { item in
                                segmentRow(index: item.offset, segment: item.element)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("All segments (\(allSegments.count))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Your results

    /// Past results of this workout, newest first (also those saved under another id for the
    /// same workout, WorkoutHistory); each row opens the report. Nothing when never done.
    @ViewBuilder
    private var historySection: some View {
        let history: [WorkoutResult] = store.history(of: definition)
        if !history.isEmpty {
            let shown: [WorkoutResult] = showAllResults ? history : Array(history.prefix(WorkoutPreviewView.resultRows))
            VStack(alignment: .leading, spacing: 0) {
                Text("Your results")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(WorkoutCardTheme.fg2)
                    .padding(.bottom, 6)
                ForEach(Array(shown.enumerated()), id: \.element.id) { item in
                    if item.offset > 0 {
                        Rectangle()
                            .fill(WorkoutCardTheme.border)
                            .frame(height: 1)
                    }
                    NavigationLink {
                        WorkoutDetailView(resultId: item.element.id)
                            .environmentObject(WorkoutStore.shared)
                    } label: {
                        WorkoutHistoryRow(result: item.element)
                    }
                    .buttonStyle(.plain)
                }
                if history.count > WorkoutPreviewView.resultRows {
                    Button {
                        showAllResults.toggle()
                    } label: {
                        Text(showAllResults ? "Show fewer" : "Show all " + String(history.count))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(WorkoutCardTheme.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(WorkoutCardTheme.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(WorkoutCardTheme.border, lineWidth: 1)
            )
        }
    }

    /// Every segment the watch steps through (rests included); none for the Free Workout.
    private var allSegments: [WorkoutSegment] {
        if definition.id == WorkoutLibrary.free.id {
            return []
        }
        return definition.segments
    }

    private func segmentRow(index: Int, segment: WorkoutSegment) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
            Circle()
                .fill(segment.kind == .run ? Theme.workoutRun : (segment.kind == .rest ? Color.gray : Theme.workoutStation))
                .frame(width: 8, height: 8)
            WorkoutCardView.lineText(WorkoutCard.segmentLine(segment))
                .font(.footnote)
            Spacer(minLength: 0)
        }
    }

    private var sentText: String {
        var text = "Sent ✓ It's on the watch's Workouts page"
        if link.isReachable {
            text += "."
        } else {
            text += " as soon as BarPath opens on the watch."
        }
        return text + " Tap START on the watch when you begin."
    }
}

/// One past result under a workout's preview: date, score, Rx / Scaled (only once answered:
/// nothing stores it yet), average heart rate.
struct WorkoutHistoryRow: View {
    let result: WorkoutResult

    var body: some View {
        let h: WorkoutSummary.Headline = WorkoutSummary.make(result: result, previous: nil, maxHeartRate: nil).headline
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(WorkoutResultCard.dateLabel(result.startDate))
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let avg = h.heartRateAvg {
                Text("\u{2665}\u{FE0E} " + SummaryFormat.bpm(avg))
                    .font(.system(size: 11.5))
                    .foregroundColor(WorkoutCardTheme.fg3)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityLabel("Average heart rate " + SummaryFormat.bpm(avg))
            }
            Text(WorkoutLastScore.text(h))
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(WorkoutCardTheme.fg3)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

/// Search in Choose: every word of the query must appear (case and accents ignored) in the
/// workout's name, short name, program or group, type and block tags, the card lines, or a
/// movement's names (as written, display name, card short names: "KB", "C&J", "Row").
enum WorkoutSearch {
    static func matches(_ d: WorkoutDefinition, program: String?, query: String) -> Bool {
        let words: [String] = query.split(whereSeparator: { (c: Character) -> Bool in c == " " || c == "\n" })
            .map { (w: Substring) -> String in String(w) }
        if words.isEmpty { return true }
        let text: String = haystack(d, program: program)
        for w in words where text.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            return false
        }
        return true
    }

    private static func haystack(_ d: WorkoutDefinition, program: String?) -> String {
        let card: WorkoutCard = WorkoutCard.make(definition: d)
        var parts: [String] = [d.name, d.shortName, card.name, card.summaryLine]
        if let p = program { parts.append(p) }
        if let t = card.typeTag { parts.append(t.label) }
        if let b = card.blockTag { parts.append(b.label) }
        if let domain = card.timeDomainLine { parts.append(domain) }
        var seen: Set<String> = []
        for s in d.segments where !seen.contains(s.movement) {
            seen.insert(s.movement)
            parts.append(s.name)
            parts.append(Movement.displayName(s.movement))
            if let one = Movement.shortName(s.movement, plural: false) { parts.append(one) }
            if let many = Movement.shortName(s.movement, plural: true) { parts.append(many) }
        }
        return parts.joined(separator: " | ")
    }
}
