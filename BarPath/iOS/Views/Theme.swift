import SwiftUI
import UIKit
import BarPathKit

enum Theme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.08)

    /// Slow → fast: blue, teal, green, yellow, red.
    static let speedColors: [Color] = [
        Color(red: 0.22, green: 0.45, blue: 1.00),
        Color(red: 0.10, green: 0.78, blue: 0.80),
        Color(red: 0.45, green: 0.85, blue: 0.25),
        Color(red: 1.00, green: 0.78, blue: 0.10),
        Color(red: 1.00, green: 0.28, blue: 0.22)
    ]
    static let speedGradient = Gradient(colors: speedColors)

    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let tileBackground = Color(uiColor: .tertiarySystemGroupedBackground)

    static func confidenceColor(_ confidence: Confidence) -> Color {
        switch confidence.rawValue {
        case "high": return Color.green
        case "medium": return Color.yellow
        default: return Color.red
        }
    }

    static func markerColor(_ kind: MarkerKind) -> Color {
        switch kind {
        case .start: return Color.gray
        case .maxHeight: return accent
        case .catchPoint: return Color.purple
        }
    }
}

/// Number formatting: cm with one decimal, m/s with two.
enum Fmt {
    static func cm(_ meters: Double) -> String {
        return String(format: "%.1f", meters * 100.0)
    }

    static func signedCm(_ meters: Double) -> String {
        return String(format: "%+.1f", meters * 100.0)
    }

    static func mps(_ value: Double) -> String {
        return String(format: "%.2f", value)
    }

    static func seconds(_ value: Double) -> String {
        return String(format: "%.2f s", value)
    }

    static func load(_ kg: Double?) -> String? {
        guard let kg = kg else { return nil }
        if kg.rounded() == kg {
            return String(format: "%.0f kg", kg)
        }
        return String(format: "%.1f kg", kg)
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    static func bytes(_ count: Int64) -> String {
        return ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

enum Labels {
    static func endReason(_ reason: EndReason?) -> String {
        guard let reason = reason else { return "—" }
        switch reason.rawValue {
        case "drop": return "Dropped"
        case "returned": return "Returned to start"
        case "timeout": return "Timed out"
        case "manual": return "Ended manually"
        case "sessionEnd": return "Session ended"
        default: return reason.rawValue
        }
    }

    static func confidence(_ confidence: Confidence) -> String {
        switch confidence.rawValue {
        case "high": return "High"
        case "medium": return "Medium"
        case "low": return "Low"
        default: return confidence.rawValue
        }
    }

    static func liftTypeName(raw: String?) -> String? {
        guard let raw = raw else { return nil }
        return LiftType(rawValue: raw)?.displayName ?? raw
    }

    /// Spec §9, shown in the app.
    static let knownLimitations: [String] = [
        "The watch sits on your wrist, not on the bar: expect a few cm of offset (no lever-arm correction yet).",
        "Forward direction assumes the watch is worn on the back of the wrist.",
        "The horizontal path is less reliable than the vertical one.",
        "Standing up from the set position without pulling the bar can produce a small false lift."
    ]
}

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.cardBackground)
            )
    }
}

extension View {
    func card() -> some View {
        return modifier(CardBackground())
    }
}

struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Theme.confidenceColor(confidence))
                .frame(width: 8, height: 8)
            Text(Labels.confidence(confidence))
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Theme.confidenceColor(confidence).opacity(0.18)))
    }
}

struct SpeedLegend: View {
    let maxSpeed: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("Speed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("0")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Capsule()
                .fill(LinearGradient(gradient: Theme.speedGradient, startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
            Text("\(Fmt.mps(maxSpeed)) m/s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
