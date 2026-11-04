import SwiftUI
import UIKit
import BarPathKit

/// Home: Effort for the day, the days of the week, and that day's workouts as flat blocks
/// (docs/DESIGN_GUIDELINES.md, stories N2, N3, N9). Planned blocks come from the library's
/// `scheduled_on`; done blocks are the day's results and lifting sessions.
struct TodayView: View {
    let onStartWorkout: () -> Void
    let onRecordLift: () -> Void

    @EnvironmentObject private var lifts: LiftStore
    @EnvironmentObject private var workouts: WorkoutStore
    @ObservedObject private var library = WorkoutLibraryStore.shared
    @State private var selected: Date = Calendar.current.startOfDay(for: Date())
    /// The day this screen last treated as today: moves `selected` along when the date changes.
    @State private var shownToday: Date = Calendar.current.startOfDay(for: Date())
    @Environment(\.scenePhase) private var scenePhase
    @State private var effortDays: [String: WorkoutEffort.Day] = [:]
    @State private var scores: [UUID: WorkoutCardScore] = [:]

    private var calendar: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private var today: Date {
        return calendar.startOfDay(for: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topLine
                    effortHeader
                    if isNewTester {
                        newTester
                    } else {
                        daysStrip
                        Text(dayLine)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .padding(.top, 10)
                            .padding(.bottom, 18)
                        blocksList
                        weekLine
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WorkoutRoute.self) { route in
                WorkoutDetailView(resultId: route.id)
            }
            .navigationDestination(for: SessionRoute.self) { route in
                SessionDetailView(sessionId: route.id)
            }
            .navigationDestination(for: LiftRoute.self) { route in
                LiftDetailView(liftId: route.id)
            }
            .onReceive(workouts.$results) { (results: [WorkoutResult]) in
                effortDays = EffortDays.make(results)
                scores = WorkoutLastScore.byResult(results)
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                followToday()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { followToday() }
            }
        }
    }

    private func followToday() {
        let now: Date = today
        if now == shownToday { return }
        if selected == shownToday { selected = now }
        shownToday = now
    }

    // MARK: Top

