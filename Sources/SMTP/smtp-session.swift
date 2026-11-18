import Foundation
import Mail
import MailConnection

public struct SMTPDelivery: Sendable, Equatable {
    public let accepted: [EmailAddress]
    public let rejected: [SMTPRecipientRejection]
    /// The server's reply to the end of `DATA`, usually carrying a queue id.
    public let reply: SMTPReply
}

/// One submission over an open transport: greeting, `EHLO`, `AUTH PLAIN`, envelope, `DATA`, `QUIT`.
public struct SMTPSession: Sendable {
    public let transport: any MailTransport
    public let clientName: String
    /// Upgrade with `STARTTLS` after the first `EHLO`, refusing a server that does not offer it.
    public let startTLS: Bool

    public init(
        transport: any MailTransport,
        clientName: String = "localhost",
        startTLS: Bool = false
    ) {
        self.transport = transport
        self.clientName = clientName
        self.startTLS = startTLS
    }

    public func submit(
        _ message: Data,
        from sender: EmailAddress,
        to recipients: [EmailAddress],
        credentials: MailCredentials? = nil
    ) async throws -> SMTPDelivery {
        guard !recipients.isEmpty else {
            throw SMTPError.noRecipients
        }

        try await open(credentials: credentials)

        try await command("MAIL FROM:<\(sender.raw)>", expecting: 250)

        var accepted: [EmailAddress] = []
        var rejected: [SMTPRecipientRejection] = []
        for recipient in recipients {
            try await transport.writeLine("RCPT TO:<\(recipient.raw)>")
            let reply = try await SMTPReply.read(from: transport)
            if reply.code == 250 || reply.code == 251 {
                accepted.append(recipient)
            } else {
                rejected.append(SMTPRecipientRejection(recipient: recipient, reply: reply))
            }
        }
        guard !accepted.isEmpty else {
            _ = try? await command("QUIT", expecting: 221)
            throw SMTPError.allRecipientsRejected(rejected)
        }

        try await command("DATA", expecting: 354)
        try await transport.write(Self.dotStuffed(message) + Data(".\r\n".utf8))
        let delivered = try await SMTPReply.read(from: transport)
        try expect(delivered, 250, after: "message data")

        _ = try? await command("QUIT", expecting: 221)
        return SMTPDelivery(accepted: accepted, rejected: rejected, reply: delivered)
    }

    /// Greeting, `EHLO`, `STARTTLS` and login, then `QUIT`, without sending:
    /// checks that an account can submit. Returns the server's extensions.
    @discardableResult
    public func verify(
        credentials: MailCredentials? = nil
    ) async throws -> Set<String> {
        let hello = try await open(credentials: credentials)
        _ = try? await command("QUIT", expecting: 221)
        return Self.extensions(hello)
    }

    /// Greeting, `EHLO`, the optional `STARTTLS` upgrade and login; the last `EHLO` reply.
    @discardableResult
    private func open(
        credentials: MailCredentials?
    ) async throws -> SMTPReply {
        try expect(try await SMTPReply.read(from: transport), 220, after: "greeting")
        var hello = try await command("EHLO \(clientName)", expecting: 250)

        if startTLS {
            guard Self.extensions(hello).contains("STARTTLS") else {
                throw MailConnectionError.startTLSUnavailable
            }
            try await command("STARTTLS", expecting: 220)
            try await transport.startTLS()
            // RFC 3207 §4.2: forget what was learned before the handshake.
            hello = try await command("EHLO \(clientName)", expecting: 250)
        }

        if let credentials {
            let mechanisms = hello.lines
                .first { $0.uppercased().hasPrefix("AUTH ") }?
                .uppercased()
                .split(separator: " ")
                .dropFirst()
                .map(String.init) ?? []
            guard mechanisms.contains(MailSASL.plainMechanism) else {
                throw SMTPError.authenticationUnsupported(advertised: mechanisms)
            }
            try await command(
                "AUTH \(MailSASL.plainMechanism) \(MailSASL.plain(credentials))",
                expecting: 235,
                label: "AUTH PLAIN"
            )
        }

        return hello
    }

    /// Extension keywords from an `EHLO` reply, uppercased; the first line is the greeting.
    static func extensions(
        _ hello: SMTPReply
    ) -> Set<String> {
        Set(hello.lines.dropFirst().compactMap { $0.split(separator: " ").first.map { $0.uppercased() } })
    }

    /// Doubles leading dots (RFC 5321 §4.5.2) and ensures a final CRLF.
    public static func dotStuffed(
        _ message: Data
    ) -> Data {
        var output = Data(capacity: message.count + 64)
        var atLineStart = true
        for byte in message {
            if atLineStart && byte == UInt8(ascii: ".") {
                output.append(byte)
            }
            output.append(byte)
            atLineStart = byte == UInt8(ascii: "\n")
        }
        if !output.isEmpty && !output.ends(with: Data("\r\n".utf8)) {
            output.append(contentsOf: Array("\r\n".utf8))
        }
        return output
    }

    @discardableResult
    private func command(
        _ line: String,
        expecting code: Int,
        label: String? = nil
    ) async throws -> SMTPReply {
        try await transport.writeLine(line)
        let reply = try await SMTPReply.read(from: transport)
        try expect(reply, code, after: label ?? line)
        return reply
    }

    private func expect(
        _ reply: SMTPReply,
        _ code: Int,
        after command: String
    ) throws {
        guard reply.code == code else {
            throw SMTPError.unexpectedReply(command: command, reply: reply)
        }
    }
}

private extension Data {
    func ends(
        with suffix: Data
    ) -> Bool {
        count >= suffix.count && self[(endIndex - suffix.count)...].elementsEqual(suffix)
    }
}
