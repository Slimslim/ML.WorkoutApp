import Foundation

/// Story W17: a result corrected in the cloud (the file in the user's Storage folder replaced by
/// an edited version) replaces the phone's copy when it is the newer correction.
public enum WorkoutCloudCorrection {

    /// True when `cloud` should replace `local`: same result id, the cloud copy carries an
    /// `editedAt`, and the phone's copy was never edited or was edited earlier. A copy the phone
    /// uploaded itself has the same `editedAt` and is not taken again; a phone edit made later
    /// than the cloud one is never overwritten.
    public static func shouldReplace(local: WorkoutResult, with cloud: WorkoutResult) -> Bool {
        guard local.id == cloud.id else { return false }
        guard let cloudEdited = cloud.editedAt else { return false }
        guard let localEdited = local.editedAt else { return true }
        return cloudEdited > localEdited
    }

    /// The result id of a cloud file name "<UUID>.json"; nil for "<UUID>.original.json" and
    /// anything else (only the current copy of a result is a correction).
    public static func resultId(fileName: String) -> UUID? {
        let suffix: String = ".json"
        guard fileName.hasSuffix(suffix), !fileName.hasSuffix(".original.json") else { return nil }
        let stem: String = String(fileName.dropLast(suffix.count))
        return UUID(uuidString: stem)
    }
}
