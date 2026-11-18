import Foundation

/// Renders a `MailMessage` into an RFC 5322 message. `Bcc` never appears in the output.
public struct MailRenderer: Sendable {
    public var makeBoundary: @Sendable () -> String
    public var now: @Sendable () -> Date

    public init(
        makeBoundary: @escaping @Sendable () -> String = { "=_mail_\(UUID().uuidString)" },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.makeBoundary = makeBoundary
        self.now = now
    }

    public func rendered(
        _ message: MailMessage
    ) -> String {
        part(for: message).rendered() + MIMEEncoding.crlf
    }

    public func data(
        _ message: MailMessage
    ) -> Data {
        Data(rendered(message).utf8)
    }

    public func part(
        for message: MailMessage
    ) -> MIMEPart {
        var root = contentPart(for: message)
        root.headers = envelopeHeaders(for: message) + root.headers
        return root
    }

    private func envelopeHeaders(
        for message: MailMessage
    ) -> [MailHeaderField] {
        var headers = [
            MailHeaderField("Date", Self.date(message.date ?? now())),
            MailHeaderField("From", Self.addressList([message.from])),
        ]
        if !message.to.isEmpty {
            headers.append(MailHeaderField("To", Self.addressList(message.to)))
        }
        if !message.cc.isEmpty {
            headers.append(MailHeaderField("Cc", Self.addressList(message.cc)))
        }
        if !message.replyTo.isEmpty {
            headers.append(MailHeaderField("Reply-To", Self.addressList(message.replyTo)))
        }
        let messageID = message.messageID ?? "\(UUID().uuidString)@\(message.from.address.domain)"
        headers += [
            MailHeaderField("Subject", MIMEEncoding.encodedWord(message.subject)),
            MailHeaderField("Message-ID", "<\(messageID)>"),
            MailHeaderField("MIME-Version", "1.0"),
        ]
        return headers + message.headers
    }

    /// `mixed[related[body, inline…], attachment…]`, dropping each layer that would be empty.
    private func contentPart(
        for message: MailMessage
    ) -> MIMEPart {
        var part = bodyPart(message.body)

        let inline = message.attachments.filter(\.isInline)
        if !inline.isEmpty {
            part = .multipart(
                "related",
                boundary: makeBoundary(),
                parts: [part] + inline.map(Self.attachmentPart)
            )
        }

        let attached = message.attachments.filter { !$0.isInline }
        if !attached.isEmpty {
            part = .multipart(
                "mixed",
                boundary: makeBoundary(),
                parts: [part] + attached.map(Self.attachmentPart)
            )
        }
        return part
    }

    private func bodyPart(
        _ body: MailBody
    ) -> MIMEPart {
        switch body {
        case .text(let text):
            return Self.textPart(text, subtype: "plain")
        case .html(let html):
            return Self.textPart(html, subtype: "html")
        case .alternative(let text, let html):
            return .multipart(
                "alternative",
                boundary: makeBoundary(),
                parts: [
                    Self.textPart(text, subtype: "plain"),
                    Self.textPart(html, subtype: "html"),
                ]
            )
        }
    }

    private static func textPart(
        _ text: String,
        subtype: String
    ) -> MIMEPart {
        MIMEPart(
            headers: [
                MailHeaderField("Content-Type", "text/\(subtype); charset=utf-8"),
                MailHeaderField("Content-Transfer-Encoding", "quoted-printable"),
            ],
            content: .body(MIMEEncoding.quotedPrintable(text))
        )
    }

    private static func attachmentPart(
        _ attachment: MailAttachment
    ) -> MIMEPart {
        let filename = quoted(MIMEEncoding.encodedWord(attachment.filename))
        var headers = [
            MailHeaderField("Content-Type", "\(attachment.contentType); name=\(filename)"),
            MailHeaderField("Content-Transfer-Encoding", "base64"),
        ]
        switch attachment.disposition {
        case .attachment:
            headers.append(MailHeaderField("Content-Disposition", "attachment; filename=\(filename)"))
        case .inline(let contentID):
            headers.append(MailHeaderField("Content-Disposition", "inline; filename=\(filename)"))
            headers.append(MailHeaderField("Content-ID", "<\(contentID)>"))
        }
        return MIMEPart(
            headers: headers,
            content: .body(MIMEEncoding.base64(attachment.data))
        )
    }

    static func addressList(
        _ addresses: [NamedAddress]
    ) -> String {
        addresses
            .map { address in
                guard let name = address.name else {
                    return address.address.raw
                }
                return "\(MIMEEncoding.displayName(name)) <\(address.address.raw)>"
            }
            .joined(separator: ", ")
    }

    private static func quoted(
        _ value: String
    ) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func date(
        _ date: Date
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }
}
