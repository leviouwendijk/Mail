import Arguments
import Foundation
import IMAP
import Mail
import MailFrame

enum ProbeCommand: BoundArgumentCommand {
    typealias Options = ProbeOptions

    static let name = "probe"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Connect and log in to each server of an account (all accounts with --all); sends nothing."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ProbeOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let selected = options.all
            ? access.visibleAccounts(in: accounts)
            : [try EmailCLI.account(options.account, in: accounts, access: access)]
        var failed = false
        for account in selected {
            if let client = accounts.imapClient(for: account) {
                do {
                    let count = try await client.session { try await $0.list().count }
                    print("\(account.identifier) imap  ok, \(count) mailboxes")
                } catch {
                    failed = true
                    print("\(account.identifier) imap  FAILED: \(EmailCLI.describe(error))")
                }
            }
            if let client = accounts.smtpClient(for: account) {
                do {
                    try await client.verify()
                    print("\(account.identifier) smtp  ok, login accepted")
                } catch {
                    failed = true
                    print("\(account.identifier) smtp  FAILED: \(EmailCLI.describe(error))")
                }
            }
        }
        if failed {
            throw EmailCLIError.missing("Some servers failed.")
        }
    }
}

struct ProbeOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Flag("all", help: "Probe every account.")
    var all: Bool

    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

enum MailboxesCommand: BoundArgumentCommand {
    typealias Options = MailboxesOptions

    static let name = "mailboxes"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("List an account's mailboxes with their roles; --counts adds total and unread."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: MailboxesOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        let lines = try await EmailCLI.imap(account, in: accounts).session { session in
            var lines: [String] = []
            for mailbox in try await session.list() where access.allows(mailbox: mailbox.name) {
                var line = mailbox.name
                if let role = mailbox.specialUse {
                    line += "  [\(role.rawValue)]"
                }
                if options.counts, mailbox.isSelectable, let status = try? await session.status(mailbox.name) {
                    line += "  \(status.unseen ?? 0) unread / \(status.messages ?? 0)"
                }
                lines.append(line)
            }
            return lines
        }
        lines.forEach { print($0) }
    }
}

struct MailboxesOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Flag("counts", short: "c", help: "Also show total and unread counts.")
    var counts: Bool

    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

enum SearchCommand: BoundArgumentCommand {
    typealias Options = SearchOptions

    static let name = "search"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Search a mailbox on the server; newest first. Never marks messages read."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: SearchOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let query = try options.query()
        if query.usesGmailExtensions {
            try access.checkCrossLabelSearch()
        }
        if !options.targets.isEmpty {
            try await searchAcross(options, query: query, accounts: accounts, access: access)
            return
        }
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        try access.check(mailbox: options.mailbox)

        let (total, summaries) = try await EmailCLI.imap(account, in: accounts).session { session in
            try await session.select(options.mailbox)
            let uids = try await session.search(query)
            return (uids.count, try await session.summaries(Array(uids.suffix(max(options.limit, 1)))))
        }

        for summary in summaries.reversed() {
            let marker = summary.isUnread ? "●" : " "
            let from = summary.envelope?.from.first.map(EmailCLI.display) ?? ""
            let date = EmailCLI.shortDate(summary.envelope?.date ?? summary.internalDate)
            print("\(marker) \(String(summary.uid.rawValue).padding(toLength: 7, withPad: " ", startingAt: 0)) \(date)  \(from)\n            \(summary.envelope?.subject ?? "(no subject)")")
            if let gmail = summary.gmail {
                let labels = gmail.labels.isEmpty ? "" : "  labels: \(gmail.labels.joined(separator: ", "))"
                print("            thread \(gmail.threadID ?? "?")\(labels)")
            }
        }
        FileHandle.standardError.write(Data("\(summaries.count) of \(total) in \(options.mailbox)\n".utf8))
    }

    /// `--in` selectors: every mailbox they pick, across accounts, newest first.
    static func searchAcross(
        _ options: SearchOptions,
        query: IMAPSearch,
        accounts: MailAccounts,
        access: MailAccess
    ) async throws {
        let selectors = try options.targets.map(MailSelector.init(parsing:))
        let result = try await accounts.search(query, in: selectors, limit: max(options.limit, 1)) { account, mailbox, _ in
            try access.check(account: account.identifier)
            try access.check(mailbox: mailbox)
        }
        for hit in result.hits {
            let marker = hit.summary.isUnread ? "●" : " "
            let from = hit.summary.envelope?.from.first.map(EmailCLI.display) ?? ""
            print("\(marker) \(hit.account):\(hit.mailbox) \(hit.summary.uid.rawValue)  \(EmailCLI.shortDate(hit.date))  \(from)\n            \(hit.summary.envelope?.subject ?? "(no subject)")")
        }
        FileHandle.standardError.write(Data("\(result.hits.count) of \(result.total) in \(result.searched.joined(separator: ", "))\n".utf8))
    }
}

