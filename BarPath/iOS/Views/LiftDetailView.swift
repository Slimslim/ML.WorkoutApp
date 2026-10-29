import SwiftUI
import BarPathKit

struct LiftDetailView: View {
    let liftId: UUID
    @EnvironmentObject private var store: LiftStore
    @Environment(\.dismiss) private var dismiss
    @State private var compareWithPrevious = true
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let entry = store.entry(id: liftId) {
                detail(entry)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            ShareLink(item: entry.fileURL) {
                                Label("Share lift file", systemImage: "square.and.arrow.up")
                            }
                            Button(role: .destructive) {
                                confirmDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .confirmationDialog("Delete lift \(entry.index)?",
                                        isPresented: $confirmDelete,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            store.delete(entry)
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    }
            } else {
                ContentUnavailableView("Lift deleted", systemImage: "trash")
            }
        }
        .navigationTitle(titleText)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var titleText: String {
        if let entry = store.entry(id: liftId) {
            return "\(entry.isSet ? "Set" : "Lift") \(entry.index)"
        }
        return "Lift"
    }

    private func detail(_ entry: LiftEntry) -> some View {
        let previous = store.previousLift(before: entry)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    LiftTitle(entry: entry)
                    if previous != nil && entry.display != nil {
                        Toggle("Compare with previous lift", isOn: $compareWithPrevious)
                            .font(.subheadline)
                    }
                    LiftAnalysisContent(entry: entry, previous: compareWithPrevious ? previous : nil)
                }
                .card()

                if let d = entry.display, !d.segments.isEmpty {
                    segmentsCard(d)
                }

                infoCard(entry)
                limitationsCard
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
    }

    private func segmentsCard(_ d: LiftDisplay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Segments")
                .font(.headline)
            Text("Motion between still points. Drift fix = velocity error removed at the closing still point (smaller is better).")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(d.segments.enumerated()), id: \.offset) { item in
                let seg = item.element
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Segment \(item.offset + 1)")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Fmt.seconds(seg.duration))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text("peak \(Fmt.mps(seg.peakVerticalVelocity)) m/s · gain \(Fmt.signedCm(seg.heightGain)) cm · range \(Fmt.cm(seg.minHeight))–\(Fmt.cm(seg.maxHeight)) cm · drift fix \(Fmt.mps(seg.driftCorrection)) m/s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if item.offset < d.segments.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }

    private func infoCard(_ entry: LiftEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recording")
                .font(.headline)
            LabeledContent("Lift type", value: entry.liftType.displayName)
            LabeledContent("Load", value: Fmt.load(entry.loadKg) ?? "—")
            LabeledContent("Started", value: entry.startDate.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Watch end reason", value: Labels.endReason(entry.endReason))
            if let d = entry.display {
                LabeledContent("Duration", value: Fmt.seconds(d.metrics.duration))
                LabeledContent("Final height", value: "\(Fmt.cm(d.metrics.finalHeight)) cm")
            }
            LabeledContent("File", value: entry.fileURL.lastPathComponent)
                .font(.caption)
        }
        .font(.subheadline)
        .card()
    }

    private var limitationsCard: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Labels.knownLimitations, id: \.self) { text in
                    Label(text, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Known limitations")
                .font(.subheadline.weight(.semibold))
        }
        .card()
    }
}
