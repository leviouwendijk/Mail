import Foundation

/// Protocol-level failures; transport failures surface as `MailConnectionError`.
public enum IMAPError: Error, Sendable, Equatable {
    case malformedResponse(String)
    case greetingRejected(String)
    case commandFailed(command: String, status: IMAPStatusText)
    case authenticationUnsupported(capabilities: [String])
    case connectionEnded(IMAPStatusText)
    /// The query or fetch needs a capability the server does not advertise.
    case unsupported(capability: String)
    /// A change needs a mailbox selected with `select(_:readOnly: false)`.
    case notWritable(mailbox: String?)
}

extension IMAPError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let line):
            return "The IMAP server sent a response that could not be read: \(line)"
        case .greetingRejected(let text):
            return "The IMAP server refused the connection: \(text)"
        case .commandFailed(let command, let status):
            if status.code == "AUTHENTICATIONFAILED" || command == "AUTHENTICATE" || command == "LOGIN" {
                return "IMAP login rejected: \(status.text) Check the username and password."
            }
            return "IMAP \(command) failed: \(status.status)\(status.code.map { " [\($0)]" } ?? "") \(status.text)"
        case .authenticationUnsupported(let capabilities):
            return "The IMAP server offers no supported login method (capabilities: \(capabilities.joined(separator: " ")))."
        case .connectionEnded(let status):
            return "The IMAP server ended the connection: \(status.text)"
        case .unsupported(let capability):
            return "The IMAP server does not support \(capability)."
        case .notWritable(let mailbox):
            if let mailbox {
                return "\(mailbox) is selected read-only; select it with readOnly: false to change messages."
            }
            return "No mailbox is selected; select one with readOnly: false to change messages."
        }
    }
}
