import Arguments
import Foundation
import IMAP
import Mail
import MailFrame
import MailIndex

enum IndexCommand: BoundArgumentCommand {
    typealias Options = IndexOptions

    static let name = "index"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Sync an account into its local index (~/.local/share/mail/index): envelopes, flags, list headers and attachments, never bodies. Read-only toward the server."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: IndexOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        for mailbox in options.mailboxes {
            try access.check(mailbox: mailbox)
        }
        let index = try MailIndex(url: EmailCLI.indexURL(options.index, account: account))
        var allowing: (@Sendable (String) -> Bool)?
        if access != .unrestricted {
            allowing = { @Sendable mailbox in access.allows(mailbox: mailbox) }
        }

        let started = Date()
        let report = try await EmailCLI.imap(account, in: accounts).session { session in
            try await index.sync(
                session,
                mailboxes: options.mailboxes.isEmpty ? nil : options.mailboxes,
                allowing: allowing,
                refreshFlags: !options.skipFlags
            ) { progress in
                FileHandle.standardError.write(Data("\r\(progress.mailbox): \(progress.done)/\(progress.total)\u{1B}[K".utf8))
            }
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))

        let totals = try await index.totals()
        print("\(account.identifier): \(report.mailboxes) mailboxes, +\(report.added) new, -\(report.removed) gone, \(report.flagsChanged) flag changes in \(Int(Date().timeIntervalSince(started)))s")
        if !report.rebuilt.isEmpty {
            print("reindexed (UIDVALIDITY changed): \(report.rebuilt.joined(separator: ", "))")
        }
        print("index: \(totals.messages) received messages, \(EmailCLI.bytes(totals.bytes)), \(totals.unread) unread, \(totals.senders) senders, \(totals.correspondents) correspondents")
    }
}

struct IndexOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opts("mailbox", short: "m", help: "Only this mailbox (repeatable); All Mail on Gmail, else every mailbox, when absent.")
    var mailboxes: [String]

    @Flag("skip-flags", help: "Only fetch new messages; skip the flag refresh and removal check.")
    var skipFlags: Bool

    @Opt("index", help: "Index file; ~/.local/share/mail/index/<account>.sqlite when absent.")
    var index: String?

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

enum ClutterCommand: BoundArgumentCommand {
    typealias Options = ClutterOptions

    static let name = "clutter"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Biggest senders, domains or mailing lists in an account's index (run `email index` first). ✉ marks someone you have written to; ↯ an unsubscribe header."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: ClutterOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        guard let grouping = MailIndexGrouping(rawValue: options.by) else {
            throw EmailCLIError.missing("--by is one of \(MailIndexGrouping.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        guard let order = MailIndexOrder(rawValue: options.order) else {
            throw EmailCLIError.missing("--order is one of \(MailIndexOrder.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        if let mailbox = options.mailbox {
            try access.check(mailbox: mailbox)
        }
        let url = EmailCLI.indexURL(options.index, account: account)
        guard MailIndex.exists(at: url) else {
            throw EmailCLIError.missing("No index for \(account.identifier) yet; run `email index -a \(account.identifier)`.")
        }
        let index = try MailIndex(url: url)
        var filter = MailIndexFilter(mailbox: options.mailbox)
        if options.strangers {
            filter.fromCorrespondent = false
        }
        if let days = options.olderThan {
            filter.receivedBefore = Date().addingTimeInterval(-Double(days) * 86_400)
        }

        let totals = try await index.totals(filter)
        let rows = try await index.clutter(by: grouping, filter: filter, order: order, limit: options.limit)
        print("\(totals.messages) messages, \(EmailCLI.bytes(totals.bytes)), \(totals.unread) unread, \(totals.senders) senders")
        print("")
        print("count".leftPadded(7) + "  " + "size".leftPadded(8) + "  read  answ  last        " + options.by)
        for row in rows {
            let marks = (row.correspondent ? "✉" : " ") + (row.unsubscribable > 0 ? "↯" : " ")
            let name = row.name.map { "  (\($0))" } ?? ""
            print(
                String(row.count).leftPadded(7) + "  "
                    + EmailCLI.bytes(row.bytes).leftPadded(8) + "  "
                    + "\(Int(row.readRatio * 100))%".leftPadded(4) + "  "
                    + String(row.answered).leftPadded(4) + "  "
                    + EmailCLI.dayText(row.last) + "  "
                    + marks + " " + row.key + (grouping == .list ? "" : name)
            )
        }
    }
}

struct ClutterOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opt("by", short: "b", default: "sender", help: "Group by sender, domain or list.")
    var by: String

    @Opt("order", short: "o", default: "count", help: "Order by count, bytes or unread.")
    var order: String

    @Opt("limit", short: "n", default: 30, help: "Rows to show.")
    var limit: Int

    @Opt("mailbox", short: "m", help: "Only this mailbox.")
    var mailbox: String?

    @Opt("older-than", help: "Only messages received more than this many days ago.")
    var olderThan: Int?

    @Flag("strangers", help: "Only senders you have never written to.")
    var strangers: Bool

    @Opt("index", help: "Index file; ~/.local/share/mail/index/<account>.sqlite when absent.")
    var index: String?

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

extension EmailCLI {
    static func indexURL(
        _ path: String?,
        account: MailAccounts.Account
    ) -> URL {
        path.map { URL(fileURLWithPath: expandingTilde($0)) } ?? MailIndex.defaultURL(account: account.identifier)
    }

    static func dayText(
        _ date: Date?
    ) -> String {
        guard let date else {
            return "          "
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func bytes(
        _ count: Int
    ) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

private extension String {
    func leftPadded(
        _ width: Int
    ) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
