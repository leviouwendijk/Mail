import Foundation
import Mail
import MailConnection

/// Serves a scripted server byte stream and records everything the client writes.
actor ScriptedTransport: MailTransport {
    private var incoming: Data
    private(set) var written: [String] = []
    private(set) var closed = false

    init(
        _ lines: [String]
    ) {
        self.incoming = Data(lines.map { $0 + "\r\n" }.joined().utf8)
    }

    func write(
        _ data: Data
    ) async throws {
        written.append(String(decoding: data, as: UTF8.self))
    }

    func readLine() async throws -> String {
        guard let range = incoming.range(of: Data("\r\n".utf8)) else {
            throw MailConnectionError.connectionClosed
        }
        let line = incoming[incoming.startIndex..<range.lowerBound]
        incoming.removeSubrange(incoming.startIndex..<range.upperBound)
        return String(decoding: line, as: UTF8.self)
    }

    func read(
        count: Int
    ) async throws -> Data {
        guard incoming.count >= count else {
            throw MailConnectionError.connectionClosed
        }
        let bytes = Data(incoming.prefix(count))
        incoming.removeFirst(count)
        return bytes
    }

    func close() async {
        closed = true
    }

    func startTLS() async throws {
        written.append("<TLS>")
    }

    /// Appends raw server bytes, for literals that are not text.
    func feed(
        _ data: Data
    ) {
        incoming.append(data)
    }

    /// Written command lines, without the message data.
    func commands() -> [String] {
        written
            .filter { !$0.contains("MIME-Version") }
            .map { $0.trimmingCharacters(in: .newlines) }
    }
}

enum MailFixtures {
    static func address(
        _ raw: String
    ) throws -> EmailAddress {
        try EmailAddress(raw)
    }

    static func message(
        body: MailBody = .text("Hello"),
        bcc: [NamedAddress] = [],
        attachments: [MailAttachment] = []
    ) throws -> MailMessage {
        MailMessage(
            from: try NamedAddress("levi@example.com", name: "Levi"),
            to: [try NamedAddress("jan@example.org")],
            bcc: bcc,
            subject: "Afspraak",
            body: body,
            attachments: attachments,
            date: Date(timeIntervalSince1970: 0),
            messageID: "fixed@example.com"
        )
    }

    static func renderer() -> MailRenderer {
        let counter = Counter()
        return MailRenderer(
            makeBoundary: { "b\(counter.next())" },
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    static let greeting = "220 mx.example.com ESMTP"
    static let ehlo = [
        "250-mx.example.com",
        "250-SIZE 35882577",
        "250-AUTH LOGIN PLAIN XOAUTH2",
        "250 8BITMIME",
    ]
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
