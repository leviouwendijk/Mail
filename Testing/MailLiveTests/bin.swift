import Foundation
import IMAP
import MailConnection
import SMTP
import Testing

/// Probes real servers without credentials: connect, TLS (implicit or
/// STARTTLS), greeting and capabilities. Never logs in or sends mail.
private enum MailLiveFailure: Error {
    case failed
}

@main
struct MailLiveMain {
    static func main() async throws {
        let reporter = PlainTextTestReporter(
            output: ClosureTestTextOutput { text in
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        )
        let result = await TestRunner.run(
            MailLiveSuite.suite,
            sink: reporter
        )
        if result.isFailure {
            throw MailLiveFailure.failed
        }
    }
}

enum MailLiveSuite {
    static let suite = TestSuite(
        "mail-live",
        title: "Mail live probes"
    ) {
        Test("icloud-smtp-starttls") {
            try await LiveProbes.smtp(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        }
        Test("fastmail-smtp-implicit-tls") {
            try await LiveProbes.smtp(host: "smtp.fastmail.com", port: 465, security: .implicitTLS)
        }
        Test("icloud-imap-implicit-tls") {
            try await LiveProbes.imap(host: "imap.mail.me.com", port: 993, security: .implicitTLS)
        }
        Test("fastmail-imap-implicit-tls") {
            try await LiveProbes.imap(host: "imap.fastmail.com", port: 993, security: .implicitTLS)
        }
    }
}

enum LiveProbes {
    /// Greeting, `EHLO`, optional `STARTTLS` and a second `EHLO`; expects `AUTH PLAIN` once encrypted.
    static func smtp(
        host: String,
        port: UInt16,
        security: MailSecurity
    ) async throws {
        let transport = try await StreamMailTransport.connect(host: host, port: port, security: security, timeout: .seconds(20))
        defer { Task { await transport.close() } }

        try Expect.equal(try await SMTPReply.read(from: transport).code, 220, "Greeting")
        try await transport.writeLine("EHLO probe.local")
        var hello = try await SMTPReply.read(from: transport)
        try Expect.equal(hello.code, 250, "EHLO")

        if security == .startTLS {
            try Expect.true(hello.lines.contains { $0.uppercased().hasPrefix("STARTTLS") }, "STARTTLS offered")
            try await transport.writeLine("STARTTLS")
            try Expect.equal(try await SMTPReply.read(from: transport).code, 220, "Ready for TLS")
            try await transport.startTLS()
            try await transport.writeLine("EHLO probe.local")
            hello = try await SMTPReply.read(from: transport)
            try Expect.equal(hello.code, 250, "EHLO over TLS")
        }

        let auth = hello.lines.first { $0.uppercased().hasPrefix("AUTH") } ?? ""
        try Expect.true(auth.uppercased().contains("PLAIN"), "AUTH PLAIN offered over TLS: \(auth)")
        try await transport.writeLine("QUIT")
    }

    /// Greeting and capabilities; expects a usable login mechanism.
    static func imap(
        host: String,
        port: UInt16,
        security: MailSecurity
    ) async throws {
        let transport = try await StreamMailTransport.connect(host: host, port: port, security: security, timeout: .seconds(20))
        defer { Task { await transport.close() } }

        let session = IMAPSession(transport: transport)
        try await session.start(startTLS: security == .startTLS)
        let capabilities = await session.capabilities
        try Expect.true(capabilities.contains("IMAP4REV1") || capabilities.contains("IMAP4REV2"), "IMAP4rev1: \(capabilities.sorted())")
        try Expect.true(
            capabilities.contains("AUTH=PLAIN") || !capabilities.contains("LOGINDISABLED"),
            "A login mechanism is available"
        )
        try await session.logout()
    }
}
