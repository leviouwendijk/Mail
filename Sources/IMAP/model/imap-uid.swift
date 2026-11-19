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
        ranges(uids).joined(separator: ",")
    }

    /// Compact sets of at most `maxLength` characters each, so a large scattered
    /// selection stays under servers' command-line limits.
    public static func sets(
        _ uids: [IMAPUID],
        maxLength: Int = 4000
    ) -> [String] {
        var sets: [String] = []
        var current = ""
        for range in ranges(uids) {
            if !current.isEmpty && current.count + 1 + range.count > maxLength {
                sets.append(current)
                current = ""
            }
            current += current.isEmpty ? range : "," + range
        }
        if !current.isEmpty {
            sets.append(current)
        }
        return sets
    }

    /// The UIDs of a set such as `304,319:320`, in the order written; `nil` for
    /// `*` or anything malformed.
    public static func parse(
        set: String
    ) -> [IMAPUID]? {
        var uids: [IMAPUID] = []
        for item in set.split(separator: ",") {
            let bounds = item.split(separator: ":", maxSplits: 1).map { UInt32($0) }
            guard let first = bounds.first ?? nil else {
                return nil
            }
            guard bounds.count == 2 else {
                uids.append(IMAPUID(first))
                continue
            }
            guard let last = bounds[1] else {
                return nil
            }
            uids += (min(first, last)...max(first, last)).map { IMAPUID($0) }
        }
        return uids
    }

    private static func ranges(
        _ uids: [IMAPUID]
    ) -> [String] {
        let sorted = Set(uids).sorted()
        var ranges: [(UInt32, UInt32)] = []
        for uid in sorted {
            if let last = ranges.last, last.1 + 1 == uid.rawValue {
                ranges[ranges.count - 1].1 = uid.rawValue
            } else {
                ranges.append((uid.rawValue, uid.rawValue))
            }
        }
        return ranges.map { $0.0 == $0.1 ? "\($0.0)" : "\($0.0):\($0.1)" }
    }
}

/// Where copied or moved messages landed, from UIDPLUS `COPYUID` (RFC 4315).
public struct IMAPUIDMapping: Sendable, Equatable {
    /// The destination mailbox's `UIDVALIDITY`.
    public let uidValidity: Int
    /// Source UID → destination UID.
    public let uids: [IMAPUID: IMAPUID]

    public init(
        uidValidity: Int,
        uids: [IMAPUID: IMAPUID]
    ) {
        self.uidValidity = uidValidity
        self.uids = uids
    }

    /// Parses a response code such as `COPYUID 38505 304,319:320 3956:3958`.
    public init?(
        code: String
    ) {
        let parts = code.split(separator: " ")
        guard parts.count == 4, parts[0].uppercased() == "COPYUID",
              let uidValidity = Int(parts[1]),
              let source = IMAPUID.parse(set: String(parts[2])),
              let destination = IMAPUID.parse(set: String(parts[3])),
              source.count == destination.count
        else {
            return nil
        }
        self.uidValidity = uidValidity
        self.uids = Dictionary(zip(source, destination), uniquingKeysWith: { _, last in last })
    }

    /// The first `COPYUID` among `codes`, merged with `previous` from an earlier batch.
    static func merging(
        _ previous: IMAPUIDMapping?,
        codes: [String?]
    ) -> IMAPUIDMapping? {
        guard let next = codes.lazy.compactMap({ $0.flatMap(IMAPUIDMapping.init(code:)) }).first else {
            return previous
        }
        guard let previous, previous.uidValidity == next.uidValidity else {
            return next
        }
        return IMAPUIDMapping(
            uidValidity: next.uidValidity,
            uids: previous.uids.merging(next.uids, uniquingKeysWith: { _, last in last })
        )
    }
}