    private var topLine: some View {
        HStack {
            Text(topText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            AccountMenu()
        }
        .frame(minHeight: 44)
    }

    private var topText: String {
        let date: String = Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        guard let program = library.todayWorkouts.compactMap({ (w: LibraryWorkout) -> String? in w.program }).first,
              !program.isEmpty else { return date }
        return date + " \u{00B7} " + program
    }

    private var effortHeader: some View {
        let h: EffortHeader = header
        return HStack(spacing: 16) {
            if !isNewTester {
                EffortRing(value: h.value, share: h.share)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isNewTester ? "Welcome" : "Effort")
                    .font(.system(size: 17, weight: .medium))
                Text(h.line1)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
                if let line2 = h.line2 {
                    Text(line2)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 20)
    }

    private struct EffortHeader {
        let value: String
        let share: Double
        let line1: String
        let line2: String?
    }

    private func key(_ date: Date) -> String {
        return LibraryDay.string(date)
    }

    private func hasActivity(_ day: Date) -> Bool {
        return !results(on: day).isEmpty || !sessions(on: day).isEmpty
    }

    private var hardestDay: Double {
        return effortDays.values.compactMap { (d: WorkoutEffort.Day) -> Double? in d.effort }.max() ?? 0
    }

    private var header: EffortHeader {
        if isNewTester {
            return EffortHeader(value: "", share: 0, line1: "Your week starts with your first workout", line2: nil)
        }
        if let day = effortDays[key(selected)] {
            return EffortHeader(value: EffortDays.text(day.effort),
                                share: hardestDay > 0 ? (day.effort ?? 0) / hardestDay : 0,
                                line1: String(Int(day.minutes.rounded())) + " min",
                                line2: rankLine(day))
        }
        if hasActivity(selected) {
            return EffortHeader(value: "\u{2014}", share: 0, line1: "Lifting, no heart rate saved", line2: nil)
        }
        if calendar.isDate(selected, inSameDayAs: today) {
            var line2: String? = nil
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
               let d = effortDays[key(yesterday)], let e = d.effort {
                line2 = "Yesterday " + EffortDays.text(e)
            }
            return EffortHeader(value: "0", share: 0, line1: "Nothing yet today", line2: line2)
        }
        let line: String = selected > today ? "Still to come" : "No workout"
        return EffortHeader(value: "\u{2014}", share: 0, line1: line, line2: nil)
    }

    private func rankLine(_ day: WorkoutEffort.Day) -> String? {
        guard let effort = day.effort else { return nil }
        let all: [Double] = effortDays.values.compactMap { (d: WorkoutEffort.Day) -> Double? in d.effort }
        if all.count < 2 { return nil }
        let rank: Int = all.filter { (e: Double) -> Bool in e > effort }.count
        if rank == 0 { return "Highest of your " + String(all.count) + " days" }
        if rank == 1 { return "Second highest of your " + String(all.count) + " days" }
        return nil
    }

    // MARK: Days

    private var week: [Date] {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: selected) else { return [selected] }
        return (0..<7).compactMap { (i: Int) -> Date? in
            calendar.date(byAdding: .day, value: i, to: interval.start)
        }
    }

    private var daysStrip: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(week, id: \.self) { (day: Date) in
                    dayCell(day)
                }
            }
            Divider()
        }
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { (value: DragGesture.Value) in
                if abs(value.translation.width) <= abs(value.translation.height) { return }
                let weeks: Int = value.translation.width < 0 ? 1 : -1
                if let moved = calendar.date(byAdding: .day, value: 7 * weeks, to: selected) {
                    selected = moved
                }
            }
        )
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected: Bool = calendar.isDate(day, inSameDayAs: selected)
        let isToday: Bool = calendar.isDate(day, inSameDayAs: today)
        let letter: String = String(day.formatted(.dateTime.weekday(.abbreviated)).prefix(1))
        return Button {
            selected = day
        } label: {
            VStack(spacing: 3) {
                Text(letter)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 17, weight: isSelected || isToday ? .medium : .regular))
                    .foregroundStyle(isToday ? Theme.accent : Color.primary)
                Text(mark(day))
                    .font(.system(size: 11))
                    .foregroundStyle(hasActivity(day) ? Color.green : Color.secondary)
                    .frame(height: 13)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Color.primary : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
        .accessibilityValue(hasActivity(day) ? "Done" : (planned(on: day).isEmpty ? "" : "Planned"))
    }

    private func mark(_ day: Date) -> String {
        if hasActivity(day) { return "\u{2713}" }
        return planned(on: day).isEmpty ? "" : "\u{25CB}"
    }

    // MARK: Data of a day

    private func results(on day: Date) -> [WorkoutResult] {
        return workouts.results.filter { (r: WorkoutResult) -> Bool in
            calendar.isDate(r.startDate, inSameDayAs: day)
        }
    }

    private func sessions(on day: Date) -> [LiftSessionGroup] {
        return lifts.sessions.filter { (s: LiftSessionGroup) -> Bool in
            calendar.isDate(s.startDate, inSameDayAs: day)
        }
    }

    private func planned(on day: Date) -> [LibraryWorkout] {
        let k: String = key(day)
        return library.workouts.filter { (w: LibraryWorkout) -> Bool in w.scheduledOn == k }
    }

    /// Planned workouts of the selected day that have no result that day yet.
    private var openPlanned: [LibraryWorkout] {
        let done: [WorkoutResult] = results(on: selected)
        return planned(on: selected).filter { (w: LibraryWorkout) -> Bool in
            !done.contains(where: { (r: WorkoutResult) -> Bool in
                r.definition.id == w.id || WorkoutHistory.isSameWorkout(w.definition, r.definition)
            })
        }
    }

    private var isNewTester: Bool {
        return workouts.results.isEmpty && lifts.sessions.isEmpty && library.workouts.isEmpty
    }

    private var dayLine: String {
        let isToday: Bool = calendar.isDate(selected, inSameDayAs: today)
        let label: String = isToday ? "Today" : WorkoutResultCard.dateLabel(selected)
        let done: Int = results(on: selected).count + sessions(on: selected).count
        let open: Int = openPlanned.count
        if done + open == 0 { return label }
        if open == 0 { return label + " \u{00B7} " + String(done) + " done" }
        return label + " \u{00B7} " + String(done) + " of " + String(done + open) + " done"
    }

    // MARK: Blocks

    @ViewBuilder
    private var blocksList: some View {
        let done: [WorkoutResult] = results(on: selected)
        let liftSessions: [LiftSessionGroup] = sessions(on: selected)
        let open: [LibraryWorkout] = openPlanned
        if done.isEmpty && liftSessions.isEmpty && open.isEmpty {
            emptyDay
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(done) { (r: WorkoutResult) in
                    NavigationLink(value: WorkoutRoute(id: r.id)) {
                        doneBlock(r)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(liftSessions) { (s: LiftSessionGroup) in
                    NavigationLink(value: SessionRoute(id: s.id)) {
                        sessionBlock(s)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(open.enumerated()), id: \.element.id) { (item: (offset: Int, element: LibraryWorkout)) in
                    NavigationLink {
                        WorkoutPreviewView(definition: item.element.definition,
                                           meta: WorkoutCardMeta.text(item.element))
                    } label: {
                        plannedBlock(item.element, isNext: item.offset == 0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func blockFrame<Content: View>(_ segments: [LineSegment],
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
        }
        .padding(.leading, 14)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            BlockLine(segments: segments)
        }
        .contentShape(Rectangle())
    }

    private func tagLine(_ card: WorkoutCard) -> String {
        var parts: [String] = []
        if let block = card.blockTag { parts.append(block.label) }
        if let type = card.typeTag { parts.append(type.label) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func titleRow(_ name: String, score: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(name)
                .font(.system(size: 18, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
            if let s = score {
                Text(s)
                    .font(.system(size: 18, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private func doneBlock(_ r: WorkoutResult) -> some View {
        let resolved: (definition: WorkoutDefinition, program: String?) =
            WorkoutResultCard.resolve(r, library: library.workouts)
        let card: WorkoutCard = WorkoutCard.make(definition: resolved.definition)
        let score: WorkoutCardScore? = scores[r.id]
        return blockFrame(LineSegment.done(r)) {
            Text(tagLine(card))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            titleRow(card.name, score: score?.value)
            if let context = score?.context {
                Text(context)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sessionBlock(_ s: LiftSessionGroup) -> some View {
        let count: Int = s.lifts.count
        return blockFrame(LineSegment.session(s)) {
            Text("Lifting")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            titleRow(s.liftTypesSummary, score: s.bestPeakVelocity.map { (v: Double) -> String in Fmt.mps(v) + " m/s" })
            Text(String(count) + (count == 1 ? " lift" : " lifts"))
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
    }

    private func plannedBlock(_ w: LibraryWorkout, isNext: Bool) -> some View {
        let card: WorkoutCard = WorkoutCard.make(definition: w.definition)
        let last: String? = WorkoutLastScore.byDefinition([w.definition], results: workouts.results)[w.id]
        let lines: [WorkoutCard.Line] = card.visibleLines().lines
        return blockFrame(LineSegment.planned(w.definition)) {
            Text(tagLine(card))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            titleRow(card.name, score: nil)
            if let domain = card.timeDomainLine {
                Text(domain)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
            }
            if let scheme = card.repSchemeLine {
                Text(scheme)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { (item: (offset: Int, element: WorkoutCard.Line)) in
                WorkoutCardView.lineText(item.element)
                    .font(.system(size: 14))
            }
            if let cap = card.capLine {
                Text(cap)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            if let l = last {
                Text("Last time " + l)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            if isNext {
                Text("Send to watch \u{203A}")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 4)
            }
        }
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selected > today ? "Nothing posted for this day yet." : "Nothing planned.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Button("Start a workout \u{203A}", action: onStartWorkout)
                .font(.system(size: 15, weight: .medium))
                .frame(minHeight: 40)
        }
    }

    private var newTester: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose a workout and send it to your watch, or record a lift.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
            Button("Start a workout \u{203A}", action: onStartWorkout)
                .font(.system(size: 15, weight: .medium))
                .frame(minHeight: 40)
            Button("Record a lift \u{203A}", action: onRecordLift)
                .font(.system(size: 15, weight: .medium))
                .frame(minHeight: 40)
        }
    }

    @ViewBuilder
    private var weekLine: some View {
        let days: [WorkoutEffort.Day] = week.compactMap { (d: Date) -> WorkoutEffort.Day? in effortDays[key(d)] }
        if !days.isEmpty {
            let total: Double = days.compactMap { (d: WorkoutEffort.Day) -> Double? in d.effort }.reduce(0, +)
            let minutes: Double = days.map { (d: WorkoutEffort.Day) -> Double in d.minutes }.reduce(0, +)
            HStack {
                Text(week.contains(today) ? "This week" : "That week")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("Effort " + EffortDays.text(total) + " \u{00B7} " + String(Int(minutes.rounded())) + " min")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, 30)
        }
    }
}

/// The avatar: a dot for the watch, and a standard menu with Open on watch, Settings and Sign out.
struct AccountMenu: View {
    @EnvironmentObject private var link: PhoneLink
    @EnvironmentObject private var cloud: CloudAccount
    @State private var showSettings: Bool = false

    var body: some View {
        Menu {
            Button {
                link.launchWatchApp()
            } label: {
                // A menu only keeps a colour on an image that carries its own.
                Label {
                    Text("Open on watch")
                } icon: {
                    Image(uiImage: watchDot)
                }
            }
            Button("Settings") { showSettings = true }
            if cloud.isSignedIn {
                Button("Sign out") {
                    Task { await cloud.signOut() }
                }
            }
        } label: {
            avatar
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Account. " + link.watchStatusText)
        .navigationDestination(isPresented: $showSettings) {
            SettingsView()
        }
    }

    /// Green when the watch app is reachable, orange when not.
    private var watchDot: UIImage {
        let color: UIColor = link.isReachable ? UIColor.systemGreen : UIColor.systemOrange
        let image: UIImage? = UIImage(systemName: "circle.fill")?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        return image ?? UIImage()
    }

    private var avatar: some View {
        Image(systemName: "person")
            .font(.system(size: 15))
            .foregroundStyle(.secondary)
            .frame(width: 36, height: 36)
            .overlay(Circle().strokeBorder(Color(uiColor: .separator), lineWidth: 1))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(link.isReachable ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
    }
}
