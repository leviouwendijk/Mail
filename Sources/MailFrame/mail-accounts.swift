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
        public let username: String
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
        for account: Account
    ) -> SMTPClient? {
        account.smtp.map { SMTPClient(configuration: $0, credentials: credentials) }
    }

    public func imapClient(
        for account: Account
    ) -> IMAPClient? {
        account.imap.map { IMAPClient(configuration: $0, credentials: credentials) }
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
        let keychain = KeychainCredentialProvider(service: keychainService)

        for binding in document.bindings(ofType: "Account") {
            let field = binding.name
            let spec = try document.decode(MailFrame.Account.self, binding: field)

            let reference: CredentialReference
            switch (spec.password.env.flatMap(Self.nonEmpty), spec.password.keychain.flatMap(Self.nonEmpty)) {
            case (let variable?, nil):
                reference = CredentialReference("mail.\(field).password")
                routes[reference] = EnvironmentCredentialProvider(symbols: [reference: variable], environment: environment)
            case (nil, let item?):
                reference = CredentialReference(item)
                routes[reference] = keychain
            default:
                throw Failure.invalid(field: "\(field).password", reason: "set exactly one of env or keychain")
            }
            let authentication = MailAuthentication(username: spec.username, password: reference)

            guard spec.provider.smtp != nil || spec.provider.imap != nil else {
                throw Failure.invalid(field: "\(field).provider", reason: "set smtp, imap or both")
            }
            let smtp = try spec.provider.smtp.map { server in
                SMTPConfiguration(
                    server: try Self.server(server, defaultPorts: (465, 587), authentication: authentication, at: "\(field).provider.smtp"),
                    clientName: Self.clientName(spec.identities.first?.address)
                )
            }
            let imap = try spec.provider.imap.map { server in
                IMAPConfiguration(
                    server: try Self.server(server, defaultPorts: (993, 143), authentication: authentication, at: "\(field).provider.imap")
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
                username: spec.username,
                smtp: smtp,
                imap: imap,
                identities: identities,
                folders: Self.folders(spec.folders),
                sending: spec.sending ?? .drafts,
                about: spec.about.flatMap(Self.nonEmpty)
            ))
        }

        self.accounts = accounts
        self.credentials = RoutedCredentialProvider(routes: routes)
    }

    private static func server(
        _ spec: MailFrame.Server,
        defaultPorts: (tls: UInt16, startTLS: UInt16),
        authentication: MailAuthentication,
        at field: String
    ) throws -> MailServerConfiguration {
        guard let host = nonEmpty(spec.host) else {
            throw Failure.invalid(field: "\(field).host", reason: "must not be empty")
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
        if let value = spec.port {
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

    private static func nonEmpty(
        _ text: String
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
