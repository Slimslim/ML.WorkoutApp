import SwiftUI
import BarPathKit

/// Settings: weight unit and the body details used to measure lifts (height, body weight, forearm
/// length). All optional. Saved through `AthleteProfile`, which keeps them in kilograms and
/// centimetres and writes them to Profile/athlete.json for the uploads.
struct AboutYouSection: View {
    @ObservedObject private var profile = AthleteProfile.shared
    @State private var cmText: String = ""
    @State private var feetText: String = ""
    @State private var inchesText: String = ""
    @State private var bodyText: String = ""
    @State private var forearmText: String = ""

    private static let cmPerInch: Double = 2.54

    private var unit: WeightUnit {
        return profile.weightUnit
    }

    private var unitBinding: Binding<WeightUnit> {
        return Binding<WeightUnit>(get: { profile.weightUnit },
                                   set: { (value: WeightUnit) in profile.setWeightUnit(value) })
    }

    var body: some View {
        Section {
            LabeledContent("Weights") {
                Picker("Weights", selection: unitBinding) {
                    Text("kg").tag(WeightUnit.kg)
                    Text("lb").tag(WeightUnit.lb)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            LabeledContent("Height") {
                if unit == .kg {
                    HStack(spacing: 6) {
                        TextField("Optional", text: $cmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: cmText) { _, _ in commitHeightCm() }
                        Text("cm").foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        TextField("Optional", text: $feetText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: feetText) { _, _ in commitHeightImperial() }
                        Text("ft").foregroundStyle(.secondary)
                        TextField("0", text: $inchesText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 44)
                            .onChange(of: inchesText) { _, _ in commitHeightImperial() }
                        Text("in").foregroundStyle(.secondary)
                    }
                }
            }
            LabeledContent("Body weight") {
                HStack(spacing: 6) {
                    TextField("Optional", text: $bodyText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: bodyText) { _, _ in commitBodyWeight() }
                    Text(unit.label).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Forearm length") {
                    HStack(spacing: 6) {
                        TextField("Optional", text: $forearmText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: forearmText) { _, _ in commitForearm() }
                        Text(unit == .kg ? "cm" : "in").foregroundStyle(.secondary)
                    }
                }
                Text("Elbow crease to the wrist bone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("About you")
        } footer: {
            Text("Used to measure your lifts. Stays with your data.")
        }
        .onAppear { loadTexts() }
        .onChange(of: unit) { _, _ in loadTexts() }
    }

    // MARK: - Text from the saved values

    private static func plain(_ value: Double) -> String {
        let tenths: Double = (value * 10).rounded() / 10
        if tenths == tenths.rounded() {
            return String(format: "%.0f", tenths)
        }
        return String(format: "%.1f", tenths)
    }

    private static func parse(_ text: String) -> Double? {
        let cleaned: String = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    private static func feetAndInches(cm: Double) -> (feet: Int, inches: Int) {
        let total: Int = Int((cm / AboutYouSection.cmPerInch).rounded())
        return (total / 12, total % 12)
    }

    private func loadTexts() {
        if let cm = profile.heightCm {
            if unit == .kg {
                cmText = AboutYouSection.plain(cm)
                feetText = ""
                inchesText = ""
            } else {
                let parts = AboutYouSection.feetAndInches(cm: cm)
                feetText = String(parts.feet)
                inchesText = String(parts.inches)
                cmText = ""
            }
        } else {
            cmText = ""
            feetText = ""
            inchesText = ""
        }
        if let kg = profile.bodyWeightKg {
            bodyText = AboutYouSection.plain(unit.display(fromKilograms: kg))
        } else {
            bodyText = ""
        }
        if let cm = profile.forearmCm {
            forearmText = AboutYouSection.plain(unit == .kg ? cm : cm / AboutYouSection.cmPerInch)
        } else {
            forearmText = ""
        }
    }

    // MARK: - Saving what is typed
    // Typing passes through values that are out of range: those wait. An empty field clears the
    // value. A field that shows what is already saved changes nothing (no rounding drift).

    private func commitHeightCm() {
        if cmText.isEmpty {
            if profile.heightCm != nil { profile.setHeightCm(nil) }
            return
        }
        guard let cm = AboutYouSection.parse(cmText), cm >= 120, cm <= 230 else { return }
        if let old = profile.heightCm, abs(old - cm) < 0.05 { return }
        profile.setHeightCm(cm)
    }

    private func commitHeightImperial() {
        if feetText.isEmpty && inchesText.isEmpty {
            if profile.heightCm != nil { profile.setHeightCm(nil) }
            return
        }
        guard let feet = Int(feetText), feet >= 3, feet <= 7 else { return }
        let inches: Int = inchesText.isEmpty ? 0 : (Int(inchesText) ?? -1)
        guard inches >= 0, inches < 12 else { return }
        let cm: Double = Double(feet * 12 + inches) * AboutYouSection.cmPerInch
        guard cm >= 120, cm <= 230 else { return }
        if let old = profile.heightCm {
            let saved = AboutYouSection.feetAndInches(cm: old)
            if saved.feet == feet && saved.inches == inches { return }
        }
        profile.setHeightCm(cm)
    }

    private func commitBodyWeight() {
        if bodyText.isEmpty {
            if profile.bodyWeightKg != nil { profile.setBodyWeightKg(nil) }
            return
        }
        guard let value = AboutYouSection.parse(bodyText) else { return }
        let kg: Double = unit.kilograms(fromDisplay: value)
        guard kg >= 30, kg <= 250 else { return }
        if let old = profile.bodyWeightKg,
           unit.display(fromKilograms: old) == unit.display(fromKilograms: kg) { return }
        profile.setBodyWeightKg(kg)
    }

    private func commitForearm() {
        if forearmText.isEmpty {
            if profile.forearmCm != nil { profile.setForearmCm(nil) }
            return
        }
        guard let value = AboutYouSection.parse(forearmText) else { return }
        let cm: Double = unit == .kg ? value : value * AboutYouSection.cmPerInch
        guard cm >= 15, cm <= 40 else { return }
        if let old = profile.forearmCm {
            let oldShown: Double = unit == .kg ? old : old / AboutYouSection.cmPerInch
            if AboutYouSection.plain(oldShown) == AboutYouSection.plain(value) { return }
        }
        profile.setForearmCm(cm)
    }
}
