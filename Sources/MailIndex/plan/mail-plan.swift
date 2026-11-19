import Foundation
import IMAP
import SQLite

/// One change to messages on the server.
public enum MailAction: Sendable, Equatable, Codable, CustomStringConvertible {
    /// To another mailbox, created when missing.
    case move(to: String)
    /// Flags or keywords, such as `\Flagged` or `$Suspicious`.
    case addFlags([String])
    case removeFlags([String])
    /// Gmail labels; `\Inbox` removed archives.
    case addLabels([String])
    case removeLabels([String])

    public var description: String {
        switch self {
        case .move(let mailbox): return "move to \(mailbox)"
        case .addFlags(let flags): return "flag \(flags.joined(separator: " "))"
        case .removeFlags(let flags): return "unflag \(flags.joined(separator: " "))"
        case .addLabels(let labels): return "label \(labels.joined(separator: ", "))"
        case .removeLabels(let labels): return "unlabel \(labels.joined(separator: ", "))"
        }
    }

    /// The action that reverses this one on the same messages; a move's
    /// reverse depends on where each message was, so it comes from the journal.
    var inverse: MailAction? {
        switch self {
        case .move: return nil
        case .addFlags(let flags): return .removeFlags(flags)
        case .removeFlags(let flags): return .addFlags(flags)
        case .addLabels(let labels): return .removeLabels(labels)
        case .removeLabels(let labels): return .addLabels(labels)
        }
    }
}

/// Proposed server changes, pinned to what the index saw: each target names
/// its mailbox, `UIDVALIDITY`, UID and Message-ID, so applying it later can
/// tell when the server no longer matches.
public struct MailPlan: Sendable, Equatable, Codable {
    public struct Target: Sendable, Equatable, Hashable, Codable {
        public let mailbox: String
        public let uidValidity: Int
        public let uid: IMAPUID
        public let messageID: String?

        public init(
            mailbox: String,
            uidValidity: Int,
            uid: IMAPUID,
            messageID: String?
        ) {
            self.mailbox = mailbox
            self.uidValidity = uidValidity
            self.uid = uid
            self.messageID = messageID
        }
    }

    public struct Step: Sendable, Equatable, Codable {
        public let action: MailAction
        public let reason: String
        public let targets: [Target]

        public init(
            _ action: MailAction,
            reason: String,
            targets: [Target]
        ) {
            self.action = action
            self.reason = reason
            self.targets = targets
        }
    }

    public let id: String
    public let createdAt: Date
    public let steps: [Step]
    /// Set when this plan reverses another.
    public let undoes: String?

    public init(
        id: String = MailPlan.newID(),
        createdAt: Date = Date(),
        steps: [Step],
        undoes: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.steps = steps
        self.undoes = undoes
    }

    public var count: Int {
        steps.reduce(0) { $0 + $1.targets.count }
    }

    /// One line per step: `move to Pruned: 120 messages (newsletters past 90 days)`.
    public var summary: String {
        steps.map { "\($0.action): \($0.targets.count) message\($0.targets.count == 1 ? "" : "s") (\($0.reason))" }
            .joined(separator: "; ")
    }

    /// Short and sortable: `20261119-163012-3fa9`.
    public static func newID(
        _ date: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }
}

/// What a target is, from the index.
public struct MailTargetPreview: Sendable, Equatable {
    public let target: MailPlan.Target
    public let fromAddress: String?
    public let fromName: String?
    public let subject: String?
    public let receivedAt: Date?
}

/// A stored plan and what became of it.
public struct MailPlanRecord: Sendable, Equatable {
    public let plan: MailPlan
    public let appliedAt: Date?
    public let undoneAt: Date?
}

/// One target's outcome when a plan was applied.
public struct MailJournalEntry: Sendable, Equatable {
    public let planID: String
    public let step: Int
    public let at: Date
    public let action: MailAction
    public let target: MailPlan.Target
    /// For a move: where the message landed, when the server reported it.
    public let destination: String?
    public let destinationValidity: Int?
    public let destinationUID: IMAPUID?
    /// `done`, or `skipped: <why>`.
    public let outcome: String

