import Foundation

/// Text helpers shared by the workout overview (WorkoutSummary) and its views. Times are
/// rounded to whole seconds. Negative values use a real minus sign (U+2212), missing values
/// an en dash. Named to avoid clashing with the iOS app's `WorkoutFmt`.
public enum SummaryFormat {
    /// U+2212 MINUS SIGN.
    public static let minus: String = "\u{2212}"
    /// Shown for a missing value.
    public static let missing: String = "\u{2013}"

    /// "0:42", "12:47", "1:23:45" (h:mm:ss from one hour). Negative: "−0:05".
    public static func clock(_ seconds: Double) -> String {
        if !seconds.isFinite { return missing }
        let total: Int = Int(abs(seconds).rounded())
        let h: Int = total / 3600
        let m: Int = (total % 3600) / 60
        let s: Int = total % 60
        let body: String
        if h > 0 {
            body = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            body = String(format: "%d:%02d", m, s)
        }
        if seconds < 0 && total > 0 { return minus + body }
        return body
    }

    /// Optional variant: missing → "–".
    public static func clock(_ seconds: Double?) -> String {
        guard let s = seconds else { return missing }
        return clock(s)
    }

    /// "+0:12", "−0:05", "+0:00" (zero after rounding is "+0:00").
    public static func signed(_ seconds: Double) -> String {
        if !seconds.isFinite { return missing }
        let total: Int = Int(abs(seconds).rounded())
        let sign: String = (seconds < 0 && total > 0) ? minus : "+"
        return sign + clock(Double(total))
    }

    /// Pace in seconds per km as "5:09" (no unit), "–" when nil.
    public static func pace(_ secondsPerKm: Double?) -> String {
        guard let p = secondsPerKm, p.isFinite, p > 0 else { return missing }
        return clock(p)
    }

    /// Heart rate as a whole number, "–" when nil.
    public static func bpm(_ value: Double?) -> String {
        guard let v = value, v.isFinite else { return missing }
        return String(Int(v.rounded()))
    }

    /// "+21 %", "−5 %", "+0 %" (whole percent).
    public static func signedPercent(_ percent: Double) -> String {
        if !percent.isFinite { return missing }
        let r: Int = Int(abs(percent).rounded())
        let sign: String = (percent < 0 && r > 0) ? minus : "+"
        return sign + String(r) + " %"
    }

    /// "+12", "−35", "+0" (whole number).
    public static func signedNumber(_ value: Double) -> String {
        if !value.isFinite { return missing }
        let r: Int = Int(abs(value).rounded())
        let sign: String = (value < 0 && r > 0) ? minus : "+"
        return sign + String(r)
    }
}
