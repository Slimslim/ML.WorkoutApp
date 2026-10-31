import SwiftUI
import WatchKit
import os
import BarPathKit

private let crownLog = Logger(subsystem: "BarPathWatch", category: "crown")

/// Digital Crown advance gesture (WORKOUT_SPEC §3).
///
/// The main page binds `crownValue` with `.digitalCrownRotation` and calls `crownChanged`
/// on every change. Turning forward through `crownThreshold` advances, backward undoes.
/// The accumulated amount resets after `idleReset` without movement; a `.click` plays at
/// half the threshold; input is ignored for `lockout` after any advance or undo.
@MainActor
final class CrownAdvanceController: ObservableObject {
    /// Sensitivity passed to `.digitalCrownRotation`. `.low` = most rotation per unit, the
    /// least likely to trigger from a bump against the wrist.
    static let sensitivity: DigitalCrownRotationalSensitivity = .low

    /// Crown "units" (change of the bound value) for ONE FULL TURN at `sensitivity`.
    /// Measured 2026-10-28 on a Series 12 (watchOS 27): one slow full turn = 5.59 units.
    /// To re-calibrate: turn exactly one full turn on the main page, then read `cr <n>` on
    /// page 2 (peak of the last gesture) or the "crown" log category.
    static let unitsPerTurn: Double = 5.6

    /// Advance/undo threshold in crown units: 0.8 of a full turn (0.6 felt too sensitive, 2026-10-29).
    static let crownThreshold: Double = 0.8 * unitsPerTurn

    /// Accumulated rotation resets after this long without movement (s).
    static let idleReset: Double = 0.8
    /// Crown input ignored for this long after any advance or undo (s).
    static let lockout: Double = 2.0

    /// Range of the bound value. Continuous (wraps), so the range only matters for the wrap
    /// correction in `crownChanged`.
    static let rangeMin: Double = 0
    static let rangeMax: Double = 1000

    /// Bound to `.digitalCrownRotation`.
    @Published var crownValue: Double = 500
    /// Signed rotation of the current gesture (crown units); drives the progress arc.
    @Published private(set) var accumulated: Double = 0
    /// Absolute peak of the last finished gesture (crown units), for calibration.
    @Published private(set) var lastPeak: Double = 0

    private var lastValue: Double = 500
    private var lastMove: Date = .distantPast
    private var lockedUntil: Date = .distantPast
    private var halfClicked = false
    private var gesturePeak: Double = 0
    private var idleTask: Task<Void, Never>?

    /// Fraction of the threshold reached (0...1) and direction, for the arc.
    var fraction: Double {
        return min(1.0, abs(accumulated) / CrownAdvanceController.crownThreshold)
    }
    var isBackward: Bool { accumulated < 0 }

    /// Crown changes while another control owns the Crown (the partial-reps picker): follow
    /// the value without counting it, so no advance/undo can fire and no jump is seen later.
    func ignore(_ newValue: Double) {
        lastValue = newValue
        resetGesture()
    }

    /// Call after any advance/undo that did not come from the Crown (press, buttons).
    func noteAction() {
        lockedUntil = Date().addingTimeInterval(CrownAdvanceController.lockout)
        resetGesture()
    }

