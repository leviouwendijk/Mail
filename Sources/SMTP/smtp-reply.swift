import MailConnection

public struct SMTPReply: Sendable, Equatable, CustomStringConvertible {
    public let code: Int
    /// Text of each reply line, without the code and separator.
    public let lines: [String]

    public init(
        code: Int,
        lines: [String]
    ) {
        self.code = code
        self.lines = lines
    }

    public var isPositive: Bool {
        (200..<400).contains(code)
    }

    public var description: String {
        "\(code) \(lines.joined(separator: " / "))"
    }

    /// Reads one possibly multi-line reply (`250-…` continued until `250 …`).
    public static func read(
        from transport: any MailTransport
    ) async throws -> SMTPReply {
        var code: Int?
        var lines: [String] = []

        while true {
            let line = try await transport.readLine()
            guard let parsed = SMTPGrammar.ReplyLine().parseComplete(line),
                  (200...599).contains(parsed.code),
                  code == nil || code == parsed.code,
                  // A bare code is only valid without text.
                  line.count == 3 || line.count > 3 && " -".contains(Array(line)[3])
            else {
                throw SMTPError.malformedReply(line)
            }
            code = parsed.code
            lines.append(parsed.text)

            if parsed.isFinal {
                return SMTPReply(code: parsed.code, lines: lines)
            }
        }
    }
}
