import Foundation
import Mail
import MailConnection

/// How `store` applies flags or labels: `+`, `-` or replace.
public enum IMAPStoreOperation: Sendable {
    case add
    case remove
    case replace

    var prefix: String {
        switch self {
        case .add: return "+"
        case .remove: return "-"
        case .replace: return ""
        }
    }
}

/// An IMAP conversation over an open transport. Fetches use `BODY.PEEK`, so
/// reading a message never marks it seen. Selections are read-only (`EXAMINE`)
/// unless asked otherwise; flag changes, moves and expunges need a writable one.
public actor IMAPSession {
    public let transport: any MailTransport
    public private(set) var capabilities: Set<String> = []
    public private(set) var selected: IMAPSelection?
    private var nextTag = 1

    public init(
        transport: any MailTransport
    ) {
        self.transport = transport
    }

    /// Reads the greeting and, with `startTLS`, upgrades the connection; `true`
    /// when the server pre-authenticated it.
    @discardableResult
    public func start(
        startTLS: Bool = false
    ) async throws -> Bool {
        guard case .status(let greeting) = try await IMAPResponse.read(from: transport) else {
            throw IMAPError.greetingRejected("no greeting")
        }
        guard greeting.isOK else {
            throw IMAPError.greetingRejected(greeting.text)
        }
        try await refreshCapabilities()

        if startTLS {
            // A pre-authenticated session cannot be upgraded (RFC 3501 §6.2.1).
            guard greeting.status != "PREAUTH", hasCapability("STARTTLS") else {
                throw MailConnectionError.startTLSUnavailable
            }
            try await execute([.text("STARTTLS")], name: "STARTTLS")
            try await transport.startTLS()
            try await refreshCapabilities()
        }
        return greeting.status == "PREAUTH"
    }

    /// Gmail's search syntax, thread IDs and labels.
    public var supportsGmailExtensions: Bool {
        hasCapability("X-GM-EXT-1")
    }

    public func hasCapability(
        _ name: String
    ) -> Bool {
        capabilities.contains(name.uppercased())
    }

    /// `AUTHENTICATE PLAIN` when offered, else `LOGIN` unless the server disables it.
    public func authenticate(
        _ credentials: MailCredentials
    ) async throws {
        if hasCapability("AUTH=PLAIN") {
            let response = MailSASL.plain(credentials)
            if hasCapability("SASL-IR") {
                try await execute([.text("AUTHENTICATE PLAIN"), .text(response)], name: "AUTHENTICATE")
            } else {
                try await execute([.text("AUTHENTICATE PLAIN")], name: "AUTHENTICATE", continuation: response)
            }
        } else if !hasCapability("LOGINDISABLED") {
            try await execute([.text("LOGIN"), .string(credentials.username), .string(credentials.password)], name: "LOGIN")
        } else {
            throw IMAPError.authenticationUnsupported(capabilities: capabilities.sorted())
        }
        try await refreshCapabilities()
    }

    /// Mailboxes matching `pattern`: `*` is every level, `%` one level.
    public func list(
        reference: String = "",
        pattern: String = "*"
    ) async throws -> [IMAPMailbox] {
        let responses = try await execute(
            [.text("LIST"), .mailbox(reference), .mailbox(pattern)],
            name: "LIST"
        )
        return responses.compactMap { values in
            guard values.count >= 4, values[0].isAtom("LIST"),
                  let attributes = values[1].list,
                  let encoded = values[3].text
            else {
                return nil
            }
            return IMAPMailbox(
                name: IMAPMailboxName.decode(encoded),
                delimiter: values[2].text.flatMap(\.first),
                attributes: Set(attributes.compactMap(\.text))
            )
        }
    }

    /// Counts without selecting the mailbox.
    public func status(
        _ mailbox: String
    ) async throws -> IMAPMailboxStatus {
        let responses = try await execute(
            [.text("STATUS"), .mailbox(mailbox), .text("(MESSAGES UNSEEN RECENT UIDNEXT UIDVALIDITY)")],
            name: "STATUS"
        )
        let items = responses.first { $0.first?.isAtom("STATUS") == true }?.last?.list ?? []
        let values = Self.pairs(items)
        return IMAPMailboxStatus(
            mailbox: mailbox,
            messages: values["MESSAGES"]?.number,
            unseen: values["UNSEEN"]?.number,
            recent: values["RECENT"]?.number,
            uidNext: values["UIDNEXT"]?.number,
            uidValidity: values["UIDVALIDITY"]?.number
        )
    }

    /// `EXAMINE` (read-only, the default) or `SELECT`.
    @discardableResult
    public func select(
        _ mailbox: String,
        readOnly: Bool = true
    ) async throws -> IMAPSelection {
        let command = readOnly ? "EXAMINE" : "SELECT"
        var exists = 0
        var recent = 0
        var flags: Set<IMAPFlag> = []
        var uidValidity: Int?
        var uidNext: Int?

        let (data, statuses, tagged) = try await run([.text(command), .mailbox(mailbox)], name: command)
        for values in data {
            if values.count >= 2, values[1].isAtom("EXISTS") {
                exists = values[0].number ?? exists
            } else if values.count >= 2, values[1].isAtom("RECENT") {
                recent = values[0].number ?? recent
            } else if values.first?.isAtom("FLAGS") == true, let list = values.last?.list {
                flags = Set(list.compactMap(\.text).map { IMAPFlag($0) })
            }
        }
        for status in statuses {
            let code = status.code?.split(separator: " ") ?? []
            if code.first == "UIDVALIDITY", code.count > 1 {
                uidValidity = Int(code[1])
            } else if code.first == "UIDNEXT", code.count > 1 {
                uidNext = Int(code[1])
            }
        }

        let selection = IMAPSelection(
            mailbox: mailbox,
            exists: exists,
            recent: recent,
            uidValidity: uidValidity,
            uidNext: uidNext,
            flags: flags,
            readOnly: readOnly || tagged.code == "READ-ONLY"
        )
        selected = selection
        return selection
    }

    /// UIDs in the selected mailbox matching `query`, ascending.
    public func search(
        _ query: IMAPSearch
    ) async throws -> [IMAPUID] {
        if query.usesGmailExtensions && !supportsGmailExtensions {
            throw IMAPError.unsupported(capability: "X-GM-EXT-1")
        }
        var parts: [IMAPCommandPart] = [.text("UID SEARCH")]
        if query.needsUTF8 {
            parts.append(.text("CHARSET UTF-8"))
        }
        parts += query.arguments()

        let responses = try await execute(parts, name: "SEARCH")
        return responses
            .filter { $0.first?.isAtom("SEARCH") == true }
            .flatMap { $0.dropFirst().compactMap { $0.number.map { IMAPUID(UInt32($0)) } } }
            .sorted()
    }

    /// Flags, dates, size and envelope for `uids` in the selected mailbox, in UID order.
    /// `headers` adds those header fields (such as `List-Id`); `structure` adds the MIME tree.
    public func summaries(
        _ uids: [IMAPUID],
        headers: [String] = [],
        structure: Bool = false
    ) async throws -> [IMAPMessageSummary] {
        guard !uids.isEmpty else {
            return []
        }
        let gmail = supportsGmailExtensions
        var items = ["UID", "FLAGS", "INTERNALDATE", "RFC822.SIZE", "ENVELOPE"]
        if gmail {
            items += ["X-GM-THRID", "X-GM-MSGID", "X-GM-LABELS"]
        }
        let fields = headers.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" }.uppercased() }.filter { !$0.isEmpty }
        if !fields.isEmpty {
            items.append("BODY.PEEK[HEADER.FIELDS (\(fields.joined(separator: " ")))]")
        }
        if structure {
            items.append("BODYSTRUCTURE")
        }

        let fetched = try await fetch(uids, items: "(" + items.joined(separator: " ") + ")")
        return try fetched.compactMap { values -> IMAPMessageSummary? in
            guard let uid = values["UID"]?.number else {
                return nil
            }
            let headerBlock = fields.isEmpty
                ? nil
                : values.first { $0.key.hasPrefix("BODY[HEADER.FIELDS") }?.value.data
            return IMAPMessageSummary(
                uid: IMAPUID(UInt32(uid)),
                flags: Set((values["FLAGS"]?.list ?? []).compactMap(\.text).map { IMAPFlag($0) }),
                internalDate: values["INTERNALDATE"]?.text.flatMap(MailDate.parseInternal),
                size: values["RFC822.SIZE"]?.number,
                envelope: try values["ENVELOPE"].map(IMAPEnvelope.init),
                gmail: gmail ? IMAPGmailAttributes(
                    threadID: values["X-GM-THRID"]?.text,
                    messageID: values["X-GM-MSGID"]?.text,
                    labels: (values["X-GM-LABELS"]?.list ?? []).compactMap(\.text).map { label in
                        label.hasPrefix("\\") ? label : IMAPMailboxName.decode(label)
                    }
                ) : nil,
                headers: fields.isEmpty ? nil : MailHeaders.parse(headerBlock ?? Data()),
                structure: structure ? try values["BODYSTRUCTURE"].map(IMAPBodyStructure.init) : nil
            )
        }
        .sorted { $0.uid < $1.uid }
    }

    /// Summaries in batches of `batchSize` UIDs, so a large mailbox streams instead
    /// of arriving as one response.
    public func summaries(
        _ uids: [IMAPUID],
        headers: [String] = [],
        structure: Bool = false,
        batchSize: Int,
        each: ([IMAPMessageSummary]) async throws -> Void
    ) async throws {
        let sorted = Set(uids).sorted()
        var start = 0
        while start < sorted.count {
            let end = min(start + max(1, batchSize), sorted.count)
            try await each(try await summaries(Array(sorted[start..<end]), headers: headers, structure: structure))
            start = end
        }
    }

    // MARK: - Changes

    /// Adds, removes or replaces flags on `uids` in the writable selection.
    public func store(
        _ flags: Set<IMAPFlag>,
        _ operation: IMAPStoreOperation = .add,
        on uids: [IMAPUID]
    ) async throws {
        try requireWritable()
        let list = "(" + flags.map(\.rawValue).sorted().joined(separator: " ") + ")"
        for set in IMAPUID.sets(uids) {
            try await execute(
                [.text("UID STORE"), .text(set), .text("\(operation.prefix)FLAGS.SILENT"), .text(list)],
                name: "STORE"
            )
        }
    }

    /// Adds, removes or replaces Gmail labels on `uids` (needs `X-GM-EXT-1`). System
    /// labels keep their backslash, such as `\Inbox`; removing `\Inbox` archives.
    public func storeLabels(
        _ labels: Set<String>,
        _ operation: IMAPStoreOperation = .add,
        on uids: [IMAPUID]
    ) async throws {
        guard supportsGmailExtensions else {
            throw IMAPError.unsupported(capability: "X-GM-EXT-1")
        }
        try requireWritable()
        let list = "(" + labels.sorted().map { label -> String in
            if label.hasPrefix("\\") {
                return label
            }
            if case .text(let quoted) = IMAPCommandPart.mailbox(label) {
                return quoted
            }
            return label
        }.joined(separator: " ") + ")"
        for set in IMAPUID.sets(uids) {
            try await execute(
                [.text("UID STORE"), .text(set), .text("\(operation.prefix)X-GM-LABELS"), .text(list)],
                name: "STORE"
            )
        }
    }

    /// Copies `uids` to `mailbox`; the mapping when the server reports it (UIDPLUS).
    @discardableResult
    public func copy(
        _ uids: [IMAPUID],
        to mailbox: String
    ) async throws -> IMAPUIDMapping? {
        var mapping: IMAPUIDMapping?
        for set in IMAPUID.sets(uids) {
            let (_, statuses, tagged) = try await run([.text("UID COPY"), .text(set), .mailbox(mailbox)], name: "COPY")
            mapping = IMAPUIDMapping.merging(mapping, codes: [tagged.code] + statuses.map(\.code))
        }
        return mapping
    }

    /// Moves `uids` to `mailbox` with `MOVE` (RFC 6851), else `COPY`, `\Deleted` and
    /// `UID EXPUNGE` (UIDPLUS). Never a plain `EXPUNGE`, which would also remove
    /// other messages already marked deleted; without either extension it refuses.
    @discardableResult
    public func move(
        _ uids: [IMAPUID],
        to mailbox: String
    ) async throws -> IMAPUIDMapping? {
        try requireWritable()
        guard !uids.isEmpty else {
            return nil
        }
        guard hasCapability("MOVE") else {
            guard hasCapability("UIDPLUS") else {
                throw IMAPError.unsupported(capability: "MOVE or UIDPLUS")
            }
            let mapping = try await copy(uids, to: mailbox)
            try await store([.deleted], .add, on: uids)
            try await expunge(uids)
            return mapping
        }

        var mapping: IMAPUIDMapping?
        for set in IMAPUID.sets(uids) {
            // The mapping arrives in an untagged OK before the expunges.
            let (_, statuses, tagged) = try await run([.text("UID MOVE"), .text(set), .mailbox(mailbox)], name: "MOVE")
            mapping = IMAPUIDMapping.merging(mapping, codes: statuses.map(\.code) + [tagged.code])
        }
        return mapping
    }

    /// Permanently removes `uids` that are marked `\Deleted`, and only those (UIDPLUS).
    public func expunge(
        _ uids: [IMAPUID]
    ) async throws {
        try requireWritable()
        guard hasCapability("UIDPLUS") else {
            throw IMAPError.unsupported(capability: "UIDPLUS")
        }
        for set in IMAPUID.sets(uids) {
            try await execute([.text("UID EXPUNGE"), .text(set)], name: "EXPUNGE")
        }
    }

    /// Creates `mailbox`; one that already exists is not an error.
    public func create(
        _ mailbox: String
    ) async throws {
        do {
            try await execute([.text("CREATE"), .mailbox(mailbox)], name: "CREATE")
        } catch IMAPError.commandFailed(_, let status) where status.code == "ALREADYEXISTS" {
            return
        }
    }

    private func requireWritable() throws {
        guard let selected, !selected.readOnly else {
            throw IMAPError.notWritable(mailbox: selected?.mailbox)
        }
    }

    /// The full raw message, without setting `\Seen`.
    public func raw(
        _ uid: IMAPUID
    ) async throws -> Data? {
        let items = try await fetch([uid], items: "(UID BODY.PEEK[])")
        return items.first { $0["UID"]?.number == Int(uid.rawValue) }?["BODY[]"]?.data
    }

    public func message(
        _ uid: IMAPUID
    ) async throws -> ReceivedMessage? {
        try await raw(uid).map(ReceivedMessage.init(parsing:))
    }

    /// The first mailbox advertising `role` (SPECIAL-USE).
    public func mailbox(
        for role: IMAPSpecialUse
    ) async throws -> IMAPMailbox? {
        try await list().first { $0.specialUse == role }
    }

    /// Stores `message` in `mailbox`, as for a draft or a sent copy. Returns the
    /// new UID when the server reports it (UIDPLUS `APPENDUID`).
    @discardableResult
    public func append(
        _ message: Data,
        to mailbox: String,
        flags: Set<IMAPFlag> = []
    ) async throws -> IMAPUID? {
        let flagList = "(" + flags.map(\.rawValue).sorted().joined(separator: " ") + ")"
        let (_, _, tagged) = try await run(
            [.text("APPEND"), .mailbox(mailbox), .text(flagList), .literal(message)],
            name: "APPEND"
        )
        let code = tagged.code?.split(separator: " ") ?? []
        guard code.count == 3, code[0].uppercased() == "APPENDUID", let uid = UInt32(code[2]) else {
            return nil
        }
        return IMAPUID(uid)
    }

    public func logout() async throws {
        _ = try? await run([.text("LOGOUT")], name: "LOGOUT")
    }

    // MARK: - Commands

    private func refreshCapabilities() async throws {
        let responses = try await execute([.text("CAPABILITY")], name: "CAPABILITY")
        capabilities = Set(
            responses
                .filter { $0.first?.isAtom("CAPABILITY") == true }
                .flatMap { $0.dropFirst().compactMap { $0.text?.uppercased() } }
        )
    }

    private func fetch(
        _ uids: [IMAPUID],
        items: String
    ) async throws -> [[String: IMAPValue]] {
        var responses: [[IMAPValue]] = []
        for set in IMAPUID.sets(uids) {
            responses += try await execute(
                [.text("UID FETCH"), .text(set), .text(items)],
                name: "FETCH"
            )
        }
        return responses.compactMap { values in
            guard values.count >= 3, values[1].isAtom("FETCH"), let list = values[2].list else {
                return nil
            }
            return Self.pairs(list)
        }
    }

    @discardableResult
    private func execute(
        _ parts: [IMAPCommandPart],
        name: String,
        continuation: String? = nil
    ) async throws -> [[IMAPValue]] {
        try await run(parts, name: name, continuation: continuation).data
    }

    /// Sends one tagged command and collects responses until its completion.
    private func run(
        _ parts: [IMAPCommandPart],
        name: String,
        continuation: String? = nil
    ) async throws -> (data: [[IMAPValue]], statuses: [IMAPStatusText], tagged: IMAPStatusText) {
        var collected = Collected(tag: "A\(nextTag)", name: name)
        nextTag += 1
        let nonSynchronizing = hasCapability("LITERAL+")

        var line = Data(collected.tag.utf8)
        for part in parts {
            if !part.closesGroup {
                line.append(0x20)
            }
            switch part {
            case .text(let text):
                line.append(Data(text.utf8))
            case .literal(let bytes):
                line.append(Data("{\(bytes.count)\(nonSynchronizing ? "+" : "")}\r\n".utf8))
                try await transport.write(line)
                if !nonSynchronizing {
                    try await awaitContinuation(&collected)
                }
                line = bytes
            }
        }
        line.append(Data("\r\n".utf8))
        try await transport.write(line)

        if let continuation {
            try await awaitContinuation(&collected)
            try await transport.writeLine(continuation)
        }

        while true {
            if let status = try collected.add(try await IMAPResponse.read(from: transport)) {
                guard status.isOK else {
                    throw IMAPError.commandFailed(command: name, status: status)
                }
                return (collected.data, collected.statuses, status)
            }
        }
    }

    private func awaitContinuation(
        _ collected: inout Collected
    ) async throws {
        while true {
            let response = try await IMAPResponse.read(from: transport)
            if case .continuation = response {
                return
            }
            if let status = try collected.add(response) {
                throw IMAPError.commandFailed(command: collected.name, status: status)
            }
        }
    }

    /// Untagged responses gathered while one command runs.
    private struct Collected {
        let tag: String
        let name: String
        var data: [[IMAPValue]] = []
        var statuses: [IMAPStatusText] = []

        /// The completion status once the command's tagged response arrives.
        mutating func add(
            _ response: IMAPResponse
        ) throws -> IMAPStatusText? {
            switch response {
            case .tagged(let responseTag, let status) where responseTag == tag:
                return status
            case .status(let status):
                if status.status == "BYE" && name != "LOGOUT" {
                    throw IMAPError.connectionEnded(status)
                }
                statuses.append(status)
            case .data(let values):
                data.append(values)
            case .tagged, .continuation:
                break
            }
            return nil
        }
    }

    /// `KEY value KEY value …` as a dictionary with uppercased keys.
    private static func pairs(
        _ values: [IMAPValue]
    ) -> [String: IMAPValue] {
        var result: [String: IMAPValue] = [:]
        var index = 0
        while index + 1 < values.count {
            if let key = values[index].text {
                result[key.uppercased()] = values[index + 1]
            }
            index += 2
        }
        return result
    }
}
