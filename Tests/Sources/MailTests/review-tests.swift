import Foundation
import IMAP
import Mail
@_spi(Testing) import MailIndex
import Testing

enum ReviewTests {
    static let pdf = "((\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 3) (\"application\" \"pdf\" NIL NIL NIL \"base64\" 40000 NIL (\"attachment\" (\"filename\" \"factuur.pdf\")) NIL NIL) \"mixed\")"
    static let html = "((\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 3) (\"text\" \"html\" NIL NIL NIL \"base64\" 900 3 NIL (\"attachment\" (\"filename\" \"inloggen.html\")) NIL NIL) \"mixed\")"

    /// contact@hondenmeesters.nl with a fake invoice, a real one, a lookalike
    /// phish, a newsletter and a question from someone written to before.
    static func indexed() async throws -> MailIndex {
        let to = ("contact", "hondenmeesters.nl")
        var lines = ["* OK ready", "* CAPABILITY IMAP4rev1 SPECIAL-USE UIDPLUS", "A1 OK done"]
        lines += ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"", "A2 OK listed"]
        lines += ["* 5 EXISTS", "* OK [UIDVALIDITY 5] v", "* OK [UIDNEXT 6] n", "A3 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1 2 3 4 5", "A4 OK searched"]
        lines += IndexTests.fetch(
            1, uid: 1, flags: "",
            from: ("Domein Registratie", "billing", "domein-registratie.example"), to: to,
            subject: "Factuur domeinregistratie hondenmeesters.nl",
            replyTo: ("pay", "elders.example"),
            headers: ["Authentication-Results: mx; spf=pass smtp.mailfrom=x; dkim=none; dmarc=fail header.from=domein-registratie.example"],
            structure: pdf
        )
        lines += IndexTests.fetch(2, uid: 2, flags: "\\Seen", from: ("TransIP", "facturen", "transip.nl"), to: to, subject: "Factuur 2026-11", structure: pdf)
        lines += IndexTests.fetch(3, uid: 3, flags: "", from: ("Hondenmeesters", "support", "hondenmeesterrs.nl"), to: to, subject: "Uw wachtwoord verloopt", structure: html)
        lines += IndexTests.fetch(4, uid: 4, flags: "", from: ("Shop", "news", "shop.example"), to: to, subject: "Deals", headers: IndexTests.newsletter)
        lines += IndexTests.fetch(5, uid: 5, flags: "\\Seen", from: ("Jan", "jan", "example.org"), to: to, subject: "Vraag over factuur")
        lines += ["A5 OK fetched"]
        lines += ["* 1 EXISTS", "* OK [UIDVALIDITY 6] v", "* OK [UIDNEXT 2] n", "A6 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1", "A7 OK searched"]
        lines += IndexTests.fetch(1, uid: 1, flags: "\\Seen", from: ("Hondenmeesters", "contact", "hondenmeesters.nl"), to: ("jan", "example.org"), subject: "Re: Vraag")
        lines += ["A8 OK fetched"]

