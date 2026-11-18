import Foundation
import Frame
import Mail

public extension MailFrame {
    /// An account named by its binding (`work`) or as a string (`"work"`), so
    /// a profile may name accounts declared in another file.
    enum AccountReference: Sendable, Hashable, Decodable {
        case name(String)
        case account(Account)

        public init(
            from decoder: any Decoder
        ) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(name)
            } else {
                self = .account(try Account(from: decoder))
            }
        }
    }

    /// A named access profile: what a session using it may reach.
    struct Access: Sendable, Hashable, Decodable {
        /// Accounts it may use; all when absent. The first is its default.
        public let accounts: [AccountReference]?
        /// Mailboxes it may read, such as `"INBOX"` or `"INBOX/Klanten/*"`; all when absent.
        public let mailboxes: [String]?
        /// Addresses it may send or draft as; every identity of its accounts when absent.
        public let identities: [String]?
        /// False: never send, only draft. Never loosens an account's sending policy.
        public let send: Bool?
        /// False: read only, no drafts either.
        public let draft: Bool?
        public let about: String?
    }
}

extension MailFrame.Access: FrameDescribable {
    public static var frameSchema: Frame.Schema {
        .object([
            .init("accounts", .array(.any), summary: "Accounts it may use, by binding or name; all when absent. The first is its default."),
            .init("mailboxes", .array(.string), summary: "Mailboxes it may read; a trailing * matches everything below, as in \"INBOX/Klanten/*\". All when absent. Restricting mailboxes also refuses Gmail search syntax and thread search, which reach across labels."),
            .init("identities", .array(.string), summary: "Addresses it may draft or send as; every identity of its accounts when absent."),
            .init("send", .boolean, summary: "False: drafts only, whatever the account allows. Never loosens an account's sending policy."),
            .init("draft", .boolean, summary: "False: read only, no drafts or sending."),
            .init("about", .string, summary: "What the profile is for."),
        ], summary: "A named access profile that a session or command line can be limited to.")
    }
}

/// What a session may reach, resolved from a profile: account names, mailbox
/// patterns and identities, plus what it may write. `unrestricted` allows all.
public struct MailAccess: Sendable, Equatable {
    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case account(String, profile: String)
        case mailbox(String, profile: String)
        case identity(String, profile: String)
        case drafting(profile: String)
        case sending(profile: String)
        case crossLabelSearch(profile: String)
        case unknownProfile(String, known: [String])

