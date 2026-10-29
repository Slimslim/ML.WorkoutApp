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
                                           WorkoutLibrary.amrap20.id]),
        WorkoutGroup(title: "Test", ids: [WorkoutLibrary.quickTest.id])
    ]

    static func summary(_ definition: WorkoutDefinition) -> String {
        let count = definition.segments.count
        var text = "\(count) segment\(count == 1 ? "" : "s")"
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

            Section("Segments") {
                ForEach(Array(definition.segments.enumerated()), id: \.offset) { item in
                    HStack(spacing: 10) {
                        Text("\(item.offset + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Circle()
                            .fill(item.element.kind == .run ? Theme.workoutRun : (item.element.kind == .rest ? Color.gray : Theme.workoutStation))
                            .frame(width: 8, height: 8)
                        Text(item.element.title)
                    }
                }
            }
        }
        .navigationTitle(definition.name)
        .navigationBarTitleDisplayMode(.inline)
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
