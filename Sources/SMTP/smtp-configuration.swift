import MailConnection

public struct SMTPConfiguration: Sendable {
    public var server: MailServerConfiguration
    /// The name announced in `EHLO`.
    public var clientName: String

    public init(
        server: MailServerConfiguration,
        clientName: String = "localhost"
    ) {
        self.server = server
        self.clientName = clientName
    }

    public init(
        host: String,
        port: UInt16 = 465,
        security: MailSecurity = .implicitTLS,
        authentication: MailAuthentication? = nil,
        clientName: String = "localhost",
        timeout: Duration = .seconds(30)
    ) {
        self.init(
            server: MailServerConfiguration(
                host: host,
                port: port,
                security: security,
                authentication: authentication,
                timeout: timeout
            ),
            clientName: clientName
        )
    }
}
