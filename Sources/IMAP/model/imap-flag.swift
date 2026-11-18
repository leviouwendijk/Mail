public struct IMAPFlag: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(
        rawValue: String
    ) {
        self.rawValue = rawValue
    }

    public init(
        _ rawValue: String
    ) {
        self.rawValue = rawValue
    }

    public static let seen = IMAPFlag("\\Seen")
    public static let answered = IMAPFlag("\\Answered")
    public static let flagged = IMAPFlag("\\Flagged")
    public static let deleted = IMAPFlag("\\Deleted")
    public static let draft = IMAPFlag("\\Draft")
    public static let recent = IMAPFlag("\\Recent")

    public var description: String {
        rawValue
    }
}
