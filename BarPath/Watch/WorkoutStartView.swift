import SwiftUI
import Combine
import BarPathKit

/// Workout mode setup, no scrolling: phone dot + DATA chip, the workout tile (tap → picker),
/// a big green START, and the last workout's summary.
struct WorkoutStartView: View {
    @EnvironmentObject var model: WorkoutSessionModel
    @ObservedObject private var link = PhoneLink.shared
    @State private var showPicker = false
    /// W23: "Heart rate is off" / "Motion is off", refreshed on appear, when the app comes
    /// back to the foreground (Settings changed) and when the practice or a workout writes the flag.
    @State private var sensorBanner: SensorBanner? = WorkoutSensorBanner.current()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(link.isReachable ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(link.isReachable ? "Phone" : "Phone offline")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    model.dataMode.toggle()
                } label: {
                    Text("DATA")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundColor(model.dataMode ? .black : .secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(model.dataMode ? Color.yellow : Color(white: 0.18))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.dataMode ? "Data mode on" : "Data mode off")
            }

            if let banner = sensorBanner {
                WorkoutSensorBanner(banner: banner)
            }

            Button {
                showPicker = true
            } label: {
                workoutTile
            }
            .buttonStyle(.plain)

            Button {
                model.start()
            } label: {
                Text("START")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Capsule().fill(Color.green))
            }
            .buttonStyle(.plain)
            // Was 60; 44 leaves room for the Screen demo button on 41 mm (START still fills
            // the free height on bigger screens).
            .frame(minHeight: 44)

            // Try the workout screen with mock data: no HealthKit, nothing saved or sent.
            // Hidden while the W23 banner shows, so the screen still fits 41 mm without scrolling.
            if sensorBanner == nil {
                Button {
                    model.startDemo()
                } label: {
                    Text("Screen demo")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(Capsule().stroke(Color(white: 0.3), lineWidth: 1))
                        // Plain style: without this only the text and the 1 pt stroke are tappable.
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Screen demo with mock data")
            }

            if let finish = model.backgroundRecoveryFinish {
                // W6: HR still recorded after End until finish + 3:00 (time since the finish).
                TimelineView(.periodic(from: Date(), by: 1.0)) { context in
                    Text("Recovery recording · " + SessionModel.formatElapsed(max(0, context.date.timeIntervalSince(finish))))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            } else if sensorBanner != nil {
                // W23: the banner takes this line's place so 41 mm still fits without scrolling.
                EmptyView()
            } else if let summary = model.lastSummary {
                Text("Last: " + summary + " · " + transferText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        }
        .padding(.horizontal, 2)
        .onAppear {
            refreshSensorBanner()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshSensorBanner()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            refreshSensorBanner()
        }
        .sheet(isPresented: $showPicker) {
            WorkoutPickerView(selection: $model.definitionId) {
                showPicker = false
            }
        }
    }

    private func refreshSensorBanner() {
        let banner: SensorBanner? = WorkoutSensorBanner.current()
        if banner != sensorBanner {
            sensorBanner = banner
        }
    }

    private var transferText: String {
        let pending = link.pendingTransfers
        return pending > 0 ? "↑\(pending)" : "sent"
    }

    /// "5 per round · 40:00" (AMRAP), "3 rounds of 3", "Crown at each change" (Free), "16 segments".
    static func tileDetail(_ definition: WorkoutDefinition, count: Int) -> String {
        if definition.id == WorkoutLibrary.free.id {
            return "Crown at each change"
        }
        if let r = definition.roundSize, r >= 1, count > r {
            var repeats: Bool = true
            for i in r..<count where definition.segments[i].title != definition.segments[i % r].title {
                repeats = false
            }
            if repeats {
                if definition.format == .amrap, let cap = definition.timeCapSeconds {
                    let total: Int = Int(cap.rounded())
                    return "\(r) per round · " + String(format: "%d:%02d", total / 60, total % 60)
                }
                return "\((count + r - 1) / r) rounds of \(r)"
            }
        }
        return "\(count) segment\(count == 1 ? "" : "s")"
    }

    private var workoutTile: some View {
        let definition = model.selectedDefinition
        let count = definition.segments.count
        return HStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("WORKOUT")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Text(definition.name)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(WorkoutStartView.tileDetail(definition, count: count) + (model.isSelectedFromPhone ? " · from iPhone" : ""))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11)))
    }
}
