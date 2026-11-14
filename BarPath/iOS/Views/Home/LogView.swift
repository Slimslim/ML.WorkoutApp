import SwiftUI
import BarPathKit

/// Lifts and workouts together, by day, newest first (story N4). Rows open the existing reports;
/// swipe to delete asks first.
struct LogView: View {
    @EnvironmentObject private var workouts: WorkoutStore
    @EnvironmentObject private var lifts: LiftStore
    @ObservedObject private var library = WorkoutLibraryStore.shared
    @State private var effortDays: [String: WorkoutEffort.Day] = [:]
    @State private var scores: [UUID: WorkoutCardScore] = [:]
    @State private var resultToDelete: WorkoutResult?
    @State private var sessionToDelete: LiftSessionGroup?

    private enum Entry: Identifiable {
        case workout(WorkoutResult)
        case session(LiftSessionGroup)

        var id: UUID {
            switch self {
            case .workout(let r): return r.id
            case .session(let s): return s.id
            }
        }

        var date: Date {
            switch self {
            case .workout(let r): return r.startDate
            case .session(let s): return s.startDate
            }
        }
    }

    private struct DayEntries: Identifiable {
        let id: Date
        let entries: [Entry]
    }

    private var days: [DayEntries] {
        let calendar = Calendar.current
        var all: [Entry] = workouts.results.map { (r: WorkoutResult) -> Entry in Entry.workout(r) }
        all += lifts.sessions.map { (s: LiftSessionGroup) -> Entry in Entry.session(s) }
        all.sort { (a: Entry, b: Entry) -> Bool in a.date > b.date }
        var order: [Date] = []
        var byDay: [Date: [Entry]] = [:]
        for e in all {
            let day: Date = calendar.startOfDay(for: e.date)
            if byDay[day] == nil {
                order.append(day)
                byDay[day] = []
            }
            byDay[day]?.append(e)
        }
        return order.map { (d: Date) -> DayEntries in DayEntries(id: d, entries: byDay[d] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if workouts.results.isEmpty && lifts.sessions.isEmpty && workouts.problems.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing logged yet", systemImage: "list.bullet")
                    } description: {
                        Text("Workouts and lifts appear here when you finish them on your watch.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Log")
            .navigationDestination(for: WorkoutRoute.self) { route in
                WorkoutDetailView(resultId: route.id)
            }
            .navigationDestination(for: SessionRoute.self) { route in
                SessionDetailView(sessionId: route.id)
            }
            .navigationDestination(for: LiftRoute.self) { route in
                LiftDetailView(liftId: route.id)
            }
            .onReceive(workouts.$results) { (results: [WorkoutResult]) in
                effortDays = EffortDays.make(results)
                scores = WorkoutLastScore.byResult(results)
            }
            .onReceive(AthleteProfile.shared.$revision) { (_: Int) in
                effortDays = EffortDays.make(workouts.results)
            }
            .confirmationDialog("Delete this workout?",
                                isPresented: isDeletingResult,
                                titleVisibility: .visible,
                                presenting: resultToDelete) { (result: WorkoutResult) in
                Button("Delete \(result.definition.name)", role: .destructive) {
                    workouts.delete(result)
                    resultToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    resultToDelete = nil
                }
            } message: { _ in
                Text("The result is removed from this iPhone. A motion recording stays in Debug tools.")
            }
            .confirmationDialog("Delete this session?",
                                isPresented: isDeletingSession,
                                titleVisibility: .visible,
                                presenting: sessionToDelete) { (session: LiftSessionGroup) in
                Button("Delete \(session.lifts.count) lift(s)", role: .destructive) {
                    lifts.deleteSession(session)
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToDelete = nil
                }
            } message: { _ in
                Text("The lift files are removed from this iPhone.")
            }
        }
    }

    private var isDeletingResult: Binding<Bool> {
        return Binding<Bool>(
            get: { resultToDelete != nil },
            set: { newValue in
                if !newValue { resultToDelete = nil }
            }
        )
    }

    private var isDeletingSession: Binding<Bool> {
        return Binding<Bool>(
            get: { sessionToDelete != nil },
            set: { newValue in
                if !newValue { sessionToDelete = nil }
            }
        )
    }

    private var list: some View {
        List {
            ForEach(days) { (day: DayEntries) in
                Section {
                    ForEach(day.entries) { (entry: Entry) in
                        row(entry)
                    }
                } header: {
                    HStack {
                        Text(WorkoutResultCard.dateLabel(day.id))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Text(effortText(day.id))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                }
            }
            if !workouts.problems.isEmpty {
                Section("Unreadable files") {
                    ForEach(Array(workouts.problems.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 90, for: .scrollContent)
        .refreshable {
            // Story W17: pull down to fetch results corrected in the cloud.
            await CloudAccount.shared.refreshNow()
        }
    }

    private func effortText(_ day: Date) -> String {
        guard let e = effortDays[LibraryDay.string(day)]?.effort else { return "\u{2014}" }
        return "Effort " + EffortDays.text(e)
    }

    @ViewBuilder
    private func row(_ entry: Entry) -> some View {
        switch entry {
        case .workout(let r):
            NavigationLink(value: WorkoutRoute(id: r.id)) {
                lined(LineSegment.done(r)) { workoutRow(r) }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    resultToDelete = r
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Color.red)
            }
        case .session(let s):
            NavigationLink(value: SessionRoute(id: s.id)) {
                lined(LineSegment.session(s)) { SessionRow(session: s) }
            }
            .swipeActions(edge: .trailing) {
                Button {
                    sessionToDelete = s
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(Color.red)
            }
        }
    }

    private func lined<Content: View>(_ segments: [LineSegment], @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                BlockLine(segments: segments)
            }
    }

    private func workoutRow(_ result: WorkoutResult) -> some View {
        let resolved: (definition: WorkoutDefinition, program: String?) =
            WorkoutResultCard.resolve(result, library: library.workouts)
        return WorkoutCardView(card: WorkoutCard.make(definition: resolved.definition),
                               meta: resolved.program,
                               style: WorkoutCardView.Style.compact,
                               score: scores[result.id] ?? WorkoutLastScore.byResult([result])[result.id])
    }
}
