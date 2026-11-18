import Foundation

/// A piece of a command line: plain text, or a literal sent as `{n}` plus its bytes.
public enum IMAPCommandPart: Sendable, Equatable {
    case text(String)
    case literal(Data)

    /// A string argument: atom-safe text as-is, printable ASCII quoted, anything else a literal.
    public static func string(
        _ value: String
    ) -> IMAPCommandPart {
        let isPrintableASCII = value.utf8.allSatisfy { (0x20...0x7E).contains($0) }
        guard isPrintableASCII else {
            return .literal(Data(value.utf8))
        }
        let isAtom = !value.isEmpty && value.allSatisfy { character in
            !" (){%*\"\\]".contains(character)
        }
        if isAtom {
            return .text(value)
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return .text("\"\(escaped)\"")
    }

    /// A mailbox name in modified UTF-7, quoted.
    public static func mailbox(
        _ name: String
    ) -> IMAPCommandPart {
        let encoded = IMAPMailboxName.encode(name)
        return .text("\"\(encoded.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"")
    }

    public var isLiteral: Bool {
        if case .literal = self {
            return true
        }
        return false
    }
}

public extension Array where Element == IMAPCommandPart {
    /// Space-separated, with literals shown inline as `{n}text`; for logs and tests.
    var preview: String {
        var output = ""
        for (index, part) in enumerated() {
            if index > 0 && !part.closesGroup {
                output += " "
            }
            switch part {
            case .text(let text):
                output += text
            case .literal(let data):
                output += "{\(data.count)}" + String(decoding: data, as: UTF8.self)
            }
        }
        return output
    }
}

extension IMAPCommandPart {
    /// A closing parenthesis follows the previous argument without a space.
    var closesGroup: Bool {
        self == .text(")")
    }
}
