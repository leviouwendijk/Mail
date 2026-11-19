import Foundation
import IMAP
import Mail
import MailConnection
import Testing

enum IMAPChangeTests {
    static func uidSets() throws {
        let scattered = stride(from: UInt32(1), through: 400, by: 2).map { IMAPUID($0) }
        let sets = IMAPUID.sets(scattered, maxLength: 100)
        try Expect.true(sets.count > 1, "Long scattered selections split")
        try Expect.true(sets.allSatisfy { $0.count <= 100 }, "Each set within the limit")
        try Expect.equal(sets.flatMap { IMAPUID.parse(set: $0) ?? [] }, scattered, "Splits lose nothing")

        try Expect.equal(IMAPUID.parse(set: "304,319:320")?.map(\.rawValue), [304, 319, 320], "Parse set")
        try Expect.equal(IMAPUID.parse(set: "5:*"), nil, "Star is not a UID")

        let mapping = try Expect.notNil(IMAPUIDMapping(code: "COPYUID 38505 304,319:320 3956:3958"), "COPYUID")
        try Expect.equal(mapping.uidValidity, 38505, "Destination UIDVALIDITY")
        try Expect.equal(mapping.uids[IMAPUID(320)], IMAPUID(3958), "Pairs in order")

        try Expect.equal(IMAPSearch.uidsFrom(IMAPUID(500)).arguments().preview, "UID 500:*", "Sync from UIDNEXT")
    }

    static func bodyStructure() throws {
        let response = try IMAPResponse.parse(
            "* 1 FETCH (UID 5 BODYSTRUCTURE ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 120 4 NIL NIL NIL NIL)"
                + "((\"text\" \"plain\" NIL NIL NIL \"7bit\" 10 1)(\"text\" \"html\" NIL NIL NIL \"7bit\" 30 1) \"alternative\")"
                + "(\"application\" \"pdf\" (\"name\" \"factuur.pdf\") NIL NIL \"base64\" 52340 NIL (\"attachment\" (\"filename\" \"=?UTF-8?Q?factuur_november.pdf?=\")) NIL NIL)"
                + "(\"application\" \"pdf\" (\"name\" \"offerte.pdf\") NIL NIL \"base64\" 2000 NIL (\"inline\" (\"filename\" \"offerte.pdf\")) NIL NIL)"
                + " \"mixed\" (\"boundary\" \"b1\") NIL NIL NIL))"
        )
        guard case .data(let values) = response, let items = values.last?.list, items.count == 4 else {
            throw TestFlowAssertionFailure(label: "bodystructure", message: "expected a fetch")
        }
        let structure = try IMAPBodyStructure(items[3])
        guard case .multipart(let subtype, let parts) = structure else {
            throw TestFlowAssertionFailure(label: "bodystructure", message: "expected multipart")
        }
        try Expect.equal(subtype, "mixed", "Multipart subtype")
        try Expect.equal(parts.count, 4, "Top-level parts")
        try Expect.equal(structure.parts.map(\.mediaType), ["text/plain", "text/plain", "text/html", "application/pdf", "application/pdf"], "Leaves depth first")
        try Expect.equal(structure.parts[0].parameters["charset"], "utf-8", "Parameters")

        let attachments = structure.attachments
        try Expect.equal(attachments.map(\.filename), ["factuur november.pdf", "offerte.pdf"], "Attachment and inline file")
        try Expect.equal(attachments[0].size, 52340, "Size")
        try Expect.equal(attachments[0].disposition?.kind, "attachment", "Disposition")
    }

