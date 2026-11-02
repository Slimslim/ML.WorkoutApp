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
            try fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
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
