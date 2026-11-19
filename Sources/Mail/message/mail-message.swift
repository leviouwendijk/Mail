import Foundation

public enum MailBody: Sendable, Equatable {
    case text(String)
    case html(String)
    case alternative(text: String, html: String)

    /// Text, HTML or both; HTML alone gets a text version derived from it, so
    /// clients that show no HTML still read the message. `nil` when both are empty.
    public init?(
        text: String?,
        html: String?
    ) {
        let text = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let html = html.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch (text, html) {
        case (let text?, let html?):
            self = .alternative(text: text, html: html)
        case (nil, let html?):
            self = .alternative(text: ReceivedMessage.plainText(fromHTML: html), html: html)
        case (let text?, nil):
            self = .text(text)
        case (nil, nil):
            return nil
        }
    }
}

public struct MailHeaderField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(
        _ name: String,
        _ value: String
    ) {
        self.name = name
        self.value = value
    }
}

public struct MailMessage: Sendable {
    public var from: NamedAddress
    public var to: [NamedAddress]
    public var cc: [NamedAddress]
    public var bcc: [NamedAddress]
    public var replyTo: [NamedAddress]
    public var subject: String
    public var body: MailBody
    public var attachments: [MailAttachment]
    /// Additional top-level headers, rendered after the standard ones.
    public var headers: [MailHeaderField]
    /// Rendering time when `nil`.
    public var date: Date?
    /// Generated from the sender's domain when `nil`; written without angle brackets.
    public var messageID: String?

    public init(
        from: NamedAddress,
        to: [NamedAddress],
        cc: [NamedAddress] = [],
        bcc: [NamedAddress] = [],
        replyTo: [NamedAddress] = [],
        subject: String,
        body: MailBody,
        attachments: [MailAttachment] = [],
        headers: [MailHeaderField] = [],
        date: Date? = nil,
        messageID: String? = nil
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.headers = headers
        self.date = date
        self.messageID = messageID
    }

    /// Envelope recipients: `to`, `cc` and `bcc`, without duplicates, in order.
    public var recipients: [EmailAddress] {
        var seen: Set<EmailAddress> = []
        return (to + cc + bcc)
            .map(\.address)
            .filter { seen.insert($0).inserted }
    }
}