    func crownChanged(to newValue: Double, model: WorkoutSessionModel) {
        let range = CrownAdvanceController.rangeMax - CrownAdvanceController.rangeMin
        var delta = newValue - lastValue
        lastValue = newValue
        // isContinuous wraps max → min: undo the jump.
        if delta > range / 2 { delta -= range }
        if delta < -range / 2 { delta += range }
        guard delta != 0 else { return }

        let now = Date()
        if now < lockedUntil {
            accumulated = 0
            return
        }
        if now.timeIntervalSince(lastMove) > CrownAdvanceController.idleReset {
            resetGesture()
        }
        lastMove = now
        // Reversing direction starts over from zero.
        if (accumulated > 0 && delta < 0) || (accumulated < 0 && delta > 0) {
            accumulated = 0
            halfClicked = false
        }
        accumulated += delta
        gesturePeak = max(gesturePeak, abs(accumulated))
        crownLog.debug("crown delta \(delta, format: .fixed(precision: 3)) acc \(self.accumulated, format: .fixed(precision: 3))")
        scheduleIdleReset()

        let threshold = CrownAdvanceController.crownThreshold
        if !halfClicked && abs(accumulated) >= threshold / 2 {
            halfClicked = true
            WKInterfaceDevice.current().play(.click)
        }
        if accumulated >= threshold {
            crownLog.info("crown advance at acc \(self.accumulated, format: .fixed(precision: 3)) (threshold \(threshold, format: .fixed(precision: 3)))")
            finishGesture()
            lockedUntil = now.addingTimeInterval(CrownAdvanceController.lockout)
            model.advance(source: .crown)
        } else if accumulated <= -threshold {
            crownLog.info("crown undo at acc \(self.accumulated, format: .fixed(precision: 3)) (threshold \(threshold, format: .fixed(precision: 3)))")
            finishGesture()
            lockedUntil = now.addingTimeInterval(CrownAdvanceController.lockout)
            model.undo(source: .crown)
        }
    }

    private func scheduleIdleReset() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(CrownAdvanceController.idleReset * 1_000_000_000))
            if Task.isCancelled { return }
            self?.finishGesture()
        }
    }

    private func finishGesture() {
        if gesturePeak > 0 {
            lastPeak = gesturePeak
            crownLog.info("crown gesture peak \(self.gesturePeak, format: .fixed(precision: 3)) units (threshold \(CrownAdvanceController.crownThreshold, format: .fixed(precision: 3)))")
        }
        resetGesture()
    }

    private func resetGesture() {
        idleTask?.cancel()
        idleTask = nil
        accumulated = 0
        halfClicked = false
        gesturePeak = 0
    }
}

/// Workout session: page 1 = main (Crown advance), page 2 = controls. No scrolling.
struct WorkoutSessionView: View {
    @EnvironmentObject var model: WorkoutSessionModel
    @StateObject private var crown = CrownAdvanceController()
    @State private var page = 0
    @State private var confirmEnd = false
    /// Bumped to make the main page take Crown focus again (e.g. after the End sheet).
    @State private var focusToken = 0

    var body: some View {
        Group {
            switch model.phase {
            case .starting:
                WorkoutStatusScreen(title: "Starting…", detail: model.selectedDefinition.shortName,
                                    buttonTitle: "Cancel",
                                    action: { model.end() })
            case .ending, .idle:
                WorkoutStatusScreen(title: "Saving…", detail: model.lastSummary ?? "",
                                    buttonTitle: nil, action: nil)
            case .running:
                TabView(selection: $page) {
                    WorkoutMainPage(crown: crown, isActivePage: page == 0, focusToken: focusToken)
                        .tag(0)
                    WorkoutControlsPage(crown: crown) {
                        confirmEnd = true
                    }
                    .tag(1)
                }
                .tabViewStyle(.page)
            }
        }
        .sheet(isPresented: $confirmEnd) {
            WorkoutEndConfirmView(progressText: progressText) {
                confirmEnd = false
                model.end()
            } onKeepGoing: {
                confirmEnd = false
                page = 0
                focusToken += 1
            }
        }
    }

    private var progressText: String {
        let p = model.progress
        let count = p.definition.segments.count
        if p.isFinished { return "Finished · \(count)/\(count)" }
        return "Segment \(p.currentIndex + 1)/\(count)"
    }
}

// MARK: - Page 1: main