        let session = IMAPSession(transport: ScriptedTransport(lines))
        try await session.start()
        let index = try MailIndex(path: ":memory:")
        _ = try await index.sync(session)
        return index
    }

    static let policy = MailSuspicionPolicy(trustedDomains: ["transip.nl"], ownDomains: ["hondenmeesters.nl"])

    static func scoring() async throws {
        let index = try await indexed()
        let suspects = try await index.suspicious(policy)
        try Expect.equal(suspects.map(\.uid.rawValue), [3, 1], "Phish and fake invoice, highest first")

        let fake = try Expect.notNil(suspects.first { $0.uid == IMAPUID(1) }, "Fake invoice")
        let signals = Set(fake.reasons.map(\.signal))
        try Expect.equal(
            signals,
            [.paymentRequest, .unknownVendor, .stranger, .rareSender, .dmarcFail, .replyElsewhere],
            "Every fake-invoice signal"
        )
        try Expect.equal(fake.attachmentNames, ["factuur.pdf"], "Attachment shown")

        let phish = try Expect.notNil(suspects.first { $0.uid == IMAPUID(3) }, "Lookalike")
        try Expect.true(phish.reasons.contains { $0.signal == .lookalike && $0.detail.contains("hondenmeesters.nl") }, "Imitates your domain")
        try Expect.true(phish.reasons.contains { $0.signal == .riskyAttachment }, "HTML attachment")

        let all = try await index.suspicious(MailSuspicionPolicy(trustedDomains: ["transip.nl"], ownDomains: ["hondenmeesters.nl"], threshold: 0))
        try Expect.false(all.contains { $0.uid == IMAPUID(2) }, "Trusted vendor never scored")
        let jan = try Expect.notNil(all.first { $0.uid == IMAPUID(5) }, "Correspondent scored")
        try Expect.equal(jan.reasons.map(\.signal), [.paymentRequest], "A correspondent is no stranger or unknown vendor")
    }

    static func decisions() async throws {
        let index = try await indexed()
        try await index.decide(MailDecision(.dismiss, .message, try Expect.notNil(try await index.messageID(IMAPUID(3), in: "INBOX"), "Message-ID")))
        try await index.decide(MailDecision(.block, .domain, "Shop.Example", note: "never subscribed"))
        try await index.decide(MailDecision(.trust, .sender, "billing@domein-registratie.example"))

        let suspects = try await index.suspicious(policy)
        try Expect.equal(suspects.map(\.uid.rawValue), [4], "Only the blocked newsletter remains")
        try Expect.true(suspects[0].reasons.contains { $0.signal == .blocked }, "Blocked reason")

        let stored = try await index.decisions()
        try Expect.equal(stored.count, 3, "Decisions kept")
        try Expect.equal(stored[1].value, "shop.example", "Lowercased")
        try Expect.equal(stored[1].note, "never subscribed", "Note")

        try await index.undecide(.domain, "shop.example")
        try Expect.equal(try await index.suspicious(policy).count, 0, "Undone")
    }

    static func domains() throws {
        let own: Set<String> = ["hondenmeesters.nl"]
        try Expect.equal(MailDomain.imitates("mail.hondenmeesterrs.nl", own), "hondenmeesters.nl", "One edit away")
        try Expect.equal(MailDomain.imitates("hondenmeesters-betaling.com", own), "hondenmeesters.nl", "Carries the name")
        try Expect.equal(MailDomain.imitates("hondenmeesters.nl", own), nil, "Itself")
        try Expect.equal(MailDomain.imitates("transip.nl", own), nil, "Unrelated")
        try Expect.true(MailDomain.related("bounce.mailer.shop.example", "shop.example"), "Subdomain related")
        try Expect.true(MailDomain.isWithin("mail.transip.nl", ["transip.nl"]), "Within a trusted domain")
        try Expect.false(MailDomain.isWithin("eviltransip.nl", ["transip.nl"]), "Suffix is not a subdomain")
        try Expect.equal(MailDomain.distance("kitten", "sitting"), 3, "Levenshtein")
    }

    /// 2026-11-19: two fake "Domeinregistratie" invoices from random gmail
    /// addresses scored 20 because a gmail correspondent made gmail.com a known domain.
    static func freemailCampaign() async throws {
        let to = ("contact", "hondenmeesters.nl")
        let invoice = "((\"text\" \"plain\" NIL NIL NIL \"7bit\" 100 3) (\"application\" \"pdf\" NIL NIL NIL \"base64\" 40000 NIL (\"attachment\" (\"filename\" \"Factuur 100200.pdf\")) NIL NIL) \"mixed\")"
        var lines = ["* OK ready", "* CAPABILITY IMAP4rev1 SPECIAL-USE UIDPLUS", "A1 OK done"]
        lines += ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "* LIST (\\HasNoChildren \\Sent) \"/\" \"Sent\"", "A2 OK listed"]
        lines += ["* 3 EXISTS", "* OK [UIDVALIDITY 5] v", "* OK [UIDNEXT 4] n", "A3 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1 2 3", "A4 OK searched"]
        lines += IndexTests.fetch(1, uid: 1, flags: "", from: ("Sanne", "sanne.b1234", "gmail.com"), to: to, subject: "Domeinregistratie voor 2027 / 2028", structure: invoice)
        lines += IndexTests.fetch(2, uid: 2, flags: "", from: ("Petra", "petra.v5678", "gmail.com"), to: to, subject: "Domeinregistratie voor 2027 / 2028", structure: invoice)
        lines += IndexTests.fetch(3, uid: 3, flags: "\\Seen", from: ("Klant", "klant.hond", "gmail.com"), to: to, subject: "Vraag over de factuur")
        lines += ["A5 OK fetched"]
        lines += ["* 1 EXISTS", "* OK [UIDVALIDITY 6] v", "* OK [UIDNEXT 2] n", "A6 OK [READ-ONLY] examined"]
        lines += ["* SEARCH 1", "A7 OK searched"]
        lines += IndexTests.fetch(1, uid: 1, flags: "\\Seen", from: ("Hondenmeesters", "contact", "hondenmeesters.nl"), to: ("klant.hond", "gmail.com"), subject: "Re: Vraag")
        lines += ["A8 OK fetched"]

        let session = IMAPSession(transport: ScriptedTransport(lines))
        try await session.start()
        let index = try MailIndex(path: ":memory:")
        _ = try await index.sync(session)

        let suspects = try await index.suspicious(policy)
        try Expect.equal(suspects.map(\.uid.rawValue).sorted(), [1, 2], "Both fake invoices, not the client")
        let signals = Set(suspects[0].reasons.map(\.signal))
        try Expect.true(signals.isSuperset(of: [.freemailInvoice, .campaign, .stranger, .unknownVendor, .rareSender]), "A gmail correspondent does not vouch for gmail.com")
    }
}
