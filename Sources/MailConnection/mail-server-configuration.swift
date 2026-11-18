import Milieu

public enum MailSecurity: Sendable, Equatable {
    /// TLS from the first byte (RFC 8314); the default for submission and retrieval.
    case implicitTLS
    /// Plain TCP upgraded with `STARTTLS` before authenticating, as on port 587
    /// or 143. Required: a server that does not offer it is refused.
    case startTLS
    /// No encryption; only for local relays such as a development catcher.
    case plaintext

    public var isEncrypted: Bool {
        self != .plaintext
    }
}

public struct MailAuthentication: Sendable, Equatable {
    public let username: String
    /// Resolved through a `CredentialProvider` when connecting.
    public let password: CredentialReference

    public init(
        username: String,
        password: CredentialReference
    ) {
        self.username = username
        self.password = password
    }
}

/// Resolved credentials; held only for the duration of a session.
public struct MailCredentials: Sendable {
    public let username: String
    public let password: String

    public init(
        username: String,
        password: String
    ) {
        self.username = username
        self.password = password
    }
}

/// Opens a transport to a server; replaceable so sessions can run against a scripted server.
public typealias MailConnector = @Sendable (MailServerConfiguration) async throws -> any MailTransport

public struct MailServerConfiguration: Sendable {
    /// The real network connection.
    public static let networkConnector: MailConnector = { try await $0.connect() }

    public var host: String
    public var port: UInt16
    public var security: MailSecurity
    public var authentication: MailAuthentication?
    public var timeout: Duration

    public init(
        host: String,
        port: UInt16,
        security: MailSecurity = .implicitTLS,
        authentication: MailAuthentication? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.authentication = authentication
        self.timeout = timeout
    }

    /// `nil` without authentication; refuses to send a password over plaintext.
    public func resolveCredentials(
        using provider: (any CredentialProvider)?
    ) async throws -> MailCredentials? {
        guard let authentication else {
            return nil
        }
        guard security.isEncrypted else {
            throw MailConnectionError.authenticationRequiresTLS
        }
        guard let provider else {
            throw MailConnectionError.missingCredentialProvider
        }
        return MailCredentials(
            username: authentication.username,
            password: try await provider.resolve(authentication.password).utf8()
        )
    }

    public func connect() async throws -> StreamMailTransport {
        try await StreamMailTransport.connect(
            host: host,
            port: port,
            security: security,
            timeout: timeout
        )
    }
}
