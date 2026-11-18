import Foundation
import Mail
import MailFrame
import Testing

enum AccessTests {
    static func profile() throws -> (MailAccounts, MailAccess) {
        let accounts = try MailAccounts.merging([
            MailAccounts(source: MailFrame.example, environment: FrameTests.environment),
        ])
        return (accounts, try accounts.access(named: "clientDesk"))
    }

    static func matching() throws {
        let (accounts, access) = try profile()
        try Expect.equal(access.accounts, ["work"], "Binding resolved to its name")
        try Expect.true(access.allows(mailbox: "inbox"), "INBOX is case-insensitive")
        try Expect.true(access.allows(mailbox: "INBOX/Klanten"), "Wildcard includes its parent")
        try Expect.true(access.allows(mailbox: "Inbox/Klanten/Rex"), "Wildcard includes children")
        try Expect.false(access.allows(mailbox: "INBOX/Privé"), "Sibling refused")
        try Expect.false(access.allows(mailbox: "Sent"), "Other mailbox refused")
        try Expect.false(access.allows(account: "personal"), "Other account refused")
        try Expect.true(access.allows(identity: "INFO@practice.example"), "Identity case-insensitive")
        try Expect.false(access.allows(identity: "alex@practice.example"), "Other identity refused")

        let work = try Expect.notNil(accounts.account(named: "work"), "Work")
        try Expect.equal(work.sending, .confirm, "Account allows sending with confirmation")
        try Expect.equal(access.sending(for: work), .drafts, "Profile tightens to drafts")
        try Expect.equal(access.identities(of: work).map(\.address.address.raw), ["info@practice.example"], "Visible identities")
        try Expect.equal(access.visibleAccounts(in: accounts).map(\.identifier), ["work"], "Visible accounts")

        try Expect.throwsError("Gmail syntax under a mailbox limit") { try access.checkCrossLabelSearch() }
        try Expect.throwsError("No sending") { try access.checkSending() }
        try Expect.doesNotThrow("Drafts allowed") { try access.checkDrafting() }
    }

    static func names() throws {
        let (accounts, _) = try profile()
        try Expect.equal(try accounts.access(named: nil), .unrestricted, "No profile means unrestricted")
        try Expect.throwsError("Unknown profile") { _ = try accounts.access(named: "nope") }

        let base = """
            import Mail;
            let a: Account = .{
                .provider = .{ .imap = .{ .host = "imap.example.org" } },
                .username = "a",
                .password = .{ .env = "A" },
                .identities = [.{ .address = "a@example.org" }],
            };
            """
        let elsewhere = """
            import Mail;
            let readOnly: Access = .{ .accounts = ["a"], .draft = false };
            """
        let merged = try MailAccounts.merging([MailAccounts(source: base), MailAccounts(source: elsewhere)])
        let readOnly = try merged.access(named: "readOnly")
        try Expect.equal(readOnly.accounts, ["a"], "Names an account of another file")
        try Expect.false(readOnly.mayDraft, "Read only")
        try Expect.false(readOnly.maySend, "Read only cannot send")

        try Expect.throwsError("Unknown account name") {
            _ = try MailAccounts.merging([
                MailAccounts(source: base),
                MailAccounts(source: "import Mail;\nlet x: Access = .{ .accounts = [\"missing\"] };"),
            ])
        }
    }
}
