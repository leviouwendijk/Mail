import Frame

/// The `Mail` Frame module: what `import Mail;` makes nameable in `mail.frame`.
///
/// Every `let name: Account` is an account identified by its binding name, in
/// declaration order; the first is the default. Providers and identities are
/// bound once and referenced from accounts. Passwords are never written in the
/// file: a `Secret` names an environment variable or a keychain item.
public enum MailFrame {
    public static let module = Frame.Module("Mail", types: [
        .decodable(Server.self, named: "Server"),
        .decodable(Provider.self, named: "Provider"),
        .decodable(Secret.self, named: "Secret"),
        .decodable(Signature.self, named: "Signature"),
        .decodable(Identity.self, named: "Identity"),
        .decodable(Folders.self, named: "Folders"),
        .decodable(Account.self, named: "Account"),
    ])

    public static let environment = Frame.Environment([module])

    /// The file's name inside a home's `domains` directory.
    public static let fileName = "mail.frame"

    public enum Security: String, Sendable, Hashable, Decodable, CaseIterable, FrameDescribable {
        case tls
        case starttls
        case plaintext
    }

    /// What an agent may do with an account's outgoing mail.
    public enum Sending: String, Sendable, Hashable, Decodable, CaseIterable, FrameDescribable {
        case drafts
        case confirm
        case allowed
    }

    /// A value written in the file, or read from an environment variable when
    /// the file loads: `"smtp.example.org"` or `.{ .env = "SMTP_HOST" }`.
    public enum Setting<Value: Sendable & Hashable & Decodable & LosslessStringConvertible>: Sendable, Hashable, Decodable {
        case value(Value)
        case env(String)

        private enum CodingKeys: String, CodingKey {
            case env
        }

        public init(
            from decoder: any Decoder
        ) throws {
            if let value = try? decoder.singleValueContainer().decode(Value.self) {
                self = .value(value)
                return
            }
            self = .env(try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .env))
        }

        /// The value, reading the variable from `environment`; `nil` when it is unset or not a `Value`.
        public func resolve(
            in environment: [String: String]
        ) -> Value? {
            switch self {
            case .value(let value):
                return value
            case .env(let variable):
                return environment[variable]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .flatMap { $0.isEmpty ? nil : Value($0) }
            }
        }
    }

    public struct Server: Sendable, Hashable, Decodable {
        public let host: Setting<String>
        public let port: Setting<Int>?
        public let security: Security?
    }

    public struct Provider: Sendable, Hashable, Decodable {
        public let smtp: Server?
        public let imap: Server?
    }

    public struct Secret: Sendable, Hashable, Decodable {
        public let env: String?
        public let keychain: String?
    }

    public struct Signature: Sendable, Hashable, Decodable {
        public let text: String?
        public let html: String?
    }

    public struct Identity: Sendable, Hashable, Decodable {
        public let address: String
        public let name: String?
        public let replyTo: String?
        public let signature: Signature?
    }

    public struct Folders: Sendable, Hashable, Decodable {
        public let sent: String?
        public let drafts: String?
        public let archive: String?
        public let trash: String?
        public let junk: String?
    }

    public struct Account: Sendable, Hashable, Decodable {
        public let provider: Provider
        public let username: Setting<String>
        public let password: Secret
        public let identities: [Identity]
        public let folders: Folders?
        public let sending: Sending?
        public let about: String?
    }
}

extension MailFrame.Server: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("host", .any, required: true, summary: "The server's host name, or .{ .env = \"VARIABLE\" } to read it from the environment."),
            .init("port", .any, summary: "A number, or .{ .env = \"VARIABLE\" }. When absent: SMTP 465 (587 with starttls), IMAP 993 (143 with starttls)."),
            .init("security", .members(of: MailFrame.Security.self, summaries: [
                .tls: "TLS from the first byte. The default.",
                .starttls: "Plain connection upgraded with STARTTLS before login, as iCloud's SMTP requires. Refused if the server does not offer it.",
                .plaintext: "No encryption; only for a local relay. Refuses to send a password.",
            ]), summary: "How the connection is protected."),
        ], summary: "A mail server.")
    }
}

extension MailFrame.Provider: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("smtp", .of(MailFrame.Server.self), summary: "Where mail is submitted. Absent means the account cannot send."),
            .init("imap", .of(MailFrame.Server.self), summary: "Where mail is read. Absent means the account cannot be searched."),
        ], summary: "A mail host's servers, shared by its accounts.")
    }
}

extension MailFrame.Secret: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("env", .string, summary: "The environment variable holding it."),
            .init("keychain", .string, summary: "The keychain item's account name under the `mail` service."),
        ], summary: "Where a password is kept; exactly one of env or keychain.")
    }
}

extension MailFrame.Signature: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("text", .string, summary: "Plain-text signature; derived from html when absent."),
            .init("html", .string, summary: "HTML signature; derived from text when absent."),
        ], summary: "Appended to messages sent from an identity.")
    }
}

extension MailFrame.Identity: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("address", .string, required: true, summary: "The From address."),
            .init("name", .string, summary: "The display name."),
            .init("replyTo", .string, summary: "A Reply-To address, when replies should go elsewhere."),
            .init("signature", .of(MailFrame.Signature.self)),
        ], summary: "An address an account sends as. An account's first identity is its default.")
    }
}

extension MailFrame.Folders: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("sent", .string),
            .init("drafts", .string),
            .init("archive", .string),
            .init("trash", .string),
            .init("junk", .string),
        ], summary: "Folder names by role, such as \"INBOX/Sent\". Only needed where the server does not advertise them (SPECIAL-USE).")
    }
}

extension MailFrame.Account: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("provider", .of(MailFrame.Provider.self), required: true),
            .init("username", .any, required: true, summary: "The login name, often the address; or .{ .env = \"VARIABLE\" } to keep it out of the file."),
            .init("password", .of(MailFrame.Secret.self), required: true, summary: "An app password, by reference."),
            .init("identities", .array(.of(MailFrame.Identity.self)), required: true, summary: "Addresses this account sends as; the first is the default."),
            .init("folders", .of(MailFrame.Folders.self)),
            .init("sending", .members(of: MailFrame.Sending.self, summaries: [
                .drafts: "An agent only drafts; a person sends. The default.",
                .confirm: "An agent may send after the owner confirms each message.",
                .allowed: "An agent may send without asking.",
            ]), summary: "What an agent may do with outgoing mail."),
            .init("about", .string, summary: "What this account is for, in your own words."),
        ], summary: "A mailbox account, identified by the binding name. The first declared is the default.")
    }
}
