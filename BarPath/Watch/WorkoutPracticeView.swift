import SwiftUI
import WatchKit

// The W22 practice workout screens (docs/concepts/first-workout.html, approved). Text is the
// mockup's. No scrolling; long lines may shrink a little (minimumScaleFactor).

// MARK: - Crown side

/// Which side of the screen the Digital Crown is on, from the watch's orientation setting
/// (Settings > General > Watch Orientation). With the Crown on the left watchOS turns the
/// display, so the Crown sits by the screen's left edge. Only for hints that point at the
/// Crown; Crown rotation handling does not depend on it.
enum CrownSide {
    static var isLeft: Bool {
        return WKInterfaceDevice.current().crownOrientation == .left
    }
}

// MARK: - Attaching it to the app root

/// Adds the practice sheet to the root view and opens it at launch until one has been finished.
struct WorkoutPracticePresenter: ViewModifier {
    @ObservedObject private var launcher = WorkoutPracticeLauncher.shared
    @EnvironmentObject private var lifting: SessionModel
    @EnvironmentObject private var workouts: WorkoutSessionModel

    func body(content: Content) -> some View {
        content
            .onAppear {
                let canRun: Bool = lifting.phase == .idle
                    && workouts.phase == .idle
                    && workouts.backgroundRecoveryFinish == nil
                launcher.openAtLaunchIfNeeded(canRun: canRun)
            }
            .sheet(isPresented: $launcher.isPresented, onDismiss: {
                WorkoutPracticeModel.shared.leave()
            }, content: {
                WorkoutPracticeView()
                    .environmentObject(lifting)
                    .environmentObject(workouts)
            })
    }
}

extension View {
    /// The practice workout sheet (W22). Needs `SessionModel` and `WorkoutSessionModel` in the
    /// environment.
    func workoutPractice() -> some View {
        return modifier(WorkoutPracticePresenter())
    }
}

// MARK: - View

struct WorkoutPracticeView: View {
    @ObservedObject private var model = WorkoutPracticeModel.shared
    @EnvironmentObject var lifting: SessionModel
    @EnvironmentObject var workouts: WorkoutSessionModel
    @StateObject private var crown = CrownAdvanceController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var crownFocused: Bool

    private let volt: Color = SegmentPalette.crownForward
    private let warn: Color = SegmentPalette.rgb(0xFFB86B)

    var body: some View {
        ZStack {
            if model.isSessionStage {
                borderLayer
            }
            content
            if model.isSessionStage && model.notice == nil && !isLuminanceReduced {
                CrownArcView(fraction: crown.fraction, isBackward: crown.isBackward)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .focusable(crownActive)
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
            crownTurned(to: newValue)
        }
        .onChange(of: crownActive) { _, active in
            crownFocused = active
            crown.noteAction()
        }
        .onAppear {
            crownFocused = crownActive
        }
        .onChange(of: scenePhase) { _, phase in
            // Left to the watch face while a HealthKit session runs: end it, no zombie session.
            if phase == .background && model.isSessionStage {
                model.leave()
                dismiss()
            }
        }
    }

    private var crownActive: Bool {
        return model.isSessionStage && model.notice == nil
    }

    private func crownTurned(to newValue: Double) {
        if crownActive {
            crown.crownChanged(to: newValue,
                               onAdvance: { model.crownAdvance() },
                               onUndo: { model.crownUndo() })
        } else {
            crown.ignore(newValue)
        }
    }

    /// Why a practice cannot start now (it would need the HealthKit session someone else has).
    private var blockedReason: String? {
        if lifting.phase != .idle {
            return "A lift is recording. Finish it first."
        }
        if workouts.phase != .idle {
            return "A workout is running. Finish it first."
        }
        if workouts.backgroundRecoveryFinish != nil {
            return "Recovery is still recording. Try again when it is done."
        }
        return nil
    }

    // MARK: Styles

    private func rounded(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        return Font.system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Screens

    @ViewBuilder
    private var content: some View {
        if let notice = model.notice {
            noticeScreen(notice)
        } else {
            switch model.stage {
            case .permissions, .requesting:
                permissionsScreen
            case .part1:
                part1Screen
            case .part2:
                if model.showUndoHint {
                    undoHintScreen
                } else {
                    part2Screen
                }
            case .done:
                doneScreen
            case .blocked:
                blockedScreen
            }
        }
    }

    private func topRow(_ tag: String, _ right: String, _ tagColor: Color) -> some View {
        return HStack {
            Text(tag)
                .font(rounded(12, .bold))
                .foregroundColor(tagColor)
            Spacer(minLength: 4)
            Text(right)
                .font(rounded(12, .bold))
                .foregroundColor(.secondary)
        }
    }

    private func dots(_ count: Int) -> some View {
        return HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { (i: Int) in
                Capsule()
                    .fill(i < count ? volt : Color(white: 0.17))
                    .frame(width: 20, height: 4)
            }
        }
    }

    private func voltButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            Text(title)
                .font(rounded(16, .heavy))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(Capsule().fill(volt))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }

