import Foundation
import Mail
import Parsing

/// RFC 3501 response grammar over response text. Literals are read as raw
/// bytes by `IMAPResponse.read` and appear in the text as `{#index}` markers,
/// so binary message data never passes through `String`.
public enum IMAPGrammar {}

extension IMAPGrammar {
    static let space = TakeWhile(where: { $0 == " " })

    static func fail<T>(
        _ message: String,
        at cursor: Cursor,
        committed: Bool = false
    ) -> ParseResult<T> {
        .failure(Diagnostic(message, range: .point(cursor.offset), committed: committed))
    }

    /// One value: a list, quoted string, literal marker, `NIL` or atom.
    public struct Value: Parser {
        public typealias Output = IMAPValue

        public let literals: [Data]

        public init(
            literals: [Data] = []
        ) {
            self.literals = literals
        }

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<IMAPValue> {
            switch cursor.peek() {
            case "(":
                return List(literals: literals).map { IMAPValue.list($0) }.parse(cursor)
            case "\"":
                return MailGrammar.QuotedString().map { IMAPValue.string(Data($0.utf8)) }.parse(cursor)
            case "{":
                return LiteralMarker(literals: literals).map { IMAPValue.string($0) }.parse(cursor)
            default:
                return Atom().map { $0.uppercased() == "NIL" ? IMAPValue.absent : .atom($0) }.parse(cursor)
            }
        }
    }

    /// `(value value …)`.
    public struct List: Parser {
        public typealias Output = [IMAPValue]

        public let literals: [Data]

        public init(
            literals: [Data] = []
        ) {
            self.literals = literals
        }

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<[IMAPValue]> {
            Char(where: { $0 == "(" }, want: "(")
                .keep(IMAPGrammar.space.keep(Value(literals: literals)).many())
                .skip(IMAPGrammar.space)
                .skip(Char(where: { $0 == ")" }, want: ")"))
                .parse(cursor)
        }
    }

    /// Atom characters, keeping a bracketed section such as `BODY[HEADER.FIELDS (FROM)]` whole.
    public struct Atom: Parser {
        public typealias Output = String

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<String> {
            var cursor = cursor
            let start = cursor.mark()
            var depth = 0
            while let character = cursor.peek() {
                if depth == 0 && " ()\"{".contains(character) {
                    break
                }
                if character == "[" {
                    depth += 1
                } else if character == "]" {
                    depth = max(0, depth - 1)
                }
                cursor.advance()
            }
            let atom = cursor.slice(from: start)
            return atom.isEmpty ? IMAPGrammar.fail("expected atom", at: cursor) : .success(atom, cursor)
        }
    }

    /// `{#index}`, resolved to the literal's bytes.
    public struct LiteralMarker: Parser {
        public typealias Output = Data

        public let literals: [Data]

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<Data> {
            let literals = literals
            return ExpectString("{#")
                .keep(TakeWhile(where: \.isNumber, minimumCount: 1, expectation: "literal index"))
                .skip(ExpectString("}"))
                .parse(cursor)
                .resolving { index, next in
                    guard let index = Int(index), literals.indices.contains(index) else {
                        return IMAPGrammar.fail("unknown literal", at: next, committed: true)
                    }
                    return .success(literals[index], next)
                }
        }
    }

    /// Space-separated values up to the end of the response.
    public struct Values: Parser {
        public typealias Output = [IMAPValue]

        public let literals: [Data]

        public init(
            literals: [Data] = []
        ) {
            self.literals = literals
        }

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<[IMAPValue]> {
            IMAPGrammar.space
                .keep(Value(literals: literals))
                .many()
                .skip(IMAPGrammar.space)
                .skip(EndOfInput())
                .parse(cursor)
        }
    }

    /// `OK [code] text` and the other status responses.
    public struct StatusText: Parser {
        public typealias Output = IMAPStatusText

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<IMAPStatusText> {
            let status = TakeWhile(where: \.isLetter, minimumCount: 1, expectation: "status")
                .map { $0.uppercased() }
            let code = Char(where: { $0 == "[" }, want: "[")
                .keep(TakeWhile(where: { $0 != "]" }))
                .skip(Char(where: { $0 == "]" }, want: "]"))
                .optional()

            return status
                .parse(cursor)
                .resolving { status, next in
                    guard IMAPStatusText.statuses.contains(status) else {
                        return IMAPGrammar.fail("expected status", at: cursor)
                    }
                    return IMAPGrammar.space
                        .keep(code)
                        .skip(IMAPGrammar.space)
                        .then(Remainder())
                        .map { code, text in
                            IMAPStatusText(status: status, code: code, text: text.trimmingCharacters(in: .whitespaces))
                        }
                        .parse(next)
                }
        }
    }

    /// `+ text`, `* …` or `tag status`.
    public struct Response: Parser {
        public typealias Output = IMAPResponse

        public let literals: [Data]

        public init(
            literals: [Data] = []
        ) {
            self.literals = literals
        }

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<IMAPResponse> {
            let continuation = Char(where: { $0 == "+" }, want: "+")
                .keep(Remainder())
                .map { IMAPResponse.continuation($0.trimmingCharacters(in: .whitespaces)) }
            let untaggedStatus = StatusText().map { IMAPResponse.status($0) }
            let untaggedData = Values(literals: literals).map { IMAPResponse.data($0) }
            let untagged = ExpectString("* ")
                .keep(untaggedStatus.orElse(untaggedData))
            let tagged = TakeWhile(where: { $0 != " " }, minimumCount: 1, expectation: "tag")
                .skip(IMAPGrammar.space)
                .then(StatusText())
                .map { IMAPResponse.tagged(tag: $0, $1) }

            return continuation.orElse(untagged).orElse(tagged).parse(cursor)
        }
    }
}

extension ParseResult {
    /// Continues with `next` after a success; passes failures through.
    func resolving<U>(
        _ next: (T, Cursor) -> ParseResult<U>
    ) -> ParseResult<U> {
        switch self {
        case .success(let output, let cursor):
            return next(output, cursor)
        case .failure(let diagnostic):
            return .failure(diagnostic)
        }
    }
}
