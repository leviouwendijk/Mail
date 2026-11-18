import Foundation
import Parsing

/// RFC 5322, RFC 2045 and RFC 2047 text grammars. Byte-level framing (header
/// block, multipart boundaries) stays in `MIMEParser`, since bodies may be binary.
public enum MailGrammar {}

package extension Parser {
    /// The output when the parser consumes all of `input`.
    func parseComplete(
        _ input: String
    ) -> Output? {
        switch skip(EndOfInput()).parse(Cursor(input)) {
        case .success(let output, _):
            return output
        case .failure:
            return nil
        }
    }
}

extension MailGrammar {
    static let space = TakeWhile(where: { $0 == " " || $0 == "\t" })
    static let whitespace = TakeWhile(where: \.isWhitespace)

    static func character(
        _ allowed: String
    ) -> Char {
        Char(where: { allowed.contains($0) }, want: "one of \(allowed)")
    }

    static func fail<T>(
        _ message: String,
        at cursor: Cursor
    ) -> ParseResult<T> {
        .failure(Diagnostic(message, range: .point(cursor.offset)))
    }

    /// A quoted string with backslash escapes, unescaped.
    public struct QuotedString: Parser {
        public typealias Output = String

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<String> {
            var cursor = cursor
            guard cursor.peek() == "\"" else {
                return MailGrammar.fail("expected quoted string", at: cursor)
            }
            cursor.advance()
            var output = ""
            while let character = cursor.peek() {
                cursor.advance()
                switch character {
                case "\\":
                    if let escaped = cursor.peek() {
                        output.append(escaped)
                        cursor.advance()
                    }
                case "\"":
                    return .success(output, cursor)
                default:
                    output.append(character)
                }
            }
            return MailGrammar.fail("unterminated quoted string", at: cursor)
        }
    }

    /// `name: value` of one unfolded header line.
    public struct HeaderField: Parser {
        public typealias Output = MailHeaderField

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<MailHeaderField> {
            TakeWhile(where: { $0 != ":" }, minimumCount: 1, expectation: "header name")
                .skip(MailGrammar.character(":"))
                .then(Remainder())
                .map { name, value in
                    MailHeaderField(
                        name.trimmingCharacters(in: .whitespaces),
                        value.trimmingCharacters(in: .whitespaces)
                    )
                }
                .parse(cursor)
        }
    }

    public struct Parameter: Sendable, Equatable {
        public let name: String
        public let value: String
    }

    /// `value; name=token; name="quoted"`, skipping malformed parameters.
    public struct HeaderValue: Parser {
        public typealias Output = (value: String, parameters: [Parameter])

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<Output> {
            let space = MailGrammar.space
            let token = TakeWhile(where: { $0 != ";" })
            let value = QuotedString()
                .orElse(token.map { $0.trimmingCharacters(in: .whitespaces) })
                .skip(space)
            let name = TakeWhile(where: { $0 != "=" && $0 != ";" }, minimumCount: 1, expectation: "parameter name")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let parameter = name
                .skip(MailGrammar.character("="))
                .skip(space)
                .then(value)
                .map { Optional(Parameter(name: $0, value: $1)) }
            let malformed = token.map { _ in Parameter?.none }
            let item = MailGrammar.character(";")
                .skip(space)
                .keep(parameter.orElse(malformed))

            return token
                .then(item.many())
                .map { head, parameters in
                    (
                        head.trimmingCharacters(in: .whitespaces).lowercased(),
                        parameters.compactMap { $0 }
                    )
                }
                .parse(cursor)
        }
    }

    public struct EncodedWord: Parser, Sendable {
        public struct Output: Sendable, Equatable {
            public let charset: String
            public let mode: Character
            public let payload: String

