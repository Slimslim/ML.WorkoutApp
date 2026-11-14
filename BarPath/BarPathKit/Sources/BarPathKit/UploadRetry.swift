import Foundation

/// What a finished background upload means for the next step (story W28).
public enum UploadOutcome: Equatable {
    /// Stored in the bucket.
    case uploaded
    /// The server can never take this file version (over the bucket's size limit): stop trying.
    case tooLarge
    /// The access token was refused (expired or invalid): get a fresh token and queue it again now.
    case authRejected
    /// Anything else (network, server error): try again at the next sync or background refresh.
    case retryLater

    /// Classifies a finished upload from its HTTP status and the first bytes of the response body.
    /// `failed` is true when the task ended with a transport error (no usable response).
    ///
    /// The Storage API answers some errors with HTTP 400 and the real reason in the body
    /// (`"statusCode": "403"`, `"message": "jwt expired"`), so the body is read too.
    public static func classify(status: Int, body: Data, failed: Bool) -> UploadOutcome {
        if failed { return .retryLater }
        if (200..<300).contains(status) { return .uploaded }
        if isTooLarge(status: status, body: body) { return .tooLarge }
        if status == 401 || status == 403 { return .authRejected }
        if status == 400 {
            let text: String = (String(data: body, encoding: .utf8) ?? "").lowercased()
            if text.contains("jwt") || text.contains("unauthorized") || text.contains("invalid token")
                || text.contains("\"403\"") || text.contains("\"401\"") {
                return .authRejected
            }
        }
        return .retryLater
    }

    /// The server refused the file for its size: HTTP 413, or the Storage API's 400 whose message
    /// says the object exceeded the maximum allowed size. A 400 without a readable body is not
    /// "too large" (it keeps being retried).
    public static func isTooLarge(status: Int, body: Data) -> Bool {
        if status == 413 { return true }
        guard status == 400 else { return false }
        let text: String = (String(data: body, encoding: .utf8) ?? "").lowercased()
        return text.contains("exceed") && text.contains("maximum")
    }
}

/// How many times a file version is queued again right away after its token was refused.
/// Keeps a broken sign-in from looping in the background; the count is per file version, so a
/// changed file starts again at zero. Not persisted: a relaunch starts with a fresh budget.
public struct UploadRetryBudget: Equatable {
    public let maxImmediateRetries: Int
    public private(set) var used: [String: Int] = [:]

    public init(maxImmediateRetries: Int = 2) {
        self.maxImmediateRetries = maxImmediateRetries
    }

    public static func key(path: String, version: String) -> String {
        return path + "|" + version
    }

    /// Takes one retry for `key` and returns true, or returns false when the budget is spent.
    public mutating func take(_ key: String) -> Bool {
        let count: Int = used[key] ?? 0
        guard count < maxImmediateRetries else { return false }
        used[key] = count + 1
        return true
    }

    /// The file version went up: forget its retries.
    public mutating func reset(_ key: String) {
        used[key] = nil
    }
}

/// When the phone should next run a background refresh (BGAppRefreshTask) to finish uploads.
public enum UploadRefreshPlan {
    /// iOS will not run an app refresh sooner than this anyway; asking earlier wastes the request.
    public static let minimumDelay: TimeInterval = 15 * 60

    /// Nil when nothing is left to upload (no refresh needed); otherwise the earliest start date.
    /// `waiting` counts files not yet in the cloud (queued in iOS or not queued yet).
    public static func nextRefresh(waiting: Int, now: Date) -> Date? {
        guard waiting > 0 else { return nil }
        return now.addingTimeInterval(minimumDelay)
    }
}
