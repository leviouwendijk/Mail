import Foundation
import IMAP
import Mail
@_spi(Testing) import MailIndex
import Testing

enum IndexTests {
    static let fields = "BODY[HEADER.FIELDS (LIST-ID LIST-UNSUBSCRIBE PRECEDENCE AUTO-SUBMITTED AUTHENTICATION-RESULTS RETURN-PATH)]"
    static let text = "(\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 100 3 NIL NIL NIL NIL)"
    static let invoice = "((\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 3) (\"application\" \"pdf\" NIL NIL NIL \"base64\" 40000 NIL (\"attachment\" (\"filename\" \"factuur.pdf\")) NIL NIL) \"mixed\")"

    /// One summary response, its header fields sent as a literal.
    static func fetch(
        _ sequence: Int,
        uid: Int,
        flags: String,
        from: (String, String, String),
        to: (String, String),
        subject: String,
        replyTo: (String, String)? = nil,
        headers: [String] = [],
        structure: String = text
    ) -> [String] {
        let block = headers.map { $0 + "\r\n" }.joined() + "\r\n"
        let sender = "((\"\(from.0)\" NIL \"\(from.1)\" \"\(from.2)\"))"
        let reply = replyTo.map { "((NIL NIL \"\($0.0)\" \"\($0.1)\"))" } ?? "NIL"
        let envelope = "(\"Mon, 2 Nov 2026 10:00:00 +0100\" \"\(subject)\" \(sender) NIL \(reply) ((NIL NIL \"\(to.0)\" \"\(to.1)\")) NIL NIL NIL \"<m\(uid)@\(from.2)>\")"
        return [
            "* \(sequence) FETCH (UID \(uid) FLAGS (\(flags)) INTERNALDATE \"02-Nov-2026 10:00:00 +0100\" RFC822.SIZE 2000 ENVELOPE \(envelope) \(fields) {\(block.utf8.count)}",
            block + " BODYSTRUCTURE \(structure))",
        ]
    }

    static let newsletter = ["List-Id: Deals <deals.shop.example>", "List-Unsubscribe: <mailto:u@shop.example>"]

