import Foundation
import Frame
import IMAP
import Mail
import MailConnection
import Milieu
import Readers
import SMTP

/// A `mail.frame` document read into guaranteed values, with a credential
/// provider that resolves each account's password from where the file says.
public struct MailAccounts: Sendable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case invalid(field: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .invalid(let field, let reason):
                return "\(field): \(reason)"
            }
        }
    }

    public struct Account: Sendable {
        /// The binding name.
        public let identifier: String
        public let smtp: SMTPConfiguration?
        public let imap: IMAPConfiguration?
        /// The first is the default.
        public let identities: [MailIdentity]
        /// Folder names by role, where the file sets them.
        public let folders: [IMAPSpecialUse: String]
        public let sending: MailFrame.Sending
        public let about: String?

        public var defaultIdentity: MailIdentity {
            identities[0]
        }
    }

    /// In declaration order; the first is the default.
    public let accounts: [Account]
    public let credentials: any CredentialProvider
    private let routes: [CredentialReference: any CredentialProvider]
    private let sources: [CredentialReference: String]

    private init(
        accounts: [Account],
        routes: [CredentialReference: any CredentialProvider],
        sources: [CredentialReference: String]
    ) {
        self.accounts = accounts
        self.routes = routes
        self.sources = sources
        self.credentials = RoutedCredentialProvider(routes: routes)
    }

    /// Where a password is read from, such as `env AWS_SMTP_PASSWD` or `keychain item personal`.
    public func source(
        of reference: CredentialReference
    ) -> String {
        sources[reference] ?? reference.id
    }

    /// Accounts from several files, in order; a binding name may appear once.
    public static func merging(
        _ parts: [MailAccounts]
    ) throws -> MailAccounts {
        var accounts: [Account] = []
        var routes: [CredentialReference: any CredentialProvider] = [:]
        var sources: [CredentialReference: String] = [:]
        for part in parts {
            for account in part.accounts {
                guard !accounts.contains(where: { $0.identifier == account.identifier }) else {
                    throw Failure.invalid(field: account.identifier, reason: "an account with this name is declared in more than one file")
                }
                accounts.append(account)
            }
            routes.merge(part.routes) { first, _ in first }
            sources.merge(part.sources) { first, _ in first }
        }
        return MailAccounts(accounts: accounts, routes: routes, sources: sources)
    }

    public var defaultAccount: Account? {
        accounts.first
    }

    public func account(
        named identifier: String
    ) -> Account? {
        accounts.first { $0.identifier == identifier }
    }

    /// The account with an identity sending as `address`.
    public func account(
        sendingAs address: EmailAddress
    ) -> Account? {
        accounts.first { account in
            account.identities.contains { $0.address.address == address }
        }
    }

    public func smtpClient(
        for account: Account,
        connector: @escaping MailConnector = MailServerConfiguration.networkConnector
    ) -> SMTPClient? {
        account.smtp.map { SMTPClient(configuration: $0, credentials: credentials, connector: connector) }
    }

    public func imapClient(
        for account: Account,
        connector: @escaping MailConnector = MailServerConfiguration.networkConnector
    ) -> IMAPClient? {
        account.imap.map { IMAPClient(configuration: $0, credentials: credentials, connector: connector) }
    }

    /// Reads `url`; `nil` when the file is missing or empty.
    public static func load(
        from url: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MailAccounts? {
        let source = try TextFileReader(url)
            .read(options: .init(missingFilePolicy: .returnEmpty))
            .text
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try MailAccounts(source: source, filePath: url.path, environment: environment)
    }

    public init(
        source: String,
        filePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "mail"
    ) throws {
        try self.init(
            document: Frame.parse(source, filePath: filePath, environment: MailFrame.environment),
            environment: environment,
            keychainService: keychainService
        )
    }

    public init(
        document: Frame.Document,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "mail"
    ) throws {
        var accounts: [Account] = []
        var routes: [CredentialReference: any CredentialProvider] = [:]
        var sources: [CredentialReference: String] = [:]
        let keychain = KeychainCredentialProvider(service: keychainService)

        for binding in document.bindings(ofType: "Account") {
            let field = binding.name
            let spec = try document.decode(MailFrame.Account.self, binding: field)

            /// The server's own login, else the account's; each part falls back separately.
            func authentication(
                for server: MailFrame.Server,
                role: String
            ) throws -> MailAuthentication {
                let at = "\(field).provider.\(role)"
                guard let usernameSetting = server.username ?? spec.username else {
                    throw Failure.invalid(field: "\(at).username", reason: "set username on the account or on this server")
                }
                guard let username = usernameSetting.resolve(in: environment).flatMap(Self.nonEmpty) else {
                    throw Failure.invalid(field: server.username == nil ? "\(field).username" : "\(at).username", reason: Self.unset(usernameSetting))
                }
                guard let secret = server.password ?? spec.password else {
                    throw Failure.invalid(field: "\(at).password", reason: "set password on the account or on this server")
                }
                let owner = server.password == nil ? field : "\(field).\(role)"
                let reference: CredentialReference
                switch (secret.env.flatMap(Self.nonEmpty), secret.keychain.flatMap(Self.nonEmpty)) {
                case (let variable?, nil):
                    reference = CredentialReference("mail.\(owner).password")
                    routes[reference] = EnvironmentCredentialProvider(symbols: [reference: variable], environment: environment)
                    sources[reference] = "env \(variable)"
                case (nil, let item?):
                    reference = CredentialReference(item)
                    routes[reference] = keychain
                    sources[reference] = "keychain item \(item) (service \(keychainService))"
                default:
                    throw Failure.invalid(field: "\(owner).password", reason: "set exactly one of env or keychain")
                }
                return MailAuthentication(username: username, password: reference)
            }

            guard spec.provider.smtp != nil || spec.provider.imap != nil else {
                throw Failure.invalid(field: "\(field).provider", reason: "set smtp, imap or both")
            }
            let smtp = try spec.provider.smtp.map { server in
                SMTPConfiguration(
                    server: try Self.server(server, defaultPorts: (465, 587), authentication: authentication(for: server, role: "smtp"), environment: environment, at: "\(field).provider.smtp"),
                    clientName: Self.clientName(spec.identities.first?.address)
                )
            }
            let imap = try spec.provider.imap.map { server in
                IMAPConfiguration(
                    server: try Self.server(server, defaultPorts: (993, 143), authentication: authentication(for: server, role: "imap"), environment: environment, at: "\(field).provider.imap")
                )
            }

            guard !spec.identities.isEmpty else {
                throw Failure.invalid(field: "\(field).identities", reason: "declare at least one identity")
            }
            let identities = try spec.identities.enumerated().map { index, identity in
                try Self.identity(identity, at: "\(field).identities[\(index)]")
            }

            accounts.append(Account(
                identifier: field,
                smtp: smtp,
                imap: imap,
                identities: identities,
                folders: Self.folders(spec.folders),
                sending: spec.sending ?? .drafts,
                about: spec.about.flatMap(Self.nonEmpty)
            ))
        }

        self.init(accounts: accounts, routes: routes, sources: sources)
    }

    private static func server(
        _ spec: MailFrame.Server,
        defaultPorts: (tls: UInt16, startTLS: UInt16),
        authentication: MailAuthentication,
        environment: [String: String],
        at field: String
    ) throws -> MailServerConfiguration {
        guard let host = spec.host.resolve(in: environment).flatMap(nonEmpty) else {
            throw Failure.invalid(field: "\(field).host", reason: unset(spec.host))
        }
        let security: MailSecurity
        switch spec.security ?? .tls {
        case .tls:
            security = .implicitTLS
        case .starttls:
            security = .startTLS
        case .plaintext:
            security = .plaintext
        }
        var port = security == .startTLS ? defaultPorts.startTLS : defaultPorts.tls
        if let setting = spec.port {
            guard let value = setting.resolve(in: environment) else {
                throw Failure.invalid(field: "\(field).port", reason: unset(setting))
            }
            guard let valid = UInt16(exactly: value), valid > 0 else {
                throw Failure.invalid(field: "\(field).port", reason: "must be between 1 and 65535")
            }
            port = valid
        }
        return MailServerConfiguration(
            host: host,
            port: port,
            security: security,
            authentication: authentication
        )
    }

    private static func identity(
        _ spec: MailFrame.Identity,
        at field: String
    ) throws -> MailIdentity {
        func address(_ raw: String, name: String?, at field: String) throws -> NamedAddress {
            do {
                return try NamedAddress(raw, name: name)
            } catch {
                throw Failure.invalid(field: field, reason: "'\(raw)' is not a valid address (\(error))")
            }
        }
        return MailIdentity(
            address: try address(spec.address, name: spec.name, at: "\(field).address"),
            replyTo: try spec.replyTo.map { try address($0, name: nil, at: "\(field).replyTo") },
            signature: spec.signature.map { MailSignature(text: $0.text, html: $0.html) }
        )
    }

    private static func folders(
        _ spec: MailFrame.Folders?
    ) -> [IMAPSpecialUse: String] {
        guard let spec else {
            return [:]
        }
        let pairs: [(IMAPSpecialUse, String?)] = [
            (.sent, spec.sent),
            (.drafts, spec.drafts),
            (.archive, spec.archive),
            (.trash, spec.trash),
            (.junk, spec.junk),
        ]
        return Dictionary(uniqueKeysWithValues: pairs.compactMap { role, name in
            name.flatMap(nonEmpty).map { (role, $0) }
        })
    }

    /// The default identity's domain, a better `EHLO` name than `localhost`.
    private static func clientName(
        _ address: String?
    ) -> String {
        address
            .flatMap { try? EmailAddress($0) }
            .map { String($0.domain) } ?? "localhost"
    }

    /// Why a setting has no value: an unset variable names itself; a written value was empty.
    private static func unset<Value>(
        _ setting: MailFrame.Setting<Value>
    ) -> String {
        switch setting {
        case .env(let variable):
            return "environment variable \(variable) is unset, empty or not a valid \(Value.self)"
        case .value:
            return "must not be empty"
        }
    }

    private static func nonEmpty(
        _ text: String
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
