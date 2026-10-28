import SwiftUI
import BarPathKit

/// 2×3 grid of `WorkoutLibrary.all` short names, no scrolling. Selected = filled.
/// Tap selects and closes.
struct WorkoutPickerView: View {
    @Binding var selection: String
    let onDone: () -> Void

    private var definitions: [WorkoutDefinition] { WorkoutLibrary.all }

    var body: some View {
        let defs = definitions
        let rows: Int = (defs.count + 1) / 2
        return VStack(spacing: 6) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 6) {
                    tile(defs, index: row * 2)
                    tile(defs, index: row * 2 + 1)
                }
            }
        }
        .padding(.horizontal, 2)
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
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(selected ? .black : .white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 4)
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
