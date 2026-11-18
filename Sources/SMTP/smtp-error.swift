import Mail

public struct SMTPRecipientRejection: Sendable, Equatable {
    public let recipient: EmailAddress
    public let reply: SMTPReply

    public init(
        recipient: EmailAddress,
        reply: SMTPReply
    ) {
        self.recipient = recipient
        self.reply = reply
    }
}

/// Protocol-level failures; transport failures surface as `MailConnectionError`.
public enum SMTPError: Error, Sendable, Equatable {
    case malformedReply(String)
    case unexpectedReply(command: String, reply: SMTPReply)
    case authenticationUnsupported(advertised: [String])
    case noRecipients
    case allRecipientsRejected([SMTPRecipientRejection])
}
