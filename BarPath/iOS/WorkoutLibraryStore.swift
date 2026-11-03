import Foundation
import Supabase
import BarPathKit

/// One workout of the cloud library (Supabase table `workout_library`, docs/WORKOUT_LIBRARY.md).
/// `definition` is the WorkoutDefinition JSON as BarPathKit encodes it; ids look like
/// "lib.<program>.<yyyymmdd>.<slug>" so they never collide with a built-in id (the watch prefers
/// its built-in version when the ids match).
struct LibraryWorkout: Codable, Equatable, Identifiable {
    let definition: WorkoutDefinition
    let program: String?
    /// Postgres `date` as sent by the API, "yyyy-MM-dd": the day it is programmed.
    let scheduledOn: String?
    let updatedAt: String?

    var id: String { return definition.id }

    enum CodingKeys: String, CodingKey {
        case definition
        case program
        case scheduledOn = "scheduled_on"
        case updatedAt = "updated_at"
    }

    /// "Mon, Nov 2" or nil.
    var dateLabel: String? {
        guard let date = LibraryDay.date(scheduledOn) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Mayhem · Mon, Nov 2", "Mayhem", "Mon, Nov 2" or nil.
    var caption: String? {
        var parts: [String] = []
        if let program = program, !program.isEmpty { parts.append(program) }
        if let label = dateLabel { parts.append(label) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Library workouts of one program (or "Library" when the row has none), newest first.
struct LibraryGroup: Identifiable {
    let title: String
    let workouts: [LibraryWorkout]
    var id: String { return title }
}

/// "yyyy-MM-dd" days in the phone's own calendar and time zone.
enum LibraryDay {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.autoupdatingCurrent
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Noon of that day: a formatter's midnight does not exist on days where DST starts at
    /// midnight (Chile, Paraguay…), and it would return nil there.
    static func date(_ text: String?) -> Date? {
        guard let text = text, !text.isEmpty else { return nil }
        let parts: [Int] = String(text.prefix(10)).split(separator: "-").compactMap { (p: Substring) -> Int? in Int(p) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.autoupdatingCurrent
        return calendar.date(from: components)
    }

    static func string(_ date: Date) -> String {
        return formatter.string(from: date)
    }

    static var today: String {
        return string(Date())
    }
}

/// Workouts added in the database (no app update needed). Fetched while signed in, cached as
/// JSON in Application Support (not Documents: Documents/Lifts, Workouts and Debug are uploaded),
/// so the chooser works offline and signed out with the last good list.
///
/// Refreshed by the Workouts tab (appear, app foreground) and the chooser (appear, pull to refresh).
/// v1: everyone reads the shared library (`owner` is null). When private workouts arrive, the
/// cache must be cleared when the signed-in user changes.
@MainActor
final class WorkoutLibraryStore: ObservableObject {
    static let shared = WorkoutLibraryStore()

    /// Newest scheduled first, then unscheduled; built-in ids and undecodable rows left out.
    @Published private(set) var workouts: [LibraryWorkout] = []
    /// When the list was last fetched successfully (also restored from the cache).
    @Published private(set) var lastRefresh: Date?
    /// Why the last fetch failed (nil after a good fetch). The cached list stays.
    @Published private(set) var lastError: String?
    /// Rows that were skipped ("<id>: <reason>").
    @Published private(set) var problems: [String] = []
    @Published private(set) var isRefreshing = false

    private var lastAttempt: Date?
    /// Automatic refreshes (appear, foreground) closer together than this are skipped.
    private static let minimumInterval: TimeInterval = 60

    private init() {
        if let cache = LibraryCache.load() {
            workouts = WorkoutLibraryStore.sorted(cache.workouts)
            lastRefresh = cache.savedAt
            problems = cache.problems
        }
    }

    var definitions: [WorkoutDefinition] {
        return workouts.map { (w: LibraryWorkout) -> WorkoutDefinition in w.definition }
    }

    /// A library workout first, then the built-in one.
    func definition(id: String) -> WorkoutDefinition? {
        if let w = workouts.first(where: { (w: LibraryWorkout) -> Bool in w.id == id }) {
            return w.definition
        }
        return WorkoutLibrary.definition(id: id)
    }

    /// Programmed for today (phone's calendar).
    var todayWorkouts: [LibraryWorkout] {
        let today: String = LibraryDay.today
        return workouts.filter { (w: LibraryWorkout) -> Bool in w.scheduledOn == today }
    }

    /// Everything not programmed today, by program; the program with the newest workout first.
    var programGroups: [LibraryGroup] {
        let today: String = LibraryDay.today
        var order: [String] = []
        var byProgram: [String: [LibraryWorkout]] = [:]
        for w in workouts where w.scheduledOn != today {
            var title: String = (w.program ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty { title = "Library" }
            if byProgram[title] == nil {
                order.append(title)
                byProgram[title] = []
            }
            byProgram[title]?.append(w)
        }
        // `workouts` is sorted newest first, so `order` already puts the newest program first.
        return order.map { (title: String) -> LibraryGroup in
            LibraryGroup(title: title, workouts: byProgram[title] ?? [])
        }
    }

    /// Starts a refresh unless one ran in the last minute.
    func refreshSoon() {
        Task { await refresh() }
    }

    /// Fetches the library. Signed out or without a cloud project: does nothing (cache stays).
    /// `force` (pull to refresh) skips the one-minute spacing.
    func refresh(force: Bool = false) async {
        let cloud = CloudAccount.shared
        guard let client = cloud.client, cloud.isSignedIn else { return }
        if isRefreshing { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < WorkoutLibraryStore.minimumInterval {
            return
        }
        lastAttempt = Date()
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            // Raw bytes, decoded here: each row is checked on its own (a bad row is skipped,
            // not the whole list) and the client's decoder settings don't matter.
            let response = try await client.from("workout_library")
                .select("id,definition,program,scheduled_on,updated_at")
                .execute()
            let rows: [LibraryRow] = try JSONDecoder().decode([LibraryRow].self, from: response.data)
            apply(rows)
        } catch {
            // Pull to refresh cancels its task when the list goes away: not a failure.
            var cancelled: Bool = error is CancellationError
            if let urlError = error as? URLError, urlError.code == .cancelled { cancelled = true }
            if cancelled {
                lastAttempt = nil
                return
            }
            lastError = "Could not refresh the workout library: \(error.localizedDescription)"
        }
    }

    private func apply(_ rows: [LibraryRow]) {
        var good: [LibraryWorkout] = []
        var bad: [String] = []
        var seen: Set<String> = []
        for row in rows {
            if let problem = row.problem {
                bad.append(problem)
                continue
            }
            guard let w = row.workout else { continue }
            if w.definition.id != row.id {
                bad.append(row.id + ": definition id is \"" + w.definition.id + "\"")
            } else if WorkoutLibrary.definition(id: w.id) != nil {
                bad.append(row.id + ": uses a built-in workout id")
            } else if seen.contains(w.id) {
                bad.append(row.id + ": appears twice")
            } else {
                seen.insert(w.id)
                good.append(w)
            }
        }
        let now = Date()
        workouts = WorkoutLibraryStore.sorted(good)
        problems = bad
        lastRefresh = now
        lastError = nil
        LibraryCache.save(LibraryCache(savedAt: now, workouts: workouts, problems: bad))
    }

    /// Scheduled newest first, unscheduled after them; then by name.
    private static func sorted(_ list: [LibraryWorkout]) -> [LibraryWorkout] {
        return list.sorted { (a: LibraryWorkout, b: LibraryWorkout) -> Bool in
            let da: String = a.scheduledOn ?? ""
            let db: String = b.scheduledOn ?? ""
            if da != db { return da > db }
            return a.definition.name < b.definition.name
        }
    }
}

// MARK: - Rows

/// One row of the API response. Never throws for a bad definition: it records why instead.
private struct LibraryRow: Decodable {
    let id: String
    let workout: LibraryWorkout?
    let problem: String?

    enum CodingKeys: String, CodingKey {
        case id
        case definition
        case program
        case scheduledOn = "scheduled_on"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rowId: String = (try? c.decode(String.self, forKey: .id)) ?? "?"
        var found: LibraryWorkout? = nil
        var failure: String? = nil
        do {
            let definition: WorkoutDefinition = try c.decode(WorkoutDefinition.self, forKey: .definition)
            let program: String? = try c.decodeIfPresent(String.self, forKey: .program)
            let scheduledOn: String? = try c.decodeIfPresent(String.self, forKey: .scheduledOn)
            let updatedAt: String? = try c.decodeIfPresent(String.self, forKey: .updatedAt)
            found = LibraryWorkout(definition: definition, program: program,
                                   scheduledOn: scheduledOn, updatedAt: updatedAt)
        } catch {
            failure = rowId + ": " + LibraryRow.describe(error)
        }
        id = rowId
        workout = found
        problem = failure
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "missing \"" + path(context.codingPath + [key]) + "\""
        case .typeMismatch(_, let context):
            return "wrong type at \"" + path(context.codingPath) + "\""
        case .valueNotFound(_, let context):
            return "no value at \"" + path(context.codingPath) + "\""
        case .dataCorrupted(let context):
            return "bad value at \"" + path(context.codingPath) + "\""
        @unknown default:
            return error.localizedDescription
        }
    }

    /// "definition.segments.3.kind" (the array index of the row itself left out).
    private static func path(_ keys: [CodingKey]) -> String {
        let parts: [String] = keys.map { (k: CodingKey) -> String in
            if let i = k.intValue { return String(i) }
            return k.stringValue
        }
        return parts.dropFirst().joined(separator: ".")
    }
}

// MARK: - Cache

/// Application Support/workout-library.json: the last good list.
private struct LibraryCache: Codable {
    let savedAt: Date
    let workouts: [LibraryWorkout]
    let problems: [String]

    private static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("workout-library.json")
    }

    static func load() -> LibraryCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LibraryCache.self, from: data)
    }

    static func save(_ cache: LibraryCache) {
        if let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
