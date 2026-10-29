import SwiftUI
import UIKit
import BarPathKit

// Colour tokens, selection styling and small shared pieces of the workout overview.
// Values are the tokens of the approved mockup (light / dark).

private func ovColor(_ light: UInt32, _ dark: UInt32) -> Color {
    let provider: (UITraitCollection) -> UIColor = { (traits: UITraitCollection) -> UIColor in
        let hex: UInt32 = traits.userInterfaceStyle == .dark ? dark : light
        let r: CGFloat = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g: CGFloat = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b: CGFloat = CGFloat(hex & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }
    return Color(uiColor: UIColor(dynamicProvider: provider))
}

extension Theme {
    static let ovRun: Color = ovColor(0x2F6BF0, 0x5A8CFF)
    static let ovRunBand: Color = ovColor(0xE3EBFD, 0x1C2947)
    static let ovStation: Color = ovColor(0xF0600A, 0xF57228)
    static let ovStationBand: Color = ovColor(0xFDE8DA, 0x42251A)
    static let ovStationMid: Color = ovColor(0xF59A63, 0xB85C2B)
    static let ovStationLight: Color = ovColor(0xF9C7A6, 0x6E3D24)
    static let ovRest: Color = ovColor(0x8E8E93, 0x8E8E93)
    static let ovRestBand: Color = ovColor(0xEEEEF1, 0x29292C)
    static let ovHR: Color = ovColor(0xD9251A, 0xFF5B4F)
    static let ovFast: Color = ovColor(0x0F9C8C, 0x3FD1BE)
    static let ovSlow: Color = ovColor(0xB03C78, 0xE77BB2)
    static let ovGrid: Color = ovColor(0xE4E4EA, 0x38383C)
    static let ovSel: Color = ovColor(0x111114, 0xF5F5F7)
    static let ovFg: Color = Color(uiColor: UIColor.label)
    static let ovFg2: Color = Color(uiColor: UIColor.secondaryLabel)
    static let ovFg3: Color = Color(uiColor: UIColor.tertiaryLabel)

    static let ovZoneColors: [Color] = [
        ovColor(0xFBE3E0, 0x3E2220),
        ovColor(0xF6B8B0, 0x6E2B25),
        ovColor(0xEE8274, 0xA9392E),
        ovColor(0xDA4A3B, 0xE0493A),
        ovColor(0x9E1C12, 0xFF8577)
    ]

    /// Zone 1...5 colour (clamped).
    static func ovZone(_ zone: Int) -> Color {
        let i: Int = Swift.min(Swift.max(zone - 1, 0), ovZoneColors.count - 1)
        return ovZoneColors[i]
    }

    /// Pale band behind the curve.
    static func ovBand(_ kind: SegmentKind) -> Color {
        switch kind {
        case .run: return ovRunBand
        case .station: return ovStationBand
        case .rest: return ovRestBand
        case .transition: return ovRestBand
        }
    }

    /// Solid colour of a kind (top edge, swatches, table marks).
    static func ovSolid(_ kind: SegmentKind) -> Color {
        switch kind {
        case .run: return ovRun
        case .station: return ovStation
        case .rest: return ovRest
        case .transition: return ovRest
        }
    }

    /// Part colours of one set / round: mid, full, light, then repeating.
    static func ovPartColor(_ index: Int) -> Color {
        let palette: [Color] = [ovStationMid, ovStation, ovStationLight]
        let i: Int = ((index % 3) + 3) % 3
        return palette[i]
    }
}

// MARK: - Formatting

enum OverviewFormat {
    static func shortDate(_ date: Date) -> String {
        let style: Date.FormatStyle = Date.FormatStyle().month(.abbreviated).day()
        return date.formatted(style)
    }

    static func timeOfDay(_ date: Date) -> String {
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func dayAndTime(_ date: Date) -> String {
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Faster (<= 0) teal, slower plum.
    static func deltaColor(_ seconds: Double?) -> Color {
        guard let s = seconds else { return Theme.ovFg2 }
        return s <= 0 ? Theme.ovFast : Theme.ovSlow
    }

    static func paceText(_ secondsPerKm: Double?) -> String {
        return SummaryFormat.pace(secondsPerKm)
    }
}

// MARK: - Selection state (linked highlight)

enum SelState {
    /// Nothing is selected anywhere.
    case idle
    /// This element is the selection or lies inside it.
    case selected
    /// This element contains the selection (a round while one of its cells is selected).
    case containing
    /// Something else is selected: fade this one.
    case dimmed
}

enum OverviewSel {
    /// Element covering segment indices a...b against the shared selection.
    static func state(_ selection: ClosedRange<Int>?, _ a: Int, _ b: Int) -> SelState {
        guard let s = selection else { return SelState.idle }
        if a >= s.lowerBound && b <= s.upperBound { return SelState.selected }
        if a <= s.lowerBound && b >= s.upperBound { return SelState.containing }
        return SelState.dimmed
    }
}

struct SelectableStyle: ViewModifier {
    let state: SelState
    let corner: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion: Bool

    private var strokeColor: Color {
        switch state {
        case .selected: return Theme.ovSel
        case .containing: return Theme.ovFg3
        case .idle: return Color.clear
        case .dimmed: return Color.clear
        }
    }

    private var strokeWidth: CGFloat {
        return state == .selected ? 2.0 : 1.0
    }

    func body(content: Content) -> some View {
        content
            .opacity(state == .dimmed ? 0.42 : 1.0)
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
            )
            .animation(reduceMotion ? nil : Animation.easeInOut(duration: 0.15), value: state)
            .accessibilityAddTraits(state == .selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }
}

extension View {
    func selectable(_ state: SelState, corner: CGFloat = 10) -> some View {
        return modifier(SelectableStyle(state: state, corner: corner))
    }
}

// MARK: - Flow layout (wrapping rows of facts)

struct FlowLayout: Layout {
    var hSpacing: CGFloat = 14
    var vSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth: CGFloat = proposal.width ?? CGFloat.infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for sub in subviews {
            let size: CGSize = sub.sizeThatFits(ProposedViewSize.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            usedWidth = Swift.max(usedWidth, x + size.width)
            x += size.width + hSpacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size: CGSize = sub.sizeThatFits(ProposedViewSize.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + vSpacing
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), anchor: UnitPoint.topLeading,
                      proposal: ProposedViewSize(size))
            x += size.width + hSpacing
            rowHeight = Swift.max(rowHeight, size.height)
        }
    }
}

// MARK: - Shared small views

/// "Label value" pair used in the hero facts and the chip: small grey label, heavy number.
struct OvFact: View {
    let label: String
    let value: String
    var unit: String = ""
    var valueColor: Color = Theme.ovFg

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            if !label.isEmpty {
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
            }
            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
            if !unit.isEmpty {
                Text(unit)
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
            }
        }
        .fixedSize()
    }
}

/// Section title with an optional grey caption.
struct OvSectionHeader: View {
    let title: String
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if !caption.isEmpty {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(Theme.ovFg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Tile with a small caps key, a heavy value and a grey detail line.
struct OvStatTile: View {
    let key: String
    let value: String
    let detail: String
    var valueColor: Color = Theme.ovFg

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.ovFg2)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ovFg2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.tileBackground)
        )
    }
}

/// Coloured square + text, for legends.
struct OvLegendItem: View {
    let color: Color
    let text: String
    var outlined: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(outlined ? Theme.ovGrid : Color.clear, lineWidth: 1)
                )
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ovFg2)
        }
        .fixedSize()
    }
}

/// Hairline between the sections of one card.
struct OvSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.ovGrid)
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}