    static func syncAndCount() async throws {
        let listing = [
            "* LIST (\\HasNoChildren) \"/\" \"INBOX\"",
            "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"",
        ]
        var lines = ["* OK ready", "* CAPABILITY IMAP4rev1 SPECIAL-USE UIDPLUS", "A1 OK done"]
        lines += listing + ["A2 OK listed"]
        lines += ["* 3 EXISTS", "* OK [UIDVALIDITY 5] v", "* OK [UIDNEXT 4] n", "A3 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1 2 3", "A4 OK searched"]
        lines += fetch(1, uid: 1, flags: "", from: ("Shop", "news", "shop.example"), to: ("contact", "leviouwendijk.com"), subject: "Deals", headers: newsletter)
        lines += fetch(2, uid: 2, flags: "", from: ("Shop", "news", "shop.example"), to: ("contact", "leviouwendijk.com"), subject: "More deals", headers: newsletter)
        lines += fetch(3, uid: 3, flags: "\\Seen \\Answered", from: ("Jan", "jan", "example.org"), to: ("contact", "leviouwendijk.com"), subject: "Vraag")
        lines += ["A5 OK fetched"]
        lines += ["* 1 EXISTS", "* OK [UIDVALIDITY 6] v", "* OK [UIDNEXT 2] n", "A6 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1", "A7 OK searched"]
        lines += fetch(1, uid: 1, flags: "\\Seen", from: ("Levi", "contact", "leviouwendijk.com"), to: ("Jan", "example.org"), subject: "Re: Vraag")
        lines += ["A8 OK fetched"]

        // Second run, INBOX only: 1 is gone, 2 was read, 4 is new.
        lines += listing + ["A9 OK listed"]
        lines += ["* 3 EXISTS", "* OK [UIDVALIDITY 5] v", "* OK [UIDNEXT 5] n", "A10 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 2 3 4", "A11 OK searched"]
        lines += ["* 1 FETCH (UID 2 FLAGS (\\Seen))", "* 2 FETCH (UID 3 FLAGS (\\Seen \\Answered))", "A12 OK fetched"]
        lines += ["* SEARCH 4", "A13 OK searched"]
        lines += fetch(
            3, uid: 4, flags: "",
            from: ("SIDN Registratie", "billing", "domein-registratie.example"),
            to: ("contact", "leviouwendijk.com"),
            subject: "Factuur domeinregistratie",
            replyTo: ("pay", "elders.example"),
            headers: ["Authentication-Results: mx.example; spf=pass smtp.mailfrom=x; dkim=none; dmarc=fail header.from=domein-registratie.example"],
            structure: invoice
        )
        lines += ["A14 OK fetched"]

        let transport = ScriptedTransport(lines)
        let session = IMAPSession(transport: transport)
        try await session.start()
        let index = try MailIndex(path: ":memory:")

        let first = try await index.sync(session)
        try Expect.equal(first.mailboxes, 2, "Both mailboxes")
        try Expect.equal(first.added, 4, "Every message")

        let totals = try await index.totals()
        try Expect.equal(totals.messages, 3, "Sent mail left out of counts")
        try Expect.equal(totals.correspondents, 1, "Jan was written to")

        let senders = try await index.clutter(by: .sender)
        try Expect.equal(senders.first?.key, "news@shop.example", "Biggest sender first")
        try Expect.equal(senders.first?.count, 2, "Count")
        try Expect.equal(senders.first?.unread, 2, "Unread")
        try Expect.equal(senders.first?.unsubscribable, 2, "Unsubscribe header")
        try Expect.false(senders.first?.correspondent ?? true, "Never written to")
        try Expect.true(senders.first { $0.key == "jan@example.org" }?.correspondent ?? false, "Correspondent")

        let lists = try await index.clutter(by: .list)
        try Expect.equal(lists.map(\.key), ["deals.shop.example"], "List-Id unwrapped")

        let deals = try await index.select(MailIndexFilter(listID: "deals.shop.example"))
        try Expect.equal(deals.mailboxes, [.init(name: "INBOX", uidValidity: 5, uids: [IMAPUID(1), IMAPUID(2)])], "Selection with UIDVALIDITY")

        let second = try await index.sync(session, mailboxes: ["INBOX"])
        try Expect.equal(second.removed, 1, "Expunged message dropped")
        try Expect.equal(second.flagsChanged, 1, "Read state refreshed")
        try Expect.equal(second.added, 1, "Only the new message fetched")

        let strangersWithFiles = try await index.select(MailIndexFilter(fromCorrespondent: false, hasAttachment: true))
        try Expect.equal(strangersWithFiles.mailboxes.first?.uids, [IMAPUID(4)], "Unknown sender with a pdf")
        try Expect.equal(try await index.totals().unread, 1, "Only the invoice is unread")

        try Expect.true(
            await transport.commands().contains("A13 UID SEARCH UID 4:*"),
            "Incremental search from the stored UIDNEXT"
        )
    }

    static func indexedFields() throws {
        try Expect.equal(IndexedMessage.listID("Deals <Deals.Shop.Example>"), "deals.shop.example", "List-Id")
        try Expect.equal(IndexedMessage.domain("<bounce@Mail.Example.org>"), "mail.example.org", "Return-Path domain")
        let results = "mx; spf=pass smtp.mailfrom=a; dkim=none; dmarc=fail header.from=x"
        try Expect.equal(IndexedMessage.result("dmarc", in: results), "fail", "DMARC")
        try Expect.equal(IndexedMessage.result("dkim", in: results), "none", "DKIM")
        try Expect.equal(IndexedMessage.result("arc", in: "mx; spf=pass"), nil, "Absent method")
    }
}
