import Foundation

public enum WorkoutLibrary {

    // MARK: Builders

    private static func runSegment(_ meters: Double) -> WorkoutSegment {
        return WorkoutSegment(kind: .run, movement: Movement.run, name: Movement.displayName(Movement.run),
                              target: SegmentTarget(meters, .meters))
    }

    private static func station(_ movement: String, _ value: Double, _ unit: TargetUnit,
                                load: SegmentLoad? = nil) -> WorkoutSegment {
        return WorkoutSegment(kind: .station, movement: movement, name: Movement.displayName(movement),
                              target: SegmentTarget(value, unit), load: load)
    }

    private static func restSegment() -> WorkoutSegment {
        return WorkoutSegment(kind: .rest, movement: Movement.rest, name: Movement.displayName(Movement.rest),
                              target: nil)
    }

    /// `rounds` copies of `round`, flattened.
    private static func repeated(_ round: [WorkoutSegment], rounds: Int) -> [WorkoutSegment] {
        var out: [WorkoutSegment] = []
        for _ in 0..<rounds {
            out.append(contentsOf: round)
        }
        return out
    }

    private static func runsAndStations(runMeters: Double,
                                        stations: [WorkoutSegment]) -> [WorkoutSegment] {
        var out: [WorkoutSegment] = []
        for s in stations {
            out.append(runSegment(runMeters))
            out.append(s)
        }
        return out
    }

    private static func hyroxStations() -> [WorkoutSegment] {
        return [
            station(Movement.skiErg, 1000, .meters),
            station(Movement.sledPush, 50, .meters),
            station(Movement.sledPull, 50, .meters),
            station(Movement.burpeeBroadJumps, 80, .meters),
            station(Movement.row, 1000, .meters),
            station(Movement.farmersCarry, 200, .meters),
            station(Movement.sandbagLunges, 100, .meters),
            station(Movement.wallBalls, 100, .reps)
        ]
    }

    private static func halfHyroxStations() -> [WorkoutSegment] {
        return [
            station(Movement.skiErg, 500, .meters),
            station(Movement.sledPush, 25, .meters),
            station(Movement.sledPull, 25, .meters),
            station(Movement.burpeeBroadJumps, 40, .meters),
            station(Movement.row, 500, .meters),
            station(Movement.farmersCarry, 100, .meters),
            station(Movement.sandbagLunges, 50, .meters),
            station(Movement.wallBalls, 50, .reps)
        ]
    }

    // MARK: Definitions

    public static let hyroxSolo: WorkoutDefinition = WorkoutDefinition(
        id: "hyrox.solo", name: "HYROX Solo", shortName: "Hyrox Solo",
        format: .forTime, team: .solo, timeCapSeconds: nil, healthKitActivity: "mixedCardio",
        segments: runsAndStations(runMeters: 1000, stations: hyroxStations()),
        roundSize: 2)

    public static let hyroxDoubles: WorkoutDefinition = WorkoutDefinition(
        id: "hyrox.doubles", name: "HYROX Doubles", shortName: "Hyrox Dbl",
        format: .forTime, team: .doubles, timeCapSeconds: nil, healthKitActivity: "mixedCardio",
        segments: runsAndStations(runMeters: 1000, stations: hyroxStations()),
        roundSize: 2)

    public static let halfHyrox: WorkoutDefinition = WorkoutDefinition(
        id: "hyrox.half", name: "Half HYROX", shortName: "Half Hyrox",
        format: .forTime, team: .solo, timeCapSeconds: nil, healthKitActivity: "mixedCardio",
        segments: runsAndStations(runMeters: 500, stations: halfHyroxStations()),
        roundSize: 2)

    public static let partnerWod1: WorkoutDefinition = WorkoutDefinition(
        // Scaled version done on 2026-10-31 (partner, 30:00 cap; runs together, stations split).
        id: "partner.wod1", name: "Partner WOD 1 (Scaled)", shortName: "WOD 1",
        format: .forTime, team: .doubles, timeCapSeconds: 1800.0, healthKitActivity: "crossTraining",
        segments: [
            runSegment(800),
            station(Movement.wallBalls, 80, .reps, load: SegmentLoad(14, .lb)),
            runSegment(600),
            station(Movement.dumbbellWalkingLunges, 60, .reps, load: SegmentLoad(50, .lb)),
            runSegment(400),
            station(Movement.burpees, 40, .reps),
            runSegment(200),
            station(Movement.medBallBoxStepOvers, 20, .reps),
            runSegment(100),
            station(Movement.devilPress, 10, .reps, load: SegmentLoad(40, .lb, count: 2))
        ],
        roundSize: 2)

    public static let partnerWod2: WorkoutDefinition = WorkoutDefinition(
        id: "partner.wod2", name: "Partner WOD 2", shortName: "WOD 2",
        format: .forTime, team: .doubles, timeCapSeconds: nil, healthKitActivity: "crossTraining",
        segments: [
            station(Movement.skiErg, 1000, .meters),
            station(Movement.sledPush, 40, .meters),
            station(Movement.farmersCarry, 100, .meters),
            station(Movement.dumbbellOverShoulder, 40, .reps),
            station(Movement.skiErg, 1000, .meters)
        ])

