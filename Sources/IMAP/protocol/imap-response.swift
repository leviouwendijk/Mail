import Foundation
import MailConnection
import Parsing

/// `OK`, `NO`, `BAD`, `BYE` or `PREAUTH` with its optional `[code]` and text.
public struct IMAPStatusText: Sendable, Equatable {
    public let status: String
    /// The bracketed response code without brackets, such as `UIDVALIDITY 3857529045`.
    public let code: String?
    public let text: String

    public init(
        status: String,
        code: String?,
        text: String
    ) {
        self.status = status
        self.code = code
        self.text = text
    }

    public var isOK: Bool {
        status == "OK" || status == "PREAUTH"
    }

    static let statuses: Set<String> = ["OK", "NO", "BAD", "BYE", "PREAUTH"]
}

public enum IMAPResponse: Sendable, Equatable {
    case tagged(tag: String, IMAPStatusText)
    case status(IMAPStatusText)
    case data([IMAPValue])
    case continuation(String)

    /// Reads one complete response. Each `{n}` literal is read as raw bytes and
    /// replaced in the text by a `{#index}` marker for the grammar.
    public static func read(
        from transport: any MailTransport
    ) async throws -> IMAPResponse {
        var text = ""
        var literals: [Data] = []
        var line = try await transport.readLine()
        while let marker = literal(line) {
            text += marker.prefix + "{#\(literals.count)}"
            literals.append(try await transport.read(count: marker.count))
            line = try await transport.readLine()
        }
        text += line
        return try parse(text, literals: literals)
    }

    public static func parse(
        _ text: String,
        literals: [Data] = []
    ) throws -> IMAPResponse {
        switch IMAPGrammar.Response(literals: literals).parse(Cursor(text)) {
        case .success(let response, _):
            return response
        case .failure(let diagnostic):
            throw IMAPError.malformedResponse("\(diagnostic.message): \(text.prefix(200))")
        }
    }

    /// The line before a trailing `{n}` or `{n+}`, and `n`.
    private static func literal(
        _ line: String
    ) -> (prefix: String, count: Int)? {
        guard line.hasSuffix("}"), let open = line.lastIndex(of: "{") else {
            return nil
        }
        var digits = line[line.index(after: open)..<line.index(before: line.endIndex)]
        if digits.hasSuffix("+") {
            digits = digits.dropLast()
        }
        guard let count = Int(digits) else {
            return nil
        }
        return (String(line[..<open]), count)
    }
}
