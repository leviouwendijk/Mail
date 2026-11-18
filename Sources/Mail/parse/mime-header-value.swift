import Foundation
import Parsing

/// A structured header value such as `text/plain; charset="utf-8"` or
/// `attachment; filename*=utf-8''r%C3%A9sum%C3%A9.pdf` (RFC 2045, RFC 2231).
public struct MIMEHeaderValue: Sendable, Equatable {
    /// Lowercased, e.g. `text/plain` or `attachment`.
    public let value: String
    /// Keys lowercased; RFC 2231 continuations joined and decoded.
    public let parameters: [String: String]

    public init(
        value: String,
        parameters: [String: String] = [:]
    ) {
        self.value = value
        self.parameters = parameters
    }

    public subscript(
        parameter: String
    ) -> String? {
        parameters[parameter.lowercased()]
    }

    public var type: Substring {
        value.split(separator: "/").first ?? ""
    }

    public static func parse(
        _ header: String
    ) -> MIMEHeaderValue {
        let parsed: MailGrammar.HeaderValue.Output
        switch MailGrammar.HeaderValue().parse(Cursor(header)) {
        case .success(let output, _):
            parsed = output
        case .failure:
            parsed = (header.trimmingCharacters(in: .whitespaces).lowercased(), [])
        }

        var plain: [String: String] = [:]
        var extended: [String: [(index: Int, value: String, encoded: Bool)]] = [:]

        for parameter in parsed.parameters {
            var key = parameter.name
            let encoded = key.hasSuffix("*")
            if encoded {
                key.removeLast()
            }
            if let star = key.firstIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                extended[String(key[..<star]), default: []].append((index, parameter.value, encoded))
            } else if encoded {
                extended[key, default: []].append((0, parameter.value, true))
            } else {
                plain[key] = MIMEEncoding.decodeEncodedWords(parameter.value)
            }
        }

        for (key, pieces) in extended {
            let ordered = pieces.sorted { $0.index < $1.index }
            var charset: String?
            var bytes = Data()
            for (offset, piece) in ordered.enumerated() {
                guard piece.encoded else {
                    bytes.append(Data(piece.value.utf8))
                    continue
                }
                var text = Substring(piece.value)
                if offset == 0 {
                    let parts = piece.value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3 {
                        charset = String(parts[0])
                        text = parts[2]
                    }
                }
                bytes.append(percentDecoded(text))
            }
            plain[key] = MIMEEncoding.decodeText(bytes, charset: charset)
        }

        return MIMEHeaderValue(value: parsed.value, parameters: plain)
    }

    private static func percentDecoded(
        _ text: Substring
    ) -> Data {
        var bytes = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "%",
               let end = text.index(index, offsetBy: 3, limitedBy: text.endIndex),
               let byte = UInt8(text[text.index(after: index)..<end], radix: 16)
            {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(character).utf8))
                index = text.index(after: index)
            }
        }
        return bytes
    }
}
