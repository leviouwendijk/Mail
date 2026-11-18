/// A mailbox's role as advertised by SPECIAL-USE (RFC 6154).
public enum IMAPSpecialUse: String, Sendable, Hashable, CaseIterable, Codable {
    case all
    case archive
    case drafts
    case flagged
    case junk
    case sent
    case trash

    init?(
        attribute: String
    ) {
        guard attribute.hasPrefix("\\") else {
            return nil
        }
        self.init(rawValue: attribute.dropFirst().lowercased())
    }
}

public struct IMAPMailbox: Sendable, Hashable {
    /// Decoded from modified UTF-7, e.g. `INBOX/Clients/Rex`.
    public let name: String
    /// The hierarchy separator, such as `/` or `.`; `nil` for a flat namespace.
    public let delimiter: Character?
    /// Attributes such as `\HasChildren`, `\Noselect` or `\Sent`.
    public let attributes: Set<String>

    public init(
        name: String,
        delimiter: Character?,
        attributes: Set<String>
    ) {
        self.name = name
        self.delimiter = delimiter
        self.attributes = attributes
    }

    public var path: [String] {
        guard let delimiter else {
            return [name]
        }
        return name.split(separator: delimiter).map(String.init)
    }

    public var isSelectable: Bool {
        !attributes.contains { attribute in
            ["\\noselect", "\\nonexistent"].contains(attribute.lowercased())
        }
    }

    public var specialUse: IMAPSpecialUse? {
        attributes.lazy.compactMap { IMAPSpecialUse(attribute: $0) }.first
    }

    public var isInbox: Bool {
        name.uppercased() == "INBOX"
    }
}

public struct IMAPMailboxStatus: Sendable, Equatable {
    public let mailbox: String
    public let messages: Int?
    public let unseen: Int?
    public let recent: Int?
    public let uidNext: Int?
    public let uidValidity: Int?
}

public struct IMAPSelection: Sendable, Equatable {
    public let mailbox: String
    public let exists: Int
    public let recent: Int
    public let uidValidity: Int?
    public let uidNext: Int?
    public let flags: Set<IMAPFlag>
    public let readOnly: Bool
}
