import Foundation

/// The weight unit an athlete lifts in, and the conversions between what is shown and what is
/// stored. Lift recordings always store kilograms; this only changes what is shown and entered.
/// Library workouts carry their own unit per segment (`SegmentLoad.Unit`) and do not use this.
public enum WeightUnit: String, CaseIterable, Codable, Sendable {
    case kg
    case lb

    public static let kgPerLb: Double = 0.45359237

    /// The unit before the athlete chooses: kg for a metric region, lb otherwise.
    public static func defaultUnit(metric: Bool) -> WeightUnit {
        return metric ? .kg : .lb
    }

    /// Short label shown after a number.
    public var label: String { return rawValue }

    /// Load on the watch picker the first time, in this unit.
    public var defaultLoad: Double { return self == .kg ? 60 : 135 }

    /// One tap or one Crown detent on the watch picker, in this unit.
    public var step: Double { return self == .kg ? 2.5 : 5 }

    /// Upper end of the pickers, in this unit.
    public var maxLoad: Double { return self == .kg ? 400 : 900 }

    /// Kilograms for a number typed or picked in this unit. Cleaned to 6 decimals so a value
    /// that went through pounds (60 kg -> 132.277 lb -> kg) comes back as 60.
    public func kilograms(fromDisplay value: Double) -> Double {
        let kg: Double = self == .kg ? value : value * WeightUnit.kgPerLb
        return WeightUnit.clean(kg)
    }

    /// The number shown for a stored weight: kg to 0.1, lb as a whole number.
    public func display(fromKilograms kg: Double) -> Double {
        switch self {
        case .kg: return (kg * 10).rounded() / 10
        case .lb: return (kg / WeightUnit.kgPerLb).rounded()
        }
    }

    /// "62.5 kg", "100 kg", "135 lb".
    public func format(kilograms kg: Double) -> String {
        return format(display: display(fromKilograms: kg))
    }

    /// A number already in this unit, with the label.
    public func format(display value: Double) -> String {
        switch self {
        case .kg:
            let tenths: Double = (value * 10).rounded() / 10
            if tenths == tenths.rounded() {
                return String(format: "%.0f kg", tenths)
            }
            return String(format: "%.1f kg", tenths)
        case .lb:
            return String(format: "%.0f lb", value.rounded())
        }
    }

    /// A stored weight moved by `delta` in this unit (a step), kept between 0 and `maxLoad`.
    public func kilograms(adding delta: Double, toKilograms kg: Double) -> Double {
        let moved: Double = display(fromKilograms: kg) + delta
        let limited: Double = min(maxLoad, max(0, moved))
        return kilograms(fromDisplay: limited)
    }

    /// Pounds to kilograms (the phone sends a lift load as `loadLb`).
    public static func kilograms(fromPounds lb: Double) -> Double {
        return clean(lb * kgPerLb)
    }

    /// Kilograms to pounds, not rounded, for the `loadLb` key on the wire.
    public static func pounds(fromKilograms kg: Double) -> Double {
        return kg / kgPerLb
    }

    private static func clean(_ kg: Double) -> Double {
        return (kg * 1_000_000).rounded() / 1_000_000
    }
}
