import Foundation
import IMAP
import Mail
import MailIndex
import Testing

enum PlanTests {
    /// Summary responses with only a UID and a Message-ID, as the executor checks them.
    static func present(
        _ items: [(sequence: Int, uid: Int, messageID: String)]
    ) -> [String] {
        items.map { "* \($0.sequence) FETCH (UID \($0.uid) FLAGS () ENVELOPE (NIL \"x\" NIL NIL NIL NIL NIL NIL NIL \"<\($0.messageID)>\"))" }
    }

    static func applyAndUndo() async throws {
        let index = try await ReviewTests.indexed()
        let suspects = try await index.suspicious(ReviewTests.policy)
        try Expect.equal(suspects.map(\.uid.rawValue), [3, 1], "Phish and fake invoice")

        let plan = MailPlan(steps: [
            .init(.move(to: "Review/Suspicious"), reason: "suspicious", targets: try await index.targets(suspects)),
            .init(.addFlags(["$Suspicious"]), reason: "mark", targets: try await index.targets(MailIndexFilter(sender: "news@shop.example"))),
        ])
        try Expect.equal(plan.count, 3, "Two suspects and the newsletter")

        // UID 3 became another message since indexing; UID 1 still is the fake invoice.
        var lines = ["* OK ready", "* CAPABILITY IMAP4rev1 UIDPLUS MOVE", "A1 OK done"]
        lines += ["* OK [UIDVALIDITY 5] v", "A2 OK [READ-WRITE] selected"]
        lines += present([(1, 1, "m1@domein-registratie.example"), (2, 3, "other@example.org")]) + ["A3 OK fetched"]
        lines += ["* LIST (\\HasNoChildren) \"/\" \"INBOX\"", "A4 OK listed"]
        lines += ["A5 OK created"]
        lines += ["* OK [COPYUID 9 1 50] moved", "* 1 EXPUNGE", "A6 OK done"]
        lines += ["* OK [UIDVALIDITY 5] v", "A7 OK [READ-WRITE] selected"]
        lines += present([(1, 4, "m4@shop.example")]) + ["A8 OK fetched"]
        lines += ["A9 OK stored"]
        let transport = ScriptedTransport(lines)
        let session = IMAPSession(transport: transport)
        try await session.start()

        let report = try await MailPlanExecutor(index: index, session: session).execute(plan, resync: false)
        try Expect.equal(report.applied, 2, "The invoice moved, the newsletter flagged")
        try Expect.equal(report.skipped.map(\.target.uid.rawValue), [3], "The changed message skipped")
        try Expect.true(report.skipped[0].reason.contains("another message"), "Says why")
        try Expect.equal(report.touched, ["INBOX", "Review/Suspicious"], "Touched mailboxes")
        try Expect.equal(
            await transport.commands().suffix(8),
            [
                "A2 SELECT \"INBOX\"",
                "A3 UID FETCH 1,3 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)",
                "A4 LIST \"\" \"*\"",
                "A5 CREATE \"Review/Suspicious\"",
                "A6 UID MOVE 1 \"Review/Suspicious\"",
                "A7 SELECT \"INBOX\"",
                "A8 UID FETCH 4 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE)",
                "A9 UID STORE 4 +FLAGS.SILENT ($Suspicious)",
            ],
            "Verify, then act on what still matches"
        )

        let journal = try await index.journal(plan: plan.id)
        try Expect.equal(journal.filter(\.isDone).count, 2, "Done entries")
        let moved = try Expect.notNil(journal.first { $0.isDone && $0.target.uid == IMAPUID(1) }, "Move journaled")
        try Expect.equal(moved.destinationUID, IMAPUID(50), "New UID from COPYUID")
        try Expect.notNil(try await index.plan(plan.id)?.appliedAt, "Marked applied")

        // Undo: the flag comes off first (later step), then the invoice moves back.
        let undo = try await index.undoPlan(for: plan.id)
        try Expect.equal(undo.steps.map(\.action), [.removeFlags(["$Suspicious"]), .move(to: "INBOX")], "Reverse order")
        try Expect.equal(undo.steps[1].targets, [.init(mailbox: "Review/Suspicious", uidValidity: 9, uid: IMAPUID(50), messageID: "m1@domein-registratie.example")], "From where it landed")

        var back = ["* OK ready", "* CAPABILITY IMAP4rev1 UIDPLUS MOVE", "A1 OK done"]
        back += ["* OK [UIDVALIDITY 5] v", "A2 OK [READ-WRITE] selected"]
        back += present([(1, 4, "m4@shop.example")]) + ["A3 OK fetched", "A4 OK stored"]
        back += ["* OK [UIDVALIDITY 9] v", "A5 OK [READ-WRITE] selected"]
        back += present([(1, 50, "m1@domein-registratie.example")]) + ["A6 OK fetched"]
        back += ["* OK [COPYUID 5 50 7] moved", "A7 OK done"]
        let undoTransport = ScriptedTransport(back)
        let undoSession = IMAPSession(transport: undoTransport)
        try await undoSession.start()
        let undone = try await MailPlanExecutor(index: index, session: undoSession).undo(plan.id, resync: false)
        try Expect.equal(undone.applied, 2, "Both reversed")
        try Expect.true(await undoTransport.commands().contains("A7 UID MOVE 50 \"INBOX\""), "No CREATE for INBOX; moved back")
        try Expect.notNil(try await index.plan(plan.id)?.undoneAt, "Original marked undone")
    }

    static func renumbered() async throws {
        let index = try await ReviewTests.indexed()
        let plan = MailPlan(steps: [
            .init(.move(to: "Pruned"), reason: "old", targets: try await index.targets(MailIndexFilter(sender: "news@shop.example"))),
        ])
        let transport = ScriptedTransport([
            "* OK ready", "* CAPABILITY IMAP4rev1 UIDPLUS MOVE", "A1 OK done",
            "* OK [UIDVALIDITY 77] v", "A2 OK [READ-WRITE] selected",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()
        let report = try await MailPlanExecutor(index: index, session: session).execute(plan, resync: false)
        try Expect.equal(report.applied, 0, "Nothing done")
        try Expect.true(report.skipped.first?.reason.contains("renumbered") ?? false, "UIDVALIDITY change refuses the mailbox")
        try Expect.equal(await transport.commands().count, 2, "No fetch, no move")
    }

    /// RackNerd's Dovecot: `.` between levels, personal folders under `INBOX.`.
    static func dovecotNames() async throws {
        let transport = ScriptedTransport([
            "* OK ready", "* CAPABILITY IMAP4rev1 NAMESPACE UIDPLUS MOVE", "A1 OK done",
            "* LIST (\\HasNoChildren) \".\" \"INBOX.spam\"", "A2 OK listed",
            "* NAMESPACE ((\"INBOX.\" \".\")) NIL NIL", "A3 OK namespace",
            "* LIST (\\HasNoChildren) \".\" \"INBOX.spam\"", "A4 OK listed",
        ])
        let session = IMAPSession(transport: transport)
        try await session.start()
        try Expect.equal(try await session.resolve(mailbox: "Review/Suspicious"), "INBOX.Review.Suspicious", "Separator and namespace prefix")
        try Expect.equal(try await session.resolve(mailbox: "INBOX.spam"), "INBOX.spam", "An existing name as is")
        try Expect.equal(try await session.resolve(mailbox: "inbox"), "INBOX", "INBOX")
    }
}