struct WorkoutMainPage: View {
    @EnvironmentObject var model: WorkoutSessionModel
    @ObservedObject var crown: CrownAdvanceController
    let isActivePage: Bool
    let focusToken: Int
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @FocusState private var crownFocused: Bool

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            content(now: context.date)
        }
        .overlay {
            crownArc.allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        // While the partial-reps picker is up it owns the Crown: this page can't take focus.
        .focusable(!repsPickerActive)
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
            if repsPickerActive {
                crown.ignore(newValue)
            } else {
                crown.crownChanged(to: newValue, model: model)
            }
        }
        .onLongPressGesture(minimumDuration: 1.0) {
            if model.advance(source: .press) {
                crown.noteAction()
            }
        }
        .onAppear {
            crownFocused = !repsPickerActive
        }
        .onChange(of: isActivePage) { _, active in
            // Off page 1 the Crown must not advance/undo unseen: drop focus there.
            crownFocused = active && !repsPickerActive
        }
        .onChange(of: focusToken) { _, _ in
            crownFocused = !repsPickerActive
        }
        .onChange(of: isLuminanceReduced) { _, reduced in
            if !reduced && isActivePage && !repsPickerActive { crownFocused = true }
        }
        .onChange(of: repsPickerActive) { _, active in
            // Picker up (cap reached): hand the Crown over. Gone (Undo): take it back.
            if active {
                crownFocused = false
                crown.noteAction()
            } else if isActivePage {
                crownFocused = true
            }
        }
    }

    /// The done screen asks for the reps of the segment cut by the time cap (§5). While true,
    /// the Crown never advances/undoes this page (Undo stays on the button).
    private var repsPickerActive: Bool {
        return model.progress.isFinished && model.asksPartialReps
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if model.progress.isFinished {
            doneScreen(now: now)
        } else if isLuminanceReduced {
            alwaysOnScreen(now: now)
        } else if showSwitchFlash(now: now) {
            switchFlash()
        } else {
            mainScreen(now: now)
        }
    }

    /// For a moment after every switch, the new segment fills the screen so it's obvious
    /// where the watch is (added after the round-4 mix-up on 2026-10-30).
    static let switchFlashSeconds: Double = 1.8

    private func showSwitchFlash(now: Date) -> Bool {
        guard let last = model.lastChangeDate else { return false }
        return now.timeIntervalSince(last) < WorkoutMainPage.switchFlashSeconds
    }

    private func switchFlash() -> some View {
        let p = model.progress
        let isRun = p.currentSegment?.kind == .run
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("NOW")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(.secondary)
            Text(p.currentSegment?.title ?? "")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundColor(isRun ? .cyan : .orange)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.5)
            if let round = roundText() {
                Text(round)
                    .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
            Text("Turn Crown back to undo")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Round 4 · 2/4" for workouts with a repeating round, else nil.
    private func roundText() -> String? {
        let p = model.progress
        guard let size = p.definition.roundSize, size > 1, p.isStarted else { return nil }
        let i = p.currentIndex
        return "Round \(i / size + 1) · \(i % size + 1)/\(size)"
    }

    private var finishedByCap: Bool {
        return model.isFinishedByCap
    }

    // MARK: Normal

    private func mainScreen(now: Date) -> some View {
        let p = model.progress
        let nowT = now.timeIntervalSince1970
        return VStack(spacing: 2) {
            Text(topLine(now: now))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)

            Text(p.currentSegment?.title ?? "")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)

            if let clock = model.nextClockEvent(), !clock.isFinish {
                // Timed rest: count down to the next set (3-2-1 haptics on the watch model).
                Text(SessionModel.formatElapsed(max(0, clock.time - nowT).rounded(.up)))
                    .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(.yellow)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            } else {
                Text(SessionModel.formatElapsed(p.segmentElapsed(now: nowT)))
                    .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let clock = model.nextClockEvent(), clock.isFinish {
                    Text("Time cap in " + SessionModel.formatElapsed(max(0, clock.time - nowT).rounded(.up)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundColor(.yellow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }

            if let run = model.runLine(now: now) {
                Text(runText(run))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }

            Spacer(minLength: 0)

            if showUndoCapsule(now: now) {
                // Not a button: a palm on the screen right after a Crown turn undid a
                // correct switch (2026-10-30). Undo is the Crown turned backward.
                Text("Turn Crown back to undo")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minHeight: 34)
            } else {
                Text(nextText)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minHeight: 34)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Always-on

    private func alwaysOnScreen(now: Date) -> some View {
        let p = model.progress
        return VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(p.currentSegment?.title ?? "")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
            if let start = p.segmentStarts.last {
                // System-updated timer text: stays correct between always-on refreshes.
                Text(Date(timeIntervalSince1970: start), style: .timer)
                    .font(.system(size: 48, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Done

    private func doneScreen(now: Date) -> some View {
        let fill = isLuminanceReduced ? Color(red: 0.12, green: 0.50, blue: 0.23) : Color.green
        let ink = isLuminanceReduced ? Color.white : Color.black
        let total = model.progress.totalElapsed(now: now.timeIntervalSince1970)
        return ZStack {
            fill.ignoresSafeArea()
            // The picker stays in always-on too (dimmed), so a value being picked isn't reset.
            if repsPickerActive {
                capDoneContent(total: total, ink: ink)
            } else {
                finishedContent(total: total, ink: ink)
            }
        }
    }

    /// Finished by the cap: compact TIME line, the reps picker, Undo.
    private func capDoneContent(total: Double, ink: Color) -> some View {
        VStack(spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("TIME")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(SessionModel.formatElapsed(total))
                    .font(.system(size: 24, weight: .heavy, design: .rounded).monospacedDigit())
            }
            .foregroundColor(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            PartialRepsPicker(segmentName: model.partialRepsSegment?.name ?? "",
                              maxReps: model.partialRepsMax,
                              ink: ink,
                              wantsFocus: isActivePage)
            Spacer(minLength: 0)
            if !isLuminanceReduced {
                undoCapsule
            }
        }
        .padding(.horizontal, 4)
    }

    private func finishedContent(total: Double, ink: Color) -> some View {
        VStack(spacing: 4) {
            Spacer(minLength: 0)
            Text(finishedByCap ? "TIME" : "DONE")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(SessionModel.formatElapsed(total))
                .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            if !isLuminanceReduced {
                undoCapsule
                Text("Swipe left for End")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(ink.opacity(0.7))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Pieces

    private var undoCapsule: some View {
        Button {
            if model.undo(source: .button) {
                crown.noteAction()
            }
        } label: {
            Text("↶ Undo")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Capsule().fill(Color(white: 0.2)))
        }
        .buttonStyle(.plain)
    }

    /// Progress arc around the screen edge while turning (green forward, orange back).
    private var crownArc: some View {
        let fraction = crown.fraction
        let color: Color = crown.isBackward ? .orange : .green
        return RoundedRectangle(cornerRadius: 36, style: .continuous)
            .trim(from: 0, to: CGFloat(fraction))
            .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .opacity(fraction > 0 ? 1 : 0)
            .padding(2)
            .ignoresSafeArea()
    }

    private func showUndoCapsule(now: Date) -> Bool {
        guard let last = model.lastChangeDate else { return false }
        return now.timeIntervalSince(last) < WorkoutSessionModel.undoCapsuleSeconds
    }

    private func topLine(now: Date) -> String {
        let p = model.progress
        let count = p.definition.segments.count
        let index = min(p.currentIndex + 1, count)
        var position = "\(index)/\(count)"
        if let size = p.definition.roundSize, size > 1, p.isStarted {
            // AMRAP / rounds: "R4 2/4" says more than "13/40".
            position = "R\(p.currentIndex / size + 1) \(p.currentIndex % size + 1)/\(size)"
        }
        var parts: [String] = [position,
                               SessionModel.formatElapsed(p.totalElapsed(now: now.timeIntervalSince1970))]
        if let hr = model.heartRate {
            parts.append(String(format: "♥ %.0f", hr))
        } else if !model.healthKitRunning {
            parts.append("♥ –")
        }
        return parts.joined(separator: " · ")
    }

    private var nextText: String {
        if let next = model.progress.nextSegment {
            return "Next: " + next.title
        }
        return "Last segment"
    }

    private func runText(_ run: WorkoutSessionModel.RunLine) -> String {
        var parts: [String] = []
        if let d = run.distance {
            parts.append(String(format: "%.0f m", d))
        } else {
            parts.append("– m")
        }
        if let pace = run.paceSecondsPerKm {
            parts.append(WorkoutSessionModel.formatPace(pace) + "/km")
        }
        if let cadence = run.cadence {
            parts.append(String(format: "%.0f", cadence))
        }
        return parts.joined(separator: "  ")
    }
}

// MARK: - Partial reps picker (WORKOUT_SPEC §5)

/// "Reps of Double Unders?" on the done screen after the time cap. The number is picked with
/// the Digital Crown (this view takes Crown focus; the main page gives it up meanwhile), Save
/// is a deliberate tap. Editable until End; the model keeps the last saved value.
struct PartialRepsPicker: View {
    @EnvironmentObject var model: WorkoutSessionModel
    let segmentName: String
    let maxReps: Int
    let ink: Color
    /// Page 1 visible: take Crown focus (dropped on page 2 so it can't change unseen).
    let wantsFocus: Bool

    @State private var value: Double = 0
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var reps: Int {
        return min(max(0, Int(value.rounded())), upperBound)
    }

    private var upperBound: Int {
        return max(1, maxReps)
    }

    private var statusText: String {
        if let saved = model.partialReps {
            return "Saved · \(saved)"
        }
        return "Turn the Crown, then Save"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("Reps of \(segmentName)?")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 8) {
                Text("\(reps)")
                    .font(.system(size: 40, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(minWidth: 70, minHeight: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(ink.opacity(focused ? 0.9 : 0.35), lineWidth: 2)
                    )
                    .focusable(true)
                    .focused($focused)
                    .focusEffectDisabled()
                    .digitalCrownRotation($value,
                                          from: 0,
                                          through: Double(upperBound),
                                          by: 1,
                                          sensitivity: .medium,
                                          isContinuous: false,
                                          isHapticFeedbackEnabled: true)
                Button {
                    model.savePartialReps(reps)
                    focused = wantsFocus
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(minWidth: 62, minHeight: 40)
                        .background(Capsule().fill(Color.black.opacity(0.85)))
                }
                .buttonStyle(.plain)
            }
            Text(statusText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(ink.opacity(0.8))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .onAppear {
            if !loaded {
                loaded = true
                value = Double(model.partialReps ?? 0)
            }
            focused = wantsFocus
        }
        .onChange(of: wantsFocus) { _, want in
            focused = want
        }
    }
}

// MARK: - Page 2: controls

struct WorkoutControlsPage: View {
    @EnvironmentObject var model: WorkoutSessionModel
    @ObservedObject var crown: CrownAdvanceController
    @ObservedObject private var link = PhoneLink.shared
    let onEnd: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Button {
                onEnd()
            } label: {
                Text("End")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 1.0, green: 0.41, blue: 0.38))
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Capsule().fill(Color(white: 0.11)))
            }
            .buttonStyle(.plain)

            Button {
                if model.undo(source: .button) {
                    crown.noteAction()
                }
            } label: {
                Text("↶ Undo")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Capsule().fill(Color(white: 0.2)))
            }
            .buttonStyle(.plain)

            if model.isRecordingCSV {
                Button {
                    model.mark()
                } label: {
                    Label("Mark", systemImage: "flag.fill")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(Color.yellow))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)

            if let error = model.errorMessage {
                Text("⚠ " + error)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(dataStrip)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .padding(.horizontal, 4)
    }

    /// Samples, CSV size, pending transfers, last Crown gesture peak (calibration).
    private var dataStrip: String {
        var parts: [String] = []
        if model.isRecordingCSV {
            parts.append("\(SessionModel.formatCount(model.motionSamples)) smp")
            parts.append(String(format: "%.1f MB", Double(model.csvBytes) / 1_000_000))
        }
        if link.pendingTransfers > 0 {
            parts.append("↑\(link.pendingTransfers)")
        }
        parts.append(String(format: "cr %.1f/%.1f", crown.lastPeak, CrownAdvanceController.crownThreshold))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Starting / saving

struct WorkoutStatusScreen: View {
    let title: String
    let detail: String
    let buttonTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            if let buttonTitle = buttonTitle, let action = action {
                Button {
                    action()
                } label: {
                    Text(buttonTitle)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Capsule().fill(Color(white: 0.15)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - End confirmation

/// Full-screen "End workout?" with Keep going as the default (top, highlighted).
struct WorkoutEndConfirmView: View {
    let progressText: String
    let onEnd: () -> Void
    let onKeepGoing: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("End workout?")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(progressText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
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
