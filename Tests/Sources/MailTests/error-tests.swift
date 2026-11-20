import Errors
import IMAP
import Mail
import MailConnection
import MailFrame
import SMTP
import Testing

enum ErrorTests {
    static func imapNamesTheFailure() throws {
        let missing = IMAPError.commandFailed(
            command: "UID MOVE",
            status: .init(status: "NO", code: "TRYCREATE", text: "Mailbox doesn't exist: Review.Suspicious")
        )
        let report = missing.report

        try Expect.equal(report.diagnostic.identity?.raw, "mail.imap.command_failed", "A failed command has a stable code")
        try Expect.equal(report.presentation.message, "IMAP UID MOVE failed.", "The message says what failed")
        try Expect.equal(report.presentation.reason, "NO [TRYCREATE] Mailbox doesn't exist: Review.Suspicious", "The reason is the server's answer")
        try Expect.equal(report.presentation.reasonOrigin, .remote, "The server's words are marked remote")
        try Expect.equal(report.diagnostic.disposition, .invalid_input, "A missing mailbox means the input must change")
        try Expect.notNil(report.presentation.recoverySuggestion, "A missing mailbox comes with a suggestion")
        try Expect.equal(
            missing.explanation,
            "IMAP UID MOVE failed. NO [TRYCREATE] Mailbox doesn't exist: Review.Suspicious. The mailbox does not exist; list mailboxes to find its path, or create it first.",
            "The whole error reads as one line"
        )

        let busy = IMAPError.commandFailed(
            command: "SELECT",
            status: .init(status: "NO", code: "UNAVAILABLE 30", text: "Try later")
        )
        try Expect.equal(busy.errorDisposition, .transient, "A response code with arguments is matched by its name")

        let login = IMAPError.commandFailed(
            command: "LOGIN",
            status: .init(status: "NO", code: "AUTHENTICATIONFAILED", text: "Invalid credentials")
        )
        try Expect.equal(login.errorIdentity.raw, "mail.imap.login_rejected", "A rejected login has its own code")
        try Expect.equal(login.errorDisposition, .requires_configuration, "A rejected login needs configuration")
    }

    static func smtpAndConnection() throws {
        let rejected = SMTPError.unexpectedReply(
            command: "AUTH",
            reply: .init(code: 535, lines: ["5.7.8 Authentication failed"])
        )
        try Expect.equal(rejected.errorIdentity.raw, "mail.smtp.login_rejected", "A 535 is a rejected login")

        let deferred = SMTPError.unexpectedReply(
            command: "RCPT TO",
            reply: .init(code: 451, lines: ["4.7.1 Greylisted"])
        )
        try Expect.equal(deferred.errorDisposition, .transient, "A 4xx reply is transient")
        try Expect.equal(
            deferred.report.diagnostic[field: "smtp.reply_code"]?.value,
            .integer(451),
            "The reply code is a field"
        )

        try Expect.equal(MailConnectionError.timedOut.errorDisposition, .transient, "A timeout is transient")
        try Expect.equal(
            MailConnectionError.startTLSUnavailable.errorDisposition,
            .requires_configuration,
            "Missing STARTTLS needs configuration"
        )
    }

    static func addressesAndAccess() throws {
        do {
            _ = try EmailAddress("noor.example.org")
            throw TestFlowAssertionFailure(label: "address", message: "expected a failure")
        } catch {
            try Expect.equal(error.report.diagnostic.identity?.raw, "mail.address.missing_at", "An address error has a stable code")
            try Expect.equal(error.explanation, "Not a valid email address. It has no @.", "It says what is wrong")
        }

        let denied = MailAccess.Failure.mailbox("Review/Private", profile: "assistant")
        try Expect.equal(denied.errorDisposition, .requires_access, "Access refusals need access")
        try Expect.equal(
            denied.report.redacted(policy: .public_safe).presentation.message,
            ErrorRedactionPolicy.placeholder,
            "A refused mailbox's name is withheld from public output"
        )
    }
}
