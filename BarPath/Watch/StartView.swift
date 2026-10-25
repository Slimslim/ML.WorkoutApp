import SwiftUI
import BarPathKit

struct StartView: View {
    @EnvironmentObject var model: SessionModel

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    LiftTypePickerView(selection: $model.liftType)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lift")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(model.liftType.displayName)
                            .font(.headline)
                    }
                    .padding(.vertical, 6)
                }

                NavigationLink {
                    LoadPickerView()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Load")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(model.useLoad ? LoadPickerView.format(model.loadKg) : "None")
                            .font(.headline)
                    }
                    .padding(.vertical, 6)
                }

                Button {
                    model.start()
                } label: {
                    Text("Start")
                        .font(.title3.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .listRowBackground(Color.clear)

                Toggle(isOn: $model.debugRecording) {
                    Text("Record full session (debug)")
                        .font(.footnote)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .listRowBackground(Color.clear)
                }

                if let summary = model.lastSummary {
                    Text("Last session: \(summary)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("BarPath")
        }
    }
}

/// Big rows: Snatch, Clean & Jerk, then the variants (LiftType.allCases order).
/// Used both from the start screen (pushed) and from the session screen (sheet).
struct LiftTypePickerView: View {
    @Binding var selection: LiftType
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            ForEach(LiftType.allCases) { type in
                Button {
                    selection = type
                    dismiss()
                } label: {
                    HStack {
                        Text(type.displayName)
                            .font(.headline)
                        Spacer()
                        if type == selection {
                            Image(systemName: "checkmark")
                                .foregroundColor(.green)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Lift")
    }
}

/// Load in kg with the Digital Crown (0.5 kg steps) plus ±5 buttons.
struct LoadPickerView: View {
    @EnvironmentObject var model: SessionModel
    @FocusState private var crownFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Toggle("Log load", isOn: $model.useLoad)
                .font(.footnote)

            Text(LoadPickerView.format(model.loadKg))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(model.useLoad ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .focusable(true)
                .focused($crownFocused)
                .digitalCrownRotation($model.loadKg,
                                      from: 0,
                                      through: 400,
                                      by: 0.5,
                                      sensitivity: .medium,
                                      isContinuous: false,
                                      isHapticFeedbackEnabled: true)

            HStack(spacing: 8) {
                Button {
                    model.loadKg = max(0, model.loadKg - 5)
                    model.useLoad = true
                } label: {
                    Text("−5")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                Button {
                    model.loadKg = min(400, model.loadKg + 5)
                    model.useLoad = true
                } label: {
                    Text("+5")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle("Load")
        .onAppear {
            crownFocused = true
        }
        .onChange(of: model.loadKg) { _, _ in
            if !model.useLoad {
                model.useLoad = true
            }
        }
    }

    static func format(_ kg: Double) -> String {
        if kg.rounded() == kg {
            return String(format: "%.0f kg", kg)
        }
        return String(format: "%.1f kg", kg)
    }
}
