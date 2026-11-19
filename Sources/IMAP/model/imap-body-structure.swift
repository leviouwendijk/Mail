import Foundation
import Mail

/// `Content-Disposition` as reported in `BODYSTRUCTURE`, such as `attachment` with a filename.
public struct IMAPBodyDisposition: Sendable, Equatable {
    /// Lowercased: `attachment` or `inline`.
    public let kind: String
    /// Lowercased keys.
    public let parameters: [String: String]

    init?(
        _ value: IMAPValue
    ) {
        guard let items = value.list, let kind = items.first?.text else {
            return nil
        }
        self.kind = kind.lowercased()
        self.parameters = items.count > 1 ? IMAPBodyStructure.parameters(items[1]) : [:]
    }
}

/// One leaf of a message's MIME tree.
public struct IMAPBodyPart: Sendable, Equatable {
    /// Lowercased, such as `application`.
    public let type: String
    /// Lowercased, such as `pdf`.
    public let subtype: String
    /// Content-Type parameters, lowercased keys (`charset`, `name`).
    public let parameters: [String: String]
    public let encoding: String?
    /// Encoded size in bytes.
    public let size: Int?
    public let disposition: IMAPBodyDisposition?

    public var mediaType: String {
        "\(type)/\(subtype)"
    }

    /// The disposition's filename, else the Content-Type `name`, encoded words decoded.
    public var filename: String? {
        (disposition?.parameters["filename"] ?? parameters["name"]).map(MIMEEncoding.decodeEncodedWords)
    }

    /// Marked as an attachment, or carrying a filename (Apple Mail sends attached
    /// files as `inline` with a filename).
    public var isAttachment: Bool {
        disposition?.kind == "attachment" || filename != nil
    }
}

/// The `BODYSTRUCTURE` fetch item (RFC 3501 §7.4.2): the MIME tree without the content.
public indirect enum IMAPBodyStructure: Sendable, Equatable {
    case part(IMAPBodyPart)
    case multipart(subtype: String, parts: [IMAPBodyStructure])

    /// Every leaf part, depth first.
    public var parts: [IMAPBodyPart] {
        switch self {
        case .part(let part):
            return [part]
        case .multipart(_, let parts):
            return parts.flatMap(\.parts)
        }
    }

    public var attachments: [IMAPBodyPart] {
        parts.filter(\.isAttachment)
    }

    public init(
        _ value: IMAPValue
    ) throws {
        guard let items = value.list, !items.isEmpty else {
            throw IMAPError.malformedResponse("BODYSTRUCTURE")
        }

        // A multipart body starts with its parts, each a list, then the subtype.
        if items[0].list != nil {
            let parts = items.prefix { $0.list != nil }
            self = .multipart(
                subtype: items.dropFirst(parts.count).first?.text?.lowercased() ?? "mixed",
                parts: try parts.map(IMAPBodyStructure.init)
            )
            return
        }

        guard items.count >= 7, let type = items[0].text?.lowercased(), let subtype = items[1].text?.lowercased() else {
            throw IMAPError.malformedResponse("BODYSTRUCTURE")
        }
        // Text parts add a line count; message/rfc822 adds envelope, body and line count.
        let extensions: Int
        switch (type, subtype) {
        case ("text", _): extensions = 8
        case ("message", "rfc822"), ("message", "global"): extensions = 10
        default: extensions = 7
        }
        // Extension data: MD5, then disposition.
        let disposition = items.indices.contains(extensions + 1) ? IMAPBodyDisposition(items[extensions + 1]) : nil

        self = .part(
            IMAPBodyPart(
                type: type,
                subtype: subtype,
                parameters: Self.parameters(items[2]),
                encoding: items[5].text?.lowercased(),
                size: items[6].number,
                disposition: disposition
            )
        )
    }

    /// `("KEY" "value" …)` with lowercased keys; `NIL` is empty.
    static func parameters(
        _ value: IMAPValue
    ) -> [String: String] {
        let items = value.list ?? []
        var result: [String: String] = [:]
        var index = 0
        while index + 1 < items.count {
            if let key = items[index].text, let value = items[index + 1].text {
                result[key.lowercased()] = value
            }
            index += 2
        }
        return result
    }
}