    public var isDone: Bool {
        outcome == "done"
    }
}

extension MailIndex {
    // MARK: - Targets

    /// The messages under `filter`, pinned for a plan.
    public func targets(
        _ filter: MailIndexFilter
    ) throws -> [MailPlan.Target] {
        let (condition, bindings) = filter.clause()
        return try database.query(
            """
            SELECT m.mailbox, b.uid_validity, m.uid, m.message_id
            FROM messages m JOIN mailboxes b ON b.name = m.mailbox
            WHERE \(condition)
            ORDER BY m.mailbox, m.uid
            """,
            bindings
        ).map(Self.target)
    }

    /// The suspects, pinned for a plan.
    public func targets(
        _ suspects: [MailSuspicion]
    ) throws -> [MailPlan.Target] {
        let validity = Dictionary(try mailboxes().map { ($0.name, $0.uidValidity) }, uniquingKeysWith: { first, _ in first })
        return suspects.compactMap { suspect in
            validity[suspect.mailbox].map {
                MailPlan.Target(mailbox: suspect.mailbox, uidValidity: $0, uid: suspect.uid, messageID: suspect.messageID)
            }
        }
    }

    /// Sender, subject and date of the first `limit` targets, to show what a plan touches.
    public func previews(
        _ targets: [MailPlan.Target],
        limit: Int = 10
    ) throws -> [MailTargetPreview] {
        try targets.prefix(max(0, limit)).map { target in
            let row = try database.query(
                "SELECT from_address, from_name, subject, received_at FROM messages WHERE mailbox = ? AND uid = ?",
                [.text(target.mailbox), .integer(Int64(target.uid.rawValue))]
            ).first
            return MailTargetPreview(
                target: target,
                fromAddress: row?[0].string,
                fromName: row?[1].string,
                subject: row?[2].string,
                receivedAt: row?[3].double.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    static func target(
        _ row: [SQLiteValue]
    ) -> MailPlan.Target {
        MailPlan.Target(
            mailbox: row[0].string ?? "",
            uidValidity: row[1].int ?? 0,
            uid: IMAPUID(UInt32(row[2].int ?? 0)),
            messageID: row[3].string
        )
    }

    // MARK: - Plans

    public func save(
        _ plan: MailPlan
    ) throws {
        let body = String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)
        try database.run(
            "INSERT OR REPLACE INTO plans (id, created_at, summary, body, applied_at, undone_at) VALUES (?, ?, ?, ?, NULL, NULL)",
            .text(plan.id), SQLiteValue(plan.createdAt), .text(plan.summary), .text(body)
        )
    }

    public func plan(
        _ id: String
    ) throws -> MailPlanRecord? {
        try records("WHERE id = ?", [.text(id)]).first
    }

    /// Newest first.
    public func plans(
        limit: Int = 20
    ) throws -> [MailPlanRecord] {
        try records("ORDER BY created_at DESC LIMIT ?", [.integer(Int64(max(1, limit)))])
    }

    func markApplied(
        _ id: String,
        at date: Date = Date()
    ) throws {
        try database.run("UPDATE plans SET applied_at = ? WHERE id = ?", SQLiteValue(date), .text(id))
    }

    func markUndone(
        _ id: String,
        at date: Date = Date()
    ) throws {
        try database.run("UPDATE plans SET undone_at = ? WHERE id = ?", SQLiteValue(date), .text(id))
    }

    private func records(
        _ clause: String,
        _ bindings: [SQLiteValue]
    ) throws -> [MailPlanRecord] {
        try database.query("SELECT body, applied_at, undone_at FROM plans \(clause)", bindings).compactMap { row in
            guard let body = row[0].string, let plan = try? JSONDecoder().decode(MailPlan.self, from: Data(body.utf8)) else {
                return nil
            }
            return MailPlanRecord(
                plan: plan,
                appliedAt: row[1].double.map(Date.init(timeIntervalSince1970:)),
                undoneAt: row[2].double.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    // MARK: - Journal

    func record(
        _ entries: [MailJournalEntry]
    ) throws {
        guard !entries.isEmpty else {
            return
        }
        try database.transaction {
            try database.run(
                """
                INSERT INTO journal (plan_id, step, at, action, mailbox, uid_validity, uid, message_id,
                                     destination, destination_validity, destination_uid, outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                try entries.map { entry in
                    [
                        .text(entry.planID), .integer(Int64(entry.step)), SQLiteValue(entry.at),
                        .text(String(decoding: try JSONEncoder().encode(entry.action), as: UTF8.self)),
                        .text(entry.target.mailbox), .integer(Int64(entry.target.uidValidity)),
                        .integer(Int64(entry.target.uid.rawValue)), SQLiteValue(entry.target.messageID),
                        SQLiteValue(entry.destination), SQLiteValue(entry.destinationValidity),
                        SQLiteValue(entry.destinationUID.map { Int($0.rawValue) }), .text(entry.outcome),
                    ]
                }
            )
        }
    }

    public func journal(
        plan id: String
    ) throws -> [MailJournalEntry] {
        try database.query(
            """
            SELECT plan_id, step, at, action, mailbox, uid_validity, uid, message_id,
                   destination, destination_validity, destination_uid, outcome
            FROM journal WHERE plan_id = ? ORDER BY step, rowid
            """,
            [.text(id)]
        ).compactMap { row in
            guard let action = row[3].string.flatMap({ try? JSONDecoder().decode(MailAction.self, from: Data($0.utf8)) }) else {
                return nil
            }
            return MailJournalEntry(
                planID: row[0].string ?? "",
                step: row[1].int ?? 0,
                at: Date(timeIntervalSince1970: row[2].double ?? 0),
                action: action,
                target: MailPlan.Target(
                    mailbox: row[4].string ?? "",
                    uidValidity: row[5].int ?? 0,
                    uid: IMAPUID(UInt32(row[6].int ?? 0)),
                    messageID: row[7].string
                ),
                destination: row[8].string,
                destinationValidity: row[9].int,
                destinationUID: row[10].int.map { IMAPUID(UInt32($0)) },
                outcome: row[11].string ?? ""
            )
        }
    }

    /// The plan that reverses what `id` did: moved messages go back from
    /// where they landed, flags and labels are taken off again. Later steps
    /// are reversed first.
    public func undoPlan(
        for id: String
    ) throws -> MailPlan {
        let done = try journal(plan: id).filter(\.isDone)
        var steps: [MailPlan.Step] = []
        for step in Set(done.map(\.step)).sorted(by: >) {
            let entries = done.filter { $0.step == step }
            guard let action = entries.first?.action else {
                continue
            }
            if case .move = action {
                // Each message goes back to its own source mailbox.
                for source in Set(entries.map(\.target.mailbox)).sorted() {
                    let targets = entries.filter { $0.target.mailbox == source }.compactMap { entry -> MailPlan.Target? in
                        guard let destination = entry.destination, let validity = entry.destinationValidity, let uid = entry.destinationUID else {
                            return nil
                        }
                        return MailPlan.Target(mailbox: destination, uidValidity: validity, uid: uid, messageID: entry.target.messageID)
                    }
                    if !targets.isEmpty {
                        steps.append(.init(.move(to: source), reason: "undo \(id)", targets: targets))
                    }
                }
            } else if let inverse = action.inverse {
                steps.append(.init(inverse, reason: "undo \(id)", targets: entries.map(\.target)))
            }
        }
        return MailPlan(id: "undo-\(id)", steps: steps, undoes: id)
    }
}
