import Foundation
import IMAP
import SQLite
import IO
import Mail

/// A local SQLite index of one account's messages: envelopes, flags, list and
/// authentication headers and attachments, never bodies. Answers count-shaped
/// questions (who sends the most, what is never read) without touching the server.
public actor MailIndex {
    let database: SQLiteDatabase

    /// Opens or creates the index at `url`, creating its directory.
    public init(
        url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        if !FileSystem.default.exists(directory) {
            try FileSystem.default.directory.create(directory)
        }
        try self.init(path: url.path)
    }

    /// `":memory:"` for a scratch index.
    public init(
        path: String
    ) throws {
        database = try SQLiteDatabase(path: path)
        try database.execute(Self.schema)
    }

    public static func exists(
        at url: URL
    ) -> Bool {
        FileSystem.default.exists(url)
    }

    /// `~/.local/share/mail/index/<account>.sqlite`.
    public static func defaultURL(
        account: String
    ) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/mail/index", isDirectory: true)
            .appendingPathComponent("\(account).sqlite")
    }

    static let schema = """
    PRAGMA journal_mode = WAL;
    CREATE TABLE IF NOT EXISTS mailboxes (
        name TEXT PRIMARY KEY,
        role TEXT,
        uid_validity INTEGER NOT NULL,
        uid_next INTEGER NOT NULL,
        synced_at REAL
    );
    CREATE TABLE IF NOT EXISTS messages (
        mailbox TEXT NOT NULL,
        uid INTEGER NOT NULL,
        message_id TEXT,
        gmail_id TEXT,
        thread_id TEXT,
        from_address TEXT,
        from_name TEXT,
        from_domain TEXT,
        reply_to_domain TEXT,
        return_path_domain TEXT,
        subject TEXT,
        sent_at REAL,
        received_at REAL,
        size INTEGER,
        seen INTEGER NOT NULL,
        answered INTEGER NOT NULL,
        flagged INTEGER NOT NULL,
        keywords TEXT,
        list_id TEXT,
        unsubscribable INTEGER NOT NULL,
        precedence TEXT,
        auto_submitted TEXT,
        spf TEXT,
        dkim TEXT,
        dmarc TEXT,
        attachment_count INTEGER NOT NULL,
        attachment_types TEXT,
        attachment_names TEXT,
        labels TEXT,
        is_sent INTEGER NOT NULL,
        PRIMARY KEY (mailbox, uid)
    );
    CREATE INDEX IF NOT EXISTS messages_from ON messages (from_address);
    CREATE INDEX IF NOT EXISTS messages_domain ON messages (from_domain);
    CREATE INDEX IF NOT EXISTS messages_list ON messages (list_id);
    CREATE INDEX IF NOT EXISTS messages_message_id ON messages (message_id);
    CREATE TABLE IF NOT EXISTS recipients (
        mailbox TEXT NOT NULL,
        uid INTEGER NOT NULL,
        address TEXT NOT NULL,
        domain TEXT NOT NULL,
        PRIMARY KEY (mailbox, uid, address)
    );
    CREATE TABLE IF NOT EXISTS correspondents (
        address TEXT PRIMARY KEY,
        domain TEXT NOT NULL,
        sent INTEGER NOT NULL,
        last_sent REAL
    );
    CREATE INDEX IF NOT EXISTS correspondents_domain ON correspondents (domain);
    -- Plans of server changes and what applying them did. Durable, like decisions.
    CREATE TABLE IF NOT EXISTS plans (
        id TEXT PRIMARY KEY,
        created_at REAL NOT NULL,
        summary TEXT NOT NULL,
        body TEXT NOT NULL,
        applied_at REAL,
        undone_at REAL
    );
    CREATE TABLE IF NOT EXISTS journal (
        plan_id TEXT NOT NULL,
        step INTEGER NOT NULL,
        at REAL NOT NULL,
        action TEXT NOT NULL,
        mailbox TEXT NOT NULL,
        uid_validity INTEGER NOT NULL,
        uid INTEGER NOT NULL,
        message_id TEXT,
        destination TEXT,
        destination_validity INTEGER,
        destination_uid INTEGER,
        outcome TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS journal_plan ON journal (plan_id);
    -- Review decisions. Durable: syncing and reindexing never touch them.
    CREATE TABLE IF NOT EXISTS decisions (
        scope TEXT NOT NULL,
        value TEXT NOT NULL,
        verdict TEXT NOT NULL,
        note TEXT,
        decided_at REAL NOT NULL,
        PRIMARY KEY (scope, value)
    );
    """

    // MARK: - Mailbox state

    public struct MailboxState: Sendable, Equatable {
        public let name: String
        public let role: String?
        public let uidValidity: Int
        public let uidNext: Int
        public let syncedAt: Date?
    }

    public func mailboxes() throws -> [MailboxState] {
        try database.query("SELECT name, role, uid_validity, uid_next, synced_at FROM mailboxes ORDER BY name").map { row in
            MailboxState(
                name: row[0].string ?? "",
                role: row[1].string,
                uidValidity: row[2].int ?? 0,
                uidNext: row[3].int ?? 1,
                syncedAt: row[4].double.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    public func mailbox(
        _ name: String
    ) throws -> MailboxState? {
        try mailboxes().first { $0.name == name }
    }

    /// Forgets `name`'s messages and starts it over, as after a `UIDVALIDITY` change.
    public func reset(
        mailbox name: String,
        role: String?,
        uidValidity: Int
    ) throws {
        try database.transaction {
            try database.run("DELETE FROM messages WHERE mailbox = ?", .text(name))
            try database.run("DELETE FROM recipients WHERE mailbox = ?", .text(name))
            try database.run(
                "INSERT OR REPLACE INTO mailboxes (name, role, uid_validity, uid_next, synced_at) VALUES (?, ?, ?, 1, NULL)",
                .text(name), SQLiteValue(role), .integer(Int64(uidValidity))
            )
        }
    }

    public func finish(
        mailbox name: String,
        uidNext: Int,
        at date: Date = Date()
    ) throws {
        try database.run(
            "UPDATE mailboxes SET uid_next = ?, synced_at = ? WHERE name = ?",
            .integer(Int64(uidNext)), SQLiteValue(date), .text(name)
        )
    }

    /// Mailboxes no longer on the server.
    public func drop(
        mailbox name: String
    ) throws {
        try database.transaction {
            try database.run("DELETE FROM messages WHERE mailbox = ?", .text(name))
            try database.run("DELETE FROM recipients WHERE mailbox = ?", .text(name))
            try database.run("DELETE FROM mailboxes WHERE name = ?", .text(name))
        }
    }

    // MARK: - Messages

    public func insert(
        _ messages: [IndexedMessage]
    ) throws {
        guard !messages.isEmpty else {
            return
        }
        try database.transaction {
            try database.run(
                """
                INSERT OR REPLACE INTO messages (
                    mailbox, uid, message_id, gmail_id, thread_id,
                    from_address, from_name, from_domain, reply_to_domain, return_path_domain,
                    subject, sent_at, received_at, size,
                    seen, answered, flagged, keywords,
                    list_id, unsubscribable, precedence, auto_submitted,
                    spf, dkim, dmarc,
                    attachment_count, attachment_types, attachment_names,
                    labels, is_sent
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                messages.map { message in
                    [
                        .text(message.mailbox), .integer(Int64(message.uid.rawValue)),
                        SQLiteValue(message.messageID), SQLiteValue(message.gmailID), SQLiteValue(message.threadID),
                        SQLiteValue(message.fromAddress), SQLiteValue(message.fromName), SQLiteValue(message.fromDomain),
                        SQLiteValue(message.replyToDomain), SQLiteValue(message.returnPathDomain),
                        SQLiteValue(message.subject), SQLiteValue(message.sentAt), SQLiteValue(message.receivedAt),
                        SQLiteValue(message.size),
                    ]
                        + Self.flagColumns(message.flags)
                        + [
                            SQLiteValue(message.listID), SQLiteValue(message.unsubscribable),
                            SQLiteValue(message.precedence), SQLiteValue(message.autoSubmitted),
                            SQLiteValue(message.spf), SQLiteValue(message.dkim), SQLiteValue(message.dmarc),
                            SQLiteValue(message.attachments.count),
                            Self.joined(message.attachments.map(\.mediaType)),
                            Self.joined(message.attachments.compactMap(\.filename)),
                            Self.joined(message.labels),
                            SQLiteValue(message.isSent),
                        ]
                }
            )
            try database.run(
                "INSERT OR REPLACE INTO recipients (mailbox, uid, address, domain) VALUES (?, ?, ?, ?)",
                messages.flatMap { message in
                    Set(message.recipients).sorted().map { address in
                        [
                            .text(message.mailbox), .integer(Int64(message.uid.rawValue)), .text(address),
                            .text(String(address.split(separator: "@").last ?? "")),
                        ]
                    }
                }
            )
        }
    }

    public func uids(
        in mailbox: String
    ) throws -> [IMAPUID] {
        try database.query("SELECT uid FROM messages WHERE mailbox = ? ORDER BY uid", [.text(mailbox)])
            .compactMap { $0[0].int.map { IMAPUID(UInt32($0)) } }
    }

    public func remove(
        _ uids: [IMAPUID],
        from mailbox: String
    ) throws {
        let rows = uids.map { [SQLiteValue.text(mailbox), .integer(Int64($0.rawValue))] }
        try database.transaction {
            try database.run("DELETE FROM messages WHERE mailbox = ? AND uid = ?", rows)
            try database.run("DELETE FROM recipients WHERE mailbox = ? AND uid = ?", rows)
        }
    }

    /// Replaces stored flags; returns how many changed.
    @discardableResult
    public func update(
        flags: [IMAPUID: Set<IMAPFlag>],
        in mailbox: String
    ) throws -> Int {
        let current = try database.query(
            "SELECT uid, seen, answered, flagged, keywords FROM messages WHERE mailbox = ?",
            [.text(mailbox)]
        )
        var changed: [[SQLiteValue]] = []
        for row in current {
            guard let uid = row[0].int, let next = flags[IMAPUID(UInt32(uid))] else {
                continue
            }
            let columns = Self.flagColumns(next)
            if Array(row[1...4]) != columns {
                changed.append(columns + [.text(mailbox), .integer(Int64(uid))])
            }
        }
        try database.transaction {
            try database.run(
                "UPDATE messages SET seen = ?, answered = ?, flagged = ?, keywords = ? WHERE mailbox = ? AND uid = ?",
                changed
            )
        }
        return changed.count
    }

    /// Rebuilds the addresses mail was sent to, from sent messages.
    public func rebuildCorrespondents() throws {
        try database.transaction {
            try database.execute(
                """
                DELETE FROM correspondents;
                INSERT INTO correspondents (address, domain, sent, last_sent)
                SELECT r.address, r.domain, COUNT(*), MAX(m.sent_at)
                FROM recipients r JOIN messages m ON m.mailbox = r.mailbox AND m.uid = r.uid
                WHERE m.is_sent = 1
                GROUP BY r.address;
                """
            )
        }
    }

    static func flagColumns(
        _ flags: Set<IMAPFlag>
    ) -> [SQLiteValue] {
        [
            SQLiteValue(flags.contains(.seen)),
            SQLiteValue(flags.contains(.answered)),
            SQLiteValue(flags.contains(.flagged)),
            joined(flags.map(\.rawValue).filter { !$0.hasPrefix("\\") }.sorted()),
        ]
    }

    /// Newline-joined, or `NULL` when empty; newlines never occur in the values.
    static func joined(
        _ values: [String]
    ) -> SQLiteValue {
        values.isEmpty ? .null : .text(values.joined(separator: "\n"))
    }
}
