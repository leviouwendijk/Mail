import Foundation
import IMAP
import Mail
import MailConnection
import Testing

enum IMAPTests {
    static func values() async throws {
        // A Latin-1 literal: not valid UTF-8, so it must never pass through String.
        let literal = Data("Caf\u{E9}\r\nworld".data(using: .isoLatin1)!)
        let transport = ScriptedTransport([])
        await transport.feed(Data("* 1 FETCH (UID 7 FLAGS (\\Seen $Junk) BODY[HEADER.FIELDS (SUBJECT)] {\(literal.count)}\r\n".utf8))
        await transport.feed(literal)
        await transport.feed(Data(" X NIL \"a \\\"q\\\"\")\r\n".utf8))

        guard case .data(let values) = try await IMAPResponse.read(from: transport) else {
            throw TestFlowAssertionFailure(label: "response", message: "expected untagged data")
        }
        try Expect.equal(values.count, 3, "Number, atom, list")
        let items = try Expect.notNil(values[2].list, "Fetch list")
        try Expect.equal(items[0], .atom("UID"), "Atom")
        try Expect.equal(items[3].list, [.atom("\\Seen"), .atom("$Junk")], "Flag list")
        try Expect.equal(items[4], .atom("BODY[HEADER.FIELDS (SUBJECT)]"), "Section kept whole")
        try Expect.equal(items[5].data, literal, "Literal bytes intact")
        try Expect.equal(items[7], .absent, "NIL")
        try Expect.equal(items[8].text, "a \"q\"", "Escaped quoted string")
    }

    static func mailboxNames() throws {
        try Expect.equal(IMAPMailboxName.encode("Entwürfe"), "Entw&APw-rfe", "Non-ASCII run")
        try Expect.equal(IMAPMailboxName.encode("R&D"), "R&-D", "Ampersand")
        try Expect.equal(IMAPMailboxName.decode("Entw&APw-rfe"), "Entwürfe", "Decode")
        for name in ["Klanten/日本", "INBOX.Ärger & Co", "📬"] {
            try Expect.equal(IMAPMailboxName.decode(IMAPMailboxName.encode(name)), name, "Round trip \(name)")
        }
    }

    static func searchQueries() throws {
        let utc = TimeZone(identifier: "UTC")!
        let since = Date(timeIntervalSince1970: 1_793_491_200) // 1 Nov 2026

        let includeSince = true
        let query = IMAPSearch.matching {
            IMAPSearch.unread
            IMAPSearch.from("jan@example.org")
            if includeSince { IMAPSearch.since(since) }
        } && !.subject("nieuwsbrief")
        try Expect.equal(
            query.arguments(timeZone: utc).preview,
            "UNSEEN FROM jan@example.org SINCE 1-Nov-2026 NOT SUBJECT nieuwsbrief",
            "Conjunction flattens"
        )

        let either = (IMAPSearch.unseen && .flagged) || .from("Jan de Vries")
        try Expect.equal(either.arguments().preview, "OR (UNSEEN FLAGGED) FROM \"Jan de Vries\"", "OR groups conjunctions")

        let any = IMAPSearch.any(.from("a"), .from("b"), .from("c"))
        try Expect.equal(any.arguments().preview, "OR FROM a OR FROM b FROM c", "Any chains OR")

        let unicode = IMAPSearch.subject("één")
        try Expect.true(unicode.needsUTF8, "Non-ASCII needs CHARSET")
        try Expect.equal(unicode.arguments().preview, "SUBJECT {5}één", "Non-ASCII becomes a literal")

        try Expect.equal(IMAPUID.set([7, 1, 2, 3, 9, 10].map { IMAPUID($0) }), "1:3,7,9:10", "UID set")
    }

