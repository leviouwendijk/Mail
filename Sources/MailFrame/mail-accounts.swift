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

    /// What an account's servers are for.
    public enum Service: String, Sendable, Hashable, CaseIterable {
        case smtp
        case imap
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
        /// The provider files sent mail itself; skip saving a copy after sending.
        public let savesSentMail: Bool
        /// Its group, for selectors such as `hondenmeesters:@junk`.
        public let group: String?
        public let about: String?
        /// Servers left out because a setting they need is not in the
        /// environment, with the reason; the account's other server still works.
        public let unavailable: [Service: String]

        public var defaultIdentity: MailIdentity {
            identities[0]
        }
    }

    /// In declaration order; the first is the default.
    public let accounts: [Account]
    public let credentials: any CredentialProvider
    /// Access profiles in declaration order.
    public let profiles: [MailAccess]
    private let routes: [CredentialReference: any CredentialProvider]
    private let sources: [CredentialReference: String]

    private init(
        accounts: [Account],
        profiles: [MailAccess],
        routes: [CredentialReference: any CredentialProvider],
        sources: [CredentialReference: String]
    ) {
        self.accounts = accounts
        self.profiles = profiles
        self.routes = routes
        self.sources = sources
        self.credentials = RoutedCredentialProvider(routes: routes)
    }

    /// Group names in first-seen order.
    public var groups: [String] {
        var seen: Set<String> = []
        return accounts.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    /// The profile named `name`; `nil` means unrestricted.
    public func access(
        named name: String?
    ) throws -> MailAccess {
        guard let name, !name.isEmpty else {
            return .unrestricted
        }
        guard let profile = profiles.first(where: { $0.name == name }) else {
            throw MailAccess.Failure.unknownProfile(name, known: profiles.map(\.name))
        }
        return profile
    }

    /// Every profile names only declared accounts.
    func validateProfiles() throws {
        let known = Set(accounts.map(\.identifier))
        for profile in profiles {
            for name in profile.accounts ?? [] where !known.contains(name) {
                throw Failure.invalid(field: "\(profile.name).accounts", reason: "no account named '\(name)'")
            }
        }
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
        var profiles: [MailAccess] = []
        var routes: [CredentialReference: any CredentialProvider] = [:]
        var sources: [CredentialReference: String] = [:]
        for part in parts {
            for profile in part.profiles {
                guard !profiles.contains(where: { $0.name == profile.name }) else {
                    throw Failure.invalid(field: profile.name, reason: "an access profile with this name is declared in more than one file")
                }
                profiles.append(profile)
            }
            for account in part.accounts {
                guard !accounts.contains(where: { $0.identifier == account.identifier }) else {
                    throw Failure.invalid(field: account.identifier, reason: "an account with this name is declared in more than one file")
                }
                accounts.append(account)
            }
            routes.merge(part.routes) { first, _ in first }
            sources.merge(part.sources) { first, _ in first }
        }
        let merged = MailAccounts(accounts: accounts, profiles: profiles, routes: routes, sources: sources)
        try merged.validateProfiles()
        return merged
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

    /// `groups` names each binding's default group, such as the folder its file is in.
    public init(
        document: Frame.Document,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychainService: String = "mail",
        groups: [String: String] = [:]
    ) throws {
        var accounts: [Account] = []
        var routes: [CredentialReference: any CredentialProvider] = [:]
        var sources: [CredentialReference: String] = [:]
        let keychain = KeychainCredentialProvider(service: keychainService)

        for binding in document.bindings(ofType: "Account") {
            let field = binding.name
            let spec = try document.decode(MailFrame.Account.self, binding: field)

            var unavailable: [Service: String] = [:]

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
                    throw Self.missing(usernameSetting, at: server.username == nil ? "\(field).username" : "\(at).username")
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
            /// The server, or `nil` with its reason when the environment lacks a setting it needs.
            func available<Configuration>(
                _ service: Service,
                _ make: () throws -> Configuration
            ) throws -> Configuration? {
                do {
                    return try make()
                } catch let unresolved as Unresolved {
                    unavailable[service] = "\(unresolved.field): \(unresolved.reason)"
                    return nil
                }
            }

            let smtp = try spec.provider.smtp.flatMap { server in try available(.smtp) {
                SMTPConfiguration(
                    server: try Self.server(server, defaultPorts: (465, 587), authentication: authentication(for: server, role: "smtp"), environment: environment, at: "\(field).provider.smtp"),
                    clientName: Self.clientName(spec.identities.first?.address)
                )
            } }
            let imap = try spec.provider.imap.flatMap { server in try available(.imap) {
                IMAPConfiguration(
                    server: try Self.server(server, defaultPorts: (993, 143), authentication: authentication(for: server, role: "imap"), environment: environment, at: "\(field).provider.imap")
                )
            } }

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
                savesSentMail: spec.provider.features?.savesSentMail ?? false,
                group: spec.group.flatMap(Self.nonEmpty) ?? groups[field],
                about: spec.about.flatMap(Self.nonEmpty),
                unavailable: unavailable
            ))
        }

        // Profiles may name accounts of other files; `merging` validates the names.
        var profiles: [MailAccess] = []
        for binding in document.bindings(ofType: "Access") {
            let spec = try document.decode(MailFrame.Access.self, binding: binding.name)
            let names = try spec.accounts.map { references in
                try references.enumerated().map { index, reference -> String in
                    switch reference {
                    case .name(let name):
                        return name
                    case .account(let account):
                        // A binding resolves to its value; find which account it was.
                        guard let match = document.bindings(ofType: "Account").first(where: {
                            (try? document.decode(MailFrame.Account.self, binding: $0.name)) == account
                        }) else {
                            throw Failure.invalid(field: "\(binding.name).accounts[\(index)]", reason: "not a declared account")
                        }
                        return match.name
                    }
                }
            }
            profiles.append(MailAccess(
                name: binding.name,
                accounts: names,
                mailboxes: spec.mailboxes,
                identities: spec.identities.map(Set.init),
                mayDraft: spec.draft ?? true,
                maySend: spec.send ?? true
            ))
        }

        self.init(accounts: accounts, profiles: profiles, routes: routes, sources: sources)
    }

    private static func server(
        _ spec: MailFrame.Server,
        defaultPorts: (tls: UInt16, startTLS: UInt16),
        authentication: MailAuthentication,
        environment: [String: String],
        at field: String
    ) throws -> MailServerConfiguration {
        guard let host = spec.host.resolve(in: environment).flatMap(nonEmpty) else {
            throw missing(spec.host, at: "\(field).host")
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
                throw missing(setting, at: "\(field).port")
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

    /// A setting with no value, which leaves its server out instead of failing the file.
    private struct Unresolved: Error {
        let field: String
        let reason: String
    }

    /// Why a setting has no value: an unset variable leaves its server out;
    /// an empty written value is an error in the file.
    private static func missing<Value>(
        _ setting: MailFrame.Setting<Value>,
        at field: String
    ) -> any Error {
        switch setting {
        case .env(let variable):
            return Unresolved(field: field, reason: "environment variable \(variable) is unset, empty or not a valid \(Value.self)")
        case .value:
            return Failure.invalid(field: field, reason: "must not be empty")
        }
    }

    private static func nonEmpty(
        _ text: String
    ) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
