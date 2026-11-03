import Foundation
import BarPathKit

/// File layout for workout results on the phone:
///
///     Documents/Workouts/<id>.json     one WorkoutResult (pretty JSON from the watch)
///
/// The motion CSV of a workout lives in Documents/Debug/ like every other recording.
/// Not actor-isolated: PhoneLink calls it from the WatchConnectivity background queue.
enum WorkoutFiles {
    static var workoutsURL: URL {
        return LiftFiles.documentsURL.appendingPathComponent("Workouts", isDirectory: true)
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: workoutsURL, withIntermediateDirectories: true)
    }

    /// Only the id is read, so a result with a newer schema still gets a proper file name.
    private struct Header: Decodable {
        let id: UUID
    }

    private static func readHeaderId(_ url: URL) -> UUID? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let header: Header? = try? JSONDecoder().decode(Header.self, from: data)
        return header?.id
    }

    /// Characters kept when a remote-supplied id is used as a file name.
    private static func safeName(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "-" || c == "_" {
                out.append(c)
            }
        }
        return out
    }

    static func fileURL(id: UUID) -> URL {
        return workoutsURL.appendingPathComponent(id.uuidString + ".json")
    }

    /// Moves an incoming result JSON to `Workouts/<id>.json` and returns the new URL.
    /// Synchronous: the system deletes `source` when the WCSession delegate call returns.
    /// The same id can arrive twice (W6: the watch sends the result at End, then an update whose
    /// HR series runs to finish + 3:00); `WorkoutResult.storedAfterWatchUpdate` decides what is
    /// kept, so an older copy never replaces a newer one and an edit made on the phone keeps
    /// everything but the longer HR series.
    static func storeIncomingResult(from source: URL, metadataId: String?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: workoutsURL, withIntermediateDirectories: true)

        var name: String
        if let id = readHeaderId(source) {
            name = id.uuidString
        } else {
            let cleaned = safeName(metadataId ?? "")
            name = cleaned.isEmpty ? UUID().uuidString : cleaned
        }
        name = name + ".json"
        // Never let a remote name escape the folder.
        let destination = workoutsURL.appendingPathComponent(name)

        if fm.fileExists(atPath: destination.path) {
            if let handled = mergeIncoming(from: source, into: destination) {
                return handled
            }
            try fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
        }
        return destination
    }

    /// A result arriving for an id already on the phone. Returns `destination` when it was
    /// handled here (merged, or the incoming copy dropped as older), nil to replace the file as
    /// before (either side unreadable, or the phone's copy untouched and the incoming one newer).
    private static func mergeIncoming(from source: URL, into destination: URL) -> URL? {
        guard let incomingData = try? Data(contentsOf: source),
              let incoming = try? WorkoutResult.decode(from: incomingData),
              let existingData = try? Data(contentsOf: destination),
              let existing = try? WorkoutResult.decode(from: existingData),
              existing.id == incoming.id else { return nil }
        let changed: Bool = hasOriginal(id: existing.id)
        guard let stored = WorkoutResult.storedAfterWatchUpdate(existing: existing, incoming: incoming,
                                                                existingWasChanged: changed) else {
            // Older than (or the same as) what the phone has, which it may have edited: keep it.
            return destination
        }
        if !changed {
            return nil
        }
        do {
            let merged: Data = try stored.encoded()
            try merged.write(to: destination, options: [.atomic])
            // "Restore original" then brings back the watch's newest copy (with the full recovery).
            try incomingData.write(to: originalURL(id: existing.id), options: [.atomic])
        } catch {
            NSLog("BarPath: could not merge workout update %@: %@", existing.id.uuidString,
                  error.localizedDescription)
        }
        return destination
    }

    /// All result JSON files in Documents/Workouts.
    static func allResultFiles() -> [URL] {
        let urls: [URL] = (try? FileManager.default.contentsOfDirectory(
            at: workoutsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { (u: URL) -> Bool in
            let name = u.lastPathComponent.lowercased()
            return u.pathExtension.lowercased() == "json" && !name.hasSuffix(".original.json")
        }
    }

    /// Untouched copy of the result as received from the watch (kept before the first edit).
    static func originalURL(id: UUID) -> URL {
        return workoutsURL.appendingPathComponent(id.uuidString + ".original.json")
    }

    static func hasOriginal(id: UUID) -> Bool {
        return FileManager.default.fileExists(atPath: originalURL(id: id).path)
    }

    /// The motion recording for a result, if it exists in Documents/Debug.
    static func csvURL(for result: WorkoutResult) -> URL? {
        guard let recorded = result.recordingFileName, !recorded.isEmpty else { return nil }
        // Keep only the last path component.
        let name = (recorded as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let url = LiftFiles.debugURL.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
