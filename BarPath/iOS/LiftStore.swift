import Foundation
import Combine
import SwiftUI
import BarPathKit

/// Owns the lifts on disk and their analyses. Decoding + `LiftAnalyzer` run on a detached
/// task; results are published on the main actor.
@MainActor
final class LiftStore: ObservableObject {
    static let shared = LiftStore()

    /// Newest session first; lifts inside a session in ascending index order.
    @Published private(set) var sessions: [LiftSessionGroup] = []
    @Published private(set) var debugFiles: [DebugFile] = []
    /// Lifts received or found on disk that are still being decoded/analyzed.
    @Published private(set) var analyzingCount: Int = 0
    @Published private(set) var isLoading: Bool = false
    /// Files that could not be read (shown in the Debug tab).
    @Published private(set) var problems: [String] = []
    /// The most recent lift that arrived from the watch while the app was running.
    @Published private(set) var latestArrivalId: UUID?

    private var entries: [UUID: LiftEntry] = [:]
    private var didLoad = false

    init() {}

    // MARK: - Queries

    /// The newest session ("current" on the Live tab).
    var currentSession: LiftSessionGroup? {
        return sessions.first
    }

    var liftCount: Int {
        return entries.count
    }

    var allLiftFileURLs: [URL] {
        return sessions.flatMap { $0.fileURLs }
    }

    func entry(id: UUID) -> LiftEntry? {
        return entries[id]
    }

    func session(id: UUID) -> LiftSessionGroup? {
        return sessions.first(where: { $0.id == id })
    }

    /// The closest earlier lift of the same session that has a bar path.
    func previousLift(before entry: LiftEntry) -> LiftEntry? {
        guard let group = session(id: entry.sessionId) else { return nil }
        return group.lifts.last(where: { $0.index < entry.index && $0.display != nil })
    }

    // MARK: - Loading

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        LiftFiles.ensureDirectories()
        reloadDebugFiles()
        let urls = LiftFiles.allLiftFiles()
        guard !urls.isEmpty else { return }
        isLoading = true
        analyzingCount += urls.count
        Task {
            for url in urls {
                let outcome = await Task.detached(priority: .userInitiated) {
                    return LiftProcessor.process(fileURL: url)
                }.value
                self.apply(outcome, isNewArrival: false)
            }
            self.isLoading = false
        }
    }

    /// Called by PhoneLink (on main) after a lift file was moved into place.
    func ingestLift(at url: URL) {
        analyzingCount += 1
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                return LiftProcessor.process(fileURL: url)
            }.value
            self.apply(outcome, isNewArrival: true)
        }
    }

    func reloadDebugFiles() {
        debugFiles = LiftFiles.debugFiles()
    }

    private func apply(_ outcome: ProcessOutcome, isNewArrival: Bool) {
        analyzingCount = max(0, analyzingCount - 1)
        switch outcome {
        case .entry(let entry):
            // Keyed by lift id, so a lift that is received twice shows up once.
            entries[entry.id] = entry
            rebuildSessions()
            if isNewArrival {
                latestArrivalId = entry.id
            }
        case .unreadable(let url, let message):
            problems.append("\(url.lastPathComponent): \(message)")
        }
    }

    private func rebuildSessions() {
        var groups: [UUID: [LiftEntry]] = [:]
        for entry in entries.values {
            groups[entry.sessionId, default: []].append(entry)
        }
        var result: [LiftSessionGroup] = []
        for (sessionId, lifts) in groups {
            let sorted = lifts.sorted { a, b in
                if a.index != b.index { return a.index < b.index }
                return a.startDate < b.startDate
            }
            result.append(LiftSessionGroup(id: sessionId, lifts: sorted))
        }
        result.sort { $0.latestDate > $1.latestDate }
        sessions = result
    }

    // MARK: - Deleting

    func delete(_ entry: LiftEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
        LiftFiles.removeFolderIfEmpty(entry.fileURL.deletingLastPathComponent())
        entries[entry.id] = nil
        if latestArrivalId == entry.id {
            latestArrivalId = nil
        }
        rebuildSessions()
    }

    func deleteSession(_ group: LiftSessionGroup) {
        for entry in group.lifts {
            try? FileManager.default.removeItem(at: entry.fileURL)
            LiftFiles.removeFolderIfEmpty(entry.fileURL.deletingLastPathComponent())
            entries[entry.id] = nil
        }
        rebuildSessions()
    }

    func deleteDebugFile(_ file: DebugFile) {
        try? FileManager.default.removeItem(at: file.url)
        reloadDebugFiles()
    }
}
