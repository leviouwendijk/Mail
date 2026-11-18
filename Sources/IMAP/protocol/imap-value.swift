import Foundation

/// One item of IMAP response data (RFC 3501 §4).
public indirect enum IMAPValue: Sendable, Equatable {
    /// Atoms and numbers, including bracketed section specifiers such as `BODY[HEADER]`.
    case atom(String)
    /// A quoted string or a literal.
    case string(Data)
    case list([IMAPValue])
    /// `NIL`.
    case absent

    public var text: String? {
        switch self {
        case .atom(let atom):
            return atom
        case .string(let data):
            return String(decoding: data, as: UTF8.self)
        default:
            return nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let data):
            return data
        case .atom(let atom):
            return Data(atom.utf8)
        default:
            return nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let values) = self {
            return values
        }
        return nil
    }

    public var number: Int? {
        text.flatMap { Int($0) }
    }

    /// Case-insensitive atom comparison.
    public func isAtom(
        _ name: String
    ) -> Bool {
        if case .atom(let atom) = self {
            return atom.caseInsensitiveCompare(name) == .orderedSame
        }
        return false
    }
}
