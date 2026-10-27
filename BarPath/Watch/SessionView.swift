import SwiftUI
import BarPathKit

struct SessionView: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject private var link = PhoneLink.shared
    @State private var showLiftPicker = false
    @State private var confirmEnd = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            content(now: context.date)
        }
        .sheet(isPresented: $showLiftPicker) {
            LiftTypePickerView(selection: $model.liftType)
        }
        .confirmationDialog("End session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End Session", role: .destructive) {
                model.end()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let status = model.status(at: now)
        ScrollView {
            VStack(spacing: 6) {
                Text(title(for: status))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(color(for: status))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 56)

                Text(model.liftType.displayName + (model.useLoad ? " · " + LoadPickerView.format(model.loadLb) : ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 4) {
                    stat(value: "\(model.liftCount)", label: "lifts")
                    stat(value: elapsed(now: now), label: "time")
                    stat(value: heartRateText, label: "bpm")
                }

                dataLine

                HStack(spacing: 6) {
                    Button {
                        showLiftPicker = true
                    } label: {
                        Text("Lift")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(model.phase != .running)

                    Button {
                        model.mark()
                    } label: {
                        Text("Mark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .tint(.yellow)
                    .disabled(model.phase != .running || !model.isRecordingCSV)
                }

                Button(role: .destructive) {
                    confirmEnd = true
                } label: {
                    Text("End")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .tint(.red)
                .disabled(model.phase == .ending)

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// "Data is flowing" line: samples recorded, CSV size, marks, pending transfers.
    private var dataLine: some View {
        var parts: [String] = []
        if model.phase == .running {
            parts.append("\(SessionModel.formatCount(model.motionSamples)) smp")
            if model.isRecordingCSV {
                parts.append("CSV " + SessionModel.formatBytes(model.csvBytes))
            }
            if model.marksCount > 0 {
                parts.append("\(model.marksCount) mk")
            }
            if model.recorderMode == .fallback100Hz {
                parts.append("100 Hz")
            } else if model.recorderMode == .unavailable {
                parts.append("no sensors")
            }
        }
        if link.pendingTransfers > 0 {
            parts.append("↑\(link.pendingTransfers)")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption2.monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var heartRateText: String {
        if let hr = model.heartRate {
            return "\(Int(hr.rounded()))"
        }
        return "--"
    }

    private func elapsed(now: Date) -> String {
        guard let start = model.sessionStartDate else { return "0:00" }
        return SessionModel.formatElapsed(now.timeIntervalSince(start))
    }

    private func title(for status: SessionModel.Status) -> String {
        switch status {
        case .starting: return "Starting…"
        case .walkToBar: return "Walk to the bar"
        case .ready: return "Ready"
        case .lifting: return "Lifting…"
        case .saving: return "Saving…"
        case .saved(let index): return "Lift \(index) saved ✓"
        case .ending: return "Ending…"
        }
    }

    private func color(for status: SessionModel.Status) -> Color {
        switch status {
        case .ready: return .green
        case .lifting: return .orange
        case .saved: return .green
        case .saving: return .yellow
        case .starting, .ending: return .secondary
        case .walkToBar: return .primary
        }
    }
}
