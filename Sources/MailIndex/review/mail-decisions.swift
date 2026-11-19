import Foundation
import IMAP
import SQLite

/// A person's verdict on a sender, a domain or one message, from review.
public struct MailDecision: Sendable, Equatable {
    public enum Scope: String, Sendable, CaseIterable {
        case sender
        case domain
        /// One message, by its Message-ID (survives moves).
        case message
    }

    public enum Verdict: String, Sendable, CaseIterable {
        /// A real vendor or contact; never flagged again.
        case trust
        /// Unwanted or fraudulent; always flagged.
        case block
        /// This message is a genuine record (invoice, contract).
        case record
        /// Looked at, harmless; stop showing it.
        case dismiss
    }

    public let scope: Scope
    /// Lowercased address or domain, or the Message-ID.
    public let value: String
    public let verdict: Verdict
    public let note: String?
    public let decidedAt: Date

    public init(
        _ verdict: Verdict,
        _ scope: Scope,
        _ value: String,
        note: String? = nil,
        decidedAt: Date = Date()
    ) {
        self.scope = scope
        self.value = scope == .message ? value : value.lowercased()
        self.verdict = verdict
        self.note = note
        self.decidedAt = decidedAt
    }
}

extension MailIndex {
    public func decide(
        _ decision: MailDecision
    ) throws {
        try database.run(
            "INSERT OR REPLACE INTO decisions (scope, value, verdict, note, decided_at) VALUES (?, ?, ?, ?, ?)",
            .text(decision.scope.rawValue), .text(decision.value), .text(decision.verdict.rawValue),
            SQLiteValue(decision.note), SQLiteValue(decision.decidedAt)
        )
    }

    public func undecide(
        _ scope: MailDecision.Scope,
        _ value: String
    ) throws {
        try database.run(
            "DELETE FROM decisions WHERE scope = ? AND value = ?",
            .text(scope.rawValue), .text(scope == .message ? value : value.lowercased())
        )
    }

    public func decisions() throws -> [MailDecision] {
        try database.query("SELECT scope, value, verdict, note, decided_at FROM decisions ORDER BY decided_at").compactMap { row in
            guard let scope = row[0].string.flatMap(MailDecision.Scope.init(rawValue:)),
                  let value = row[1].string,
                  let verdict = row[2].string.flatMap(MailDecision.Verdict.init(rawValue:))
            else {
                return nil
            }
            return MailDecision(
                verdict, scope, value,
                note: row[3].string,
                decidedAt: Date(timeIntervalSince1970: row[4].double ?? 0)
            )
        }
    }

    /// The indexed Message-ID of `uid` in `mailbox`, to decide on one message.
    public func messageID(
        _ uid: IMAPUID,
        in mailbox: String
    ) throws -> String? {
        try database.query(
            "SELECT message_id FROM messages WHERE mailbox = ? AND uid = ?",
            [.text(mailbox), .integer(Int64(uid.rawValue))]
        ).first?.first?.string
    }
}
