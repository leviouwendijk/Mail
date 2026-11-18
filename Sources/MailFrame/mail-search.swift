import Foundation
import IMAP
import MailConnection

/// One message found by a search across selectors.
public struct MailSearchHit: Sendable {
    public let account: String
    public let mailbox: String
    public let summary: IMAPMessageSummary

    public var date: Date? {
        summary.envelope?.date ?? summary.internalDate
    }
}

public struct MailSearchResult: Sendable {
    /// Matches across every mailbox searched.
    public let total: Int
    /// The newest `limit` matches, newest first.
    public let hits: [MailSearchHit]
    /// `account:mailbox` for each mailbox searched.
    public let searched: [String]
    /// Accounts the selectors picked that cannot be read, with the reason.
    public let skipped: [String: String]
}

public extension MailAccounts {
    /// Searches every mailbox the selectors pick, one connection per account.
    /// `permit` sees each account and mailbox before it is opened and throws to refuse;
    /// a refusal stops the whole search, so nothing is read past a boundary.
    func search(
        _ query: IMAPSearch,
        in selectors: [MailSelector],
        limit: Int = 20,
        maximumMailboxes: Int = 40,
        connector: @escaping MailConnector = MailServerConfiguration.networkConnector,
        permit: @Sendable (MailAccounts.Account, String, MailboxRole?) throws -> Void
    ) async throws -> MailSearchResult {
        // Accounts in configuration order, each with the selectors that pick it.
        var plan: [(account: MailAccounts.Account, selectors: [MailSelector])] = []
        for selector in selectors {
            for account in try selector.accounts(in: self) {
                if let index = plan.firstIndex(where: { $0.account.identifier == account.identifier }) {
                    plan[index].selectors.append(selector)
                } else {
                    plan.append((account, [selector]))
                }
            }
        }

        var total = 0
        var hits: [MailSearchHit] = []
        var searched: [String] = []
        var skipped: [String: String] = [:]
        for (account, selectors) in plan {
            guard let client = imapClient(for: account, connector: connector) else {
                skipped[account.identifier] = account.unavailable[.imap] ?? "no IMAP server"
                continue
            }
            let found = try await client.session { session -> (Int, [MailSearchHit], [String]) in
                let needsListing = selectors.contains { if case .unspecified = $0.mailboxes { return false } else { return true } }
                let listed = needsListing ? try await session.list() : []
                var mailboxes: [(name: String, role: MailboxRole?)] = []
                for selector in selectors {
                    for mailbox in selector.mailboxes(of: account, listed: listed)
                    where !mailboxes.contains(where: { $0.name == mailbox.name }) {
                        mailboxes.append(mailbox)
                    }
                }
                guard searched.count + mailboxes.count <= maximumMailboxes else {
                    throw MailSearchFailure.tooManyMailboxes(maximumMailboxes)
                }
                for mailbox in mailboxes {
                    try permit(account, mailbox.name, mailbox.role)
                }

                var count = 0
                var found: [MailSearchHit] = []
                for mailbox in mailboxes {
                    try await session.select(mailbox.name)
                    let uids = try await session.search(query)
                    count += uids.count
                    let summaries = try await session.summaries(Array(uids.suffix(limit)))
                    found += summaries.map { MailSearchHit(account: account.identifier, mailbox: mailbox.name, summary: $0) }
                }
                return (count, found, mailboxes.map { "\(account.identifier):\($0.name)" })
            }
            total += found.0
            hits += found.1
            searched += found.2
        }

        let newest = hits.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return MailSearchResult(total: total, hits: Array(newest.prefix(limit)), searched: searched, skipped: skipped)
    }
}

public enum MailSearchFailure: Error, Sendable, Equatable, LocalizedError {
    case tooManyMailboxes(Int)

    public var errorDescription: String? {
        switch self {
        case .tooManyMailboxes(let maximum):
            return "The selectors pick more than \(maximum) mailboxes; narrow them."
        }
    }
}
