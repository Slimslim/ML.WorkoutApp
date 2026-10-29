import SwiftUI
import BarPathKit

/// Lifts tab: pick the lift and the load for the next block and send them to the watch.
/// The watch shows them on its Lifting page (or the Change screen), ready to START.
struct LiftChooserView: View {
    @EnvironmentObject private var link: PhoneLink
    @AppStorage("liftChooser.liftType") private var liftRaw: String = LiftType.snatch.rawValue
    @AppStorage("liftChooser.useLoad") private var useLoad: Bool = true
    @AppStorage("liftChooser.loadLb") private var loadLb: Double = 135

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
                                                    loadLb: useLoad ? loadLb : nil,
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
                    Text("Opens BarPath on the watch with this lift and load set. Press START there. During a session, tap Change on the watch first, then send.")
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
                Text(link.sentLift?.summary ?? "Not sent yet")
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
            Text(String(format: "%.0f lb", loadLb))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                ForEach([-45.0, -10.0, -5.0, 5.0, 10.0, 45.0], id: \.self) { step in
                    Button {
                        loadLb = min(900, max(0, loadLb + step))
                    } label: {
                        Text(step > 0 ? String(format: "+%.0f", step) : String(format: "−%.0f", -step))
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
