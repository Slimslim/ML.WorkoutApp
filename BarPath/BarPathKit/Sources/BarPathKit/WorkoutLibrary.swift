import Foundation

public enum WorkoutLibrary {

    // MARK: Builders

    private static func runSegment(_ meters: Double) -> WorkoutSegment {
        return WorkoutSegment(kind: .run, movement: Movement.run, name: Movement.displayName(Movement.run),
                              target: SegmentTarget(meters, .meters))
    }

    private static func station(_ movement: String, _ value: Double, _ unit: TargetUnit) -> WorkoutSegment {
        return WorkoutSegment(kind: .station, movement: movement, name: Movement.displayName(movement),
                              target: SegmentTarget(value, unit))
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
        segments: runsAndStations(runMeters: 1000, stations: hyroxStations()))

    public static let hyroxDoubles: WorkoutDefinition = WorkoutDefinition(
        id: "hyrox.doubles", name: "HYROX Doubles", shortName: "Hyrox Dbl",
        format: .forTime, team: .doubles, timeCapSeconds: nil, healthKitActivity: "mixedCardio",
        segments: runsAndStations(runMeters: 1000, stations: hyroxStations()))

    public static let halfHyrox: WorkoutDefinition = WorkoutDefinition(
        id: "hyrox.half", name: "Half HYROX", shortName: "Half Hyrox",
        format: .forTime, team: .solo, timeCapSeconds: nil, healthKitActivity: "mixedCardio",
        segments: runsAndStations(runMeters: 500, stations: halfHyroxStations()))

    public static let partnerWod1: WorkoutDefinition = WorkoutDefinition(
        id: "partner.wod1", name: "Partner WOD 1", shortName: "WOD 1",
        format: .forTime, team: .doubles, timeCapSeconds: nil, healthKitActivity: "crossTraining",
        segments: [
            runSegment(1000),
            station(Movement.wallBalls, 100, .reps),
            runSegment(800),
            station(Movement.dumbbellWalkingLunges, 80, .reps),
            runSegment(600),
            station(Movement.burpees, 60, .reps),
            runSegment(400),
            station(Movement.medBallBoxStepOvers, 40, .reps),
            runSegment(200),
            station(Movement.devilPress, 20, .reps)
        ])

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

    /// Exactly 6, in this order: hyroxSolo, hyroxDoubles, halfHyrox, partnerWod1, partnerWod2, quickTest.
    public static let all: [WorkoutDefinition] = [
        hyroxSolo, hyroxDoubles, halfHyrox, partnerWod1, partnerWod2, quickTest
    ]

    public static func definition(id: String) -> WorkoutDefinition? {
        return all.first(where: { (d: WorkoutDefinition) -> Bool in d.id == id })
    }
}
