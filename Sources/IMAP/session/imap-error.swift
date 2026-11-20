import Errors
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

extension IMAPError:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    public static let errorNamespace = "mail.imap"

    public var errorCode: String {
        switch self {
        case .malformedResponse: return "malformed_response"
        case .greetingRejected: return "greeting_rejected"
        case .commandFailed where isLoginRejection: return "login_rejected"
        case .commandFailed: return "command_failed"
        case .authenticationUnsupported: return "authentication_unsupported"
        case .connectionEnded: return "connection_ended"
        case .unsupported: return "unsupported"
        case .notWritable: return "not_writable"
        }
    }

    public var errorPresentation: ErrorPresentation {
        switch self {
        case .malformedResponse(let line):
            return .init(
                message: "The IMAP server sent a response that could not be read.",
                reason: line,
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .greetingRejected(let text):
            return .init(
                message: "The IMAP server refused the connection.",
                reason: text,
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .commandFailed(let command, let status) where isLoginRejection:
            return .init(
                message: "IMAP login rejected (\(command)).",
                reason: status.text,
                recoverySuggestion: "Check the username and password.",
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .commandFailed(let command, let status):
            return .init(
                message: "IMAP \(command) failed.",
                reason: status.line,
                recoverySuggestion: Self.suggestion(for: status.atom),
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .authenticationUnsupported:
            return .init(
                message: "The IMAP server offers no supported login method.",
                recoverySuggestion: "Use a server or account that offers PLAIN or LOGIN over TLS."
            )
        case .connectionEnded(let status):
            return .init(
                message: "The IMAP server ended the connection.",
                reason: status.text,
                recoverySuggestion: "Try again; the server may be busy or restarting.",
                reasonSensitivity: .potentially_sensitive,
                reasonOrigin: .remote
            )
        case .unsupported(let capability):
            return .init(
                message: "The IMAP server does not support \(capability)."
            )
        case .notWritable(let mailbox):
            if let mailbox {
                return .init(
                    message: "\(mailbox) is selected read-only.",
                    recoverySuggestion: "Select it with readOnly: false to change messages.",
                    messageSensitivity: .potentially_sensitive
                )
            }
            return .init(
                message: "No mailbox is selected.",
                recoverySuggestion: "Select one with readOnly: false to change messages."
            )
        }
    }

    public var errorDiagnosticFields: [ErrorDiagnosticField] {
        switch self {
        case .commandFailed(let command, let status):
            return [
                .init(key: "imap.command", value: command),
                .init(key: "imap.status", value: status.status),
            ] + (status.code.map { [.init(key: "imap.response_code", value: $0)] } ?? [])
        case .connectionEnded(let status):
            return status.code.map { [.init(key: "imap.response_code", value: $0)] } ?? []
        case .authenticationUnsupported(let capabilities):
            return [.init(key: "imap.capabilities", value: .array(capabilities.map { .string($0) }))]
        case .unsupported(let capability):
            return [.init(key: "imap.capability", value: capability)]
        case .notWritable(let mailbox):
            return mailbox.map { [.init(key: "mailbox", value: $0, sensitivity: .potentially_sensitive)] } ?? []
        case .malformedResponse, .greetingRejected:
            return []
        }
    }

    public var errorDisposition: ErrorDisposition? {
        switch self {
        case .commandFailed where isLoginRejection:
            return .requires_configuration
        case .commandFailed(_, let status):
            return Self.disposition(for: status.atom)
        case .connectionEnded, .greetingRejected:
            return .transient
        case .authenticationUnsupported:
            return .requires_configuration
        case .unsupported:
            return .permanent
        case .notWritable:
            return .invalid_input
        case .malformedResponse:
            return nil
        }
    }

    private var isLoginRejection: Bool {
        guard case .commandFailed(let command, let status) = self else {
            return false
        }
        return status.atom == "AUTHENTICATIONFAILED" || command == "AUTHENTICATE" || command == "LOGIN"
    }

    /// RFC 5530 response codes, where they say what to do.
    private static func disposition(
        for code: String?
    ) -> ErrorDisposition? {
        switch code {
        case "UNAVAILABLE", "INUSE", "LIMIT", "SERVERBUG":
            return .transient
        case "NOPERM", "PRIVACYREQUIRED":
            return .requires_access
        case "AUTHENTICATIONFAILED", "AUTHORIZATIONFAILED", "EXPIRED":
            return .requires_configuration
        case "NONEXISTENT", "TRYCREATE", "ALREADYEXISTS", "CANNOT", "BADCHARSET", "CLIENTBUG":
            return .invalid_input
        case "OVERQUOTA", "CONTACTADMIN":
            return .permanent
        default:
            return nil
        }
    }

    private static func suggestion(
        for code: String?
    ) -> String? {
        switch code {
        case "NONEXISTENT", "TRYCREATE":
            return "The mailbox does not exist; list mailboxes to find its path, or create it first."
        case "ALREADYEXISTS":
            return "A mailbox with that path already exists."
        case "NOPERM":
            return "The account may not do this in that mailbox."
        case "UNAVAILABLE", "INUSE":
            return "The server is busy; try again shortly."
        case "OVERQUOTA":
            return "The mailbox is full; free space before trying again."
        default:
            return nil
        }
    }
}

extension IMAPStatusText {
    /// The response code's name, without its arguments (`BADCHARSET` of
    /// `BADCHARSET (UTF-8)`).
    var atom: String? {
        code?.split(separator: " ").first.map { String($0).uppercased() }
    }

    /// `NO [CODE] text`, as the server answered.
    var line: String {
        "\(status)\(code.map { " [\($0)]" } ?? "") \(text)"
    }
}
