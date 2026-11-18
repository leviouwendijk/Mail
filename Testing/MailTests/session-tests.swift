import Foundation
import Mail
import MailConnection
import SMTP
import Testing

enum SessionTests {
    static func multiLineReply() async throws {
        let transport = ScriptedTransport(MailFixtures.ehlo)
        let reply = try await SMTPReply.read(from: transport)
        try Expect.equal(reply.code, 250, "Code")
        try Expect.equal(reply.lines, ["mx.example.com", "SIZE 35882577", "AUTH LOGIN PLAIN XOAUTH2", "8BITMIME"], "Lines")

        try await Expect.throwsError("Mixed codes") {
            _ = try await SMTPReply.read(from: ScriptedTransport(["250-a", "251 b"]))
        }
        try await Expect.throwsError("Garbage") {
            _ = try await SMTPReply.read(from: ScriptedTransport(["hello"]))
        }
    }

    static func dotStuffing() throws {
        let stuffed = SMTPSession.dotStuffed(Data(".start\r\nmid.dle\r\n.\r\nend".utf8))
        try Expect.equal(
            String(decoding: stuffed, as: UTF8.self),
            "..start\r\nmid.dle\r\n..\r\nend\r\n",
            "Leading dots doubled, final CRLF added"
        )
    }

    static func submitWithAuth() async throws {
        let transport = ScriptedTransport(
            [MailFixtures.greeting] + MailFixtures.ehlo + [
                "235 2.7.0 Accepted",
                "250 2.1.0 OK",
                "250 2.1.5 OK",
                "354 Go ahead",
                "250 2.0.0 OK queued as ABC123",
                "221 2.0.0 Bye",
            ]
        )
        let delivery = try await SMTPSession(transport: transport, clientName: "client.example.com").submit(
            Data("Subject: x\r\nMIME-Version: 1.0\r\n\r\nHi\r\n".utf8),
            from: try MailFixtures.address("levi@example.com"),
            to: [try MailFixtures.address("jan@example.org")],
            credentials: MailCredentials(username: "levi", password: "secret")
        )

        let token = Data("\0levi\0secret".utf8).base64EncodedString()
        try Expect.equal(
            await transport.commands(),
            [
                "EHLO client.example.com",
                "AUTH PLAIN \(token)",
                "MAIL FROM:<levi@example.com>",
                "RCPT TO:<jan@example.org>",
                "DATA",
                "QUIT",
            ],
            "Command sequence"
        )
        try Expect.equal(delivery.accepted.map(\.raw), ["jan@example.org"], "Accepted")
        try Expect.equal(delivery.reply.lines, ["2.0.0 OK queued as ABC123"], "Queue reply")
    }

    static func partialRejection() async throws {
        let transport = ScriptedTransport(
            [MailFixtures.greeting] + MailFixtures.ehlo + [
                "250 OK",
                "550 5.1.1 No such user",
                "250 OK",
                "354 Go ahead",
                "250 OK",
                "221 Bye",
            ]
        )
        let delivery = try await SMTPSession(transport: transport).submit(
            Data("Hi\r\n".utf8),
            from: try MailFixtures.address("levi@example.com"),
            to: [try MailFixtures.address("nobody@example.org"), try MailFixtures.address("jan@example.org")]
        )
        try Expect.equal(delivery.accepted.map(\.raw), ["jan@example.org"], "Accepted")
        try Expect.equal(delivery.rejected.map(\.recipient.raw), ["nobody@example.org"], "Rejected")
        try Expect.equal(delivery.rejected.first?.reply.code, 550, "Rejection code")
    }

    static func allRejected() async throws {
        let transport = ScriptedTransport(
            [MailFixtures.greeting] + MailFixtures.ehlo + [
                "250 OK",
                "550 No such user",
                "221 Bye",
            ]
        )
        do {
            _ = try await SMTPSession(transport: transport).submit(
                Data("Hi\r\n".utf8),
                from: try MailFixtures.address("levi@example.com"),
                to: [try MailFixtures.address("nobody@example.org")]
            )
            throw TestFlowAssertionFailure(label: "all-rejected", message: "submission should fail")
        } catch SMTPError.allRecipientsRejected(let rejected) {
            try Expect.equal(rejected.count, 1, "One rejection")
        }
        try Expect.false(await transport.commands().contains("DATA"), "DATA never sent")
    }

    static func authUnsupported() async throws {
        let transport = ScriptedTransport(
            [MailFixtures.greeting, "250-mx.example.com", "250 AUTH LOGIN"]
        )
        do {
            _ = try await SMTPSession(transport: transport).submit(
                Data("Hi\r\n".utf8),
                from: try MailFixtures.address("levi@example.com"),
                to: [try MailFixtures.address("jan@example.org")],
                credentials: MailCredentials(username: "levi", password: "secret")
            )
            throw TestFlowAssertionFailure(label: "auth", message: "submission should fail")
        } catch SMTPError.authenticationUnsupported(let advertised) {
            try Expect.equal(advertised, ["LOGIN"], "Advertised mechanisms")
        }
    }
}
