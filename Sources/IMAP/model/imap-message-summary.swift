import Foundation
import Mail

/// The `ENVELOPE` fetch item: a message's main headers, parsed by the server.
public struct IMAPEnvelope: Sendable, Equatable {
    public let date: Date?
    public let subject: String?
    public let from: [NamedAddress]
    public let sender: [NamedAddress]
    public let replyTo: [NamedAddress]
    public let to: [NamedAddress]
    public let cc: [NamedAddress]
    public let bcc: [NamedAddress]
    public let inReplyTo: String?
    public let messageID: String?

    /// Parses the ten-item envelope list (RFC 3501 §7.4.2).
    init(
        _ value: IMAPValue
    ) throws {
        guard let items = value.list, items.count >= 10 else {
            throw IMAPError.malformedResponse("ENVELOPE")
        }
        self.date = items[0].text.flatMap(MailDate.parse)
        self.subject = items[1].text.map(MIMEEncoding.decodeEncodedWords)
        self.from = Self.addresses(items[2])
        self.sender = Self.addresses(items[3])
        self.replyTo = Self.addresses(items[4])
        self.to = Self.addresses(items[5])
        self.cc = Self.addresses(items[6])
        self.bcc = Self.addresses(items[7])
        self.inReplyTo = items[8].text.flatMap { ReceivedMessageIDs.first($0) }
        self.messageID = items[9].text.flatMap { ReceivedMessageIDs.first($0) }
    }

    /// Each address is `(name adl mailbox host)`; a `NIL` host marks group syntax and is skipped.
    private static func addresses(
        _ value: IMAPValue
    ) -> [NamedAddress] {
        (value.list ?? []).compactMap { entry in
            guard let parts = entry.list, parts.count >= 4,
                  let mailbox = parts[2].text,
                  let host = parts[3].text
            else {
                return nil
            }
            return try? NamedAddress(
                "\(mailbox)@\(host)",
                name: parts[0].text.map(MIMEEncoding.decodeEncodedWords)
            )
        }
    }
}

public struct IMAPMessageSummary: Sendable, Equatable {
    public let uid: IMAPUID
    public let flags: Set<IMAPFlag>
    public let internalDate: Date?
    public let size: Int?
    public let envelope: IMAPEnvelope?

    public var isUnread: Bool {
        !flags.contains(.seen)
    }
}

enum ReceivedMessageIDs {
    static func first(
        _ header: String
    ) -> String? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard let open = trimmed.firstIndex(of: "<"),
              let close = trimmed[open...].firstIndex(of: ">")
        else {
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(trimmed[trimmed.index(after: open)..<close])
    }
}
