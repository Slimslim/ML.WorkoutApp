import SwiftUI
import BarPathKit

/// Setup screen, no scrolling: Lift tile, Load tile, START. The top row shows whether the
/// phone is reachable and toggles Data mode (full-session CSV + Mark button in the session).
struct StartView: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject private var link = PhoneLink.shared
    @State private var confirmFinish = false

    private var isPaused: Bool { model.phase == .paused }

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                HStack {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(link.isReachable ? Color.green : Color.gray)
                            .frame(width: 6, height: 6)
                        Text(link.isReachable ? "Phone" : "Phone offline")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        model.debugRecording.toggle()
                    } label: {
                        Text("DATA")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundColor(model.debugRecording ? .black : .secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(model.debugRecording ? Color.yellow : Color(white: 0.18))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.debugRecording ? "Data mode on" : "Data mode off")
                }

                NavigationLink {
                    LiftTypePickerView(selection: $model.liftType)
                } label: {
                    SetupTile(label: "LIFT", value: model.liftType.displayName)
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LoadPickerView()
                } label: {
                    SetupTile(label: "LOAD",
                              value: model.useLoad ? LoadPickerView.format(model.loadLb) : "No load")
                }
                .buttonStyle(.plain)

                Button {
                    model.start()
                } label: {
                    Text(isPaused ? "CONTINUE" : "START")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Capsule().fill(Color.green))
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)

                if isPaused {
                    Button {
                        confirmFinish = true
                    } label: {
                        Text("Finish workout · \(model.liftCount) lift\(model.liftCount == 1 ? "" : "s")")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 1.0, green: 0.41, blue: 0.38))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .buttonStyle(.plain)
                } else if let error = model.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                } else if let summary = model.lastSummary {
                    Text("Last: \(summary)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $confirmFinish) {
            EndConfirmView(liftCount: model.liftCount) {
                confirmFinish = false
                model.end()
            } onKeepGoing: {
                confirmFinish = false
            }
        }
    }
}

/// A big tappable tile: small caps label over a large value, chevron on the right.
struct SetupTile: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11)))
    }
}

/// Big rows: Snatch, Clean & Jerk, then the variants (LiftType.allCases order).
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

/// Load in lbs: tap −5 / +5, or turn the Digital Crown (5 lb steps).
struct LoadPickerView: View {
    @EnvironmentObject var model: SessionModel
    @FocusState private var crownFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            Toggle("Log load", isOn: $model.useLoad)
                .font(.footnote)

            Text(LoadPickerView.format(model.loadLb))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundColor(model.useLoad ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .focusable(true)
                .focused($crownFocused)
                .digitalCrownRotation($model.loadLb,
                                      from: 0,
                                      through: 900,
                                      by: 5,
                                      sensitivity: .low,
                                      isContinuous: false,
                                      isHapticFeedbackEnabled: true)

            HStack(spacing: 8) {
                Button {
                    model.loadLb = max(0, model.loadLb - 5)
                    model.useLoad = true
                } label: {
                    Text("−5")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                Button {
                    model.loadLb = min(900, model.loadLb + 5)
                    model.useLoad = true
                } label: {
                    Text("+5")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        }
        .padding(.horizontal, 4)
        .navigationTitle("Load")
        .onAppear {
            crownFocused = true
        }
        .onChange(of: model.loadLb) { _, _ in
            if !model.useLoad {
                model.useLoad = true
            }
        }
    }

    static func format(_ lb: Double) -> String {
        return String(format: "%.0f lb", lb.rounded())
    }
}
