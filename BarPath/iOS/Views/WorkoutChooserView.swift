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
        guard let id = link.sentWorkoutId, let definition = WorkoutLibrary.definition(id: id) else {
            return "Not chosen yet"
        }
        return definition.name
    }
}

/// Built-in workouts by group; tap one to preview it and send it to the watch.
struct WorkoutChooserView: View {
    @ObservedObject private var link = PhoneLink.shared

    var body: some View {
        List {
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
        }
        .navigationTitle("Choose workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ definition: WorkoutDefinition) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.name)
                    .font(.body.weight(.semibold))
                Text(WorkoutGroups.summary(definition))
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
}

/// The segments of one workout and a big "Send to watch" button.
struct WorkoutPreviewView: View {
    let definition: WorkoutDefinition
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
                Text(WorkoutGroups.summary(definition))
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
