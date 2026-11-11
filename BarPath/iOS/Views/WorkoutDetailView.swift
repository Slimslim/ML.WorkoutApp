import SwiftUI
import BarPathKit

/// The report of one workout, then every split, the share buttons and Fix splits.
struct WorkoutDetailView: View {
    let resultId: UUID
    @EnvironmentObject private var store: WorkoutStore
    @ObservedObject private var library = WorkoutLibraryStore.shared
    @ObservedObject private var profile = AthleteProfile.shared
    @State private var fixingSplits = false

    var body: some View {
        Group {
            if let result = store.result(id: resultId) {
                content(result)
            } else {
                ContentUnavailableView("Workout deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ result: WorkoutResult) -> some View {
        let resolved: (definition: WorkoutDefinition, program: String?) =
            WorkoutResultCard.resolve(result, library: library.workouts)
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkoutReportView(result: result, previous: store.previousAttempt(before: result),
                                  card: WorkoutCard.make(definition: resolved.definition),
                                  meta: WorkoutResultCard.reportMeta(result, program: resolved.program),
                                  maxHeartRate: profile.maxHeartRate(results: store.results)?.value)
                    .id(result.id)
                NavigationLink {
                    ScrollView {
                        WorkoutOverviewView(result: result, previous: store.previousAttempt(before: result),
                                            maxHeartRate: profile.maxHeartRate(results: store.results)?.value,
                                            card: WorkoutCard.make(definition: resolved.definition),
                                            cardMeta: WorkoutResultCard.reportMeta(result, program: resolved.program))
                            .padding(16)
                    }
                    .background(Theme.pageBackground)
                    .navigationTitle("Every split")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    HStack {
                        Text("Every split")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .card()
                WorkoutShareCard(result: result)
                Button {
                    fixingSplits = true
                } label: {
                    Label("Fix splits", systemImage: "slider.horizontal.3")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .card()
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
        .sheet(isPresented: $fixingSplits) {
            FixSplitsView(original: result)
                .environmentObject(store)
        }
        .onAppear {
            WorkoutViewed.markIfNewest(result, in: store.results)
        }
    }
}

// MARK: - Share

struct WorkoutShareCard: View {
    let result: WorkoutResult

    var body: some View {
        let jsonURL: URL = WorkoutFiles.fileURL(id: result.id)
        let csvURL: URL? = WorkoutFiles.csvURL(for: result)
        VStack(alignment: .leading, spacing: 12) {
            ShareLink(item: jsonURL) {
                Label("Share result (JSON)", systemImage: "square.and.arrow.up")
            }
            if let csvURL = csvURL {
                ShareLink(item: csvURL) {
                    Label("Share motion recording (CSV)", systemImage: "waveform.path.ecg")
                }
            } else if result.recordingFileName != nil {
                Text("The motion recording has not arrived on this iPhone yet (or was deleted from Debug).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .card()
    }
}
