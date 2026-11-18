import Foundation
import IMAP

/// A mailbox's role: `INBOX`, or a SPECIAL-USE role such as Sent or Junk.
public enum MailboxRole: Sendable, Hashable, CustomStringConvertible {
    case inbox
    case special(IMAPSpecialUse)

    /// `inbox`, `sent`, `drafts`, `junk`, `trash`, `archive`, `all` or `flagged`.
    public init?(
        name: String
    ) {
        let name = name.lowercased()
        if name == "inbox" {
            self = .inbox
        } else if let use = IMAPSpecialUse(rawValue: name) {
            self = .special(use)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .inbox: return "inbox"
        case .special(let use): return use.rawValue
        }
    }

    /// The role of `mailbox` on `account`: INBOX by name, the file's folder
    /// overrides, then the server's SPECIAL-USE attributes from `listed`.
    public static func of(
        _ mailbox: String,
        account: MailAccounts.Account,
        listed: [IMAPMailbox]
    ) -> MailboxRole? {
        if mailbox.caseInsensitiveCompare("INBOX") == .orderedSame {
            return .inbox
        }
        if let role = account.folders.first(where: { $0.value == mailbox })?.key {
            return .special(role)
        }
        return listed.first { $0.name == mailbox }?.specialUse.map(MailboxRole.special)
    }
}

/// What a selector such as `hondenmeesters:@junk` or `levi:INBOX/Klanten/*` picks:
/// accounts by name, group or `*`, and optionally mailboxes by name, pattern or role.
public struct MailSelector: Sendable, Hashable, CustomStringConvertible {
    public enum Target: Sendable, Hashable {
        case all
        /// An account's name, or a group's.
        case name(String)
    }

    public enum Mailboxes: Sendable, Hashable {
        /// No mailbox given: every mailbox for access; INBOX when searching.
        case unspecified
        /// A name or `prefix/*` pattern; Gmail labels are mailboxes too.
        case pattern(String)
        case role(MailboxRole)
    }

    public enum Failure: Error, Sendable, Equatable, LocalizedError {
        case empty
        case unknownRole(String)
        case unknownTarget(String, accounts: [String], groups: [String])

        public var errorDescription: String? {
            switch self {
            case .empty:
                return "An empty selector; use an account, a group or *, optionally followed by :mailbox or :@role."
            case .unknownRole(let role):
                return "Unknown mailbox role '@\(role)'; use @inbox, @sent, @drafts, @junk, @trash, @archive, @all or @flagged."
            case .unknownTarget(let name, let accounts, let groups):
                return "'\(name)' is neither an account (\(accounts.joined(separator: ", "))) nor a group (\(groups.isEmpty ? "none" : groups.joined(separator: ", ")))."
            }
        }
    }

    public let target: Target
    public let mailboxes: Mailboxes

    public init(
        target: Target,
        mailboxes: Mailboxes = .unspecified
    ) {
        self.target = target
        self.mailboxes = mailboxes
    }

    /// `account`, `group`, `*`, each optionally followed by `:mailbox`, `:prefix/*` or `:@role`.
    public init(
        parsing text: String
    ) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw Failure.empty
        }
        let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
        let head = parts[0].trimmingCharacters(in: .whitespaces)
        guard !head.isEmpty else {
            throw Failure.empty
        }
        self.target = head == "*" ? .all : .name(head)

        let mailbox = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        if mailbox.isEmpty {
            self.mailboxes = .unspecified
        } else if mailbox.hasPrefix("@") {
            guard let role = MailboxRole(name: String(mailbox.dropFirst())) else {
                throw Failure.unknownRole(String(mailbox.dropFirst()))
            }
            self.mailboxes = .role(role)
        } else {
            self.mailboxes = .pattern(mailbox)
        }
    }

    public var description: String {
        let head: String
        switch target {
        case .all: head = "*"
        case .name(let name): head = name
        }
        switch mailboxes {
        case .unspecified: return head
        case .pattern(let pattern): return "\(head):\(pattern)"
        case .role(let role): return "\(head):@\(role)"
        }
    }

    public func matches(
        account: MailAccounts.Account
    ) -> Bool {
        switch target {
        case .all:
            return true
        case .name(let name):
            return account.identifier == name || account.group == name
        }
    }

    /// Whether `mailbox` (with its role, when known) is picked. `unspecified` picks every mailbox.
    public func matches(
        mailbox: String,
        role: MailboxRole?
    ) -> Bool {
        switch mailboxes {
        case .unspecified:
            return true
        case .pattern(let pattern):
            return MailAccess.matches(pattern: pattern, mailbox: mailbox)
        case .role(let wanted):
            return role == wanted
        }
    }

    /// The accounts picked, in configuration order; an unknown name fails.
    public func accounts(
        in accounts: MailAccounts
    ) throws -> [MailAccounts.Account] {
        let picked = accounts.accounts.filter(matches(account:))
        if case .name(let name) = target, picked.isEmpty {
            throw Failure.unknownTarget(name, accounts: accounts.accounts.map(\.identifier), groups: accounts.groups)
        }
        return picked
    }

    /// The selectable mailboxes picked on one account, given its listing.
    /// Without a mailbox part this is INBOX, as for a search.
    public func mailboxes(
        of account: MailAccounts.Account,
        listed: [IMAPMailbox]
    ) -> [(name: String, role: MailboxRole?)] {
        if case .unspecified = mailboxes {
            return [("INBOX", .inbox)]
        }
        return listed
            .filter(\.isSelectable)
            .map { ($0.name, MailboxRole.of($0.name, account: account, listed: listed)) }
            .filter { matches(mailbox: $0.0, role: $0.1) }
    }
}
