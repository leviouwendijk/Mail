import Foundation
import Mail

/// A typed IMAP `SEARCH` query (RFC 3501 §6.4.4).
///
/// ```swift
/// let query: IMAPSearch = .unread && .from("jan@example.org") && !.subject("newsletter")
/// let either = IMAPSearch.any(.flagged, .from("jan"), .from("casper"))
///
/// // A block for conditional criteria. Swift reads a line that starts with
/// // `.name` as a member of the line above, so name the type on each line.
/// let filtered = IMAPSearch.matching {
///     IMAPSearch.unread
///     if let since { IMAPSearch.since(since) }
/// }
/// ```
public indirect enum IMAPSearch: Sendable, Equatable {
    case all
    case seen
    case unseen
    case flagged
    case unflagged
    case answered
    case unanswered
    case deleted
    case undeleted
    case draft
    case undraft
    case keyword(String)
    case unkeyword(String)

    case from(String)
    case to(String)
    case cc(String)
    case bcc(String)
    case subject(String)
    /// Body text only.
    case body(String)
    /// Headers and body.
    case text(String)
    case header(String, String)

    /// Internal (received) date, compared by day in the server's zone.
    case since(Date)
    case before(Date)
    case on(Date)
    /// The `Date:` header, compared by day.
    case sentSince(Date)
    case sentBefore(Date)
    case sentOn(Date)

    case larger(Int)
    case smaller(Int)
    case uids([IMAPUID])

    case and([IMAPSearch])
    case or(IMAPSearch, IMAPSearch)
    case not(IMAPSearch)

    public static var unread: IMAPSearch { .unseen }
    public static var read: IMAPSearch { .seen }

    /// Every criterion must hold.
    public static func matching(
        _ criteria: IMAPSearch...
    ) -> IMAPSearch {
        .and(criteria)
    }

    public static func matching(
        @IMAPSearchBuilder _ criteria: () -> [IMAPSearch]
    ) -> IMAPSearch {
        .and(criteria())
    }

    /// At least one criterion must hold.
    public static func any(
        _ criteria: IMAPSearch...
    ) -> IMAPSearch {
        disjunction(criteria)
    }

    public static func any(
        @IMAPSearchBuilder _ criteria: () -> [IMAPSearch]
    ) -> IMAPSearch {
        disjunction(criteria())
    }

    private static func disjunction(
        _ all: [IMAPSearch]
    ) -> IMAPSearch {
        guard var result = all.last else {
            return .not(.all)
        }
        for criterion in all.dropLast().reversed() {
            result = .or(criterion, result)
        }
        return result
    }

    public static func && (
        lhs: IMAPSearch,
        rhs: IMAPSearch
    ) -> IMAPSearch {
        .and(lhs.conjuncts + rhs.conjuncts)
    }

    public static func || (
        lhs: IMAPSearch,
        rhs: IMAPSearch
    ) -> IMAPSearch {
        .or(lhs, rhs)
    }

    public static prefix func ! (
        operand: IMAPSearch
    ) -> IMAPSearch {
        if case .not(let inner) = operand {
            return inner
        }
        return .not(operand)
    }

    /// Whether rendering needs `CHARSET UTF-8`.
    public var needsUTF8: Bool {
        arguments().contains(where: \.isLiteral)
    }

    /// The search keys, ready to follow `UID SEARCH`.
    public func arguments(
        timeZone: TimeZone = .current
    ) -> [IMAPCommandPart] {
        func date(_ key: String, _ value: Date) -> [IMAPCommandPart] {
            [.text(key), .text(MailDate.searchDate(value, in: timeZone))]
        }
        func string(_ key: String, _ value: String) -> [IMAPCommandPart] {
            [.text(key), .string(value)]
        }

        switch self {
        case .all: return [.text("ALL")]
        case .seen: return [.text("SEEN")]
        case .unseen: return [.text("UNSEEN")]
        case .flagged: return [.text("FLAGGED")]
        case .unflagged: return [.text("UNFLAGGED")]
        case .answered: return [.text("ANSWERED")]
        case .unanswered: return [.text("UNANSWERED")]
        case .deleted: return [.text("DELETED")]
        case .undeleted: return [.text("UNDELETED")]
        case .draft: return [.text("DRAFT")]
        case .undraft: return [.text("UNDRAFT")]
        case .keyword(let flag): return [.text("KEYWORD"), .text(flag)]
        case .unkeyword(let flag): return [.text("UNKEYWORD"), .text(flag)]

        case .from(let value): return string("FROM", value)
        case .to(let value): return string("TO", value)
        case .cc(let value): return string("CC", value)
        case .bcc(let value): return string("BCC", value)
        case .subject(let value): return string("SUBJECT", value)
        case .body(let value): return string("BODY", value)
        case .text(let value): return string("TEXT", value)
        case .header(let name, let value): return [.text("HEADER"), .string(name), .string(value)]

        case .since(let value): return date("SINCE", value)
        case .before(let value): return date("BEFORE", value)
        case .on(let value): return date("ON", value)
        case .sentSince(let value): return date("SENTSINCE", value)
        case .sentBefore(let value): return date("SENTBEFORE", value)
        case .sentOn(let value): return date("SENTON", value)

        case .larger(let size): return [.text("LARGER"), .text(String(size))]
        case .smaller(let size): return [.text("SMALLER"), .text(String(size))]
        case .uids(let uids): return [.text("UID"), .text(uids.isEmpty ? "0" : IMAPUID.set(uids))]

        case .and(let criteria):
            guard !criteria.isEmpty else {
                return [.text("ALL")]
            }
            return criteria.flatMap { $0.arguments(timeZone: timeZone) }
        case .or(let lhs, let rhs):
            return [.text("OR")] + lhs.key(timeZone) + rhs.key(timeZone)
        case .not(let operand):
            return [.text("NOT")] + operand.key(timeZone)
        }
    }

    /// The arguments as one search key, parenthesized when they are several.
    private func key(
        _ timeZone: TimeZone
    ) -> [IMAPCommandPart] {
        if case .and(let criteria) = self, criteria.count > 1 {
            var parts = arguments(timeZone: timeZone)
            if case .text(let first) = parts[0] {
                parts[0] = .text("(" + first)
            }
            parts.append(.text(")"))
            return parts
        }
        return arguments(timeZone: timeZone)
    }

    private var conjuncts: [IMAPSearch] {
        if case .and(let criteria) = self {
            return criteria
        }
        return [self]
    }
}

@resultBuilder
public enum IMAPSearchBuilder {
    public static func buildBlock(
        _ parts: [IMAPSearch]...
    ) -> [IMAPSearch] {
        parts.flatMap { $0 }
    }

    public static func buildExpression(
        _ expression: IMAPSearch
    ) -> [IMAPSearch] {
        [expression]
    }

    public static func buildOptional(
        _ parts: [IMAPSearch]?
    ) -> [IMAPSearch] {
        parts ?? []
    }

    public static func buildEither(
        first parts: [IMAPSearch]
    ) -> [IMAPSearch] {
        parts
    }

    public static func buildEither(
        second parts: [IMAPSearch]
    ) -> [IMAPSearch] {
        parts
    }

    public static func buildArray(
        _ parts: [[IMAPSearch]]
    ) -> [IMAPSearch] {
        parts.flatMap { $0 }
    }
}
