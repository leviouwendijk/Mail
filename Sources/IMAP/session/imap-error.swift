/// Protocol-level failures; transport failures surface as `MailConnectionError`.
public enum IMAPError: Error, Sendable, Equatable {
    case malformedResponse(String)
    case greetingRejected(String)
    case commandFailed(command: String, status: IMAPStatusText)
    case authenticationUnsupported(capabilities: [String])
    case connectionEnded(IMAPStatusText)
    /// The query or fetch needs a capability the server does not advertise.
    case unsupported(capability: String)
}
