import SwiftUI
import BarPathKit

/// 3×3 grid of `WorkoutLibrary.all` short names, no scrolling. Selected = filled.
/// Tap selects and closes.
struct WorkoutPickerView: View {
    @Binding var selection: String
    let onDone: () -> Void

    private var definitions: [WorkoutDefinition] { WorkoutLibrary.all }

    var body: some View {
        let defs = definitions
        let columns: Int = 3
        let rows: Int = (defs.count + columns - 1) / columns
        return VStack(spacing: 5) {
            practiceRow
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 5) {
                    tile(defs, index: row * columns)
                    tile(defs, index: row * columns + 1)
                    tile(defs, index: row * columns + 2)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    /// W22: the practice workout is the first row of the list (opens once this sheet is closed).
    private var practiceRow: some View {
        return Button {
            onDone()
            WorkoutPracticeLauncher.shared.open(afterSeconds: 0.7)
        } label: {
            Text("Practice · 1 min")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(SegmentPalette.crownForward)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tile(_ defs: [WorkoutDefinition], index: Int) -> some View {
        if index < defs.count {
            let definition = defs[index]
            let selected = definition.id == selection
            Button {
                selection = definition.id
                onDone()
            } label: {
                Text(definition.shortName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? .black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(selected ? Color.green : Color(white: 0.15))
                    )
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
