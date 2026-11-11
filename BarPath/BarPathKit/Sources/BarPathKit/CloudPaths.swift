import Foundation

/// Path helpers for walking and clearing a user's folder in Supabase Storage.
public enum CloudPaths {
    /// Full object path of an entry listed under `folder` ("" for the bucket root).
    public static func join(folder: String, name: String) -> String {
        if folder.isEmpty { return name }
        if folder.hasSuffix("/") { return folder + name }
        return folder + "/" + name
    }

    /// `items` without duplicates (first occurrence kept), cut into groups of at most `size`.
    public static func batches(_ items: [String], size: Int = 100) -> [[String]] {
        let step: Int = max(1, size)
        var seen: Set<String> = []
        var unique: [String] = []
        for item in items where seen.insert(item).inserted {
            unique.append(item)
        }
        var result: [[String]] = []
        var start: Int = 0
        while start < unique.count {
            result.append(Array(unique[start..<min(start + step, unique.count)]))
            start += step
        }
        return result
    }
}
