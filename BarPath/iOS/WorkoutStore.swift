import Foundation
import Combine
import SwiftUI
import BarPathKit

/// Workout results on disk (Documents/Workouts), newest first.
@MainActor
final class WorkoutStore: ObservableObject {
    static let shared = WorkoutStore()

    @Published private(set) var results: [WorkoutResult] = []
    /// Files that could not be read ("<file>: <reason>").
    @Published private(set) var problems: [String] = []

    private var didLoad = false

    init() {}

    func result(id: UUID) -> WorkoutResult? {
        return results.first(where: { $0.id == id })
    }

    /// The most recent result by end date (what the Live tab shows after a workout).
    var newestResult: WorkoutResult? {
        var newest: WorkoutResult? = nil
        for r in results {
            if let n = newest {
                if r.endDate > n.endDate { newest = r }
            } else {
                newest = r
            }
        }
        return newest
    }

    /// The most recent earlier attempt at the same workout (same definition id).
    func previousAttempt(before result: WorkoutResult) -> WorkoutResult? {
        var best: WorkoutResult? = nil
        for r in results where r.definition.id == result.definition.id
            && r.id != result.id && r.startDate < result.startDate {
            if let b = best {
                if r.startDate > b.startDate { best = r }
            } else {
                best = r
            }
        }
        return best
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        WorkoutFiles.ensureDirectory()
        var loaded: [WorkoutResult] = []
        var failed: [String] = []
        for url in WorkoutFiles.allResultFiles() {
            do {
                let data = try Data(contentsOf: url)
                let decoded = try WorkoutResult.decode(from: data)
                loaded.append(decoded)
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        results = WorkoutStore.sorted(loaded)
        problems = failed
    }

    /// Called by PhoneLink (on main) after a result file was moved into place.
    func ingest(at url: URL) {
        loadIfNeeded()
        do {
            let data = try Data(contentsOf: url)
            let decoded = try WorkoutResult.decode(from: data)
            var updated: [WorkoutResult] = results.filter { $0.id != decoded.id }
            updated.append(decoded)
            results = WorkoutStore.sorted(updated)
            problems.removeAll(where: { $0.hasPrefix(url.lastPathComponent + ":") })
        } catch {
            let text = "\(url.lastPathComponent): \(error.localizedDescription)"
            if !problems.contains(text) {
                problems.append(text)
            }
        }
    }

    func delete(_ result: WorkoutResult) {
        try? FileManager.default.removeItem(at: WorkoutFiles.fileURL(id: result.id))
        results.removeAll(where: { $0.id == result.id })
    }

    private static func sorted(_ list: [WorkoutResult]) -> [WorkoutResult] {
        return list.sorted(by: { $0.startDate > $1.startDate })
    }
}
