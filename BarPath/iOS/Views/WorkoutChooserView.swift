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
    @ObservedObject private var store = WorkoutStore.shared
    /// Last score per definition id (newest result), rebuilt when the results change.
    @State private var lastScores: [String: String] = [:]

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
                                WorkoutPreviewView(definition: definition, meta: WorkoutCardMeta.text(nil))
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
        .onReceive(store.$results) { (results: [WorkoutResult]) in
            lastScores = WorkoutLastScore.byDefinitionId(results)
        }
        .navigationTitle("Choose workout")
        .navigationBarTitleDisplayMode(.inline)
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
    @State private var showSegments: Bool = false

    private var isSent: Bool {
        return link.sentWorkoutId == definition.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                WorkoutCardView(card: WorkoutCard.make(definition: definition), meta: meta,
                                style: WorkoutCardView.Style.full)

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
            Text(segment.title + (segment.load.map { (l: SegmentLoad) -> String in " · " + l.text } ?? ""))
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
