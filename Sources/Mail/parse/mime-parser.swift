import Foundation

/// A parsed MIME entity: leaf bodies are transfer-decoded, multiparts hold their parts.
public struct ParsedPart: Sendable, Equatable {
    public let headers: MailHeaders
    public let contentType: MIMEHeaderValue
    public let disposition: MIMEHeaderValue?
    /// Transfer-decoded bytes; empty for a multipart.
    public let body: Data
    public let parts: [ParsedPart]

    public var isMultipart: Bool {
        contentType.type == "multipart"
    }

    public var filename: String? {
        disposition?["filename"] ?? contentType["name"]
    }

    /// The body as text in its declared charset.
    public var text: String {
        MIMEEncoding.decodeText(body, charset: contentType["charset"])
    }

    /// Leaves in document order.
    public var leaves: [ParsedPart] {
        isMultipart ? parts.flatMap(\.leaves) : [self]
    }
}

public enum MIMEParser {
    public static func parse(
        _ data: Data
    ) -> ParsedPart {
        let (head, body) = splitHead(data)
        let headers = MailHeaders.parse(head)
        let contentType = headers["Content-Type"].map(MIMEHeaderValue.parse)
            ?? MIMEHeaderValue(value: "text/plain", parameters: ["charset": "us-ascii"])
        let disposition = headers["Content-Disposition"].map(MIMEHeaderValue.parse)

        if contentType.type == "multipart", let boundary = contentType["boundary"], !boundary.isEmpty {
            return ParsedPart(
                headers: headers,
                contentType: contentType,
                disposition: disposition,
                body: Data(),
                parts: splitMultipart(body, boundary: boundary).map(parse)
            )
        }

        let encoding = headers["Content-Transfer-Encoding"]?.trimmingCharacters(in: .whitespaces).lowercased()
        let decoded: Data
        switch encoding {
        case "base64":
            decoded = MIMEEncoding.decodeBase64(body)
        case "quoted-printable":
            decoded = MIMEEncoding.decodeQuotedPrintable(body)
        default:
            decoded = body
        }
        return ParsedPart(
            headers: headers,
            contentType: contentType,
            disposition: disposition,
            body: decoded,
            parts: []
        )
    }

    /// Splits at the first empty line, accepting CRLF or bare LF.
    static func splitHead(
        _ data: Data
    ) -> (Data, Data) {
        let lines = lineRanges(data)
        for line in lines where line.content.isEmpty {
            return (
                Data(data[data.startIndex..<line.content.lowerBound]),
                Data(data[line.full.upperBound...])
            )
        }
        return (data, Data())
    }

    static func splitMultipart(
        _ data: Data,
        boundary: String
    ) -> [Data] {
        let delimiter = Array("--\(boundary)".utf8)
        let closing = delimiter + Array("--".utf8)

        var parts: [Data] = []
        var partStart: Data.Index?
        var previousContentEnd = data.startIndex

        for line in lineRanges(data) {
            var content = Array(data[line.content])
            while let last = content.last, last == 0x20 || last == 0x09 {
                content.removeLast()
            }
            if content == delimiter || content == closing {
                if let start = partStart {
                    parts.append(start < previousContentEnd ? Data(data[start..<previousContentEnd]) : Data())
                }
                if content == closing {
                    return parts
                }
                partStart = line.full.upperBound
            }
            previousContentEnd = line.content.upperBound
        }
        if let start = partStart, start < data.endIndex {
            parts.append(Data(data[start...]))
        }
        return parts
    }

    /// Each line's range without and with its terminator.
    private static func lineRanges(
        _ data: Data
    ) -> [(content: Range<Data.Index>, full: Range<Data.Index>)] {
        var ranges: [(Range<Data.Index>, Range<Data.Index>)] = []
        var start = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == 0x0A {
                let contentEnd = index > start && data[index - 1] == 0x0D ? index - 1 : index
                ranges.append((start..<contentEnd, start..<(index + 1)))
                start = index + 1
            }
            index += 1
        }
        if start < data.endIndex {
            ranges.append((start..<data.endIndex, start..<data.endIndex))
        }
        return ranges
    }
}
