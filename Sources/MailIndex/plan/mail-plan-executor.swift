import Foundation
import IMAP

/// What applying a plan did.
public struct MailPlanReport: Sendable, Equatable {
    public struct Skip: Sendable, Equatable {
        public let target: MailPlan.Target
        public let reason: String
    }

    public let planID: String
    public var applied = 0
    public var skipped: [Skip] = []
    /// Mailboxes changed on the server, re-synced into the index when asked.
    public var touched: [String] = []

    public init(
        planID: String
    ) {
        self.planID = planID
    }
}

/// Applies a plan on the server over an authenticated session. Each mailbox
/// is selected writable; a changed `UIDVALIDITY` refuses its targets; each
/// target's Message-ID is fetched again and a target whose message changed or
/// went is skipped. Every outcome is journaled, then the touched mailboxes are
/// re-synced so the index follows the server. Never deletes permanently.
public struct MailPlanExecutor: Sendable {
    public let index: MailIndex
    public let session: IMAPSession

    public init(
        index: MailIndex,
        session: IMAPSession
    ) {
        self.index = index
        self.session = session
    }

    public func execute(
        _ plan: MailPlan,
        resync: Bool = true
    ) async throws -> MailPlanReport {
        try await index.save(plan)
        var report = MailPlanReport(planID: plan.id)
        var touched: [String] = []
        func touch(_ mailbox: String) {
            if !touched.contains(mailbox) {
                touched.append(mailbox)
            }
        }

        for (number, step) in plan.steps.enumerated() {
            var entries: [MailJournalEntry] = []
            func journal(_ target: MailPlan.Target, _ outcome: String, destination: String? = nil, validity: Int? = nil, uid: IMAPUID? = nil) {
                entries.append(MailJournalEntry(
                    planID: plan.id, step: number, at: Date(), action: step.action, target: target,
                    destination: destination, destinationValidity: validity, destinationUID: uid, outcome: outcome
                ))
            }
            func skip(_ target: MailPlan.Target, _ reason: String) {
                report.skipped.append(.init(target: target, reason: reason))
                journal(target, "skipped: \(reason)")
            }

            for mailbox in Self.mailboxes(of: step.targets) {
                let targets = step.targets.filter { $0.mailbox == mailbox }
                if case .move(let destination) = step.action, destination == mailbox {
                    targets.forEach { skip($0, "already in \(destination)") }
                    continue
                }
                let selection = try await session.select(mailbox, readOnly: false)
                let current = targets.filter { $0.uidValidity == selection.uidValidity }
                for stale in targets where stale.uidValidity != selection.uidValidity {
                    skip(stale, "\(mailbox) was renumbered since indexing (UIDVALIDITY changed)")
                }

                // The server's Message-ID for each UID, now.
                let present = try await session.summaries(current.map(\.uid))
                let messageIDs = Dictionary(present.map { ($0.uid, $0.envelope?.messageID) }, uniquingKeysWith: { first, _ in first })
                var verified: [MailPlan.Target] = []
                for target in current {
                    guard let found = messageIDs[target.uid] else {
                        skip(target, "no longer in \(mailbox)")
                        continue
                    }
                    if let expected = target.messageID, found != expected {
                        skip(target, "UID \(target.uid) is another message now")
                        continue
                    }
                    verified.append(target)
                }
                guard !verified.isEmpty else {
                    continue
                }
                let uids = verified.map(\.uid)

                switch step.action {
                case .move(let destination):
                    if destination.uppercased() != "INBOX" {
                        try await session.create(destination)
                    }
                    let mapping = try await session.move(uids, to: destination)
                    for target in verified {
                        journal(target, "done", destination: destination, validity: mapping?.uidValidity, uid: mapping?.uids[target.uid])
                    }
                    touch(mailbox)
                    touch(destination)
                case .addFlags(let flags):
                    try await session.store(Set(flags.map { IMAPFlag($0) }), .add, on: uids)
                    verified.forEach { journal($0, "done") }
                    touch(mailbox)
                case .removeFlags(let flags):
                    try await session.store(Set(flags.map { IMAPFlag($0) }), .remove, on: uids)
                    verified.forEach { journal($0, "done") }
                    touch(mailbox)
                case .addLabels(let labels):
                    try await session.storeLabels(Set(labels), .add, on: uids)
                    verified.forEach { journal($0, "done") }
                    touch(mailbox)
                case .removeLabels(let labels):
                    try await session.storeLabels(Set(labels), .remove, on: uids)
                    verified.forEach { journal($0, "done") }
                    touch(mailbox)
                }
                report.applied += verified.count
            }
            try await index.record(entries)
        }

        try await index.markApplied(plan.id)
        if let undone = plan.undoes {
            try await index.markUndone(undone)
        }
        report.touched = touched
        if resync && !touched.isEmpty {
            _ = try await index.sync(session, mailboxes: touched)
        }
        return report
    }

    /// Applies the reverse of what plan `id` did.
    public func undo(
        _ id: String,
        resync: Bool = true
    ) async throws -> MailPlanReport {
        try await execute(try await index.undoPlan(for: id), resync: resync)
    }

    /// Mailboxes in first-seen order.
    static func mailboxes(
        of targets: [MailPlan.Target]
    ) -> [String] {
        var seen: [String] = []
        for target in targets where !seen.contains(target.mailbox) {
            seen.append(target.mailbox)
        }
        return seen
    }
}
