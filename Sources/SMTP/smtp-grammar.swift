import Mail
import Parsing

/// RFC 5321 §4.2 reply lines.
public enum SMTPGrammar {}

extension SMTPGrammar {
    public struct ReplyLine: Parser {
        public struct Output: Sendable, Equatable {
            public let code: Int
            /// `false` for a `250-` continuation line.
            public let isFinal: Bool
            public let text: String
        }

        public init() {}

        public func parse(
            _ cursor: Cursor
        ) -> ParseResult<Output> {
            let digit = Char(where: { $0.isASCII && $0.isNumber }, want: "reply code digit")
            let code = digit.then(digit).then(digit)
                .map { Int("\($0.0)\($0.1)\($1)") ?? 0 }
            let separator = Char(where: { $0 == " " || $0 == "-" }, want: "space or hyphen").optional()

            return code
                .then(separator)
                .then(Remainder())
                .map { head, text in
                    Output(code: head.0, isFinal: head.1 != "-", text: text)
                }
                .parse(cursor)
        }
    }
}
