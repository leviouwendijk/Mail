import Mail
import MailConnection
import Milieu

public struct IMAPConfiguration: Sendable {
    public var server: MailServerConfiguration

    public init(
        server: MailServerConfiguration
    ) {
        self.server = server
    }

    public init(
        host: String,
        port: UInt16 = 993,
        security: MailSecurity = .implicitTLS,
        authentication: MailAuthentication? = nil,
        timeout: Duration = .seconds(30)
    ) {
        self.init(
            server: MailServerConfiguration(
                host: host,
                port: port,
                security: security,
                authentication: authentication,
                timeout: timeout
            )
        )
    }
}

public struct IMAPClient: Sendable {
    public let configuration: IMAPConfiguration
    public let credentials: (any CredentialProvider)?

    public init(
        configuration: IMAPConfiguration,
        credentials: (any CredentialProvider)? = nil
    ) {
        self.configuration = configuration
        self.credentials = credentials
    }

    /// Connects, authenticates, runs `body` and logs out.
    public func session<T: Sendable>(
        _ body: (IMAPSession) async throws -> T
    ) async throws -> T {
        let resolved = try await configuration.server.resolveCredentials(using: credentials)
        let transport = try await configuration.server.connect()
        let session = IMAPSession(transport: transport)

        do {
            let preauthenticated = try await session.start(
                startTLS: configuration.server.security == .startTLS
            )
            if let resolved, !preauthenticated {
                try await session.authenticate(resolved)
            }
            let result = try await body(session)
            try await session.logout()
            await transport.close()
            return result
        } catch {
            await transport.close()
            throw error
        }
    }

    public func mailboxes() async throws -> [IMAPMailbox] {
        try await session { try await $0.list() }
    }

    public func status(
        of mailbox: String
    ) async throws -> IMAPMailboxStatus {
        try await session { try await $0.status(mailbox) }
    }

    /// Summaries of messages in `mailbox` matching `query`, newest last; `limit` keeps the newest.
    public func search(
        _ query: IMAPSearch,
        in mailbox: String = "INBOX",
        limit: Int? = nil
    ) async throws -> [IMAPMessageSummary] {
        try await session { session in
            try await session.select(mailbox)
            var uids = try await session.search(query)
            if let limit {
                uids = Array(uids.suffix(limit))
            }
            return try await session.summaries(uids)
        }
    }

    public func message(
        _ uid: IMAPUID,
        in mailbox: String = "INBOX"
    ) async throws -> ReceivedMessage? {
        try await session { session in
            try await session.select(mailbox)
            return try await session.message(uid)
        }
    }
}
