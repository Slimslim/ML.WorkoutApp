import Foundation

/// Supabase project the app signs in to and uploads to.
/// The anon key is public by design: what a signed-in user may read or write is decided by the
/// row-level security policies in `supabase/migrations/`, not by keeping this key secret.
/// While `url` is empty the app runs as before: no sign-in screen, no uploads.
enum CloudConfig {
    static let url = ""
    static let anonKey = ""

    /// Private Storage bucket; each user's files live under `<user id>/`.
    static let bucket = "uploads"

    static var isConfigured: Bool {
        return !url.isEmpty && !anonKey.isEmpty
    }
}
