/// A message's UID within one mailbox, stable while the mailbox's `UIDVALIDITY` is unchanged.
public struct IMAPUID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(
        rawValue: UInt32
    ) {
        self.rawValue = rawValue
    }

    public init(
        _ rawValue: UInt32
    ) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: IMAPUID,
        rhs: IMAPUID
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        String(rawValue)
    }

    /// A compact sequence set such as `1:3,7,9:10`.
    public static func set(
        _ uids: [IMAPUID]
    ) -> String {
        let sorted = Set(uids).sorted()
        var ranges: [(UInt32, UInt32)] = []
        for uid in sorted {
            if let last = ranges.last, last.1 + 1 == uid.rawValue {
                ranges[ranges.count - 1].1 = uid.rawValue
            } else {
                ranges.append((uid.rawValue, uid.rawValue))
            }
        }
        return ranges
            .map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0):\($0.1)" }
            .joined(separator: ",")
    }
}
