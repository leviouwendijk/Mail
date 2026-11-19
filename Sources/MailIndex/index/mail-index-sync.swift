import Foundation
import IMAP

public struct MailIndexReport: Sendable, Equatable {
    public var mailboxes = 0
    public var added = 0
    public var removed = 0
    public var flagsChanged = 0
    /// Mailboxes indexed from scratch after a `UIDVALIDITY` change.
    public var rebuilt: [String] = []

    public init() {}
}

public struct MailIndexProgress: Sendable, Equatable {
    public let mailbox: String
    public let done: Int
    public let total: Int
}

extension MailIndex {
    /// Brings the index up to date over an authenticated session: new messages
    /// since each mailbox's last `UIDNEXT`, flag changes and removals. A changed
    /// `UIDVALIDITY` reindexes that mailbox. Read-only toward the server.
    ///
    /// `mailboxes` defaults to `[Gmail]/All Mail` on Gmail (every label lives
    /// there) and to every selectable mailbox elsewhere; `allowing` narrows either.
    public func sync(
        _ session: IMAPSession,
        mailboxes names: [String]? = nil,
        allowing: (@Sendable (String) -> Bool)? = nil,
        refreshFlags: Bool = true,
        batchSize: Int = 500,
        progress: (@Sendable (MailIndexProgress) -> Void)? = nil
    ) async throws -> MailIndexReport {
        let listed = try await session.list().filter { $0.isSelectable && (allowing?($0.name) ?? true) }
        let targets: [IMAPMailbox]
        if let names {
            targets = names.filter { allowing?($0) ?? true }.map { name in
                listed.first { $0.name == name } ?? IMAPMailbox(name: name, delimiter: nil, attributes: [])
            }
        } else if let all = listed.first(where: { $0.specialUse == .all }) {
            targets = [all]
        } else {
            targets = listed
        }

        var report = MailIndexReport()
        for mailbox in targets {
            try await sync(mailbox, session: session, refreshFlags: refreshFlags, batchSize: batchSize, report: &report, progress: progress)
        }
        // A narrowed run cannot tell a missing mailbox from a hidden one.
        if names == nil && allowing == nil {
            let present = Set(listed.map(\.name))
            for state in try self.mailboxes() where !present.contains(state.name) {
                try drop(mailbox: state.name)
            }
        }
        try rebuildCorrespondents()
        return report
    }

    private func sync(
        _ mailbox: IMAPMailbox,
        session: IMAPSession,
        refreshFlags: Bool,
        batchSize: Int,
        report: inout MailIndexReport,
        progress: (@Sendable (MailIndexProgress) -> Void)?
    ) async throws {
        let selection = try await session.select(mailbox.name)
        let uidValidity = selection.uidValidity ?? 0
        let role = mailbox.specialUse?.rawValue ?? (mailbox.isInbox ? "inbox" : nil)
        report.mailboxes += 1

        var state = try self.mailbox(mailbox.name)
        if state == nil || state?.uidValidity != uidValidity {
            if state != nil {
                report.rebuilt.append(mailbox.name)
            }
            try reset(mailbox: mailbox.name, role: role, uidValidity: uidValidity)
            state = try self.mailbox(mailbox.name)
        }
        let start = state?.uidNext ?? 1
        let fresh = start <= 1

        // Known messages: drop what the server no longer has, refresh flags.
        if !fresh {
            let known = try uids(in: mailbox.name)
            let present = Set(try await session.search(.all))
            let gone = known.filter { !present.contains($0) }
            if !gone.isEmpty {
                try remove(gone, from: mailbox.name)
                report.removed += gone.count
            }
            if refreshFlags {
                let kept = known.filter { present.contains($0) }
                report.flagsChanged += try update(flags: try await session.flags(kept), in: mailbox.name)
            }
        }

        // New messages. `start:*` always includes the newest, so filter.
        let added = try await session.search(fresh ? .all : .uidsFrom(IMAPUID(UInt32(start))))
            .filter { $0.rawValue >= UInt32(start) }
        let sent = mailbox.specialUse == .sent
        var done = 0
        var offset = 0
        while offset < added.count {
            let batch = Array(added[offset..<min(offset + max(1, batchSize), added.count)])
            let summaries = try await session.summaries(batch, headers: IndexedMessage.headerFields, structure: true)
            try insert(summaries.map { IndexedMessage($0, mailbox: mailbox.name, sentMailbox: sent) })
            done += batch.count
            offset += batch.count
            progress?(MailIndexProgress(mailbox: mailbox.name, done: done, total: added.count))
        }
        report.added += added.count

        let next = selection.uidNext ?? Int((added.last?.rawValue ?? UInt32(start - 1)) + 1)
        try finish(mailbox: mailbox.name, uidNext: max(next, start))
    }
}