    static func session() async throws {
        let raw = "From: Jan <jan@example.org>\r\nSubject: Hoi\r\n\r\nTot morgen\r\n"
        let transport = ScriptedTransport([
            "* OK [CAPABILITY IMAP4rev1] ready",
            "* CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+",
            "A1 OK done",
            "A2 OK authenticated",
            "* CAPABILITY IMAP4rev1 LITERAL+ SPECIAL-USE",
            "A3 OK done",
            "* LIST (\\HasChildren) \"/\" \"INBOX\"",
            "* LIST (\\HasNoChildren \\Sent) \"/\" \"Verzonden\"",
            "* LIST (\\HasNoChildren) \"/\" \"INBOX/Klanten/Entw&APw-rfe\"",
            "A4 OK done",
            "* STATUS \"INBOX\" (MESSAGES 12 UNSEEN 3 RECENT 0 UIDNEXT 45 UIDVALIDITY 99)",
            "A5 OK done",
            "* FLAGS (\\Seen \\Flagged)",
            "* 12 EXISTS",
            "* 0 RECENT",
            "* OK [UIDVALIDITY 99] valid",
            "* OK [UIDNEXT 45] next",
            "A6 OK [READ-ONLY] examined",
            "* SEARCH 42 40",
            "A7 OK done",
            "* 1 FETCH (UID 40 FLAGS () INTERNALDATE \"16-Nov-2026 08:00:00 +0100\" RFC822.SIZE 900 ENVELOPE (NIL \"Eerder\" NIL NIL NIL NIL NIL NIL NIL NIL))",
            "* 2 FETCH (UID 42 FLAGS (\\Flagged) INTERNALDATE \"17-Nov-2026 09:30:00 +0100\" RFC822.SIZE 1234 ENVELOPE (\"Tue, 17 Nov 2026 09:30:00 +0100\" \"=?UTF-8?Q?Afspraak_morgen?=\" ((\"Jan de Vries\" NIL \"jan\" \"example.org\")) NIL NIL ((NIL NIL \"levi\" \"example.com\")) NIL NIL NIL \"<abc@example.org>\"))",
            "A8 OK done",
            "* 2 FETCH (UID 42 BODY[] {\(raw.utf8.count)}",
            raw + ")",
            "A9 OK done",
            "* BYE logging out",
            "A10 OK done",
        ])
        let session = IMAPSession(transport: transport)

        try await session.start()
        try await session.authenticate(MailCredentials(username: "levi", password: "secret"))
        try Expect.true(await session.hasCapability("SPECIAL-USE"), "Capabilities refreshed after login")

        let mailboxes = try await session.list()
        try Expect.equal(mailboxes.map(\.name), ["INBOX", "Verzonden", "INBOX/Klanten/Entwürfe"], "Names decoded")
        try Expect.equal(mailboxes[1].specialUse, .sent, "Special use")
        try Expect.equal(mailboxes[2].path, ["INBOX", "Klanten", "Entwürfe"], "Path split on delimiter")

        let status = try await session.status("INBOX")
        try Expect.equal(status.unseen, 3, "Unseen count without selecting")

        let selection = try await session.select("INBOX")
        try Expect.equal(selection.exists, 12, "Exists")
        try Expect.equal(selection.uidValidity, 99, "UIDVALIDITY from response code")
        try Expect.true(selection.readOnly, "Examined read-only")

        let uids = try await session.search(.unread && .from("jan"))
        try Expect.equal(uids, [IMAPUID(40), IMAPUID(42)], "UIDs sorted")

        let summaries = try await session.summaries(uids)
        try Expect.equal(summaries.map(\.uid), [IMAPUID(40), IMAPUID(42)], "Summaries in UID order")
        try Expect.true(summaries[0].isUnread, "No \\Seen means unread")
        let envelope = try Expect.notNil(summaries[1].envelope, "Envelope")
        try Expect.equal(envelope.subject, "Afspraak morgen", "Envelope subject decoded")
        try Expect.equal(envelope.from.first?.name, "Jan de Vries", "Envelope from")
        try Expect.equal(envelope.messageID, "abc@example.org", "Envelope message id")

        let message = try Expect.notNil(try await session.message(IMAPUID(42)), "Message")
        try Expect.equal(message.subject, "Hoi", "Fetched message parsed")
        try Expect.equal(message.text, "Tot morgen\r\n", "Fetched body")

        try await session.logout()

        try Expect.equal(
            await transport.commands(),
            [
                "A1 CAPABILITY",
                "A2 AUTHENTICATE PLAIN AGxldmkAc2VjcmV0",
                "A3 CAPABILITY",
                "A4 LIST \"\" \"*\"",
                "A5 STATUS \"INBOX\" (MESSAGES UNSEEN RECENT UIDNEXT UIDVALIDITY)",
                "A6 EXAMINE \"INBOX\"",
                "A7 UID SEARCH UNSEEN FROM jan",
                "A8 UID FETCH 40,42 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)",
                "A9 UID FETCH 42 (UID BODY.PEEK[])",
                "A10 LOGOUT",
            ],
            "Command sequence"
        )
    }

    static func synchronizingLiteral() async throws {
        let transport = ScriptedTransport([
            "* OK ready",
            "* CAPABILITY IMAP4rev1",
            "A1 OK done",
            "+ go ahead",
            "* SEARCH 3",
            "A2 OK done",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()

        let uids = try await session.search(.subject("één"))
        try Expect.equal(uids, [IMAPUID(3)], "Search result")
        try Expect.equal(
            await transport.written,
            ["A1 CAPABILITY\r\n", "A2 UID SEARCH CHARSET UTF-8 SUBJECT {5}\r\n", "één\r\n"],
            "Literal waits for continuation"
        )
    }

    static func failure() async throws {
        let transport = ScriptedTransport([
            "* OK ready",
            "* CAPABILITY IMAP4rev1",
            "A1 OK done",
            "A2 NO [NONEXISTENT] no such mailbox",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()
        do {
            _ = try await session.select("Nope")
            throw TestFlowAssertionFailure(label: "select", message: "should fail")
        } catch IMAPError.commandFailed(let command, let status) {
            try Expect.equal(command, "EXAMINE", "Command")
            try Expect.equal(status.code, "NONEXISTENT", "Response code")
        }
    }
}