            public var decoded: String {
                let bytes = mode == "B"
                    ? MIMEEncoding.decodeBase64(Data(payload.utf8))
                    : MIMEEncoding.decodeQuotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
                // RFC 2231 allows `charset*language`.
                return MIMEEncoding.decodeText(bytes, charset: String(charset.split(separator: "*").first ?? ""))
            }
        }

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<Output> {
            let field = TakeWhile(where: { $0 != "?" && !$0.isWhitespace }, minimumCount: 1, expectation: "charset")
            let mode = Char(where: { "BbQq".contains($0) }, want: "B or Q")
            let payload = TakeWhile(where: { $0 != "?" && !$0.isWhitespace })

            return ExpectString("=?")
                .keep(field)
                .skip(ExpectString("?"))
                .then(mode)
                .skip(ExpectString("?"))
                .then(payload)
                .skip(ExpectString("?="))
                .map { head, payload in
                    Output(charset: head.0, mode: Character(head.1.uppercased()), payload: payload)
                }
                .parse(cursor)
        }
    }

    /// Header text with encoded words decoded and whitespace between adjacent words dropped.
    public struct EncodedText: Parser {
        public typealias Output = String

        enum Segment: Sendable {
            case word(String)
            case space(String)
            case text(String)
        }

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<String> {
            let word = EncodedWord().map { Segment.word($0.decoded) }
            let space = TakeWhile(where: \.isWhitespace, minimumCount: 1).map { Segment.space($0) }
            let text = TakeWhile(where: { $0 != "=" && !$0.isWhitespace }, minimumCount: 1)
                .orElse(Char(where: { _ in true }).map { String($0) })
                .map { Segment.text($0) }

            return word.orElse(space).orElse(text)
                .many()
                .map(Self.join)
                .parse(cursor)
        }

        static func join(
            _ segments: [Segment]
        ) -> String {
            var output = ""
            var pendingSpace = ""
            var previousWasWord = false
            for segment in segments {
                switch segment {
                case .space(let space):
                    pendingSpace += space
                case .word(let word):
                    output += previousWasWord ? "" : pendingSpace
                    output += word
                    pendingSpace = ""
                    previousWasWord = true
                case .text(let text):
                    output += pendingSpace + text
                    pendingSpace = ""
                    previousWasWord = false
                }
            }
            return output + pendingSpace
        }
    }

    public enum AddressToken: Sendable, Equatable {
        case quoted(String)
        case comment(String)
        case angle(String)
        case special(Character)
        case word(String)
    }

    /// A parenthesized comment, nesting allowed, without its outer parentheses.
    public struct Comment: Parser {
        public typealias Output = String

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<String> {
            var cursor = cursor
            guard cursor.peek() == "(" else {
                return MailGrammar.fail("expected comment", at: cursor)
            }
            cursor.advance()
            var depth = 1
            var output = ""
            while let character = cursor.peek() {
                cursor.advance()
                switch character {
                case "\\":
                    if let escaped = cursor.peek() {
                        output.append(escaped)
                        cursor.advance()
                    }
                case "(":
                    depth += 1
                    output.append(character)
                case ")":
                    depth -= 1
                    if depth == 0 {
                        return .success(output, cursor)
                    }
                    output.append(character)
                default:
                    output.append(character)
                }
            }
            return MailGrammar.fail("unterminated comment", at: cursor)
        }
    }

    /// The lexical tokens of an address-list header (RFC 5322 §3.4), leniently.
    public struct AddressTokens: Parser {
        public typealias Output = [AddressToken]

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<[AddressToken]> {
            let quoted = QuotedString().map { AddressToken.quoted($0) }
            let comment = Comment().map { AddressToken.comment($0) }
            let angle = MailGrammar.character("<")
                .keep(TakeWhile(where: { $0 != ">" }))
                .skip(MailGrammar.character(">"))
                .map { AddressToken.angle($0.trimmingCharacters(in: .whitespaces)) }
            let special = MailGrammar.character(",;:").map { AddressToken.special($0) }
            let word = TakeWhile(where: { !$0.isWhitespace && !"\"(<,;:".contains($0) }, minimumCount: 1)
                .map { AddressToken.word($0) }
            let stray = Char(where: { !$0.isWhitespace }).map { AddressToken.word(String($0)) }

            let token = quoted.orElse(comment).orElse(angle).orElse(special).orElse(word).orElse(stray)
            return MailGrammar.whitespace
                .keep(token)
                .many()
                .skip(MailGrammar.whitespace)
                .parse(cursor)
        }
    }
}
