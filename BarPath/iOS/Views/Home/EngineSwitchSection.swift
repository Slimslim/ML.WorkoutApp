import SwiftUI
import BarPathKit

/// Settings › Workout engine (E2, 0.18): New / Classic. Takes effect at the next workout start on
/// the watch; a workout already running keeps its engine.
struct EngineSwitchSection: View {
    @ObservedObject private var setting = EngineSwitchSetting.shared

    private var selection: Binding<WorkoutEngine> {
        return Binding<WorkoutEngine>(get: { setting.engine },
                                      set: { (value: WorkoutEngine) in setting.set(value) })
    }

    var body: some View {
        Section {
            Picker("Workout engine", selection: selection) {
                Text("New").tag(WorkoutEngine.v2)
                Text("Classic").tag(WorkoutEngine.legacy)
            }
        } header: {
            Text("Workouts")
        } footer: {
            Text("Used from the next workout you start on the watch.")
        }
    }
}
