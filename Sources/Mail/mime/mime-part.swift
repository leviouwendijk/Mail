public struct MIMEPart: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// Already transfer-encoded, with CRLF line breaks.
        case body(String)
        case multipart(subtype: String, boundary: String, parts: [MIMEPart])
    }

    public var headers: [MailHeaderField]
    public var content: Content

    public init(
        headers: [MailHeaderField],
        content: Content
    ) {
        self.headers = headers
        self.content = content
    }

    public static func multipart(
        _ subtype: String,
        boundary: String,
        parts: [MIMEPart]
    ) -> MIMEPart {
        MIMEPart(
            headers: [
                MailHeaderField("Content-Type", "multipart/\(subtype); boundary=\"\(boundary)\"")
            ],
            content: .multipart(subtype: subtype, boundary: boundary, parts: parts)
        )
    }

    public func rendered() -> String {
        let crlf = MIMEEncoding.crlf
        var output = headers
            .map { "\($0.name): \($0.value)" + crlf }
            .joined()
        output += crlf

        switch content {
        case .body(let body):
            output += body
        case .multipart(_, let boundary, let parts):
            for part in parts {
                output += "--\(boundary)" + crlf
                output += part.rendered()
                output += crlf
            }
            output += "--\(boundary)--"
        }
        return output
    }
}