        public var errorDescription: String? {
            switch self {
            case .account(let name, let profile):
                return "Account '\(name)' is not accessible under access profile '\(profile)'."
            case .mailbox(let name, let profile):
                return "Mailbox '\(name)' is not accessible under access profile '\(profile)'."
            case .identity(let address, let profile):
                return "Sending as \(address) is not allowed under access profile '\(profile)'."
            case .drafting(let profile):
                return "Access profile '\(profile)' is read-only: no drafts or sending."
            case .sending(let profile):
                return "Access profile '\(profile)' allows drafts only, not sending."
            case .crossLabelSearch(let profile):
                return "Access profile '\(profile)' limits mailboxes, so Gmail search syntax and thread search, which reach across labels, are refused."
            case .unknownProfile(let name, let known):
                return "No access profile '\(name)'; known: \(known.isEmpty ? "none" : known.joined(separator: ", "))."
            }
        }
    }

    public let name: String
    /// Account names in order; nil allows every account.
    public let accounts: [String]?
    /// Mailbox patterns; nil allows every mailbox.
    public let mailboxes: [String]?
    /// Lowercased addresses; nil allows every identity.
    public let identities: Set<String>?
    public let mayDraft: Bool
    public let maySend: Bool

    public static let unrestricted = MailAccess(
        name: "unrestricted",
        accounts: nil,
        mailboxes: nil,
        identities: nil,
        mayDraft: true,
        maySend: true
    )

    public init(
        name: String,
        accounts: [String]?,
        mailboxes: [String]?,
        identities: Set<String>?,
        mayDraft: Bool,
        maySend: Bool
    ) {
        self.name = name
        self.accounts = accounts
        self.mailboxes = mailboxes
        self.identities = identities.map { Set($0.map { $0.lowercased() }) }
        self.mayDraft = mayDraft
        self.maySend = mayDraft && maySend
    }

    public var restrictsMailboxes: Bool {
        mailboxes != nil
    }

    // MARK: - Questions

    public func allows(
        account name: String
    ) -> Bool {
        accounts?.contains(name) ?? true
    }

    /// `INBOX` matches case-insensitively; `prefix/*` matches the prefix and everything below it.
    public func allows(
        mailbox name: String
    ) -> Bool {
        guard let mailboxes else {
            return true
        }
        return mailboxes.contains { Self.matches(pattern: $0, mailbox: name) }
    }

    /// `INBOX` matches case-insensitively; `prefix/*` matches the prefix and everything below it.
    public static func matches(
        pattern: String,
        mailbox: String
    ) -> Bool {
        let candidate = normalized(mailbox)
        let pattern = normalized(pattern)
        if pattern == "*" {
            return true
        }
        if pattern.hasSuffix("*") {
            let prefix = String(pattern.dropLast())
            let parent = prefix.hasSuffix("/") || prefix.hasSuffix(".") ? String(prefix.dropLast()) : prefix
            return candidate.hasPrefix(prefix) || candidate == parent
        }
        return candidate == pattern
    }

    public func allows(
        identity address: String
    ) -> Bool {
        identities?.contains(address.lowercased()) ?? true
    }

    /// The account's policy, tightened by this profile; never loosened.
    public func sending(
        for account: MailAccounts.Account
    ) -> MailFrame.Sending {
        maySend ? account.sending : .drafts
    }

    /// The accounts this profile can see, in its order (or the configuration's).
    public func visibleAccounts(
        in accounts: MailAccounts
    ) -> [MailAccounts.Account] {
        guard let names = self.accounts else {
            return accounts.accounts
        }
        return names.compactMap { accounts.account(named: $0) }
    }

    /// The identities of `account` this profile may use, in the account's order.
    public func identities(
        of account: MailAccounts.Account
    ) -> [MailIdentity] {
        account.identities.filter { allows(identity: $0.address.address.raw) }
    }

    // MARK: - Checks that throw

    public func check(
        account name: String
    ) throws {
        guard allows(account: name) else {
            throw Failure.account(name, profile: self.name)
        }
    }

    public func check(
        mailbox name: String
    ) throws {
        guard allows(mailbox: name) else {
            throw Failure.mailbox(name, profile: self.name)
        }
    }

    public func check(
        identity address: String
    ) throws {
        guard allows(identity: address) else {
            throw Failure.identity(address, profile: name)
        }
    }

    public func checkDrafting() throws {
        guard mayDraft else {
            throw Failure.drafting(profile: name)
        }
    }

    public func checkSending() throws {
        try checkDrafting()
        guard maySend else {
            throw Failure.sending(profile: name)
        }
    }

    /// Gmail search syntax and thread search reach across labels, so a mailbox limit refuses them.
    public func checkCrossLabelSearch() throws {
        guard !restrictsMailboxes else {
            throw Failure.crossLabelSearch(profile: name)
        }
    }

    /// `INBOX` is case-insensitive (RFC 3501 §5.1), including as a parent.
    private static func normalized(
        _ mailbox: String
    ) -> String {
        let head = mailbox.prefix(5)
        guard head.uppercased() == "INBOX" else {
            return mailbox
        }
        let rest = mailbox.dropFirst(5)
        guard rest.isEmpty || rest.first == "/" || rest.first == "." else {
            return mailbox
        }
        return "INBOX" + rest
    }
}
