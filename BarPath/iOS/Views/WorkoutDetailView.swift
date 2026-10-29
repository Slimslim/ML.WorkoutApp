import SwiftUI
import BarPathKit

/// Overview (score, heart rate, story, splits) and the share buttons for one workout.
struct WorkoutDetailView: View {
    let resultId: UUID
    @EnvironmentObject private var store: WorkoutStore

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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkoutOverviewView(result: result, previous: store.previousAttempt(before: result))
                    .id(result.id)
                WorkoutShareCard(result: result)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
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
