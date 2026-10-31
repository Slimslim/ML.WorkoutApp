import SwiftUI
import BarPathKit

/// Sheet to correct split boundaries (and the partial reps after an AMRAP cap) of one workout.
/// Works on a local copy; Save writes it through WorkoutStore.saveEdited.
struct FixSplitsView: View {
    let original: WorkoutResult
    @EnvironmentObject private var store: WorkoutStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkoutResult
    @State private var confirmRestore = false

    init(original: WorkoutResult) {
        self.original = original
        _draft = State(initialValue: original)
    }

    private var isAmrap: Bool {
        return draft.definition.format == .amrap
    }

    private var maxPartialReps: Int {
        if let t = draft.definition.segments.last?.target, t.unit == .reps, t.value >= 1 {
            return Int(t.value)
        }
        return 200
    }

    private var partialBinding: Binding<Int> {
        return Binding<Int>(
            get: { return draft.partialReps ?? 0 },
            set: { (newValue: Int) in
                draft.setPartialReps(newValue)
            })
    }

    /// Median duration per movement id, over the draft's segments.
    private func median(for movement: String) -> Double {
        var values: [Double] = []
        for s in draft.segments where s.movement == movement {
            values.append(s.duration)
        }
        values.sort()
        if values.isEmpty { return 0 }
        let mid = values.count / 2
        if values.count % 2 == 1 { return values[mid] }
        return (values[mid - 1] + values[mid]) / 2
    }

    private func isTooShort(_ s: SegmentResult) -> Bool {
        return s.duration < 5
    }

    private func isTooLong(_ s: SegmentResult) -> Bool {
        var count = 0
        for o in draft.segments where o.movement == s.movement { count += 1 }
        if count < 3 { return false }
        let m = median(for: s.movement)
        return m > 0 && s.duration > 2 * m
    }

    private var workoutStart: Double {
        return draft.startDate.timeIntervalSince1970
    }

    private static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func originalDuration(_ position: Int) -> Double? {
        if position >= 0 && position < original.segments.count {
            return original.segments[position].duration
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(draft.segments.indices, id: \.self) { (i: Int) in
                        segmentRow(i)
                    }
                } header: {
                    Text("Segments")
                } footer: {
                    Text("Moving a start shifts the boundary with the previous segment.")
                }
                if isAmrap {
                    Section("Reps after the cap") {
                        Stepper(value: partialBinding, in: 0...maxPartialReps) {
                            Text("\(draft.partialReps ?? 0) reps")
                                .monospacedDigit()
                        }
                    }
                }
                if WorkoutFiles.hasOriginal(id: draft.id) {
                    Section {
                        Button("Restore original", role: .destructive) {
                            confirmRestore = true
                        }
                    }
                }
            }
            .navigationTitle("Fix splits")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveEdited(draft)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Restore the original splits from the watch?",
                                isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Restore original", role: .destructive) {
                    _ = store.restoreOriginal(id: draft.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func segmentRow(_ i: Int) -> some View {
        let s: SegmentResult = draft.segments[i]
        let short = isTooShort(s)
        let long = !short && isTooLong(s)
        let flagged = short || long
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(i + 1)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .leading)
                Text(s.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("start " + FixSplitsView.clock(s.start - workoutStart))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text(FixSplitsView.clock(s.duration))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(flagged ? Color.orange : Color.primary)
                }
            }
            if short {
                Text("too short?").font(.caption).foregroundStyle(Color.orange)
            } else if long {
                Text("too long?").font(.caption).foregroundStyle(Color.orange)
            }
            if let before = originalDuration(i), abs(before - s.duration) >= 0.5 {
                let diff = s.duration - before
                Text(String(format: "%@%.0f s (was %@)", diff >= 0 ? "+" : "-", abs(diff),
                            FixSplitsView.clock(before)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if i >= 1 {
                HStack(spacing: 8) {
                    nudge(i, -5)
                    nudge(i, -1)
                    nudge(i, 1)
                    nudge(i, 5)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func nudge(_ i: Int, _ delta: Double) -> some View {
        let label = delta > 0 ? "+\(Int(delta)) s" : "\u{2212}\(Int(-delta)) s"
        return Button {
            let current = draft.segments[i].start
            draft.moveSegmentStart(index: i, to: current + delta)
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
