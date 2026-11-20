import Errors
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

extension SMTPError:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    public static let errorNamespace = "mail.smtp"

    public var errorCode: String {
        switch self {
        case .malformedReply: return "malformed_reply"
        case .unexpectedReply(_, let reply) where reply.code == 535: return "login_rejected"
        case .unexpectedReply: return "unexpected_reply"
        case .authenticationUnsupported: return "authentication_unsupported"
        case .noRecipients: return "no_recipients"
        case .allRecipientsRejected: return "all_recipients_rejected"
        }
    }

    public var errorPresentation: ErrorPresentation {
        switch self {
        case .malformedReply(let line):
            return .init(
                message: "The SMTP server sent a reply that could not be read.",
                reason: line,
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .unexpectedReply(let command, let reply) where reply.code == 535:
            return .init(
                message: "SMTP login rejected (\(command)).",
                reason: reply.description,
                recoverySuggestion: "Check the username and password.",
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .unexpectedReply(let command, let reply):
            return .init(
                message: "SMTP \(command) failed.",
                reason: reply.description,
                recoverySuggestion: (400..<500).contains(reply.code) ? "The server refused for now; try again later." : nil,
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .authenticationUnsupported:
            return .init(
                message: "The SMTP server offers no supported login method.",
                recoverySuggestion: "Use a server or account that offers PLAIN or LOGIN over TLS."
            )
        case .noRecipients:
            return .init(
                message: "The message has no recipients.",
                recoverySuggestion: "Add at least one address to to, cc or bcc."
            )
        case .allRecipientsRejected(let rejections):
            return .init(
                message: "Every recipient was refused.",
                reason: rejections.map { "\($0.recipient.raw) (\($0.reply))" }.joined(separator: "; "),
                recoverySuggestion: "Check the addresses.",
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        }
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        switch self {
        case .unexpectedReply(let command, let reply):
            return [
                .init(key: "smtp.command", value: command),
                .init(key: "smtp.reply_code", value: reply.code),
            ]
        case .allRecipientsRejected(let rejections):
            return [
                .init(key: "smtp.rejected_count", value: rejections.count),
                .init(key: "smtp.reply_codes", value: .array(rejections.map { .integer($0.reply.code) })),
            ]
        case .authenticationUnsupported(let advertised):
            return [.init(key: "smtp.advertised", value: .array(advertised.map { .string($0) }))]
        case .malformedReply, .noRecipients:
            return []
        }
    }

    public var errorDisposition: ErrorDisposition? {
        switch self {
        case .unexpectedReply(_, let reply) where reply.code == 535:
            return .requires_configuration
        case .unexpectedReply(_, let reply) where (400..<500).contains(reply.code):
            return .transient
        case .unexpectedReply(_, let reply) where [550, 551, 553, 501].contains(reply.code):
            return .invalid_input
        case .unexpectedReply:
            return .permanent
        case .authenticationUnsupported:
            return .requires_configuration
        case .noRecipients, .allRecipientsRejected:
            return .invalid_input
        case .malformedReply:
            return nil
        }
    }
}
