import SwiftUI
import BarPathKit

/// Settings: birth year and max heart rate, which set the Effort zones (story W25).
struct HeartRateSection: View {
    @EnvironmentObject private var workouts: WorkoutStore
    @ObservedObject private var profile = AthleteProfile.shared
    @State private var yearText: String = ""
    @State private var maxText: String = ""

    private var maxLine: String {
        guard let found = profile.maxHeartRate(results: workouts.results) else { return "Not known yet" }
        let value: String = String(Int(found.value.rounded())) + " bpm"
        switch found.source {
        case .manual: return value + " \u{00B7} Set by you"
        case .age: return value + " \u{00B7} Estimated from age"
        case .workouts: return value + " \u{00B7} From your workouts"
        }
    }

    var body: some View {
        Section("Heart rate") {
            if let year = profile.healthBirthYear {
                LabeledContent("Birth year", value: String(year) + " \u{00B7} From Health")
            } else {
                LabeledContent("Birth year") {
                    TextField("Year", text: $yearText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: yearText) { _, text in
                            commitYear(text)
                        }
                }
            }
            LabeledContent("Max heart rate", value: maxLine)
            LabeledContent("Set your own") {
                TextField("bpm", text: $maxText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: maxText) { _, text in
                        commitMax(text)
                    }
            }
            if profile.manualMaxHeartRate != nil {
                Button("Use the automatic value") {
                    maxText = ""
                    profile.setManualMaxHeartRate(nil)
                }
            }
        }
        .onAppear {
            if let y = profile.manualBirthYear { yearText = String(y) }
            if let m = profile.manualMaxHeartRate { maxText = String(Int(m.rounded())) }
        }
    }

    /// Saves a four digit year from 1900 to this year; empty clears it. Anything else waits.
    private func commitYear(_ text: String) {
        if text.isEmpty {
            if profile.manualBirthYear != nil { profile.setManualBirthYear(nil) }
            return
        }
        if let y = Int(text), text.count == 4, y >= 1900, y <= AthleteProfile.currentYear {
            if y != profile.manualBirthYear { profile.setManualBirthYear(y) }
        }
    }

    /// Saves a value from 100 to 230. Typing passes through smaller numbers: those wait.
    private func commitMax(_ text: String) {
        if let m = Int(text), m >= 100, m <= 230 {
            if Double(m) != profile.manualMaxHeartRate { profile.setManualMaxHeartRate(Double(m)) }
        }
    }
}
