import Foundation

/// File layout on the phone (spec §8):
///
///     Documents/Lifts/<sessionId>/<id>.json      one lift recording
///     Documents/Lifts/Unsorted/<id>.json         lift whose header could not be read
///     Documents/Debug/session-<sessionId>.csv    full-session debug recording
///     Documents/Debug/...-marks.csv              optional companion marks file
///
/// Not actor-isolated: PhoneLink calls it from the WatchConnectivity background queue.
enum LiftFiles {
    static var documentsURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var liftsURL: URL {
        return documentsURL.appendingPathComponent("Lifts", isDirectory: true)
    }

    static var debugURL: URL {
        return documentsURL.appendingPathComponent("Debug", isDirectory: true)
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: liftsURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: debugURL, withIntermediateDirectories: true)
    }

    // MARK: - Incoming files (called synchronously inside the WCSession delegate)

    private struct LiftHeader: Decodable {
        let id: UUID
        let sessionId: UUID
    }

    private static func readLiftHeader(_ url: URL) -> LiftHeader? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LiftHeader.self, from: data)
    }

    /// Moves an incoming lift JSON to `Lifts/<sessionId>/<id>.json` and returns the new URL.
    static func storeIncomingLift(from source: URL, metadataId: String?) throws -> URL {
        var folder = liftsURL.appendingPathComponent("Unsorted", isDirectory: true)
        var name = (metadataId ?? UUID().uuidString) + ".json"
        if let header = readLiftHeader(source) {
            folder = liftsURL.appendingPathComponent(header.sessionId.uuidString, isDirectory: true)
            name = header.id.uuidString + ".json"
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        try moveReplacing(source, to: destination)
        return destination
    }

    /// Moves an incoming debug file (session CSV or marks file) into `Debug/`.
    static func storeIncomingDebugFile(from source: URL, isMarks: Bool, metadataSessionId: String?) throws -> URL {
        try FileManager.default.createDirectory(at: debugURL, withIntermediateDirectories: true)
        let original = source.lastPathComponent
        let sessionId = metadataSessionId ?? sessionIdFromCSVHeader(source)
        var name: String
        if isMarks {
            if original.lowercased().hasSuffix("-marks.csv") {
                name = original
            } else if let sid = sessionId {
                name = "session-\(sid)-marks.csv"
            } else {
                name = "marks-\(timestampString()).csv"
            }
        } else {
            if original.hasPrefix("session-") && original.lowercased().hasSuffix(".csv") {
                name = original
            } else if let sid = sessionId {
                name = "session-\(sid).csv"
            } else {
                name = "session-\(timestampString()).csv"
            }
        }
        // Never let a remote name escape the folder.
        name = name.replacingOccurrences(of: "/", with: "_")
        let destination = debugURL.appendingPathComponent(name)
        try moveReplacing(source, to: destination)
        return destination
    }

    private static func moveReplacing(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
        }
    }

    private static func timestampString() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: - Reading the CSV cheaply (header / tail only)

    private static func readHead(_ url: URL, length: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: length)
        return String(decoding: data, as: UTF8.self)
    }

    private static func readTail(_ url: URL, length: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > length ? size - length : 0
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Value of `key=` in the first `#` comment line of a CSV, if present.
    static func headerValue(_ key: String, in url: URL) -> String? {
        guard let text = readHead(url, length: 1024) else { return nil }
        guard let range = text.range(of: key + "=") else { return nil }
        let rest = text[range.upperBound...]
        let value = rest.prefix { c in
            return c != "," && c != "\n" && c != "\r" && c != " "
        }
        return value.isEmpty ? nil : String(value)
    }

    static func sessionIdFromCSVHeader(_ url: URL) -> String? {
        return headerValue("sessionId", in: url)
    }

    /// Time of the last data row (= recording duration, since the CSV starts at t = 0).
    static func csvDuration(_ url: URL) -> Double? {
        guard let tail = readTail(url, length: 4096) else { return nil }
        let lines = tail.split(whereSeparator: { (c: Character) -> Bool in c.isNewline })
        for line in lines.reversed() {
            if line.hasPrefix("#") || line.hasPrefix("t,") { continue }
            guard let firstField = line.split(separator: ",").first else { continue }
            if let t = Double(firstField) { return t }
        }
        return nil
    }

    // MARK: - Listing

    /// All lift JSON files under Documents/Lifts, newest first.
    static func allLiftFiles() -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: liftsURL, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles], errorHandler: nil) else {
            return []
        }
        var found: [(url: URL, date: Date)] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            guard url.pathExtension.lowercased() == "json" else { continue }
            found.append((url: url, date: modificationDate(url) ?? .distantPast))
        }
        found.sort { $0.date > $1.date }
        return found.map { $0.url }
    }

    static func modificationDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }

    static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    /// Files in Documents/Debug, newest first.
    static func debugFiles() -> [DebugFile] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: debugURL,
                                                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var files: [DebugFile] = []
        for url in urls {
            let name = url.lastPathComponent
            let lower = name.lowercased()
            let kind: DebugFile.Kind
            if lower.hasSuffix("-marks.csv") || lower.hasPrefix("marks-") {
                kind = .marks
            } else if lower.hasSuffix(".csv") {
                kind = .session
            } else {
                kind = .other
            }
            let duration: Double? = (kind == .session) ? csvDuration(url) : nil
            let startDate: Date? = (kind == .session) ? headerValue("startDate", in: url).flatMap { parseISODate($0) } : nil
            let liftType: String? = (kind == .session) ? headerValue("liftType", in: url) : nil
            files.append(DebugFile(url: url,
                                   kind: kind,
                                   size: fileSize(url),
                                   modified: modificationDate(url) ?? .distantPast,
                                   recordingStart: startDate,
                                   duration: duration,
                                   liftTypeRaw: liftType))
        }
        files.sort { $0.sortDate > $1.sortDate }
        return files
    }

    static func parseISODate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    /// Removes an empty session folder (never the Lifts root itself).
    static func removeFolderIfEmpty(_ folder: URL) {
        let fm = FileManager.default
        if folder.standardizedFileURL.path == liftsURL.standardizedFileURL.path { return }
        guard let contents = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let visible = contents.filter { !$0.hasPrefix(".") }
        if visible.isEmpty {
            try? fm.removeItem(at: folder)
        }
    }
}

struct DebugFile: Identifiable, Equatable {
    enum Kind: String {
        case session, marks, other
    }

    let url: URL
    let kind: Kind
    let size: Int64
    let modified: Date
    let recordingStart: Date?
    let duration: Double?
    let liftTypeRaw: String?

    var id: URL { return url }
    var name: String { return url.lastPathComponent }
    var sortDate: Date { return recordingStart ?? modified }
}
