import SwiftUI
import BarPathKit

/// Session screen, no scrolling and display-only: one signal per state. Only READY fills
/// the screen (green); every other state is black with text. End is offered only while
/// walking to the bar; in Data mode a Mark button and the data line are added.
struct SessionView: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject private var link = PhoneLink.shared
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var confirmEnd = false

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            content(now: context.date)
        }
        .sheet(isPresented: $confirmEnd) {
            EndConfirmView(liftCount: model.liftCount) {
                confirmEnd = false
                model.end()
            } onKeepGoing: {
                confirmEnd = false
            }
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let status = model.status(at: now)
        if status == .ready {
            readyScreen
        } else {
            darkScreen(status: status, now: now)
        }
    }

    // MARK: - READY (the only bright screen)

    private var readyScreen: some View {
        let fill = isLuminanceReduced ? Color(red: 0.12, green: 0.50, blue: 0.23) : Color.green
        let ink = isLuminanceReduced ? Color.white : Color.black
        return ZStack {
            fill.ignoresSafeArea()
            VStack(spacing: 6) {
                Image(systemName: "dumbbell.fill")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(ink)
                Text("READY")
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .foregroundColor(ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(setupLine)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
    }

    // MARK: - Dark states

    private func darkScreen(status: SessionModel.Status, now: Date) -> some View {
        VStack(spacing: 4) {
            Text(setupLine)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)
            statusBlock(status)
            Spacer(minLength: 0)

            HStack {
                Text("\(model.liftCount) lift\(model.liftCount == 1 ? "" : "s")")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text(elapsed(now: now))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 6)

            if let error = model.errorMessage {
                Text("⚠ " + error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            bottomControls(status: status)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func statusBlock(_ status: SessionModel.Status) -> some View {
        switch status {
        case .saved(let index):
            VStack(spacing: 0) {
                Image(systemName: "checkmark")
                    .font(.system(size: 22, weight: .bold))
                Text("\(index)")
                    .font(.system(size: 52, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                Text(link.pendingTransfers > 0 ? "lift saved · ↑\(link.pendingTransfers)" : "lift saved")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.white)
        case .lifting:
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 12, height: 12)
                Text("LIFTING")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        default:
            Text(title(for: status))
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
        }
    }

    @ViewBuilder
    private func bottomControls(status: SessionModel.Status) -> some View {
        let canEnd = status == .walkToBar || status == .starting
        VStack(spacing: 3) {
            if model.isRecordingCSV {
                Button {
                    model.mark()
                } label: {
                    Label("Mark", systemImage: "flag.fill")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Capsule().fill(Color.yellow))
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .running)
            }
            if canEnd {
                HStack(spacing: 4) {
                    changeButton
                    endButton
                }
            }
            if model.isRecordingCSV {
                dataLine
            }
        }
    }

    /// Back to setup (new lift type / load) without ending the workout.
    private var changeButton: some View {
        Button {
            model.change()
        } label: {
            Text("Change")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(Color(white: 0.23)))
        }
        .buttonStyle(.plain)
        .disabled(model.phase != .running)
    }

    private var endButton: some View {
        Button {
            confirmEnd = true
        } label: {
            Text("End")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 1.0, green: 0.41, blue: 0.38))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(Color(white: 0.11)))
        }
        .buttonStyle(.plain)
        .disabled(model.phase == .ending)
    }

    /// Data mode line: samples recorded, CSV size, marks, pending transfers.
    private var dataLine: some View {
        var parts: [String] = []
        if model.phase == .running {
            parts.append("\(SessionModel.formatCount(model.motionSamples)) smp")
            parts.append("CSV " + SessionModel.formatBytes(model.csvBytes))
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
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }

    // MARK: - Helpers

    private var setupLine: String {
        return model.liftType.displayName + (model.useLoad ? " · " + LoadPickerView.format(model.loadLb) : "")
    }

    private func elapsed(now: Date) -> String {
        guard let start = model.sessionStartDate else { return "0:00" }
        return SessionModel.formatElapsed(now.timeIntervalSince(start))
    }

    private func title(for status: SessionModel.Status) -> String {
        switch status {
        case .starting: return "Starting…"
        case .walkToBar: return "Walk to\nthe bar"
        case .ready: return "READY"
        case .lifting: return "LIFTING"
        case .saving: return "Saving…"
        case .saved(let index): return "Lift \(index) saved"
        case .ending: return "Ending…"
        }
    }
}

/// Full-screen "End session?" with Keep going as the default (top, highlighted).
struct EndConfirmView: View {
    let liftCount: Int
    let onEnd: () -> Void
    let onKeepGoing: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("End session?")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
            Text("\(liftCount) lift\(liftCount == 1 ? "" : "s") sent")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
            Button {
                onKeepGoing()
            } label: {
                Text("Keep going")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color(white: 0.23)))
                    .overlay(Capsule().stroke(Color.white, lineWidth: 2))
            }
            .buttonStyle(.plain)
            Button {
                onEnd()
            } label: {
                Text("End")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.41, blue: 0.38))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Capsule().fill(Color(white: 0.11)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }
}
