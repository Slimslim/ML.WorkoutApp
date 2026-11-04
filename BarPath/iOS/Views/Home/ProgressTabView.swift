import SwiftUI
import Charts
import BarPathKit

/// First version of Progress: Effort per week and per day, real data only (story N11).
struct ProgressTabView: View {
    @EnvironmentObject private var workouts: WorkoutStore
    @State private var days: [WorkoutEffort.Day] = []

    private struct Bar: Identifiable {
        let id: Date
        let effort: Double
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var dayBars: [Bar] {
        let today: Date = calendar.startOfDay(for: Date())
        let byKey: [String: Double] = Dictionary(
            days.map { (d: WorkoutEffort.Day) -> (String, Double) in (d.day, d.effort ?? 0) },
            uniquingKeysWith: { (a: Double, _: Double) -> Double in a })
        return (0..<14).reversed().compactMap { (back: Int) -> Bar? in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return Bar(id: day, effort: byKey[LibraryDay.string(day)] ?? 0)
        }
    }

    private var weekBars: [Bar] {
        var totals: [Date: Double] = [:]
        for d in days {
            guard let date = LibraryDay.date(d.day),
                  let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { continue }
            totals[week, default: 0] += d.effort ?? 0
        }
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return (0..<8).reversed().compactMap { (back: Int) -> Bar? in
            guard let week = calendar.date(byAdding: .day, value: -7 * back, to: thisWeek) else { return nil }
            return Bar(id: week, effort: totals[week] ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to show yet", systemImage: "chart.bar")
                    } description: {
                        Text("Finish a workout with your watch and your Effort appears here.")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 32) {
                            chart("Effort per week", bars: weekBars, unit: .weekOfYear, format: .dateTime.month(.abbreviated).day())
                            chart("Effort per day", bars: dayBars, unit: .day, format: .dateTime.day())
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 110)
                    }
                }
            }
            .navigationTitle("Progress")
            .onReceive(workouts.$results) { (results: [WorkoutResult]) in
                days = WorkoutEffort.days(results, calendar: Calendar.current)
            }
        }
    }

    private func chart(_ title: String, bars: [Bar], unit: Calendar.Component,
                       format: Date.FormatStyle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
            Chart(bars) { (bar: Bar) in
                BarMark(x: .value("Date", bar.id, unit: unit), y: .value("Effort", bar.effort))
                    .foregroundStyle(Color.primary)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: format)
                }
            }
            .frame(height: 150)
        }
    }
}
