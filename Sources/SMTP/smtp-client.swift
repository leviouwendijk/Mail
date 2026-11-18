import Mail
import MailConnection
import Milieu

public struct SMTPClient: Sendable {
    public let configuration: SMTPConfiguration
    public let credentials: (any CredentialProvider)?
    public let connector: MailConnector
    public let renderer: MailRenderer

    public init(
        configuration: SMTPConfiguration,
        credentials: (any CredentialProvider)? = nil,
        renderer: MailRenderer = MailRenderer(),
        connector: @escaping MailConnector = MailServerConfiguration.networkConnector
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.renderer = renderer
        self.connector = connector
    }

    /// Renders and submits `message`; the envelope sender is `message.from`.
    @discardableResult
    public func send(
        _ message: MailMessage
    ) async throws -> SMTPDelivery {
        let resolved = try await configuration.server.resolveCredentials(using: credentials)
        let transport = try await connector(configuration.server)

        do {
            let delivery = try await SMTPSession(
                transport: transport,
                clientName: configuration.clientName,
                startTLS: configuration.server.security == .startTLS
            ).submit(
                renderer.data(message),
                from: message.from.address,
                to: message.recipients,
                credentials: resolved
            )
            await transport.close()
            return delivery
        } catch {
            await transport.close()
            throw error
        }
    }

    /// Connects, upgrades and logs in, then quits without sending.
    @discardableResult
    public func verify() async throws -> Set<String> {
        let resolved = try await configuration.server.resolveCredentials(using: credentials)
        let transport = try await connector(configuration.server)
        do {
            let extensions = try await SMTPSession(
                transport: transport,
                clientName: configuration.clientName,
                startTLS: configuration.server.security == .startTLS
            ).verify(credentials: resolved)
            await transport.close()
            return extensions
        } catch {
            await transport.close()
            throw error
        }
    }
}
