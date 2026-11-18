import Foundation
import Parsing

/// Header fields in message order, looked up case-insensitively.
public struct MailHeaders: Sendable, Equatable {
    public let fields: [MailHeaderField]

    public init(
        _ fields: [MailHeaderField]
    ) {
        self.fields = fields
    }

    /// The first field named `name`, with folding removed but encoded words intact.
    public subscript(
        name: String
    ) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(
        _ name: String
    ) -> [String] {
        fields
            .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            .map(\.value)
    }

    /// The first field named `name` with RFC 2047 encoded words decoded.
    public func text(
        _ name: String
    ) -> String? {
        self[name].map(MIMEEncoding.decodeEncodedWords)
    }

    /// Parses a header block, unfolding continuation lines (RFC 5322 §2.2.3).
    public static func parse(
        _ data: Data
    ) -> MailHeaders {
        let text = MIMEEncoding.decodeText(data, charset: nil)
        // `"\r\n"` is one Character, so normalize before splitting.
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)

        // Unfold continuation lines (RFC 5322 §2.2.3), then parse each field.
        var unfolded: [String] = []
        for line in lines where !line.isEmpty {
            if line.first == " " || line.first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line
            } else {
                unfolded.append(String(line))
            }
        }
        let fields = unfolded.compactMap { MailGrammar.HeaderField().parseComplete($0) }
        return MailHeaders(fields)
    }
}
