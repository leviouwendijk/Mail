import Foundation

/// SASL initial responses, sent as `AUTH <mechanism> <response>` (SMTP) or
/// `AUTHENTICATE <mechanism> <response>` (IMAP).
public enum MailSASL {
    public static let plainMechanism = "PLAIN"

    /// RFC 4616: base64 of `\0username\0password`.
    public static func plain(
        _ credentials: MailCredentials
    ) -> String {
        Data("\0\(credentials.username)\0\(credentials.password)".utf8).base64EncodedString()
    }
}
