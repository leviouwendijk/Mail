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
