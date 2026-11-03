import SwiftUI
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

    /// Round length when every segment repeats the first round (by title and kind), else nil.
    /// HYROX (different stations each round) is not repeating; a cut last round is fine.
    static func repeatingRoundSize(_ definition: WorkoutDefinition) -> Int? {
        guard let r = definition.roundSize, r >= 1, definition.segments.count > r else { return nil }
        let segs: [WorkoutSegment] = definition.segments
        for i in r..<segs.count {
            let first: WorkoutSegment = segs[i % r]
            if segs[i].title != first.title || segs[i].kind != first.kind { return nil }
        }
        return r
    }

    /// "Each round · as many rounds as possible in 40:00", "3 rounds of", "Every 3:00 · 6 sets of", "Segments".
    static func roundHeader(_ definition: WorkoutDefinition) -> String {
        if definition.id == WorkoutLibrary.free.id {
            return "No plan: turn the Crown at each change (new movement, set or rest), End when done"
        }
        guard let r = repeatingRoundSize(definition) else { return "Segments" }
        let rounds: Int = (definition.segments.count + r - 1) / r
        if definition.format == .amrap, let cap = definition.timeCapSeconds {
            return "Each round · as many rounds as you can in " + WorkoutFmt.clock(cap)
        }
        if let interval = definition.intervalSeconds {
            return "Every " + WorkoutFmt.clock(interval) + " · \(rounds) sets of"
        }
        return "\(rounds) rounds of"
    }

    static func summary(_ definition: WorkoutDefinition) -> String {
        if definition.id == WorkoutLibrary.free.id {
            return "No plan · Crown at each change"
        }
        let count = definition.segments.count
        var text = "\(count) segment\(count == 1 ? "" : "s")"
        if let r = repeatingRoundSize(definition) {
            if definition.format == .amrap {
                text = "\(r) per round"
            } else {
                let rounds: Int = (count + r - 1) / r
                text = "\(rounds) rounds of \(r)"
            }
        }
        if definition.runCount > 0 {
            text += " · \(definition.runCount) run\(definition.runCount == 1 ? "" : "s")"
        }
        if let cap = definition.timeCapSeconds {
            text += " · cap \(WorkoutFmt.clock(cap))"
        }
        return text
    }
}

/// Top of the Workouts tab: the workout the watch will run next, with a button to change it.
struct NextWorkoutBar: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = WorkoutLibraryStore.shared

    var body: some View {
        NavigationLink {
            WorkoutChooserView()
        } label: {
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
                Spacer()
                Text("Choose")
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .buttonStyle(.plain)
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
/// the library (docs/WORKOUT_LIBRARY.md).
struct WorkoutChooserView: View {
    @ObservedObject private var link = PhoneLink.shared
    @ObservedObject private var library = WorkoutLibraryStore.shared

    var body: some View {
        List {
            if !library.todayWorkouts.isEmpty {
                Section("Today") {
                    ForEach(library.todayWorkouts) { (w: LibraryWorkout) in
                        libraryLink(w, detail: w.program)
                    }
                }
            }
            ForEach(library.programGroups) { (group: LibraryGroup) in
                Section(group.title) {
                    ForEach(group.workouts) { (w: LibraryWorkout) in
                        libraryLink(w, detail: w.dateLabel)
                    }
                }
            }
            ForEach(WorkoutGroups.sections) { (section: WorkoutGroup) in
                Section(section.title) {
                    ForEach(section.ids, id: \.self) { id in
                        if let definition = WorkoutLibrary.definition(id: id) {
                            NavigationLink {
                                WorkoutPreviewView(definition: definition)
                            } label: {
                                row(definition)
                            }
                        }
                    }
                }
            }
            libraryStatus
        }
        .refreshable {
            await library.refresh(force: true)
        }
        .task {
            await library.refresh()
        }
        .navigationTitle("Choose workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func libraryLink(_ w: LibraryWorkout, detail: String?) -> some View {
        NavigationLink {
            WorkoutPreviewView(definition: w.definition, note: w.caption)
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

    private func row(_ definition: WorkoutDefinition, detail: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.name)
                    .font(.body.weight(.semibold))
                Text(rowCaption(definition, detail: detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if link.sentWorkoutId == definition.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private func rowCaption(_ definition: WorkoutDefinition, detail: String?) -> String {
        let summary: String = WorkoutGroups.summary(definition)
        if let detail = detail, !detail.isEmpty {
            return detail + " · " + summary
        }
        return summary
    }
}

/// The segments of one workout and a big "Send to watch" button.
struct WorkoutPreviewView: View {
    let definition: WorkoutDefinition
    /// Library workouts: "Mayhem · Mon, Nov 2".
    var note: String? = nil
    @ObservedObject private var link = PhoneLink.shared

    private var isSent: Bool {
        return link.sentWorkoutId == definition.id
    }

    var body: some View {
        List {
            Section {
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
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                if let error = link.sendWorkoutError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                } else if isSent {
                    Text(sentText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(footerText)
            }

            Section {
                ForEach(Array(shownSegments.enumerated()), id: \.offset) { item in
                    HStack(spacing: 10) {
                        Text("\(item.offset + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Circle()
                            .fill(item.element.kind == .run ? Theme.workoutRun : (item.element.kind == .rest ? Color.gray : Theme.workoutStation))
                            .frame(width: 8, height: 8)
                        Text(item.element.title + (item.element.load.map { " · " + $0.text } ?? ""))
                    }
                }
            } header: {
                Text(WorkoutGroups.roundHeader(definition))
            }
        }
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// One round when the workout repeats the same round (AMRAP 40, Helen…), else every segment.
    private var shownSegments: [WorkoutSegment] {
        if definition.id == WorkoutLibrary.free.id {
            return []
        }
        if let r = WorkoutGroups.repeatingRoundSize(definition) {
            return Array(definition.segments.prefix(r))
        }
        return definition.segments
    }

    private var footerText: String {
        let summary: String = WorkoutGroups.summary(definition)
        if let note = note, !note.isEmpty {
            return note + " · " + summary
        }
        return summary
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
