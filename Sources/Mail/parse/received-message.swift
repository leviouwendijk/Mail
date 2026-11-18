import Foundation

/// A message read from a server or file: decoded headers, bodies and attachments.
public struct ReceivedMessage: Sendable, Equatable {
    public let root: ParsedPart
    public let from: [NamedAddress]
    public let to: [NamedAddress]
    public let cc: [NamedAddress]
    public let replyTo: [NamedAddress]
    public let subject: String?
    public let date: Date?
    /// Without angle brackets.
    public let messageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let text: String?
    public let html: String?
    public let attachments: [MailAttachment]

    public var headers: MailHeaders {
        root.headers
    }

    public init(
        parsing data: Data
    ) {
        let root = MIMEParser.parse(data)
        let headers = root.headers
        self.root = root
        self.from = headers["From"].map(NamedAddress.parseList) ?? []
        self.to = headers["To"].map(NamedAddress.parseList) ?? []
        self.cc = headers["Cc"].map(NamedAddress.parseList) ?? []
        self.replyTo = headers["Reply-To"].map(NamedAddress.parseList) ?? []
        self.subject = headers.text("Subject")
        self.date = headers["Date"].flatMap(MailDate.parse)
        self.messageID = headers["Message-ID"].flatMap { Self.messageIDs($0).first }
        self.inReplyTo = headers["In-Reply-To"].flatMap { Self.messageIDs($0).first }
        self.references = headers["References"].map(Self.messageIDs) ?? []

        var text: String?
        var html: String?
        var attachments: [MailAttachment] = []
        for leaf in root.leaves {
            let isAttachment = leaf.disposition?.value == "attachment"
                || (leaf.filename != nil && leaf.contentType.type != "text")
                || (leaf.contentType.type != "text" && leaf.contentType.type != "multipart")
            if !isAttachment && leaf.contentType.value == "text/plain" && text == nil {
                text = leaf.text
            } else if !isAttachment && leaf.contentType.value == "text/html" && html == nil {
                html = leaf.text
            } else {
                attachments.append(Self.attachment(leaf))
            }
        }
        self.text = text
        self.html = html
        self.attachments = attachments
    }

    /// `<a@b> <c@d>` → `["a@b", "c@d"]`.
    static func messageIDs(
        _ header: String
    ) -> [String] {
        header
            .split(separator: "<")
            .compactMap { piece in
                piece.split(separator: ">", maxSplits: 1).first.map(String.init)
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func attachment(
        _ part: ParsedPart
    ) -> MailAttachment {
        let contentID = part.headers["Content-ID"].flatMap { messageIDs($0).first }
        let disposition: MailAttachment.Disposition
        if part.disposition?.value != "attachment", let contentID {
            disposition = .inline(contentID: contentID)
        } else {
            disposition = .attachment
        }
        return MailAttachment(
            filename: part.filename ?? "part",
            contentType: part.contentType.value,
            data: part.body,
            disposition: disposition
        )
    }
}
