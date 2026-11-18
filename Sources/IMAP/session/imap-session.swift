import Foundation
import Mail
import MailConnection

/// A read-only IMAP conversation over an open transport. Fetches use `BODY.PEEK`,
/// so reading a message never marks it seen.
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
    public func summaries(
        _ uids: [IMAPUID]
    ) async throws -> [IMAPMessageSummary] {
        guard !uids.isEmpty else {
            return []
        }
        let items = try await fetch(uids, items: "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)")
        return try items.compactMap { values -> IMAPMessageSummary? in
            guard let uid = values["UID"]?.number else {
                return nil
            }
            return IMAPMessageSummary(
                uid: IMAPUID(UInt32(uid)),
                flags: Set((values["FLAGS"]?.list ?? []).compactMap(\.text).map { IMAPFlag($0) }),
                internalDate: values["INTERNALDATE"]?.text.flatMap(MailDate.parseInternal),
                size: values["RFC822.SIZE"]?.number,
                envelope: try values["ENVELOPE"].map(IMAPEnvelope.init)
            )
        }
        .sorted { $0.uid < $1.uid }
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
        let responses = try await execute(
            [.text("UID FETCH"), .text(IMAPUID.set(uids)), .text(items)],
            name: "FETCH"
        )
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
