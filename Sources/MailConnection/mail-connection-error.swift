import Errors
import Foundation

public enum MailConnectionError: Error, Sendable, Equatable {
    case invalidPort(UInt16)
    case connectionFailed(String)
    case connectionClosed
    case timedOut
    case authenticationRequiresTLS
    case missingCredentialProvider
    /// The server offered no `STARTTLS` though the configuration requires it.
    case startTLSUnavailable
    /// The server sent data after agreeing to `STARTTLS` and before the handshake.
    case unexpectedDataBeforeTLS
}

extension MailConnectionError:
    SemanticError,
    ErrorNamespaced,
    ErrorDispositionProviding
{
    public static let errorNamespace = "mail.connection"

    public var errorCode: String {
        switch self {
        case .invalidPort: return "invalid_port"
        case .connectionFailed: return "connection_failed"
        case .connectionClosed: return "connection_closed"
        case .timedOut: return "timed_out"
        case .authenticationRequiresTLS: return "authentication_requires_tls"
        case .missingCredentialProvider: return "missing_credential_provider"
        case .startTLSUnavailable: return "starttls_unavailable"
        case .unexpectedDataBeforeTLS: return "unexpected_data_before_tls"
        }
    }

    public var errorPresentation: ErrorPresentation {
        switch self {
        case .invalidPort(let port):
            return .init(
                message: "\(port) is not a valid port.",
                recoverySuggestion: "Set the server's port in the mail configuration."
            )
        case .connectionFailed(let reason):
            return .init(
                message: "Could not connect to the mail server.",
                // The system's text can name the host.
                reason: reason,
                reasonSensitivity: .potentially_sensitive
            )
        case .connectionClosed:
            return .init(
                message: "The server closed the connection.",
                recoverySuggestion: "Try again."
            )
        case .timedOut:
            return .init(
                message: "The server did not answer in time.",
                recoverySuggestion: "Try again."
            )
        case .authenticationRequiresTLS:
            return .init(
                message: "Refusing to send a password over an unencrypted connection.",
                recoverySuggestion: "Configure TLS or STARTTLS for this server."
            )
        case .missingCredentialProvider:
            return .init(
                message: "No credential provider to resolve the password."
            )
        case .startTLSUnavailable:
            return .init(
                message: "The server does not offer STARTTLS, which the configuration requires.",
                recoverySuggestion: "Use the server's TLS port, or check the server address."
            )
        case .unexpectedDataBeforeTLS:
            return .init(
                message: "The server sent data before the TLS handshake; the connection was dropped."
            )
        }
    }

    public var errorDisposition: ErrorDisposition? {
        switch self {
        case .connectionFailed, .connectionClosed, .timedOut:
            return .transient
        case .invalidPort, .authenticationRequiresTLS, .missingCredentialProvider, .startTLSUnavailable:
            return .requires_configuration
        case .unexpectedDataBeforeTLS:
            return .permanent
        }
    }
}
