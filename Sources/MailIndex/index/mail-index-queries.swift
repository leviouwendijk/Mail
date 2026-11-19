import Foundation
import IMAP
import SQLite

/// Which messages a query looks at. Sent mail is left out unless asked for.
public struct MailIndexFilter: Sendable, Equatable {
    public var mailbox: String?
    public var sender: String?
    public var domain: String?
    public var listID: String?
    public var receivedBefore: Date?
    public var receivedSince: Date?
    public var unread: Bool?
    public var unsubscribable: Bool?
    /// From an address mail was ever sent to.
    public var fromCorrespondent: Bool?
    public var hasAttachment: Bool?
    public var includeSent: Bool

    public init(
        mailbox: String? = nil,
        sender: String? = nil,
        domain: String? = nil,
        listID: String? = nil,
        receivedBefore: Date? = nil,
        receivedSince: Date? = nil,
        unread: Bool? = nil,
        unsubscribable: Bool? = nil,
        fromCorrespondent: Bool? = nil,
        hasAttachment: Bool? = nil,
        includeSent: Bool = false
    ) {
        self.mailbox = mailbox
        self.sender = sender
        self.domain = domain
        self.listID = listID
        self.receivedBefore = receivedBefore
        self.receivedSince = receivedSince
        self.unread = unread
        self.unsubscribable = unsubscribable
        self.fromCorrespondent = fromCorrespondent
        self.hasAttachment = hasAttachment
        self.includeSent = includeSent
    }

    /// `WHERE` conditions over `messages m`, with their bindings.
    func clause() -> (String, [SQLiteValue]) {
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        func add(_ condition: String, _ values: SQLiteValue...) {
            conditions.append(condition)
            bindings += values
        }
        if !includeSent { add("m.is_sent = 0") }
        if let mailbox { add("m.mailbox = ?", .text(mailbox)) }
        if let sender { add("m.from_address = ?", .text(sender.lowercased())) }
        if let domain { add("(m.from_domain = ? OR m.from_domain LIKE ?)", .text(domain.lowercased()), .text("%." + domain.lowercased())) }
        if let listID { add("m.list_id = ?", .text(listID.lowercased())) }
        if let receivedBefore { add("m.received_at < ?", SQLiteValue(receivedBefore)) }
        if let receivedSince { add("m.received_at >= ?", SQLiteValue(receivedSince)) }
        if let unread { add(unread ? "m.seen = 0" : "m.seen = 1") }
        if let unsubscribable { add(unsubscribable ? "m.unsubscribable = 1" : "m.unsubscribable = 0") }
        if let hasAttachment { add(hasAttachment ? "m.attachment_count > 0" : "m.attachment_count = 0") }
        if let fromCorrespondent {
            add((fromCorrespondent ? "" : "NOT ") + "EXISTS (SELECT 1 FROM correspondents c WHERE c.address = m.from_address)")
        }
        return (conditions.isEmpty ? "1" : conditions.joined(separator: " AND "), bindings)
    }
}

public enum MailIndexGrouping: String, Sendable, CaseIterable {
    case sender
    case domain
    case list

    var column: String {
        switch self {
        case .sender: return "m.from_address"
        case .domain: return "m.from_domain"
        case .list: return "m.list_id"
        }
    }

    /// Whether anyone in the group was ever written to.
    var correspondent: String {
        switch self {
        case .sender: return "EXISTS (SELECT 1 FROM correspondents c WHERE c.address = m.from_address)"
        case .domain: return "EXISTS (SELECT 1 FROM correspondents c WHERE c.domain = m.from_domain)"
        case .list: return "0"
        }
    }
}

public enum MailIndexOrder: String, Sendable, CaseIterable {
    case count
    case bytes
    case unread
}

/// One sender, domain or list with its volume and how it is treated.
public struct MailClutterRow: Sendable, Equatable {
    public let key: String
    /// A display name seen for the group.
    public let name: String?
    public let count: Int
    public let bytes: Int
    public let unread: Int
    public let answered: Int
    public let unsubscribable: Int
    public let withAttachments: Int
    public let first: Date?
    public let last: Date?
    /// Mail was sent to this sender (or someone at this domain).
    public let correspondent: Bool

    public var readRatio: Double {
        count == 0 ? 0 : Double(count - unread) / Double(count)
    }
}

public struct MailIndexTotals: Sendable, Equatable {
    public let messages: Int
    public let bytes: Int
    public let unread: Int
    public let senders: Int
    public let correspondents: Int
}

