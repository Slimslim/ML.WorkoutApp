import Foundation
import HealthKit
import BarPathKit

/// What the phone knows about the athlete for heart rate zones: birth year (from Apple Health, or
/// typed in Settings) and an optional manual max heart rate. Kept on this phone only: never in
/// a result, an upload or a phone-watch message. The values live in UserDefaults; `revision`
/// changes after each write so screens can recompute.
final class AthleteProfile: ObservableObject {
    static let shared = AthleteProfile()

    /// Birth year read from Health (cached; removed when Health gives none).
    static let healthYearKey = "athlete.birthYearFromHealth"
    /// Birth year typed in Settings.
    static let manualYearKey = "athlete.birthYearManual"
    /// Manual max heart rate (this key was read before but never written).
    static let maxHeartRateKey = "maxHeartRate"

    @Published private(set) var revision: Int = 0

    private var didRefreshFromHealth = false

    private init() {}

    static var currentYear: Int {
        return Calendar.current.component(.year, from: Date())
    }

    /// The birth year from Health, nil when Health has none (not available, not set, denied).
    var healthBirthYear: Int? {
        let v: Int = UserDefaults.standard.integer(forKey: AthleteProfile.healthYearKey)
        return v > 0 ? v : nil
    }

    var manualBirthYear: Int? {
        let v: Int = UserDefaults.standard.integer(forKey: AthleteProfile.manualYearKey)
        return v > 0 ? v : nil
    }

    /// The year in use: Health first.
    var birthYear: Int? {
        return healthBirthYear ?? manualBirthYear
    }

    /// The manual max heart rate, nil when not set.
    var manualMaxHeartRate: Double? {
        let v: Double = UserDefaults.standard.double(forKey: AthleteProfile.maxHeartRateKey)
        return v > 0 ? v : nil
    }

    func setManualBirthYear(_ year: Int?) {
        if let y = year {
            UserDefaults.standard.set(y, forKey: AthleteProfile.manualYearKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AthleteProfile.manualYearKey)
        }
        revision += 1
    }

    func setManualMaxHeartRate(_ bpm: Double?) {
        if let b = bpm {
            UserDefaults.standard.set(b, forKey: AthleteProfile.maxHeartRateKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AthleteProfile.maxHeartRateKey)
        }
        revision += 1
    }

    /// The max heart rate in use for these results, nil when nothing is known yet.
    func maxHeartRate(results: [WorkoutResult]) -> WorkoutEffort.MaxHeartRate? {
        return WorkoutEffort.effectiveMaxHeartRate(results: results, birthYear: birthYear,
                                                   override: manualMaxHeartRate,
                                                   year: AthleteProfile.currentYear)
    }

    /// Reads the birth year from Health once per launch. Asks for read access to that one type
    /// first (shows nothing when it was answered before), then reads off the main thread.
    /// Not available, not set and denied all leave no year.
    func refreshFromHealth() {
        if didRefreshFromHealth { return }
        didRefreshFromHealth = true
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.characteristicType(forIdentifier: .dateOfBirth) else {
            return
        }
        let store = HKHealthStore()
        let read: Set<HKObjectType> = [type]
        store.requestAuthorization(toShare: nil, read: read) { (_: Bool, _: Error?) in
            var year: Int? = nil
            do {
                let components: DateComponents = try store.dateOfBirthComponents()
                year = components.year
            } catch {
                year = nil
            }
            DispatchQueue.main.async {
                self.storeHealthYear(year)
            }
        }
    }

    private func storeHealthYear(_ year: Int?) {
        let old: Int? = healthBirthYear
        if let y = year, y > 0 {
            UserDefaults.standard.set(y, forKey: AthleteProfile.healthYearKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AthleteProfile.healthYearKey)
        }
        if old != healthBirthYear { revision += 1 }
    }
}
