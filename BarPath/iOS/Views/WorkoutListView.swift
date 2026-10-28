import SwiftUI
import BarPathKit

struct WorkoutRoute: Hashable {
    let id: UUID
}

extension Theme {
    static let workoutRun = Color(red: 0.22, green: 0.45, blue: 1.00)
    static let workoutStation = accent
}

/// Time formatting for workouts: h:mm:ss / m:ss, pace m:ss/km.
enum WorkoutFmt {
    /// "1:02:03" from an hour on, otherwise "41:12".
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Always h:mm:ss (list rows and the detail header).
    static func hms(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func pace(_ secondsPerKm: Double) -> String {
        let total = Int(max(0, secondsPerKm).rounded())
        return String(format: "%d:%02d/km", total / 60, total % 60)
    }

    static func distance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.2f km", meters / 1000.0)
        }
        return String(format: "%.0f m", meters)
    }

    static func bpm(_ value: Double?) -> String {
        guard let value = value else { return "–" }
        return String(format: "%.0f", value)
    }
}

/// Finished workouts, newest first.
struct WorkoutListView: View {
    @EnvironmentObject private var store: WorkoutStore
    @State private var resultToDelete: WorkoutResult?

    private var confirmBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { resultToDelete != nil },
            set: { newValue in
                if !newValue { resultToDelete = nil }
            }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.results.isEmpty && store.problems.isEmpty {
                    ContentUnavailableView {
                        Label("No workouts yet", systemImage: "figure.run")
                    } description: {
                        Text("Finish a workout on your watch — results appear here")
                    }
                } else {
                    resultList
                }
            }
            .navigationTitle("Workouts")
            .navigationDestination(for: WorkoutRoute.self) { route in
                WorkoutDetailView(resultId: route.id)
            }
            .confirmationDialog("Delete this workout?",
                                isPresented: confirmBinding,
                                titleVisibility: .visible,
                                presenting: resultToDelete) { result in
                Button("Delete \(result.definition.name)", role: .destructive) {
                    store.delete(result)
                    resultToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    resultToDelete = nil
                }
            } message: { _ in
                Text("The result is removed from this iPhone. A motion recording stays in the Debug tab.")
            }
        }
    }

    private var resultList: some View {
        List {
            Section {
                ForEach(store.results) { result in
                    NavigationLink(value: WorkoutRoute(id: result.id)) {
                        WorkoutRow(result: result)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            resultToDelete = result
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Color.red)
                    }
                }
            }
            if !store.problems.isEmpty {
                Section("Unreadable files") {
                    ForEach(Array(store.problems.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

struct WorkoutRow: View {
    let result: WorkoutResult

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.definition.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(result.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(WorkoutFmt.hms(result.totalSeconds))
                    .font(.headline)
                    .monospacedDigit()
                Text("\(result.segments.count) segment\(result.segments.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
