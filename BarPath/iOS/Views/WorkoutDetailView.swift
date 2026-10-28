import SwiftUI
import Charts
import BarPathKit

/// Header, split table, per-segment bar chart and share buttons for one workout.
struct WorkoutDetailView: View {
    let resultId: UUID
    @EnvironmentObject private var store: WorkoutStore

    var body: some View {
        Group {
            if let result = store.result(id: resultId) {
                content(result)
            } else {
                ContentUnavailableView("Workout deleted", systemImage: "trash")
            }
        }
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ result: WorkoutResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                WorkoutHeaderCard(result: result)
                WorkoutSplitTable(result: result)
                WorkoutSegmentChart(result: result)
                WorkoutShareCard(result: result)
            }
            .padding(16)
        }
        .background(Theme.pageBackground)
    }
}

// MARK: - Header

struct WorkoutHeaderCard: View {
    let result: WorkoutResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.definition.name)
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                Text(result.startDate.formatted(date: .complete, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(WorkoutFmt.hms(result.totalSeconds))
                .font(.system(size: 52, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if result.finishDate == nil {
                Label("Ended before the last segment", systemImage: "flag.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.orange)
            }
            HStack(spacing: 10) {
                tile("Runs", WorkoutFmt.hms(result.runSeconds), Theme.workoutRun)
                tile("Stations", WorkoutFmt.hms(result.stationSeconds), Theme.workoutStation)
            }
            HStack(spacing: 10) {
                tile("HR avg", WorkoutFmt.bpm(result.heartRateAvg), Color.red)
                tile("HR max", WorkoutFmt.bpm(result.heartRateMax), Color.red)
            }
        }
        .card()
    }

    private func tile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(value)
                .font(.title3.weight(.bold))
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.tileBackground)
        )
    }
}

// MARK: - Split table

struct WorkoutSplitTable: View {
    let result: WorkoutResult

    private var firstStart: Double {
        return result.segments.first?.start ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Splits")
                .font(.headline)
                .padding(.bottom, 8)
            headerRow
            Divider()
            ForEach(result.segments, id: \.index) { segment in
                row(segment)
                Divider()
            }
        }
        .card()
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("#")
                .frame(width: 24, alignment: .leading)
            Text("Segment")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Split / total")
                .frame(width: 76, alignment: .trailing)
            Text("HR")
                .frame(width: 30, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private func detailLine(_ segment: SegmentResult) -> String {
        var parts: [String] = []
        if let distance = segment.distance {
            parts.append(WorkoutFmt.distance(distance))
        }
        if segment.kind == .run {
            if let pace = segment.paceSecondsPerKm {
                parts.append(WorkoutFmt.pace(pace))
            }
            if let cadence = segment.cadence {
                parts.append(String(format: "%.0f spm", cadence))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func row(_ segment: SegmentResult) -> some View {
        let isRun: Bool = segment.kind == .run
        let line: String = detailLine(segment)
        let cumulative: Double = segment.end - firstStart
        return HStack(alignment: .top, spacing: 8) {
            Text("\(segment.index + 1)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(isRun ? Theme.workoutRun : Theme.workoutStation)
                .frame(width: 24, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(segment.title)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if !line.isEmpty {
                    Text(line)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WorkoutFmt.clock(segment.duration))
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                Text(WorkoutFmt.clock(cumulative))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 76, alignment: .trailing)
            Text(WorkoutFmt.bpm(segment.heartRateAvg))
                .font(.subheadline)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Chart

struct WorkoutSegmentChart: View {
    let result: WorkoutResult

    private func label(_ segment: SegmentResult) -> String {
        return "\(segment.index + 1) \(segment.title)"
    }

    private func kindName(_ segment: SegmentResult) -> String {
        return segment.kind == .run ? "Run" : "Station"
    }

    var body: some View {
        let labels: [String] = result.segments.map { label($0) }
        VStack(alignment: .leading, spacing: 8) {
            Text("Time per segment")
                .font(.headline)
            Chart {
                ForEach(result.segments, id: \.index) { segment in
                    BarMark(
                        x: .value("Seconds", segment.duration),
                        y: .value("Segment", label(segment))
                    )
                    .foregroundStyle(by: .value("Type", kindName(segment)))
                }
            }
            .chartYScale(domain: labels)
            .chartForegroundStyleScale(["Run": Theme.workoutRun, "Station": Theme.workoutStation])
            .chartLegend(position: .bottom)
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let seconds = value.as(Double.self) {
                            Text(WorkoutFmt.clock(seconds))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                }
            }
            .frame(height: CGFloat(result.segments.count) * 28.0 + 60.0)
        }
        .card()
    }
}

// MARK: - Share

struct WorkoutShareCard: View {
    let result: WorkoutResult

    var body: some View {
        let jsonURL: URL = WorkoutFiles.fileURL(id: result.id)
        let csvURL: URL? = WorkoutFiles.csvURL(for: result)
        VStack(alignment: .leading, spacing: 12) {
            ShareLink(item: jsonURL) {
                Label("Share result (JSON)", systemImage: "square.and.arrow.up")
            }
            if let csvURL = csvURL {
                ShareLink(item: csvURL) {
                    Label("Share motion recording (CSV)", systemImage: "waveform.path.ecg")
                }
            } else if result.recordingFileName != nil {
                Text("The motion recording has not arrived on this iPhone yet (or was deleted from Debug).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .card()
    }
}
