import SwiftUI
import BarPathKit

struct SessionRow: View {
    let session: LiftSessionGroup

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.liftTypesSummary)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(session.lifts.count) lift\(session.lifts.count == 1 ? "" : "s") · \(session.startDate.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let best = session.bestPeakVelocity {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(Fmt.mps(best)) m/s")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                    Text("best peak")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SessionDetailView: View {
    let sessionId: UUID
    @EnvironmentObject private var store: LiftStore
    @State private var liftToDelete: LiftEntry?

    private var confirmBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { liftToDelete != nil },
            set: { newValue in
                if !newValue { liftToDelete = nil }
            }
        )
    }

    var body: some View {
        Group {
            if let session = store.session(id: sessionId) {
                list(session)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(items: session.fileURLs) {
                                Label("Share session", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
            } else {
                ContentUnavailableView("Session deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this lift?",
                            isPresented: confirmBinding,
                            titleVisibility: .visible,
                            presenting: liftToDelete) { entry in
            Button("Delete lift \(entry.index)", role: .destructive) {
                store.delete(entry)
                liftToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                liftToDelete = nil
            }
        }
    }

    private func list(_ session: LiftSessionGroup) -> some View {
        List {
            Section {
                LabeledContent("Started", value: session.startDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Lifts", value: "\(session.lifts.count)")
                if let best = session.bestPeakVelocity {
                    LabeledContent("Best peak velocity", value: "\(Fmt.mps(best)) m/s")
                }
                ShareLink(items: session.fileURLs) {
                    Label("Share all lift files (\(session.lifts.count))", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text(session.liftTypesSummary)
            }
            Section {
                ForEach(session.lifts) { entry in
                    NavigationLink(value: LiftRoute(id: entry.id)) {
                        LiftRow(entry: entry)
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            liftToDelete = entry
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(Color.red)
                        ShareLink(item: entry.fileURL) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(Color.blue)
                    }
                }
            } header: {
                Text("Lifts")
            }
        }
        .listStyle(.insetGrouped)
    }
}
