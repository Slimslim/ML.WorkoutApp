import SwiftUI
import BarPathKit

/// Workout mode setup, no scrolling: phone dot + DATA chip, the workout tile (tap → picker),
/// a big green START, and the last workout's summary.
struct WorkoutStartView: View {
    @EnvironmentObject var model: WorkoutSessionModel
    @ObservedObject private var link = PhoneLink.shared
    @State private var showPicker = false

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
            .frame(minHeight: 60)

            if let summary = model.lastSummary {
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
        .sheet(isPresented: $showPicker) {
            WorkoutPickerView(selection: $model.definitionId) {
                showPicker = false
            }
        }
    }

    private var transferText: String {
        let pending = link.pendingTransfers
        return pending > 0 ? "↑\(pending)" : "sent"
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
                Text("\(count) segment\(count == 1 ? "" : "s")")
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
