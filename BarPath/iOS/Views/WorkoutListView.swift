import SwiftUI
import Combine
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

/// The Workouts tab: the workout the watch runs next (first row, tap to choose), then the Log:
/// finished workouts newest first, each a compact done card (name, date · program · block · type,
/// one line of movements, score and Rx / Scaled badge on the right).
struct WorkoutListView: View {
    @EnvironmentObject private var store: WorkoutStore
    @ObservedObject private var library = WorkoutLibraryStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var resultToDelete: WorkoutResult?
    /// Score of each result, rebuilt when the results change (a summary per row is not free).
    @State private var scores: [UUID: WorkoutCardScore] = [:]

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
            resultList
                .navigationTitle("Workouts")
                // Library workouts added in the database (WorkoutLibraryStore skips refreshes
                // closer than a minute apart, and does nothing signed out).
                .task {
                    await WorkoutLibraryStore.shared.refresh()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        WorkoutLibraryStore.shared.refreshSoon()
                    }
                }
                .onReceive(store.$results) { (results: [WorkoutResult]) in
                    scores = WorkoutLastScore.byResult(results)
                }
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
                NextWorkoutBar()
            }
            if store.results.isEmpty && store.problems.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No workouts yet", systemImage: "figure.run")
                    } description: {
                        Text("Choose a workout above and send it to your watch. Results appear here when you finish.")
                    }
                }
            } else if !store.results.isEmpty {
                Section("Log") {
                    ForEach(store.results) { (result: WorkoutResult) in
                        NavigationLink(value: WorkoutRoute(id: result.id)) {
                            logRow(result)
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

    /// Compact done card (context c "Log" of docs/concepts/workout-cards.html).
    private func logRow(_ result: WorkoutResult) -> some View {
        let resolved: (definition: WorkoutDefinition, program: String?) =
            WorkoutResultCard.resolve(result, library: library.workouts)
        return WorkoutCardView(card: WorkoutCard.make(definition: resolved.definition),
                               meta: WorkoutResultCard.logMeta(result, program: resolved.program),
                               style: WorkoutCardView.Style.compact,
                               score: scores[result.id] ?? WorkoutLastScore.byResult([result])[result.id])
    }
}
