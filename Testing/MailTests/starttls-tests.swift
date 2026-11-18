import Foundation
import IMAP
import Mail
import MailConnection
import MailFrame
import SMTP
import Testing

enum StartTLSTests {
    static func smtp() async throws {
        let transport = ScriptedTransport([
            "220 smtp.mail.me.com ESMTP",
            "250-smtp.mail.me.com",
            "250-STARTTLS",
            "250 8BITMIME",
            "220 2.0.0 Ready to start TLS",
            "250-smtp.mail.me.com",
            "250-AUTH LOGIN PLAIN",
            "250 8BITMIME",
            "235 2.7.0 Authentication successful",
            "250 OK",
            "250 OK",
            "354 Go ahead",
            "250 OK",
            "221 Bye",
        ])
        _ = try await SMTPSession(transport: transport, clientName: "icloud.com", startTLS: true).submit(
            Data("Hi\r\n".utf8),
            from: try EmailAddress("alex@icloud.com"),
            to: [try EmailAddress("jan@example.org")],
            credentials: MailCredentials(username: "alex@icloud.com", password: "app-password")
        )
        let commands = await transport.commands()
        try Expect.equal(
            Array(commands.prefix(4)),
            ["EHLO icloud.com", "STARTTLS", "<TLS>", "EHLO icloud.com"],
            "Upgrade, then greet again"
        )
        try Expect.true(commands[4].hasPrefix("AUTH PLAIN"), "Login only after the upgrade")
    }

    static func smtpRefused() async throws {
        let transport = ScriptedTransport([
            "220 mx.example.com ESMTP",
            "250-mx.example.com",
            "250 AUTH PLAIN",
        ])
        do {
            _ = try await SMTPSession(transport: transport, startTLS: true).submit(
                Data("Hi\r\n".utf8),
                from: try EmailAddress("a@example.com"),
                to: [try EmailAddress("b@example.com")],
                credentials: MailCredentials(username: "a", password: "secret")
            )
            throw TestFlowAssertionFailure(label: "starttls", message: "should refuse")
        } catch MailConnectionError.startTLSUnavailable {
        }
        try Expect.false(await transport.commands().contains { $0.hasPrefix("AUTH") }, "Password never sent in the clear")
    }

    static func imap() async throws {
        let transport = ScriptedTransport([
            "* OK ready",
            "* CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED",
            "A1 OK done",
            "A2 OK Begin TLS negotiation now",
            "* CAPABILITY IMAP4rev1 AUTH=PLAIN",
            "A3 OK done",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start(startTLS: true)
        try Expect.equal(
            await transport.commands(),
            ["A1 CAPABILITY", "A2 STARTTLS", "<TLS>", "A3 CAPABILITY"],
            "Upgrade, then refresh capabilities"
        )
        try Expect.true(await session.hasCapability("AUTH=PLAIN"), "Post-TLS capabilities")
        try Expect.false(await session.hasCapability("LOGINDISABLED"), "Pre-TLS capabilities forgotten")
    }

    static func frameDefaults() throws {
        let accounts = try MailAccounts(source: MailFrame.example, environment: FrameTests.environment)
        let personal = try Expect.notNil(accounts.account(named: "personal"), "iCloud account")
        try Expect.equal(personal.smtp?.server.security, .startTLS, "STARTTLS")
        try Expect.equal(personal.smtp?.server.port, 587, "Submission port")
        try Expect.equal(personal.imap?.server.security, .implicitTLS, "IMAP over TLS")
        try Expect.equal(personal.imap?.server.port, 993, "IMAPS port")
    }
}
