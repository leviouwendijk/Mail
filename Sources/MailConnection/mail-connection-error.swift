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

extension MailConnectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            return "\(port) is not a valid port."
        case .connectionFailed(let reason):
            return "Could not connect: \(reason)"
        case .connectionClosed:
            return "The server closed the connection."
        case .timedOut:
            return "The server did not answer in time."
        case .authenticationRequiresTLS:
            return "Refusing to send a password over an unencrypted connection."
        case .missingCredentialProvider:
            return "No credential provider to resolve the password."
        case .startTLSUnavailable:
            return "The server does not offer STARTTLS, which the configuration requires."
        case .unexpectedDataBeforeTLS:
            return "The server sent data before the TLS handshake; the connection was dropped."
        }
    }
}
