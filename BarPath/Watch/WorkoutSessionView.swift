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
        let demo: String = model.isDemo ? "Demo · " : ""
        if p.isFinished { return demo + "Finished · \(count)/\(count)" }
        return demo + "Segment \(p.currentIndex + 1)/\(count)"
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
            // Crown-turn arc: on the race border's line, drawn on top of it. Hidden wrist down.
            if !isLuminanceReduced {
                CrownArcView(fraction: crown.fraction, isBackward: crown.isBackward)
                    .ignoresSafeArea()
            }
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
        } else {
            ZStack {
                // Race progress border (layout D+). Full screen, behind the text.
                RaceBorderView(state: borderState(now: now), isAlwaysOn: isLuminanceReduced)
                    .ignoresSafeArea()
                // Wrist down: the SAME main layout, dimmed, with system-rendered clocks
                // (athlete feedback 2026-11-01: glance without raising the arm). No NOW flash.
                if !isLuminanceReduced && showSwitchFlash(now: now) {
                    switchFlash()
                } else {
                    mainScreen(now: now)
                        .opacity(isLuminanceReduced ? WorkoutMainPage.alwaysOnOpacity : 1.0)
                }
            }
        }
    }

    /// For a moment after every switch, the new segment fills the screen so it's obvious
    /// where the watch is (added after the round-4 mix-up on 2026-10-30).
    static let switchFlashSeconds: Double = 1.8
    /// "Turn Crown back to undo" replaces the bottom line for this long after a switch.
    static let undoHintSeconds: Double = 5.0
    /// Share of a run's target distance from which the bottom turns into "Exit soon".
    static let exitSoonFraction: Double = 0.85
    /// Stations without a measurable target fill the current slice against this nominal
    /// time and stop at `stationMaxFraction` until the athlete switches.
    static let stationNominalSeconds: Double = 180.0
    static let stationMaxFraction: Double = 0.9
    /// AMRAP border: time toward the cap, one slit every 5 minutes.
    static let amrapTickSeconds: Double = 300.0
    /// Wrist down the main layout is drawn at this opacity (same layout, dimmer).
    static let alwaysOnOpacity: Double = 0.8
    /// The layout is drawn for 45 mm (≈ 198 pt wide); smaller screens scale down a little.
    static let designWidth: CGFloat = 198.0

    static func layoutScale(width: CGFloat) -> CGFloat {
        guard width > 0 else { return 1.0 }
        return min(1.0, max(0.8, width / WorkoutMainPage.designWidth))
    }

    private func showSwitchFlash(now: Date) -> Bool {
        guard let last = model.lastChangeDate else { return false }
        return now.timeIntervalSince(last) < WorkoutMainPage.switchFlashSeconds
    }

    private func showUndoHint(now: Date) -> Bool {
        guard let last = model.lastChangeDate else { return false }
        return now.timeIntervalSince(last) < WorkoutMainPage.undoHintSeconds
    }

    private func switchFlash() -> some View {
        let p: WorkoutProgress = model.progress
        let name: String = (p.currentSegment?.name ?? "").uppercased()
        let isLong: Bool = name.count > 11
        return VStack(spacing: 6) {
            Spacer(minLength: 0)
            Text("NOW")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(.secondary)
            Text(name)
                .font(.system(size: isLong ? 26 : 32, weight: .heavy, design: .rounded))
                .foregroundColor(currentColor)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
            Text(positionText())
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            Text("Turn Crown back to undo")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.92)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Round 4 · 2/4" for workouts with a repeating round, else "3/5".
    private func positionText() -> String {
        if let round = roundText() {
            return round
        }
        let p: WorkoutProgress = model.progress
        let count: Int = p.definition.segments.count
        return "\(min(p.currentIndex + 1, count))/\(count)"
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

    // MARK: Segment colour and progress

    /// The current segment's colour (name, border slice, NOW flash): see `SegmentPalette`.
    private var currentColor: Color {
        return SegmentPalette.color(forSegmentAt: model.progress.currentIndex, in: model.progress.definition)
    }

    /// Run with a metre target: pedometer distance into the segment / target (0…1). Nil when
    /// not on such a run or no distance yet.
    private func runFraction(now: Date) -> Double? {
        guard let segment = model.progress.currentSegment, segment.kind == .run,
              let target = segment.target, target.unit == .meters, target.value > 0,
              let run = model.runLine(now: now), let distance = run.distance else { return nil }
        return min(1.0, max(0.0, distance / target.value))
    }

    /// How far into the current segment (0…1), for its border slice.
    private func currentSegmentFraction(now: Date) -> Double {
        let p: WorkoutProgress = model.progress
        guard let segment = p.currentSegment else { return 0 }
        let nowT: Double = now.timeIntervalSince1970
        let elapsed: Double = p.segmentElapsed(now: nowT)
        let nominal: Double = min(WorkoutMainPage.stationMaxFraction,
                                  elapsed / WorkoutMainPage.stationNominalSeconds)
        switch segment.kind {
        case .run:
            return runFraction(now: now) ?? 0
        case .rest:
            // Rest on the clock: time toward the next set.
            if let clock = model.nextClockEvent(), !clock.isFinish, let start = p.segmentStarts.last {
                let span: Double = clock.time - start
                if span > 0 {
                    return min(1.0, max(0.0, (nowT - start) / span))
                }
            }
            // Clock suppressed (after an undo) or the cap comes first: use the rest's own time.
            if let target = segment.target, target.unit == .seconds, target.value > 0 {
                return min(1.0, elapsed / target.value)
            }
            return nominal
        case .station, .transition:
            if let target = segment.target, target.unit == .seconds, target.value > 0 {
                return min(1.0, elapsed / target.value)
            }
            // No counter yet (reps, metres on an erg): nominal time, parked at 90 %.
            return nominal
        }
    }

    private func borderState(now: Date) -> RaceBorderState {
        let p: WorkoutProgress = model.progress
        let definition: WorkoutDefinition = p.definition
        if definition.format == .amrap, let cap = definition.timeCapSeconds, cap > 0 {
            // Screen demo: the cap is shortened (WorkoutDemo.timeScale), so are the slits.
            let tick: Double = model.isDemo
                ? WorkoutMainPage.amrapTickSeconds / WorkoutDemo.timeScale
                : WorkoutMainPage.amrapTickSeconds
            return RaceBorderState.timeToCap(elapsed: p.totalElapsed(now: now.timeIntervalSince1970),
                                             cap: cap,
                                             tick: tick,
                                             color: SegmentPalette.elapsed)
        }
        return RaceBorderState.segments(colors: SegmentPalette.segmentColors(for: definition),
                                        currentIndex: p.currentIndex,
                                        currentFraction: currentSegmentFraction(now: now))
    }

    // MARK: Normal

    private func mainScreen(now: Date) -> some View {
        GeometryReader { (geo: GeometryProxy) in
            mainStack(now: now, scale: WorkoutMainPage.layoutScale(width: geo.size.width))
        }
    }

    private func mainStack(now: Date, scale: CGFloat) -> some View {
        let p: WorkoutProgress = model.progress
        let name: String = (p.currentSegment?.name ?? "").uppercased()
        let isLong: Bool = name.count > 11
        return VStack(spacing: 0) {
            Text(name)
                .font(.system(size: (isLong ? 19 : 24) * scale, weight: .heavy, design: .rounded))
                .foregroundColor(currentColor)
                .multilineTextAlignment(.center)
                .lineLimit(isLong ? 2 : 1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                totalText(now: now)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.92)
                if model.isDemo {
                    DemoTag()
                }
            }
            .padding(.top, 2)

            Spacer(minLength: 0)

            timerText(now: now, scale: scale)
            metricRow(now: now, scale: scale)

            Spacer(minLength: 0)

            bottomLine(now: now)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Segment time, or the countdown to the next set during a timed rest (and during every
    /// segment of an interval workout, whose sets start on the clock).
    private func timerText(now: Date, scale: CGFloat) -> some View {
        return timerValue(now: now)
            .font(.system(size: 54 * scale, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundColor(SegmentPalette.elapsed)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    /// Wrist down the clock is a system timer text: watchOS keeps it ticking every second in
    /// always-on, while this view's own refresh (`now`) may come only once a minute.
    private func timerValue(now: Date) -> Text {
        let p: WorkoutProgress = model.progress
        if isLuminanceReduced, let start = p.segmentStarts.last {
            if let clock = model.nextClockEvent(), !clock.isFinish {
                return WorkoutMainPage.liveCountDown(from: start, to: clock.time)
            }
            return WorkoutMainPage.liveCountUp(from: start)
        }
        let nowT: Double = now.timeIntervalSince1970
        var seconds: Double = p.segmentElapsed(now: nowT)
        if let clock = model.nextClockEvent(), !clock.isFinish {
            // Timed rest, or any segment of an interval workout: count down to the next set
            // (3-2-1 haptics on the watch model).
            seconds = max(0, clock.time - nowT).rounded(.up)
        }
        return Text(SessionModel.formatElapsed(seconds))
    }

    // MARK: Live clocks (always-on)

    /// Upper bound of a live count-up clock's range (it stops there).
    static let liveCountUpLimit: TimeInterval = 24 * 3600

    /// Count-up clock ("12:34", "1:02:03") rendered by the system, live in always-on.
    static func liveCountUp(from start: Double) -> Text {
        let from: Date = Date(timeIntervalSince1970: start)
        // Bounded (not `Date.distantFuture`): the timer text may size itself for the longest
        // value in its range; 24 h keeps that to "23:59:59".
        let range: ClosedRange<Date> = from...from.addingTimeInterval(WorkoutMainPage.liveCountUpLimit)
        return Text(timerInterval: range, countsDown: false)
    }

    /// Countdown to `end` rendered by the system, live in always-on; stops at 0:00.
    /// `start` is only the range's lower bound (clamped so the range is never inverted).
    static func liveCountDown(from start: Double, to end: Double) -> Text {
        let to: Date = Date(timeIntervalSince1970: end)
        let from: Date = Date(timeIntervalSince1970: min(start, end))
        let range: ClosedRange<Date> = from...to
        return Text(timerInterval: range, countsDown: true)
    }

    /// One row under the timer: the key metric, then HR.
    private func metricRow(now: Date, scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            keyMetric(now: now, scale: scale)
            valueWithUnit(heartRateValue, unit: "bpm", color: SegmentPalette.heartRate, scale: scale)
        }
        .lineLimit(1)
        // "12:40 /KM" + "152 BPM" is wider than the 156 pt content width on 41 mm.
        .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func keyMetric(now: Date, scale: CGFloat) -> some View {
        if let segment = model.progress.currentSegment {
            if segment.kind == .run {
                valueWithUnit(paceValue(now: now), unit: "/km", color: SegmentPalette.run, scale: scale)
            } else if segment.kind == .station, let target = segment.target {
                // Until rep counting exists: the target ("100 reps", "1000 m") in white.
                Text(target.text)
                    .font(.system(size: 20 * scale, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(.white)
            }
        }
    }

    private func valueWithUnit(_ value: String, unit: String, color: Color, scale: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: 22 * scale, weight: .heavy, design: .rounded).monospacedDigit())
            Text(unit.uppercased())
                .font(.system(size: 11, weight: .heavy, design: .rounded))
        }
        .foregroundColor(color)
    }

    private var heartRateValue: String {
        if let hr = model.heartRate {
            return String(format: "%.0f", hr)
        }
        return "–"
    }

    private func paceValue(now: Date) -> String {
        if let run = model.runLine(now: now), let pace = run.paceSecondsPerKm {
            return WorkoutSessionModel.formatPace(pace)
        }
        return "–:––"
    }

    /// `totalLine` as a Text; wrist down the clock in it is a system timer (live in always-on).
    private func totalText(now: Date) -> Text {
        let p: WorkoutProgress = model.progress
        guard isLuminanceReduced, let start = p.startTime else {
            return Text(totalLine(now: now))
        }
        if let cap = p.capTime {
            var prefix: String = ""
            if let size = p.definition.roundSize, size > 1 {
                prefix = "R\(p.currentIndex / size + 1) · "
            }
            let clock: Text = WorkoutMainPage.liveCountDown(from: start, to: cap)
            return Text(verbatim: prefix) + clock + Text(verbatim: " left")
        }
        return WorkoutMainPage.liveCountUp(from: start)
    }

    /// Small line under the name: total race time; AMRAP: round and time left to the cap.
    private func totalLine(now: Date) -> String {
        let p: WorkoutProgress = model.progress
        let nowT: Double = now.timeIntervalSince1970
        if let cap = p.capTime {
            let left: String = SessionModel.formatElapsed(max(0, cap - nowT).rounded(.up)) + " left"
            if let size = p.definition.roundSize, size > 1 {
                return "R\(p.currentIndex / size + 1) · " + left
            }
            return left
        }
        return SessionModel.formatElapsed(p.totalElapsed(now: nowT))
    }

    /// Undo hint for 5 s after a switch, else "Exit soon" near the end of a run, else Next.
    /// Wrist down there is no undo hint: `now` may be up to a minute old there, and the Crown
    /// is not in use with the arm down.
    @ViewBuilder
    private func bottomLine(now: Date) -> some View {
        if !isLuminanceReduced && showUndoHint(now: now) {
            // Not a button: a palm on the screen right after a Crown turn undid a correct
            // switch (2026-10-30). Undo is the Crown turned backward.
            bottomText("Turn Crown back to undo")
        } else if let fraction = runFraction(now: now), fraction >= WorkoutMainPage.exitSoonFraction {
            exitSoonBanner
        } else {
            bottomText(nextText)
        }
    }

    private var nextText: String {
        if let next = model.progress.nextSegment {
            return "Next: " + next.title
        }
        return "Last segment"
    }

    private func bottomText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.92)
            .frame(maxWidth: .infinity, minHeight: 30)
    }

    /// Wrist down: same banner, outlined instead of a solid blue fill (always-on stays dark).
    private var exitSoonBanner: some View {
        let next: String = model.progress.nextSegment?.title ?? "Finish"
        let dim: Bool = isLuminanceReduced
        return Text("Exit soon · Next: " + next)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundColor(dim ? SegmentPalette.run : SegmentPalette.ink)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.92)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(dim ? Color.clear : SegmentPalette.run))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(dim ? SegmentPalette.run : Color.clear, lineWidth: 1.5))
            // 22 pt from the screen edge as in the design: a full-width box crosses the border
            // in the rounded bottom corners.
            .padding(.horizontal, 12)
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
                capDoneContent(total: total, ink: ink, now: now)
            } else {
                finishedContent(total: total, ink: ink, now: now)
            }
        }
    }

    /// Finished by the cap: compact TIME line, one recovery line, the reps picker, Undo.
    private func capDoneContent(total: Double, ink: Color, now: Date) -> some View {
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
            if let elapsed = model.recoveryElapsed(now: now) {
                compactRecoveryLine(elapsed: elapsed)
                    .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(ink.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
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

    /// DONE / TIME and the total on one line, the recovery block (time since the finish,
    /// HR now and its drop since the finish), Undo and the End hint. Fits 41 mm: one 26 pt line,
    /// a two-line block, the 34 pt capsule and up to two 11 pt lines.
    private func finishedContent(total: Double, ink: Color, now: Date) -> some View {
        let elapsed: Double = model.recoveryElapsed(now: now) ?? 0
        let recoveryDone: Bool = elapsed >= WorkoutMainPage.recoveryTargetSeconds
        return VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(finishedByCap ? "TIME" : "DONE")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                Text(SessionModel.formatElapsed(total))
                    .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
            }
            .foregroundColor(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
            recoveryBlock(elapsed: elapsed)
            Spacer(minLength: 0)
            if !isLuminanceReduced {
                undoCapsule
            }
            Text(endHint(recoveryDone: recoveryDone))
                .font(.system(size: 11, weight: recoveryDone ? .heavy : .semibold, design: .rounded))
                .foregroundColor(ink.opacity(recoveryDone ? 0.9 : 0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 4)
    }

    // MARK: Recovery (WORKOUT_SPEC §6)

    /// "3 min recovery done" from here; the model plays the haptics (1:00, 2:00, 3:00).
    static let recoveryTargetSeconds: Double = 180.0

    private func endHint(recoveryDone: Bool) -> String {
        let demo: String = model.isDemo ? "Demo · " : ""
        if recoveryDone {
            return demo + "3 min recovery done · End when ready"
        }
        return demo + "Swipe left for End"
    }

    /// Dark panel (like the Undo capsule) with the D+ colours: yellow recovery clock, red HR,
    /// lime drop. In always-on the clock is a system timer text (stays right between refreshes).
    private func recoveryBlock(elapsed: Double) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("RECOVERY")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(Color(white: 0.75))
                recoveryClock(elapsed: elapsed)
                    .font(.system(size: 18, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundColor(SegmentPalette.elapsed)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(heartRateValue)
                        .font(.system(size: 26, weight: .heavy, design: .rounded).monospacedDigit())
                    Text("BPM")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                }
                .foregroundColor(SegmentPalette.heartRate)
                if let drop = model.recoveryDrop {
                    // Drop since the finish: "−19" when HR went down.
                    Text(SummaryFormat.signedNumber(-drop))
                        .font(.system(size: 22, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundColor(drop >= 0 ? SegmentPalette.crownForward : SegmentPalette.crownBackward)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(isLuminanceReduced ? 0.6 : 0.85)))
        .opacity(isLuminanceReduced ? 0.85 : 1.0)
    }

    /// Wrist down a system timer text (live in always-on); else from `elapsed`.
    private func recoveryClock(elapsed: Double) -> Text {
        if isLuminanceReduced, let finish = model.progress.finishTime {
            return WorkoutMainPage.liveCountUp(from: finish)
        }
        return Text(SessionModel.formatElapsed(elapsed))
    }

    /// `compactRecoveryText` as a Text; wrist down the clock in it is a system timer.
    private func compactRecoveryLine(elapsed: Double) -> Text {
        guard isLuminanceReduced, elapsed < WorkoutMainPage.recoveryTargetSeconds else {
            return Text(compactRecoveryText(elapsed: elapsed))
        }
        var tail: String = " · " + heartRateValue + " bpm"
        if let drop = model.recoveryDrop {
            tail += " " + SummaryFormat.signedNumber(-drop)
        }
        return Text(verbatim: "Recovery ") + recoveryClock(elapsed: elapsed) + Text(verbatim: tail)
    }

    /// One line for the cap done screen (the reps picker needs the room).
    private func compactRecoveryText(elapsed: Double) -> String {
        if elapsed >= WorkoutMainPage.recoveryTargetSeconds {
            return "3 min recovery done · End when ready"
        }
        var text: String = "Recovery " + SessionModel.formatElapsed(elapsed) + " · " + heartRateValue + " bpm"
        if let drop = model.recoveryDrop {
            text += " " + SummaryFormat.signedNumber(-drop)
        }
        return text
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
}

// MARK: - Screen demo tag

/// Tiny grey "DEMO" capsule shown during a screen demo, so it can't pass for a real workout.
struct DemoTag: View {
    var body: some View {
        Text("DEMO")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundColor(.black)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color(white: 0.6)))
            .fixedSize()
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
                Text(model.isDemo ? "End demo" : "End")
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