    static func moveAndFlag() async throws {
        let headers = "List-Id: Nieuws <nieuws.example.org>\r\nList-Unsubscribe: <mailto:u@example.org>\r\n\r\n"
        let transport = ScriptedTransport([
            "* OK ready",
            "* CAPABILITY IMAP4rev1 UIDPLUS MOVE",
            "A1 OK done",
            "* 3 EXISTS",
            "* OK [UIDVALIDITY 7] valid",
            "A2 OK [READ-WRITE] selected",
            "* 1 FETCH (UID 5 FLAGS (\\Seen) RFC822.SIZE 53000 BODY[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE)] {\(headers.utf8.count)}",
            headers + " BODYSTRUCTURE (\"application\" \"pdf\" NIL NIL NIL \"base64\" 100 NIL (\"attachment\" (\"filename\" \"a.pdf\")) NIL NIL))",
            "A3 OK done",
            "A4 OK stored",
            "A5 NO [ALREADYEXISTS] Mailbox exists",
            "* OK [COPYUID 12 5:6 100:101] moved",
            "* 1 EXPUNGE",
            "* 1 EXPUNGE",
            "A6 OK done",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()

        do {
            try await session.store([.flagged], on: [IMAPUID(5)])
            throw TestFlowAssertionFailure(label: "store", message: "changes need a writable selection")
        } catch IMAPError.notWritable(let mailbox) {
            try Expect.equal(mailbox, nil, "Nothing selected")
        }

        let selection = try await session.select("Archief", readOnly: false)
        try Expect.false(selection.readOnly, "Selected writable")

        let summaries = try await session.summaries([IMAPUID(5)], headers: ["List-Id", "List-Unsubscribe"], structure: true)
        let summary = try Expect.notNil(summaries.first, "Summary")
        try Expect.equal(summary.headers?["list-id"], "Nieuws <nieuws.example.org>", "Header fields")
        try Expect.equal(summary.structure?.attachments.first?.filename, "a.pdf", "Structure")

        try await session.store([.flagged], on: [IMAPUID(5), IMAPUID(6)])
        try await session.create("Records/2026")
        let mapping = try await session.move([IMAPUID(6), IMAPUID(5)], to: "Records/2026")
        try Expect.equal(mapping?.uidValidity, 12, "Destination UIDVALIDITY")
        try Expect.equal(mapping?.uids, [IMAPUID(5): IMAPUID(100), IMAPUID(6): IMAPUID(101)], "Mapping from untagged COPYUID")

        try Expect.equal(
            await transport.commands(),
            [
                "A1 CAPABILITY",
                "A2 SELECT \"Archief\"",
                "A3 UID FETCH 5 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY.PEEK[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE)] BODYSTRUCTURE)",
                "A4 UID STORE 5:6 +FLAGS.SILENT (\\Flagged)",
                "A5 CREATE \"Records/2026\"",
                "A6 UID MOVE 5:6 \"Records/2026\"",
            ],
            "Commands"
        )
    }

    static func moveFallback() async throws {
        let transport = ScriptedTransport([
            "* OK ready",
            "* CAPABILITY IMAP4rev1 UIDPLUS",
            "A1 OK done",
            "A2 OK [READ-WRITE] selected",
            "A3 OK [COPYUID 1 3:4,9 20:22] copied",
            "A4 OK stored",
            "* 1 EXPUNGE",
            "A5 OK expunged",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()
        try await session.select("INBOX", readOnly: false)
        let mapping = try await session.move([3, 4, 9].map { IMAPUID($0) }, to: "Pruned")
        try Expect.equal(mapping?.uids[IMAPUID(9)], IMAPUID(22), "Mapping from COPY")
        try Expect.equal(
            await transport.commands(),
            [
                "A1 CAPABILITY",
                "A2 SELECT \"INBOX\"",
                "A3 UID COPY 3:4,9 \"Pruned\"",
                "A4 UID STORE 3:4,9 +FLAGS.SILENT (\\Deleted)",
                "A5 UID EXPUNGE 3:4,9",
            ],
            "Copy, mark, expunge only those UIDs"
        )

        let bare = ScriptedTransport(["* OK ready", "* CAPABILITY IMAP4rev1", "A1 OK done", "A2 OK [READ-WRITE] selected"])
        let plain = IMAPSession(transport: bare)
        try await plain.start()
        try await plain.select("INBOX", readOnly: false)
        do {
            try await plain.move([IMAPUID(1)], to: "Pruned")
            throw TestFlowAssertionFailure(label: "move", message: "must not fall back to a plain EXPUNGE")
        } catch IMAPError.unsupported(let capability) {
            try Expect.equal(capability, "MOVE or UIDPLUS", "Names what is missing")
        }
        try Expect.equal(await bare.commands().count, 2, "Nothing sent for the refused move")
    }

    static func gmailLabels() async throws {
        let transport = ScriptedTransport([
            "* OK Gimap ready",
            "* CAPABILITY IMAP4rev1 X-GM-EXT-1 UIDPLUS MOVE",
            "A1 OK done",
            "A2 OK [READ-WRITE] selected",
            "* 1 FETCH (X-GM-LABELS (\\Inbox \"Records/2026\") UID 9)",
            "A3 OK done",
            "* 1 FETCH (X-GM-LABELS (\"Records/2026\") UID 9)",
            "A4 OK done",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()
        try await session.select("[Gmail]/All Mail", readOnly: false)
        try await session.storeLabels(["Records/2026"], on: [IMAPUID(9)])
        try await session.storeLabels(["\\Inbox"], .remove, on: [IMAPUID(9)])
        try Expect.equal(
            Array(await transport.commands().suffix(2)),
            [
                "A3 UID STORE 9 +X-GM-LABELS (\"Records/2026\")",
                "A4 UID STORE 9 -X-GM-LABELS (\\Inbox)",
            ],
            "Label, then archive"
        )
    }
}
