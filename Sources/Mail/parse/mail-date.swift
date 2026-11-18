import Foundation

public enum MailDate {
    /// RFC 5322 dates, tolerating a missing weekday or seconds and a trailing `(CET)` comment.
    public static func parse(
        _ text: String
    ) -> Date? {
        var cleaned = text
        if let comment = cleaned.firstIndex(of: "(") {
            cleaned = String(cleaned[..<comment])
        }
        cleaned = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        for format in [
            "EEE, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
            "EEE, d MMM yy HH:mm:ss Z",
        ] {
            if let date = formatter(format).date(from: cleaned) {
                return date
            }
        }
        return nil
    }

    /// IMAP `INTERNALDATE`, such as `17-Jul-1996 02:44:25 -0700`.
    public static func parseInternal(
        _ text: String
    ) -> Date? {
        formatter("d-MMM-yyyy HH:mm:ss Z").date(
            from: text.trimmingCharacters(in: .whitespaces)
        )
    }

    /// IMAP search dates, such as `1-Feb-2026`.
    public static func searchDate(
        _ date: Date,
        in timeZone: TimeZone = .current
    ) -> String {
        let formatter = formatter("d-MMM-yyyy")
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    private static func formatter(
        _ format: String
    ) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