    public static let quickTest: WorkoutDefinition = WorkoutDefinition(
        id: "quick.test", name: "Quick Test", shortName: "Test",
        format: .forTime, team: .solo, timeCapSeconds: nil, healthKitActivity: "crossTraining",
        segments: [
            runSegment(200),
            station(Movement.airSquats, 20, .reps),
            runSegment(200),
            station(Movement.burpees, 10, .reps)
        ])

    /// Class workout (week of Oct 28): "Helen", 3 rounds for time.
    public static let helen: WorkoutDefinition = WorkoutDefinition(
        id: "wod.helen", name: "Helen", shortName: "Helen",
        format: .forTime, team: .solo, timeCapSeconds: 960.0, healthKitActivity: "crossTraining",
        segments: repeated([
            runSegment(400),
            station(Movement.kettlebellSwings, 21, .reps),
            station(Movement.pullUps, 12, .reps)
        ], rounds: 3),
        roundSize: 3)

    /// Class workout: every 3:00 × 6 sets of 15 cal row + 12 thrusters; rest until the next set.
    /// The rest ends by itself on the 3:00 clock (`intervalSeconds`), with a 3-2-1 countdown.
    public static let rowThrusters: WorkoutDefinition = WorkoutDefinition(
        id: "wod.rowThrusters", name: "Every 3:00 × 6: Row + Thrusters", shortName: "Row Thrust",
        format: .emom, team: .solo, timeCapSeconds: 1080.0, healthKitActivity: "crossTraining",
        segments: Array(repeated([
            station(Movement.row, 15, .calories),
            station(Movement.thrusters, 12, .reps),
            restSegment()
        ], rounds: 6).dropLast()),
        intervalSeconds: 180.0,
        roundSize: 3)

    /// Class workout: "Nightmare Before Halloween", 20:00 AMRAP. 10 rounds listed; end the
    /// workout at 20:00 wherever you are.
    public static let amrap20: WorkoutDefinition = WorkoutDefinition(
        id: "wod.nightmareAmrap", name: "Nightmare AMRAP 20", shortName: "AMRAP 20",
        format: .amrap, team: .solo, timeCapSeconds: 1200.0, healthKitActivity: "crossTraining",
        segments: repeated([
            station(Movement.lateralBurpeeOverDumbbell, 10, .reps),
            station(Movement.doubleUnders, 31, .reps),
            station(Movement.dumbbellSnatch, 10, .reps),
            station(Movement.doubleUnders, 31, .reps)
        ], rounds: 10),
        roundSize: 4)

    /// Station with its own display name (class workouts that offer a choice, "Row / Bike").
    private static func choice(_ movement: String, _ name: String, _ value: Double,
                               _ unit: TargetUnit) -> WorkoutSegment {
        return WorkoutSegment(kind: .station, movement: movement, name: name,
                              target: SegmentTarget(value, unit))
    }

    /// Class workout (Sun 2026-11-02, PitFIRE): AMRAP 40 of 12/10 cal row/bike, 15 push-ups /
    /// 6 strict pull-ups, 12 alt DB clean & jerks / snatches, 15 burpees to target / 3 wall walks,
    /// 1:00 rest. Each slot is "this or that"; targets show the first option. The rest ends by
    /// itself after 1:00 with the 3-2-1 countdown. 12 rounds listed; the cap ends it at 40:00.
    public static let amrap40: WorkoutDefinition = WorkoutDefinition(
        id: "wod.amrap40", name: "AMRAP 40 with 1:00 rest", shortName: "AMRAP 40",
        format: .amrap, team: .solo, timeCapSeconds: 2400.0, healthKitActivity: "crossTraining",
        segments: repeated([
            choice(Movement.row, "Row / Bike", 12, .calories),
            choice(Movement.pushUps, "Push-ups / Pull-ups", 15, .reps),
            choice(Movement.dumbbellSnatch, "DB C&J / Snatch", 12, .reps),
            choice(Movement.burpees, "Burpees / Wall Walks", 15, .reps),
            WorkoutSegment(kind: .rest, movement: Movement.rest, name: Movement.displayName(Movement.rest),
                           target: SegmentTarget(60, .seconds))
        ], rounds: 12),
        roundSize: 5)

    /// Free workout: for anything not built yet. 60 open "Part N" segments with no target and no
    /// cap; turn the Crown at each change (new movement, new set, rest…), End when done. Name and
    /// details are added later on the phone.
    public static let free: WorkoutDefinition = {
        var parts: [WorkoutSegment] = []
        for i in 1...60 {
            parts.append(WorkoutSegment(kind: .station, movement: Movement.part, name: "Part " + String(i),
                                        target: nil))
        }
        return WorkoutDefinition(id: "free.workout", name: "Free Workout", shortName: "Free",
                                 format: .forTime, team: .solo, timeCapSeconds: nil,
                                 healthKitActivity: "crossTraining", segments: parts)
    }()

    /// Exactly 9, in this order (fills the watch's 3×3 picker). quickTest stays defined but is
    /// off the grid since 2026-11-01 (Screen demo replaces it); amrap20 made room for Free.
    public static let all: [WorkoutDefinition] = [
        hyroxSolo, hyroxDoubles, halfHyrox, partnerWod1, partnerWod2, amrap40,
        helen, rowThrusters, free
    ]

    /// Every built-in definition, including ones off the watch grid (old results still resolve).
    public static let known: [WorkoutDefinition] = all + [amrap20, quickTest]

    public static func definition(id: String) -> WorkoutDefinition? {
        return known.first(where: { (d: WorkoutDefinition) -> Bool in d.id == id })
    }
}
