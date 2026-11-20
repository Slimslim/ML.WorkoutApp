import SwiftUI
import BarPathKit

/// Session screen, no scrolling and display-only: one signal per state. Only READY fills
/// the screen (green); every other state is black with text. Between sets (#148) the Rest
/// screen counts up; a Crown turn arms the next set; tapping the weight changes it. Swipe left
/// (not during a set) for End and Change lift. In Data mode a Mark button and the data line
/// are added.
struct SessionView: View {
    @EnvironmentObject var model: SessionModel
    @ObservedObject private var link = PhoneLink.shared
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var confirmEnd = false
    @State private var editWeight = false
    @State private var page = 0
    @StateObject private var crown = CrownAdvanceController()
    @FocusState private var crownFocused: Bool

    /// The End page goes back to the main page by itself after this long (s).
    static let endPageTimeout: Double = 5.0

    var body: some View {
        TabView(selection: $page) {
            TimelineView(.periodic(from: Date(), by: 1.0)) { context in
                content(now: context.date)
            }
            .tag(0)
            if model.canShowEndPage {
                EndPageView(onEnd: {
                    confirmEnd = true
                }, onChange: {
                    page = 0
                    model.change()
                })
                .tag(1)
            }
        }
        .tabViewStyle(.page)
        .onChange(of: model.canShowEndPage) { _, canShow in
            if !canShow {
                page = 0
            }
        }
        .onChange(of: page) { _, newPage in
            if newPage == 0 {
                crownFocused = true
                return
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(SessionView.endPageTimeout * 1_000_000_000))
                if page == newPage && !confirmEnd {
                    page = 0
                }
            }
        }
        .sheet(isPresented: $editWeight, onDismiss: {
            crownFocused = true
        }, content: {
            RestWeightView {
                editWeight = false
            }
            .environmentObject(model)
        })
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
        if let since = SessionView.restSince(status) {
            restScreen(since: since, now: now)
        } else if status == .ready {
            readyScreen
        } else {
            darkScreen(status: status, now: now)
        }
    }

    // MARK: - Rest (#148): counts up; Crown turn = next set; tap the weight to change it

    private static func restSince(_ status: SessionModel.Status) -> Date? {
        if case .resting(let since) = status {
            return since
        }
        return nil
    }

    private func restScreen(since: Date, now: Date) -> some View {
        let rest = Color(red: 1.0, green: 0.84, blue: 0.04)
        return VStack(spacing: 2) {
            Text(restTopLine)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)
            Text("REST")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(rest)
            Text(SessionModel.formatElapsed(now.timeIntervalSince(since)))
                .font(.system(size: 52, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(rest)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Button {
                editWeight = true
            } label: {
                Text(model.useLoad ? model.loadText : "Weight")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(Capsule().fill(Color(white: 0.23)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)

            HStack {
                if !CrownSide.isLeft {
                    Spacer(minLength: 0)
                }
                Text(CrownSide.isLeft ? "\u{27F3} Turn Crown for next set" : "Turn Crown for next set \u{27F3}")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(SegmentPalette.crownForward)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if CrownSide.isLeft {
                    Spacer(minLength: 0)
                }
            }
            if model.isRecordingCSV {
                dataLine
            }
        }
        .padding(.horizontal, 2)
        .overlay {
            if !isLuminanceReduced && !crown.isBackward {
                CrownArcView(fraction: crown.fraction, isBackward: false)
                    .ignoresSafeArea()
            }
        }
        .focusable(!editWeight)
        .focused($crownFocused)
        .focusEffectDisabled()
        .digitalCrownRotation($crown.crownValue,
                              from: CrownAdvanceController.rangeMin,
                              through: CrownAdvanceController.rangeMax,
                              by: nil,
                              sensitivity: CrownAdvanceController.sensitivity,
                              isContinuous: true,
                              isHapticFeedbackEnabled: false)
        .onChange(of: crown.crownValue) { _, newValue in
            if editWeight || page != 0 {
                crown.ignore(newValue)
            } else {
                crown.crownChanged(to: newValue, onAdvance: {
                    model.armNextSet()
                }, onUndo: {})
            }
        }
        .onAppear {
            crownFocused = true
        }
    }

    private var restTopLine: String {
        let n = model.liftCount
        if model.isRepMode {
            if let reps = model.lastSetReps {
                return "\u{2713} Set \(n) \u{00B7} \(reps) rep\(reps == 1 ? "" : "s")"
            }
            return "\u{2713} Set \(n)"
        }
        if model.liftCount > model.savedLiftCount {
            return "Saving lift \(n)\u{2026}"
        }
        return "\u{2713} Lift \(n) saved"
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
                Text(countLine)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                footerRight(status: status, now: now)
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
                Text(savedLine)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.white)
        case .reps(let n):
            VStack(spacing: 0) {
                Text("\(n)")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundColor(.green)
                    .lineLimit(1)
                Text(n == 1 ? "rep" : "reps")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
            }
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
            if model.isRecordingCSV {
                dataLine
            }
        }
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
        return model.liftType.displayName + (model.useLoad ? " · " + model.loadText : "")
    }

    private func elapsedText(now: Date) -> Text {
        return Text(elapsed(now: now))
    }

    /// Armed for the next set: the rest just taken (#148); otherwise the session time.
    private func footerRight(status: SessionModel.Status, now: Date) -> Text {
        let armed = status == .waitingForSet || status == .ready || status == .walkToBar
        if armed && model.phase == .running, let rest = model.lastRestSeconds {
            return Text("rest " + SessionModel.formatElapsed(rest))
        }
        return elapsedText(now: now)
    }

    private var countLine: String {
        let n = model.liftCount
        let unit = model.isRepMode ? "set" : "lift"
        return "\(n) \(unit)\(n == 1 ? "" : "s")"
    }

    private var savedLine: String {
        var line = model.isRepMode ? "set saved" : "lift saved"
        if model.isRepMode, let reps = model.lastSetReps {
            line = "\(reps) rep\(reps == 1 ? "" : "s") · saved"
        }
        if link.pendingTransfers > 0 {
            line += " · ↑\(link.pendingTransfers)"
        }
        return line
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
        case .waitingForSet: return "Grip the\nbar"
        case .reps(let n): return "\(n) reps"
        case .resting: return "Rest"
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
            Text("\(liftCount) saved")
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

/// Swipe left from the main page (#148, not during a set): End and Change lift.
struct EndPageView: View {
    @EnvironmentObject var model: SessionModel
    let onEnd: () -> Void
    let onChange: () -> Void

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            VStack(spacing: 8) {
                Text("Session \u{00B7} " + elapsed(now: context.date))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Text(savedLine)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
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
                .disabled(model.phase == .ending)
                Button {
                    onChange()
                } label: {
                    Text("Change lift")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(Color(white: 0.23)))
                }
                .buttonStyle(.plain)
                .disabled(model.phase != .running)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }

    private var savedLine: String {
        let n = model.liftCount
        let unit = model.isRepMode ? "set" : "lift"
        return "\(n) \(unit)\(n == 1 ? "" : "s") saved"
    }

    private func elapsed(now: Date) -> String {
        guard let start = model.sessionStartDate else { return "0:00" }
        return SessionModel.formatElapsed(now.timeIntervalSince(start))
    }
}

/// Weight for the next set, at rest (#148 variant A): the Crown changes it (the unit's step,
/// detent haptic, as on the Load picker). Done, or 3 s without a change, goes back to Rest.
struct RestWeightView: View {
    @EnvironmentObject var model: SessionModel
    let onDone: () -> Void
    @FocusState private var focused: Bool
    @State private var lastChange = Date()

    /// Back to Rest after this long without a Crown change (s).
    static let idleClose: Double = 3.0

    private var crownValue: Binding<Double> {
        return Binding<Double>(get: { model.loadDisplay },
                               set: { (value: Double) in model.setLoadDisplay(value) })
    }

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            VStack(spacing: 6) {
                Text("Weight \u{00B7} next set")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Text(model.loadText)
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .focusable(true)
                    .focused($focused)
                    .digitalCrownRotation(crownValue,
                                          from: 0,
                                          through: model.weightUnit.maxLoad,
                                          by: model.weightUnit.step,
                                          sensitivity: .low,
                                          isContinuous: false,
                                          isHapticFeedbackEnabled: true)
                Text("Turn the Crown")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
                Button {
                    onDone()
                } label: {
                    Text("Done" + restSuffix(now: context.date))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(Color(white: 0.23)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .onAppear {
            focused = true
            lastChange = Date()
        }
        .onChange(of: model.loadKg) { _, _ in
            lastChange = Date()
            if !model.useLoad {
                model.useLoad = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                if Date().timeIntervalSince(lastChange) >= RestWeightView.idleClose {
                    onDone()
                    return
                }
            }
        }
    }

    private func restSuffix(now: Date) -> String {
        guard let since = model.restStartDate else { return "" }
        return " \u{00B7} rest " + SessionModel.formatElapsed(now.timeIntervalSince(since))
    }
}
