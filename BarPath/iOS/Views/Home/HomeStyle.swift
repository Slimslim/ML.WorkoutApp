import SwiftUI
import BarPathKit

/// Modalities of the guidelines (section 3). Each movement belongs to one; movements this build
/// doesn't know have none and draw a grey line.
enum Modality {
    case oly, str, gym, crd, cry

    var color: Color {
        switch self {
        case .oly: return Color(red: 0.898, green: 0.694, blue: 0.227)
        case .str: return Color(red: 0.851, green: 0.412, blue: 0.180)
        case .gym: return Color(red: 0.247, green: 0.647, blue: 0.541)
        case .crd: return Color(red: 0.310, green: 0.525, blue: 0.910)
        case .cry: return Color(red: 0.557, green: 0.471, blue: 0.788)
        }
    }

    var name: String {
        switch self {
        case .oly: return "Oly"
        case .str: return "Strength"
        case .gym: return "Gymnastics"
        case .crd: return "Cardio"
        case .cry: return "Carries"
        }
    }

    private static let byMovement: [String: Modality] = [
        "powerCleans": .oly, "powerCleanAndJerk": .oly,
        "run": .crd, "row": .crd, "skiErg": .crd,
        "sledPush": .cry, "sledPull": .cry, "farmersCarry": .cry, "sandbagLunges": .cry,
        "wallBalls": .str, "thrusters": .str, "kettlebellSwings": .str, "devilPress": .str,
        "dumbbellSnatch": .str, "dumbbellOverShoulder": .str, "dumbbellWalkingLunges": .str,
        "burpees": .gym, "burpeeBroadJumps": .gym, "lateralBurpeeOverDumbbell": .gym,
        "airSquats": .gym, "pullUps": .gym, "pushUps": .gym, "doubleUnders": .gym,
        "medBallBoxStepOvers": .gym
    ]

    static func of(movement: String) -> Modality? {
        return byMovement[movement]
    }

    static func of(lift: LiftType) -> Modality {
        return lift == LiftType.deadlift ? Modality.str : Modality.oly
    }
}

/// One colour of a block's line and its share of the height.
struct LineSegment: Identifiable {
    let id: Int
    let color: Color
    let share: Double

    private static let unknown: Color = Color.gray.opacity(0.5)

    /// Shares from (movement, weight) pairs, kept in the order each colour first appears.
    private static func make(_ items: [(String, Double)]) -> [LineSegment] {
        var order: [Modality?] = []
        var totals: [Double] = []
        for (movement, weight) in items {
            let m: Modality? = Modality.of(movement: movement)
            if let i = order.firstIndex(where: { (o: Modality?) -> Bool in o == m }) {
                totals[i] += weight
            } else {
                order.append(m)
                totals.append(weight)
            }
        }
        let sum: Double = totals.reduce(0, +)
        if sum <= 0 { return [LineSegment(id: 0, color: unknown, share: 1)] }
        return order.indices.map { (i: Int) -> LineSegment in
            LineSegment(id: i, color: order[i]?.color ?? unknown, share: totals[i] / sum)
        }
    }

    /// Planned: by number of segments.
    static func planned(_ definition: WorkoutDefinition) -> [LineSegment] {
        let items: [(String, Double)] = definition.segments
            .filter { (s: WorkoutSegment) -> Bool in s.kind == .station || s.kind == .run }
            .map { (s: WorkoutSegment) -> (String, Double) in (s.movement, 1) }
        return make(items)
    }

    /// Done: by time in each movement.
    static func done(_ result: WorkoutResult) -> [LineSegment] {
        let items: [(String, Double)] = result.segments
            .filter { (s: SegmentResult) -> Bool in s.kind == .station || s.kind == .run }
            .map { (s: SegmentResult) -> (String, Double) in (s.movement, s.duration) }
        return make(items)
    }

    static func session(_ session: LiftSessionGroup) -> [LineSegment] {
        let first: Modality = session.newestLift.map { (e: LiftEntry) -> Modality in Modality.of(lift: e.liftType) }
            ?? Modality.oly
        return [LineSegment(id: 0, color: first.color, share: 1)]
    }
}

/// The straight coloured line beside a block, split by modality.
struct BlockLine: View {
    let segments: [LineSegment]

    var body: some View {
        GeometryReader { (geo: GeometryProxy) in
            let gaps: CGFloat = CGFloat(max(0, segments.count - 1)) * 2
            VStack(spacing: 2) {
                ForEach(segments) { (s: LineSegment) in
                    Rectangle()
                        .fill(s.color)
                        .frame(height: max(0, (geo.size.height - gaps) * CGFloat(s.share)))
                }
            }
        }
        .frame(width: 2)
        .accessibilityHidden(true)
    }
}

/// Thin ring with the Effort number. `share` is against the hardest day so far.
struct EffortRing: View {
    let value: String
    let share: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(uiColor: .separator), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, share))))
                .stroke(Color.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value)
                .font(.system(size: 22, weight: .medium))
                .monospacedDigit()
        }
        .frame(width: 84, height: 84)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Effort " + value)
    }
}

/// Effort by "yyyy-MM-dd", from the results.
enum EffortDays {
    static func make(_ results: [WorkoutResult]) -> [String: WorkoutEffort.Day] {
        var out: [String: WorkoutEffort.Day] = [:]
        for d in list(results) {
            out[d.day] = d
        }
        return out
    }

    /// One entry per day, scored with the max heart rate in use (AthleteProfile).
    static func list(_ results: [WorkoutResult]) -> [WorkoutEffort.Day] {
        let profile: AthleteProfile = AthleteProfile.shared
        return WorkoutEffort.days(results, calendar: gregorian, birthYear: profile.birthYear,
                                  override: profile.manualMaxHeartRate, year: AthleteProfile.currentYear)
    }

    /// Day keys are gregorian whatever calendar the phone uses (LibraryDay).
    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.autoupdatingCurrent
        return c
    }

    /// Rounded for display, "—" without heart rate data.
    static func text(_ effort: Double?) -> String {
        guard let e = effort else { return "\u{2014}" }
        return String(Int(e.rounded()))
    }
}
