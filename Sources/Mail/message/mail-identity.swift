import Foundation

public struct MailSignature: Sendable, Equatable {
    public let text: String?
    public let html: String?

    public init(
        text: String? = nil,
        html: String? = nil
    ) {
        self.text = text
        self.html = html
    }

    /// Appends the signature: after the `-- ` delimiter in text (RFC 3676 §4.3), as a block in HTML.
    public func signing(
        _ body: MailBody
    ) -> MailBody {
        switch body {
        case .text(let content):
            return .text(signText(content))
        case .html(let content):
            return .html(signHTML(content))
        case .alternative(let text, let html):
            return .alternative(text: signText(text), html: signHTML(html))
        }
    }

    private func signText(
        _ content: String
    ) -> String {
        guard let text = text ?? html.map(Self.plain) else {
            return content
        }
        return content + "\n\n-- \n" + text
    }

    private func signHTML(
        _ content: String
    ) -> String {
        guard let html = html ?? text.map(Self.paragraphs) else {
            return content
        }
        return content + "\n<div class=\"signature\">\(html)</div>"
    }

    private static func plain(
        _ html: String
    ) -> String {
        html
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func paragraphs(
        _ text: String
    ) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

/// A sender: the `From` address, an optional `Reply-To` and a signature.
public struct MailIdentity: Sendable, Equatable {
    public let address: NamedAddress
    public let replyTo: NamedAddress?
    public let signature: MailSignature?

    public init(
        address: NamedAddress,
        replyTo: NamedAddress? = nil,
        signature: MailSignature? = nil
    ) {
        self.address = address
        self.replyTo = replyTo
        self.signature = signature
    }

    /// A message from this identity, signed.
    public func message(
        to: [NamedAddress],
        cc: [NamedAddress] = [],
        bcc: [NamedAddress] = [],
        subject: String,
        body: MailBody,
        attachments: [MailAttachment] = []
    ) -> MailMessage {
        MailMessage(
            from: address,
            to: to,
            cc: cc,
            bcc: bcc,
            replyTo: replyTo.map { [$0] } ?? [],
            subject: subject,
            body: signature?.signing(body) ?? body,
            attachments: attachments
        )
    }
}
