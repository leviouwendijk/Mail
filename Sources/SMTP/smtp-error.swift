import Foundation
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

extension SMTPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedReply(let line):
            return "The SMTP server sent a reply that could not be read: \(line)"
        case .unexpectedReply(let command, let reply):
            if reply.code == 535 {
                return "SMTP login rejected: \(reply) Check the username and password."
            }
            return "SMTP \(command) failed: \(reply)"
        case .authenticationUnsupported(let advertised):
            return "The SMTP server offers no supported login method (advertised: \(advertised.joined(separator: " ")))."
        case .noRecipients:
            return "The message has no recipients."
        case .allRecipientsRejected(let rejections):
            return "Every recipient was refused: " + rejections.map { "\($0.recipient.raw) (\($0.reply))" }.joined(separator: "; ")
        }
    }
}
