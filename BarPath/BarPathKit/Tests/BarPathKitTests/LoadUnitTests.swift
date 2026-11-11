import XCTest
@testable import BarPathKit

final class LoadUnitTests: XCTestCase {
    func testDefaultsAndSteps() {
        XCTAssertEqual(WeightUnit.defaultUnit(metric: true), .kg)
        XCTAssertEqual(WeightUnit.defaultUnit(metric: false), .lb)
        XCTAssertEqual(WeightUnit.kg.defaultLoad, 60)
        XCTAssertEqual(WeightUnit.kg.step, 2.5)
        XCTAssertEqual(WeightUnit.lb.defaultLoad, 135)
        XCTAssertEqual(WeightUnit.lb.step, 5)
    }

    func testFormat() {
        XCTAssertEqual(WeightUnit.kg.format(kilograms: 60), "60 kg")
        XCTAssertEqual(WeightUnit.kg.format(kilograms: 62.5), "62.5 kg")
        XCTAssertEqual(WeightUnit.kg.format(kilograms: 100), "100 kg")
        XCTAssertEqual(WeightUnit.kg.format(kilograms: 61.23496), "61.2 kg")
        XCTAssertEqual(WeightUnit.lb.format(kilograms: 61.23496), "135 lb")
        XCTAssertEqual(WeightUnit.lb.format(kilograms: 60), "132 lb")
    }

    func testKilogramsRoundTripInKilograms() {
        var value = 0.0
        while value <= 400 {
            let kg = WeightUnit.kg.kilograms(fromDisplay: value)
            XCTAssertEqual(WeightUnit.kg.display(fromKilograms: kg), value, accuracy: 1e-9)
            value += 2.5
        }
    }

    func testPoundsRoundTripInPounds() {
        var value = 0.0
        while value <= 900 {
            let kg = WeightUnit.lb.kilograms(fromDisplay: value)
            XCTAssertEqual(WeightUnit.lb.display(fromKilograms: kg), value, accuracy: 1e-9)
            value += 5
        }
        XCTAssertEqual(WeightUnit.lb.display(fromKilograms: WeightUnit.lb.kilograms(fromDisplay: 135)), 135)
    }

    func testKilogramsThroughTheLiftSelectionPounds() {
        // The phone sends kilograms as loadLb; the watch converts back.
        for kg in [20.0, 60.0, 62.5, 100.0, 142.5] {
            let lb = WeightUnit.pounds(fromKilograms: kg)
            XCTAssertEqual(WeightUnit.kilograms(fromPounds: lb), kg, accuracy: 1e-9)
            XCTAssertEqual(WeightUnit.kg.format(kilograms: WeightUnit.kilograms(fromPounds: lb)),
                           WeightUnit.kg.format(display: kg))
        }
    }

    func testStepsAndLimits() {
        var kg = WeightUnit.kg.kilograms(fromDisplay: 60)
        kg = WeightUnit.kg.kilograms(adding: 2.5, toKilograms: kg)
        XCTAssertEqual(WeightUnit.kg.display(fromKilograms: kg), 62.5)
        kg = WeightUnit.kg.kilograms(adding: -100, toKilograms: kg)
        XCTAssertEqual(kg, 0)
        kg = WeightUnit.kg.kilograms(adding: 1000, toKilograms: kg)
        XCTAssertEqual(kg, 400)

        var pounds = WeightUnit.lb.kilograms(fromDisplay: 135)
        pounds = WeightUnit.lb.kilograms(adding: 5, toKilograms: pounds)
        XCTAssertEqual(WeightUnit.lb.display(fromKilograms: pounds), 140)
    }
}
