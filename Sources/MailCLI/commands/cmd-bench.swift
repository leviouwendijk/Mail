import Arguments
import Foundation
import IMAP
import Mail
import MailFrame
import MailIndex

enum BenchCommand: BoundArgumentCommand {
    typealias Options = BenchOptions

    static let name = "bench"

    static func components() throws -> [CommandComponentLowerable] {
        [
            about("Time an account's IMAP server: connect and login, round trips, listing, searching and fetching in batches, read-only. --write also times APPEND, MOVE and removal of one test message it creates itself, in a Bench folder; nothing else is touched."),
            try params(Options.self),
        ]
    }

    static func run(
        _ options: BenchOptions,
        invocation: ParsedInvocation
    ) async throws {
        let (accounts, access) = try EmailCLI.scope(directory: options.directory, access: options.access)
        let account = try EmailCLI.account(options.account, in: accounts, access: access)
        try access.check(mailbox: options.mailbox)
        if options.write {
            try access.checkDrafting()
        }
        let client = try EmailCLI.imap(account, in: accounts)
        let clock = ContinuousClock()

        var rows: [(String, Duration, String)] = []
        func row(_ label: String, _ duration: Duration, _ note: String = "") {
            rows.append((label, duration, note))
            FileHandle.standardError.write(Data("\r\(label)…\u{1B}[K".utf8))
        }

        let started = clock.now
        try await client.session { session in
            row("connect + TLS + login", clock.now - started, account.imap.map { "\($0.server.host):\($0.server.port)" } ?? "")

            var trips: [Duration] = []
            for _ in 0..<5 {
                let start = clock.now
                try await session.noop()
                trips.append(clock.now - start)
            }
            row("round trip (NOOP, median of 5)", trips.sorted()[2], "min \(Self.ms(trips.min()!)), max \(Self.ms(trips.max()!))")

            var start = clock.now
            let mailboxes = try await session.list()
            row("LIST", clock.now - start, "\(mailboxes.count) mailboxes")

            start = clock.now
            let selection = try await session.select(options.mailbox)
            row("EXAMINE \(options.mailbox)", clock.now - start, "\(selection.exists) messages")

            start = clock.now
            let uids = try await session.search(.all)
            row("UID SEARCH ALL", clock.now - start, "\(uids.count) UIDs")

            start = clock.now
            let flags = try await session.flags(uids)
            row("FETCH flags, all", clock.now - start, "\(flags.count) messages, \(Self.per(clock.now - start, flags.count))")

            let newest = Array(uids.suffix(options.batch))
            start = clock.now
            _ = try await session.summaries(newest)
            row("FETCH envelopes ×\(newest.count)", clock.now - start, Self.per(clock.now - start, newest.count))

            start = clock.now
            _ = try await session.summaries(newest, headers: IndexedMessage.headerFields, structure: true)
            row("FETCH index fields ×\(newest.count)", clock.now - start, "as email index does; \(Self.per(clock.now - start, newest.count))")

            if let last = uids.last {
                start = clock.now
                let raw = try await session.raw(last) ?? Data()
                let elapsed = clock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                row("FETCH one full message", elapsed, "\(raw.count / 1024) KB, \(seconds > 0 ? Int(Double(raw.count) / 1024 / seconds) : 0) KB/s")
            }

            if options.write {
                try await Self.writes(session: session, account: account, clock: clock, row: row)
            }
        }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))

        print("\(account.identifier)")
        for (label, duration, note) in rows {
            print("  " + label.padding(toLength: 34, withPad: " ", startingAt: 0) + Self.ms(duration).leftPadded(9) + (note.isEmpty ? "" : "   \(note)"))
        }
    }

    /// One message of its own: appended, moved, then marked deleted and
    /// expunged by UID alone. Its folders stay, empty.
    static func writes(
        session: IMAPSession,
        account: MailAccounts.Account,
        clock: ContinuousClock,
        row: (String, Duration, String) -> Void
    ) async throws {
        guard await session.hasCapability("UIDPLUS") else {
            row("writes", .zero, "skipped: the server lacks UIDPLUS, so the test message could not be removed alone")
            return
        }
        let first = try await session.resolve(mailbox: "Bench/In")
        let second = try await session.resolve(mailbox: "Bench/Out")
        try await session.create(first)
        try await session.create(second)

        let address = account.defaultIdentity.address.address.raw
        let message = Data("""
            From: <\(address)>\r
            To: <\(address)>\r
            Subject: email bench \(UUID().uuidString)\r
            Date: \(Date().formatted(.iso8601))\r
            Message-ID: <bench-\(UUID().uuidString)@email.bench>\r
            \r
            Test message written by `email bench --write`; it removes itself.\r

            """.utf8)

        var start = clock.now
        guard let appended = try await session.append(message, to: first, flags: [.seen]) else {
            row("APPEND", clock.now - start, "no APPENDUID; stopped before moving anything")
            return
        }
        row("APPEND (\(message.count) bytes)", clock.now - start, "UID \(appended) in \(first)")

        try await session.select(first, readOnly: false)
        start = clock.now
        let mapping = try await session.move([appended], to: second)
        row("MOVE one message", clock.now - start, (await session.hasCapability("MOVE") ? "MOVE" : "COPY + UID EXPUNGE") + " → \(second)")

        guard let moved = mapping?.uids[appended] else {
            row("remove", .zero, "no COPYUID; the test message stays in \(second)")
            return
        }
        try await session.select(second, readOnly: false)
        start = clock.now
        try await session.store([.deleted], .add, on: [moved])
        try await session.expunge([moved])
        row("remove (flag + UID EXPUNGE)", clock.now - start, "UID \(moved) only")
    }

    static func ms(
        _ duration: Duration
    ) -> String {
        let millis = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return millis < 10 ? String(format: "%.1f ms", millis) : "\(Int(millis.rounded())) ms"
    }

    static func per(
        _ duration: Duration,
        _ count: Int
    ) -> String {
        guard count > 0 else {
            return ""
        }
        return "\(ms(duration / count)) per message"
    }
}

struct BenchOptions: Sendable, ArgumentGroup {
    @Opt("account", short: "a", help: "Account name; the default account when absent.")
    var account: String?

    @Opt("mailbox", short: "m", default: "INBOX", help: "Mailbox to time listing and fetching in.")
    var mailbox: String

    @Opt("batch", default: 200, help: "Newest messages fetched per batch.")
    var batch: Int

    @Flag("write", help: "Also time APPEND, MOVE and removal of one test message of its own, in a Bench folder.")
    var write: Bool

    @Opt("config", help: "One configuration directory alone; every root's .config/mail (your own, then shared roots in ~/.config/roots.frame) when absent.")
    var directory: String?

    @Opt("access", help: "Limit to a named access profile from the configuration.")
    var access: String?

    init() {}
}

private extension String {
    func leftPadded(
        _ width: Int
    ) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
