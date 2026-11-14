import SwiftUI
import BarPathKit

/// Lifts tab: pick the lift and the load for the next block and send them to the watch.
/// The watch shows them on its Lifting page (or the Change screen), ready to START.
struct LiftChooserView: View {
    @EnvironmentObject private var link: PhoneLink
    @AppStorage("liftChooser.liftType") private var liftRaw: String = LiftType.snatch.rawValue
    @AppStorage("liftChooser.useLoad") private var useLoad: Bool = true
    /// The load is kept in kilograms (-1 = not chosen yet); shown and stepped in the weight unit.
    @AppStorage("liftChooser.loadKg") private var loadKgStored: Double = -1
    /// Pounds stored by older builds, read until a kilogram value is chosen.
    @AppStorage("liftChooser.loadLb") private var legacyLoadLb: Double = 0
    @ObservedObject private var profile = AthleteProfile.shared

    private var unit: WeightUnit {
        return profile.weightUnit
    }

    private var loadKg: Double {
        if loadKgStored >= 0 { return loadKgStored }
        if legacyLoadLb > 0 { return WeightUnit.kilograms(fromPounds: legacyLoadLb) }
        return unit.kilograms(fromDisplay: unit.defaultLoad)
    }

    private var stepValues: [Double] {
        return unit == .kg ? [-20.0, -5.0, -2.5, 2.5, 5.0, 20.0] : [-45.0, -10.0, -5.0, 5.0, 10.0, 45.0]
    }

    /// "Snatch · 62.5 kg" in the weight unit (the selection carries pounds on the wire).
    private var sentSummary: String {
        guard let sent = link.sentLift else { return "Not sent yet" }
        guard let lb = sent.loadLb else { return sent.liftType.displayName }
        return sent.liftType.displayName + " \u{00B7} " + unit.format(kilograms: WeightUnit.kilograms(fromPounds: lb))
    }

    private func stepLabel(_ step: Double) -> String {
        let size: Double = abs(step)
        let number: String = size == size.rounded() ? String(format: "%.0f", size) : String(format: "%.1f", size)
        return (step > 0 ? "+" : "\u{2212}") + number
    }

    private var liftType: LiftType {
        return LiftType(rawValue: liftRaw) ?? .snatch
    }

    private static let olympic: [LiftType] = [.snatch, .cleanAndJerk, .powerSnatch, .hangSnatch,
                                              .powerClean, .hangClean, .clean, .jerk]
    private static let strength: [LiftType] = [.deadlift]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sentRow
                }
                Section("Olympic lifts · bar path per lift") {
                    ForEach(LiftChooserView.olympic) { type in
                        liftRow(type)
                    }
                }
                Section("Strength · reps per set") {
                    ForEach(LiftChooserView.strength) { type in
                        liftRow(type)
                    }
                }
                Section("Load") {
                    Toggle("Log load", isOn: $useLoad)
                    if useLoad {
                        loadEditor
                    }
                }
                Section {
                    Button {
                        link.sendLift(LiftSelection(liftType: liftType,
                                                    loadLb: useLoad ? WeightUnit.pounds(fromKilograms: loadKg) : nil,
                                                    sentAt: Date().timeIntervalSince1970))
                    } label: {
                        Label("Send to watch", systemImage: "applewatch")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    if let error = link.sendLiftError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                    }
                } footer: {
                    Text("Opens Rx Lab on the watch with this lift and load set. Press START there. During a session it is used at your next Change on the watch.")
                }
            }
            .navigationTitle("Lifts")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    WatchStatusChip()
                }
            }
        }
    }

    private var sentRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next lift on watch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(sentSummary)
                    .font(.headline)
            }
        }
    }

    private func liftRow(_ type: LiftType) -> some View {
        Button {
            liftRaw = type.rawValue
        } label: {
            HStack {
                Text(type.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if type == liftType {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private var loadEditor: some View {
        VStack(spacing: 10) {
            Text(unit.format(kilograms: loadKg))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ForEach(stepValues, id: \.self) { step in
                    Button {
                        loadKgStored = unit.kilograms(adding: step, toKilograms: loadKg)
                    } label: {
                        Text(stepLabel(step))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