    // 1 · Before START

    private var permissionsScreen: some View {
        return VStack(alignment: .leading, spacing: 4) {
            topRow("PRACTICE", "1 min", volt)
            Text("Three permissions:")
                .font(rounded(14, .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            permissionRow(symbol: "heart.fill", color: SegmentPalette.heartRate,
                          text: "Heart rate · effort and recovery")
            permissionRow(symbol: "figure.walk", color: SegmentPalette.run,
                          text: "Motion · steps and reps")
            permissionRow(symbol: "location.fill", color: SegmentPalette.run,
                          text: "Location · run distance and pace")
            Spacer(minLength: 0)
            voltButton("Continue", enabled: model.stage == .permissions) {
                model.continueFromPermissions(blockedReason: blockedReason)
            }
        }
        .padding(.horizontal, 12)
    }

    private func permissionRow(symbol: String, color: Color, text: String) -> some View {
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundColor(.black)
                .frame(width: 18, height: 18)
                .background(Circle().fill(color))
            Text(text)
                .font(rounded(11, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    // 1b · Refused

    private func noticeScreen(_ notice: WorkoutPracticeModel.Notice) -> some View {
        let isHeart: Bool = notice == .heartRate
        let title: String = isHeart ? "Heart rate is off" : "Motion is off"
        let symbol: String = isHeart ? "heart.fill" : "figure.walk"
        let cost: String = isHeart
            ? "Workouts will have time and splits, but no heart rate, calories or recovery."
            : "Workouts will have time and splits, but no steps or rep data."
        let fix: String = isHeart
            ? "Turn on: iPhone → Health → Sharing → Rx Lab."
            : "Turn on: Watch Settings → Privacy & Security → Motion & Fitness."
        return VStack(alignment: .leading, spacing: 5) {
            topRow("PRACTICE", "", warn)
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .heavy))
                Text(title)
                    .font(rounded(14, .heavy))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(warn)
            Text(cost)
                .font(rounded(12, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            Text(fix)
                .font(rounded(12, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            voltButton("Continue", enabled: true) {
                model.dismissNotice()
            }
        }
        .padding(.horizontal, 12)
    }

    // 2 · Part 1

    private var part1Screen: some View {
        return VStack(alignment: .leading, spacing: 3) {
            topRow("PART 1 OF 2", "", volt)
            dots(1)
            Text("WALK")
                .font(rounded(30, .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("or march in place")
                .font(rounded(12, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .center, spacing: 4) {
                if CrownSide.isLeft {
                    crownArrow
                    Spacer(minLength: 2)
                    heartRateView
                } else {
                    heartRateView
                    Spacer(minLength: 2)
                    crownArrow
                }
            }
            .padding(.top, 4)
            Spacer(minLength: 0)
            doneLine
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var heartRateView: some View {
        if let bpm = model.heartRate {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(bpm)")
                    .font(rounded(26, .heavy).monospacedDigit())
                    .foregroundColor(SegmentPalette.heartRate)
                Text("BPM")
                    .font(rounded(11, .bold))
                    .foregroundColor(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else if model.heartRateOff {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("—")
                    .font(rounded(26, .heavy))
                    .foregroundColor(Color(white: 0.43))
                Text("HR OFF")
                    .font(rounded(11, .heavy))
                    .foregroundColor(warn)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("—")
                    .font(rounded(26, .heavy))
                    .foregroundColor(Color(white: 0.43))
                Text("BPM")
                    .font(rounded(11, .bold))
                    .foregroundColor(Color(white: 0.43))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
    }

    /// "Turn the Crown" with an arrow pointing at the Crown: on the trailing edge pointing
    /// right, or on the leading edge pointing left when the Crown is on the left.
    @ViewBuilder
    private var crownArrow: some View {
        if CrownSide.isLeft {
            HStack(spacing: 3) {
                crownArrowIcon("arrow.left")
                crownArrowText(.leading)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn the Crown")
        } else {
            HStack(spacing: 3) {
                crownArrowText(.trailing)
                crownArrowIcon("arrow.right")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Turn the Crown")
        }
    }

    private func crownArrowText(_ alignment: TextAlignment) -> some View {
        return Text("Turn\nthe Crown")
            .font(rounded(11, .heavy))
            .foregroundColor(volt)
            .multilineTextAlignment(alignment)
            .lineLimit(2)
            .fixedSize()
    }

    private func crownArrowIcon(_ name: String) -> some View {
        return Image(systemName: name)
            .font(.system(size: 13, weight: .heavy))
            .foregroundColor(volt)
    }

    private var doneLine: some View {
        return (Text("Done? ").foregroundColor(.white) + Text("Turn the Crown").foregroundColor(volt))
            .font(rounded(12, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    // 3 · Part 2

    private var part2Screen: some View {
        return VStack(alignment: .leading, spacing: 3) {
            topRow("PART 2 OF 2", "", volt)
            dots(2)
            Text("Nice.")
                .font(rounded(30, .heavy))
                .foregroundColor(volt)
                .lineLimit(1)
            Text("In a workout you turn it after every run, station and set.")
                .font(rounded(13, .bold))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 4) {
                if CrownSide.isLeft {
                    crownArrow
                    Spacer(minLength: 2)
                    onceMoreText
                        .multilineTextAlignment(.trailing)
                } else {
                    onceMoreText
                    Spacer(minLength: 2)
                    crownArrow
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var onceMoreText: some View {
        return Text("Once more to finish")
            .font(rounded(12, .semibold))
            .lineLimit(2)
            .minimumScaleFactor(0.8)
    }

    // 3b · Wrong turn hint

    private var undoHintScreen: some View {
        return VStack(alignment: .leading, spacing: 3) {
            topRow("PART 2 OF 2", "", volt)
            dots(2)
            Text("Wrong turn?")
                .font(rounded(26, .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            (Text("Turn back").foregroundColor(SegmentPalette.crownBackward) + Text(" to undo.").foregroundColor(.white))
                .font(rounded(14, .bold))
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("The line runs the other way.")
                .font(rounded(12, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
    }

    // 4 · Finish

    private var doneScreen: some View {
        return VStack(alignment: .leading, spacing: 4) {
            topRow("DONE", "", volt)
            dots(3)
            (Text("After a workout the watch records ")
                + Text("3 min of recovery").foregroundColor(SegmentPalette.heartRate)
                + Text("."))
                .font(rounded(13, .bold))
                .lineLimit(4)
                .minimumScaleFactor(0.8)
            (Text("No need to wait: swipe left and tap ")
                + Text("End").foregroundColor(.white).bold()
                + Text(". Recovery keeps recording in the background."))
                .font(rounded(11, .semibold))
                .foregroundColor(.secondary)
                .lineLimit(5)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            voltButton("Got it", enabled: true) {
                model.markFinished()
                dismiss()
            }
        }
        .padding(.horizontal, 12)
    }

    // Can't start

    private var blockedScreen: some View {
        return VStack(alignment: .leading, spacing: 6) {
            topRow("PRACTICE", "", warn)
            Text(model.blockedText)
                .font(rounded(14, .bold))
                .lineLimit(5)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            voltButton("Close", enabled: true) {
                dismiss()
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Border

    private var borderLayer: some View {
        return TimelineView(.periodic(from: Date(), by: 1.0)) { context in
            RaceBorderView(state: borderState(now: context.date), isAlwaysOn: isLuminanceReduced)
                .ignoresSafeArea()
        }
    }

    /// Two slices, part 1 run blue and part 2 station orange, as in the mockup.
    private func borderState(now: Date) -> RaceBorderState {
        let colors: [Color] = [SegmentPalette.run, SegmentPalette.stations[0]]
        let index: Int = model.stage == .part2 ? 1 : 0
        let elapsed: Double = max(0, now.timeIntervalSince(model.partStart))
        let fraction: Double = min(WorkoutMainPage.stationMaxFraction,
                                   elapsed / WorkoutPracticeModel.partNominalSeconds)
        return RaceBorderState.segments(colors: colors, currentIndex: index, currentFraction: fraction)
    }
}