struct SearchOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opts("in", help: "Selector, repeatable: account, group or *, with :mailbox, :prefix/* or :@role (hondenmeesters:@junk). Replaces --account and --mailbox.")
    var targets: [String]

    @Opt("mailbox", short: "m", default: "INBOX", help: "Mailbox, such as INBOX/Clients.")
    var mailbox: String

    @Flag("unread", short: "u", help: "Only unread messages.")
    var unread: Bool

    @Flag("flagged", help: "Only flagged messages.")
    var flagged: Bool

    @Opt("from", short: "f", help: "Sender contains.")
    var from: String?

    @Opt("to", help: "Recipient contains.")
    var to: String?

    @Opt("subject", short: "s", help: "Subject contains.")
    var subject: String?

    @Opt("text", short: "t", help: "Headers or body contain.")
    var text: String?

    @Opt("since", help: "Received on or after, yyyy-MM-dd.")
    var since: String?

    @Opt("before", help: "Received before, yyyy-MM-dd.")
    var before: String?

    @Opt("gmail", short: "g", help: "Gmail search syntax, such as 'has:attachment older_than:7d' (Gmail only).")
    var gmail: String?

    @Opt("thread", help: "Every message of a Gmail conversation, by thread ID (Gmail only).")
    var thread: String?

    @Opt("limit", short: "n", default: 20, help: "Most recent matches to show.")
    var limit: Int

    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}

    func query() throws -> IMAPSearch {
        var criteria: [IMAPSearch] = []
        if unread { criteria.append(.unseen) }
        if flagged { criteria.append(.flagged) }
        if let from { criteria.append(.from(from)) }
        if let to { criteria.append(.to(to)) }
        if let subject { criteria.append(.subject(subject)) }
        if let text { criteria.append(.text(text)) }
        if let since { criteria.append(.since(try EmailCLI.day(since))) }
        if let before { criteria.append(.before(try EmailCLI.day(before))) }
        if let gmail { criteria.append(.gmail(gmail)) }
        if let thread { criteria.append(.gmailThread(thread)) }
        return .and(criteria)
    }
}

enum ReadCommand: BoundArgumentCommand {
    typealias Options = ReadOptions

    static let name = "read"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Print one message by UID (from email search). Does not mark it read."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ReadOptions,
        invocation: ParsedInvocation
    ) async throws {
        guard options.uid > 0 else {
            throw EmailCLIError.missing("Give the message's UID: email read <uid>.")
        }
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        try access.check(mailbox: options.mailbox)
        let message = try await EmailCLI.imap(account, in: accounts).session { session in
            try await session.select(options.mailbox)
            return try await session.message(IMAPUID(UInt32(clamping: options.uid)))
        }
        guard let message else {
            throw EmailCLIError.notFound(uid: options.uid, mailbox: options.mailbox)
        }

        print("From:    \(message.from.map(EmailCLI.display).joined(separator: ", "))")
        print("To:      \(message.to.map(EmailCLI.display).joined(separator: ", "))")
        if !message.cc.isEmpty {
            print("Cc:      \(message.cc.map(EmailCLI.display).joined(separator: ", "))")
        }
        print("Date:    \(EmailCLI.shortDate(message.date))")
        print("Subject: \(message.subject ?? "")")
        for attachment in message.attachments {
            print("Attach:  \(attachment.filename) (\(attachment.contentType), \(attachment.data.count) bytes)")
        }
        print("")
        print(message.readableText ?? "")
    }
}

struct ReadOptions: Sendable, ArgumentGroup {
    @Arg("uid", help: "The message's UID.", default: 0)
    var uid: Int

    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opt("mailbox", short: "m", default: "INBOX", help: "Mailbox holding the message.")
    var mailbox: String

    @Opt("config", help: "Configuration directory; ~/.config/mail when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}