/// Messages picked by a filter, per mailbox with the `UIDVALIDITY` they belong to,
/// ready for a later plan to move or label.
public struct MailIndexSelection: Sendable, Equatable {
    public struct Mailbox: Sendable, Equatable {
        public let name: String
        public let uidValidity: Int
        public let uids: [IMAPUID]

        public init(
            name: String,
            uidValidity: Int,
            uids: [IMAPUID]
        ) {
            self.name = name
            self.uidValidity = uidValidity
            self.uids = uids
        }
    }

    public let mailboxes: [Mailbox]
    public let bytes: Int

    public var count: Int {
        mailboxes.reduce(0) { $0 + $1.uids.count }
    }
}

extension MailIndex {
    public func totals(
        _ filter: MailIndexFilter = MailIndexFilter()
    ) throws -> MailIndexTotals {
        let (condition, bindings) = filter.clause()
        let row = try database.query(
            """
            SELECT COUNT(*), COALESCE(SUM(m.size), 0), COALESCE(SUM(1 - m.seen), 0), COUNT(DISTINCT m.from_address),
                   (SELECT COUNT(*) FROM correspondents)
            FROM messages m WHERE \(condition)
            """,
            bindings
        ).first ?? []
        return MailIndexTotals(
            messages: row.first?.int ?? 0,
            bytes: row.count > 1 ? row[1].int ?? 0 : 0,
            unread: row.count > 2 ? row[2].int ?? 0 : 0,
            senders: row.count > 3 ? row[3].int ?? 0 : 0,
            correspondents: row.count > 4 ? row[4].int ?? 0 : 0
        )
    }

    /// The biggest senders, domains or lists under `filter`.
    public func clutter(
        by grouping: MailIndexGrouping,
        filter: MailIndexFilter = MailIndexFilter(),
        order: MailIndexOrder = .count,
        limit: Int = 50
    ) throws -> [MailClutterRow] {
        let (condition, bindings) = filter.clause()
        let orderBy: String
        switch order {
        case .count: orderBy = "COUNT(*) DESC"
        case .bytes: orderBy = "SUM(m.size) DESC"
        case .unread: orderBy = "SUM(1 - m.seen) DESC"
        }
        let rows = try database.query(
            """
            SELECT \(grouping.column) AS key, MAX(m.from_name), COUNT(*), COALESCE(SUM(m.size), 0),
                   SUM(1 - m.seen), SUM(m.answered), SUM(m.unsubscribable), SUM(m.attachment_count > 0),
                   MIN(m.received_at), MAX(m.received_at), MAX(\(grouping.correspondent))
            FROM messages m
            WHERE \(condition) AND \(grouping.column) IS NOT NULL
            GROUP BY key
            ORDER BY \(orderBy)
            LIMIT ?
            """,
            bindings + [.integer(Int64(max(1, limit)))]
        )
        return rows.map { row in
            MailClutterRow(
                key: row[0].string ?? "",
                name: row[1].string,
                count: row[2].int ?? 0,
                bytes: row[3].int ?? 0,
                unread: row[4].int ?? 0,
                answered: row[5].int ?? 0,
                unsubscribable: row[6].int ?? 0,
                withAttachments: row[7].int ?? 0,
                first: row[8].double.map(Date.init(timeIntervalSince1970:)),
                last: row[9].double.map(Date.init(timeIntervalSince1970:)),
                correspondent: (row[10].int ?? 0) != 0
            )
        }
    }

    /// The messages matching `filter`, grouped by mailbox.
    public func select(
        _ filter: MailIndexFilter
    ) throws -> MailIndexSelection {
        let (condition, bindings) = filter.clause()
        let rows = try database.query(
            """
            SELECT m.mailbox, b.uid_validity, m.uid, COALESCE(m.size, 0)
            FROM messages m JOIN mailboxes b ON b.name = m.mailbox
            WHERE \(condition)
            ORDER BY m.mailbox, m.uid
            """,
            bindings
        )
        var order: [String] = []
        var validity: [String: Int] = [:]
        var uids: [String: [IMAPUID]] = [:]
        var bytes = 0
        for row in rows {
            let name = row[0].string ?? ""
            if uids[name] == nil {
                order.append(name)
                validity[name] = row[1].int ?? 0
            }
            uids[name, default: []].append(IMAPUID(UInt32(row[2].int ?? 0)))
            bytes += row[3].int ?? 0
        }
        return MailIndexSelection(
            mailboxes: order.map { MailIndexSelection.Mailbox(name: $0, uidValidity: validity[$0] ?? 0, uids: uids[$0] ?? []) },
            bytes: bytes
        )
    }
}
